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
private let heavyLoadPingThreshold: TimeInterval = 0.750   // measured baseline (4 SSE conns) ~350-460ms
private let heavyBurstCount = 10   // even — see that test's own comment on why this must stay even
private let sseConnectionCount = 4   // a couple of open guide tabs/windows — see the test's own comment
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

// .serialized: every test hits the one shared live server, so running them concurrently (Swift
// Testing's default) contaminates each other's latency numbers — apiLatency_staysResponsive_
// duringGuideChangeBurst deliberately generates real background load (held-open SSE connections
// + a broadcast burst) that's severe enough to time out an unrelated sibling test's requests if
// they overlap (caught live: apiLatency_underThreshold's /api/now.json hit its 5s timeout while
// racing this one).
@Suite("Post-deploy: web server performance baseline (requires running app on :1980)", .serialized)
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

    // Reported live: the web guide feels laggy while the app is doing something "heavy," and
    // specifically feels like slow *connecting* rather than a slow response once loaded. Root-
    // caused 2026-08-24 (see ISSUES.md's entry for the full trail — disk I/O pressure alone was
    // ruled out first): `broadcastGuideChangeEvent` (fired by 9+ show-lifecycle events —
    // add/edit/delete/pause/resume/favorite-toggle/etc.) embeds the *entire* guide grid HTML,
    // uncompressed, in the SSE event JSON — measured at ~2.2MB for one broadcast on this app's
    // real guide — and pushes that to every connected SSE client (every open web guide tab/
    // window). `NWListener`/every `NWConnection` share one serial `DispatchQueue` (`queue`, see
    // its own doc comment above `WebServer.stop()`), so those large sends compete directly with
    // accepting brand-new connections and every other connection's I/O — which is exactly why it
    // *feels* like connecting is slow: the TCP handshake itself stays instant, but nothing gets
    // read from the new connection's socket until the queue works through the SSE backlog first.
    // First attempt at this test (no SSE connections open) missed this entirely and passed
    // comfortably — the real trigger needs at least one open SSE connection, the same thing any
    // real browser tab on the guide page holds open for live updates.
    //
    // POST /api/toggle-favorite on a real channel is the cheapest real trigger of the same
    // broadcastGuideChangeEvent path (doesn't tie up a tuner or write a file, and an even count
    // leaves the channel's favorite state exactly as found).
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

        // A few held-open SSE connections — the ingredient the first version of this test was
        // missing. `bytes(for:)` streams rather than waiting for a response that never completes;
        // the loop just discards chunks to keep the connection alive and registered server-side.
        // Cancelling the Task is enough to tear the connection down at the end.
        func openSSEConnection() -> Task<Void, Never> {
            Task {
                guard let url = URL(string: "http://127.0.0.1:1980/api/events") else { return }
                guard let (bytes, _) = try? await URLSession.shared.bytes(for: URLRequest(url: url, timeoutInterval: 30)) else { return }
                do {
                    for try await _ in bytes where !Task.isCancelled {}
                } catch { }
            }
        }
        let sseTasks = (0..<sseConnectionCount).map { _ in openSSEConnection() }
        defer { sseTasks.forEach { $0.cancel() } }
        try await Task.sleep(nanoseconds: 300_000_000)   // let the connections actually register

        // Interleaved, not concurrent: each toggle fires the full rebuild + SSE fan-out, then the
        // very next request measures how long a normal client would wait right behind it — the
        // worst-case gap a real user would actually feel, not just the rebuild's own isolated cost.
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
