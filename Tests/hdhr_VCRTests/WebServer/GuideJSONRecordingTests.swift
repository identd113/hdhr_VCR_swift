import Testing
import Foundation
@testable import hdhr_VCR

// Regression coverage for the /api/guide.json isRecording bug: buildGuideJSON used to flag every
// entry on a recording channel as isRecording (a bare device+channel membership check against
// recordingShows, applied to every entry in the whole guide window), not just the one actually on
// air — so a channel with an active recording showed its entire future schedule as "recording" in
// hdhr_guide. Fixed by requiring the entry's own time span to cover *now*, same as
// buildGuideGridHTML's isEntryRec = isRecCh && isNow.

private final class GuideJSONMockURLProtocol: MockURLProtocolBase {
    private static var _handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { _handler }
        set { _handler = newValue }
    }
}

@Suite("buildGuideJSON — isRecording scoped to the on-air entry only")
struct GuideJSONRecordingTests {

    @MainActor
    @Test func onlyOnAirEntryIsFlaggedRecording() async throws {
        let device = HDHRDevice(DeviceID: "AABBCCDD", LocalIP: "192.168.1.50",
                                 BaseURL: "http://192.168.1.50", TunerCount: 2,
                                 FirmwareVersion: nil, DeviceAuth: nil)
        let lineup = [LineupEntry(GuideNumber: "5.1", GuideName: "KVUE", URL: nil, HD: 1, Favorite: nil)]

        let now = Int(Date().timeIntervalSince1970)
        let onAirStart = now - 600, onAirEnd = now + 600
        let futureStart = now + 3600, futureEnd = now + 7200
        let guideJSON = """
        [{"GuideNumber":"5.1","GuideName":"KVUE","Guide":[
            {"StartTime":\(onAirStart),"EndTime":\(onAirEnd),"Title":"On Air Now"},
            {"StartTime":\(futureStart),"EndTime":\(futureEnd),"Title":"Not Started Yet"}
        ]}]
        """
        let session = makeMockSession(GuideJSONMockURLProtocol.self)
        GuideJSONMockURLProtocol.requestHandler = { req in
            (HTTPResponse(url: req.url!), guideJSON.data(using: .utf8)!)
        }
        let guideStore = GuideStore(session: session)
        await guideStore.load(for: device)

        var recordingShow = Show.blank(channel: "5.1", device: "AABBCCDD")
        recordingShow.show_recording = true
        recordingShow.show_end = Date(timeIntervalSince1970: TimeInterval(onAirEnd))

        let state = makeTestAppState(shows: [recordingShow], devices: [device],
                                      lineups: ["AABBCCDD": lineup], guideStore: guideStore)

        let data = WebServer().buildGuideJSON(state: state, deviceId: "AABBCCDD")
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let channels = try #require(payload["channels"] as? [[String: Any]])
        let entries = try #require(channels.first?["entries"] as? [[String: Any]])
        #expect(entries.count == 2)

        let onAir = try #require(entries.first { $0["title"] as? String == "On Air Now" })
        let future = try #require(entries.first { $0["title"] as? String == "Not Started Yet" })
        #expect(onAir["isRecording"] as? Bool == true)
        #expect(future["isRecording"] as? Bool == false)
    }
}

private func HTTPResponse(url: URL) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
}
