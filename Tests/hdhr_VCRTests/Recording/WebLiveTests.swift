import Testing
import Foundation
@testable import hdhr_VCR

// MARK: - Browser live TV (AppState+WebLive.swift)
//
// Live TV for a browser holds a real tuner, so the bookkeeping around it decides whether a recording can start:
// refusals must say why, the last viewer out must free the tuner and delete the spool, quitting must free every
// tuner, and each session must count against its device's occupancy. None of these needs a tuner to run — they use
// the session table directly (the puller itself is covered by the FEED cache tests).

@Suite("Browser live TV")
struct WebLiveTests {

    private func session(id: String = "live-1", device: String = "DEV1", channel: String = "5.1", viewers: Int = 1) throws -> WebLiveSession {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("\(id)-\(UUID().uuidString).ts").path
        try Data([0x47]).write(to: URL(fileURLWithPath: path))
        var s = WebLiveSession(id: id, deviceId: device, guideNumber: channel, title: "KFOO", cachePath: path,
                               startedAt: Date(), lastActive: Date())
        s.viewers = viewers
        return s
    }

    private func message(_ r: Result<WebLiveSession, WebLiveError>) -> String? {
        if case .failure(let e) = r { return e.message }
        return nil
    }

    // MARK: refusals

    @Test func startIsRefusedWhenWebStreamingIsOff() async {
        let state = await makeTestAppState(devices: [.test(id: "DEV1")], lineups: ["DEV1": [.test(number: "5.1")]])
        await MainActor.run { state.config.Web_streaming_enabled = false }
        let r = await state.startWebLive(deviceId: "DEV1", guideNumber: "5.1")
        #expect(message(r)?.contains("Web streaming is off") == true)
    }

    @Test func startIsRefusedForAnUnknownTuner() async {
        let state = await makeTestAppState(devices: [.test(id: "DEV1")])
        await MainActor.run { state.config.Web_streaming_enabled = true }
        let r = await state.startWebLive(deviceId: "NOPE", guideNumber: "5.1")
        #expect(message(r) == "Tuner not found")
    }

    @Test func startIsRefusedForAChannelTheTunerDoesNotHave() async {
        let state = await makeTestAppState(devices: [.test(id: "DEV1")], lineups: ["DEV1": [.test(number: "5.1")]])
        await MainActor.run { state.config.Web_streaming_enabled = true }
        let r = await state.startWebLive(deviceId: "DEV1", guideNumber: "99.9")
        #expect(message(r) == "Channel not found")
    }

    @Test func startIsRefusedWhenEveryTunerIsBusy_andNothingIsLeftBehind() async {
        let state = await makeTestAppState(devices: [.test(id: "DEV1", tuners: 1)], lineups: ["DEV1": [.test(number: "5.1")]])
        await MainActor.run {
            state.config.Web_streaming_enabled = true
            state.deviceTunerOccupancy["DEV1"] = [DeviceTunerInfo(Resource: "tuner0", VctNumber: "7.1", TargetIP: nil, SignalQualityPercent: nil)]
        }
        let r = await state.startWebLive(deviceId: "DEV1", guideNumber: "5.1")
        #expect(message(r) == "All tuners are in use")
        #expect(await state.webLiveSessions.isEmpty)
    }

    // MARK: concurrent first requests

    @Test @MainActor func twoFirstRequestsWaitingOnTheAirScanShareOneTunerStream() async throws {
        let scriptPath = try writeMockCurlScript(sleepSeconds: 30, outputBytes: 4096)
        defer { try? FileManager.default.removeItem(atPath: scriptPath) }
        let manager = RecordingManager(curlExecutablePath: scriptPath)
        let state = makeTestAppState(devices: [.test(id: "DEV1", tuners: 2)], lineups: ["DEV1": [.test(number: "5.1")]], recordingManager: manager)
        state.config.Web_streaming_enabled = true
        // An air scan holds a tuner, so both requests pause in yieldOTAScan before either has started a stream.
        state.otaScanDeviceId = "DEV1"
        state.otaScanTask = Task { try? await Task.sleep(for: .seconds(60)) }
        state.otaHeldResources = ["tuner0", "tuner1"]
        defer { state.otaScanTask?.cancel(); state.stopAllWebLive(reason: "test") }

        async let a = state.startWebLive(deviceId: "DEV1", guideNumber: "5.1")
        async let b = state.startWebLive(deviceId: "DEV1", guideNumber: "5.1")
        try? await Task.sleep(nanoseconds: 300_000_000)
        state.otaHeldResources = []   // the scan lets go; both callers resume
        let (ra, rb) = await (a, b)

        let sa = try ra.get(), sb = try rb.get()
        #expect(sa.id == sb.id)
        #expect(state.webLiveSessions.count == 1)
        #expect(state.webLiveSessions[sa.id]?.viewers == 2)
    }

    // MARK: viewers

    @Test func theTunerIsFreedOnlyWhenTheLastViewerLeaves() async throws {
        let state = await makeTestAppState(devices: [.test(id: "DEV1", tuners: 2)])
        let s = try session(viewers: 2)
        await MainActor.run { state.webLiveSessions[s.id] = s }

        await MainActor.run { state.releaseWebLiveViewer(id: s.id) }
        #expect(await state.webLiveSessions[s.id]?.viewers == 1)
        #expect(FileManager.default.fileExists(atPath: s.cachePath))

        await MainActor.run { state.releaseWebLiveViewer(id: s.id) }
        #expect(await state.webLiveSessions[s.id] == nil)
        #expect(!FileManager.default.fileExists(atPath: s.cachePath))
    }

    @Test func releasingAnUnknownSessionIsHarmless() async {
        let state = await makeTestAppState(devices: [.test(id: "DEV1")])
        await MainActor.run { state.releaseWebLiveViewer(id: "gone") }
        #expect(await state.webLiveSessions.isEmpty)
    }

    // MARK: quitting and recordings

    @Test func stopAllFreesEverySessionAndDeletesItsSpool() async throws {
        let state = await makeTestAppState(devices: [.test(id: "DEV1", tuners: 2), .test(id: "DEV2", tuners: 2)])
        let a = try session(id: "live-a", device: "DEV1")
        let b = try session(id: "live-b", device: "DEV2", channel: "7.1")
        await MainActor.run { state.webLiveSessions = [a.id: a, b.id: b] }

        await MainActor.run { state.stopAllWebLive(reason: "test") }

        #expect(await state.webLiveSessions.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: a.cachePath))
        #expect(!FileManager.default.fileExists(atPath: b.cachePath))
    }

    @Test func eachSessionCountsAgainstItsOwnDevicesTuners() async throws {
        let state = await makeTestAppState(devices: [.test(id: "DEV1", tuners: 2), .test(id: "DEV2", tuners: 2)])
        let a = try session(id: "live-a", device: "DEV1")
        let b = try session(id: "live-b", device: "DEV1", channel: "7.1")
        await MainActor.run { state.webLiveSessions = [a.id: a, b.id: b] }

        #expect(await state.activeTunerCount(for: "DEV1") == 2)
        #expect(await state.tunersFull(for: "DEV1"))
        #expect(await state.activeTunerCount(for: "DEV2") == 0)

        await MainActor.run { state.stopAllWebLive(reason: "test") }
        #expect(await state.activeTunerCount(for: "DEV1") == 0)
    }

    @Test func turningWebStreamingOffEndsEverySession() async throws {
        let state = await makeTestAppState(devices: [.test(id: "DEV1", tuners: 2)])
        let s = try session()
        await MainActor.run {
            state.config.Web_streaming_enabled = false
            state.webLiveSessions[s.id] = s
            state.reapWebLiveSessions()
        }
        for _ in 0..<40 where await !state.webLiveSessions.isEmpty { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(await state.webLiveSessions.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: s.cachePath))
    }

    @Test func aSessionWhosePullerDiedIsReaped() async throws {
        // No puller was ever started for this id, so isFeedCachePullRunning is false — the same state as a curl that exited.
        let state = await makeTestAppState(devices: [.test(id: "DEV1", tuners: 2)])
        let s = try session()
        await MainActor.run {
            state.config.Web_streaming_enabled = true
            state.webLiveSessions[s.id] = s
            state.reapWebLiveSessions()
        }
        for _ in 0..<40 where await !state.webLiveSessions.isEmpty { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(await state.webLiveSessions.isEmpty)
    }

    // MARK: a scheduled recording wins the tuner

    private func dueShow(device: String) -> Show {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var show = Show.blank(channel: "5.1", device: device)
        show.show_title = "Test Show"
        show.show_active = true
        show.show_next = Date().addingTimeInterval(-5)
        show.show_end = Date().addingTimeInterval(1800)
        show.show_dir = dir.path
        show.show_url = "http://192.168.1.100:5004/auto/v5.1"
        return show
    }

    @Test @MainActor func aRecordingDueOnAFullTunerEndsBrowserLiveTV_andKeepsOtherTunersAlone() async throws {
        let script = try writeMockCurlScript(sleepSeconds: 30)
        defer { try? FileManager.default.removeItem(atPath: script) }
        let manager = RecordingManager(curlExecutablePath: script)
        let show = dueShow(device: "DEV1")
        let state = makeTestAppState(shows: [show], devices: [.test(id: "DEV1", tuners: 1), .test(id: "DEV2", tuners: 1)], recordingManager: manager)
        state.config.Min_disk_free_gb = 0
        let mine = try session(id: "live-mine", device: "DEV1")
        let other = try session(id: "live-other", device: "DEV2", channel: "7.1")
        state.webLiveSessions = [mine.id: mine, other.id: other]

        await state.startRecording(index: 0)

        #expect(state.webLiveSessions[mine.id] == nil)
        #expect(!FileManager.default.fileExists(atPath: mine.cachePath))
        #expect(state.webLiveSessions[other.id] != nil)   // another tuner's viewer is not affected
        manager.stop(showId: show.show_id)
        state.stopAllWebLive(reason: "test")
    }

    @Test @MainActor func aRecordingWithATunerToSpareLeavesBrowserLiveTVRunning() async throws {
        let script = try writeMockCurlScript(sleepSeconds: 30)
        defer { try? FileManager.default.removeItem(atPath: script) }
        let manager = RecordingManager(curlExecutablePath: script)
        let show = dueShow(device: "DEV1")
        let state = makeTestAppState(shows: [show], devices: [.test(id: "DEV1", tuners: 2)], recordingManager: manager)
        state.config.Min_disk_free_gb = 0
        let mine = try session(id: "live-mine", device: "DEV1")
        state.webLiveSessions = [mine.id: mine]

        await state.startRecording(index: 0)

        #expect(state.webLiveSessions[mine.id] != nil)
        manager.stop(showId: show.show_id)
        state.stopAllWebLive(reason: "test")
    }

    // MARK: the air scan steps aside

    @Test @MainActor func theAirScanMustYieldWhenBrowserLiveTVAndTheScanTogetherHoldEveryTuner() async throws {
        let state = makeTestAppState(devices: [.test(id: "DEV1", tuners: 2)])
        state.otaScanDeviceId = "DEV1"
        state.otaScanTask = Task { try? await Task.sleep(nanoseconds: 5_000_000_000) }
        state.otaHeldResources = ["tuner0"]
        defer { state.otaScanTask?.cancel(); state.otaScanTask = nil }

        #expect(!state.otaNeedsYield(for: "DEV1"))   // the scan has a spare tuner

        let live = try session(device: "DEV1")
        state.webLiveSessions[live.id] = live
        #expect(state.otaNeedsYield(for: "DEV1"))    // live TV holds the other one: a new stream would find none free
        state.stopAllWebLive(reason: "test")
    }
}
