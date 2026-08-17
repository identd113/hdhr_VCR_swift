import Testing
@testable import hdhr_VCR

// MARK: - Show.seriesTitle(from:) and String.channelSortKey
//
// Both had zero coverage despite sitting under real scheduling behavior:
// seriesTitle is the comparison normalizer for the title-fallback matching tier
// (GuideStore.currentEntryByTitle/nextEntryByTitle) — a regression here silently breaks
// scheduling for exactly the series whose guide entries omit SeriesID. channelSortKey
// orders every channel list in the web guide and menus; a regression reverts to string
// ordering ("10.1" before "5.1").

@Suite("Show.seriesTitle(from:)")
struct SeriesTitleTests {

    // One (input → expected) table, parameterized rather than seven near-identical bodies.
    // Rows annotate the specific contract they pin.
    @Test(arguments: [
        // Strips the trailing episode tag + whatever guest line follows it.
        (raw: "South Park S24E116 Trey Parker; Matt Stone; Alison Brie", expected: "South Park"),
        (raw: "Nova S51E12", expected: "Nova"),
        // Tag match is case-insensitive.
        (raw: "Nova s51e12", expected: "Nova"),
        // No tag — untouched.
        (raw: "Antiques Roadshow", expected: "Antiques Roadshow"),
        // The regex requires whitespace before the tag — a title that IS "S01E01" has nothing
        // preceding it to keep, so it must come back untouched rather than becoming "".
        (raw: "S01E01", expected: "S01E01"),
        // "S10" without an E<n> is a legitimate title word (e.g. "Audi S4"), not an episode tag.
        (raw: "Top Gear S10", expected: "Top Gear S10"),
        (raw: "", expected: ""),
    ])
    func stripsOnlyRealEpisodeSuffixes(_ row: (raw: String, expected: String)) {
        #expect(Show.seriesTitle(from: row.raw) == row.expected)
    }
}

@Suite("Show.genreImpliesBonusTime(_:)")
struct GenreImpliesBonusTimeTests {

    // The sports-genre Bonus Time default had zero coverage (CLAUDE.md/TODO.md, 2026-08-16 audit)
    // despite being duplicated across three call sites (AddShowView's two entry paths + guide.js's
    // own client-side check) before being consolidated into this one shared helper — one of the
    // three (applyWebGuideEntry) had drifted to matching only "sports", silently missing XMLTV's
    // singular "Sport" category tag. This table pins the contract all three now share.
    @Test(arguments: [
        (genre: "Sports",     expected: true),   // guide.php's plural tag
        (genre: "Sport",      expected: true),   // XMLTV's singular tag — the one that had drifted
        (genre: "sports",     expected: true),   // case-insensitive
        (genre: "Sports talk", expected: true),  // substring match
        (genre: "Comedy",     expected: false),
        (genre: "",           expected: false),
        (genre: nil,          expected: false),
    ])
    func matchesSportSubstringCaseInsensitively(_ row: (genre: String?, expected: Bool)) {
        #expect(Show.genreImpliesBonusTime(row.genre) == row.expected)
    }
}

@Suite("String.channelSortKey")
struct ChannelSortKeyTests {

    @Test(arguments: [
        (channel: "5.1",   expected: (5, 1)),
        (channel: "10.2",  expected: (10, 2)),
        // Missing minor defaults to 0 — sorts identically to an explicit ".0".
        (channel: "702",   expected: (702, 0)),
        (channel: "702.0", expected: (702, 0)),
        // compactMap drops unparseable segments — garbage sorts first rather than crashing.
        (channel: "abc",   expected: (0, 0)),
        (channel: "",      expected: (0, 0)),
    ])
    func parsesMajorMinor(_ row: (channel: String, expected: (Int, Int))) {
        #expect(row.channel.channelSortKey == row.expected)
    }

    @Test func numericNotStringOrder() {
        // The whole reason this key exists: string sort puts "10.1" before "5.1".
        #expect("5.1".channelSortKey < "10.1".channelSortKey)
        #expect("2.4".channelSortKey > "2.1".channelSortKey)
    }
}
