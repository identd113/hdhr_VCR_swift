import Testing
import Foundation
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

    @Test func routerAssignedName_acceptedOnlyWhenUnderTheLocalDomain() {
        let local = { (h: String) in h.hasSuffix(".fritz.box") }
        #expect(WebServer.requestRejectionReason(method: "GET", host: "macmini.fritz.box:1980", origin: nil, secFetchSite: nil,
                                                 contentType: nil, localHostNames: names, inLocalDomain: local) == nil)
        #expect(WebServer.requestRejectionReason(method: "GET", host: "evil.example.com:1980", origin: nil, secFetchSite: nil,
                                                 contentType: nil, localHostNames: names, inLocalDomain: local) != nil)
        // default (no domain check) keeps the old behavior
        #expect(reason("GET", host: "macmini.fritz.box:1980") != nil)
    }
}

@Suite("LocalHostVerifier — this network's own domain host check")
struct LocalHostVerifierTests {
    final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 1_000) }

    @Test func parseSearchDomains_readsSearchAndDomainLines() {
        let text = "# comment\nnameserver 10.0.0.1\ndomain fritz.box\nsearch home.example lan.example\n"
        #expect(LocalHostVerifier.parseSearchDomains(text) == ["fritz.box", "home.example", "lan.example"])
        #expect(LocalHostVerifier.parseSearchDomains("") == [])
    }

    @Test func inLocalDomain_acceptsOnlyNamesUnderTheNetworksDomain() {
        let v = LocalHostVerifier(searchDomains: { ["fritz.box", ".Home.Example.", "com", "localnet"] }, ownHostName: { "woodflix.local" })
        #expect(v.inLocalDomain("macmini.fritz.box"))
        #expect(v.inLocalDomain("MacMini.Home.Example"))
        #expect(v.inLocalDomain("a.b.fritz.box"))
        #expect(!v.inLocalDomain("fritz.box"))                    // the bare domain isn't a host label under it
        #expect(!v.inLocalDomain("evil.example.com"))             // rebinding attacker's domain
        #expect(!v.inLocalDomain("notfritz.box"))                 // suffix must be on a label boundary
        #expect(!v.inLocalDomain("evil.com"))                     // a bare "com" entry never widens the gate
    }

    @Test func ownHostNameDomainCounts() {
        let v = LocalHostVerifier(searchDomains: { [] }, ownHostName: { "macmini.attlocal.net" })
        #expect(v.inLocalDomain("printer.attlocal.net"))
        #expect(!v.inLocalDomain("printer.example.com"))
    }

    @Test func localHostNames_refreshAfterRename() {
        final class Name: @unchecked Sendable { var v = "Old.local" }
        let name = Name(), clock = Clock()
        let v = LocalHostVerifier(searchDomains: { [] }, ownHostName: { name.v }, now: { clock.t })
        #expect(v.localHostNames() == ["old.local", "old"])
        name.v = "New.local"
        #expect(v.localHostNames() == ["old.local", "old"])   // within the 60 s TTL
        clock.t = clock.t.addingTimeInterval(61)
        #expect(v.localHostNames() == ["new.local", "new"])
    }
}
