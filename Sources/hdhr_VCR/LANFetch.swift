import Foundation

/// Short-timeout GETs for HDHomeRun devices on the local network (status.json, vstatus, lineup).
///
/// `URLSession.shared` waits 60 s on a hung device, which stalled the callers (the player's
/// tuner-free wait, tuner-occupancy polling, the signal scan) far longer than their own cadence.
/// This uses a 10 s request timeout and logs — to `hdhrVCRplus.log` — any call that fails or takes
/// longer than `slowThreshold`, so a flaky or overloaded device shows up in the log afterwards
/// (grep `[LAN]`). Public/internet URLs must NOT use this: they belong behind a cache (see
/// `ChannelIconCache`) rather than a retry-fast policy.
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

    /// Returns the response body, or nil on any failure. `label` names the call in the log.
    static func data(from url: URL, label: String) async -> Data? {
        let started = Date()
        do {
            let (data, _) = try await session.data(from: url)
            let elapsed = Date().timeIntervalSince(started)
            if elapsed >= slowThreshold {
                glog("[LAN] slow \(label): \(String(format: "%.1f", elapsed))s \(url.host ?? "") \(url.path)", level: .warning)
            }
            return data
        } catch {
            let elapsed = Date().timeIntervalSince(started)
            glog("[LAN] \(label) failed after \(String(format: "%.1f", elapsed))s \(url.host ?? "") \(url.path): \(error.localizedDescription)", level: .warning)
            return nil
        }
    }
}
