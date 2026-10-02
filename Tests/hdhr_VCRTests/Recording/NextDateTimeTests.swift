import Testing
import Foundation
@testable import hdhr_VCR

// Regression coverage for 2026-10-01 review findings #2/#3 — nextDateTime used to always search
// from the start of *tomorrow*, so an edit skipped an airing still upcoming today, and a recording
// that ended past midnight skipped the very next night.
@Suite("AppState.nextDateTime — DateTime show rescheduling")
struct NextDateTimeTests {
    // 2026-10-05 is a Monday.
    private func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func dateTimeShow(days: [String], time: Double, next: Date?) -> Show {
        var s = Show.blank(channel: "5.1", device: "105404BE")
        s.show_is_series = true            // series flags off + is_series → .dateTime
        s.show_air_date = days
        s.show_time = time
        s.show_next = next
        return s
    }

    @MainActor @Test func editBeforeTonightsAiring_keepsTonight() {
        let state = makeTestAppState()
        let show = dateTimeShow(days: ["Monday"], time: 21, next: date(5, 21, 0))
        #expect(show.state == .dateTime)
        #expect(state.nextDateTime(for: show, now: date(5, 8, 0)) == date(5, 21, 0))
    }

    @MainActor @Test func recordingEndingPastMidnight_schedulesTheNextNight() {
        let state = makeTestAppState()
        let weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"]
        // Monday's 23:35 airing stopped Tuesday 00:37 — next is Tuesday 23:35, not Wednesday.
        let show = dateTimeShow(days: weekdays, time: 23 + 35.0 / 60, next: date(5, 23, 35))
        #expect(state.nextDateTime(for: show, now: date(6, 0, 37)) == date(6, 23, 35))
    }

    @MainActor @Test func completedSameDayAiring_neverReschedulesToItself() {
        let state = makeTestAppState()
        let show = dateTimeShow(days: ["Monday", "Tuesday"], time: 21, next: date(5, 21, 0))
        #expect(state.nextDateTime(for: show, now: date(5, 21, 30)) == date(6, 21, 0))
    }

    @Test func searchStart_futureAiringSearchesFromNow_pastAiringFromJustAfterIt() {
        let now = date(5, 8, 0)
        #expect(AppState.nextDateTimeSearchStart(currentNext: date(5, 21, 0), now: now) == now)
        #expect(AppState.nextDateTimeSearchStart(currentNext: nil, now: now) == now)
        // Within the first minute of an airing, still skip that airing itself.
        let start = date(5, 21, 0)
        #expect(AppState.nextDateTimeSearchStart(currentNext: start, now: start.addingTimeInterval(10))
                == start.addingTimeInterval(60))
    }
}
