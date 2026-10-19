import Testing
import Foundation
@testable import hdhr_VCR

@Suite("ThroughputTracker")
struct ThroughputTrackerTests {

    /// Feeds `values` three seconds apart (the player's stats tick).
    private func tracker(_ values: [Double]) -> ThroughputTracker {
        var t = ThroughputTracker()
        for (i, v) in values.enumerated() { t.add(mbps: v, at: Double(i) * 3) }
        return t
    }

    private let healthy = [9.0, 8.5, 10.0, 9.5, 8.0, 9.2, 10.5, 9.0, 8.8, 9.6, 9.1, 8.7]   // 33 s of ~9 Mbps

    @Test func unitIsBytesPerMicrosecond_rawTimesEight() {
        #expect(ThroughputTracker.mbps(fromVLCRaw: 1.0) == 8.0)
        #expect(abs(ThroughputTracker.mbps(fromVLCRaw: 1.2) - 9.6) < 0.0001)
    }

    @Test func tooLittleHistory_isMeasuring() {
        #expect(tracker([9, 9, 9]).state == .measuring)
        #expect(tracker(Array(healthy.prefix(8))).state == .measuring)   // 21 s, under the 30 s minimum
    }

    @Test func steadyStream_isSteady_andAveragesTheWindow() {
        let t = tracker(healthy)
        #expect(t.state == .steady)
        #expect(abs(t.average! - healthy.reduce(0, +) / Double(healthy.count)) < 0.0001)
        #expect(t.current == healthy.last)
    }

    @Test func sustainedDrop_isTrending() {
        // 15 -> about 8 (53 %), the example that started this feature
        let t = tracker(healthy.map { $0 * 1.6 } + [8.0, 7.5, 8.2])      // baseline ~15 Mbps, now ~8
        #expect(t.state == .trending)
    }

    @Test func modestDrop_underTwentyFivePercent_isStillSteady() {
        #expect(tracker(healthy + [8.0, 7.5, 8.2]).state == .steady)    // ~13 % under the baseline
    }

    @Test func singleLowReading_doesNotFlipToTrending() {
        #expect(tracker(healthy + [9.0, 9.2, 4.0]).state == .steady)   // smoothed over three readings
    }

    @Test func twoNearZeroReadingsInARow_isStalled() {
        #expect(tracker(healthy + [9.0, 0.2, 0.0]).state == .stalled)
    }

    @Test func oneNearZeroReading_isNotYetStalled() {
        let t = tracker(healthy + [9.0, 9.1, 0.0])
        #expect(t.state != .stalled)
    }

    @Test func tinySubchannel_isNeverJudgedByRatio() {
        let quiet = Array(repeating: 0.3, count: 12) + [0.0, 0.0, 0.0]
        #expect(tracker(quiet).state == .steady)
    }

    @Test func samplesOlderThanTwoMinutes_areDropped() {
        var t = ThroughputTracker()
        t.add(mbps: 50, at: 0)
        for i in 1...50 { t.add(mbps: 5, at: 100 + Double(i)) }   // the 50 Mbps reading is >120 s old by now
        #expect(t.average == 5)
    }

    @Test func reset_forgetsEverything() {
        var t = tracker(healthy)
        t.reset()
        #expect(t.current == nil && t.average == nil && t.state == .measuring)
    }

    @Test func healthyRealisticVariation_staysSteadyAlmostAlways() {
        // ~9.5 Mbps mean, ~2 Mbps stdev, like the 2026-10-17 recording-relay runs; seeded so it is repeatable.
        var seed: UInt64 = 42
        func next() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
        var t = ThroughputTracker()
        var flagged = 0, judged = 0
        for i in 0..<120 {
            let v = 9.5 + (next() + next() + next() - 1.5) * 2.4
            t.add(mbps: max(0, v), at: Double(i) * 3)
            if t.state != .measuring { judged += 1; if t.state != .steady { flagged += 1 } }
        }
        #expect(Double(flagged) / Double(judged) < 0.10, "flagged \(flagged) of \(judged)")
    }

    @Test func pausedOrNotYetPlaying_readingsAreNotRecorded() {
        #expect(ThroughputTracker.shouldRecord(isPlaying: true, isPaused: false))
        #expect(!ThroughputTracker.shouldRecord(isPlaying: true, isPaused: true))      // a paused recording reads ~0
        #expect(!ThroughputTracker.shouldRecord(isPlaying: false, isPaused: false))    // still starting / buffering
    }
}
