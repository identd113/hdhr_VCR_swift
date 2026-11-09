import Foundation
import Testing
@testable import hdhr_VCR

// With no browser connected (no SSE client) a guide-changing event must not pay for the grid, page and gzip rebuild; it marks the caches
// stale and the next request that reads them rebuilds. A connected observer (what a browser is, as far as the broadcast is concerned) keeps
// the eager push.

@MainActor
struct LazyPageCacheTests {
    @Test func noClientMeansNoRebuildUntilARequestReadsTheCaches() {
        let state = makeTestAppState()
        let web = WebServer()
        #expect(!state.guidePageCacheWarm)
        web.broadcastGuideChangeEvent(type: "guide_refreshed", state: state)
        #expect(!state.guidePageCacheWarm)                      // nothing was built
        web.refreshCachesIfGuideWindowMoved(state: state)       // what GET / and /api/guide.json do first
        #expect(state.guidePageCacheWarm)
    }

    @Test func aWatchingClientKeepsTheEagerRebuild() {
        let state = makeTestAppState()
        let web = WebServer()
        var seen: [String] = []
        web.broadcastObserver = { seen.append($0["type"] as? String ?? "") }
        web.broadcastGuideChangeEvent(type: "guide_refreshed", state: state)
        #expect(seen == ["guide_refreshed"])
        #expect(state.guidePageCacheWarm)
    }

    @Test func deviceBarAndRecordingEventsAlsoDefer() {
        let state = makeTestAppState()
        let web = WebServer()
        web.broadcastDeviceBarEvent(type: "device_offline", deviceId: "DEV", state: state)
        web.broadcastRecordingEvent(type: "recording_started", channel: "5.1", device: "DEV", state: state)
        #expect(!state.guidePageCacheWarm)
        web.refreshCachesIfGuideWindowMoved(state: state)
        #expect(state.guidePageCacheWarm)
    }
}
