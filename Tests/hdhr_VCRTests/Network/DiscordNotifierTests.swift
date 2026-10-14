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
// Own mock URLProtocol storage (not GuideStoreTests' MockURLProtocol) — that type's
// `requestHandler` is shared global mutable state; reusing it across files risks a cross-file
// race under Swift Testing's default parallel execution. A dedicated type + a `.serialized`
// suite here avoids that without depending on GuideStoreTests' own serialization boundary.
// Shared request-replay mechanics live in TestFixtures.swift's `MockURLProtocolBase`.

private final class DiscordMockURLProtocol: MockURLProtocolBase {
    private static var _handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static var requestCount = 0

    override class var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { _handler }
        set { _handler = newValue }
    }
    override class func recordRequest() { requestCount += 1 }
}

private func makeDiscordMockSession() -> URLSession { makeMockSession(DiscordMockURLProtocol.self) }

private func discordOKResponse(for url: URL) -> HTTPURLResponse { mockOKResponse(for: url) }

@Suite("DiscordNotifier", .serialized)
struct DiscordNotifierTests {

    // MARK: - Guard clauses (no network call should be made)

    // One (webhookURL → guarded, no network call) table.
    @Test(arguments: [
        "",                            // emptyWebhookURL_returnsNilWithoutNetworkCall
        "https://evil.com/webhook",    // nonDiscordHost_returnsNilWithoutNetworkCall
        // isDiscordHost uses hasSuffix("." + domain), not a bare hasSuffix(domain) — guards
        // against "notdiscord.com" (no "." boundary) being accepted as a discord.com host.
        "https://notdiscord.com/webhook",  // spoofedHostWithoutDotBoundary_returnsNilWithoutNetworkCall
        "http://discord.com/api/webhooks/1/token",  // plain http would send the token in the clear
    ])
    func invalidWebhookURL_returnsNilWithoutNetworkCall(_ webhookURL: String) async {
        DiscordMockURLProtocol.requestCount = 0
        DiscordMockURLProtocol.requestHandler = { _ in
            (discordOKResponse(for: URL(string: "https://discord.com")!), Data("{}".utf8))
        }
        let result = await sendDiscordEmbedCapturing(to: webhookURL, embed: ["title": "x"], session: makeDiscordMockSession())
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

    // One (HTTP status code → returns nil) table.
    @Test(arguments: [500, 429])   // httpErrorStatus_returnsNil, rateLimited429_returnsNil
    func errorStatusCode_returnsNil(_ statusCode: Int) async {
        DiscordMockURLProtocol.requestHandler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let result = await sendDiscordEmbedCapturing(to: "https://discord.com/api/webhooks/1/token", embed: ["title": "x"], session: makeDiscordMockSession())
        #expect(result == nil)
    }

    // One (HTTP-200 response body → returns nil because it can't be parsed for an id) table.
    @Test(arguments: [
        #"{"content":"no id here"}"#,  // responseMissingIdField_returnsNil
        "not json at all",             // nonJSONResponseBody_returnsNil
    ])
    func unparsableResponseBody_returnsNil(_ responseBody: String) async {
        DiscordMockURLProtocol.requestHandler = { req in
            (discordOKResponse(for: req.url!), Data(responseBody.utf8))
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

    // MARK: - Rate limiting, edit URL (T20)

    @Test func rateLimited429_isRetriedAfterRetryAfter_thenSucceeds() async {
        DiscordMockURLProtocol.requestCount = 0
        DiscordMockURLProtocol.requestHandler = { req in
            if DiscordMockURLProtocol.requestCount == 1 {
                let r = HTTPURLResponse(url: req.url!, statusCode: 429, httpVersion: "HTTP/1.1", headerFields: ["Retry-After": "0"])!
                return (r, Data(#"{"retry_after":0}"#.utf8))
            }
            return (discordOKResponse(for: req.url!), Data(#"{"id":"m1"}"#.utf8))
        }
        let id = await sendDiscordEmbedCapturing(to: "https://discord.com/api/webhooks/1/token", embed: ["title": "x"], session: makeDiscordMockSession())
        #expect(id == "m1")
        #expect(DiscordMockURLProtocol.requestCount == 2)
    }

    @Test func persistent429_givesUpAfterTwoRetries() async {
        DiscordMockURLProtocol.requestCount = 0
        DiscordMockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 429, httpVersion: "HTTP/1.1", headerFields: ["Retry-After": "0"])!, Data("{}".utf8))
        }
        let id = await sendDiscordEmbedCapturing(to: "https://discord.com/api/webhooks/1/token", embed: ["title": "x"], session: makeDiscordMockSession())
        #expect(id == nil)
        #expect(DiscordMockURLProtocol.requestCount == 3)
    }

    @Test func retryDelay_prefersHeader_thenBody_andIsClamped() {
        #expect(discordRetryDelay(retryAfterHeader: "2", body: Data()) == 2)
        #expect(discordRetryDelay(retryAfterHeader: nil, body: Data(#"{"retry_after":1.5}"#.utf8)) == 1.5)
        #expect(discordRetryDelay(retryAfterHeader: nil, body: Data()) == 1)
        #expect(discordRetryDelay(retryAfterHeader: "9999", body: Data()) == 15)
        #expect(discordRetryDelay(retryAfterHeader: "0", body: Data()) == 0.1)
    }

    @Test func editURL_keepsThreadIdQueryAfterThePath() {
        let url = discordEditURL(webhookURL: "https://discord.com/api/webhooks/1/token?thread_id=99", messageId: "555")
        #expect(url?.absoluteString == "https://discord.com/api/webhooks/1/token/messages/555?thread_id=99")
        #expect(discordEditURL(webhookURL: "https://discord.com/api/webhooks/1/token/", messageId: "555")?.absoluteString
                == "https://discord.com/api/webhooks/1/token/messages/555")
    }

    @Test func editURL_rejectsPlainHttp_otherHosts_andEmptyId() {
        #expect(discordEditURL(webhookURL: "http://discord.com/api/webhooks/1/t", messageId: "5") == nil)
        #expect(discordEditURL(webhookURL: "https://evil.com/api/webhooks/1/t", messageId: "5") == nil)
        #expect(discordEditURL(webhookURL: "https://discord.com/api/webhooks/1/t", messageId: "") == nil)
    }
}
