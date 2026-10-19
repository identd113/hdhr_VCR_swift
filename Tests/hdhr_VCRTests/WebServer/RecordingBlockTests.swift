import Testing
@testable import hdhr_VCR

// The guide marks the block a recording is capturing, not just whatever covers "now" (Bonus Time runs past the slot).
@Suite("Guide recording block")
struct RecordingBlockTests {
    private let six = 21_600, seven = 25_200, eight = 28_800

    @Test func coversNowWhenNoAnchorIsKnown() {
        #expect(WebServer.isRecordingBlock(onRecordingChannel: true, anchors: [], start: six, end: seven, nowTs: six + 60))
        #expect(!WebServer.isRecordingBlock(onRecordingChannel: true, anchors: [], start: seven, end: eight, nowTs: six + 60))
    }

    @Test func bonusTimeKeepsTheRecordingsOwnBlock() {
        // 7:05 — the 6–7 slot has ended but its recording (anchored at 6:00) continues.
        let now = seven + 300
        #expect(WebServer.isRecordingBlock(onRecordingChannel: true, anchors: [six], start: six, end: seven, nowTs: now))
        #expect(!WebServer.isRecordingBlock(onRecordingChannel: true, anchors: [six], start: seven, end: eight, nowTs: now))
    }

    @Test func otherChannelsAreNeverMarked() {
        #expect(!WebServer.isRecordingBlock(onRecordingChannel: false, anchors: [six], start: six, end: seven, nowTs: six + 60))
    }
}
