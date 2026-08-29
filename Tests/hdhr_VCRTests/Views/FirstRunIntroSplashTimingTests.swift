import Testing
@testable import hdhr_VCR

// Regression coverage for IntroSplashOverlay.totalDurationMs, which had zero test coverage
// despite going through two confirmed bugs and fixes this cycle:
//   1. Too short — the finale's own FinaleGrowReveal dot hadn't finished growing to cover the
//      stage before the overlay tore down, so the effect visibly cut off mid-grow.
//   2. Too long — a since-reverted fix padded totalDurationMs by a full extra depart leg
//      (normalLegDurationMs + 150) to protect a departing tile that's actually already hidden
//      under the fully-grown reveal well before that leg would matter, adding a ~1s dead pause
//      at the end that was itself reported as a bug ("pauses too long at the end").
// These two tests pin totalDurationMs to the narrow correct range between those two failure
// modes, using the same static constants IntroSplashOverlay itself computes totalDurationMs
// from (see that file's own comments) rather than hardcoded literals, so a deliberate constant
// retune doesn't spuriously fail this — only a regression to one of the two actual bugs should.
@Suite("IntroSplashOverlay.totalDurationMs")
struct FirstRunIntroSplashTimingTests {
    @Test func doesNotTearDownBeforeTheGrowPhaseItselfFinishes() {
        let growPhaseEndMs = Int((IntroSplashOverlay.growStartMsPreScale + IntroSplashOverlay.growDurationMs) * introSplashSpeedScale)
        #expect(IntroSplashOverlay.totalDurationMs >= growPhaseEndMs,
                "totalDurationMs (\(IntroSplashOverlay.totalDurationMs)) must not elapse before the grow phase itself finishes (\(growPhaseEndMs)) — regression of the 'cuts off mid-grow' bug")
    }

    @Test func doesNotPadWithAFullExtraDepartLeg() {
        // The reverted fix's buffer, for comparison — totalDurationMs must stay well under this,
        // not just technically less than it, to actually fix the "pauses too long" complaint
        // rather than merely not regressing to the exact old number.
        let revertedBufferMs = Int((IntroSplashOverlay.growStartMsPreScale + IntroSplashOverlay.growDurationMs + IntroSplashOverlay.normalLegDurationMs) * introSplashSpeedScale)
        #expect(IntroSplashOverlay.totalDurationMs < revertedBufferMs,
                "totalDurationMs (\(IntroSplashOverlay.totalDurationMs)) should not pad out to a full extra depart leg (\(revertedBufferMs)) — regression of the 'pauses too long at the end' bug")
    }
}
