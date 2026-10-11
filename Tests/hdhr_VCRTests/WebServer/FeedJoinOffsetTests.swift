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

// An explicit `back=<seconds>` (Watch from Beginning on another Mac) joins that far behind, or at byte 0 when it reaches
// past the start of the file.
@Suite("WebServer.feedBackOffset")
struct FeedBackOffsetTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func backPastTheStart_isByteZero() {
        #expect(WebServer.feedBackOffset(currentSize: 600_000_000, recordingStart: now.addingTimeInterval(-600), backSeconds: 600, now: now) == 0)
        #expect(WebServer.feedBackOffset(currentSize: 600_000_000, recordingStart: now.addingTimeInterval(-600), backSeconds: 999_999, now: now) == 0)
    }

    @Test func backWithinTheFile_joinsThatFarBehind() {
        let size = 600_000_000   // 1 MB/s over 600 s
        let off = WebServer.feedBackOffset(currentSize: size, recordingStart: now.addingTimeInterval(-600), backSeconds: 120, now: now)
        #expect(off % 188 == 0)
        #expect(abs(Double(size - off) - 120_000_000) < 400_000, "joined \(size - off) bytes behind, expected ~120 MB")
    }

    @Test func unknownStartOrEmptyFile_joinsAtTheLiveEdge() {
        #expect(WebServer.feedBackOffset(currentSize: 1_000_000, recordingStart: nil, backSeconds: 60, now: now) == 1_000_000)
        #expect(WebServer.feedBackOffset(currentSize: 0, recordingStart: now.addingTimeInterval(-600), backSeconds: 60, now: now) == 0)
    }

    @Test func backZero_isTheLiveEdgeNotTheDefaultCushion() {
        let size = 600_000_000
        let off = WebServer.feedBackOffset(currentSize: size, recordingStart: now.addingTimeInterval(-600), backSeconds: 0, now: now)
        #expect(size - off < 1_000, "back=0 should join at the write position, got \(size - off) bytes behind")
    }
}
