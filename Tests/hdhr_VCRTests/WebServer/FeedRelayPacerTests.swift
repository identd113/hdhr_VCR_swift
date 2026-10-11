import Testing
import Foundation
@testable import hdhr_VCR

// The FEED serving pacer's schedule is cumulative (start + paced bytes ÷ the current rate estimate), so a falling rate
// estimate re-prices all history. Without a cap a single low measurement window late in a session held every chunk for
// tens of seconds while the data sat on disk (live 2026-10-11: a 57 s freeze). These tests pin the cap.

@Suite("WebServer.FeedRelayPacer")
struct FeedRelayPacerTests {
    private let t0 = Date(timeIntervalSince1970: 2_000_000)
    private let rate = 1_260_000.0   // an HD OTA stream, bytes/s

    /// Feeds `seconds` of steady real-time delivery in 50 ms chunks, returning the largest delay it ever asked for.
    @discardableResult
    private func deliverSteadily(_ p: WebServer.FeedRelayPacer, seconds: Double, from start: Date) -> Double {
        var worst = 0.0
        var t = 0.0
        let chunk = Int(rate * 0.05)
        while t < seconds {
            let d = p.delayBeforeSending(chunkBytes: chunk, now: start.addingTimeInterval(t))
            worst = max(worst, d)
            p.recordPacedSend(chunk)
            t += 0.05
        }
        return worst
    }

    @Test func steadyDeliveryAtThePace_neverHoldsLong() {
        let p = WebServer.FeedRelayPacer(initialFileSize: 0, seedBytesPerSecond: rate)
        #expect(deliverSteadily(p, seconds: 60, from: t0) <= 0.6)
    }

    @Test func aFallingRateEstimateLateInASession_cannotFreezeDelivery() {
        let p = WebServer.FeedRelayPacer(initialFileSize: 0, seedBytesPerSecond: rate)
        deliverSteadily(p, seconds: 200, from: t0)            // ~250 MB paced
        // One bad 2 s window: the cache file grew only 0.4 MB/s (a source hiccup). EWMA 0.7/0.3 → the estimate drops.
        let now = t0.addingTimeInterval(200)
        p.maybeUpdateObservedRate(currentFileSize: 0, now: now.addingTimeInterval(-2))   // prime the window
        p.maybeUpdateObservedRate(currentFileSize: 800_000, now: now)
        let d = p.delayBeforeSending(chunkBytes: Int(rate * 0.05), now: now)
        // Before the cap this was ~45 s. Now it is held at most maxHoldSeconds.
        #expect(d <= WebServer.FeedRelayPacer.maxHoldSeconds, "held a chunk for \(d)s after the rate estimate fell")
    }

    @Test func afterReanchoring_deliveryResumesImmediately() {
        let p = WebServer.FeedRelayPacer(initialFileSize: 0, seedBytesPerSecond: rate)
        deliverSteadily(p, seconds: 200, from: t0)
        let now = t0.addingTimeInterval(200)
        p.maybeUpdateObservedRate(currentFileSize: 0, now: now.addingTimeInterval(-2))
        p.maybeUpdateObservedRate(currentFileSize: 800_000, now: now)
        _ = p.delayBeforeSending(chunkBytes: Int(rate * 0.05), now: now)          // re-anchors
        let next = p.delayBeforeSending(chunkBytes: Int(rate * 0.05), now: now.addingTimeInterval(0.05))
        #expect(next <= 0.6, "still holding \(next)s after the schedule was re-anchored")
    }

    @Test func aBurstAheadOfThePace_isStillSmoothedUpToTheCap() {
        let p = WebServer.FeedRelayPacer(initialFileSize: 0, seedBytesPerSecond: rate)
        // 3 s worth of bytes arriving at once is held back (smoothing), but never beyond the cap.
        let d = p.delayBeforeSending(chunkBytes: Int(rate * 3), now: t0)
        #expect(d > 0.5 && d <= WebServer.FeedRelayPacer.maxHoldSeconds + 3.0, "burst delay \(d)")
    }
}
