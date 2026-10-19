import Foundation

/// Rolling two-minute view of a stream's bitrate, and a plain-language verdict on it.
///
/// Source: VLC's `f_demux_bitrate` read as bytes/µs, so raw × 8 = Mbps. The tuner's own `/status.json` `NetworkRate`
/// is erratic and not used.
///
/// Pure value type (no clock, no VLC) so the rules are unit-testable. Thresholds were tuned on real streams sampled every
/// 3 s: a flat 85 % cutoff flipped to "trending" 9–27 % of the time on healthy streams; 75 % against the smoothed last
/// three readings did so 0–7 % of the time and still catches real dips.
struct ThroughputTracker {
    enum State: Equatable {
        case measuring      // not enough history yet
        case steady
        case trending       // recent readings well under the two-minute average (yellow)
        case stalled        // two readings in a row near zero (red)

        var label: String {
            switch self {
            case .measuring: return "Measuring"
            case .steady:    return "Steady"
            case .trending:  return "Trending down"
            case .stalled:   return "Stalled"
            }
        }
    }

    static let window: TimeInterval = 120
    static let minHistory: TimeInterval = 30
    static let trendingBelow = 0.75     // smoothed (last 3) under this fraction of the baseline average
    static let stallBelow = 0.25        // two consecutive readings under this fraction
    static let lowRateFloor = 0.5       // Mbps: a baseline under this is a tiny subchannel; ratios mean nothing

    private(set) var samples: [(at: TimeInterval, mbps: Double)] = []

    nonisolated static func mbps(fromVLCRaw raw: Float) -> Double { Double(raw) * 8 }

    /// Whether a fresh reading belongs in the window: only while actually playing and not paused. A paused stream, or one
    /// still starting, reads ~0 — counting that would show a false "Stalled" and drag the average down.
    nonisolated static func shouldRecord(isPlaying: Bool, isPaused: Bool) -> Bool { isPlaying && !isPaused }

    mutating func add(mbps: Double, at: TimeInterval) {
        samples.append((at, mbps))
        samples.removeAll { at - $0.at > Self.window }
    }

    mutating func reset() { samples.removeAll() }

    /// Latest reading.
    var current: Double? { samples.last?.mbps }

    /// Mean over the whole window, including recent readings (what the readout shows as "2-min average").
    var average: Double? {
        samples.isEmpty ? nil : samples.reduce(0) { $0 + $1.mbps } / Double(samples.count)
    }

    /// Mean of the last three readings; smooths a single noisy sample.
    private var smoothed: Double? {
        let tail = samples.suffix(3)
        return tail.count == 3 ? tail.reduce(0) { $0 + $1.mbps } / 3 : nil
    }

    /// The baseline a reading is judged against: the window's mean *before* the last three readings, so a fresh dip
    /// can't drag its own yardstick down.
    private var baseline: Double? {
        let older = samples.dropLast(3)
        return older.count >= 5 ? older.reduce(0) { $0 + $1.mbps } / Double(older.count) : nil
    }

    var state: State {
        guard let first = samples.first, let last = samples.last, last.at - first.at >= Self.minHistory,
              let base = baseline, let smooth = smoothed else { return .measuring }
        guard base >= Self.lowRateFloor else { return .steady }
        let lastTwo = samples.suffix(2)
        if lastTwo.count == 2, lastTwo.allSatisfy({ $0.mbps < Self.stallBelow * base }) { return .stalled }
        if smooth < Self.trendingBelow * base { return .trending }
        return .steady
    }
}
