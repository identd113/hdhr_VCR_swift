import Testing
@testable import hdhr_VCR

// Coverage for AppState.guideRefreshIntervalSeconds(guideHours:divisor:) and
// jitteredGuideRefreshIntervalSeconds(nominal:unitRandom:) — added 2026-09-21 when the guide
// auto-refresh setting changed from an independent duration (Guide_refresh_interval_minutes,
// 15...240) to a fraction of GuideHours (Guide_refresh_interval_divisor, one of 2/4/8), then
// gained "fuzzy" jitter the same day so a refresh doesn't always land at a predictable,
// round wall-clock-relative offset. Both pure functions, extracted for unit testing per this
// file's own established precedent.
@Suite("AppState.guideRefreshIntervalSeconds")
struct AppStateGuideRefreshIntervalTests {

    @Test func defaultConfig_24hGuideDividedByEight_isThreeHours() {
        let seconds = AppState.guideRefreshIntervalSeconds(guideHours: 24, divisor: 8)
        #expect(seconds == 3 * 3600)
    }

    @Test func halfDivisor_ofTwentyFourHours_isTwelveHours() {
        let seconds = AppState.guideRefreshIntervalSeconds(guideHours: 24, divisor: 2)
        #expect(seconds == 12 * 3600)
    }

    @Test func quarterDivisor_ofTwentyFourHours_isSixHours() {
        let seconds = AppState.guideRefreshIntervalSeconds(guideHours: 24, divisor: 4)
        #expect(seconds == 6 * 3600)
    }

    @Test func smallGuideHours_withEighthDivisor_isFlooredAtThirtyMinutes() {
        // 1h / 8 = 7.5 min, which is below the 30-minute floor meant to keep a small GuideHours
        // combined with the largest divisor from driving the idle loop into refreshing too aggressively.
        let seconds = AppState.guideRefreshIntervalSeconds(guideHours: 1, divisor: 8)
        #expect(seconds == 30 * 60)
    }

    @Test func maxGuideHours_withHalfDivisor_isFourteenHours() {
        let seconds = AppState.guideRefreshIntervalSeconds(guideHours: 28, divisor: 2)
        #expect(seconds == 14 * 3600)
    }
}

@Suite("AppState.jitteredGuideRefreshIntervalSeconds")
struct AppStateJitteredGuideRefreshIntervalTests {

    @Test func windowLongerThanAnHour_zeroRandom_isOneHourBeforeNominal() {
        // 3h nominal, unitRandom=0 → earliest allowed: exactly one hour before the boundary
        // ("sometime between 2h and 3h" — the earliest end of that range).
        let seconds = AppState.jitteredGuideRefreshIntervalSeconds(nominal: 3 * 3600, unitRandom: 0)
        #expect(seconds == 2 * 3600)
    }

    @Test func windowLongerThanAnHour_almostOneRandom_isNearNominal() {
        let seconds = AppState.jitteredGuideRefreshIntervalSeconds(nominal: 3 * 3600, unitRandom: 0.999)
        #expect(seconds > 2.99 * 3600 && seconds <= 3 * 3600)
    }

    @Test func windowLongerThanAnHour_midRandom_isThirtyMinutesBeforeNominal() {
        let seconds = AppState.jitteredGuideRefreshIntervalSeconds(nominal: 3 * 3600, unitRandom: 0.5)
        #expect(seconds == 2.5 * 3600)
    }

    @Test func windowShorterThanAnHour_zeroRandom_isZero() {
        // 30-minute nominal (the floor case) — jitter window can't exceed the nominal itself, so
        // the earliest allowed point is the very start of the window, not "one hour before."
        let seconds = AppState.jitteredGuideRefreshIntervalSeconds(nominal: 30 * 60, unitRandom: 0)
        #expect(seconds == 0)
    }

    @Test func windowShorterThanAnHour_midRandom_isHalfOfNominal() {
        let seconds = AppState.jitteredGuideRefreshIntervalSeconds(nominal: 30 * 60, unitRandom: 0.5)
        #expect(seconds == 15 * 60)
    }

    @Test func exactlyOneHourWindow_zeroRandom_isZero() {
        // Boundary case: jitterWindow == nominal exactly (min(3600, 3600)), same shape as the
        // shorter-than-an-hour case rather than the longer-than-an-hour case.
        let seconds = AppState.jitteredGuideRefreshIntervalSeconds(nominal: 3600, unitRandom: 0)
        #expect(seconds == 0)
    }
}
