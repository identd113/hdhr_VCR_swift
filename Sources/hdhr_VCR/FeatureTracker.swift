import Foundation

/// Counts how often each newer data source is used versus how often the app fell back to the older method, and why.
/// Keys in use: `lineup.tuning` (`/lineup.json?tuning`), `lineup.status` (`/lineup_status.json`), `scan.skipCovered` (the daily air scan
/// skipping RF channels the lineup covers), `series.episodes` (`api/episodes` feeding series scheduling). Counts live in memory (they restart
/// with the app); every fallback is also logged, the first few times and then one line per ten, so a persistent problem is visible without flooding.
final class FeatureTracker: @unchecked Sendable {
    static let shared = FeatureTracker()

    struct Stat: Codable, Equatable {
        var used = 0
        var fellBack = 0
        var lastFallback: Date?
        var lastReason: String?
    }

    private let lock = NSLock()
    private var stats: [String: Stat] = [:]

    func used(_ feature: String) {
        lock.lock(); defer { lock.unlock() }
        stats[feature, default: Stat()].used += 1
    }

    func fellBack(_ feature: String, _ reason: String) {
        lock.lock()
        var s = stats[feature, default: Stat()]
        s.fellBack += 1; s.lastFallback = Date(); s.lastReason = reason
        stats[feature] = s
        let n = s.fellBack, usedCount = s.used
        lock.unlock()
        if n <= 3 || n % 10 == 0 { glog("[Features] \(feature) fell back to the older method (\(reason)) — used \(usedCount)×, fell back \(n)×", level: .warning) }
    }

    func snapshot() -> [String: Stat] { lock.lock(); defer { lock.unlock() }; return stats }

    func reset() { lock.lock(); stats = [:]; lock.unlock() }

    /// JSON-ready form for `/api/feature-stats`.
    func jsonObject() -> [String: Any] {
        let iso = ISO8601DateFormatter()
        return snapshot().mapValues { s in
            var o: [String: Any] = ["used": s.used, "fellBack": s.fellBack]
            if let d = s.lastFallback { o["lastFallback"] = iso.string(from: d) }
            if let r = s.lastReason { o["lastReason"] = r }
            return o
        }
    }
}
