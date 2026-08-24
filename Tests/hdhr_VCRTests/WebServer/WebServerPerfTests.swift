import Testing
import Foundation
@testable import hdhr_VCR

// MARK: - Performance regression baseline
//
// These tests connect to the running app on localhost:1980 — same convention as
// WebServerSmokeTests in WebServerTests.swift — and assert response latency stays within a
// generous multiple of the measured warm-cache baseline. They exist to catch the class of
// regression where per-request work that should be cached/precomputed (e.g. gzip-compressing the
// guide page) gets redone on every request instead: a ~10-30x latency jump that's easy to miss by
// eye but obvious once measured (see docs/WebServer.md's HTML cache section for the numbers this
// was tuned against). Run `./deploy.sh` first so the server is up; tests skip silently otherwise,
// so they're safe in CI/sandboxes with no device/network.
//
// Thresholds are deliberately loose (many multiples of the current baseline) to avoid flaking on
// a loaded machine — they're sized to catch a real architectural regression (missing cache,
// O(n) blowup), not to enforce a specific millisecond figure.

private let pageLoadThreshold: TimeInterval = 0.050   // GET / warm-cache baseline is ~1-5ms
private let apiCallThreshold: TimeInterval  = 0.050   // small JSON endpoints are ~1-5ms too
private let refreshThreshold: TimeInterval  = 0.250   // /api/guide-refresh rebuilds live, not cached
// Looser still than refreshThreshold — this measures a normal client's wait right behind a
// MainActor-blocking rebuild triggered by something else entirely (see
// apiLatency_staysResponsive_duringGuideChangeBurst below), not the rebuild's own cost.
private let heavyLoadPingThreshold: TimeInterval = 0.500
private let heavyBurstCount = 10   // even — see that test's own comment on why this must stay even
private let sampleCount = 5

private func serverAvailable(port: Int = 1980) async -> Bool {
    guard let (status, _, _) = try? await timedGet("/api/ping", port: port) else { return false }
    return status == 200
}

// Returns (status, body, elapsed) — elapsed is client-measured wall time for the full
// request/response round-trip, matching what a real browser experiences.
private func timedGet(_ path: String, port: Int = 1980, timeout: Double = 5) async throws -> (Int, Data, TimeInterval) {
    let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
    var req = URLRequest(url: url, timeoutInterval: timeout)
    req.cachePolicy = .reloadIgnoringLocalCacheData
    let start = Date()
    let (data, resp) = try await URLSession.shared.data(for: req)
    let elapsed = Date().timeIntervalSince(start)
    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
    return (status, data, elapsed)
}

private func get(_ path: String, port: Int = 1980, timeout: Double = 5) async throws -> (Int, Data) {
    let (status, data, _) = try await timedGet(path, port: port, timeout: timeout)
    return (status, data)
}

// Issues `path` several times back-to-back and returns the median elapsed time — a single sample
// is noisy (scheduler jitter, first-request-after-idle costs); the median of a few warm requests
// is a stable, representative number.
private func medianLatency(_ path: String, port: Int = 1980, samples: Int = sampleCount) async throws -> TimeInterval {
    var times: [TimeInterval] = []
    for _ in 0..<samples {
        let (status, _, elapsed) = try await timedGet(path, port: port)
        #expect(status == 200, "\(path) returned \(status)")
        times.append(elapsed)
    }
    times.sort()
    return times[times.count / 2]
}

@Suite("Post-deploy: web server performance baseline (requires running app on :1980)")
struct WebServerPerfTests {

    @Test func pageLoad_underThreshold() async throws {
        guard await serverAvailable() else { return }
        let median = try await medianLatency("/")
        #expect(median < pageLoadThreshold,
            "GET / median \(Int(median * 1000))ms exceeds \(Int(pageLoadThreshold * 1000))ms baseline — check cachedHTML/cachedHTMLGzip are actually warm (prebuildPageHTML) and not being recomputed per-request")
    }

    @Test func pageLoad_isGzipCompressed() async throws {
        guard await serverAvailable() else { return }
        let url = URL(string: "http://127.0.0.1:1980/")!
        var req = URLRequest(url: url)
        req.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as? HTTPURLResponse
        #expect((http?.value(forHTTPHeaderField: "Content-Encoding") ?? "").lowercased() == "gzip")
        // A regression that silently fell back to serving the raw ~1.5MB page would still return
        // 200 with valid content, so size (not just status) is the signal that matters here.
        #expect(data.count > 100_000, "decoded body suspiciously small — is the guide actually loaded?")
    }

    // One (path → under apiCallThreshold) table — both endpoints share the identical assertion
    // shape and threshold. pageLoad_underThreshold above stays separate: it uses a different
    // threshold (pageLoadThreshold) and a richer diagnostic message worth keeping intact.
    @Test(arguments: ["/api/ping", "/api/now.json"])   // pingLatency_underThreshold, nowJsonLatency_underThreshold
    func apiLatency_underThreshold(_ path: String) async throws {
        guard await serverAvailable() else { return }
        let median = try await medianLatency(path)
        #expect(median < apiCallThreshold, "\(path) median \(Int(median * 1000))ms exceeds \(Int(apiCallThreshold * 1000))ms baseline")
    }

    @Test func guideDetailLatency_underThreshold() async throws {
        guard await serverAvailable() else { return }
        // Discover a real device/channel from /api/now.json so this exercises the actual
        // entries-lookup + JSON-encoding path, not just the empty-result fast path.
        let (status, body) = try await get("/api/now.json")
        #expect(status == 200)
        guard let arr = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]],
              let first = arr.first,
              let devId = first["deviceId"] as? String,
              let num   = first["guideNumber"] as? String else {
            return   // no live guide data in this environment — nothing to measure
        }
        // winStart/winSec: the endpoint accepts a client-supplied window and falls back to "now"
        // if malformed (see WebServer.md's Lazy heavy-data loading section), so an approximate
        // recent window is fine here — this test isn't validating window-matching, just latency.
        let winStart = Int(Date().timeIntervalSince1970) - 3600
        let median = try await medianLatency("/api/guide-detail/\(devId)/\(num)/\(winStart)/86400")
        #expect(median < apiCallThreshold)
    }

    @Test func guideRefreshLatency_underThreshold() async throws {
        guard await serverAvailable() else { return }
        // Unlike GET /, this rebuilds the full grid HTML + tuner dropdowns live on every call
        // (refreshGuide() needs fresh data) — not cached, so a separate, looser threshold.
        let median = try await medianLatency("/api/guide-refresh", samples: 3)
        #expect(median < refreshThreshold,
            "guide-refresh median \(Int(median * 1000))ms — this rebuilds the grid live so some slack is expected, but this suggests a real O(n) regression in buildGuideGridHTML")
    }

    // Reported live: the web guide feels laggy while the app is doing something "heavy" —
    // ISSUES.md's open entry on this. The prime suspect, already flagged separately in TODO.md
    // ("Watch for UI hitches from broadcastGuideChangeEvent's wider call-site fan-out"), is that
    // 9+ show-lifecycle events (add/edit/delete/pause/resume/favorite-toggle/etc.) each trigger a
    // full `@MainActor` rebuild (buildGuideGridHTML + buildDevBarHTML + gzip'd prebuildPageHTML)
    // — previously only the hourly refresh and recording start/stop paid that cost. This measures
    // whether *unrelated* traffic (a normal client loading the guide) stays responsive while that
    // rebuild fires repeatedly back-to-back, without needing a real recording (which would tie up
    // a tuner and write a file) or any new mocking — POST /api/toggle-favorite on a real channel
    // is the cheapest real trigger of the same broadcastGuideChangeEvent path, and toggling it an
    // even number of times leaves the channel's favorite state exactly as found.
    @Test func apiLatency_staysResponsive_duringGuideChangeBurst() async throws {
        guard await serverAvailable() else { return }
        let (status, body) = try await get("/api/now.json")
        #expect(status == 200)
        guard let arr = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]],
              let first = arr.first,
              let devId = first["deviceId"] as? String,
              let num   = first["guideNumber"] as? String else {
            return   // no live guide data in this environment — nothing to measure
        }

        func toggleFavorite() async throws {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:1980/api/toggle-favorite")!)
            req.httpMethod = "POST"
            req.httpBody = try JSONSerialization.data(withJSONObject: ["deviceId": devId, "guideNumber": num])
            _ = try await URLSession.shared.data(for: req)
        }

        // Interleaved, not concurrent: each toggle fires the full rebuild, then the very next
        // request measures how long a normal client would wait right behind it — the worst-case
        // gap a real user would actually feel, not just the rebuild's own isolated cost.
        var pingTimes: [TimeInterval] = []
        for _ in 0..<heavyBurstCount {
            try await toggleFavorite()
            let (pingStatus, _, elapsed) = try await timedGet("/api/ping")
            #expect(pingStatus == 200)
            pingTimes.append(elapsed)
        }

        pingTimes.sort()
        let median = pingTimes[pingTimes.count / 2]
        let worst  = pingTimes.last ?? 0
        #expect(median < heavyLoadPingThreshold,
            "/api/ping median \(Int(median * 1000))ms right after a favorite-toggle rebuild (worst \(Int(worst * 1000))ms) — suggests broadcastGuideChangeEvent's MainActor rebuild is blocking normal traffic longer than expected")
    }
}
