import Testing
import Foundation
@testable import hdhr_VCR

// MARK: - UpdateChecker
//
// Zero prior coverage — UpdateChecker.swift was 0% at the 2026-08-15 coverage pass that added it.
// isVersion(_:newerThan:) is pure and tested directly; checkForUpdate(currentVersion:session:)'s
// success/HTTP-error/malformed-JSON/network-error/not-actually-newer paths go through a mocked
// URLSession, the same injectable-session shape as DiscordNotifier/HDHRManager.
//
// Own mock URLProtocol storage — see HDHRManagerTests/DiscordNotifierTests for why each mocking
// file needs its own `requestHandler` slot rather than sharing one. Shared request-replay
// mechanics live in TestFixtures.swift's `MockURLProtocolBase`.

private final class UpdateCheckMockURLProtocol: MockURLProtocolBase {
    private static var _handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { _handler }
        set { _handler = newValue }
    }
}

private func makeUpdateCheckSession() -> URLSession { makeMockSession(UpdateCheckMockURLProtocol.self) }

private func releaseJSON(tag: String, htmlURL: String = "https://github.com/identd113/hdhr_VCR_swift/releases/tag/x") -> Data {
    Data("""
    {"tag_name":"\(tag)","html_url":"\(htmlURL)"}
    """.utf8)
}

@Suite("UpdateChecker: isVersion(_:newerThan:)")
struct IsVersionTests {
    // One (version, than → expectedNewer) table.
    @Test(arguments: [
        // "2.0.10" < "2.0.9" as strings, but 10 > 9 numerically — the whole reason for
        // component-wise comparison instead of a raw string/lexicographic compare. Also covers
        // strictlyNewerPatch (identical inputs).
        (version: "2.0.10",   than: "2.0.9",   expectedNewer: true),   // strictlyNewerPatch / plainStringCompareWouldGetThisWrong (1/2)
        // Missing trailing components are treated as 0, so "2.1" beats "2.0.9".
        (version: "2.1",      than: "2.0.9",   expectedNewer: true),   // strictlyNewerMinor_shorterString
        (version: "2.0.4",    than: "2.0.4",   expectedNewer: false),  // equalVersions_notNewer
        (version: "2.0.3",    than: "2.0.4",   expectedNewer: false),  // olderVersion_notNewer
        (version: "2.0.9",    than: "2.0.10",  expectedNewer: false),  // plainStringCompareWouldGetThisWrong (2/2)
        (version: "2.0.beta", than: "2.0.0",   expectedNewer: false),  // nonNumericComponent_treatedAsZero
    ])
    func compare(_ row: (version: String, than: String, expectedNewer: Bool)) {
        #expect(isVersion(row.version, newerThan: row.than) == row.expectedNewer)
    }
}

@Suite("UpdateChecker: checkForUpdate(currentVersion:session:)", .serialized)
struct CheckForUpdateTests {
    @Test func newerReleaseAvailable_returnsResult() async {
        UpdateCheckMockURLProtocol.requestHandler = { req in
            (mockOKResponse(for: req.url!), releaseJSON(tag: "v2.0.5", htmlURL: "https://github.com/identd113/hdhr_VCR_swift/releases/tag/v2.0.5"))
        }
        let result = await checkForUpdate(currentVersion: "2.0.4", session: makeUpdateCheckSession())
        #expect(result?.latestVersion == "2.0.5")
        #expect(result?.releaseURL.absoluteString == "https://github.com/identd113/hdhr_VCR_swift/releases/tag/v2.0.5")
    }

    // Not every GitHub tag is prefixed with "v" — strip only if present.
    @Test func tagWithoutVPrefix_parsedCorrectly() async {
        UpdateCheckMockURLProtocol.requestHandler = { req in
            (mockOKResponse(for: req.url!), releaseJSON(tag: "2.0.5"))
        }
        let result = await checkForUpdate(currentVersion: "2.0.4", session: makeUpdateCheckSession())
        #expect(result?.latestVersion == "2.0.5")
    }

    @Test func currentVersionUpToDate_returnsNil() async {
        UpdateCheckMockURLProtocol.requestHandler = { req in
            (mockOKResponse(for: req.url!), releaseJSON(tag: "v2.0.4"))
        }
        let result = await checkForUpdate(currentVersion: "2.0.4", session: makeUpdateCheckSession())
        #expect(result == nil)
    }

    @Test func currentVersionNewerThanLatestTag_returnsNil() async {
        // Can happen mid-development: a dev build's CFBundleShortVersionString still reflects
        // the last real release, but guard against the inverse regardless.
        UpdateCheckMockURLProtocol.requestHandler = { req in
            (mockOKResponse(for: req.url!), releaseJSON(tag: "v1.0.0"))
        }
        let result = await checkForUpdate(currentVersion: "2.0.4", session: makeUpdateCheckSession())
        #expect(result == nil)
    }

    @Test func emptyCurrentVersion_returnsNilWithoutNetworkCall() async {
        UpdateCheckMockURLProtocol.requestHandler = { _ in
            Issue.record("should not fetch when currentVersion is empty")
            throw URLError(.badURL)
        }
        let result = await checkForUpdate(currentVersion: "", session: makeUpdateCheckSession())
        #expect(result == nil)
    }

    @Test func httpErrorStatus_returnsNil() async {
        UpdateCheckMockURLProtocol.requestHandler = { req in
            (mockOKResponse(for: req.url!, statusCode: 404), Data())
        }
        let result = await checkForUpdate(currentVersion: "2.0.4", session: makeUpdateCheckSession())
        #expect(result == nil)
    }

    @Test func rateLimited_returnsNil() async {
        UpdateCheckMockURLProtocol.requestHandler = { req in
            (mockOKResponse(for: req.url!, statusCode: 403), Data("{\"message\":\"API rate limit exceeded\"}".utf8))
        }
        let result = await checkForUpdate(currentVersion: "2.0.4", session: makeUpdateCheckSession())
        #expect(result == nil)
    }

    @Test func malformedJSON_returnsNil() async {
        UpdateCheckMockURLProtocol.requestHandler = { req in
            (mockOKResponse(for: req.url!), Data("not json".utf8))
        }
        let result = await checkForUpdate(currentVersion: "2.0.4", session: makeUpdateCheckSession())
        #expect(result == nil)
    }

    @Test func missingHtmlURLField_returnsNil() async {
        UpdateCheckMockURLProtocol.requestHandler = { req in
            (mockOKResponse(for: req.url!), Data("{\"tag_name\":\"v9.9.9\"}".utf8))
        }
        let result = await checkForUpdate(currentVersion: "2.0.4", session: makeUpdateCheckSession())
        #expect(result == nil)
    }

    @Test func networkFailure_returnsNil() async {
        UpdateCheckMockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
        let result = await checkForUpdate(currentVersion: "2.0.4", session: makeUpdateCheckSession())
        #expect(result == nil)
    }
}
