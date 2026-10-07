import Testing
import Foundation
@testable import hdhr_VCR

// MARK: - Web guide push on a hardware tuner-occupancy change
//
// Two pushes with different costs (AppState.broadcastTunerOccupancyChange): the tiny tuner-count badge update
// (`tuner_update`) goes out every time, immediately; the guide grid/dropdown rebuild (`tuner_occupancy_changed`)
// is throttled to once per cooldown per device, with the dropped change picked up by a trailing rebuild. The
// churn test found the badge trailing a closed player by ~12s when both shared the throttle.

@Suite("AppState.broadcastTunerOccupancyChange")
struct TunerOccupancyBroadcastTests {

    private func busy(_ resource: String, _ channel: String) -> DeviceTunerInfo {
        try! JSONDecoder().decode(DeviceTunerInfo.self, from: Data(#"{"Resource":"\#(resource)","VctNumber":"\#(channel)"}"#.utf8))
    }

    @MainActor private func observe(_ state: AppState) -> ObservedEvents {
        let box = ObservedEvents()
        state.webServer.broadcastObserver = { box.events.append($0) }
        return box
    }
    final class ObservedEvents {
        var events: [[String: Any]] = []
        func count(_ type: String) -> Int { events.filter { $0["type"] as? String == type }.count }
    }

    @MainActor @Test func theFirstChange_pushesBothTheBadgeCountsAndTheGuideRebuild() async {
        let state = makeTestAppState(devices: [.test(id: "AAAA0001", tuners: 2)])
        state.deviceTunerOccupancy["AAAA0001"] = [busy("tuner0", "5.1")]
        let seen = observe(state)

        await state.broadcastTunerOccupancyChange(deviceId: "AAAA0001")

        #expect(seen.count("tuner_update") == 1)
        #expect(seen.count("tuner_occupancy_changed") == 1)
        let counts = seen.events.first { $0["type"] as? String == "tuner_update" }?["counts"] as? [String: [String: Any]]
        #expect(counts?["AAAA0001"]?["a"] as? Int == 1)
        #expect(counts?["AAAA0001"]?["t"] as? Int == 2)
    }

    @MainActor @Test func aSecondChangeInsideTheCooldown_stillPushesTheBadgeImmediately_butNotAnotherGridRebuild() async {
        let state = makeTestAppState(devices: [.test(id: "AAAA0001", tuners: 2)])
        state.deviceTunerOccupancy["AAAA0001"] = [busy("tuner0", "5.1"), busy("tuner1", "9.1")]
        let seen = observe(state)

        await state.broadcastTunerOccupancyChange(deviceId: "AAAA0001")      // two tuners busy
        state.deviceTunerOccupancy["AAAA0001"] = [busy("tuner0", "5.1")]     // a stream closes a moment later
        await state.broadcastTunerOccupancyChange(deviceId: "AAAA0001")

        // The badge reflects the second change right away (2 → 1) …
        let badgeValues = seen.events.filter { $0["type"] as? String == "tuner_update" }
            .compactMap { ($0["counts"] as? [String: [String: Any]])?["AAAA0001"]?["a"] as? Int }
        #expect(badgeValues == [2, 1])
        // … while the heavy grid rebuild ran once (the second is deferred to a trailing rebuild).
        #expect(seen.count("tuner_occupancy_changed") == 1)
    }

    @MainActor @Test func theBadgeCountIncludesTheLocalLiveStream_notJustTheHardware() async {
        // activeTunerCount = max(hardware, recordings + local VLC); with a local recording and one hardware-busy
        // tuner the badge must say 1, never double-count.
        var rec = Show.testRecording()
        rec.hdhr_record = "AAAA0001"
        let state = makeTestAppState(shows: [rec], devices: [.test(id: "AAAA0001", tuners: 2)])
        state.deviceTunerOccupancy["AAAA0001"] = [busy("tuner0", "5.1")]
        let seen = observe(state)

        await state.broadcastTunerOccupancyChange(deviceId: "AAAA0001")

        let counts = seen.events.first { $0["type"] as? String == "tuner_update" }?["counts"] as? [String: [String: Any]]
        #expect(counts?["AAAA0001"]?["a"] as? Int == 1)
    }

    @MainActor @Test func aVirtualRelayDevice_isNeverGivenABadgeEntry() async {
        let state = makeTestAppState(devices: [.test(id: "AAAA0001", tuners: 2), .test(id: "FEED0001", isVirtualRelay: true)])
        let seen = observe(state)

        await state.broadcastTunerOccupancyChange(deviceId: "AAAA0001")

        let counts = seen.events.first { $0["type"] as? String == "tuner_update" }?["counts"] as? [String: Any]
        #expect(counts?.keys.sorted() == ["AAAA0001"])
    }
}
