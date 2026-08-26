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

// Regression coverage for CLAUDE.md's "Web guide offline devices" invariant ("Never silently omit
// them") not being mirrored in this JSON endpoint — buildDevBarHTML (the web guide's own dev bar)
// already unions in a device referenced by a show's hdhr_record but absent from state.devices;
// buildGuideJSON didn't, so hdhr_guide's Tab/switchDevice() (which only ever iterates this
// endpoint's own devices list) had no way to even see, let alone manage, a show stuck on a tuner
// that's gone fully undetected.
@Suite("buildGuideJSON — offline devices referenced by a show are never silently omitted")
struct GuideJSONOfflineDeviceTests {

    @MainActor
    @Test func offlineDeviceStillListedInDevices() throws {
        let device = HDHRDevice(DeviceID: "AABBCCDD", LocalIP: "192.168.1.50",
                                 BaseURL: "http://192.168.1.50", TunerCount: 2,
                                 FirmwareVersion: nil, DeviceAuth: nil)
        var stuckShow = Show.blank(channel: "9.1", device: "OFFLINE01")
        stuckShow.show_active = true

        let state = makeTestAppState(shows: [stuckShow], devices: [device])

        let data = WebServer().buildGuideJSON(state: state, deviceId: "AABBCCDD")
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let devices = try #require(payload["devices"] as? [[String: Any]])
        let offlineEntry = devices.first { $0["deviceId"] as? String == "OFFLINE01" }
        #expect(offlineEntry != nil, "a device referenced by a show's hdhr_record must never be silently omitted from /api/guide.json's devices list")
        #expect(offlineEntry?["active"] as? Int == 0)
        #expect(offlineEntry?["total"] as? Int == 0)
    }

    @MainActor
    @Test func requestingTheOfflineDeviceReturnsItsOwnEmptyPayloadNotASubstitutedDevice() throws {
        let device = HDHRDevice(DeviceID: "AABBCCDD", LocalIP: "192.168.1.50",
                                 BaseURL: "http://192.168.1.50", TunerCount: 2,
                                 FirmwareVersion: nil, DeviceAuth: nil)
        var stuckShow = Show.blank(channel: "9.1", device: "OFFLINE01")
        stuckShow.show_active = true

        let state = makeTestAppState(shows: [stuckShow], devices: [device])

        // Must echo back the requested offline id, not silently substitute AABBCCDD's own guide —
        // that would show the wrong tuner's schedule with no indication a swap happened.
        let data = WebServer().buildGuideJSON(state: state, deviceId: "OFFLINE01")
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(payload["deviceId"] as? String == "OFFLINE01")
        #expect((payload["channels"] as? [[String: Any]])?.isEmpty == true)
    }

    @MainActor
    @Test func onlineOnlyDeviceIsUnaffected() throws {
        // No shows at all -> offlineIDs is empty -> devices list is exactly state.devices, same as
        // before this fix.
        let device = HDHRDevice(DeviceID: "AABBCCDD", LocalIP: "192.168.1.50",
                                 BaseURL: "http://192.168.1.50", TunerCount: 2,
                                 FirmwareVersion: nil, DeviceAuth: nil)
        let state = makeTestAppState(devices: [device])

        let data = WebServer().buildGuideJSON(state: state, deviceId: "AABBCCDD")
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let devices = try #require(payload["devices"] as? [[String: Any]])
        #expect(devices.count == 1)
        #expect(devices.first?["deviceId"] as? String == "AABBCCDD")
    }
}

private func HTTPResponse(url: URL) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
}
