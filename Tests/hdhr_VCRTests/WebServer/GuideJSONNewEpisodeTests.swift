import Testing
import Foundation
@testable import hdhr_VCR

// Regression coverage for /api/guide.json's isNew field — added so hdhr_guide (the bundled
// terminal client) can show the same green "NEW" title pill the web guide's .g-new-tag shows.
// Mirrors buildGuideGridHTML's own isNew computation (newEpisodeTest's shared closure factory):
// OriginalAirdate falls on the server's local "today".

private final class GuideJSONNewEpisodeMockURLProtocol: MockURLProtocolBase {
    private static var _handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { _handler }
        set { _handler = newValue }
    }
}

@Suite("buildGuideJSON — isNew mirrors the web guide's NEW-episode indicator")
struct GuideJSONNewEpisodeTests {

    @MainActor
    @Test func todaysOriginalAirdateIsFlaggedNew() async throws {
        let device = HDHRDevice(DeviceID: "AABBCCDD", LocalIP: "192.168.1.50",
                                 BaseURL: "http://192.168.1.50", TunerCount: 2,
                                 FirmwareVersion: nil, DeviceAuth: nil)
        let lineup = [LineupEntry(GuideNumber: "5.1", GuideName: "KVUE", URL: nil, HD: 1, Favorite: nil)]

        let now = Int(Date().timeIntervalSince1970)
        let start = now + 3600, end = now + 5400
        // Midnight UTC of "today" — always decodes to today's local calendar date regardless of
        // the CI machine's timezone offset from UTC (same reasoning as isNewEpisode's own doc
        // comment: OriginalAirdate is UTC midnight for the broadcast calendar date).
        let todayMidnightUTC = Int(Calendar(identifier: .gregorian).startOfDay(for: Date()).timeIntervalSince1970)
        let guideJSON = """
        [{"GuideNumber":"5.1","GuideName":"KVUE","Guide":[
            {"StartTime":\(start),"EndTime":\(end),"Title":"Brand New Episode","OriginalAirdate":\(todayMidnightUTC)},
            {"StartTime":\(start),"EndTime":\(end),"Title":"Old Rerun"}
        ]}]
        """
        let session = makeMockSession(GuideJSONNewEpisodeMockURLProtocol.self)
        GuideJSONNewEpisodeMockURLProtocol.requestHandler = { req in
            (mockOKResponse(for: req.url!), guideJSON.data(using: .utf8)!)
        }
        let guideStore = GuideStore(session: session)
        await guideStore.load(for: device)

        let state = makeTestAppState(devices: [device], lineups: ["AABBCCDD": lineup], guideStore: guideStore)

        let data = WebServer().buildGuideJSON(state: state, deviceId: "AABBCCDD")
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let channels = try #require(payload["channels"] as? [[String: Any]])
        let entries = try #require(channels.first?["entries"] as? [[String: Any]])

        let new = try #require(entries.first { $0["title"] as? String == "Brand New Episode" })
        let old = try #require(entries.first { $0["title"] as? String == "Old Rerun" })
        #expect(new["isNew"] as? Bool == true)
        #expect(old["isNew"] as? Bool == false, "an entry with no OriginalAirdate at all must never be flagged new")
    }
}
