import Testing
import Foundation
@testable import hdhr_VCR

// MARK: - scheduleNextAir series-scheduling tier order
//
// `scheduleNextAir`'s .seriesChannel/.seriesAll branch tries four guide lookups in a fixed order
// before giving up and retrying later — see AppState.swift's own comments there: currentEpisode
// (SeriesID, on-air now) → nextEpisode (SeriesID, future) → currentEntryByTitle (title, on-air) →
// nextEntryByTitle (title, future) → no match (bump show_next by Series_scan_retry_hours). The
// underlying GuideStore lookups already have direct coverage via GuideStoreTests; what was
// untested was scheduleNextAir's own orchestration — which tier wins when more than one could
// match, and that seriesChannel vs. seriesAll differ only in channel scope. Uses the same
// injectable-guideStore seam AppStateIdleLoopStaleIndexTests.swift introduced, but pre-loads the
// guide via a direct mocked `guideStore.load(for:)` call before constructing AppState — since
// `isFresh` is then already true, `scheduleNextAir` never re-enters its own guide-fetch branch,
// so no per-test URLProtocol handler juggling is needed the way the stale-index tests require.

private final class SeriesSchedulingMockURLProtocol: MockURLProtocolBase {
    private static var _handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { _handler }
        set { _handler = newValue }
    }
}

@Suite("AppState scheduleNextAir series tier order", .serialized)
struct AppStateSeriesSchedulingTests {

    private func makeSeriesShow(all: Bool, channel: String, device: String) -> Show {
        var s = Show.blank(channel: channel, device: device)
        s.show_title = "Tier Order Show"
        s.show_active = true
        s.show_is_series = true
        s.show_use_seriesid = !all
        s.show_use_seriesid_all = all
        s.show_seriesid = "series123"
        s.show_length = 30
        // Starts stale-in-the-past so a no-match fallback is clearly distinguishable from
        // "already future, leave unchanged" in the no-match test below.
        s.show_next = Date().addingTimeInterval(-600)
        s.show_end  = Date().addingTimeInterval(-300)
        return s
    }

    // Loads `json` into a fresh GuideStore via the mocked session, then hands it to a fresh
    // AppState — isFresh is true immediately afterward, so scheduleNextAir uses it as-is.
    @MainActor
    private func makeStateWithGuide(show: Show, device: HDHRDevice, json: String) async -> AppState {
        let guideStore = GuideStore(session: makeMockSession(SeriesSchedulingMockURLProtocol.self))
        SeriesSchedulingMockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             json.data(using: .utf8)!)
        }
        await guideStore.load(for: device)
        #expect(guideStore.isFresh(deviceId: device.DeviceID))
        return makeTestAppState(shows: [show], devices: [device], guideStore: guideStore)
    }

    @Test @MainActor func seriesChannel_prefersCurrentlyAiringOverFutureEpisode() async {
        let device = HDHRDevice.test(id: "AABBCCDD", tuners: 2)
        let show = makeSeriesShow(all: false, channel: "5.1", device: device.DeviceID)
        let now = Int(Date().timeIntervalSince1970)
        let json = """
        [{"GuideNumber":"5.1","GuideName":"Test Channel","Guide":[
            {"StartTime":\(now - 300),"EndTime":\(now + 300),"Title":"Tier Order Show","SeriesID":"series123","EpisodeTitle":"On Air"},
            {"StartTime":\(now + 3600),"EndTime":\(now + 5400),"Title":"Tier Order Show","SeriesID":"series123","EpisodeTitle":"Future"}
        ]}]
        """
        let state = await makeStateWithGuide(show: show, device: device, json: json)

        await state.scheduleNextAir(index: 0)

        let updated = state.shows[0]
        #expect(updated.show_next?.timeIntervalSince1970 == Double(now - 300))
        #expect(updated.show_end?.timeIntervalSince1970 == Double(now + 300))
    }

    @Test @MainActor func seriesChannel_fallsBackToNextEpisodeWhenNoneCurrentlyAiring() async {
        let device = HDHRDevice.test(id: "AABBCCDD", tuners: 2)
        let show = makeSeriesShow(all: false, channel: "5.1", device: device.DeviceID)
        let futureStart = Int(Date().addingTimeInterval(3600).timeIntervalSince1970)
        let futureEnd   = futureStart + 1800
        let json = """
        [{"GuideNumber":"5.1","GuideName":"Test Channel","Guide":[
            {"StartTime":\(futureStart),"EndTime":\(futureEnd),"Title":"Tier Order Show","SeriesID":"series123"}
        ]}]
        """
        let state = await makeStateWithGuide(show: show, device: device, json: json)

        await state.scheduleNextAir(index: 0)

        #expect(state.shows[0].show_next?.timeIntervalSince1970 == Double(futureStart))
    }

    @Test @MainActor func seriesChannel_fallsBackToTitleMatchWhenSeriesIDAbsentFromGuide() async {
        let device = HDHRDevice.test(id: "AABBCCDD", tuners: 2)
        // The show's own SeriesID is set, but the guide provider's entry for this airing carries
        // no SeriesID at all (a real-world crosswalk gap) — currentEpisode/nextEpisode can never
        // match, so the title-based tiers are what's actually being exercised here.
        let show = makeSeriesShow(all: false, channel: "5.1", device: device.DeviceID)
        let now = Int(Date().timeIntervalSince1970)
        let json = """
        [{"GuideNumber":"5.1","GuideName":"Test Channel","Guide":[
            {"StartTime":\(now - 300),"EndTime":\(now + 300),"Title":"Tier Order Show"}
        ]}]
        """
        let state = await makeStateWithGuide(show: show, device: device, json: json)

        await state.scheduleNextAir(index: 0)

        #expect(state.shows[0].show_next?.timeIntervalSince1970 == Double(now - 300))
    }

    @Test @MainActor func seriesChannel_fallsBackToNextEntryByTitleAsLastResort() async {
        let device = HDHRDevice.test(id: "AABBCCDD", tuners: 2)
        let show = makeSeriesShow(all: false, channel: "5.1", device: device.DeviceID)
        let futureStart = Int(Date().addingTimeInterval(3600).timeIntervalSince1970)
        let futureEnd   = futureStart + 1800
        let json = """
        [{"GuideNumber":"5.1","GuideName":"Test Channel","Guide":[
            {"StartTime":\(futureStart),"EndTime":\(futureEnd),"Title":"Tier Order Show"}
        ]}]
        """
        let state = await makeStateWithGuide(show: show, device: device, json: json)

        await state.scheduleNextAir(index: 0)

        #expect(state.shows[0].show_next?.timeIntervalSince1970 == Double(futureStart))
    }

    @Test @MainActor func seriesChannel_noMatchAnywhere_bumpsShowNextByRetryHoursAndResyncsEnd() async {
        let device = HDHRDevice.test(id: "AABBCCDD", tuners: 2)
        let show = makeSeriesShow(all: false, channel: "5.1", device: device.DeviceID)
        let json = """
        [{"GuideNumber":"5.1","GuideName":"Test Channel","Guide":[
            {"StartTime":\(Int(Date().timeIntervalSince1970) + 3600),"EndTime":\(Int(Date().timeIntervalSince1970) + 5400),"Title":"Unrelated Show","SeriesID":"other999"}
        ]}]
        """
        let state = await makeStateWithGuide(show: show, device: device, json: json)
        let retryHours = state.config.Series_scan_retry_hours

        await state.scheduleNextAir(index: 0)

        let updated = state.shows[0]
        let expected = Date().addingTimeInterval(Double(retryHours) * 3600)
        #expect(abs((updated.show_next ?? .distantPast).timeIntervalSince(expected)) < 5)
        // show_end re-syncs to the bumped show_next + show_length even though no real match was
        // found — otherwise it stays stuck at the pre-test stale value set in makeSeriesShow.
        let expectedEnd = (updated.show_next ?? .distantPast).addingTimeInterval(Double(show.show_length) * 60)
        #expect(updated.show_end == expectedEnd)
    }

    @Test @MainActor func seriesChannel_neverMatchesOnADifferentChannel() async {
        let device = HDHRDevice.test(id: "AABBCCDD", tuners: 2)
        // Assigned to channel 5.1, but the only matching episode in the guide airs on 9.1 —
        // seriesChannel must not follow it there (CLAUDE.md: "Neither type can ever match/record
        // on more than one tuner" — and seriesChannel specifically stays pinned to one channel).
        let show = makeSeriesShow(all: false, channel: "5.1", device: device.DeviceID)
        let now = Int(Date().timeIntervalSince1970)
        let json = """
        [{"GuideNumber":"9.1","GuideName":"Other Channel","Guide":[
            {"StartTime":\(now - 300),"EndTime":\(now + 300),"Title":"Tier Order Show","SeriesID":"series123"}
        ]}]
        """
        let state = await makeStateWithGuide(show: show, device: device, json: json)
        let retryHours = state.config.Series_scan_retry_hours

        await state.scheduleNextAir(index: 0)

        // No match found on 5.1 despite a real match existing on 9.1 — falls through to the
        // retry-bump fallback exactly like the "no match anywhere" case above, and show_channel
        // is left untouched (never silently reassigned to 9.1).
        let updated = state.shows[0]
        let expected = Date().addingTimeInterval(Double(retryHours) * 3600)
        #expect(abs((updated.show_next ?? .distantPast).timeIntervalSince(expected)) < 5)
        #expect(updated.show_channel == "5.1")
    }

    @Test @MainActor func seriesAll_matchesAcrossChannelsOnSameDevice() async {
        let device = HDHRDevice.test(id: "AABBCCDD", tuners: 2)
        // Same setup as the seriesChannel cross-channel test above, but seriesAll — the only
        // difference between the two types is channel scope, so the identical guide content
        // must now match, and show_channel must follow it to 9.1.
        let show = makeSeriesShow(all: true, channel: "5.1", device: device.DeviceID)
        let now = Int(Date().timeIntervalSince1970)
        let json = """
        [{"GuideNumber":"9.1","GuideName":"Other Channel","Guide":[
            {"StartTime":\(now - 300),"EndTime":\(now + 300),"Title":"Tier Order Show","SeriesID":"series123"}
        ]}]
        """
        let state = await makeStateWithGuide(show: show, device: device, json: json)

        await state.scheduleNextAir(index: 0)

        let updated = state.shows[0]
        #expect(updated.show_next?.timeIntervalSince1970 == Double(now - 300))
        #expect(updated.show_channel == "9.1")
        // Device scope is still pinned — seriesAll only widens channel scope, never device scope.
        #expect(updated.hdhr_record == device.DeviceID)
    }
}
