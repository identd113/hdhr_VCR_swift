import Testing
import Foundation
@testable import hdhr_VCR

// MARK: - he() HTML escaping

@Suite("he() HTML entity escaping")
struct HeEscapingTests {

    @Test func ampersand() {
        #expect(he("a & b") == "a &amp; b")
    }

    @Test func lessThan() {
        #expect(he("<script>") == "&lt;script&gt;")
    }

    @Test func greaterThan() {
        #expect(he("a>b") == "a&gt;b")
    }

    @Test func doubleQuote() {
        #expect(he("say \"hi\"") == "say &quot;hi&quot;")
    }

    @Test func multipleEntities() {
        #expect(he("<a href=\"x&y\">") == "&lt;a href=&quot;x&amp;y&quot;&gt;")
    }

    @Test func plainText_unchanged() {
        #expect(he("hello world") == "hello world")
    }

    @Test func empty_unchanged() {
        #expect(he("") == "")
    }
}

// MARK: - timeRemaining(until:)

@Suite("timeRemaining(until:) duration formatting")
struct TimeRemainingTests {

    @Test func endingSoon_zeroSeconds() {
        let past = Date(timeIntervalSinceNow: 0)
        #expect(timeRemaining(until: past) == "ending soon")
    }

    @Test func endingSoon_pastDate() {
        let past = Date(timeIntervalSinceNow: -60)
        #expect(timeRemaining(until: past) == "ending soon")
    }

    @Test func endingSoon_lessThanOneMinute() {
        let soon = Date(timeIntervalSinceNow: 30)
        #expect(timeRemaining(until: soon) == "ending soon")
    }

    // All future dates add 5 s so Int(...) truncation of sub-millisecond execution time
    // never crosses the boundary being tested.
    @Test func oneMinute() {
        let t = Date(timeIntervalSinceNow: 1 * 60 + 5)
        #expect(timeRemaining(until: t) == "1m left")
    }

    @Test func fortyFiveMinutes() {
        let t = Date(timeIntervalSinceNow: 45 * 60 + 5)
        #expect(timeRemaining(until: t) == "45m left")
    }

    @Test func oneHourOneMinute() {
        let t = Date(timeIntervalSinceNow: 61 * 60 + 5)
        #expect(timeRemaining(until: t) == "1h 1m left")
    }

    @Test func oneHourThirtyMinutes() {
        let t = Date(timeIntervalSinceNow: 90 * 60 + 5)
        #expect(timeRemaining(until: t) == "1h 30m left")
    }

    @Test func twoHoursNoMinutes() {
        // 120 minutes + 5 s: clearly ≥ 120m so h=2, m=0 → "2h left".
        let t = Date(timeIntervalSinceNow: 120 * 60 + 5)
        #expect(timeRemaining(until: t) == "2h left")
    }

    @Test func twoHoursFiveMinutes() {
        let t = Date(timeIntervalSinceNow: 125 * 60 + 5)
        #expect(timeRemaining(until: t) == "2h 5m left")
    }
}

// MARK: - AppConfig Codable — web server fields

@Suite("AppConfig Codable — web server fields")
struct AppConfigWebServerTests {

    private func decode(_ json: String) throws -> AppConfig {
        // AppConfig is Codable and wraps the config under a "config" key in the file JSON,
        // but is itself decodable directly for unit testing.
        let data = Data(json.utf8)
        return try JSONDecoder().decode(AppConfig.self, from: data)
    }

    @Test func webServer_defaultsWhenAbsent() throws {
        let cfg = try decode("{}")
        #expect(cfg.Web_server_enabled == false)
        #expect(cfg.Web_server_port == 1980)
    }

    @Test func webServer_enabled_roundTrips() throws {
        let cfg = try decode(#"{"Web_server_enabled": true, "Web_server_port": 8080}"#)
        #expect(cfg.Web_server_enabled == true)
        #expect(cfg.Web_server_port == 8080)
    }

    @Test func webServer_port_defaultsTo1980WhenKeyAbsent() throws {
        let cfg = try decode(#"{"Web_server_enabled": true}"#)
        #expect(cfg.Web_server_port == 1980)
    }

    @Test func webServer_disabled_defaultsToFalse() throws {
        let cfg = try decode(#"{"Web_server_port": 2000}"#)
        #expect(cfg.Web_server_enabled == false)
        #expect(cfg.Web_server_port == 2000)
    }

    @Test func webServer_encodes_andDecodes() throws {
        var cfg = AppConfig()
        cfg.Web_server_enabled = true
        cfg.Web_server_port = 3000
        let data = try JSONEncoder().encode(cfg)
        let cfg2 = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(cfg2.Web_server_enabled == true)
        #expect(cfg2.Web_server_port == 3000)
    }
}

// MARK: - Post-deploy HTTP smoke tests

// These tests connect to the running app on localhost:1980.
// They are skipped automatically when the port is not open — safe to run in CI.

// Pings /api/ping to confirm the server is up and responding end-to-end (not just port-bound).
private func serverAvailable(port: Int = 1980) async -> Bool {
    guard let (status, _) = try? await get("/api/ping", port: port) else { return false }
    return status == 200
}

private func get(_ path: String, port: Int = 1980, timeout: Double = 5) async throws -> (Int, Data) {
    let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
    var req = URLRequest(url: url, timeoutInterval: timeout)
    req.cachePolicy = .reloadIgnoringLocalCacheData
    let (data, resp) = try await URLSession.shared.data(for: req)
    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
    return (status, data)
}

@Suite("Post-deploy: web server smoke tests (requires running app on :1980)")
struct WebServerSmokeTests {

    @Test func pingReturnsOk() async throws {
        guard await serverAvailable() else { return }
        let (status, body) = try await get("/api/ping")
        #expect(status == 200)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["ok"] as? Bool == true)
    }

    @Test func rootReturnsHTML() async throws {
        guard await serverAvailable() else { return }
        let (status, body) = try await get("/")
        #expect(status == 200)
        let html = String(data: body, encoding: .utf8) ?? ""
        #expect(html.contains("<!DOCTYPE html>"))
        #expect(html.contains("hdhrVCR+"))
    }

    @Test func rootContentTypeIsHTML() async throws {
        guard await serverAvailable() else { return }
        let url = URL(string: "http://127.0.0.1:1980/")!
        let (_, resp) = try await URLSession.shared.data(from: url)
        let ct = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
        #expect(ct.hasPrefix("text/html"))
    }

    @Test func nowJsonReturnsValidArray() async throws {
        guard await serverAvailable() else { return }
        let (status, body) = try await get("/api/now.json")
        #expect(status == 200)
        let json = try JSONSerialization.jsonObject(with: body) as? [[String: Any]]
        #expect(json != nil)
        // Every entry must have the required string fields
        for entry in json ?? [] {
            #expect(entry["deviceId"] is String)
            #expect(entry["guideNumber"] is String)
            #expect(entry["title"] is String)
        }
    }

    @Test func unknownRouteReturns404() async throws {
        guard await serverAvailable() else { return }
        let (status, _) = try await get("/no/such/path")
        #expect(status == 404)
    }

    @Test func indexHtmlEqualsRoot() async throws {
        guard await serverAvailable() else { return }
        let (s1, d1) = try await get("/")
        let (s2, d2) = try await get("/index.html")
        #expect(s1 == 200)
        #expect(s2 == 200)
        // Both routes call buildHTML — size should be identical
        #expect(d1.count == d2.count)
    }

    @Test func connectionDefaultsToKeepAlive() async throws {
        guard await serverAvailable() else { return }
        // HTTP/1.1 keep-alive by default (unless the client sends "Connection: close") — avoids
        // paying a fresh TCP handshake for every one of the guide's ~20 lazy-load requests on a
        // real LAN client. See the connection-handling comment in WebServer.swift.
        let url = URL(string: "http://127.0.0.1:1980/api/now.json")!
        let (_, resp) = try await URLSession.shared.data(from: url)
        let conn = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Connection") ?? ""
        #expect(conn.lowercased() == "keep-alive")
    }

    @Test func connectionReusedAcrossRequests() async throws {
        guard await serverAvailable() else { return }
        // A single URLSession naturally reuses a kept-alive connection for same-host requests;
        // this isn't directly observable via the public API, so assert the behavioral proxy that
        // matters: several sequential requests on one session all succeed without the connection
        // getting cut mid-sequence (the old Connection: close behavior still would have passed
        // this, since each request opened its own connection — this is a smoke test, not a
        // reuse-proof, but paired with connectionDefaultsToKeepAlive above it covers the contract).
        for _ in 0..<5 {
            let (status, _) = try await get("/api/ping")
            #expect(status == 200)
        }
    }

    @Test func postToRecordWithoutBodyReturns400() async throws {
        guard await serverAvailable() else { return }
        let url = URL(string: "http://127.0.0.1:1980/api/record")!
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = "POST"
        req.httpBody = Data("{}".utf8)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        // Missing required fields → 400
        #expect(status == 400)
    }
}
