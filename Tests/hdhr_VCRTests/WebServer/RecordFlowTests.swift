import Testing
import Foundation
@testable import hdhr_VCR

// Coverage for the exact request shape hdhr_guide (Sources/hdhr_guide/, a separate SPM executable
// target that can't itself be @testable imported here — see docs/TUIGuide.md's "Robustness fixes"
// section) sends when scheduling a recording: API.postRecord() posts
// {deviceId, guideNumber, startTime, showType, bonusTime} to /api/record, with no title override
// (unlike the web guide's Record modal, which always sends one). Manually verified live once via
// tools/mock_scenario.py plant (same /api/record endpoint, same payload shape) — this codifies
// that as a repeatable, in-process test instead of a one-off manual check, and covers all four
// showType values hdhr_guide's 1-4 keys can send, not just the one manually tried.

private final class RecordFlowMockURLProtocol: MockURLProtocolBase {
    private static var _handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { _handler }
        set { _handler = newValue }
    }
}

@Suite("handleRecord — hdhr_guide's exact POST /api/record shape")
struct RecordFlowTests {

    @MainActor
    @Test(arguments: ["single", "dateTime", "seriesChannel", "seriesAll"])
    func hdhrGuideRequestShapeProducesAValidShow(showType: String) async throws {
        let device = HDHRDevice(DeviceID: "AABBCCDD", LocalIP: "192.168.1.50",
                                 BaseURL: "http://192.168.1.50", TunerCount: 2,
                                 FirmwareVersion: nil, DeviceAuth: nil)
        let lineup = [LineupEntry(GuideNumber: "5.1", GuideName: "KVUE", URL: nil, HD: 1, Favorite: nil)]

        let start = Int(Date().timeIntervalSince1970) + 3600
        let end = start + 1800
        let guideJSON = """
        [{"GuideNumber":"5.1","GuideName":"KVUE","Guide":[
            {"StartTime":\(start),"EndTime":\(end),"Title":"Jeopardy!","EpisodeNumber":"S42E101","SeriesID":"C184056EN6FJY","Filter":["Game Show"]}
        ]}]
        """
        let session = makeMockSession(RecordFlowMockURLProtocol.self)
        RecordFlowMockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             guideJSON.data(using: .utf8)!)
        }
        let guideStore = GuideStore(session: session)
        await guideStore.load(for: device)

        let state = makeTestAppState(devices: [device], lineups: ["AABBCCDD": lineup], guideStore: guideStore)
        #expect(state.shows.isEmpty)

        // Exactly hdhr_guide's confirmRecord()/API.postRecord() body — no "title" key, matching
        // the TUI's own reliance on the server default (main.swift: postRecord(deviceId:guideNumber:
        // startTime:showType:bonusTime:), the JSON dictionary built there has no title field at all).
        let body: [String: Any] = [
            "deviceId": "AABBCCDD", "guideNumber": "5.1", "startTime": start,
            "showType": showType, "bonusTime": false
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        let response = WebServer().handleRecord(state: state, body: bodyData)
        guard case .ok(_, let respData) = response else {
            Issue.record("expected .ok, got \(response)")
            return
        }
        let respJSON = try #require(JSONSerialization.jsonObject(with: respData) as? [String: Any])
        #expect(respJSON["ok"] as? Bool == true)
        #expect(respJSON["title"] as? String == "Jeopardy!")   // server default — no override sent

        let show = try #require(state.shows.first)
        #expect(state.shows.count == 1)
        #expect(show.show_title == "Jeopardy!")
        #expect(show.show_channel == "5.1")
        #expect(show.hdhr_record == "AABBCCDD")
        #expect(show.show_active == true)
        #expect(show.show_paused == false)
        #expect(show.show_fail_count == 0)
        #expect(show.show_length == 30)   // (end - start) / 60
        #expect(show.state == WebServer().showStateFromString(showType))
        // dateTime/seriesChannel/seriesAll all set show_is_series (only "single" doesn't — a
        // recurring dateTime show is a series too, just not SeriesID-matched); seriesAll
        // additionally sets show_use_seriesid_all. Show.state (Models.swift) is this decision
        // tree inverted: !show_is_series -> single, else show_use_seriesid_all -> seriesAll,
        // else show_use_seriesid -> seriesChannel, else dateTime.
        switch showType {
        case "single":
            #expect(show.show_is_series == false)
        case "dateTime":
            #expect(show.show_is_series == true)
            #expect(show.show_use_seriesid == false)
            #expect(show.show_use_seriesid_all == false)
        case "seriesChannel":
            #expect(show.show_is_series == true)
            #expect(show.show_use_seriesid_all == false)
        case "seriesAll":
            #expect(show.show_is_series == true)
            #expect(show.show_use_seriesid_all == true)
        default:
            Issue.record("unhandled showType in test itself: \(showType)")
        }
    }
}
