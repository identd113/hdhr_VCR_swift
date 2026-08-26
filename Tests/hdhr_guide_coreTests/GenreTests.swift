import Testing
@testable import hdhr_guide_core

@Suite("genreBackground")
struct GenreTests {

    @Test func knownGenreReturnsA24BitBackgroundEscape() {
        let esc = genreBackground("Drama")
        #expect(esc.hasPrefix("\u{1B}[48;2;"))
        #expect(esc.hasSuffix("m"))
    }

    @Test func matchIsCaseInsensitive() {
        #expect(genreBackground("SPORTS") == genreBackground("sports"))
    }

    // Mirrors guide.js's own genre alias table (_ggAlias) — a mismatch here means a channel tile
    // colored differently in the TUI than the exact same show colors in the web guide.
    @Test(arguments: [
        ("sitcom", "comedy"), ("movies", "movie"), ("kids", "children"), ("sport", "sports"),
        ("documentary", "doc"), ("game show", "gameshow"), ("animation", "children"), ("animated", "children")
    ])
    func aliasResolvesToTheSameColorAsItsCanonicalGenre(alias: String, canonical: String) {
        #expect(genreBackground(alias) == genreBackground(canonical))
    }

    @Test func unrecognizedGenreReturnsEmptyString() {
        #expect(genreBackground("NotARealGenre") == "")
    }

    @Test func nilGenreReturnsEmptyString() {
        #expect(genreBackground(nil) == "")
    }

    @Test func emptyStringGenreReturnsEmptyString() {
        #expect(genreBackground("") == "")
    }

    // Every genreHSL entry converted to RGB should exactly match Resources/guide.js's _gcDk table —
    // manually cross-checked once this session via Python's colorsys against every one of guide.js's
    // 24 hsl() values (found zero drift); this test only re-verifies the ones the TUI actually
    // exercises (all 24 known genre keys resolve to *some* real color, not silently falling through
    // to the empty/unrecognized case), not the literal RGB values against guide.js — that
    // cross-file drift check has no automated home yet (guide.js isn't something a Swift test can
    // import), so it's still a manual check if that palette ever changes on either side.
    @Test(arguments: [
        "drama", "comedy", "news", "sports", "reality", "movie", "talk", "children", "crime",
        "romance", "thriller", "action", "mystery", "doc", "science", "nature", "history", "music",
        "food", "travel", "gameshow", "home", "health", "faith"
    ])
    func everyKnownGenreKeyResolves(genre: String) {
        #expect(genreBackground(genre) != "")
    }
}
