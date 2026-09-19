import Testing
import Foundation
@testable import hdhr_VCR

// Own MockURLProtocol subclass — shared request-replay mechanics live in TestFixtures.swift's
// MockURLProtocolBase; a distinct static-storage type per file avoids a cross-file race under
// Swift Testing's default parallel execution (same reasoning as
// AppStateFetchGuidesCoalescingTests/GuideStoreTests).
private final class AllChannelsMockURLProtocol: MockURLProtocolBase {
    private static var _handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { _handler }
        set { _handler = newValue }
    }
}

private func makeAllChannelsMockSession() -> URLSession { makeMockSession(AllChannelsMockURLProtocol.self) }

// Regression coverage for AppState.allChannels(for:at:), added 2026-09-19 alongside
// PiPPickerView's "Live TV" section — the sibling of onAirNow(for:at:) that does NOT drop a
// channel just because it has no guide entry airing right now (see AppState.swift's own doc
// comment on why: PiPPickerView needs to offer every tunable channel as a PiP secondary, not just
// what the EPG happens to cover this minute). Real bug this replaced: PiPPickerView silently
// couldn't offer a channel with stale/missing guide data at all.
@Suite("AppState.allChannels(for:at:)")
struct AppStateAllChannelsTests {

    private func makeDevice(id: String = "AABBCCDD") -> HDHRDevice {
        HDHRDevice(DeviceID: id, LocalIP: "192.168.1.100", BaseURL: "http://192.168.1.100",
                   TunerCount: 2, FirmwareVersion: nil, DeviceAuth: nil)
    }

    // Channel 5.1 has a currently-on-air entry; channel 7.1 has a Guide entry that's already over
    // (representative of stale/missing EPG coverage for "right now") — the exact shape onAirNow
    // drops and allChannels must not.
    private func loadGuide(into guideStore: GuideStore, device: HDHRDevice) async {
        let now = Int(Date().timeIntervalSince1970)
        let json = """
        [
            {"GuideNumber":"5.1","GuideName":"KVUE","Guide":[
                {"StartTime":\(now - 300),"EndTime":\(now + 1500),"Title":"On Air Now"}
            ]},
            {"GuideNumber":"7.1","GuideName":"KXYZ","Guide":[
                {"StartTime":\(now - 7200),"EndTime":\(now - 3600),"Title":"Long Over"}
            ]}
        ]
        """
        AllChannelsMockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
        }
        _ = await guideStore.load(for: device)
    }

    @Test @MainActor func includesAChannelWithNoCurrentGuideEntry() async {
        let device = makeDevice()
        let guideStore = GuideStore(session: makeAllChannelsMockSession())
        await loadGuide(into: guideStore, device: device)
        let state = makeTestAppState(
            devices: [device],
            lineups: [device.DeviceID: [.test(number: "5.1", name: "KVUE"), .test(number: "7.1", name: "KXYZ")]],
            guideStore: guideStore)

        let result = state.allChannels(for: device, at: Date())

        #expect(result.count == 2, "both channels must appear even though only 5.1 has a current entry")
        let byNumber = Dictionary(uniqueKeysWithValues: result.map { ($0.channel.GuideNumber, $0.entry) })
        #expect(byNumber["5.1"]??.Title == "On Air Now")
        #expect(byNumber["7.1"] != nil, "7.1 must still be present")
        #expect((byNumber["7.1"] ?? nil) == nil, "7.1's entry must be nil — its only Guide entry already ended")
    }

    @Test @MainActor func onAirNowExcludesTheSameChannelAllChannelsIncludes() async {
        // Direct regression proof this is a real behavioral difference, not just two ways of
        // saying the same thing — onAirNow is the pre-existing function allChannels was added
        // alongside, deliberately left with its original "only what's airing" semantics.
        let device = makeDevice()
        let guideStore = GuideStore(session: makeAllChannelsMockSession())
        await loadGuide(into: guideStore, device: device)
        let state = makeTestAppState(
            devices: [device],
            lineups: [device.DeviceID: [.test(number: "5.1", name: "KVUE"), .test(number: "7.1", name: "KXYZ")]],
            guideStore: guideStore)

        let onAir = state.onAirNow(for: device, at: Date())
        let all   = state.allChannels(for: device, at: Date())

        #expect(onAir.map(\.channel.GuideNumber) == ["5.1"])
        #expect(Set(all.map(\.channel.GuideNumber)) == Set(["5.1", "7.1"]))
    }

    @Test @MainActor func sortsFavoritesFirstRegardlessOfCurrentEntry() async {
        // 7.1 (favorite, no current entry) must still sort ahead of 5.1 (not favorite, on air) —
        // favorite status is the primary sort key, matching onAirNow's own documented ordering.
        let device = makeDevice()
        let guideStore = GuideStore(session: makeAllChannelsMockSession())
        await loadGuide(into: guideStore, device: device)
        let state = makeTestAppState(
            devices: [device],
            lineups: [device.DeviceID: [.test(number: "5.1", name: "KVUE"),
                                         .test(number: "7.1", name: "KXYZ", favorite: true)]],
            guideStore: guideStore)

        let result = state.allChannels(for: device, at: Date())
        #expect(result.map(\.channel.GuideNumber) == ["7.1", "5.1"])
    }

    @Test @MainActor func dedupsRepeatedGuideNumbers() async {
        let device = makeDevice()
        let guideStore = GuideStore(session: makeAllChannelsMockSession())
        await loadGuide(into: guideStore, device: device)
        let state = makeTestAppState(
            devices: [device],
            lineups: [device.DeviceID: [.test(number: "5.1", name: "KVUE"), .test(number: "5.1", name: "KVUE Dup")]],
            guideStore: guideStore)

        let result = state.allChannels(for: device, at: Date())
        #expect(result.count == 1)
    }

    @Test @MainActor func emptyLineup_returnsEmpty() async {
        let device = makeDevice()
        let state = makeTestAppState(devices: [device], lineups: [:])
        #expect(state.allChannels(for: device, at: Date()).isEmpty)
    }

    @Test @MainActor func unknownDevice_returnsEmpty() async {
        let device = makeDevice()
        let state = makeTestAppState(devices: [device],
                                      lineups: [device.DeviceID: [.test(number: "5.1")]])
        #expect(state.allChannels(for: HDHRDevice(DeviceID: "NOPE", LocalIP: "0.0.0.0", BaseURL: "http://0.0.0.0",
                                                   TunerCount: 2, FirmwareVersion: nil, DeviceAuth: nil),
                                   at: Date()).isEmpty)
    }
}
