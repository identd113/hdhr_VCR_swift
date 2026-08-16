import Testing
import Foundation
@testable import hdhr_VCR

// MARK: - AppState recording-scheduling engine
//
// idleLoop()/startRecording(index:)/stopRecording(index:natural:)/scheduleNextAir(index:) had zero
// test coverage — the code that actually decides when a recording starts, stops, retries after
// failure, and reschedules the next episode. Unblocked 2026-08-15 by giving AppState an injectable
// `recordingManager` (mirroring the pre-existing `configManager` seam), pointed at
// RecordingManager(curlExecutablePath:) — the same mock-curl-script technique
// RecordingManagerTests already uses in isolation. Shared helpers (writeMockCurlScript/waitUntil)
// live in TestFixtures.swift now, used by both files.
//
// Deliberately out of scope: scheduleNextAir's .seriesChannel/.seriesAll branches and
// resolveSeriesAir depend on a freshly-loaded GuideStore (real network fetch when stale) — the
// underlying lookup methods they call already have direct coverage via GuideStoreTests, but their
// own "which lookup tier, in what order" orchestration doesn't. Flagged in TODO.md rather than
// pulling GuideStore network-mocking into this file. .single/.dateTime are both network-free and
// covered below alongside the recording lifecycle itself.
//
// Own RecordingManager instance per test (not shared/static) — each test's mock curl script is
// uniquely named and each RecordingManager is a fresh instance, so no .serialized needed here
// despite touching real subprocesses, same reasoning RecordingManagerTests documents.

@Suite("AppState recording engine")
struct AppStateRecordingEngineTests {

    // Real, disposable directory per test. Show.posixRecordDir falls back to the real user's
    // ~/Movies/hdhr_videos whenever show_dir is empty (or its parent doesn't exist) — every
    // fixture here sets show_dir explicitly to a temp path whose parent (the temp dir itself)
    // already exists, so startRecording's real FileManager.createDirectory call and stopRecording's
    // real file-size check both stay fully sandboxed.
    private func tempRecordDir() -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    private func makeDevice() -> HDHRDevice { .test(id: "FFFFFFFF", tuners: 4) }

    private func makeShow(recordDir: String, next: Date, end: Date) -> Show {
        var s = Show.blank(channel: "5.1", device: "FFFFFFFF")
        s.show_title = "Test Show"
        s.show_active = true
        s.show_next = next
        s.show_end = end
        s.show_dir = recordDir
        s.show_url = "http://192.168.1.100:5004/auto/v5.1"  // mock curl ignores this; only needs to be non-empty
        return s
    }

    // MARK: - startRecording

    @Test @MainActor func startRecording_happyPath_marksRecordingAndLaunchesRealProcess() async throws {
        let scriptPath = try writeMockCurlScript(sleepSeconds: 30)
        defer { try? FileManager.default.removeItem(atPath: scriptPath) }
        let manager = RecordingManager(curlExecutablePath: scriptPath)
        let show = makeShow(recordDir: tempRecordDir(), next: Date().addingTimeInterval(-5), end: Date().addingTimeInterval(1800))
        let state = makeTestAppState(shows: [show], devices: [makeDevice()], recordingManager: manager)
        state.maxDiskPct = 100  // real disk-usage % on the test machine is irrelevant to this test

        await state.startRecording(index: 0)

        #expect(state.shows[0].show_recording == true)
        #expect(!state.shows[0].show_recording_path.isEmpty)
        await waitUntil { manager.isRunning(showId: show.show_id) }
        #expect(manager.isRunning(showId: show.show_id) == true)
        manager.stop(showId: show.show_id)
    }

    @Test @MainActor func startRecording_launchFailure_recordsFailureWithoutMarkingRecording() async throws {
        // Nonexistent executable path — RecordingManager.start's posix_spawn throws.
        let manager = RecordingManager(curlExecutablePath: "/no/such/binary-\(UUID().uuidString)")
        let show = makeShow(recordDir: tempRecordDir(), next: Date().addingTimeInterval(-5), end: Date().addingTimeInterval(1800))
        let state = makeTestAppState(shows: [show], devices: [makeDevice()], recordingManager: manager)
        state.maxDiskPct = 100  // real disk-usage % on the test machine is irrelevant to this test

        await state.startRecording(index: 0)

        #expect(state.shows[0].show_recording == false)
        #expect(state.shows[0].show_fail_count == 1)
        #expect(state.shows[0].show_fail_reason.contains("Launch failed"))
    }

    @Test @MainActor func startRecording_deviceNotInDeviceList_skipsWithoutFailing() async throws {
        let manager = RecordingManager(curlExecutablePath: "/usr/bin/true")
        let show = makeShow(recordDir: tempRecordDir(), next: Date().addingTimeInterval(-5), end: Date().addingTimeInterval(1800))
        // No matching device in `devices` — startRecording's very first guard should skip cleanly,
        // not burn a fail count on a tuner that isn't there.
        let state = makeTestAppState(shows: [show], devices: [], recordingManager: manager)

        await state.startRecording(index: 0)

        #expect(state.shows[0].show_recording == false)
        #expect(state.shows[0].show_fail_count == 0)
    }

    // MARK: - stopRecording

    @Test @MainActor func stopRecording_natural_nonEmptyFile_completesAndReschedules() async throws {
        let scriptPath = try writeMockCurlScript(sleepSeconds: 30)
        defer { try? FileManager.default.removeItem(atPath: scriptPath) }
        let manager = RecordingManager(curlExecutablePath: scriptPath)
        let recordDir = tempRecordDir()
        var show = makeShow(recordDir: recordDir, next: Date().addingTimeInterval(-1800), end: Date().addingTimeInterval(-1))
        let outputPath = (recordDir as NSString).appendingPathComponent("output.ts")
        try Data(repeating: 0, count: 2048).write(to: URL(fileURLWithPath: outputPath))
        show.show_recording = true
        show.show_recording_path = outputPath
        let state = makeTestAppState(shows: [show], devices: [makeDevice()], recordingManager: manager)
        try manager.start(showId: show.show_id, title: show.show_title, url: show.show_url,
                           outputPath: outputPath, durationSeconds: 30, transcode: "none",
                           showEnd: show.show_end!)
        await waitUntil { manager.isRunning(showId: show.show_id) }

        await state.stopRecording(index: 0, natural: true)

        #expect(manager.isRunning(showId: show.show_id) == false)
        guard let updated = state.shows.first(where: { $0.show_id == show.show_id }) else {
            Issue.record("show disappeared"); return
        }
        #expect(updated.show_recording == false)
        // .single show, successful completion — scheduleNextAir's .single branch deactivates it.
        #expect(updated.show_active == false)
    }

    @Test @MainActor func stopRecording_natural_emptyFile_recordsFailureAndSchedulesRetry() async throws {
        let scriptPath = try writeMockCurlScript(sleepSeconds: 30)
        defer { try? FileManager.default.removeItem(atPath: scriptPath) }
        let manager = RecordingManager(curlExecutablePath: scriptPath)
        let recordDir = tempRecordDir()
        var show = makeShow(recordDir: recordDir, next: Date().addingTimeInterval(-1800), end: Date().addingTimeInterval(-1))
        let outputPath = (recordDir as NSString).appendingPathComponent("output.ts")
        // Genuinely empty (0-byte) file at a real path — the FAIL branch only triggers when the
        // path is non-empty AND the file size is 0; a never-created path takes a different,
        // non-failure branch (see AppState.swift:1842's `!path.isEmpty && fileSize == 0`).
        FileManager.default.createFile(atPath: outputPath, contents: Data())
        show.show_recording = true
        show.show_recording_path = outputPath
        let state = makeTestAppState(shows: [show], devices: [makeDevice()], recordingManager: manager)
        try manager.start(showId: show.show_id, title: show.show_title, url: show.show_url,
                           outputPath: outputPath, durationSeconds: 30, transcode: "none",
                           showEnd: show.show_end!)
        await waitUntil { manager.isRunning(showId: show.show_id) }

        await state.stopRecording(index: 0, natural: true)

        guard let updated = state.shows.first(where: { $0.show_id == show.show_id }) else {
            Issue.record("show disappeared"); return
        }
        #expect(updated.show_recording == false)
        #expect(updated.show_fail_count == 1)
        #expect(updated.show_fail_reason.contains("missing or empty"))
        #expect(state.showRetryAfter[show.show_id] != nil)
    }

    @Test @MainActor func stopRecording_manual_pausesWithoutRescheduling() async throws {
        let scriptPath = try writeMockCurlScript(sleepSeconds: 30)
        defer { try? FileManager.default.removeItem(atPath: scriptPath) }
        let manager = RecordingManager(curlExecutablePath: scriptPath)
        let recordDir = tempRecordDir()
        var show = makeShow(recordDir: recordDir, next: Date().addingTimeInterval(-300), end: Date().addingTimeInterval(1800))
        show.show_recording = true
        let state = makeTestAppState(shows: [show], devices: [makeDevice()], recordingManager: manager)
        try manager.start(showId: show.show_id, title: show.show_title, url: show.show_url,
                           outputPath: (recordDir as NSString).appendingPathComponent("output.ts"),
                           durationSeconds: 30, transcode: "none", showEnd: show.show_end!)
        await waitUntil { manager.isRunning(showId: show.show_id) }

        await state.stopRecording(index: 0, natural: false)

        guard let updated = state.shows.first(where: { $0.show_id == show.show_id }) else {
            Issue.record("show disappeared"); return
        }
        #expect(updated.show_recording == false)
        #expect(updated.show_paused == true)
        #expect(updated.show_fail_reason == "Manually stopped")
        // Manual stop returns before scheduleNextAir — a .single show would otherwise be
        // deactivated by it; confirm it's still active (just paused) instead.
        #expect(updated.show_active == true)
    }

    // MARK: - idleLoop end-to-end

    @Test @MainActor func idleLoop_startsShowWhoseWindowIsOpen() async throws {
        let scriptPath = try writeMockCurlScript(sleepSeconds: 30)
        defer { try? FileManager.default.removeItem(atPath: scriptPath) }
        let manager = RecordingManager(curlExecutablePath: scriptPath)
        let show = makeShow(recordDir: tempRecordDir(), next: Date().addingTimeInterval(-5), end: Date().addingTimeInterval(120))
        let state = makeTestAppState(shows: [show], devices: [makeDevice()], recordingManager: manager)
        state.maxDiskPct = 100  // real disk-usage % on the test machine is irrelevant to this test

        await state.idleLoop()

        guard let updated = state.shows.first(where: { $0.show_id == show.show_id }) else {
            Issue.record("show disappeared"); return
        }
        #expect(updated.show_recording == true)
        await waitUntil { manager.isRunning(showId: show.show_id) }
        #expect(manager.isRunning(showId: show.show_id) == true)
        manager.stop(showId: show.show_id)
    }

    @Test @MainActor func idleLoop_stopsAndReschedulesOverdueRecording() async throws {
        let scriptPath = try writeMockCurlScript(sleepSeconds: 30)
        defer { try? FileManager.default.removeItem(atPath: scriptPath) }
        let manager = RecordingManager(curlExecutablePath: scriptPath)
        let recordDir = tempRecordDir()
        var show = makeShow(recordDir: recordDir, next: Date().addingTimeInterval(-1800), end: Date().addingTimeInterval(-1))
        let outputPath = (recordDir as NSString).appendingPathComponent("output.ts")
        try Data(repeating: 0, count: 1024).write(to: URL(fileURLWithPath: outputPath))
        show.show_recording = true
        show.show_recording_path = outputPath
        let state = makeTestAppState(shows: [show], devices: [makeDevice()], recordingManager: manager)
        try manager.start(showId: show.show_id, title: show.show_title, url: show.show_url,
                           outputPath: outputPath, durationSeconds: 30, transcode: "none",
                           showEnd: show.show_end!)
        await waitUntil { manager.isRunning(showId: show.show_id) }

        await state.idleLoop()

        guard let updated = state.shows.first(where: { $0.show_id == show.show_id }) else {
            Issue.record("show disappeared"); return
        }
        #expect(updated.show_recording == false)
        #expect(manager.isRunning(showId: show.show_id) == false)
        #expect(updated.show_active == false)  // .single, successful completion
    }

    // MARK: - scheduleNextAir (.single / .dateTime — network-free branches only)

    @Test @MainActor func scheduleNextAir_single_deactivatesShow() async {
        let show = makeShow(recordDir: tempRecordDir(), next: Date(), end: Date().addingTimeInterval(1800))
        let state = makeTestAppState(shows: [show])

        await state.scheduleNextAir(index: 0)

        #expect(state.shows[0].show_active == false)
    }

    @Test @MainActor func scheduleNextAir_dateTime_advancesToNextAirDay() async throws {
        var show = makeShow(recordDir: tempRecordDir(), next: Date(), end: Date().addingTimeInterval(1800))
        show.show_is_series = true
        show.show_use_seriesid = false
        show.show_use_seriesid_all = false
        show.show_air_date = ["monday", "wednesday", "friday"]
        show.show_time = 20.0
        show.show_length = 60
        #expect(show.state == .dateTime)
        let state = makeTestAppState(shows: [show])

        await state.scheduleNextAir(index: 0)

        let updated = state.shows[0]
        #expect(updated.show_paused == false)
        let next = try #require(updated.show_next)
        let weekday = Calendar.current.component(.weekday, from: next)  // 1=Sun...7=Sat
        #expect([2, 4, 6].contains(weekday), "expected Mon/Wed/Fri, got weekday \(weekday)")
        let hour = Calendar.current.component(.hour, from: next)
        #expect(hour == 20)
        #expect(next > Date())
        #expect(updated.show_end == next.addingTimeInterval(Double(show.show_length) * 60))
    }

    @Test @MainActor func scheduleNextAir_dateTime_noAirDays_pausesShow() async {
        var show = makeShow(recordDir: tempRecordDir(), next: Date(), end: Date().addingTimeInterval(1800))
        show.show_is_series = true
        show.show_use_seriesid = false
        show.show_use_seriesid_all = false
        show.show_air_date = []  // no air days configured
        #expect(show.state == .dateTime)
        let state = makeTestAppState(shows: [show])

        await state.scheduleNextAir(index: 0)

        #expect(state.shows[0].show_paused == true)
        #expect(state.shows[0].show_fail_reason == "No air days configured")
    }
}
