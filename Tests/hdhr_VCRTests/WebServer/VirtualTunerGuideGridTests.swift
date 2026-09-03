import Testing
import Foundation
@testable import hdhr_VCR

// Regression coverage for buildGuideGridHTML's device-enumeration loop excluding a discovered
// virtual relay device (VirtualTunerService.swift) — a relay's synthetic lineup entry can carry
// the SAME channel number as the real channel it's relaying (buildVirtualTunerLineupJSON copies
// GuideNumber verbatim), so an unfiltered loop here would iterate the relay device too. In
// practice entriesInWindow's own `guard !entries.isEmpty` (fed by GuideStore.entries(deviceId:
// channelNum:), keyed strictly by "deviceId:channelNum" with no cross-device fallback) already
// prevents a row from rendering for a device with no real guide data — a relay's guide fetch is
// deliberately skipped (see AppState.performFetchAllGuides) so channelEntryIndex never has an
// entry for it — but the device-loop filter is kept as defense in depth and for consistency with
// every other device-enumeration site in this feature (docs/VirtualTunerService.md).

private final class VirtualTunerGuideGridMockURLProtocol: MockURLProtocolBase {
    private static var _handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { _handler }
        set { _handler = newValue }
    }
}

@Suite("buildGuideGridHTML — virtual relay device exclusion")
struct VirtualTunerGuideGridTests {

    @MainActor
    @Test func relayDeviceSharingARealChannelNumberNeverProducesItsOwnRow() async throws {
        let realDevice = HDHRDevice(DeviceID: "AABBCCDD", LocalIP: "192.168.1.50",
                                     BaseURL: "http://192.168.1.50", TunerCount: 2,
                                     FirmwareVersion: nil, DeviceAuth: nil)
        let relayDevice = HDHRDevice.test(id: "FEED9999", isVirtualRelay: true)

        let now = Int(Date().timeIntervalSince1970)
        let start = now - 300, end = now + 1500
        let guideJSON = """
        [{"GuideNumber":"5.1","GuideName":"KVUE","Guide":[
            {"StartTime":\(start),"EndTime":\(end),"Title":"Real Channel's Own Show"}
        ]}]
        """
        let session = makeMockSession(VirtualTunerGuideGridMockURLProtocol.self)
        VirtualTunerGuideGridMockURLProtocol.requestHandler = { req in
            (mockOKResponse(for: req.url!), guideJSON.data(using: .utf8)!)
        }
        let guideStore = GuideStore(session: session)
        await guideStore.load(for: realDevice)   // relayDevice deliberately never loaded — no
                                                  // guide fetch is ever attempted for it in production.

        // Same channel number "5.1" on both devices — the collision buildVirtualTunerLineupJSON's
        // own `dev=` disambiguation exists to handle on the streaming side; this test covers the
        // guide-grid rendering side.
        let realLineup  = [LineupEntry.test(number: "5.1", name: "KVUE")]
        let relayLineup = [LineupEntry.test(number: "5.1", name: "KVUE", showTitle: "Recording On Other Mac")]

        let state = makeTestAppState(devices: [realDevice, relayDevice],
                                      lineups: ["AABBCCDD": realLineup, "FEED9999": relayLineup],
                                      guideStore: guideStore)

        let html = WebServer().buildGuideGridHTML(state: state)
        #expect(html.contains(#"data-dev="AABBCCDD""#))
        #expect(html.contains(#"data-ch="5.1""#))
        #expect(!html.contains(#"data-dev="FEED9999""#))
    }
}
