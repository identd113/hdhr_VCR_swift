import Foundation
import Testing
@testable import hdhr_VCR

#if DEBUG
// The API reference (APIDocs.swift, debug builds) must account for every route the web server answers, so it cannot drift.
struct APIDocsTests {
    private static var webServerSource: String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return (try? String(contentsOf: root.appendingPathComponent("Sources/hdhr_VCR/WebServer.swift"), encoding: .utf8)) ?? ""
    }

    @Test func everyRouteTheServerAnswersIsDocumented() throws {
        let source = Self.webServerSource
        try #require(!source.isEmpty, "could not read WebServer.swift")
        // "/api/…" literals (and the virtual tuner's three top-level files), as the router compares or prefix-matches them.
        let regex = try NSRegularExpression(pattern: #""(/api/[A-Za-z0-9_.\-]*/?|/discover\.json|/lineup\.json|/status\.json|/auto/v)""#)
        let found = Set(regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap { m -> String? in
            Range(m.range(at: 1), in: source).map { String(source[$0]) }
        })
        let known = APIDocs.documentedPaths.union(APIDocs.internalPaths).union(["/api/guide.json/", "/api/watch-recording"])
        let documentedPrefixes = Set(APIDocs.documentedPaths.map { $0.hasSuffix("/") ? $0 : $0 + "/" }).union(APIDocs.documentedPaths)
        let missing = found.filter { !known.contains($0) && !documentedPrefixes.contains($0) && !known.contains(String($0.dropLast())) }
        #expect(missing.isEmpty, "routes in WebServer.swift missing from APIDocs.routes: \(missing.sorted())")
    }

    @Test func theHelpJSONIsValidOpenAPIShape() throws {
        let json = try #require(try JSONSerialization.jsonObject(with: APIDocs.helpJSON()) as? [String: Any])
        #expect(json["openapi"] as? String == "3.0.3")
        let paths = try #require(json["paths"] as? [String: Any])
        #expect(paths["/api/ota-status"] != nil)
        #expect(paths.count >= 20)
    }

    @Test func postExampleBodiesAreValidJSON() throws {
        for r in APIDocs.routes where r.method == "POST" {
            let data = try #require(r.body?.data(using: .utf8), "\(r.path) has no example body")
            #expect((try? JSONSerialization.jsonObject(with: data)) != nil, "\(r.path) example is not valid JSON")
        }
    }
}
#endif
