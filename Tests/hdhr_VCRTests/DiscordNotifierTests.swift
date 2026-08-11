import Testing
import Foundation
@testable import hdhr_VCR

// MARK: - DiscordNotifier
//
// Zero prior coverage despite being the only outbound integration besides HDHomeRun/guide APIs.
// Exercises isDiscordHost's validation (via the public functions' guard clauses — it's private,
// so tested through its observable contract, not directly) and sendDiscordEmbedCapturing's
// success/HTTP-error/malformed-JSON paths. sendDiscordEmbed/editDiscordEmbed are fire-and-forget
// (wrapped in an unstructured Task with no awaitable completion point), so only their guard-clause
// no-op behavior is covered here — the actual send/edit HTTP paths are exercised for free via
// sendDiscordEmbedCapturing, which is byte-for-byte the same guard/build/send shape.
//
// Own mock URLProtocol (not GuideStoreTests' MockURLProtocol) — that type's `requestHandler` is
// shared global mutable state; reusing it across files risks a cross-file race under Swift
// Testing's default parallel execution. A dedicated type + a `.serialized` suite here avoids that
// without depending on GuideStoreTests' own serialization boundary.

private final class DiscordMockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func makeDiscordMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [DiscordMockURLProtocol.self]
    return URLSession(configuration: config)
}

private func discordOKResponse(for url: URL) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
}

@Suite("DiscordNotifier", .serialized)
struct DiscordNotifierTests {

    // MARK: - Guard clauses (no network call should be made)

    @Test func emptyWebhookURL_returnsNilWithoutNetworkCall() async {
        DiscordMockURLProtocol.requestCount = 0
        DiscordMockURLProtocol.requestHandler = { _ in
            (discordOKResponse(for: URL(string: "https://discord.com")!), Data("{}".utf8))
        }
        let result = await sendDiscordEmbedCapturing(to: "", embed: ["title": "x"], session: makeDiscordMockSession())
        #expect(result == nil)
        #expect(DiscordMockURLProtocol.requestCount == 0)
    }

    @Test func nonDiscordHost_returnsNilWithoutNetworkCall() async {
        DiscordMockURLProtocol.requestCount = 0
        DiscordMockURLProtocol.requestHandler = { _ in
            (discordOKResponse(for: URL(string: "https://evil.com")!), Data("{}".utf8))
        }
        let result = await sendDiscordEmbedCapturing(to: "https://evil.com/webhook", embed: ["title": "x"], session: makeDiscordMockSession())
        #expect(result == nil)
        #expect(DiscordMockURLProtocol.requestCount == 0)
    }

    // isDiscordHost uses hasSuffix("." + domain), not a bare hasSuffix(domain) — guards against
    // "notdiscord.com" (no "." boundary) being accepted as a discord.com host.
    @Test func spoofedHostWithoutDotBoundary_returnsNilWithoutNetworkCall() async {
        DiscordMockURLProtocol.requestCount = 0
        DiscordMockURLProtocol.requestHandler = { _ in
            (discordOKResponse(for: URL(string: "https://notdiscord.com")!), Data("{}".utf8))
        }
        let result = await sendDiscordEmbedCapturing(to: "https://notdiscord.com/webhook", embed: ["title": "x"], session: makeDiscordMockSession())
        #expect(result == nil)
        #expect(DiscordMockURLProtocol.requestCount == 0)
    }

    // MARK: - Valid hosts (case-insensitivity, subdomains)

    @Test func uppercaseDiscordHost_stillMatches() async {
        DiscordMockURLProtocol.requestCount = 0
        DiscordMockURLProtocol.requestHandler = { req in
            (discordOKResponse(for: req.url!), Data(#"{"id":"abc123"}"#.utf8))
        }
        let result = await sendDiscordEmbedCapturing(to: "https://DISCORD.COM/api/webhooks/1/token", embed: ["title": "x"], session: makeDiscordMockSession())
        #expect(result == "abc123")
        #expect(DiscordMockURLProtocol.requestCount == 1)
    }

    @Test func discordappSubdomain_matches() async {
        DiscordMockURLProtocol.requestCount = 0
        DiscordMockURLProtocol.requestHandler = { req in
            (discordOKResponse(for: req.url!), Data(#"{"id":"abc123"}"#.utf8))
        }
        let result = await sendDiscordEmbedCapturing(to: "https://ptb.discordapp.com/api/webhooks/1/token", embed: ["title": "x"], session: makeDiscordMockSession())
        #expect(result == "abc123")
    }

    // MARK: - sendDiscordEmbedCapturing response handling

    @Test func successfulSend_returnsMessageId() async {
        DiscordMockURLProtocol.requestHandler = { req in
            (discordOKResponse(for: req.url!), Data(#"{"id":"999888777"}"#.utf8))
        }
        let result = await sendDiscordEmbedCapturing(to: "https://discord.com/api/webhooks/1/token", embed: ["title": "Recording Started"], session: makeDiscordMockSession())
        #expect(result == "999888777")
    }

    @Test func httpErrorStatus_returnsNil() async {
        DiscordMockURLProtocol.requestHandler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let result = await sendDiscordEmbedCapturing(to: "https://discord.com/api/webhooks/1/token", embed: ["title": "x"], session: makeDiscordMockSession())
        #expect(result == nil)
    }

    @Test func rateLimited429_returnsNil() async {
        DiscordMockURLProtocol.requestHandler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let result = await sendDiscordEmbedCapturing(to: "https://discord.com/api/webhooks/1/token", embed: ["title": "x"], session: makeDiscordMockSession())
        #expect(result == nil)
    }

    @Test func responseMissingIdField_returnsNil() async {
        DiscordMockURLProtocol.requestHandler = { req in
            (discordOKResponse(for: req.url!), Data(#"{"content":"no id here"}"#.utf8))
        }
        let result = await sendDiscordEmbedCapturing(to: "https://discord.com/api/webhooks/1/token", embed: ["title": "x"], session: makeDiscordMockSession())
        #expect(result == nil)
    }

    @Test func nonJSONResponseBody_returnsNil() async {
        DiscordMockURLProtocol.requestHandler = { req in
            (discordOKResponse(for: req.url!), Data("not json at all".utf8))
        }
        let result = await sendDiscordEmbedCapturing(to: "https://discord.com/api/webhooks/1/token", embed: ["title": "x"], session: makeDiscordMockSession())
        #expect(result == nil)
    }

    // wait=true is required for Discord to echo the created message body (source of the msgId
    // this function exists to capture) — a regression here would silently break every future
    // edit, since editDiscordEmbed needs that captured ID.
    @Test func waitTrueQueryParamIsAppended() async {
        var capturedURL: URL?
        DiscordMockURLProtocol.requestHandler = { req in
            capturedURL = req.url
            return (discordOKResponse(for: req.url!), Data(#"{"id":"1"}"#.utf8))
        }
        _ = await sendDiscordEmbedCapturing(to: "https://discord.com/api/webhooks/1/token", embed: ["title": "x"], session: makeDiscordMockSession())
        #expect(capturedURL?.query?.contains("wait=true") == true)
    }

    // MARK: - Fire-and-forget guard clauses (sendDiscordEmbed / editDiscordEmbed)

    @Test func sendDiscordEmbed_emptyURL_doesNotCrash() {
        // No session param on this fire-and-forget entry point in production callers, but the
        // guard clause itself is synchronous — an empty/invalid URL returns before Task{} is even
        // created, so nothing here needs awaiting.
        sendDiscordEmbed(to: "", embed: ["title": "x"])
        sendDiscordEmbed(to: "https://evil.com/webhook", embed: ["title": "x"])
    }

    @Test func editDiscordEmbed_emptyMessageId_doesNotCrash() {
        editDiscordEmbed(webhookURL: "https://discord.com/api/webhooks/1/token", messageId: "", embed: ["title": "x"])
        editDiscordEmbed(webhookURL: "", messageId: "123", embed: ["title": "x"])
    }
}
