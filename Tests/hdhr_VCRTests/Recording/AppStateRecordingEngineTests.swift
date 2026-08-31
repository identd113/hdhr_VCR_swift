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
        state.maxDiskPct = 100
        state.config.Min_disk_free_gb = 0  // real free space on the test machine is irrelevant to this test  // real disk-usage % on the test machine is irrelevant to this test

        await state.startRecording(index: 0)

        #expect(state.shows[0].show_recording == true)
        #expect(!state.shows[0].show_recording_path.isEmpty)
        await waitUntil { manager.isRunning(showId: show.show_id) }
        #expect(manager.isRunning(showId: show.show_id) == true)
        manager.stop(showId: show.show_id)
    }

    // Device support is gated on HDHRDevice.supportsTranscode (ModelNumber's "HDTC" prefix) —
    // startRecording must never hand curl a transcode profile the tuner will just reject with
    // X-HDHomeRun-Error 802 "Unknown Transcode Profile" (docs/HDHRFindings.md). makeDevice() (no
    // modelNumber) is the conservative "unsupported" case by construction; a second device with an
    // "HDTC"-prefixed ModelNumber covers the positive case in the same test so a future change
    // can't satisfy one assertion by breaking the other (e.g. forcing "none" unconditionally).
    @Test @MainActor func startRecording_unsupportedDevice_forcesTranscodeNone_supportedDeviceKeepsChoice() async throws {
        let argsLogUnsupported = NSTemporaryDirectory() + "hdhrVCRplus-test-argslog-\(UUID().uuidString).txt"
        let argsLogSupported   = NSTemporaryDirectory() + "hdhrVCRplus-test-argslog-\(UUID().uuidString).txt"
        defer {
            try? FileManager.default.removeItem(atPath: argsLogUnsupported)
            try? FileManager.default.removeItem(atPath: argsLogSupported)
        }
        let scriptUnsupported = try writeMockCurlScript(sleepSeconds: 30, argsLogPath: argsLogUnsupported)
        let scriptSupported   = try writeMockCurlScript(sleepSeconds: 30, argsLogPath: argsLogSupported)
        defer {
            try? FileManager.default.removeItem(atPath: scriptUnsupported)
            try? FileManager.default.removeItem(atPath: scriptSupported)
        }

        let unsupportedDevice = HDHRDevice.test(id: "FFFFFFFF", tuners: 4)  // no ModelNumber
        let supportedDevice   = HDHRDevice.test(id: "AAAAAAAA", tuners: 4, modelNumber: "HDTC-2US")

        var showUnsupported = makeShow(recordDir: tempRecordDir(), next: Date().addingTimeInterval(-5), end: Date().addingTimeInterval(1800))
        showUnsupported.show_transcode = "heavy"
        // show_id is randomized by Show.blank() (called via makeShow) — no explicit uniquing needed
        // to keep this show's --dump-header temp path from colliding with showUnsupported's.
        var showSupported = makeShow(recordDir: tempRecordDir(), next: Date().addingTimeInterval(-5), end: Date().addingTimeInterval(1800))
        showSupported.hdhr_record = "AAAAAAAA"
        showSupported.show_transcode = "heavy"

        let managerUnsupported = RecordingManager(curlExecutablePath: scriptUnsupported)
        let stateUnsupported = makeTestAppState(shows: [showUnsupported], devices: [unsupportedDevice], recordingManager: managerUnsupported)
        stateUnsupported.maxDiskPct = 100
        stateUnsupported.config.Min_disk_free_gb = 0
        await stateUnsupported.startRecording(index: 0)
        // Generous timeout — under a loaded test run (many suites spawning real subprocesses in
        // parallel), the mock curl script can take longer than waitUntil's 3s default just to get
        // scheduled and write its args log.
        await waitUntil(timeout: 8) { FileManager.default.fileExists(atPath: argsLogUnsupported) }
        let argsUnsupported = (try? String(contentsOfFile: argsLogUnsupported, encoding: .utf8)) ?? ""
        #expect(argsUnsupported.contains("transcode=none"))
        #expect(!argsUnsupported.contains("transcode=heavy"))
        managerUnsupported.stop(showId: showUnsupported.show_id)

        let managerSupported = RecordingManager(curlExecutablePath: scriptSupported)
        let stateSupported = makeTestAppState(shows: [showSupported], devices: [supportedDevice], recordingManager: managerSupported)
        stateSupported.maxDiskPct = 100
        stateSupported.config.Min_disk_free_gb = 0
        await stateSupported.startRecording(index: 0)
        await waitUntil(timeout: 8) { FileManager.default.fileExists(atPath: argsLogSupported) }
        let argsSupported = (try? String(contentsOfFile: argsLogSupported, encoding: .utf8)) ?? ""
        #expect(argsSupported.contains("transcode=heavy"))
        managerSupported.stop(showId: showSupported.show_id)
    }

    @Test @MainActor func startRecording_metadataSidecarEnabled_writesNfoFileAlongsideRecording() async throws {
        let scriptPath = try writeMockCurlScript(sleepSeconds: 30)
        defer { try? FileManager.default.removeItem(atPath: scriptPath) }
        let manager = RecordingManager(curlExecutablePath: scriptPath)
        let show = makeShow(recordDir: tempRecordDir(), next: Date().addingTimeInterval(-5), end: Date().addingTimeInterval(1800))
        let state = makeTestAppState(shows: [show], devices: [makeDevice()], recordingManager: manager)
        state.maxDiskPct = 100
        state.config.Min_disk_free_gb = 0
        state.config.Write_metadata_sidecar = true

        await state.startRecording(index: 0)

        // No GuideStore data loaded in this fixture, so writeMetadataSidecar's entry is nil —
        // exercises the graceful-degradation path (title-only .nfo, no season/episode/synopsis).
        let nfoPath = (state.shows[0].show_recording_path as NSString).deletingPathExtension + ".nfo"
        #expect(FileManager.default.fileExists(atPath: nfoPath))
        let xml = try String(contentsOfFile: nfoPath, encoding: .utf8)
        #expect(xml.contains("<showtitle>Test Show</showtitle>"))
        manager.stop(showId: show.show_id)
    }

    @Test @MainActor func startRecording_metadataSidecarDisabled_writesNoNfoFile() async throws {
        let scriptPath = try writeMockCurlScript(sleepSeconds: 30)
        defer { try? FileManager.default.removeItem(atPath: scriptPath) }
        let manager = RecordingManager(curlExecutablePath: scriptPath)
        let show = makeShow(recordDir: tempRecordDir(), next: Date().addingTimeInterval(-5), end: Date().addingTimeInterval(1800))
        let state = makeTestAppState(shows: [show], devices: [makeDevice()], recordingManager: manager)
        state.maxDiskPct = 100
        state.config.Min_disk_free_gb = 0
        state.config.Write_metadata_sidecar = false  // default

        await state.startRecording(index: 0)

        let nfoPath = (state.shows[0].show_recording_path as NSString).deletingPathExtension + ".nfo"
        #expect(!FileManager.default.fileExists(atPath: nfoPath))
        manager.stop(showId: show.show_id)
    }

    @Test @MainActor func startRecording_launchFailure_recordsFailureWithoutMarkingRecording() async throws {
        // Nonexistent executable path — RecordingManager.start's posix_spawn throws.
        let manager = RecordingManager(curlExecutablePath: "/no/such/binary-\(UUID().uuidString)")
        let show = makeShow(recordDir: tempRecordDir(), next: Date().addingTimeInterval(-5), end: Date().addingTimeInterval(1800))
        let state = makeTestAppState(shows: [show], devices: [makeDevice()], recordingManager: manager)
        state.maxDiskPct = 100
        state.config.Min_disk_free_gb = 0  // real free space on the test machine is irrelevant to this test  // real disk-usage % on the test machine is irrelevant to this test

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

    // MARK: - Bonus Time

    // Sports_padding_enabled && show.show_bonus_time extends show_end past the guide's own end —
    // had zero coverage despite being a named CLAUDE.md invariant (2026-08-16 audit/TODO.md). This
    // pins startRecording's actual arithmetic: show_end is persisted with the padding applied
    // *before* the process is even spawned (AppState.swift, "Always persist endDate" comment), so
    // /usr/bin/true is enough here — no need for a real mock-curl recording to observe it.
    @Test @MainActor func startRecording_bonusTimeEnabled_extendsShowEndByPaddingMinutes() async throws {
        let manager = RecordingManager(curlExecutablePath: "/usr/bin/true")
        let guideEnd = Date().addingTimeInterval(1800)
        var show = makeShow(recordDir: tempRecordDir(), next: Date().addingTimeInterval(-5), end: guideEnd)
        show.show_bonus_time = true
        let state = makeTestAppState(shows: [show], devices: [makeDevice()], recordingManager: manager)
        state.maxDiskPct = 100
        state.config.Min_disk_free_gb = 0  // real free space on the test machine is irrelevant to this test
        state.config.Sports_padding_enabled = true
        state.config.Sports_padding_minutes = 30

        await state.startRecording(index: 0)

        let expectedEnd = guideEnd.addingTimeInterval(30 * 60)
        #expect(abs(state.shows[0].show_end!.timeIntervalSince(expectedEnd)) < 1)
    }

    @Test @MainActor func startRecording_bonusTimeShowButPaddingDisabled_leavesShowEndUnchanged() async throws {
        let manager = RecordingManager(curlExecutablePath: "/usr/bin/true")
        let guideEnd = Date().addingTimeInterval(1800)
        var show = makeShow(recordDir: tempRecordDir(), next: Date().addingTimeInterval(-5), end: guideEnd)
        show.show_bonus_time = true
        let state = makeTestAppState(shows: [show], devices: [makeDevice()], recordingManager: manager)
        state.maxDiskPct = 100
        state.config.Min_disk_free_gb = 0  // real free space on the test machine is irrelevant to this test
        state.config.Sports_padding_enabled = false  // master toggle off — per-show flag alone isn't enough
        state.config.Sports_padding_minutes = 30

        await state.startRecording(index: 0)

        #expect(abs(state.shows[0].show_end!.timeIntervalSince(guideEnd)) < 1)
    }

    @Test @MainActor func startRecording_bonusTimeDisabledOnShow_leavesShowEndUnchangedEvenWithPaddingEnabled() async throws {
        let manager = RecordingManager(curlExecutablePath: "/usr/bin/true")
        let guideEnd = Date().addingTimeInterval(1800)
        var show = makeShow(recordDir: tempRecordDir(), next: Date().addingTimeInterval(-5), end: guideEnd)
        show.show_bonus_time = false  // this show opted out — a global padding toggle can't override that
        let state = makeTestAppState(shows: [show], devices: [makeDevice()], recordingManager: manager)
        state.maxDiskPct = 100
        state.config.Min_disk_free_gb = 0  // real free space on the test machine is irrelevant to this test
        state.config.Sports_padding_enabled = true
        state.config.Sports_padding_minutes = 30

        await state.startRecording(index: 0)

        #expect(abs(state.shows[0].show_end!.timeIntervalSince(guideEnd)) < 1)
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
        #expect(state.showRuntime[show.show_id]?.retryAfter != nil)
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
        state.maxDiskPct = 100
        state.config.Min_disk_free_gb = 0  // real free space on the test machine is irrelevant to this test  // real disk-usage % on the test machine is irrelevant to this test

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

    // MARK: - idleLoop auto-pause/auto-resume on missing tuner

    @Test @MainActor func idleLoop_autoPausesActiveShowOnUndetectedTuner() async {
        var show = Show.blank(channel: "9.1", device: "GHOST0001")
        show.show_title = "Ghost Show"
        show.show_active = true
        show.show_next = Date().addingTimeInterval(3600)
        // A real, present device so the `!devices.isEmpty` guard runs the auto-pause check at all —
        // GHOST0001 (the show's own tuner) is deliberately absent from this list.
        let state = makeTestAppState(shows: [show], devices: [makeDevice()])

        await state.idleLoop()

        guard let updated = state.shows.first(where: { $0.show_id == show.show_id }) else {
            Issue.record("show disappeared"); return
        }
        #expect(updated.show_paused == true)
        #expect(updated.show_fail_reason == "Tuner not detected")
    }

    @Test @MainActor func idleLoop_autoResumesShowOnceItsTunerIsDetectedAgain() async {
        var show = Show.blank(channel: "9.1", device: "FFFFFFFF")
        show.show_title = "Returning Show"
        show.show_active = true
        show.show_paused = true
        show.show_fail_reason = "Tuner not detected"   // the exact auto-pause marker
        // Stale cooldown markers left over from before the outage — must be cleared on resume
        // (ISSUES.md's 2026-08-19 entry) so they can't wrongly suppress the pre-notification for
        // whatever airing is actually next once this show is active again.
        show.notify_upnext_time = Date().addingTimeInterval(3600)
        show.notify_recording_time = Date().addingTimeInterval(3600)
        // The show's own tuner (FFFFFFFF) is now present — should be auto-resumed this tick.
        let state = makeTestAppState(shows: [show], devices: [makeDevice()])

        await state.idleLoop()

        guard let updated = state.shows.first(where: { $0.show_id == show.show_id }) else {
            Issue.record("show disappeared"); return
        }
        #expect(updated.show_paused == false)
        #expect(updated.show_fail_reason.isEmpty)
        #expect(updated.notify_upnext_time == nil)
        #expect(updated.notify_recording_time == nil)
    }

    @Test @MainActor func resumeShow_rearmsNotificationCooldowns() {
        var show = Show.blank(channel: "9.1", device: "FFFFFFFF")
        show.show_title = "Manually Resumed Show"
        show.show_active = true
        show.show_paused = true
        show.show_fail_reason = "Manually paused"
        show.notify_upnext_time = Date().addingTimeInterval(3600)
        show.notify_recording_time = Date().addingTimeInterval(3600)
        let state = makeTestAppState(shows: [show], devices: [makeDevice()])

        state.resumeShow(show)

        guard let updated = state.shows.first(where: { $0.show_id == show.show_id }) else {
            Issue.record("show disappeared"); return
        }
        #expect(updated.show_paused == false)
        #expect(updated.notify_upnext_time == nil)
        #expect(updated.notify_recording_time == nil)
    }

    // Regression: reactivatePausedShows (Settings -> Maintenance's bulk action) predates
    // applyResume and doesn't route through it, so it needed the same notify-cooldown fix applied
    // separately — caught by a 2026-08-19 review sweep after the original resumeShow/idleLoop fix.
    @Test @MainActor func reactivatePausedShows_rearmsNotificationCooldowns() {
        var show = Show.blank(channel: "9.1", device: "FFFFFFFF")
        show.show_title = "Bulk Reactivated Show"
        show.show_active = true
        show.show_paused = true
        show.show_fail_reason = "Manually paused"
        show.notify_upnext_time = Date().addingTimeInterval(3600)
        show.notify_recording_time = Date().addingTimeInterval(3600)
        let state = makeTestAppState(shows: [show], devices: [makeDevice()])

        state.reactivatePausedShows()

        guard let updated = state.shows.first(where: { $0.show_id == show.show_id }) else {
            Issue.record("show disappeared"); return
        }
        #expect(updated.show_paused == false)
        #expect(updated.notify_upnext_time == nil)
        #expect(updated.notify_recording_time == nil)
    }

    // Exercises idleLoop's separate, older "paused window expired" generic auto-resume (Pass 2,
    // the endDate <= now branch) — distinct from the tuner-detection path above. A .single show
    // (no series flags) whose show_end is already in the past drives this branch; scheduleNextAir
    // then immediately deactivates it (the existing, unrelated .single "DONE" behavior), but the
    // notify cooldowns must already be cleared before that runs.
    @Test @MainActor func idleLoop_genericWindowExpiredAutoResume_rearmsNotificationCooldowns() async {
        var show = Show.blank(channel: "9.1", device: "FFFFFFFF")
        show.show_title = "Window Expired Show"
        show.show_active = true
        show.show_paused = true
        show.show_fail_reason = "Manually paused"
        show.show_next = Date().addingTimeInterval(-1800)
        show.show_end  = Date().addingTimeInterval(-60)   // already in the past — triggers endDate <= now
        show.notify_upnext_time = Date().addingTimeInterval(3600)
        show.notify_recording_time = Date().addingTimeInterval(3600)
        let state = makeTestAppState(shows: [show], devices: [makeDevice()])

        await state.idleLoop()

        guard let updated = state.shows.first(where: { $0.show_id == show.show_id }) else {
            Issue.record("show disappeared"); return
        }
        #expect(updated.notify_upnext_time == nil)
        #expect(updated.notify_recording_time == nil)
    }

    @Test @MainActor func idleLoop_neverAutoResumesAManuallyPausedShow() async {
        var show = Show.blank(channel: "9.1", device: "FFFFFFFF")
        show.show_title = "Deliberately Paused Show"
        show.show_active = true
        show.show_paused = true
        show.show_fail_reason = "Manually paused"   // pauseShow's own marker, not the auto-pause one
        // Both windows kept safely in the future so the pre-existing, unrelated "paused window
        // expired" generic recovery (Pass 2 below) can't also resume this show — this test is
        // specifically isolating the tuner-detection auto-resume's own marker check, not that.
        show.show_next = Date().addingTimeInterval(3600)
        show.show_end  = Date().addingTimeInterval(5400)
        let state = makeTestAppState(shows: [show], devices: [makeDevice()])

        await state.idleLoop()

        guard let updated = state.shows.first(where: { $0.show_id == show.show_id }) else {
            Issue.record("show disappeared"); return
        }
        #expect(updated.show_paused == true, "A user's own pause must never be undone by tuner detection")
        #expect(updated.show_fail_reason == "Manually paused")
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
