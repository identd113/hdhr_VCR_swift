import Testing
import Foundation
@testable import hdhr_VCR

// Coverage for the virtual-tuner HTTP JSON builders (WebServer.swift's buildVirtualTunerDiscoverJSON/
// LineupJSON/StatusJSON) and the /api/record refusal guardrail — the parts reachable without a live
// NWListener or real socket. Full route dispatch (/discover.json, /lineup.json 404-when-idle, the
// UDP responder, ?duration= auto-close) is covered by the plan's own manual "Verification" section
// (tools/mock_scenario.py record-test + curl), same split RecordFlowTests/GuideJSONRecordingTests
// already use for their own routes.
@Suite("Virtual tuner web JSON + record guardrail")
struct VirtualTunerWebRoutesTests {

    @MainActor
    @Test func discoverJSON_reflectsActiveRecordingCountAndCarriesRelayMarker() {
        var show = Show.testRecording(title: "Days of Our Lives", channel: "5.1")
        show.hdhr_record = "FFFFFFFF"
        let state = makeTestAppState(shows: [show], devices: [.test(id: "FFFFFFFF")])

        let json = WebServer().buildVirtualTunerDiscoverJSON(state: state, deviceID: "FEEDABCD")
        #expect(json["DeviceID"] as? String == "FEEDABCD")
        #expect(json["TunerCount"] as? Int == 1)
        #expect(json["HdhrVCRplusVirtualRelay"] as? Bool == true)
        #expect((json["BaseURL"] as? String)?.isEmpty == false)
        #expect((json["LineupURL"] as? String)?.hasSuffix("/lineup.json") == true)
    }

    // Requested 2026-09-03: the relay should read as clearly related to the real unit it's
    // relaying from in a third-party client's device list, instead of a generic label.
    @MainActor
    @Test func discoverJSON_friendlyNameIsSourceDeviceNameWithRelaySuffix() {
        var show = Show.testRecording(title: "Days of Our Lives", channel: "5.1")
        show.hdhr_record = "FFFFFFFF"
        let state = makeTestAppState(shows: [show],
                                      devices: [.test(id: "FFFFFFFF", friendlyName: "HDHomeRun EXTEND")])
        let json = WebServer().buildVirtualTunerDiscoverJSON(state: state, deviceID: "FEEDABCD")
        #expect(json["FriendlyName"] as? String == "HDHomeRun EXTEND-Relay")
    }

    @MainActor
    @Test func discoverJSON_friendlyNameFallsBackToGenericWhenSourceDeviceHasNone() {
        var show = Show.testRecording(title: "Days of Our Lives", channel: "5.1")
        show.hdhr_record = "FFFFFFFF"
        // .test()'s default friendlyName is nil — mirrors a UDP-only-discovered source device with
        // no FriendlyName TLV read, same as the existing ModelNumber-absent convention.
        let state = makeTestAppState(shows: [show], devices: [.test(id: "FFFFFFFF")])
        let json = WebServer().buildVirtualTunerDiscoverJSON(state: state, deviceID: "FEEDABCD")
        #expect(json["FriendlyName"] as? String == "hdhrVCRplus (Recording Relay)")
    }

    @MainActor
    @Test func discoverJSON_tunerCountOnlyCountsActivelyRecordingShows() {
        var recording = Show.testRecording(title: "Recording Now", channel: "5.1")
        recording.hdhr_record = "FFFFFFFF"
        let scheduled = Show.testActive(title: "Not Recording Yet", channel: "7.1")
        let state = makeTestAppState(shows: [recording, scheduled], devices: [.test(id: "FFFFFFFF")])

        let json = WebServer().buildVirtualTunerDiscoverJSON(state: state, deviceID: "FEEDABCD")
        #expect(json["TunerCount"] as? Int == 1)
    }

    @MainActor
    @Test func lineupJSON_oneEntryPerRecordingChannel_carryingShowTitleAndGuideName() {
        var show = Show.testRecording(title: "Days of Our Lives", channel: "5.1")
        show.hdhr_record = "FFFFFFFF"
        let lineup = [LineupEntry.test(number: "5.1", name: "KFOO")]
        let state = makeTestAppState(shows: [show], devices: [.test(id: "FFFFFFFF")],
                                      lineups: ["FFFFFFFF": lineup])

        let entries = WebServer().buildVirtualTunerLineupJSON(state: state)
        #expect(entries.count == 1)
        let entry = try! #require(entries.first)
        #expect(entry["GuideNumber"] as? String == "5.1")
        #expect(entry["GuideName"] as? String == "KFOO")
        #expect(entry["HdhrVCRplusShowTitle"] as? String == "Days of Our Lives")
        #expect((entry["URL"] as? String)?.contains("/auto/v5.1") == true)
        #expect((entry["URL"] as? String)?.contains("dev=FFFFFFFF") == true)
    }

    @MainActor
    @Test func lineupJSON_disambiguatesTwoDevicesSharingAChannelNumber() {
        // Two real devices both happening to have a channel numbered "5.1" (e.g. two tuners fed
        // from the same cable lineup), both recording simultaneously — without a `dev=` component
        // in the URL, the two entries would be byte-for-byte identical and a remote viewer picking
        // either one would always resolve to the same device's recording.
        var showA = Show.testRecording(title: "Show On Device A", channel: "5.1"); showA.hdhr_record = "AAAAAAAA"
        var showB = Show.testRecording(title: "Show On Device B", channel: "5.1"); showB.hdhr_record = "BBBBBBBB"
        let state = makeTestAppState(shows: [showA, showB], devices: [.test(id: "AAAAAAAA"), .test(id: "BBBBBBBB")])

        let entries = WebServer().buildVirtualTunerLineupJSON(state: state)
        #expect(entries.count == 2)
        let urls = Set(entries.compactMap { $0["URL"] as? String })
        #expect(urls.count == 2)   // distinct despite the identical GuideNumber
        #expect(urls.contains { $0.contains("dev=AAAAAAAA") })
        #expect(urls.contains { $0.contains("dev=BBBBBBBB") })
    }

    @MainActor
    @Test func lineupJSON_excludesNonRecordingShows() {
        let scheduled = Show.testActive(title: "Later Tonight", channel: "7.1")
        let state = makeTestAppState(shows: [scheduled], devices: [.test(id: "FFFFFFFF")])
        #expect(WebServer().buildVirtualTunerLineupJSON(state: state).isEmpty)
    }

    @MainActor
    @Test func lineupJSON_fallsBackToChannelNumberWhenLineupHasNoMatchingEntry() {
        // No lineup loaded at all for this device — GuideName has nothing to look up.
        var show = Show.testRecording(title: "Days of Our Lives", channel: "5.1")
        show.hdhr_record = "FFFFFFFF"
        let state = makeTestAppState(shows: [show], devices: [.test(id: "FFFFFFFF")])
        let entry = try! #require(WebServer().buildVirtualTunerLineupJSON(state: state).first)
        #expect(entry["GuideName"] as? String == "5.1")
    }

    @MainActor
    @Test func statusJSON_oneTunerRowPerRecordingChannel() {
        var s1 = Show.testRecording(title: "Show A", channel: "5.1"); s1.hdhr_record = "FFFFFFFF"
        var s2 = Show.testRecording(title: "Show B", channel: "7.1"); s2.hdhr_record = "FFFFFFFF"
        let state = makeTestAppState(shows: [s1, s2], devices: [.test(id: "FFFFFFFF")])

        let tuners = WebServer().buildVirtualTunerStatusJSON(state: state)
        #expect(tuners.count == 2)
        #expect(Set(tuners.compactMap { $0["VctNumber"] as? String }) == ["5.1", "7.1"])
    }

    // MARK: - /api/record refusal for a virtual-relay device

    @MainActor
    @Test func handleRecord_refusesRecordingAgainstAVirtualRelayDevice() throws {
        let relay = HDHRDevice.test(id: "FEED1111", isVirtualRelay: true)
        let lineup = [LineupEntry.test(number: "5.1", name: "KFOO")]
        let state = makeTestAppState(devices: [relay], lineups: ["FEED1111": lineup])

        let start = Int(Date().timeIntervalSince1970) + 3600
        let body: [String: Any] = [
            "deviceId": "FEED1111", "guideNumber": "5.1", "startTime": start,
            "showType": "single", "bonusTime": false,
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        let response = WebServer().handleRecord(state: state, body: bodyData)
        guard case .ok(_, let respData) = response else {
            Issue.record("expected .ok (with ok:false payload), got \(response)")
            return
        }
        let respJSON = try #require(JSONSerialization.jsonObject(with: respData) as? [String: Any])
        #expect(respJSON["ok"] as? Bool == false)
        #expect(state.shows.isEmpty)
    }

    // MARK: - Already-modern-codec skip (lineup fast path vs. on-disk PAT/PMT fallback)

    @Test func sourceIsAlreadyModernCodec_lineupSaysH264_trueWithoutTouchingDisk() {
        // A nonexistent path proves the lineup answer was used directly — if this fell through to
        // the file probe it would hit the missing-file case and return false instead.
        #expect(WebServer.sourceIsAlreadyModernCodec(
            lineupVideoCodec: "H264", recordingPath: "/nonexistent/\(UUID().uuidString).ts"))
    }

    @Test func sourceIsAlreadyModernCodec_lineupSaysMPEG2_false() {
        #expect(!WebServer.sourceIsAlreadyModernCodec(
            lineupVideoCodec: "MPEG2", recordingPath: "/nonexistent/\(UUID().uuidString).ts"))
    }

    @Test func sourceIsAlreadyModernCodec_lineupNil_fallsBackToFileProbe() {
        // No lineup answer (this app's own synthetic virtual-relay entries never set VideoCodec) and
        // no file to probe either — must fail safe (false, no crash), not throw or assume "modern".
        #expect(!WebServer.sourceIsAlreadyModernCodec(
            lineupVideoCodec: nil, recordingPath: "/nonexistent/\(UUID().uuidString).ts"))
    }

    // MARK: - Web guide device bar / default tuner exclusion

    @MainActor
    @Test func devBarHTML_excludesAVirtualRelayDevice() {
        let relay = HDHRDevice.test(id: "FEED3333", isVirtualRelay: true)
        let real = HDHRDevice.test(id: "FFFFFFFF")
        let state = makeTestAppState(devices: [relay, real])
        let ws = WebServer()
        let devTuners = WebServer.computeDevTuners(state: state)
        let html = ws.buildDevBarHTML(state: state, devTuners: devTuners)
        #expect(!html.contains("FEED3333"))
        #expect(html.contains("FFFFFFFF"))
    }
}
