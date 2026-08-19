import Testing
import Foundation
@testable import hdhr_VCR

// MARK: - WebServer pure string helpers
//
// WebServer() with no start() call has no listener, no network — these are plain method calls
// against pure string-in/string-out helpers. Two of the three are security-relevant escaping
// gates (he() prevents HTML/attribute injection, jsEscapeForScript prevents </script> breakout)
// for show titles and other guide-provider-sourced strings embedded into the page — per
// CLAUDE.md, this server has no auth beyond LAN-subnet matching, so these are the actual
// injection boundary, not a defense-in-depth nicety.

@Suite("WebServer string helpers")
struct WebServerHelperTests {

    // MARK: he() — HTML escaping (Views/GuideViewHelpers.swift, used throughout WebServer.swift)

    // One (input → expected) table.
    @Test(arguments: [
        (#"<script>alert("x")&y</script>"#, #"&lt;script&gt;alert(&quot;x&quot;)&amp;y&lt;/script&gt;"#),  // escapesAllFourSpecialChars
        ("Antiques Roadshow S02E04", "Antiques Roadshow S02E04"),  // leavesPlainTextUntouched
        ("", ""),                                                  // handlesEmptyString
        // Guards against a future accidental double-call — & must become &amp; exactly once.
        ("&", "&amp;"),           // doesNotDoubleEscape (1/2)
        ("&amp;", "&amp;amp;"),   // doesNotDoubleEscape (2/2) — literal input "&amp;" only has its own & escaped
    ] as [(input: String, expected: String)])
    func heEscaping(_ row: (input: String, expected: String)) {
        #expect(he(row.input) == row.expected)
    }

    // MARK: jsEscapeForScript() — <script> breakout guard

    // One (input → expected) table.
    @Test(arguments: [
        ("</script>", "\\u003c/script\\u003e"),                                    // breaksUpScriptCloseTag
        ("<&>", "\\u003c\\u0026\\u003e"),                                           // allThreeCharsReplaced
        (#"{"title":"Antiques Roadshow","channel":"5.1"}"#, #"{"title":"Antiques Roadshow","channel":"5.1"}"#),  // plainJSONUntouched
        ("", ""),                                                                   // emptyString
    ] as [(input: String, expected: String)])
    func jsEscape(_ row: (input: String, expected: String)) {
        let ws = WebServer()
        #expect(ws.jsEscapeForScript(row.input) == row.expected)
    }

    // MARK: showTypeStr / showStateFromString — round-trip against ShowState

    // Mirrors Show.state's own derivation exactly (Models.swift): !is_series → single;
    // is_series && use_seriesid_all → seriesAll; is_series && use_seriesid → seriesChannel;
    // is_series alone → dateTime. DateTime is a *recurring, non-SeriesID* case — is_series here
    // means "recurs", not "SeriesID-based" — easy to misread from the flag name alone.
    private func show(for state: ShowState) -> Show {
        var show = Show.blank()
        switch state {
        case .single:
            show.show_is_series = false
        case .dateTime:
            show.show_is_series = true
            show.show_use_seriesid = false
            show.show_use_seriesid_all = false
        case .seriesChannel:
            show.show_is_series = true
            show.show_use_seriesid = true
            show.show_use_seriesid_all = false
        case .seriesAll:
            show.show_is_series = true
            show.show_use_seriesid_all = true
        }
        return show
    }

    @Test func showTypeStr_matchesEveryShowStateCase() {
        let ws = WebServer()
        for state in ShowState.allCases {
            let s = show(for: state)
            #expect(s.state == state, "test fixture didn't reproduce \(state) — check Show.state's derivation logic")
            let str = ws.showTypeStr(s)
            #expect(ws.showStateFromString(str) == state,
                    "round-trip broke for \(state): showTypeStr → '\(str)' → showStateFromString → \(ws.showStateFromString(str))")
        }
    }

    @Test func showStateFromString_unknownString_fallsBackToSingle() {
        let ws = WebServer()
        #expect(ws.showStateFromString("bogus") == .single)
        #expect(ws.showStateFromString("") == .single)
    }

    // MARK: fillTemplate() — {{TOKEN}} substitution for Resources/guide.{css,js,html}

    // One (template, tokens → expected) table.
    @Test(arguments: [
        ("a={{A}};b={{B}};", [("A", "1"), ("B", "2")], "a=1;b=2;"),  // substitutesAllTokens
        // A typo'd/renamed token should stay visible as "{{...}}" rather than silently vanish.
        ("x={{TYPO}};", [("A", "1")], "x={{TYPO}};"),  // leavesUnrecognizedTokenLiteral
        // Regression: a reduce-over-replacingOccurrences implementation rescans its own output, so
        // a value substituted early (e.g. a user-entered show title landing in recsByDevJS) that
        // happens to contain literal "{{OTHER_TOKEN}}" text would get corrupted when that later
        // token is substituted. fillTemplate must do a single pass over the original template so
        // inserted values are never rescanned.
        ("first={{FIRST}};second={{SECOND}};",
         [("FIRST", "Meeting {{SECOND}} Notes"), ("SECOND", "42")],
         "first=Meeting {{SECOND}} Notes;second=42;"),  // substitutedValueContainingTokenSyntaxIsNotRescanned
        ("x={{A", [("A", "1")], "x={{A"),  // unterminatedTokenLeftAsLiteral
    ] as [(template: String, tokens: [(String, String)], expected: String)])
    func fillTemplate(_ row: (template: String, tokens: [(String, String)], expected: String)) {
        let ws = WebServer()
        #expect(ws.fillTemplate(row.template, row.tokens) == row.expected)
    }
}
