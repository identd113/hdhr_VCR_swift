import Testing
import SwiftUI
@testable import hdhr_VCR

// MARK: - guideEntryColor(for:onAir:)
//
// Zero prior coverage despite three independent copies of the same alias map existing
// (this one, WebServer.swift's ggAlias, guide.js's _ggAlias) — a real regression shipped
// here once already: this file's _genreAlias was missing "kids": "children" (present in
// both siblings), so a "Kids"-tagged entry silently fell through to the default gray
// instead of the "children" hue. Pins every alias entry against its target's real color
// so the three copies can't diverge again without a test failing.

private func entry(genre: String?) -> GuideEntry {
    GuideEntry(StartTime: 0, EndTime: 1800, Title: "Show", Filter: genre.map { [$0] })
}

@Suite("guideEntryColor genre aliasing")
struct GuideEntryColorTests {

    // One (alias genre → target genre) table — every row checks that the alias's color equals
    // its target's color. Row order/names match the original standalone tests.
    @Test(arguments: [
        (alias: "Kids",      target: "Children"),  // kidsAliasesToChildren
        (alias: "Sport",     target: "Sports"),     // sportAliasesToSports
        (alias: "Movies",    target: "Movie"),      // moviesAliasesToMovie
        (alias: "Sitcom",    target: "Comedy"),     // sitcomAliasesToComedy
        (alias: "Documentary", target: "Doc"),      // documentaryAliasesToDoc
        (alias: "Game show", target: "Gameshow"),   // gameShowAliasesToGameshow
        (alias: "Animation", target: "Children"),   // animationAndAnimatedBothAliasToChildren (1/2)
        (alias: "Animated",  target: "Children"),   // animationAndAnimatedBothAliasToChildren (2/2)
        (alias: "KIDS",      target: "Children"),   // aliasLookupIsCaseInsensitive
    ])
    func aliasMatchesTarget(_ row: (alias: String, target: String)) {
        #expect(guideEntryColor(for: entry(genre: row.alias), onAir: true)
             == guideEntryColor(for: entry(genre: row.target), onAir: true))
    }

    // One (genre → falls back to default gray) table — distinct assertion shape from the alias
    // table above (compares against a fixed color, not another genre's color).
    @Test(arguments: [
        "Nonexistent Genre" as String?,  // unknownGenre_fallsBackToDefaultGray
        nil,                             // noGenre_fallsBackToDefaultGray
    ])
    func unrecognizedGenre_fallsBackToDefaultGray(_ genre: String?) {
        #expect(guideEntryColor(for: entry(genre: genre), onAir: true) == Color(white: 0.22))
    }

    @Test func offAir_isDimmedVersionOfOnAirColor() {
        let onAir  = guideEntryColor(for: entry(genre: "Drama"), onAir: true)
        let offAir = guideEntryColor(for: entry(genre: "Drama"), onAir: false)
        #expect(onAir != offAir)
        #expect(offAir == onAir.opacity(0.75))
    }
}
