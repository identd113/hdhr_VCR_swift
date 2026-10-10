import Foundation
import Security

/// Reads when a server's TLS certificate expires, so the app can warn *before* the guide service
/// stops working. 2026-10-09: SiliconDust's `*.hdhomerun.com` certificate expired and every guide
/// call failed its secure connection; the app can't renew it, but it can say so a couple of weeks
/// ahead (and GuideStore/AppState already say so when it actually fails).
enum CertificateExpiry {
    /// Days-remaining thresholds a warning is sent at — once each per certificate.
    static let warningDays = [14, 7, 3, 1]

    /// The leaf certificate's "not after" date, nil if it can't be read.
    static func notAfter(of cert: SecCertificate) -> Date? {
        guard let values = SecCertificateCopyValues(cert, [kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [CFString: Any],
              let entry = values[kSecOIDX509V1ValidityNotAfter] as? [CFString: Any],
              let raw = entry[kSecPropertyKeyValue] else { return nil }
        if let n = raw as? NSNumber { return Date(timeIntervalSinceReferenceDate: n.doubleValue) }
        return raw as? Date
    }

    /// Whole days from `now` until `expiry` (0 = under a day left; negative once expired).
    static func daysLeft(until expiry: Date, from now: Date = Date()) -> Int {
        Int(floor(expiry.timeIntervalSince(now) / 86_400))
    }

    /// The threshold a warning is due for, or nil: the smallest `warningDays` value `daysLeft` has
    /// reached, unless a warning at that threshold (or a lower one) was already sent for this
    /// certificate. `alreadyWarnedAt` is the lowest threshold warned so far (nil = none yet).
    static func dueThreshold(daysLeft: Int, alreadyWarnedAt: Int?) -> Int? {
        guard let t = warningDays.filter({ daysLeft <= $0 }).min() else { return nil }
        if let warned = alreadyWarnedAt, warned <= t { return nil }
        return t
    }

    /// Words for the advance warning (macOS notification + Discord).
    static func warningMessage(host: String, expiry: Date, daysLeft: Int)
        -> (title: String, subtitle: String, detail: String) {
        let f = DateFormatter()
        f.dateStyle = .medium; f.timeStyle = .short
        let when = daysLeft <= 0 ? "in under a day" : "in \(daysLeft) day\(daysLeft == 1 ? "" : "s")"
        return ("Guide Service Certificate Expiring",
                "\(host) expires \(when)",
                "🔒 The HDHomeRun guide service's secure certificate (\(host)) expires \(when) (\(f.string(from: expiry))). "
              + "SiliconDust has to renew it — nothing you need to do. If they don't in time, the guide stops refreshing "
              + "(hdhrVCRplus keeps using the last saved guide and tells you when it recovers).")
    }

    /// Connects to `host` over HTTPS and returns its certificate's expiry. Validation is untouched —
    /// the delegate only *reads* the certificate, then lets the normal checks run, so an already
    /// expired certificate still fails the request (the date is captured before that).
    static func fetchNotAfter(host: String, timeout: TimeInterval = 10) async -> Date? {
        guard let url = URL(string: "https://\(host)/") else { return nil }
        let probe = Probe()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config, delegate: probe, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        _ = try? await session.data(for: request)   // the outcome is irrelevant; the challenge already recorded the date
        return probe.notAfter
    }

    private final class Probe: NSObject, URLSessionDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var _notAfter: Date?
        var notAfter: Date? { lock.withLock { _notAfter } }

        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let trust = challenge.protectionSpace.serverTrust,
               let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first {
                let date = CertificateExpiry.notAfter(of: leaf)
                lock.withLock { _notAfter = date }
            }
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
