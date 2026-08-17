import Testing
import Foundation
@testable import hdhr_VCR

// MARK: - scheduleNextAir stale-index-across-await safety
//
// CLAUDE.md invariant: "idleLoop()... re-resolve shows by show_id after any await — never reuse
// a captured Int index, since shows can mutate... while suspended." Had only happy-path coverage
// before this file (2026-08-15's AppStateRecordingEngineTests) — nothing forced the actual race
// the invariant defends against. .single/.dateTime shows never suspend inside scheduleNextAir (no
// network dependency — see that file's own header comment), so exercising this needs a
// .seriesChannel show and a mocked guide-fetch to create a genuine `await` suspension
// deterministically: the mock's requestHandler runs synchronously as part of producing the HTTP
// response, so mutating `state.shows` from inside it (via DispatchQueue.main.sync, to safely reach
// the @MainActor-isolated property from URLProtocol's background-thread callback) is guaranteed to
// land *during* scheduleNextAir's `await guideStore.load(...)` suspension — not racily, before, or
// after it. Unblocked by giving AppState an injectable `guideStore` (mirroring the pre-existing
// `recordingManager` seam) specifically for this test.

private final class IdleLoopMockURLProtocol: MockURLProtocolBase {
    private static var _handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { _handler }
        set { _handler = newValue }
    }
}

// .serialized: IdleLoopMockURLProtocol.requestHandler is a static var shared across both tests in
// this suite — Swift Testing runs tests concurrently by default, and without this, one test's
// handler could overwrite the other's before its URLSession request actually fires (same race
// GuideStoreTests.swift documents and guards against the same way).
@Suite("AppState scheduleNextAir stale-index safety", .serialized)
struct AppStateIdleLoopStaleIndexTests {

    private func makeSeriesChannelShow(device: String) -> Show {
        var s = Show.blank(channel: "5.1", device: device)
        s.show_title = "Stale Index Show"
        s.show_active = true
        // Show.state checks show_is_series before show_use_seriesid — omitting this falls through
        // to .single (which awaits nothing), never reaching the guide-fetch this test depends on.
        s.show_is_series = true
        s.show_use_seriesid = true
        s.show_seriesid = "abc123"
        s.show_next = Date().addingTimeInterval(3600)
        s.show_end  = Date().addingTimeInterval(7200)
        return s
    }

    @Test @MainActor func scheduleNextAir_showDeletedDuringGuideFetch_reResolvesInsteadOfTrapping() async {
        let device = HDHRDevice.test(id: "AABBCCDD", tuners: 2)
        let show = makeSeriesChannelShow(device: device.DeviceID)
        let guideStore = GuideStore(session: makeMockSession(IdleLoopMockURLProtocol.self))
        let state = makeTestAppState(shows: [show], devices: [device], guideStore: guideStore)

        IdleLoopMockURLProtocol.requestHandler = { req in
            // Deletes the show while scheduleNextAir's guide-fetch await is genuinely suspended.
            // If scheduleNextAir reused the stale `index: 0` parameter after resuming instead of
            // re-resolving by show_id (AppState.swift's `guard let reIdx = shows.firstIndex(...)`),
            // its very next line — `shows[idx].show_next = ...` inside applyMatch, or the
            // stranded-show_next fallback a few lines later — would trap: index out of range on
            // an array that's now empty.
            DispatchQueue.main.sync { state.shows.removeAll() }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    "[]".data(using: .utf8)!)
        }

        await state.scheduleNextAir(index: 0)

        // Reaching this line at all (no trap) is most of the point; also confirm the deletion
        // wasn't clobbered by scheduleNextAir resurrecting a stale write to the old index.
        #expect(state.shows.isEmpty)
    }

    @Test @MainActor func scheduleNextAir_showStillPresentAfterGuideFetch_appliesMatchAtReResolvedIndex() async {
        let device = HDHRDevice.test(id: "AABBCCDD", tuners: 2)
        let show = makeSeriesChannelShow(device: device.DeviceID)
        // A second show inserted ahead of it during the await shifts the real show from index 0
        // to index 1 — re-resolution by show_id must find it there, not keep using index 0.
        let decoy = Show.blank(channel: "9.1", device: device.DeviceID)
        let guideStore = GuideStore(session: makeMockSession(IdleLoopMockURLProtocol.self))
        let state = makeTestAppState(shows: [show], devices: [device], guideStore: guideStore)

        let futureStart = Int(Date().addingTimeInterval(600).timeIntervalSince1970)
        let futureEnd   = futureStart + 1800
        let guideJSON = """
        [{"GuideNumber":"5.1","GuideName":"Test Channel","Guide":[
            {"StartTime":\(futureStart),"EndTime":\(futureEnd),"Title":"Stale Index Show","SeriesID":"abc123"}
        ]}]
        """
        IdleLoopMockURLProtocol.requestHandler = { req in
            DispatchQueue.main.sync { state.shows.insert(decoy, at: 0) }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    guideJSON.data(using: .utf8)!)
        }

        await state.scheduleNextAir(index: 0)

        #expect(state.shows.count == 2)
        let updated = state.shows.first(where: { $0.show_id == show.show_id })
        #expect(updated?.show_next?.timeIntervalSince1970 == Double(futureStart))
        // The decoy inserted at index 0 must be untouched — a stale-index bug would instead have
        // written the match onto the decoy sitting at the captured index 0.
        #expect(state.shows.first(where: { $0.show_id == decoy.show_id })?.show_next == nil)
    }
}
