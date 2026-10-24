import Foundation
import Testing
@testable import hdhr_VCR

// RELEASES.md -> the About tab's version chips and big-feature card (ReleaseNotes.swift).
struct ReleaseNotesTests {
    private let sample = """
    # Release Notes

    Intro text.

    ---

    ## Unreleased

    ### The headline: Your antenna, now in the guide

    Every morning the app listens to the air
    and finds missing stations.

    **Coming soon, in testing:** live TV in a browser (beta).

    **What else is new.**
    - One thing.

    ---

    ## v2.6.5 (2026-10-15)

    ### The headline: fixes and polish

    Steadier.

    ---

    ## v2.0.0 — First Notarized Release (2026-08-08)

    Notarized.
    """

    @Test func splitsOneNotePerVersionNewestFirst() {
        let notes = ReleaseNotes.parse(sample)
        #expect(notes.map(\.id) == ["Unreleased", "v2.6.5", "v2.0.0"])
        #expect(notes[0].subtitle == "")
        #expect(notes[1].subtitle == "2026-10-15")
        #expect(notes[2].subtitle == "First Notarized Release · 2026-08-08")
    }

    @Test func aNoteHasNoHeadingAndNoTrailingRule() {
        let notes = ReleaseNotes.parse(sample)
        #expect(!notes[1].body.hasPrefix("## "))
        #expect(!notes[1].body.hasSuffix("---"))
        #expect(notes[1].body.contains("Steadier."))
        #expect(!notes[1].body.contains("Unreleased"))
    }

    @Test func textBeforeTheFirstVersionIsIgnored() {
        #expect(ReleaseNotes.parse(sample).allSatisfy { !$0.body.contains("Intro text.") })
        #expect(ReleaseNotes.parse("").isEmpty)
        #expect(ReleaseNotes.parse("no headings at all").isEmpty)
    }

    @Test func theHeadlineIsTitleBlurbAndComingSoon() throws {
        let note = try #require(ReleaseNotes.parse(sample).first)
        let headline = try #require(ReleaseNotes.headline(in: note.body))
        #expect(headline.title == "Your antenna, now in the guide")
        #expect(headline.blurb == "Every morning the app listens to the air and finds missing stations.")
        #expect(headline.comingSoon?.hasPrefix("**Coming soon, in testing:**") == true)
    }

    @Test func aReleaseWithoutAComingSoonNoteStillHasAHeadline() throws {
        let note = ReleaseNotes.parse(sample)[1]
        let headline = try #require(ReleaseNotes.headline(in: note.body))
        #expect(headline.title == "fixes and polish")
        #expect(headline.comingSoon == nil)
    }

    @Test func aReleaseWithNoHeadlineSectionHasNone() {
        #expect(ReleaseNotes.headline(in: ReleaseNotes.parse(sample)[2].body) == nil)
    }

    @Test func theRealReleaseNotesFileParses() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: repo.appendingPathComponent("RELEASES.md"), encoding: .utf8)
        let notes = ReleaseNotes.parse(text)
        #expect(notes.count >= 5)
        #expect(notes.first?.id == "Unreleased" || notes.first?.id.hasPrefix("v") == true)
        #expect(notes.allSatisfy { !$0.body.isEmpty })
    }
}
