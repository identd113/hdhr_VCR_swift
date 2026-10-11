import Testing
import Foundation
@testable import hdhr_VCR

// A raw FEED viewer joins `feedJoinBackoffSeconds` behind the write position (a cushion against delivery jitter) once
// the recording has more than that on disk; a younger recording, or one with an unknown start, joins at the live edge.

@Suite("WebServer.feedJoinOffset")
struct FeedJoinOffsetTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func longRecording_joinsBackoffSecondsBehind() {
        // 600 s elapsed, 600 MB written (1 MB/s) → join 8 s behind = 592 MB, TS-aligned.
        let size = 600_000_000
        let off = WebServer.feedJoinOffset(currentSize: size, recordingStart: now.addingTimeInterval(-600), now: now)
        let behind = size - off
        #expect(off % 188 == 0)
        #expect(abs(Double(behind) - 8_000_000) < 200_000, "joined \(behind) bytes behind, expected ~8 MB")
    }

    @Test func recordingYoungerThanBackoff_joinsAtLiveEdge() {
        let size = 5_000_000
        #expect(WebServer.feedJoinOffset(currentSize: size, recordingStart: now.addingTimeInterval(-5), now: now) == size)
        #expect(WebServer.feedJoinOffset(currentSize: size, recordingStart: now.addingTimeInterval(-8), now: now) == size)
    }

    @Test func justOverBackoff_joinsNearTheStart() {
        let size = 9_000_000
        let off = WebServer.feedJoinOffset(currentSize: size, recordingStart: now.addingTimeInterval(-9), now: now)
        #expect(off < size)
        #expect(off <= 1_100_000, "9 s elapsed, 8 s behind → ~1 s from the start; got \(off)")
    }

    @Test func unknownStartOrEmptyFile_joinsAtLiveEdge() {
        #expect(WebServer.feedJoinOffset(currentSize: 1_000_000, recordingStart: nil, now: now) == 1_000_000)
        #expect(WebServer.feedJoinOffset(currentSize: 0, recordingStart: now.addingTimeInterval(-600), now: now) == 0)
    }

    @Test func neverBeyondTheFile() {
        let size = 123_456_789
        let off = WebServer.feedJoinOffset(currentSize: size, recordingStart: now.addingTimeInterval(-30), now: now)
        #expect(off >= 0 && off <= size)
    }
}
