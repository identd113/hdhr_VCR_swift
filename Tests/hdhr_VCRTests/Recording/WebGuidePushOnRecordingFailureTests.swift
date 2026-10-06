import Testing
import Foundation
@testable import hdhr_VCR

// MARK: - The web guide hears about a show that stops recording for a bad reason
//
// A show paused after repeated failures, or skipped because the disk is full, used to change state
// without telling the web guide — it kept looking unchanged until something unrelated rebuilt it.
// Both paths in `AppState.startRecording` now push a `show_updated` guide event. These tests observe
// the events through `WebServer.broadcastObserver` (a no-client-needed seam) and check the state each
// path leaves behind, which is what that event's rebuilt payload then renders.

@Suite("startRecording → web guide push on failure/skip")
struct WebGuidePushOnRecordingFailureTests {

    private func tempRecordDir() -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    // single: false → a recurring date/time show (no guide re-check before the fail-threshold gate);
    // true → a one-off.
    private func makeShow(single: Bool = false) -> Show {
        var s = Show.blank(channel: "5.1", device: "FFFFFFFF")
        s.show_title = "Test Show"
        s.show_active = true
        s.show_next = Date().addingTimeInterval(-5)
        s.show_end = Date().addingTimeInterval(1800)
        s.show_dir = tempRecordDir()
        s.show_url = "http://192.168.1.100:5004/auto/v5.1"
        s.show_is_series = !single
        s.show_use_seriesid = false
        s.show_use_seriesid_all = false
        return s
    }

    // Collects the `type` of every event the web server was asked to broadcast.
    @MainActor
    private func observe(_ state: AppState) -> Box {
        let box = Box()
        state.webServer.broadcastObserver = { event in box.events.append(event) }
        return box
    }
    final class Box { var events: [[String: Any]] = [] }

    private func showUpdated(_ events: [[String: Any]]) -> [[String: Any]] {
        events.filter { $0["type"] as? String == "show_updated" }
    }

    // MARK: failure threshold

    @Test @MainActor func failThresholdReached_pausesARecurringShow_andPushesShowUpdated() async {
        var show = makeShow()
        show.show_fail_count = 99          // ≥ any configured Fail_count_setting
        show.show_fail_reason = "No stream URL"
        let state = makeTestAppState(shows: [show], devices: [.test(id: "FFFFFFFF", tuners: 4)])
        state.config.Min_disk_free_gb = 0
        let box = observe(state)

        await state.startRecording(index: 0)

        #expect(state.shows[0].show_paused == true)
        #expect(state.shows[0].show_recording == false)
        let pushed = showUpdated(box.events)
        #expect(pushed.count >= 1, "paused-after-failures changed state but never told the web guide")
        #expect(pushed.first?["channel"] as? String == "5.1")
        #expect(pushed.first?["device"] as? String == "FFFFFFFF")
    }

    @Test @MainActor func failThresholdReached_deactivatesASingle_insteadOfPausingIt() async {
        var show = makeShow(single: true)
        show.show_fail_count = 99
        let state = makeTestAppState(shows: [show], devices: [.test(id: "FFFFFFFF", tuners: 4)])
        state.config.Min_disk_free_gb = 0
        let box = observe(state)

        await state.startRecording(index: 0)

        #expect(state.shows[0].show_active == false)   // singles auto-clean; there's no "next airing" to retry
        #expect(state.shows[0].show_recording == false)
        #expect(showUpdated(box.events).count >= 1)
    }

    // MARK: disk full

    @Test @MainActor func diskBelowMinimum_skipsTheRecording_recordsAFailure_andPushesShowUpdated() async {
        let show = makeShow()
        let state = makeTestAppState(shows: [show], devices: [.test(id: "FFFFFFFF", tuners: 4)])
        state.config.Min_disk_free_gb = 1_000_000_000   // more than any volume has free
        let box = observe(state)

        await state.startRecording(index: 0)

        #expect(state.shows[0].show_recording == false)
        #expect(state.shows[0].show_fail_count == 1)
        #expect(state.shows[0].show_fail_reason.contains("free up space"))
        let pushed = showUpdated(box.events)
        #expect(pushed.count >= 1, "disk-full skip changed state but never told the web guide")
        #expect(pushed.first?["channel"] as? String == "5.1")
    }

    @Test @MainActor func aHealthyShow_withEnoughDisk_doesNotTakeEitherFailurePath() async throws {
        let scriptPath = try writeMockCurlScript(sleepSeconds: 30)
        defer { try? FileManager.default.removeItem(atPath: scriptPath) }
        let manager = RecordingManager(curlExecutablePath: scriptPath)
        let show = makeShow()
        let state = makeTestAppState(shows: [show], devices: [.test(id: "FFFFFFFF", tuners: 4)], recordingManager: manager)
        state.config.Min_disk_free_gb = 0
        let box = observe(state)

        await state.startRecording(index: 0)
        defer { manager.stop(showId: show.show_id) }

        #expect(state.shows[0].show_recording == true)
        #expect(state.shows[0].show_paused == false)
        #expect(state.shows[0].show_fail_count == 0)
        // No failure-flavoured show_updated from these two paths (recording start uses its own event).
        #expect(showUpdated(box.events).allSatisfy { ($0["channel"] as? String) == "5.1" })
    }
}
