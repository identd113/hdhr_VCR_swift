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

// Coverage for AppState.effectiveGuideRefreshIntervalSeconds(guideHours:divisor:unitRandom:) —
// added 2026-09-21 in code review, fixing a real bug: jitteredGuideRefreshIntervalSeconds alone
// can return a value below guideRefreshIntervalSeconds's own 30-minute floor for any nominal
// under 5400s, which defeats the floor's entire anti-thrash purpose (see the function's own doc
// comment). These tests exercise the exact scenario the review found — small GuideHours with the
// /8 divisor — plus the boundary where the bug stops applying.
@Suite("AppState.effectiveGuideRefreshIntervalSeconds")
struct AppStateEffectiveGuideRefreshIntervalTests {

    @Test func flooredNominal_zeroRandom_neverGoesBelowTheFloor() {
        // GuideHours=1 ÷ divisor=8 floors nominal at exactly 1800s. Unclamped jitter would return
        // 0 here (see windowShorterThanAnHour_zeroRandom_isZero above) — the whole point of this
        // function is that it doesn't.
        let seconds = AppState.effectiveGuideRefreshIntervalSeconds(guideHours: 1, divisor: 8, unitRandom: 0)
        #expect(seconds == 30 * 60)
    }

    @Test func nominalWellAboveOneHour_zeroRandom_neverGoesBelowTheFloor() {
        // GuideHours=5 ÷ divisor=4 → nominal=4500s (75 min). Unclamped jitter would return
        // nominal - 3600 = 900s here — far below the 1800s floor. This is the "wider than the
        // 1-hour-floored case" half of the bug: it isn't only the exact-floor value that's affected.
        let seconds = AppState.effectiveGuideRefreshIntervalSeconds(guideHours: 5, divisor: 4, unitRandom: 0)
        #expect(seconds == 30 * 60)
    }

    @Test func nominalAtNinetyMinutes_zeroRandom_isExactlyTheFloor_boundaryCase() {
        // nominal=5400s (90 min) is the exact point where jitterWindow's lower bound
        // (nominal - 3600) equals the 1800s floor — the boundary where the bug stops mattering.
        let seconds = AppState.effectiveGuideRefreshIntervalSeconds(guideHours: 3, divisor: 2, unitRandom: 0)
        #expect(seconds == 30 * 60)
    }

    @Test func normalCase_defaultConfig_jitterRangeUnaffectedByTheFloor() {
        // GuideHours=24 ÷ divisor=8 → nominal=3h, well clear of the floor-violating zone —
        // the floor clamp must be a no-op here, preserving the full "sometime between 2h and 3h" range.
        let zeroRandom = AppState.effectiveGuideRefreshIntervalSeconds(guideHours: 24, divisor: 8, unitRandom: 0)
        let fullRandom = AppState.effectiveGuideRefreshIntervalSeconds(guideHours: 24, divisor: 8, unitRandom: 0.999)
        #expect(zeroRandom == 2 * 3600)
        #expect(fullRandom > 2.99 * 3600 && fullRandom <= 3 * 3600)
    }
}
