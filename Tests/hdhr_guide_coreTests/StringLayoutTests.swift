import Testing
@testable import hdhr_guide_core

@Suite("pad/truncate/wordWrap")
struct StringLayoutTests {

    @Test func padShorterStringAddsTrailingSpaces() {
        #expect(pad("hi", 5) == "hi   ")
    }

    @Test func padExactWidthStringUnchanged() {
        #expect(pad("hello", 5) == "hello")
    }

    @Test func padLongerStringTruncates() {
        #expect(pad("hello world", 5) == "hello")
    }

    @Test func padZeroWidthReturnsEmpty() {
        #expect(pad("hello", 0) == "")
    }

    @Test func truncateShorterStringUnchanged() {
        #expect(truncate("hi", 5) == "hi")
    }

    @Test func truncateLongerStringEndsInASCIIDot() {
        // "." not "…" — the ellipsis glyph is Unicode Ambiguous-width, which is exactly the class
        // of bug this whole library split exists to keep regression-tested (see StringLayout.swift).
        let result = truncate("Sesame Street", 8)
        #expect(result == "Sesame .")
        #expect(result.count == 8)
    }

    @Test func truncateWidthOneReturnsOneCharNoDot() {
        // width - 1 == 0 has no room for both content and the dot — the width>1 guard falls back
        // to a bare prefix instead.
        #expect(truncate("hello", 1) == "h")
    }

    @Test func truncateZeroWidthReturnsEmpty() {
        #expect(truncate("hello", 0) == "")
    }

    @Test func wordWrapShortTextFitsOneLine() {
        #expect(wordWrap("hello world", width: 20) == ["hello world"])
    }

    @Test func wordWrapBreaksAtWordBoundaries() {
        let lines = wordWrap("the quick brown fox jumps", width: 10)
        #expect(lines.allSatisfy { $0.count <= 10 })
        #expect(lines.joined(separator: " ") == "the quick brown fox jumps")
    }

    // Regression test for a real bug found in a full code review: a single word longer than the
    // wrap width (a long URL, a hyphen-less compound token in real synopsis data) used to be
    // emitted as one line wider than `width` regardless — the same overflow-then-terminal-wraps
    // bug class as everything else this app's width handling guards against. Fixed by hard-breaking
    // any such word into width-sized chunks before falling back to normal word-boundary wrapping.
    @Test func wordWrapHardBreaksAWordLongerThanWidth() {
        let longWord = "https://example.com/" + String(repeating: "a", count: 60)
        let text = "See this link \(longWord) for more info."
        let lines = wordWrap(text, width: 20)
        #expect(lines.allSatisfy { $0.count <= 20 }, "every line must fit within width, got \(lines.map(\.count))")
        // Reassembling (undoing the hard-break points, which have no space to rejoin on) should
        // still contain the original long word intact, just split across several lines.
        #expect(lines.joined().contains("https://example.com/"))
    }

    @Test func wordWrapHardBreaksAWordExactlyAtWidth() {
        let text = String(repeating: "x", count: 20)
        let lines = wordWrap(text, width: 20)
        #expect(lines == [text])   // exactly width, no break needed
    }

    @Test func wordWrapEmptyTextReturnsEmptyArray() {
        #expect(wordWrap("", width: 10) == [])
    }

    @Test func wordWrapZeroWidthReturnsWholeTextAsOneLine() {
        #expect(wordWrap("hello world", width: 0) == ["hello world"])
    }
}
