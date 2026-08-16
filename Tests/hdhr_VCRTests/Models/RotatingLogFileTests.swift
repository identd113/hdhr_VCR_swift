import Testing
import Foundation
@testable import hdhr_VCR

// MARK: - RotatingLogFile
//
// The self-rotation that keeps a months-long session from growing the three log files
// unbounded (CLAUDE.md "Logs"). Zero prior coverage; the contract tested here is the
// observable file behavior: rotation renames to `<path>.1` (replacing any older backup),
// the next write starts a fresh main file, and the byte counter seeds from the file's real
// on-disk size on open so an app relaunch against an already-large log still rotates.

@Suite("RotatingLogFile rotation")
struct RotatingLogFileTests {

    private func tempLogPath() -> String {
        (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("hdhrRotateTest-\(UUID().uuidString).log")
    }

    private func contents(_ path: String) -> String? {
        FileManager.default.fileExists(atPath: path)
            ? (try? String(contentsOfFile: path, encoding: .utf8)) : nil
    }

    @Test func belowThreshold_noRotation() {
        let path = tempLogPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let log = RotatingLogFile(path: path, rotateThresholdBytes: 1000)
        log.write("one line\n")
        #expect(contents(path) == "one line\n")
        #expect(!FileManager.default.fileExists(atPath: path + ".1"), "no .1 backup before threshold")
    }

    @Test func crossingThreshold_movesFileToDot1_andNextWriteStartsFresh() {
        let path = tempLogPath()
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + ".1")
        }
        // Threshold 100: two 61-byte lines cross it on the second write (write() rotates
        // AFTER appending, so both lines land in the rotated-out generation).
        let line1 = String(repeating: "a", count: 60) + "\n"
        let line2 = String(repeating: "b", count: 60) + "\n"
        let line3 = String(repeating: "c", count: 60) + "\n"
        let log = RotatingLogFile(path: path, rotateThresholdBytes: 100)
        log.write(line1)
        log.write(line2)   // 122 bytes ≥ 100 → rotate
        #expect(contents(path + ".1") == line1 + line2, "rotated generation holds everything written so far")
        log.write(line3)   // reopens → fresh main file
        #expect(contents(path) == line3, "post-rotation main file starts empty, not appended to old content")
    }

    @Test func secondRotation_replacesOlderBackup() {
        let path = tempLogPath()
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + ".1")
        }
        let log = RotatingLogFile(path: path, rotateThresholdBytes: 10)
        log.write("generation-1\n")   // 13 bytes ≥ 10 → rotate
        log.write("generation-2\n")   // fresh file, 13 ≥ 10 → rotate again
        // Only ONE prior generation is kept — the second rotation must replace the first
        // backup, not fail because .1 already exists (rotate() removes it before the move).
        #expect(contents(path + ".1") == "generation-2\n")
    }

    @Test func reopenSeedsCounterFromExistingFileSize() {
        let path = tempLogPath()
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + ".1")
        }
        // Simulate an app relaunch against a log that already sits at 90 bytes: a fresh
        // instance's first 20-byte write must count 90+20 ≥ 100 and rotate — if the counter
        // started at 0, the cap would only be enforced against bytes written since launch
        // and a restart-heavy machine could grow the file far past its documented cap.
        try? Data(repeating: UInt8(ascii: "x"), count: 90).write(to: URL(fileURLWithPath: path))
        let log = RotatingLogFile(path: path, rotateThresholdBytes: 100)
        log.write(String(repeating: "y", count: 20))
        #expect(FileManager.default.fileExists(atPath: path + ".1"),
                "pre-existing on-disk size must count toward the rotation threshold")
    }
}
