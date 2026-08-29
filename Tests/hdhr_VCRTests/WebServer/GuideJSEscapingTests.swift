import Testing
import Foundation

// Regression coverage for the XSS fix in guide.js's hej() escaper (patched in commit 919a045,
// part of this cycle's pre-release review): a guide entry's poster ImageURL was concatenated into
// a search-dropdown <img src="..."> attribute via hej(), which escaped &, <, > but not " — a
// crafted ImageURL containing a double quote could break out of the attribute and inject
// arbitrary HTML/JS. hej() now escapes '"' too.
//
// This is guide.js's only test of any kind — there is no JS test harness anywhere in this repo,
// and adding one for the whole file isn't practical (it's full of unfilled `{{TOKEN}}` template
// placeholders and browser-only globals like `document`/`window`/`EventSource`, per CLAUDE.md's
// own note on validating it against the *served* output instead). Since hej() itself is a single,
// dependency-free line, this instead extracts just that line by regex from the real source file
// (so an edit to the real function is what's exercised here, not a hand-copied duplicate that
// could silently drift) and evaluates it in an actual `node` process — the same tool CLAUDE.md
// already assumes is available for `node --check`-validating this file. Skips gracefully (not a
// failure) if `node` isn't on this machine, mirroring how WindowNavigationTests.swift gates on
// environment preconditions it can't guarantee either.
@Suite("guide.js hej() escaper")
struct GuideJSEscapingTests {

    private func nodeIsAvailable() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "--version"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // Tests/hdhr_VCRTests/WebServer/<this file> → repo root is 4 path components up.
    private func guideJSPath() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/guide.js")
    }

    private func extractHej() throws -> String {
        let source = try String(contentsOf: guideJSPath(), encoding: .utf8)
        guard let range = source.range(of: #"function hej\(s\)\{[^\n]*\}"#, options: .regularExpression) else {
            Issue.record("could not find hej() in guide.js by regex — extraction pattern needs updating to match a real edit")
            return ""
        }
        return String(source[range])
    }

    // Passes the payload via an environment variable rather than embedding it as a literal in the
    // script text, so no JS-string-escaping of the test's own malicious payload is needed here —
    // sidesteps the exact class of quoting bug this test exists to catch in the code under test.
    private func runHej(_ hejSource: String, on input: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "-e", "\(hejSource)\nprocess.stdout.write(hej(process.env.HEJ_TEST_INPUT));"]
        var env = ProcessInfo.processInfo.environment
        env["HEJ_TEST_INPUT"] = input
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    @Test func escapesDoubleQuotes_preventingAttributeBreakout() throws {
        guard nodeIsAvailable() else { return }
        let hej = try extractHej()
        try #require(!hej.isEmpty)

        // The actual attack shape: an ImageURL crafted to close the src="..." attribute early and
        // inject a new element.
        let output = try runHej(hej, on: #""><script>alert(1)</script>"#)
        #expect(!output.contains("\""),
                "hej() must escape every '\"' — a raw quote in the output lets a crafted ImageURL break out of <img src=\"...\">")
        #expect(output.contains("&quot;"))
    }

    @Test func escapesAngleBracketsAndAmpersand() throws {
        guard nodeIsAvailable() else { return }
        let hej = try extractHej()
        try #require(!hej.isEmpty)

        let output = try runHej(hej, on: "<b>&\"")
        #expect(output == "&lt;b&gt;&amp;&quot;")
    }

    @Test func plainTextIsUnchanged() throws {
        guard nodeIsAvailable() else { return }
        let hej = try extractHej()
        try #require(!hej.isEmpty)

        let output = try runHej(hej, on: "Jeopardy! S42E101")
        #expect(output == "Jeopardy! S42E101")
    }
}
