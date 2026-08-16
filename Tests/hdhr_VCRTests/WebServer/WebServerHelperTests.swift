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

    @Test func he_escapesAllFourSpecialChars() {
        #expect(he(#"<script>alert("x")&y</script>"#) ==
                #"&lt;script&gt;alert(&quot;x&quot;)&amp;y&lt;/script&gt;"#)
    }

    @Test func he_leavesPlainTextUntouched() {
        #expect(he("Antiques Roadshow S02E04") == "Antiques Roadshow S02E04")
    }

    @Test func he_handlesEmptyString() {
        #expect(he("") == "")
    }

    @Test func he_doesNotDoubleEscape() {
        // Guards against a future accidental double-call — & must become &amp; exactly once.
        #expect(he("&") == "&amp;")
        #expect(he("&amp;") == "&amp;amp;")   // literal input "&amp;" only has its own & escaped
    }

    // MARK: jsEscapeForScript() — <script> breakout guard

    @Test func jsEscape_breaksUpScriptCloseTag() {
        let ws = WebServer()
        #expect(ws.jsEscapeForScript("</script>") == "\\u003c/script\\u003e")
    }

    @Test func jsEscape_allThreeCharsReplaced() {
        let ws = WebServer()
        #expect(ws.jsEscapeForScript("<&>") == "\\u003c\\u0026\\u003e")
    }

    @Test func jsEscape_plainJSONUntouched() {
        let ws = WebServer()
        let json = #"{"title":"Antiques Roadshow","channel":"5.1"}"#
        #expect(ws.jsEscapeForScript(json) == json)
    }

    @Test func jsEscape_emptyString() {
        let ws = WebServer()
        #expect(ws.jsEscapeForScript("") == "")
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

    @Test func fillTemplate_substitutesAllTokens() {
        let ws = WebServer()
        let result = ws.fillTemplate("a={{A}};b={{B}};", [("A", "1"), ("B", "2")])
        #expect(result == "a=1;b=2;")
    }

    @Test func fillTemplate_leavesUnrecognizedTokenLiteral() {
        let ws = WebServer()
        // A typo'd/renamed token should stay visible as "{{...}}" rather than silently vanish.
        let result = ws.fillTemplate("x={{TYPO}};", [("A", "1")])
        #expect(result == "x={{TYPO}};")
    }

    @Test func fillTemplate_substitutedValueContainingTokenSyntaxIsNotRescanned() {
        // Regression: a reduce-over-replacingOccurrences implementation rescans its own output,
        // so a value substituted early (e.g. a user-entered show title landing in recsByDevJS)
        // that happens to contain literal "{{OTHER_TOKEN}}" text would get corrupted when that
        // later token is substituted. fillTemplate must do a single pass over the original
        // template so inserted values are never rescanned.
        let ws = WebServer()
        let result = ws.fillTemplate(
            "first={{FIRST}};second={{SECOND}};",
            [("FIRST", "Meeting {{SECOND}} Notes"), ("SECOND", "42")]
        )
        #expect(result == "first=Meeting {{SECOND}} Notes;second=42;")
    }

    @Test func fillTemplate_unterminatedTokenLeftAsLiteral() {
        let ws = WebServer()
        let result = ws.fillTemplate("x={{A", [("A", "1")])
        #expect(result == "x={{A")
    }
}
