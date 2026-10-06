import Testing
import Foundation
@testable import hdhr_VCR

// MARK: - /api/tuner-status.json (Home Assistant status endpoint)
//
// Off by default and a real gate (Settings → Sharing → Home Assistant), not a courtesy toggle — so the
// gate is tested through `tunerStatusResponse(state:)`, the exact function the route calls. The payload
// is tested through `buildTunerStatusJSON`: per-device occupancy/total/full, the
// recording / upNext / scheduled / paused grouping, the recording-vs-"other" occupancy breakdown, poster
// omission, and that a virtual relay is never reported as a tuner.

@Suite("WebServer /api/tuner-status.json")
struct WebServerTunerStatusTests {

    private func busyTuner(_ resource: String, channel: String) -> DeviceTunerInfo {
        let json = #"{"Resource":"\#(resource)","VctNumber":"\#(channel)","TargetIP":"10.0.0.9","SignalQualityPercent":90}"#
        return try! JSONDecoder().decode(DeviceTunerInfo.self, from: Data(json.utf8))
    }

    private func idleTuner(_ resource: String) -> DeviceTunerInfo {
        try! JSONDecoder().decode(DeviceTunerInfo.self, from: Data(#"{"Resource":"\#(resource)"}"#.utf8))
    }

    @MainActor
    private func tuners(_ state: AppState) throws -> [[String: Any]] {
        let data = WebServer().buildTunerStatusJSON(state: state)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(obj["tuners"] as? [[String: Any]])
    }

    // MARK: gate

    @MainActor
    @Test func disabledByDefault_returnsNotFound_withTheEnableHint() {
        let state = makeTestAppState(devices: [.test(id: "AAAA0001")])
        #expect(state.config.Home_assistant_status_enabled == false)
        switch WebServer().tunerStatusResponse(state: state) {
        case .notFound(let msg): #expect(msg.contains("Settings → Sharing"))
        default: Issue.record("expected .notFound while the endpoint is disabled")
        }
    }

    @MainActor
    @Test func enabled_returnsJSON() throws {
        let state = makeTestAppState(devices: [.test(id: "AAAA0001")])
        state.config.Home_assistant_status_enabled = true
        guard case .ok(let type, let body) = WebServer().tunerStatusResponse(state: state) else {
            Issue.record("expected .ok once enabled"); return
        }
        #expect(type == "application/json")
        #expect(try JSONSerialization.jsonObject(with: body) is [String: Any])
    }

    // MARK: payload

    @MainActor
    @Test func idleDevice_reportsTotalsAndNothingActive() throws {
        let state = makeTestAppState(devices: [.test(id: "AAAA0001", tuners: 2)])
        state.deviceTunerOccupancy["AAAA0001"] = [idleTuner("tuner0"), idleTuner("tuner1")]
        let t = try #require(try tuners(state).first)
        #expect(t["deviceId"] as? String == "AAAA0001")
        #expect(t["name"] as? String == "HDHR-AAAA0001")
        #expect(t["online"] as? Bool == true)
        #expect(t["tunerTotal"] as? Int == 2)
        #expect(t["tunerActive"] as? Int == 0)
        #expect(t["tunerFull"] as? Bool == false)
        #expect(t["watchingLive"] as? Bool == false)
        #expect(t["otherOccupancy"] as? Int == 0)
        #expect((t["recording"] as? [Any])?.isEmpty == true)
    }

    @MainActor
    @Test func hardwareBusyWithNoLocalExplanation_isOtherOccupancy_andCanFillTheDevice() throws {
        let state = makeTestAppState(devices: [.test(id: "AAAA0001", tuners: 2)])
        state.deviceTunerOccupancy["AAAA0001"] = [busyTuner("tuner0", channel: "5.1"), busyTuner("tuner1", channel: "9.1")]
        let t = try #require(try tuners(state).first)
        #expect(t["tunerActive"] as? Int == 2)
        #expect(t["tunerFull"] as? Bool == true)
        #expect(t["otherOccupancy"] as? Int == 2)     // another machine / the HDHomeRun app — not this app's own use
        #expect(t["watchingLive"] as? Bool == false)
    }

    @MainActor
    @Test func ownRecording_isListedAndSubtractedFromOtherOccupancy() throws {
        var rec = Show.testRecording(title: "The Tonight Show", channel: "5.1")
        rec.hdhr_record = "AAAA0001"
        rec.show_logo_url = "https://img.example/poster.jpg"
        let state = makeTestAppState(shows: [rec], devices: [.test(id: "AAAA0001", tuners: 2)])
        state.deviceTunerOccupancy["AAAA0001"] = [busyTuner("tuner0", channel: "5.1"), busyTuner("tuner1", channel: "9.1")]
        let t = try #require(try tuners(state).first)
        let recs = try #require(t["recording"] as? [[String: Any]])
        #expect(recs.count == 1)
        #expect(recs[0]["title"] as? String == "The Tonight Show")
        #expect(recs[0]["channel"] as? String == "5.1")
        #expect(recs[0]["poster"] as? String == "https://img.example/poster.jpg")
        #expect(recs[0]["end"] is Int)
        #expect(t["otherOccupancy"] as? Int == 1)      // 2 busy − 1 this app's own recording
    }

    @MainActor
    @Test func recordingWithoutALogo_omitsThePosterKey() throws {
        var rec = Show.testRecording()
        rec.hdhr_record = "AAAA0001"
        let state = makeTestAppState(shows: [rec], devices: [.test(id: "AAAA0001")])
        let t = try #require(try tuners(state).first)
        let recs = try #require(t["recording"] as? [[String: Any]])
        #expect(recs[0]["poster"] == nil)              // omitted, not a misleading ""
    }

    @MainActor
    @Test func scheduledAndPausedShows_landInTheirOwnGroups_perDevice() throws {
        var scheduledMine = Show.testActive(title: "60 Minutes", channel: "3.1")
        scheduledMine.hdhr_record = "AAAA0001"
        scheduledMine.show_next = Date().addingTimeInterval(5 * 86_400)     // not today → Scheduled, not Up Next
        var pausedMine = Show.testActive(title: "Dateline NBC", channel: "4.1")
        pausedMine.hdhr_record = "AAAA0001"
        pausedMine.show_paused = true
        var otherDevice = Show.testActive(title: "Elsewhere", channel: "7.1")
        otherDevice.hdhr_record = "BBBB0002"
        otherDevice.show_next = Date().addingTimeInterval(5 * 86_400)
        let state = makeTestAppState(shows: [scheduledMine, pausedMine, otherDevice],
                                     devices: [.test(id: "AAAA0001"), .test(id: "BBBB0002")])
        let all = try tuners(state)
        let a = try #require(all.first { $0["deviceId"] as? String == "AAAA0001" })
        let b = try #require(all.first { $0["deviceId"] as? String == "BBBB0002" })

        #expect((a["scheduled"] as? [[String: Any]])?.map { $0["title"] as? String } == ["60 Minutes"])
        #expect((a["paused"] as? [[String: Any]])?.map { $0["title"] as? String } == ["Dateline NBC"])
        #expect((b["scheduled"] as? [[String: Any]])?.map { $0["title"] as? String } == ["Elsewhere"])
        #expect((b["paused"] as? [Any])?.isEmpty == true)
    }

    @MainActor
    @Test func aShowAiringLaterToday_isUpNext_notScheduled() throws {
        var soon = Show.testActive(title: "Late Night", channel: "5.1")
        soon.hdhr_record = "AAAA0001"
        // Today but later — computed so the test still holds near midnight.
        let cal = Calendar.current
        let endOfToday = cal.startOfDay(for: Date()).addingTimeInterval(86_400 - 60)
        soon.show_next = min(endOfToday, Date().addingTimeInterval(600))
        try #require(cal.isDateInToday(soon.show_next!))
        let state = makeTestAppState(shows: [soon], devices: [.test(id: "AAAA0001")])
        let t = try #require(try tuners(state).first)
        let up = try #require(t["upNext"] as? [String: Any])
        #expect(up["title"] as? String == "Late Night")
        #expect((t["scheduled"] as? [Any])?.isEmpty == true)
    }

    @MainActor
    @Test func virtualRelayDevice_isNeverReportedAsATuner() throws {
        let state = makeTestAppState(devices: [.test(id: "AAAA0001"), .test(id: "FEED0001", isVirtualRelay: true)])
        let ids = try tuners(state).compactMap { $0["deviceId"] as? String }
        #expect(ids == ["AAAA0001"])
    }

    @MainActor
    @Test func undetectedDeviceStillOwningAShow_isListedOffline_neverSilentlyOmitted() throws {
        var orphan = Show.testActive(title: "Orphan", channel: "2.1")
        orphan.hdhr_record = "GONE0001"
        orphan.show_next = Date().addingTimeInterval(5 * 86_400)   // not today → Scheduled (today's would be Up Next)
        let state = makeTestAppState(shows: [orphan], devices: [.test(id: "AAAA0001")])
        let all = try tuners(state)
        let gone = try #require(all.first { $0["deviceId"] as? String == "GONE0001" })
        #expect(gone["online"] as? Bool == false)
        #expect(gone["tunerTotal"] as? Int == 0)
        #expect((gone["scheduled"] as? [[String: Any]])?.map { $0["title"] as? String } == ["Orphan"])
    }
}
