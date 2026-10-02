import Testing
@testable import hdhr_VCR

// 2026-10-01 review #16 — cross-site request forgery / DNS-rebinding guard.
@Suite("WebServer.requestRejectionReason — cross-site / rebinding guard")
struct WebServerRequestGuardTests {
    private let names: Set<String> = ["woodflix.local", "woodflix"]

    private func reason(_ method: String, host: String?, origin: String? = nil,
                        site: String? = nil, type: String? = "application/json") -> String? {
        WebServer.requestRejectionReason(method: method, host: host, origin: origin, secFetchSite: site,
                                         contentType: type, localHostNames: names)
    }

    @Test func legitimateClients_pass() {
        #expect(reason("GET", host: "10.0.2.100:1980") == nil)
        #expect(reason("GET", host: "localhost:1980") == nil)
        #expect(reason("GET", host: "woodflix.local:1980") == nil)
        #expect(reason("GET", host: "woodflix:1980") == nil)
        #expect(reason("GET", host: "[fe80::1]:1980") == nil)
        #expect(reason("GET", host: nil) == nil)   // HTTP/1.0
        // guide.js (same-origin fetch), the in-app WKWebView, the hdhr_guide TUI (no Origin)
        #expect(reason("POST", host: "10.0.2.100:1980", origin: "http://10.0.2.100:1980", site: "same-origin") == nil)
        #expect(reason("POST", host: "localhost:1980", origin: "http://localhost:1980") == nil)
        #expect(reason("POST", host: "127.0.0.1:1980") == nil)
    }

    @Test func rebindingHost_isRefused() {
        #expect(reason("GET", host: "evil.example.com:1980") != nil)
        #expect(reason("POST", host: "rebind.attacker.net:1980", origin: "http://rebind.attacker.net:1980") != nil)
    }

    @Test func crossSitePosts_areRefused() {
        #expect(reason("POST", host: "10.0.2.100:1980", origin: "https://evil.example.com") != nil)
        #expect(reason("POST", host: "10.0.2.100:1980", origin: "null") != nil)
        #expect(reason("POST", host: "10.0.2.100:1980", site: "cross-site") != nil)
        // no-cors "simple" request bodies
        #expect(reason("POST", host: "10.0.2.100:1980", type: "text/plain") != nil)
        #expect(reason("POST", host: "10.0.2.100:1980", type: nil) != nil)
    }
}
