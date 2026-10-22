import Testing
import Foundation
@testable import hdhr_VCR

// 2026-10-22 audit: cross-site GET guard, connection admission, method allow-list, duplicate template tokens.
@Suite("WebServer hardening")
struct WebServerHardeningTests {
    private let names: Set<String> = ["woodflix.local"]

    private func reason(_ method: String, _ path: String, site: String?) -> String? {
        WebServer.requestRejectionReason(method: method, host: "10.0.2.100:1980", origin: nil, secFetchSite: site,
                                         contentType: nil, path: path, localHostNames: names)
    }

    @Test(arguments: ["/auto/v5.1", "/api/hls/abc/index.m3u8", "/api/watch-recording", "/api/feed-local-relay", "/api/transcode-source-relay"])
    func crossSiteGET_toSideEffectRoutes_isRefused(path: String) {
        #expect(reason("GET", path, site: "cross-site") != nil)
        #expect(reason("HEAD", path, site: "cross-site") != nil)
    }

    @Test(arguments: ["/auto/v5.1", "/api/hls/abc/index.m3u8", "/api/watch-recording"])
    func nonBrowserAndSameOriginGET_stillAllowed(path: String) {
        #expect(reason("GET", path, site: nil) == nil)          // VLC, curl, hdhr_guide send no header
        #expect(reason("GET", path, site: "same-origin") == nil)
        #expect(reason("GET", path, site: "none") == nil)
        #expect(reason("GET", path, site: "same-site") == nil)
    }

    @Test func crossSiteGET_toReadOnlyRoutes_isNotAffected() {
        #expect(reason("GET", "/", site: "cross-site") == nil)
        #expect(reason("GET", "/api/ping", site: "cross-site") == nil)
    }

    @Test func admission_capsPerIP_andTotal_butNeverLoopback() {
        let sixteen = Array(repeating: "10.0.0.5", count: WebServer.maxConnectionsPerIP)
        #expect(!WebServer.admitConnection(remoteIP: "10.0.0.5", existingLANIPs: sixteen))
        #expect(WebServer.admitConnection(remoteIP: "10.0.0.6", existingLANIPs: sixteen))
        let full = (0..<WebServer.maxLANConnections).map { "10.0.\($0 / 16).\($0 % 16)" }
        #expect(!WebServer.admitConnection(remoteIP: "10.9.9.9", existingLANIPs: full))
        #expect(WebServer.admitConnection(remoteIP: "127.0.0.1", existingLANIPs: full))
        #expect(WebServer.admitConnection(remoteIP: "::1", existingLANIPs: full))
        #expect(WebServer.admitConnection(remoteIP: nil, existingLANIPs: full))
    }

    @Test func servedMethods_areGetHeadPostOnly() {
        #expect(WebServer.servedMethods == ["GET", "HEAD", "POST"])
        #expect(WebServer.allowedMethods == "GET, HEAD, POST")
    }

    @Test func fillTemplate_duplicateToken_doesNotTrap() {
        let server = WebServer()
        #expect(server.fillTemplate("a{{X}}b", [("X", "1"), ("X", "2")]) == "a1b")
    }
}
