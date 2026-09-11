import Testing
import Foundation
@testable import hdhr_VCR

// MARK: - resolveSeriesAir tier order (TODO.md's "AppState's recording-scheduling engine" gap)
//
// resolveSeriesAir is a separate function from scheduleNextAir — called once, from the Add Show
// flow (applyGuideEntry), to seed a brand-new SeriesID(Channel)/SeriesID(All) show's initial
// show_next/show_end/show_channel/hdhr_record — not on every idle-loop tick the way
// scheduleNextAir is. It has its own copy of the same four-tier lookup order (currentEpisode →
// currentEntryByTitle → nextEpisode → nextEntryByTitle — note currentEntryByTitle is tier 2 here,
// not tier 3 like scheduleNextAir's own ordering) and its own channel-scoping rule (chFilter nil
// for seriesAll, pinned for seriesChannel). Unlike scheduleNextAir, a total no-match leaves `show`
// completely untouched (no retry-bump fallback) — whatever the caller already set on it (the
// guide entry the user picked when adding the show) simply stands. Mirrors
// AppStateSeriesSchedulingTests.swift's makeStateWithGuide seam (pre-loaded mocked GuideStore, so
// isFresh is already true and no per-test URLProtocol juggling around a guide-fetch is needed) —
// resolveSeriesAir itself never fetches a guide, so that part matters less here, but reusing the
// same fixture shape keeps the two suites easy to compare.

private final class ResolveSeriesAirMockURLProtocol: MockURLProtocolBase {
    private static var _handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { _handler }
        set { _handler = newValue }
    }
}

@Suite("AppState.resolveSeriesAir tier order", .serialized)
struct AppStateResolveSeriesAirTests {

    private func makeSeriesShow(all: Bool, channel: String, device: String) -> Show {
        var s = Show.blank(channel: channel, device: device)
        s.show_title = "Tier Order Show"
        s.show_active = true
        s.show_is_series = true
        s.show_use_seriesid = !all
        s.show_use_seriesid_all = all
        s.show_seriesid = "series123"
        s.show_length = 30
        // Distinguishable from any real match's start time below, so a no-match case (show left
        // untouched) is unambiguous.
        s.show_next = Date().addingTimeInterval(-999_999)
        s.show_end  = Date().addingTimeInterval(-999_998)
        return s
    }

    @MainActor
    private func makeStateWithGuide(show: Show, device: HDHRDevice, json: String) async -> AppState {
        let guideStore = GuideStore(session: makeMockSession(ResolveSeriesAirMockURLProtocol.self))
        ResolveSeriesAirMockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             json.data(using: .utf8)!)
        }
        await guideStore.load(for: device)
        #expect(guideStore.isFresh(deviceId: device.DeviceID))
        return makeTestAppState(shows: [show], devices: [device], guideStore: guideStore)
    }

    @Test @MainActor func seriesChannel_prefersCurrentlyAiringOverFutureEpisode() async {
        let device = HDHRDevice.test(id: "AABBCCDD", tuners: 2)
        var show = makeSeriesShow(all: false, channel: "5.1", device: device.DeviceID)
        let now = Int(Date().timeIntervalSince1970)
        let json = """
        [{"GuideNumber":"5.1","GuideName":"Test Channel","Guide":[
            {"StartTime":\(now - 300),"EndTime":\(now + 300),"Title":"Tier Order Show","SeriesID":"series123","EpisodeTitle":"On Air"},
            {"StartTime":\(now + 3600),"EndTime":\(now + 5400),"Title":"Tier Order Show","SeriesID":"series123","EpisodeTitle":"Future"}
        ]}]
        """
        let state = await makeStateWithGuide(show: show, device: device, json: json)
        let channel = LineupEntry.test(number: "5.1", name: "Test Channel")

        state.resolveSeriesAir(show: &show, device: device, isAll: false, channel: channel)

        #expect(show.show_next?.timeIntervalSince1970 == Double(now - 300))
        #expect(show.show_end?.timeIntervalSince1970 == Double(now + 300))
        #expect(show.show_channel == "5.1")
    }

    @Test @MainActor func seriesChannel_fallsBackToTitleMatchBeforeFutureEpisode() async {
        // resolveSeriesAir's own tier order puts currentEntryByTitle *ahead* of nextEpisode
        // (unlike scheduleNextAir's ordering) — a currently-airing, SeriesID-less entry must win
        // over a real future SeriesID match, not the other way around.
        let device = HDHRDevice.test(id: "AABBCCDD", tuners: 2)
        var show = makeSeriesShow(all: false, channel: "5.1", device: device.DeviceID)
        let now = Int(Date().timeIntervalSince1970)
        let json = """
        [{"GuideNumber":"5.1","GuideName":"Test Channel","Guide":[
            {"StartTime":\(now - 300),"EndTime":\(now + 300),"Title":"Tier Order Show"},
            {"StartTime":\(now + 3600),"EndTime":\(now + 5400),"Title":"Tier Order Show","SeriesID":"series123"}
        ]}]
        """
        let state = await makeStateWithGuide(show: show, device: device, json: json)
        let channel = LineupEntry.test(number: "5.1", name: "Test Channel")

        state.resolveSeriesAir(show: &show, device: device, isAll: false, channel: channel)

        #expect(show.show_next?.timeIntervalSince1970 == Double(now - 300))
    }

    @Test @MainActor func seriesChannel_fallsBackToNextEpisodeWhenNoneCurrentlyAiring() async {
        let device = HDHRDevice.test(id: "AABBCCDD", tuners: 2)
        var show = makeSeriesShow(all: false, channel: "5.1", device: device.DeviceID)
        let futureStart = Int(Date().addingTimeInterval(3600).timeIntervalSince1970)
        let futureEnd   = futureStart + 1800
        let json = """
        [{"GuideNumber":"5.1","GuideName":"Test Channel","Guide":[
            {"StartTime":\(futureStart),"EndTime":\(futureEnd),"Title":"Tier Order Show","SeriesID":"series123"}
        ]}]
        """
        let state = await makeStateWithGuide(show: show, device: device, json: json)
        let channel = LineupEntry.test(number: "5.1", name: "Test Channel")

        state.resolveSeriesAir(show: &show, device: device, isAll: false, channel: channel)

        #expect(show.show_next?.timeIntervalSince1970 == Double(futureStart))
    }

    @Test @MainActor func seriesChannel_fallsBackToNextEntryByTitleAsLastResort() async {
        let device = HDHRDevice.test(id: "AABBCCDD", tuners: 2)
        var show = makeSeriesShow(all: false, channel: "5.1", device: device.DeviceID)
        let futureStart = Int(Date().addingTimeInterval(3600).timeIntervalSince1970)
        let futureEnd   = futureStart + 1800
        let json = """
        [{"GuideNumber":"5.1","GuideName":"Test Channel","Guide":[
            {"StartTime":\(futureStart),"EndTime":\(futureEnd),"Title":"Tier Order Show"}
        ]}]
        """
        let state = await makeStateWithGuide(show: show, device: device, json: json)
        let channel = LineupEntry.test(number: "5.1", name: "Test Channel")

        state.resolveSeriesAir(show: &show, device: device, isAll: false, channel: channel)

        #expect(show.show_next?.timeIntervalSince1970 == Double(futureStart))
    }

    @Test @MainActor func seriesChannel_noMatchAnywhere_leavesShowCompletelyUnchanged() async {
        // Unlike scheduleNextAir, resolveSeriesAir has no retry-bump fallback — a total no-match
        // is a silent no-op, since applyGuideEntry (the only caller) has already set show_next/
        // show_end from the guide entry the user picked before this ever runs.
        let device = HDHRDevice.test(id: "AABBCCDD", tuners: 2)
        var show = makeSeriesShow(all: false, channel: "5.1", device: device.DeviceID)
        let sentinelNext = show.show_next
        let sentinelEnd  = show.show_end
        let json = """
        [{"GuideNumber":"5.1","GuideName":"Test Channel","Guide":[
            {"StartTime":\(Int(Date().timeIntervalSince1970) + 3600),"EndTime":\(Int(Date().timeIntervalSince1970) + 5400),"Title":"Unrelated Show","SeriesID":"other999"}
        ]}]
        """
        let state = await makeStateWithGuide(show: show, device: device, json: json)
        let channel = LineupEntry.test(number: "5.1", name: "Test Channel")

        state.resolveSeriesAir(show: &show, device: device, isAll: false, channel: channel)

        #expect(show.show_next == sentinelNext)
        #expect(show.show_end == sentinelEnd)
        #expect(show.show_channel == "5.1")
    }

    @Test @MainActor func seriesChannel_neverMatchesOnADifferentChannel() async {
        let device = HDHRDevice.test(id: "AABBCCDD", tuners: 2)
        var show = makeSeriesShow(all: false, channel: "5.1", device: device.DeviceID)
        let sentinelNext = show.show_next
        let now = Int(Date().timeIntervalSince1970)
        // A real match exists, but on 9.1 — seriesChannel must stay pinned to 5.1 and not follow it.
        let json = """
        [{"GuideNumber":"9.1","GuideName":"Other Channel","Guide":[
            {"StartTime":\(now - 300),"EndTime":\(now + 300),"Title":"Tier Order Show","SeriesID":"series123"}
        ]}]
        """
        let state = await makeStateWithGuide(show: show, device: device, json: json)
        let channel = LineupEntry.test(number: "5.1", name: "Test Channel")

        state.resolveSeriesAir(show: &show, device: device, isAll: false, channel: channel)

        #expect(show.show_next == sentinelNext)
        #expect(show.show_channel == "5.1")
    }

    @Test @MainActor func seriesAll_matchesAcrossChannelsOnSameDevice() async {
        let device = HDHRDevice.test(id: "AABBCCDD", tuners: 2)
        // Identical guide content to the seriesChannel cross-channel test above, but seriesAll —
        // the only difference between the two types is channel scope, so this one must match and
        // follow show_channel to 9.1.
        var show = makeSeriesShow(all: true, channel: "5.1", device: device.DeviceID)
        let now = Int(Date().timeIntervalSince1970)
        let json = """
        [{"GuideNumber":"9.1","GuideName":"Other Channel","Guide":[
            {"StartTime":\(now - 300),"EndTime":\(now + 300),"Title":"Tier Order Show","SeriesID":"series123"}
        ]}]
        """
        let state = await makeStateWithGuide(show: show, device: device, json: json)
        let channel = LineupEntry.test(number: "5.1", name: "Test Channel")

        state.resolveSeriesAir(show: &show, device: device, isAll: true, channel: channel)

        #expect(show.show_next?.timeIntervalSince1970 == Double(now - 300))
        #expect(show.show_channel == "9.1")
        // Device scope is still pinned — seriesAll only widens channel scope, never device scope.
        #expect(show.hdhr_record == device.DeviceID)
    }
}
