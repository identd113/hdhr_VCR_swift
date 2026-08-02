import Testing
import Foundation
@testable import hdhr_VCR

// MARK: - ManagedGuideMatcher
//
// Covers the tiered matching behind the web guide's gold/green corner flags (CLAUDE.md
// "Web guide managed markers are tuner-scoped"): seriesAll matches on any device via a bare
// key, seriesChannel is scoped to "device:key" and must NOT leak onto another device, and
// dateTime slot keys include weekday so a same-time rerun on a different day of the week
// isn't mistaken for the managed airing. Zero prior coverage — this is pure, deterministic
// logic (no MainActor, no I/O), so a regression here (e.g. a dropped device-scope check)
// would otherwise only surface as a wrongly-flagged tuner in manual guide testing.

@Suite("ManagedGuideMatcher")
struct ManagedGuideMatcherTests {

    // Fixed reference instant + its actual weekday name, rather than a hardcoded guess —
    // avoids the test being wrong about which calendar date lands on which weekday.
    private static let cal = Calendar.current
    private static let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    private static let base = cal.date(from: DateComponents(year: 2026, month: 6, day: 3, hour: 20, minute: 0))!
    private static let baseDayName = dayNames[cal.component(.weekday, from: base) - 1]
    // Same weekday + time, one week later — a same-day rerun the matcher should still catch.
    private static let sameWeekdayNextWeek = cal.date(byAdding: .day, value: 7, to: base)!
    // One day later, same time — the "Friday rerun of a Wednesday show" case that must NOT match.
    private static let nextDaySameTime = cal.date(byAdding: .day, value: 1, to: base)!

    private func entry(device: String, channel: String, start: Date, title: String = "Show",
                        seriesID: String? = nil) -> GuideEntry {
        let s = Int(start.timeIntervalSince1970)
        return GuideEntry(deviceId: device, channelNum: channel, StartTime: s, EndTime: s + 1800,
                           Title: title, SeriesID: seriesID)
    }

    private func managedShow(state seriesAll: Bool, seriesChannel: Bool, device: String, channel: String,
                              title: String = "Show", seriesID: String = "", next: Date? = nil,
                              airDays: [String] = []) -> Show {
        var s = Show.blank(channel: channel, device: device)
        s.show_title = title
        s.show_active = true
        s.show_seriesid = seriesID
        // dateTime (both false here) is still a series-tracking mode, distinct from `single` —
        // Show.state only returns .dateTime when show_is_series is true AND neither SeriesID
        // flag is set, so this must be unconditional, not `seriesAll || seriesChannel`.
        s.show_is_series = true
        s.show_use_seriesid_all = seriesAll
        s.show_use_seriesid = seriesChannel
        s.show_next = next
        s.show_air_date = airDays
        return s
    }

    // MARK: seriesAll — bare key, matches any device

    @Test func seriesAll_bySeriesID_matchesAnyDevice() {
        let show = managedShow(state: true, seriesChannel: false, device: "DEV1", channel: "5.1",
                                seriesID: "SID123")
        let matcher = ManagedGuideMatcher(activeManagedShows: [show])
        let onOtherDevice = entry(device: "DEV2", channel: "9.9", start: Self.base, seriesID: "SID123")
        #expect(matcher.owner(for: onOtherDevice)?.show_id == show.show_id)
    }

    @Test func seriesAll_byTitle_matchesAnyDevice() {
        let show = managedShow(state: true, seriesChannel: false, device: "DEV1", channel: "5.1",
                                title: "Jeopardy!")
        let matcher = ManagedGuideMatcher(activeManagedShows: [show])
        let onOtherDevice = entry(device: "DEV2", channel: "9.9", start: Self.base, title: "Jeopardy!")
        #expect(matcher.owner(for: onOtherDevice)?.show_id == show.show_id)
    }

    // MARK: seriesChannel — "device:key", must not leak to another device

    @Test func seriesChannel_bySeriesID_matchesOwnDevice() {
        let show = managedShow(state: false, seriesChannel: true, device: "DEV1", channel: "5.1",
                                seriesID: "SID456")
        let matcher = ManagedGuideMatcher(activeManagedShows: [show])
        let sameDevice = entry(device: "DEV1", channel: "5.1", start: Self.base, seriesID: "SID456")
        #expect(matcher.owner(for: sameDevice)?.show_id == show.show_id)
    }

    @Test func seriesChannel_bySeriesID_doesNotLeakToOtherDevice() {
        let show = managedShow(state: false, seriesChannel: true, device: "DEV1", channel: "5.1",
                                seriesID: "SID456")
        let matcher = ManagedGuideMatcher(activeManagedShows: [show])
        let otherDevice = entry(device: "DEV2", channel: "5.1", start: Self.base, seriesID: "SID456")
        #expect(matcher.owner(for: otherDevice) == nil)
    }

    @Test func seriesChannel_byTitle_doesNotLeakToOtherDevice() {
        let show = managedShow(state: false, seriesChannel: true, device: "DEV1", channel: "5.1",
                                title: "Local News")
        let matcher = ManagedGuideMatcher(activeManagedShows: [show])
        let otherDevice = entry(device: "DEV2", channel: "5.1", start: Self.base, title: "Local News")
        #expect(matcher.owner(for: otherDevice) == nil)
    }

    // MARK: dateTime — weekday-scoped slot keys

    @Test func dateTime_matchesSameWeekdaySameTime() {
        let show = managedShow(state: false, seriesChannel: false, device: "DEV1", channel: "5.1",
                                next: Self.base, airDays: [Self.baseDayName])
        let matcher = ManagedGuideMatcher(activeManagedShows: [show])
        let rerunNextWeek = entry(device: "DEV1", channel: "5.1", start: Self.sameWeekdayNextWeek)
        #expect(matcher.owner(for: rerunNextWeek)?.show_id == show.show_id)
    }

    @Test func dateTime_sameTimeDifferentWeekday_doesNotMatch() {
        // The exact gotcha CLAUDE.md calls out: "a Wednesday-only show doesn't flag Friday reruns."
        let show = managedShow(state: false, seriesChannel: false, device: "DEV1", channel: "5.1",
                                next: Self.base, airDays: [Self.baseDayName])
        let matcher = ManagedGuideMatcher(activeManagedShows: [show])
        let dayAfter = entry(device: "DEV1", channel: "5.1", start: Self.nextDaySameTime)
        #expect(matcher.owner(for: dayAfter) == nil)
    }

    @Test func dateTime_emptyAirDate_fallsBackToAllSevenDays() {
        // show_air_date == [] means "every day" per ManagedGuideMatcher's init.
        let show = managedShow(state: false, seriesChannel: false, device: "DEV1", channel: "5.1",
                                next: Self.base, airDays: [])
        let matcher = ManagedGuideMatcher(activeManagedShows: [show])
        let dayAfter = entry(device: "DEV1", channel: "5.1", start: Self.nextDaySameTime)
        #expect(matcher.owner(for: dayAfter)?.show_id == show.show_id)
    }

    // MARK: single — exact device:channel:epoch match only

    @Test func single_exactEpochMatches() {
        var show = Show.blank(channel: "5.1", device: "DEV1")
        show.show_active = true
        show.show_next = Self.base
        let matcher = ManagedGuideMatcher(activeManagedShows: [show])
        let sameSlot = entry(device: "DEV1", channel: "5.1", start: Self.base)
        #expect(matcher.owner(for: sameSlot)?.show_id == show.show_id)
    }

    @Test func single_differentEpoch_doesNotMatch() {
        var show = Show.blank(channel: "5.1", device: "DEV1")
        show.show_active = true
        show.show_next = Self.base
        let matcher = ManagedGuideMatcher(activeManagedShows: [show])
        let laterSlot = entry(device: "DEV1", channel: "5.1", start: Self.nextDaySameTime)
        #expect(matcher.owner(for: laterSlot) == nil)
    }

    // MARK: unmanaged

    @Test func unmanagedEntry_returnsNil() {
        let matcher = ManagedGuideMatcher(activeManagedShows: [])
        #expect(matcher.owner(for: entry(device: "DEV1", channel: "5.1", start: Self.base)) == nil)
        #expect(matcher.isManaged(entry: entry(device: "DEV1", channel: "5.1", start: Self.base)) == false)
    }
}
