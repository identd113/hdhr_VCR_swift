import Testing
import Foundation
@testable import hdhr_VCR

// The player's optional status bar (docs/VLCPlayerView.md, "Status bar"): pure formatting, health and upcoming-show
// rules, and the window math that must treat the bar as part of the chrome around the video.

@Suite("PlayerStatusFormat")
struct PlayerStatusFormatTests {

    private func entry(_ title: String, start: Int, end: Int, filter: [String]? = nil) -> GuideEntry {
        var e = GuideEntry(StartTime: start, EndTime: end, Title: title)
        e.Filter = filter
        return e
    }

    // MARK: time range

    /// macOS formats "8:30 AM" with a narrow no-break space (U+202F) before AM/PM; compare with a plain space.
    private func plain(_ text: String) -> String { text.replacingOccurrences(of: "\u{202F}", with: " ") }

    @Test func timeRange_sharedMeridiem_isShownOnce() {
        let tz = TimeZone(identifier: "UTC")!
        let start = Date(timeIntervalSince1970: 1_800_000_000)           // a fixed instant
        let text = PlayerStatusFormat.timeRange(start: start, end: start.addingTimeInterval(1800),
                                                locale: Locale(identifier: "en_US"), timeZone: tz)
        // 2027-01-15 08:00 UTC -> "8:00 – 8:30 AM"
        #expect(plain(text) == "8:00 – 8:30 AM")
    }

    @Test func timeRange_acrossNoon_keepsBothMeridiems() {
        let tz = TimeZone(identifier: "UTC")!
        let start = Date(timeIntervalSince1970: 1_800_000_000).addingTimeInterval(3.75 * 3600)   // 11:45 AM
        let text = PlayerStatusFormat.timeRange(start: start, end: start.addingTimeInterval(1800),
                                                locale: Locale(identifier: "en_US"), timeZone: tz)
        #expect(plain(text) == "11:45 AM – 12:15 PM")
    }

    // MARK: genre tags

    @Test func genreTags_dropSeries_uppercase_andLimit() {
        let e = entry("X", start: 0, end: 1, filter: ["Series", "Drama", "Crime", "Mystery"])
        #expect(PlayerStatusFormat.genreTags(e) == ["DRAMA", "CRIME"])
        #expect(PlayerStatusFormat.genreTags(e, limit: 1) == ["DRAMA"])
    }

    @Test func genreTags_moviesBecomesMovie_andDuplicatesCollapse() {
        let e = entry("X", start: 0, end: 1, filter: ["Movies", "movie", "Action"])
        #expect(PlayerStatusFormat.genreTags(e) == ["MOVIE", "ACTION"])
    }

    @Test func genreTags_noFilter_isEmpty() {
        #expect(PlayerStatusFormat.genreTags(entry("X", start: 0, end: 1)).isEmpty)
    }

    // MARK: upcoming shows

    @Test func upcoming_onlyEntriesStartingAtOrAfterTheCurrentEnd_soonestFirst() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let nowI = Int(now.timeIntervalSince1970)
        let current = entry("Now", start: nowI - 600, end: nowI + 600)
        let all = [
            entry("Later", start: nowI + 4200, end: nowI + 7800),
            entry("Current", start: nowI - 600, end: nowI + 600),
            entry("Next", start: nowI + 600, end: nowI + 4200),
        ]
        let result = PlayerStatusFormat.upcoming(after: current, in: all, now: now)
        #expect(result.map(\.Title) == ["Next", "Later"])
    }

    @Test func upcoming_respectsHorizonAndLimit() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let nowI = Int(now.timeIntervalSince1970)
        let current = entry("Now", start: nowI - 600, end: nowI + 600)
        let far = entry("Far", start: nowI + 7 * 3600, end: nowI + 8 * 3600)            // beyond the 6 h horizon
        let many = (0..<10).map { entry("S\($0)", start: nowI + 600 + $0 * 1800, end: nowI + 600 + ($0 + 1) * 1800) }
        let result = PlayerStatusFormat.upcoming(after: current, in: many + [far], now: now, limit: 4)
        #expect(result.map(\.Title) == ["S0", "S1", "S2", "S3"])
        #expect(!PlayerStatusFormat.upcoming(after: current, in: many + [far], now: now, limit: 20).contains { $0.Title == "Far" })
    }

    // MARK: source text

    @Test func sourceText_perSessionKind() {
        #expect(PlayerStatusFormat.sourceText(.liveTuner(deviceID: "105404be", signalQuality: 96)) == "HDHR-105404BE · quality 96%")
        #expect(PlayerStatusFormat.sourceText(.liveTuner(deviceID: "105404BE", signalQuality: nil)) == "HDHR-105404BE")
        #expect(PlayerStatusFormat.sourceText(.recording) == "From disk · no tuner used")
        #expect(PlayerStatusFormat.sourceText(.feed(host: "Woodflix")) == "FEED · Woodflix")
        #expect(PlayerStatusFormat.sourceText(.feed(host: nil)) == "FEED · another Mac")
    }

    // MARK: health

    @Test func health_followsThroughputWhenSignalIsFine() {
        #expect(PlayerStatusFormat.health(throughput: .steady, signalQuality: 96) == .good)
        #expect(PlayerStatusFormat.health(throughput: .trending, signalQuality: 96) == .fair)
        #expect(PlayerStatusFormat.health(throughput: .stalled, signalQuality: 96) == .poor)
        #expect(PlayerStatusFormat.health(throughput: .measuring, signalQuality: nil) == .measuring)
        #expect(PlayerStatusFormat.health(throughput: .steady, signalQuality: nil) == .good)
    }

    @Test func health_aWeakSignalCanOnlyMakeItWorse() {
        #expect(PlayerStatusFormat.health(throughput: .steady, signalQuality: 55) == .fair)
        #expect(PlayerStatusFormat.health(throughput: .steady, signalQuality: 30) == .poor)
        #expect(PlayerStatusFormat.health(throughput: .stalled, signalQuality: 55) == .poor)      // already worse
        #expect(PlayerStatusFormat.health(throughput: .measuring, signalQuality: 30) == .poor)    // weak signal shows at once
        #expect(PlayerStatusFormat.health(throughput: .measuring, signalQuality: 90) == .measuring)
    }
}

@Suite("Player window chrome with the status bar")
struct PlayerStatusBarChromeTests {
    private let hd = CGSize(width: 1920, height: 1080)          // 16:9

    @Test func chromeConstants() {
        #expect(VLCPlayerWindowManager.playerToolbarHeight == 44)
        #expect(VLCPlayerWindowManager.playerStatusBarHeight == 52)
    }

    @Test func contentSize_addsToolbarAndBar_soTheVideoKeepsItsShape() {
        let chrome = VLCPlayerWindowManager.playerToolbarHeight + VLCPlayerWindowManager.playerStatusBarHeight   // 96
        let size = VLCPlayerWindowManager.contentSize(width: 1280, nativePixelSize: hd, toolbarHeight: chrome)
        #expect(size.width == 1280)
        #expect(size.height - chrome == 720)                     // the video area is exactly 16:9
    }

    @Test func aspectLock_withTheBar_holdsTheVideoAreaNotTheWholeWindow() {
        let chrome = VLCPlayerWindowManager.playerToolbarHeight + VLCPlayerWindowManager.playerStatusBarHeight
        let current = CGSize(width: 1280, height: 720 + chrome)
        let r = VLCPlayerWindowManager.aspectLockedContentSize(
            proposed: CGSize(width: 1600, height: 720 + chrome), current: current, nativePixelSize: hd, toolbarHeight: chrome)
        #expect(r.width == 1600)
        #expect(abs((r.height - chrome) - 900) < 0.001)          // 1600 x 900 video area, bar and toolbar on top of that
    }

    @Test func aspectLock_sameProposalWithoutTheBar_differsByExactlyTheBarHeight() {
        let withBar = VLCPlayerWindowManager.playerToolbarHeight + VLCPlayerWindowManager.playerStatusBarHeight
        let a = VLCPlayerWindowManager.contentSize(width: 1000, nativePixelSize: hd, toolbarHeight: VLCPlayerWindowManager.playerToolbarHeight)
        let b = VLCPlayerWindowManager.contentSize(width: 1000, nativePixelSize: hd, toolbarHeight: withBar)
        #expect(b.height - a.height == VLCPlayerWindowManager.playerStatusBarHeight)
    }
}

@Suite("AppState.recordUpcoming (status bar's next-show Record)")
struct RecordUpcomingTests {
    private let device = HDHRDevice.test(id: "DEV1", tuners: 1)
    private let channel = LineupEntry.test(number: "5.1", name: "KFOO")

    private func future(_ title: String = "Late Show") -> GuideEntry {
        let start = Int(Date().timeIntervalSince1970) + 7200
        return GuideEntry.test(title: title, start: start, end: start + 3600)
    }

    @Test @MainActor func schedulesTheUpcomingAiring_atItsOwnStartAndEnd() throws {
        let state = makeTestAppState(devices: [device], lineups: ["DEV1": [channel]])
        let entry = future()
        state.recordUpcoming(type: .single, entry: entry, device: device, channel: channel)
        let show = try #require(state.shows.first)
        #expect(state.shows.count == 1)
        #expect(show.show_title == "Late Show")
        #expect(show.show_channel == "5.1")
        #expect(show.hdhr_record == "DEV1")
        #expect(show.show_next == entry.startDate)
        #expect(show.show_end == entry.endDate)
    }

    // The reason it exists: quickRecord refuses while every tuner is busy *right now*, which is the wrong test for a show
    // that has not started. With the device's only tuner recording something else, quickRecord says no and recordUpcoming
    // still schedules.
    @Test @MainActor func schedules_evenWhileEveryTunerIsBusyNow() {
        var busy = Show.testRecording(title: "Already Recording", channel: "9.9")
        busy.hdhr_record = "DEV1"
        let state = makeTestAppState(shows: [busy], devices: [device], lineups: ["DEV1": [channel]])
        let entry = future()

        #expect(state.quickRecord(type: .single, entry: entry, device: device, channel: channel) == false)
        state.recordUpcoming(type: .single, entry: entry, device: device, channel: channel)

        #expect(state.shows.count == 2)
        #expect(state.shows.contains { $0.show_title == "Late Show" })
    }

    @Test @MainActor func seriesTypes_stripTheEpisodeSuffix_andTrackTheSeries() throws {
        let state = makeTestAppState(devices: [device], lineups: ["DEV1": [channel]])
        var entry = future("Drama Hour S02E06 The Lantern")
        entry.SeriesID = "SER123"
        state.recordUpcoming(type: .seriesChannel, entry: entry, device: device, channel: channel)
        let show = try #require(state.shows.first)
        #expect(show.show_title == "Drama Hour")
        #expect(show.show_is_series == true)
        #expect(show.show_seriesid == "SER123")
    }

    @Test @MainActor func everyOfTheFourTypesIsAccepted() {
        for type in ShowState.allCases {
            let state = makeTestAppState(devices: [device], lineups: ["DEV1": [channel]])
            state.recordUpcoming(type: type, entry: future(), device: device, channel: channel)
            #expect(state.shows.count == 1, "\(type.rawValue) should add a show")
        }
    }
}

@Suite("VLCPlayerWindowManager status bar state")
struct PlayerStatusBarWindowStateTests {
    @Test @MainActor func chromeHeight_tracksTheBar_andReturnsToTheToolbarAlone() {
        let manager = VLCPlayerWindowManager.shared
        defer { manager.setStatusBarVisible(false) }            // the manager is a singleton: leave it as found
        manager.setStatusBarVisible(false)
        #expect(manager.statusBarHeight == 0)
        #expect(manager.chromeHeight == VLCPlayerWindowManager.playerToolbarHeight)
        manager.setStatusBarVisible(true)
        #expect(manager.statusBarHeight == VLCPlayerWindowManager.playerStatusBarHeight)
        #expect(manager.chromeHeight == VLCPlayerWindowManager.playerToolbarHeight + VLCPlayerWindowManager.playerStatusBarHeight)
        manager.setStatusBarVisible(true)                       // idempotent
        #expect(manager.chromeHeight == 96)
        manager.setStatusBarVisible(false)
        #expect(manager.chromeHeight == 44)
    }

    // Regression (code review): the manager is a singleton, but the player window is recreated at its default size after a
    // close. The resize owed for the bar must be measured against what the *frame* was sized for, not against the last
    // requested height, or a reopened window would never grow for the bar.
    @Test @MainActor func withNoWindow_theResizeIsStillOwed_notConsideredDone() {
        let manager = VLCPlayerWindowManager.shared
        defer { manager.setStatusBarVisible(false) }
        manager.setStatusBarVisible(false)
        #expect(manager.frameStatusBarHeight == 0)
        manager.setStatusBarVisible(true)
        #expect(manager.statusBarHeight == 52)
        #expect(manager.frameStatusBarHeight == 0)               // no window to resize: still owed
        manager.setStatusBarVisible(true)                        // asking again must not mark it done
        #expect(manager.frameStatusBarHeight == 0)
    }
}

@Suite("PlayerStatusBar.shortTime")
struct PlayerStatusBarShortTimeTests {
    private let now = Date()

    @Test func sameDay_hasNoWeekday() {
        let text = PlayerStatusBar.shortTime(now.addingTimeInterval(60), now: now)
        let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        // 60 s later can cross midnight; only assert when it is still the same calendar day.
        if Calendar.current.isDate(now.addingTimeInterval(60), inSameDayAs: now) {
            #expect(!weekdays.contains { text.hasPrefix($0) })
        }
    }

    @Test func anotherDay_getsAWeekdayPrefix_unlessDropped() {
        let later = now.addingTimeInterval(3 * 24 * 3600)
        let withDay = PlayerStatusBar.shortTime(later, now: now)
        let compact = PlayerStatusBar.shortTime(later, now: now, dropWeekday: true)
        #expect(withDay.count > compact.count)
        #expect(withDay.hasSuffix(compact) || withDay.contains(compact))
    }
}
