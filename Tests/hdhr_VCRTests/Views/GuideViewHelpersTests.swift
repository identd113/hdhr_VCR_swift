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

    @Test func kidsAliasesToChildren() {
        #expect(guideEntryColor(for: entry(genre: "Kids"), onAir: true)
             == guideEntryColor(for: entry(genre: "Children"), onAir: true))
    }

    @Test func sportAliasesToSports() {
        #expect(guideEntryColor(for: entry(genre: "Sport"), onAir: true)
             == guideEntryColor(for: entry(genre: "Sports"), onAir: true))
    }

    @Test func moviesAliasesToMovie() {
        #expect(guideEntryColor(for: entry(genre: "Movies"), onAir: true)
             == guideEntryColor(for: entry(genre: "Movie"), onAir: true))
    }

    @Test func sitcomAliasesToComedy() {
        #expect(guideEntryColor(for: entry(genre: "Sitcom"), onAir: true)
             == guideEntryColor(for: entry(genre: "Comedy"), onAir: true))
    }

    @Test func documentaryAliasesToDoc() {
        #expect(guideEntryColor(for: entry(genre: "Documentary"), onAir: true)
             == guideEntryColor(for: entry(genre: "Doc"), onAir: true))
    }

    @Test func gameShowAliasesToGameshow() {
        #expect(guideEntryColor(for: entry(genre: "Game show"), onAir: true)
             == guideEntryColor(for: entry(genre: "Gameshow"), onAir: true))
    }

    @Test func animationAndAnimatedBothAliasToChildren() {
        let animation = guideEntryColor(for: entry(genre: "Animation"), onAir: true)
        let animated  = guideEntryColor(for: entry(genre: "Animated"), onAir: true)
        let children  = guideEntryColor(for: entry(genre: "Children"), onAir: true)
        #expect(animation == children)
        #expect(animated == children)
    }

    @Test func aliasLookupIsCaseInsensitive() {
        #expect(guideEntryColor(for: entry(genre: "KIDS"), onAir: true)
             == guideEntryColor(for: entry(genre: "Children"), onAir: true))
    }

    @Test func unknownGenre_fallsBackToDefaultGray() {
        #expect(guideEntryColor(for: entry(genre: "Nonexistent Genre"), onAir: true)
             == Color(white: 0.22))
    }

    @Test func noGenre_fallsBackToDefaultGray() {
        #expect(guideEntryColor(for: entry(genre: nil), onAir: true) == Color(white: 0.22))
    }

    @Test func offAir_isDimmedVersionOfOnAirColor() {
        let onAir  = guideEntryColor(for: entry(genre: "Drama"), onAir: true)
        let offAir = guideEntryColor(for: entry(genre: "Drama"), onAir: false)
        #expect(onAir != offAir)
        #expect(offAir == onAir.opacity(0.75))
    }
}
