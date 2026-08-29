import Testing
import Foundation
@testable import hdhr_VCR

// Coverage for handleGuideSearch(path:state:) — /api/guide-search's actual scan+group+sort logic,
// which had zero test coverage despite a pre-release commit (919a045) moving its per-keystroke
// work off @MainActor for responsiveness and this cycle adding the client-side type-ahead search
// feature it powers. `state` is an explicit parameter (rather than WebServer's own private
// `appState`) specifically so this is directly callable here — same shape RecordFlowTests already
// uses for handleRecord(state:body:).
//
// Not covered here (and can't be, with this project's current tooling): the client-side XSS fix
// in the same commit (guide.js's hej() escaper) — that's pure JS with no test harness in this
// repo. This file only covers the server's JSON response; the vulnerable string-concatenation into
// an <img src="..."> attribute lives entirely in guide.js.
private final class GuideSearchMockURLProtocol: MockURLProtocolBase {
    private static var _handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { _handler }
        set { _handler = newValue }
    }
}

@Suite("handleGuideSearch — /api/guide-search", .serialized)
struct GuideSearchTests {

    // Loads `guideJSON` into a real GuideStore (via a mocked session, same pattern
    // RecordFlowTests uses) and returns an AppState wired to it.
    @MainActor
    private func makeState(deviceId: String = "AABBCCDD", guideJSON: String) async -> AppState {
        let device = HDHRDevice(DeviceID: deviceId, LocalIP: "192.168.1.50",
                                 BaseURL: "http://192.168.1.50", TunerCount: 2,
                                 FirmwareVersion: nil, DeviceAuth: nil)
        let session = makeMockSession(GuideSearchMockURLProtocol.self)
        GuideSearchMockURLProtocol.requestHandler = { req in
            (mockOKResponse(for: req.url!), Data(guideJSON.utf8))
        }
        let guideStore = GuideStore(session: session)
        await guideStore.load(for: device)
        return makeTestAppState(devices: [device], guideStore: guideStore)
    }

    @MainActor
    private func search(_ query: String, deviceId: String = "AABBCCDD", state: AppState) async -> [[String: Any]] {
        let path = "/api/guide-search/\(deviceId)/\(query)"
        let response = await WebServer().handleGuideSearch(path: path, state: state)
        guard case .ok(_, let data) = response else {
            Issue.record("expected .ok, got \(response)")
            return []
        }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return json["shows"] as? [[String: Any]] ?? []
    }

    @Test @MainActor func matchingTitleReturnsOneShowWithOneAiring() async {
        let start = Int(Date().timeIntervalSince1970) + 3600
        let guideJSON = """
        [{"GuideNumber":"5.1","GuideName":"KVUE","Guide":[
            {"StartTime":\(start),"EndTime":\(start + 1800),"Title":"Jeopardy!","SeriesID":"C184056EN6FJY"}
        ]}]
        """
        let state = await makeState(guideJSON: guideJSON)
        let shows = await search("jeopardy", state: state)
        #expect(shows.count == 1)
        #expect(shows.first?["title"] as? String == "Jeopardy!")
        #expect(shows.first?["seriesId"] as? String == "C184056EN6FJY")
        #expect((shows.first?["airings"] as? [[String: Any]])?.count == 1)
    }

    @Test @MainActor func caseInsensitiveSubstringMatch() async {
        let start = Int(Date().timeIntervalSince1970) + 3600
        let guideJSON = """
        [{"GuideNumber":"5.1","GuideName":"KVUE","Guide":[
            {"StartTime":\(start),"EndTime":\(start + 1800),"Title":"The Daily Show","SeriesID":"ds456"}
        ]}]
        """
        let state = await makeState(guideJSON: guideJSON)
        let shows = await search("DAILY", state: state)
        #expect(shows.count == 1)
        #expect(shows.first?["title"] as? String == "The Daily Show")
    }

    // Two airings sharing a SeriesID (a rerun) must collapse into one show with two airings, not
    // two separate rows — the same grouping guarantee GuideLogicTests.searchShows already verifies
    // for the Terminal Guide's offline counterpart to this endpoint.
    @Test @MainActor func groupsRerunsBySeriesID() async {
        let start = Int(Date().timeIntervalSince1970) + 3600
        let guideJSON = """
        [{"GuideNumber":"5.1","GuideName":"KVUE","Guide":[
            {"StartTime":\(start),"EndTime":\(start + 1800),"Title":"Seinfeld","SeriesID":"sf1"},
            {"StartTime":\(start + 1800),"EndTime":\(start + 3600),"Title":"Seinfeld","SeriesID":"sf1"}
        ]}]
        """
        let state = await makeState(guideJSON: guideJSON)
        let shows = await search("seinfeld", state: state)
        #expect(shows.count == 1)
        #expect((shows.first?["airings"] as? [[String: Any]])?.count == 2)
    }

    // No SeriesID at all (some local/syndicated reruns never carry one) — must still collapse via
    // the title-normalization fallback instead of showing one row per airing.
    @Test @MainActor func groupsBySeriesTitleWhenSeriesIDAbsent() async {
        let start = Int(Date().timeIntervalSince1970) + 3600
        let guideJSON = """
        [{"GuideNumber":"5.1","GuideName":"KVUE","Guide":[
            {"StartTime":\(start),"EndTime":\(start + 1800),"Title":"Local News"},
            {"StartTime":\(start + 1800),"EndTime":\(start + 3600),"Title":"Local News"}
        ]}]
        """
        let state = await makeState(guideJSON: guideJSON)
        let shows = await search("local news", state: state)
        #expect(shows.count == 1)
        #expect((shows.first?["airings"] as? [[String: Any]])?.count == 2)
    }

    @Test @MainActor func noMatchReturnsEmptyShows() async {
        let start = Int(Date().timeIntervalSince1970) + 3600
        let guideJSON = """
        [{"GuideNumber":"5.1","GuideName":"KVUE","Guide":[
            {"StartTime":\(start),"EndTime":\(start + 1800),"Title":"Jeopardy!"}
        ]}]
        """
        let state = await makeState(guideJSON: guideJSON)
        let shows = await search("zzqxvbnkjhgqwerty0987", state: state)
        #expect(shows.isEmpty)
    }

    // Defense-in-depth floor below guide.js's own 3-char client threshold — this LAN API has no
    // auth beyond subnet matching (CLAUDE.md), so the server never trusts the caller's own length
    // check. Also proves this short-circuits before ever touching guideStore (no match required).
    @Test @MainActor func queryBelowTwoCharFloorReturnsEmptyWithoutSearching() async {
        let guideJSON = #"[{"GuideNumber":"5.1","GuideName":"KVUE","Guide":[]}]"#
        let state = await makeState(guideJSON: guideJSON)
        let shows = await search("j", state: state)
        #expect(shows.isEmpty)
    }

    @Test @MainActor func resultsSortedAlphabeticallyByTitle() async {
        let start = Int(Date().timeIntervalSince1970) + 3600
        let guideJSON = """
        [{"GuideNumber":"5.1","GuideName":"KVUE","Guide":[
            {"StartTime":\(start),"EndTime":\(start + 1800),"Title":"Zoo Show","SeriesID":"z1"},
            {"StartTime":\(start + 1800),"EndTime":\(start + 3600),"Title":"Animal World","SeriesID":"a1"}
        ]}]
        """
        let state = await makeState(guideJSON: guideJSON)
        let shows = await search("o", state: state)
        let titles = shows.compactMap { $0["title"] as? String }
        #expect(titles == titles.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    // Search is per-tuner (mirrors the genre filter's own per-tuner scope, per this endpoint's own
    // doc comment) — a query matching a show on a *different* device must not surface it.
    @Test @MainActor func searchIsScopedToTheRequestedDeviceOnly() async {
        let start = Int(Date().timeIntervalSince1970) + 3600
        let guideJSON = """
        [{"GuideNumber":"5.1","GuideName":"KVUE","Guide":[
            {"StartTime":\(start),"EndTime":\(start + 1800),"Title":"Jeopardy!"}
        ]}]
        """
        let state = await makeState(deviceId: "AABBCCDD", guideJSON: guideJSON)
        let shows = await search("jeopardy", deviceId: "11119999", state: state)
        #expect(shows.isEmpty)
    }
}
