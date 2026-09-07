import Testing
@testable import hdhr_VCR

// Regression coverage for a real reported bug: a remote FEED viewer's "fill phase" (playing
// slightly below realtime while a network stream's buffer builds) took several real *minutes* to
// ramp back up to full speed instead of the ~8 seconds both the code's own comment and
// VLCPlayerView's buffer-pill UI ("X of 8 seconds") promised — confirmed live 2026-09-06 via a real
// session's log: 0.90 → ~1.000 took from 23:33:33 to 23:39:33. Root cause: the old formula grew
// `estimatedLagSec` by `(1.0 - currentRate) * 3.0` each tick — self-referential, since that
// increment shrinks toward zero as the rate approaches 1.0, turning the ramp into a geometric decay
// that only asymptotically approaches its cap. `rampedFillRate` fixes this by advancing
// `estimatedLagSec` by a fixed real-time tick interval instead, so the ramp is linear and actually
// finishes in `maxLagSec` real seconds. No real libvlc session needed — this is pure arithmetic.
@Suite("VLCBridge fill-phase rate ramp")
struct VLCBridgeRateRampTests {

    @Test func rampedFillRate_reachesFullRateWithinMaxLagSec_notMinutes() {
        // 3s ticks, minRate=0.90 (matches the live-reported session) — the old buggy formula never
        // gets meaningfully close to 1.0 within this many ticks (it takes real minutes); the fixed
        // linear ramp must reach it in exactly ceil(8/3) = 3 ticks (9s of tick time, capped at 8s).
        var lag = 0.0
        var rate: Float = 0.90
        for _ in 0..<3 {
            (lag, rate) = VLCBridge.rampedFillRate(minRate: 0.90, estimatedLagSec: lag, tickInterval: 3.0)
        }
        #expect(lag == 8.0)
        #expect(rate == 1.0)
    }

    @Test func rampedFillRate_isLinearInElapsedTime_notInCurrentRate() {
        // Halfway through the window (4 of 8 seconds) must give a rate exactly halfway between
        // minRate and 1.0 — the whole point of fixing this to be a straight linear ramp.
        let (lag, rate) = VLCBridge.rampedFillRate(minRate: 0.90, estimatedLagSec: 0.0, tickInterval: 4.0)
        #expect(lag == 4.0)
        #expect(abs(rate - 0.95) < 0.0001)   // 0.90 + (1.0 - 0.90) * 0.5
    }

    @Test func rampedFillRate_lagNeverExceedsMaxLagSec() {
        let (lag, rate) = VLCBridge.rampedFillRate(minRate: 0.90, estimatedLagSec: 7.0, tickInterval: 10.0)
        #expect(lag == 8.0)
        #expect(rate == 1.0)
    }

    @Test func rampedFillRate_atZeroElapsed_returnsMinRate() {
        let (lag, rate) = VLCBridge.rampedFillRate(minRate: 0.93, estimatedLagSec: 0.0, tickInterval: 0.0)
        #expect(lag == 0.0)
        #expect(rate == 0.93)
    }

    @Test func rampedFillRate_respectsACustomMaxLagSec() {
        let (lag, rate) = VLCBridge.rampedFillRate(minRate: 0.5, estimatedLagSec: 0.0, tickInterval: 2.0, maxLagSec: 4.0)
        #expect(lag == 2.0)
        #expect(abs(rate - 0.75) < 0.0001)   // halfway through a 4s window: 0.5 + 0.5*0.5
    }
}
