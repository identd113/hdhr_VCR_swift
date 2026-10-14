import Testing
@testable import hdhr_VCR

// T16: organizeSeriesRecordings used a bare hasPrefix("Title "), so "Law & Order" claimed
// "Law & Order SVU_…" and moved another show's recordings into its folder.
@Suite("AppState.recordingFilename(_:belongsToSeries:)")
struct SeriesFilenameMatchTests {
    private func match(_ f: String, _ t: String) -> Bool { AppState.recordingFilename(f, belongsToSeries: t) }

    @Test func newFormat_matches() {
        #expect(match("Law & Order_S01E02_5.1_20261001_2000.ts", "Law & Order"))
        #expect(match("Law & Order_5.1_20261001_2000.ts", "Law & Order"))
    }

    @Test func legacyFormat_withEpisodeTag_matches() {
        #expect(match("Law & Order S22E125 Guest Name_5.1_20261001_2000.ts", "Law & Order"))
        #expect(match("Law & Order S3_5.1_20261001_2000.ts", "Law & Order"))
        #expect(match("Law & Order s22e125 guest_5.1_20261001_2000.ts", "Law & Order"))
    }

    @Test func longerTitleSharingThePrefix_doesNotMatch() {
        #expect(!match("Law & Order SVU_5.1_20261001_2000.ts", "Law & Order"))
        #expect(!match("Law & Order SVU_S01E02_5.1_20261001_2000.ts", "Law & Order"))
        #expect(!match("Star Trek Voyager S01E01 Caretaker_5.1_20261001_2000.ts", "Star Trek"))
        #expect(!match("Law & Order SVU S22E125 x_5.1_20261001_2000.ts", "Law & Order"))
    }

    @Test func otherShows_andEmptyTitle_doNotMatch() {
        #expect(!match("Jeopardy_5.1_20261001_2000.ts", "Law & Order"))
        #expect(!match("Law & Order_5.1_20261001_2000.ts", ""))
    }

    @Test func tagFollowedByLetters_isNotAnEpisodeTag() {
        #expect(!match("Law & Order Special_5.1_20261001_2000.ts", "Law & Order"))
        #expect(!match("Law & Order S01Extra_5.1_20261001_2000.ts", "Law & Order"))
    }
}
