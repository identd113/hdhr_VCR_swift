import Testing
@testable import hdhr_VCR

// MARK: - Player channel ordering
//
// The player's channel pulldown lists everything in one fixed stack — Recording now, then FEEDs from
// other Macs, then ★ Favorites, then all other channels — and media-key next/prev walks the same
// stack but in plain channel order (not favorites-first, so up/down steps 5.1 → 5.2 → 6.1). The SwiftUI
// Picker itself is declarative; the decisions behind it are the two pure functions tested here.

@Suite("VLCPlayerView channel ordering")
struct PlayerChannelOrderTests {

    private func nums(_ entries: [LineupEntry]) -> [String] { entries.map(\.GuideNumber) }

    @Test func channelsSortNumerically_notLexically() {
        let lineup = ["11.1", "5.10", "5.2", "9.1", "5.1", "2.4"].map { LineupEntry.test(number: $0) }
        #expect(nums(VLCPlayerView.sortedChannels(lineup)) == ["2.4", "5.1", "5.2", "5.10", "9.1", "11.1"])
    }

    @Test func sortingIsStableForAnAlreadySortedLineup_andEmptyIsEmpty() {
        let lineup = ["2.1", "4.1", "5.1"].map { LineupEntry.test(number: $0) }
        #expect(nums(VLCPlayerView.sortedChannels(lineup)) == ["2.1", "4.1", "5.1"])
        #expect(VLCPlayerView.sortedChannels([]).isEmpty)
    }

    @Test func favoritesAreIdentifiedByTheDeviceFlag_andKeepNumericOrder() {
        let lineup = [LineupEntry.test(number: "9.1", favorite: true),
                      LineupEntry.test(number: "5.1"),
                      LineupEntry.test(number: "4.1", favorite: true)]
        let sorted = VLCPlayerView.sortedChannels(lineup)
        #expect(nums(sorted.filter(\.isFavorite)) == ["4.1", "9.1"])
        #expect(nums(sorted.filter { !$0.isFavorite }) == ["5.1"])
    }

    @Test func cycleOrder_isRecordingThenFeedThenChannels() {
        let rec = [LineupEntry(GuideNumber: "live:abc", GuideName: "Live 9.1  News", URL: nil, HD: nil, Favorite: nil)]
        let feed = [LineupEntry(GuideNumber: "live-feed:http://x", GuideName: "FEED  Game", URL: nil, HD: nil, Favorite: nil)]
        let channels = ["5.1", "6.1"].map { LineupEntry.test(number: $0) }
        let order = VLCPlayerView.channelCycleOrder(recording: rec, feeds: feed, channels: channels, recordingChannels: [])
        #expect(nums(order) == ["live:abc", "live-feed:http://x", "5.1", "6.1"])
    }

    // 2026-10-01 review #13: the plain row for a channel that is recording redirects to its "Live" row,
    // so leaving it in meant up/down could never step past it.
    @Test func cycleOrder_dropsThePlainRowForAChannelThatIsRecording() {
        let rec = [LineupEntry(GuideNumber: "live:abc", GuideName: "Live 9.1  News", URL: nil, HD: nil, Favorite: nil)]
        let channels = ["5.1", "9.1", "11.1"].map { LineupEntry.test(number: $0) }
        let order = VLCPlayerView.channelCycleOrder(recording: rec, feeds: [], channels: channels, recordingChannels: ["9.1"])
        #expect(nums(order) == ["live:abc", "5.1", "11.1"])
    }

    @Test func cycleOrder_isPlainAscending_notFavoritesFirst() {
        // 9.1 is a favorite but must still sit between 5.1 and 11.1 — next/prev is a dial, not a menu.
        let channels = VLCPlayerView.sortedChannels([LineupEntry.test(number: "11.1"),
                                                      LineupEntry.test(number: "9.1", favorite: true),
                                                      LineupEntry.test(number: "5.1")])
        let order = VLCPlayerView.channelCycleOrder(recording: [], feeds: [], channels: channels, recordingChannels: [])
        #expect(nums(order) == ["5.1", "9.1", "11.1"])
    }

    @Test func cycleOrder_withNothingExtra_isJustTheChannels() {
        let channels = ["2.1", "3.1"].map { LineupEntry.test(number: $0) }
        #expect(nums(VLCPlayerView.channelCycleOrder(recording: [], feeds: [], channels: channels, recordingChannels: [])) == ["2.1", "3.1"])
    }
}
