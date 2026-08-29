import Testing
import Foundation
@testable import hdhr_VCR

// Dedicated mock URLProtocol + counter, following DiscordNotifierTests' pattern rather than
// reusing GuideStoreTests' own MockURLProtocol — that type's `requestHandler`/counter would be
// global mutable state shared across files, risking a cross-file race under Swift Testing's
// default parallel execution. Shared request-replay mechanics live in TestFixtures.swift's
// `MockURLProtocolBase`.
private final class FetchGuidesMockURLProtocol: MockURLProtocolBase {
    private static var _handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static var requestCount = 0

    override class var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { _handler }
        set { _handler = newValue }
    }
    override class func recordRequest() { requestCount += 1 }
}

private func makeFetchGuidesMockSession() -> URLSession { makeMockSession(FetchGuidesMockURLProtocol.self) }

private let minimalGuideJSON = """
[{"GuideNumber":"5.1","GuideName":"KVUE","Guide":[]}]
"""

// Regression coverage for the race a pre-release review found: AppState.startup(),
// idleLoop()'s no-devices-yet retry, and FirstRunWizardView.prefetchIntroArtIfNeeded() are three
// independent call sites that can all observe an empty guideByDevice at once on a slow/cold
// launch and each call fetchAllGuides() themselves, doubling the guide.php round trip.
// fetchAllGuides() now coalesces concurrent callers onto one in-flight Task
// (AppState.swift's fetchAllGuidesTask, mirroring ensureLineupLoaded's loadingLineupTasks idiom)
// — this asserts that coalescing actually happens, not just that it compiles.
@Suite("AppState.fetchAllGuides() coalescing", .serialized)
struct AppStateFetchGuidesCoalescingTests {
    @Test @MainActor func concurrentCallers_shareOneInFlightFetchPerDevice() async {
        FetchGuidesMockURLProtocol.requestCount = 0
        FetchGuidesMockURLProtocol.requestHandler = { req in
            (mockOKResponse(for: req.url!), Data(minimalGuideJSON.utf8))
        }
        let device = HDHRDevice(DeviceID: "AABBCCDD", LocalIP: "192.168.1.50",
                                 BaseURL: "http://192.168.1.50", TunerCount: 2,
                                 FirmwareVersion: nil, DeviceAuth: nil)
        let guideStore = GuideStore(session: makeFetchGuidesMockSession())
        let state = makeTestAppState(devices: [device], guideStore: guideStore)

        async let first: Void = state.fetchAllGuides()
        async let second: Void = state.fetchAllGuides()
        _ = await (first, second)

        #expect(FetchGuidesMockURLProtocol.requestCount == 1,
                "expected two concurrent fetchAllGuides() callers to coalesce onto one network fetch, got \(FetchGuidesMockURLProtocol.requestCount)")
        #expect(state.guideByDevice[device.DeviceID]?.count == 1)
    }

    // A caller that arrives *after* the in-flight fetch has already completed must still get a
    // fresh fetch of its own — coalescing should only skip a truly concurrent second call, never
    // suppress every call after the first for the rest of the app's lifetime.
    @Test @MainActor func sequentialCallers_eachGetTheirOwnFetch() async {
        FetchGuidesMockURLProtocol.requestCount = 0
        FetchGuidesMockURLProtocol.requestHandler = { req in
            (mockOKResponse(for: req.url!), Data(minimalGuideJSON.utf8))
        }
        let device = HDHRDevice(DeviceID: "AABBCCDD", LocalIP: "192.168.1.50",
                                 BaseURL: "http://192.168.1.50", TunerCount: 2,
                                 FirmwareVersion: nil, DeviceAuth: nil)
        let guideStore = GuideStore(session: makeFetchGuidesMockSession())
        let state = makeTestAppState(devices: [device], guideStore: guideStore)

        await state.fetchAllGuides()
        await state.fetchAllGuides()

        #expect(FetchGuidesMockURLProtocol.requestCount == 2,
                "sequential (non-overlapping) fetchAllGuides() calls should each hit the network, got \(FetchGuidesMockURLProtocol.requestCount)")
    }
}
