import Testing
import Foundation
@testable import hdhr_VCR

// Opt-in, real end-to-end tests for the virtual-tuner relay's stream endpoint — the two the user
// asked for directly (enable the relay, "start a recording," connect to the advertised stream URL,
// confirm real bytes flow; same with a real transcode profile requested, confirming the bytes that
// come back are genuinely H.264, not the original MPEG-2), plus a third the user's own follow-up
// suggestion led to: request a transcode of a channel that's *already* broadcasting H.264 per its
// own lineup entry, and confirm the relay skips the re-encode entirely (byte-identical to the raw
// capture) instead of wastefully re-encoding an already-modern source.
//
// Deliberately opt-in (RUN_VIRTUAL_TUNER_LIVE_TESTS=1), same convention as WindowNavigationTests.swift's
// RUN_WINDOW_NAV_TESTS and AppStateDiskIOLatencyTests.swift's RUN_DISK_IO_TESTS: this suite binds a
// REAL WebServer to a real TCP port, does a REAL UDP bind for VirtualTunerService (port 65001 —
// shared via SO_REUSEPORT, so it coexists with any other running instance, including a deployed
// build of this same app), briefly tunes a REAL HDHomeRun device on the LAN to capture a genuine
// sample (a synthetic byte pattern can't be decoded into anything, so it couldn't prove a real
// codec change happened — the user's own suggestion over synthesizing one with ffmpeg), and for the
// transcode tests, drives a REAL headless libvlc encode — none of that belongs in the default
// `swift test` run every other file in this project keeps clean of live sockets/hardware.
//
// Tool/hardware requirements:
//   - A real (non-virtual-relay) HDHomeRun device reachable via normal discovery — briefly occupies
//     one of its tuners (~7s per test) to capture the sample. No mock/synthetic fallback: without
//     one, every test reports clearly and returns rather than fabricating fake input.
//   - VLC.app installed, for the transcode tests (same requirement the app itself already has).
//   - `mediainfo` on PATH (test-only tool, never shipped in the app) — introspects the captured and
//     transcoded files' actual video codec (`brew install media-info`; already present via that
//     formula's `mediainfo` binary on machines that have it).
//
//   RUN_VIRTUAL_TUNER_LIVE_TESTS=1 swift test --filter VirtualTunerLiveStreamTests
//
// Runs on a dedicated test port (19801), never 1980, so this never collides with a separately
// running deployed instance of the real app.
private func virtualTunerLiveTestsOptedIn() -> Bool {
    ProcessInfo.processInfo.environment["RUN_VIRTUAL_TUNER_LIVE_TESTS"] == "1"
}

private func findExecutable(_ name: String) -> String? {
    for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] {
        let path = dir + "/" + name
        if FileManager.default.isExecutableFile(atPath: path) { return path }
    }
    return nil
}

private enum LiveTestError: Error { case noRealDeviceFound, noChannelsInLineup, captureFailed, badResponse, timedOut }

@Suite("Virtual tuner relay — live stream + transcode (opt-in)", .serialized)
struct VirtualTunerLiveStreamTests {
    private static let testPort = 19801
    private static let captureSeconds = 6

    // Finds a real (non-relay) HDHomeRun device via normal discovery, fetches its lineup, and
    // curls a few real seconds of its first channel into a temp file — genuine, decodable MPEG-2
    // broadcast content, not a synthesized test pattern. `?duration=` (RecordingManager.swift's own
    // convention against a real tuner) makes the device itself close the stream, so this doesn't
    // depend on curl's own timeout to let go of the tuner.
    private func captureRealChannelSample(
        preferring: (LineupEntry) -> Bool = { _ in true }
    ) async throws -> (path: String, entry: LineupEntry) {
        let hdhrManager = HDHRManager()
        let devices = (try? await hdhrManager.discoverDevices()) ?? []
        guard let device = devices.first(where: { !$0.isVirtualRelay }) else {
            throw LiveTestError.noRealDeviceFound
        }
        let lineup = try await hdhrManager.fetchLineup(for: device)
        // `preferring` lets a caller ask for e.g. a channel the lineup already reports as H264 —
        // falls back to the first channel with a URL at all if nothing matches the preference, so
        // this doesn't hard-fail on a lineup that happens not to have one right now.
        guard let channel = (lineup.first(where: { preferring($0) && $0.URL != nil }) ?? lineup.first(where: { $0.URL != nil })),
              let baseURL = channel.URL
        else { throw LiveTestError.noChannelsInLineup }
        let path = NSTemporaryDirectory() + "hdhrVCRplus-vtunertest-\(UUID().uuidString).ts"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        proc.arguments = [
            "--max-time", "\(Self.captureSeconds + 5)",
            "-o", path,
            "\(baseURL)?duration=\(Self.captureSeconds)",
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError  = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        guard FileManager.default.fileExists(atPath: path),
              let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int, size > 0
        else { throw LiveTestError.captureFailed }
        return (path, channel)
    }

    // Reads up to `maxBytes` from `url` (or until `timeout`), then stops — the relay's stream is
    // intentionally open-ended (no Content-Length), so a plain URLSession.data(for:) would hang
    // waiting for an end that only comes when the "recording" itself stops. Racing against a
    // timeout task and cancelling the loser also cooperatively cancels the underlying
    // URLSessionTask (AsyncBytes honors Task cancellation), so no connection lingers into the next
    // test.
    private func collectBytes(from url: URL, maxBytes: Int, timeout: TimeInterval) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                let (bytes, response) = try await URLSession.shared.bytes(for: URLRequest(url: url))
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw LiveTestError.badResponse
                }
                var collected = Data()
                for try await byte in bytes {
                    collected.append(byte)
                    if collected.count >= maxBytes { break }
                }
                return collected
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw LiveTestError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    // Shared setup: a real AppState + real WebServer bound to Self.testPort, one show marked as
    // recording against `samplePath`, the relay enabled and actually activated
    // (updateVirtualTunerPresence — a real UDP bind, same as a genuine recording start). Caller is
    // responsible for state.webServer.stop() when done.
    @MainActor
    private func makeLiveRelayState(samplePath: String, entry: LineupEntry) async throws -> (state: AppState, device: HDHRDevice, showId: String) {
        let device = HDHRDevice.test(id: "AAAAAAAA")
        var show = Show.testRecording(title: "Live Relay Test", channel: entry.GuideNumber)
        show.hdhr_record = device.DeviceID
        show.show_recording_path = samplePath
        // Seeds the SAME VideoCodec the real device's own lineup reported for this channel, under
        // this test's fake device ID — handleVirtualTunerStream's fast-path check
        // (WebServer.sourceIsAlreadyModernCodec) looks this up via state.lineups[show.hdhr_record],
        // so this is what actually exercises the lineup path end to end rather than only ever
        // falling through to the on-disk PAT/PMT probe.
        let state = makeTestAppState(shows: [show], devices: [device],
                                      lineups: [device.DeviceID: [entry]])
        state.config.Virtual_tuner_relay_enabled = true
        // Keep AppState's own port config in lockstep with the port actually started below —
        // updateVirtualTunerPresence()'s ensureWebServerRunning() call reads config.Web_server_port
        // (not whatever port a caller happened to start the listener on), and — see webServerRunning
        // just below — would otherwise think the server isn't running yet and restart it on the
        // *default* port 1980 instead, tearing down this test's own listener on Self.testPort out
        // from under it (and likely failing outright, since 1980 is where a separately-running
        // deployed instance of this same app already listens).
        state.config.Web_server_port = Self.testPort

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            state.webServer.start(port: Self.testPort, appState: state) { _ in cont.resume() }
        }
        // Calling webServer.start(...) directly above (rather than through AppState.setupWebServer()/
        // ensureWebServerRunning()) never ran applyWebServerState(_:), so state.webServerRunning is
        // still its default false — set it explicitly so updateVirtualTunerPresence()'s own
        // ensureWebServerRunning() call correctly sees the server as already running and skips its
        // own redundant (and, per the comment above, actively harmful) restart.
        state.webServerRunning = true
        state.updateVirtualTunerPresence()
        return (state, device, show.show_id)
    }

    @MainActor
    @Test func relayServesRawRecordingBytesToARealConnection() async throws {
        guard virtualTunerLiveTestsOptedIn() else { return }
        let (samplePath, entry): (String, LineupEntry)
        do {
            (samplePath, entry) = try await captureRealChannelSample()
        } catch {
            Issue.record("RUN_VIRTUAL_TUNER_LIVE_TESTS=1 but couldn't capture a real channel sample (\(error)) — need a real, reachable HDHomeRun device on the LAN")
            return
        }
        defer { try? FileManager.default.removeItem(atPath: samplePath) }
        let sampleBytes = try Data(contentsOf: URL(fileURLWithPath: samplePath))

        let (state, device, showId) = try await makeLiveRelayState(samplePath: samplePath, entry: entry)
        defer { state.webServer.stop() }

        let deviceId = await MainActor.run { state.activeVirtualTunerDeviceID }
        #expect(deviceId != nil)   // relay actually activated

        let streamURL = URL(string: "http://127.0.0.1:\(Self.testPort)/auto/v\(entry.GuideNumber)?dev=\(device.DeviceID)")!
        let received = try await collectBytes(from: streamURL, maxBytes: 4096, timeout: 5)
        #expect(!received.isEmpty)
        // Untranscoded path is a byte-for-byte passthrough of the on-disk file — the whole point of
        // Phase 1's design (docs/VirtualTunerService.md).
        #expect(received == sampleBytes.prefix(received.count))

        _ = showId
    }

    @MainActor
    @Test func relayTranscodesToH264WhenAProfileIsRequested() async throws {
        guard virtualTunerLiveTestsOptedIn() else { return }
        guard let mediainfoPath = findExecutable("mediainfo") else {
            Issue.record("RUN_VIRTUAL_TUNER_LIVE_TESTS=1 but mediainfo not found on PATH (brew install media-info) — reporting, not silently skipping")
            return
        }
        guard await MainActor.run(body: { VLCBridge.shared.isAvailable }) else {
            Issue.record("RUN_VIRTUAL_TUNER_LIVE_TESTS=1 but VLC.app isn't installed/loadable — transcode needs it, same as the app itself does")
            return
        }
        let (samplePath, entry): (String, LineupEntry)
        do {
            // Deliberately requests an MPEG2-reporting channel — this test proves a real re-encode
            // happens; relaySkipsTranscodeWhenSourceIsAlreadyModernPerLineup below covers the
            // opposite (already-H264) case.
            (samplePath, entry) = try await captureRealChannelSample(preferring: { $0.VideoCodec == "MPEG2" })
        } catch {
            Issue.record("RUN_VIRTUAL_TUNER_LIVE_TESTS=1 but couldn't capture a real channel sample (\(error)) — need a real, reachable HDHomeRun device on the LAN")
            return
        }
        defer { try? FileManager.default.removeItem(atPath: samplePath) }

        // Sanity-check the capture itself is what we think it is (real MPEG-2) — if this ever
        // isn't true, the "transcoded to h264" assertion below would be meaningless (it might just
        // mean the source was never MPEG-2 to begin with).
        let sourceFormat = try probeVideoFormat(mediainfoPath: mediainfoPath, path: samplePath)
        #expect(sourceFormat?.contains("MPEG Video") == true)

        let (state, device, showId) = try await makeLiveRelayState(samplePath: samplePath, entry: entry)
        defer {
            state.webServer.stop()
            Task { @MainActor in VLCBridge.shared.stopAllTranscodeSessions(showId: showId) }
        }

        let streamURL = URL(string: "http://127.0.0.1:\(Self.testPort)/auto/v\(entry.GuideNumber)?dev=\(device.DeviceID)&transcode=mobile")!
        // Generous timeout: a real headless libvlc transcode needs real wall-clock time to produce
        // enough encoded bytes to be worth probing, on top of the relay's own ~0.6s sout-httpd
        // startup grace period (WebServer.beginTranscodeRelay's own comment on why that exists).
        let received = try await collectBytes(from: streamURL, maxBytes: 64 * 1024, timeout: 20)
        #expect(!received.isEmpty)

        let outPath = NSTemporaryDirectory() + "hdhrVCRplus-vtunertest-out-\(UUID().uuidString).ts"
        try received.write(to: URL(fileURLWithPath: outPath))
        defer { try? FileManager.default.removeItem(atPath: outPath) }

        let outFormat = try probeVideoFormat(mediainfoPath: mediainfoPath, path: outPath)
        #expect(outFormat?.contains("AVC") == true)   // mediainfo's name for H.264
        // Regression guard for an explicit user request: whatever transcode profile is requested,
        // the output must keep the SOURCE's own frame rate and dimensions, never resize/reframe it
        // (VLCBridge.transcodeBitrateKbps's own doc comment — bitrate is the only thing that varies
        // by profile; no scale=/width=/height=/fps= is ever passed to the sout chain).
        let sourceDims = try probeVideoDimensions(mediainfoPath: mediainfoPath, path: samplePath)
        let outDims = try probeVideoDimensions(mediainfoPath: mediainfoPath, path: outPath)
        #expect(outDims.width == sourceDims.width)
        #expect(outDims.height == sourceDims.height)
        if let sFPS = sourceDims.frameRate.flatMap(Double.init), let oFPS = outDims.frameRate.flatMap(Double.init) {
            #expect(abs(sFPS - oFPS) < 0.1)
        } else {
            Issue.record("Could not parse a numeric frame rate from mediainfo for source (\(sourceDims.frameRate ?? "nil")) and/or output (\(outDims.frameRate ?? "nil")) — width/height were still compared above")
        }
        // Regression guard for a real bug caught live the first time this test actually ran
        // (2026-09-02): a real over-the-air 5.1 source silently produced a video-only transcode
        // with no audio track at all — the audio encoder (mpga at the time; acodec=a52/AC-3 as of
        // 2026-09-04, same constraint) only supports up to 2 channels and dropped the audio
        // entirely rather than erroring loudly. Fixed by adding an explicit `channels=2` downmix to
        // the sout chain (VLCBridge.startTranscodeSession's own comment on why). Asserting a
        // 2-channel audio track survived the transcode catches a regression of that same silent
        // failure, not just "some bytes came back."
        // Not an exact-match assertion: mediainfo's --Inform concatenates one value per matching
        // track with no separator (a transcode can legitimately produce more than one audio track),
        // so "22" (two 2-channel tracks) is a real, valid pass, not "22 channels". Checking for the
        // absence of "6" (5.1) is the actual regression guard; non-empty proves a track survived at all.
        let outChannels = try probeAudioChannelCount(mediainfoPath: mediainfoPath, path: outPath)
        #expect(!(outChannels ?? "").isEmpty)
        #expect(outChannels?.contains("6") != true)
    }

    // The "Already-modern-codec skip" from the user's own suggestion: some real channels already
    // report VideoCodec "H264" in the lineup (confirmed live 2026-09-02 — 15 of 112 on the device
    // this was verified against, an entire sub-multiplex). Requesting a transcode of one of those
    // must relay it as-is, not actually re-encode — proven here by byte-identity with the raw
    // capture (a real re-encode, even to the same codec, would never reproduce the exact same
    // bytes x264 didn't produce), which is a stronger proof than "the output still says AVC" would
    // be on its own.
    @MainActor
    @Test func relaySkipsTranscodeWhenSourceIsAlreadyModernPerLineup() async throws {
        guard virtualTunerLiveTestsOptedIn() else { return }
        guard await MainActor.run(body: { VLCBridge.shared.isAvailable }) else {
            Issue.record("RUN_VIRTUAL_TUNER_LIVE_TESTS=1 but VLC.app isn't installed/loadable")
            return
        }
        let (samplePath, entry): (String, LineupEntry)
        do {
            (samplePath, entry) = try await captureRealChannelSample(preferring: { $0.VideoCodec == "H264" })
        } catch {
            Issue.record("RUN_VIRTUAL_TUNER_LIVE_TESTS=1 but couldn't capture a real channel sample (\(error)) — need a real, reachable HDHomeRun device on the LAN")
            return
        }
        defer { try? FileManager.default.removeItem(atPath: samplePath) }
        guard entry.VideoCodec == "H264" else {
            Issue.record("No channel in this device's current lineup reports VideoCodec H264 right now (lineups can change) — nothing to test the skip path against; not a failure of the app itself")
            return
        }
        let sampleBytes = try Data(contentsOf: URL(fileURLWithPath: samplePath))

        let (state, device, showId) = try await makeLiveRelayState(samplePath: samplePath, entry: entry)
        defer {
            state.webServer.stop()
            Task { @MainActor in VLCBridge.shared.stopAllTranscodeSessions(showId: showId) }
        }

        let streamURL = URL(string: "http://127.0.0.1:\(Self.testPort)/auto/v\(entry.GuideNumber)?dev=\(device.DeviceID)&transcode=mobile")!
        let received = try await collectBytes(from: streamURL, maxBytes: 4096, timeout: 5)
        #expect(!received.isEmpty)
        #expect(received == sampleBytes.prefix(received.count))
    }

    // Returns mediainfo's reported Format for the first video track in `path` (e.g. "MPEG Video"
    // for MPEG-2, "AVC" for H.264).
    private func probeVideoFormat(mediainfoPath: String, path: String) throws -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: mediainfoPath)
        proc.arguments = ["--Inform=Video;%Format%", path]
        return try runMediainfo(proc)
    }

    // Returns mediainfo's reported width/height/frame rate for the first video track in `path` —
    // used to prove a transcode kept the source's own dimensions/fps rather than resizing/reframing
    // it (see relayTranscodesToH264WhenAProfileIsRequested's own comment).
    private func probeVideoDimensions(mediainfoPath: String, path: String) throws -> (width: String?, height: String?, frameRate: String?) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: mediainfoPath)
        proc.arguments = ["--Inform=Video;%Width%,%Height%,%FrameRate%", path]
        guard let output = try runMediainfo(proc) else { return (nil, nil, nil) }
        let parts = output.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        return (parts.count > 0 && !parts[0].isEmpty ? parts[0] : nil,
                parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil,
                parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil)
    }

    // Returns mediainfo's reported channel count for the first audio track in `path` (nil if the
    // container has no audio track at all — e.g. the exact silent-failure mode this exists to catch).
    private func probeAudioChannelCount(mediainfoPath: String, path: String) throws -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: mediainfoPath)
        proc.arguments = ["--Inform=Audio;%Channel(s)%", path]
        return try runMediainfo(proc)
    }

    private func runMediainfo(_ proc: Process) throws -> String? {
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = FileHandle.nullDevice
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
