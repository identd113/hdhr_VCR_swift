import Foundation

/// Rate limiter for [LAN] log lines, per key (the device host, optionally prefixed by kind). Status
/// is polled every few seconds per device, so an unreachable tuner would otherwise log a warning on
/// every poll — thousands of lines a day. The first failure in a streak is always logged; further
/// ones are counted and reported at most once per `interval`; the first success after a streak is
/// reported once, with how many were suppressed. Pure value type — clock passed in — for unit tests.
struct LANLogThrottle {
    static let interval: TimeInterval = 300
    private var streaks: [String: (lastLogged: Date, suppressed: Int)] = [:]

    /// Returns nil to stay quiet, or the number of earlier occurrences suppressed since the last line to log now.
    mutating func recordFailure(_ key: String, at now: Date) -> Int? {
        guard var s = streaks[key] else {
            streaks[key] = (now, 0)
            return 0
        }
        if now.timeIntervalSince(s.lastLogged) >= Self.interval {
            let suppressed = s.suppressed
            streaks[key] = (now, 0)
            return suppressed
        }
        s.suppressed += 1
        streaks[key] = s
        return nil
    }

    /// Returns the failure count of the streak that just ended (suppressed + the logged ones aren't
    /// distinguished — just "was failing"), or nil if `key` wasn't failing.
    mutating func recordSuccess(_ key: String) -> Int? {
        guard let s = streaks.removeValue(forKey: key) else { return nil }
        return s.suppressed
    }
}

/// Short-timeout GETs for HDHomeRun devices on the local network (status.json, vstatus, lineup).
///
/// `URLSession.shared` waits 60 s on a hung device, which stalled the callers (the player's
/// tuner-free wait, tuner-occupancy polling, the signal scan) far longer than their own cadence.
/// This uses a 10 s request timeout and logs — to `hdhrVCRplus.log` — a call that fails or takes
/// longer than `slowThreshold`, so a flaky or overloaded device shows up in the log afterwards
/// (grep `[LAN]`), throttled per host by `LANLogThrottle`. Public/internet URLs must NOT use this:
/// they belong behind a cache (see `ChannelIconCache`) rather than a retry-fast policy.
enum LANFetch {
    static let slowThreshold: TimeInterval = 3.0
    static let requestTimeout: TimeInterval = 10.0

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = requestTimeout
        c.timeoutIntervalForResource = requestTimeout * 2
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    // Shared by concurrent tasks (status polls run in a task group per device) — guarded by a lock.
    private static let throttleLock = NSLock()
    nonisolated(unsafe) private static var throttle = LANLogThrottle()

    private static func withThrottle<T>(_ body: (inout LANLogThrottle) -> T) -> T {
        throttleLock.lock(); defer { throttleLock.unlock() }
        return body(&throttle)
    }

    /// Returns the response body, or nil on any failure. `label` names the call in the log.
    static func data(from url: URL, label: String) async -> Data? {
        let started = Date()
        let host = url.host ?? "?"
        do {
            let (data, _) = try await session.data(from: url)
            let elapsed = Date().timeIntervalSince(started)
            if let n = withThrottle({ $0.recordSuccess("fail:\(host)") }) {
                glog("[LAN] \(host) reachable again (\(label))" + (n > 0 ? " — \(n) failure(s) were not logged" : ""))
            }
            if elapsed >= slowThreshold,
               let n = withThrottle({ $0.recordFailure("slow:\(host)", at: Date()) }) {
                glog("[LAN] slow \(label): \(String(format: "%.1f", elapsed))s \(host)\(url.path)" + (n > 0 ? " (+\(n) more slow calls since last note)" : ""), level: .warning)
            }
            return data
        } catch {
            let elapsed = Date().timeIntervalSince(started)
            if let n = withThrottle({ $0.recordFailure("fail:\(host)", at: Date()) }) {
                glog("[LAN] \(label) failed after \(String(format: "%.1f", elapsed))s \(host)\(url.path): \(error.localizedDescription)" + (n > 0 ? " (+\(n) more failures since last note)" : ""), level: .warning)
            }
            return nil
        }
    }
}
