import Testing
import Foundation
@testable import hdhr_VCR

// rebuildMenuEntries' conflict pass: a single-tuner device with two overlapping shows flags the
// loser, and a favorited channel wins the tie-break regardless of show_id order.

@Suite("AppState conflict detection")
struct AppStateConflictDetectionTests {

    @MainActor private func makeState(favoriteChannel: String?, tunerCount: Int = 1, shows: [Show]) -> AppState {
        let device = HDHRDevice(DeviceID: "FFFFFFFF", LocalIP: "192.168.1.100", BaseURL: "http://192.168.1.100",
                                TunerCount: tunerCount, FirmwareVersion: nil, DeviceAuth: nil)
        let lineup = ["3.1", "4.1"].map {
            LineupEntry(GuideNumber: $0, GuideName: $0, URL: nil, HD: nil, Favorite: $0 == favoriteChannel ? 1 : nil)
        }
        return makeTestAppState(shows: shows, devices: [device], lineups: ["FFFFFFFF": lineup])
    }

    private func overlapping(_ title: String, channel: String, next: Date) -> Show {
        var s = Show.testActive(title: title, channel: channel)
        s.show_next = next
        s.show_end = next.addingTimeInterval(3600)
        return s
    }

    @Test @MainActor func favoriteChannelWinsTheOnlyTuner() {
        let next = Date().addingTimeInterval(7200)
        let plain = overlapping("Plain", channel: "3.1", next: next)
        let fav = overlapping("Fav", channel: "4.1", next: next)
        let state = makeState(favoriteChannel: "4.1", shows: [plain, fav])
        state.rebuildMenuEntries()
        #expect(state.showRuntime[plain.show_id]?.isConflicting == true)
        #expect(state.showRuntime[plain.show_id]?.conflictBeatenByFavorite == true)
        #expect(state.showRuntime[fav.show_id]?.isConflicting != true)
    }

    @Test @MainActor func favoriteWinsRegardlessOfListOrder() {
        let next = Date().addingTimeInterval(7200)
        let plain = overlapping("Plain", channel: "3.1", next: next)
        let fav = overlapping("Fav", channel: "4.1", next: next)
        let state = makeState(favoriteChannel: "4.1", shows: [fav, plain])
        state.rebuildMenuEntries()
        #expect(state.showRuntime[plain.show_id]?.isConflicting == true)
        #expect(state.showRuntime[fav.show_id]?.isConflicting != true)
    }

    @Test @MainActor func noFavorites_loserIsConflictingButNotBeatenByFavorite() {
        let next = Date().addingTimeInterval(7200)
        let a = overlapping("A", channel: "3.1", next: next)
        let b = overlapping("B", channel: "4.1", next: next)
        let state = makeState(favoriteChannel: nil, shows: [a, b])
        state.rebuildMenuEntries()
        let flagged = [a, b].filter { state.showRuntime[$0.show_id]?.isConflicting == true }
        #expect(flagged.count == 1)
        #expect(state.showRuntime[flagged[0].show_id]?.conflictBeatenByFavorite != true)
    }

    @Test @MainActor func twoTuners_noConflict() {
        let next = Date().addingTimeInterval(7200)
        let a = overlapping("A", channel: "3.1", next: next)
        let b = overlapping("B", channel: "4.1", next: next)
        let state = makeState(favoriteChannel: "4.1", tunerCount: 2, shows: [a, b])
        state.rebuildMenuEntries()
        #expect(state.showRuntime[a.show_id]?.isConflicting != true)
        #expect(state.showRuntime[b.show_id]?.isConflicting != true)
    }

    // Regression (code review): a lineup with the same GuideNumber twice used to count as favorite if ANY entry was one;
    // isFavoriteChannel has always used the first entry, and the set built for the conflict pass must agree.
    @Test @MainActor func duplicateGuideNumber_usesTheFirstEntryLikeIsFavoriteChannel() {
        let next = Date().addingTimeInterval(7200)
        let a = overlapping("A", channel: "3.1", next: next)
        let b = overlapping("B", channel: "4.1", next: next)
        let device = HDHRDevice(DeviceID: "FFFFFFFF", LocalIP: "192.168.1.100", BaseURL: "http://192.168.1.100",
                                TunerCount: 1, FirmwareVersion: nil, DeviceAuth: nil)
        let lineup = [
            LineupEntry(GuideNumber: "3.1", GuideName: "A", URL: nil, HD: nil, Favorite: nil),
            LineupEntry(GuideNumber: "4.1", GuideName: "B", URL: nil, HD: nil, Favorite: nil),   // first 4.1: not a favorite
            LineupEntry(GuideNumber: "4.1", GuideName: "B2", URL: nil, HD: nil, Favorite: 1),     // duplicate, favorite
        ]
        let state = makeTestAppState(shows: [a, b], devices: [device], lineups: ["FFFFFFFF": lineup])
        #expect(state.isFavoriteChannel(b) == false)             // the rule the set must match
        state.rebuildMenuEntries()
        let flagged = [a, b].filter { state.showRuntime[$0.show_id]?.isConflicting == true }
        #expect(flagged.count == 1)
        #expect(state.showRuntime[flagged[0].show_id]?.conflictBeatenByFavorite != true)
    }
}
