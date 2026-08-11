import Testing
import Foundation
@testable import hdhr_VCR

// he() coverage lives in WebServerHelperTests.swift (the canonical suite for the injection
// boundary) — a per-character suite here duplicated it across files and was folded in.

// MARK: - timeRemaining(until:)

@Suite("timeRemaining(until:) duration formatting")
struct TimeRemainingTests {

    // One (offset → label) table: every body was identical except the interval and the
    // expected string. Future rows add 5 s so Int(...) truncation of sub-millisecond
    // execution time never crosses the boundary being tested; the three ≤ 60 s rows pin
    // the "ending soon" floor (zero, past, and under-a-minute).
    @Test(arguments: [
        (seconds: 0.0,     expected: "ending soon"),
        (seconds: -60.0,   expected: "ending soon"),
        (seconds: 30.0,    expected: "ending soon"),
        (seconds: 65.0,    expected: "1m left"),      // 1 min
        (seconds: 2705.0,  expected: "45m left"),     // 45 min
        (seconds: 3665.0,  expected: "1h 1m left"),   // 61 min
        (seconds: 5405.0,  expected: "1h 30m left"),  // 90 min
        // 120 min: clearly ≥ 120m so h=2, m=0 → "2h left" (no dangling "0m").
        (seconds: 7205.0,  expected: "2h left"),
        (seconds: 7505.0,  expected: "2h 5m left"),   // 125 min
    ])
    func formatsRemainingDuration(_ row: (seconds: Double, expected: String)) {
        #expect(timeRemaining(until: Date(timeIntervalSinceNow: row.seconds)) == row.expected)
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

// Sends a raw HTTP request over a fresh TCP socket and returns the response text (up to 64 KB).
// Needed for malformed / non-standard requests URLSession refuses to send (negative Content-Length,
// HEAD, HTTP/1.0) — exercising the keep-alive reuse gate and the crash guard directly.
private func rawRequest(_ request: String, port: UInt16 = 1980, timeout: Double = 3) -> String? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
    var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    let connected = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard connected == 0 else { return nil }
    _ = Array(request.utf8).withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
    var buf = [UInt8](repeating: 0, count: 65536)
    let n = recv(fd, &buf, buf.count, 0)
    return n > 0 ? String(decoding: buf[0..<n], as: UTF8.self) : ""
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
        #expect(html.contains("hdhrVCRplus"))
    }

    @Test func verticalReturnsHTML() async throws {
        guard await serverAvailable() else { return }
        let (status, body) = try await get("/vertical")
        #expect(status == 200)
        let html = String(data: body, encoding: .utf8) ?? ""
        #expect(html.contains("<!DOCTYPE html>"))
        #expect(html.contains("hdhrVCRplus"))
        // /vertical is the one route that ships the vertical time-axis stylesheet and bakes
        // VT_ELIGIBLE=true — GET / must never carry either (see CLAUDE.md's "Vertical time-axis
        // mode is per-route, not global" invariant). A real deploy has the template file present,
        // so this also guards against the includeVerticalCSS-but-template-missing case where
        // VT_ELIGIBLE would wrongly stay/become true with no matching CSS actually embedded.
        #expect(html.contains("var _vtEligible=true;"))
        #expect(html.contains("@media (orientation: portrait)"))
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

    @Test func negativeContentLengthDoesNotCrash() async throws {
        guard await serverAvailable() else { return }
        // A negative Content-Length used to make dropFirst(-1) trap and crash the whole app.
        // The server must reject it (400), and — the real assertion — still be alive afterward.
        let resp = rawRequest("POST /api/ping HTTP/1.1\r\nHost: x\r\nContent-Length: -1\r\n\r\n")
        #expect(resp?.contains("400") == true)
        let (status, _) = try await get("/api/ping")
        #expect(status == 200, "server crashed on a negative Content-Length")
    }

    @Test func guideDetailOverflowWindowDoesNotCrash() async throws {
        guard await serverAvailable() else { return }
        // An absurd-but-well-formed winStart/winSec used to overflow the winStart+winSec addition
        // and trap the whole app — a LAN client could kill in-progress recordings with one request.
        // The route must clamp to the server's own window instead of trapping.
        let (status, _) = try await get("/api/guide-detail/x/y/9223372036854775807/1")
        #expect(status == 200, "server crashed on an overflowing guide-detail window")
        let (pingStatus, _) = try await get("/api/ping")
        #expect(pingStatus == 200, "server crashed on an overflowing guide-detail window")
    }

    @Test func headRequestClosesConnection() async throws {
        guard await serverAvailable() else { return }
        // HEAD isn't safe to keep-alive (the server would send a body the client doesn't read,
        // desyncing a reused socket), so the reuse gate must force Connection: close.
        let resp = rawRequest("HEAD /api/ping HTTP/1.1\r\nHost: x\r\n\r\n") ?? ""
        #expect(resp.lowercased().contains("connection: close"))
    }

    @Test func http10RequestClosesConnection() async throws {
        guard await serverAvailable() else { return }
        // HTTP/1.0 defaults to close; keeping it alive would hang EOF-framed 1.0 clients until the
        // idle timer fires. The reuse gate only opts in HTTP/1.1.
        let resp = rawRequest("GET /api/ping HTTP/1.0\r\nHost: x\r\n\r\n") ?? ""
        #expect(resp.lowercased().contains("connection: close"))
    }
}
