import Testing
import Foundation
@testable import hdhr_VCR

// A stream scrubbed back to some point keeps playing from there while it sits in the PiP corner;
// tabbing to the PiP and back must give it back that position, not the live edge.
@Suite("SeekAnchorSwapper — scrub position survives a PiP swap")
struct SeekAnchorSwapperTests {
    private func anchor(_ id: String, base: Double) -> SeekAnchor {
        SeekAnchor(showId: id, start: Date(timeIntervalSince1970: 1_000), baseSeconds: base,
                   reopenedAt: Date(timeIntervalSince1970: 2_000))
    }

    @Test func scrubbedPrimary_comesBackUnchangedAfterTabAndTabBack() {
        var s = SeekAnchorSwapper()
        let scrubbed = anchor("FEED-1", base: 120)        // scrubbed back to 2:00
        // Tab to the PiP (a live channel, no anchor, is promoted): the FEED is demoted and saved.
        #expect(s.swap(demoting: scrubbed) == nil)
        #expect(s.secondary == scrubbed)
        // Tab back: the live stream (no anchor) is demoted; the FEED gets its own position back.
        #expect(s.swap(demoting: nil) == scrubbed)
        #expect(s.secondary == nil)
    }

    @Test func twoRecordingStreams_eachKeepsItsOwnPosition() {
        var s = SeekAnchorSwapper()
        let a = anchor("A", base: 30), b = anchor("B", base: 600)
        #expect(s.swap(demoting: a) == nil)        // A primary → corner; B (never primary) promoted
        #expect(s.swap(demoting: b) == a)          // B → corner; A promoted with its own base
        #expect(s.swap(demoting: a) == b)          // and back again
    }

    @Test func aStreamNeverPrimary_hasNothingToRestore() {
        var s = SeekAnchorSwapper()
        #expect(s.swap(demoting: anchor("A", base: 5)) == nil)   // falls back to the near-live approximation
    }

    @Test func replacingOrClosingTheCornerStream_dropsItsSavedPosition() {
        var s = SeekAnchorSwapper()
        _ = s.swap(demoting: anchor("A", base: 90))
        s.clearSecondary()
        #expect(s.secondary == nil)
        #expect(s.swap(demoting: nil) == nil)      // a later promotion must not get A's stale position
    }
}
