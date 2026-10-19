import Testing
@testable import hdhr_VCR

// The guide marks the block a recording is capturing, not just whatever covers "now" (Bonus Time runs past the slot).
@Suite("Guide recording block")
struct RecordingBlockTests {
    private let six = 21_600, seven = 25_200, eight = 28_800

    @Test func coversNowWhenNoAnchorIsKnown() {
        #expect(WebServer.isRecordingBlock(onRecordingChannel: true, anchors: [], coversNowToo: true, start: six, end: seven, nowTs: six + 60))
        #expect(!WebServer.isRecordingBlock(onRecordingChannel: true, anchors: [], coversNowToo: true, start: seven, end: eight, nowTs: six + 60))
    }

    @Test func bonusTimeKeepsTheRecordingsOwnBlock() {
        // 7:05 — the 6–7 slot has ended but its recording (anchored at 6:00) continues.
        let now = seven + 300
        #expect(WebServer.isRecordingBlock(onRecordingChannel: true, anchors: [six], coversNowToo: false, start: six, end: seven, nowTs: now))
        #expect(!WebServer.isRecordingBlock(onRecordingChannel: true, anchors: [six], coversNowToo: false, start: seven, end: eight, nowTs: now))
    }

    @Test func otherChannelsAreNeverMarked() {
        #expect(!WebServer.isRecordingBlock(onRecordingChannel: false, anchors: [six], coversNowToo: false, start: six, end: seven, nowTs: six + 60))
    }

    @Test func aRecordingWithNoAnchorAlsoMarksTheBlockCoveringNow() {
        // One recording anchored at 6:00, another started by hand: both the 6–7 block and the one covering now are marked.
        let now = seven + 300
        #expect(WebServer.coversNowToo(anchors: [six], hasUnanchored: true, blocks: [(six, seven), (seven, eight)]))
        #expect(WebServer.isRecordingBlock(onRecordingChannel: true, anchors: [six], coversNowToo: true, start: six, end: seven, nowTs: now))
        #expect(WebServer.isRecordingBlock(onRecordingChannel: true, anchors: [six], coversNowToo: true, start: seven, end: eight, nowTs: now))
    }

    @Test func anAnchorOutsideTheWindowFallsBackToNow() {
        // The recording's own block has scrolled out of the window: nothing contains the anchor, so mark what covers now.
        #expect(WebServer.coversNowToo(anchors: [six], hasUnanchored: false, blocks: [(seven, eight)]))
        #expect(!WebServer.coversNowToo(anchors: [six], hasUnanchored: false, blocks: [(six, seven), (seven, eight)]))
    }
}
