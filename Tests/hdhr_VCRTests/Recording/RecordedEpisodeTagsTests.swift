import Testing
import Foundation
@testable import hdhr_VCR

// Covers AppState.recordedEpisodeTags — the on-disk scan behind the
// "skip already-recorded episodes" feature. Exercises the two-level walk
// (Title/ + Title/Season NN/), the tag regex, case-normalization, and the
// failed-stub size floor.
@MainActor
struct RecordedEpisodeTagsTests {

    /// Writes a file of `bytes` size at `dir/name`, creating intermediate dirs.
    private func writeFile(_ dir: String, _ name: String, bytes: Int) throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent(name)
        try Data(count: bytes).write(to: URL(fileURLWithPath: path))
    }

    private func tempBase() -> String {
        (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("hdhrTagTest-\(UUID().uuidString)")
    }

    @Test func scansSeasonSubfoldersAndFlatFiles() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let title = "The Office"
        let big = 2_000_000
        // Season subfolder file, and a flat file directly under the title dir.
        try writeFile("\(base)/\(title)/Season 01", "The Office_S01E01_5.1_20260101_2000.m2ts", bytes: big)
        try writeFile("\(base)/\(title)", "The Office_S02E05_5.1_20260201_2000.mkv", bytes: big)

        let state = makeTestAppState()
        let tags = state.recordedEpisodeTags(forTitle: title, baseDir: base)
        #expect(tags.contains("S01E01"))
        #expect(tags.contains("S02E05"))
    }

    @Test func ignoresStubFilesBelowSizeFloor() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let title = "The Office"
        // A crashed/zero-length attempt must NOT count as recorded.
        try writeFile("\(base)/\(title)/Season 01", "The Office_S01E02_5.1_20260108_2000.m2ts", bytes: 1024)

        let state = makeTestAppState()
        let tags = state.recordedEpisodeTags(forTitle: title, baseDir: base)
        #expect(!tags.contains("S01E02"))
    }

    @Test func normalizesTagCaseAndTypeMatchesUppercase() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let title = "Show"
        try writeFile("\(base)/\(title)/Season 03", "Show_s03e18_7.1_20260301_2000.m2ts", bytes: 2_000_000)

        let state = makeTestAppState()
        let tags = state.recordedEpisodeTags(forTitle: title, baseDir: base)
        // Tags are upper-cased so callers can compare against an upper-cased guide tag.
        #expect(tags.contains("S03E18"))
    }

    @Test func missingFolderReturnsEmpty() throws {
        let state = makeTestAppState()
        let tags = state.recordedEpisodeTags(forTitle: "Nope", baseDir: tempBase())
        #expect(tags.isEmpty)
    }

    @Test func renameTruncatedTagRenamesOnlyTheMatchingBelowFloorFile() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let title = "The Office"
        let seasonDir = "\(base)/\(title)/Season 01"
        // Truncated attempt at the tag we're about to re-record — should get renamed.
        try writeFile(seasonDir, "The Office_S01E02_5.1_20260108_2000.ts", bytes: 1024)
        // A genuinely complete file for a different episode — must be left alone even though
        // renameTruncatedTag is set, since its own tag doesn't match.
        try writeFile(seasonDir, "The Office_S01E01_5.1_20260101_2000.ts", bytes: 2_000_000)

        let state = makeTestAppState()
        _ = state.recordedEpisodeTags(forTitle: title, baseDir: base, renameTruncatedTag: "S01E02")

        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: "\(seasonDir)/The Office_S01E02_5.1_20260108_2000.ts"))
        #expect(fm.fileExists(atPath: "\(seasonDir)/The Office_S01E02_5.1_20260108_2000.partial"))
        #expect(fm.fileExists(atPath: "\(seasonDir)/The Office_S01E01_5.1_20260101_2000.ts"))
    }

    @Test func renameTruncatedTagLeavesAboveFloorFilesAlone() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let title = "The Office"
        let seasonDir = "\(base)/\(title)/Season 01"
        try writeFile(seasonDir, "The Office_S01E03_5.1_20260115_2000.ts", bytes: 2_000_000)

        let state = makeTestAppState()
        let tags = state.recordedEpisodeTags(forTitle: title, baseDir: base, renameTruncatedTag: "S01E03")

        #expect(tags.contains("S01E03"))
        #expect(FileManager.default.fileExists(atPath: "\(seasonDir)/The Office_S01E03_5.1_20260115_2000.ts"))
    }

    /// Real-world case (2026-08-22): a HDHomeRun reboot cut a 60-minute recording off after
    /// ~25 minutes — 1.37 GB against a normal ~3.4 GB episode for that series. That cleared the
    /// flat duration floor alone (well past a stub) but was nowhere close to a real episode.
    /// expectedMinutes: 1 here (not 60) purely to keep the fake files small/fast — the ratios are
    /// what matter, not the absolute scale.
    @Test func siblingSizeFloorCatchesSubstantiallyIncompleteFile() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let title = "Late Night"
        let seasonDir = "\(base)/\(title)/Season 13"
        // Real complete siblings establish what a genuine episode actually looks like for this
        // series/channel — the flat duration floor alone has no way to know this.
        try writeFile(seasonDir, "Late Night_S13E98_11.1_20260819_2337.ts", bytes: 20_000_000)
        try writeFile(seasonDir, "Late Night_S13E99_11.1_20260820_2337.ts", bytes: 20_000_000)
        // Well past the flat duration floor (9 MB for expectedMinutes=1) but well under 80% of
        // the real siblings (16 MB) — exactly the truncated-but-substantial shape from the field.
        try writeFile(seasonDir, "Late Night_S13E100_11.1_20260821_2337.ts", bytes: 9_500_000)

        let state = makeTestAppState()
        let tags = state.recordedEpisodeTags(forTitle: title, baseDir: base, expectedMinutes: 1)

        #expect(tags.contains("S13E98"))
        #expect(tags.contains("S13E99"))
        #expect(!tags.contains("S13E100"),
            "well below this series' own real sibling sizes should not count as complete, even though it clears the flat duration floor alone")
    }

    /// A series whose only file is itself small/truncated must not turn the sibling-size floor
    /// into something laxer than the flat duration floor — max(durationFloor, siblingFloor), never
    /// just siblingFloor alone.
    @Test func siblingSizeFloorNeverLowersBelowDurationFloor() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let title = "New Show"
        let seasonDir = "\(base)/\(title)/Season 01"
        try writeFile(seasonDir, "New Show_S01E01_5.1_20260101_2000.ts", bytes: 500_000)

        let state = makeTestAppState()
        let tags = state.recordedEpisodeTags(forTitle: title, baseDir: base, expectedMinutes: 1)
        #expect(!tags.contains("S01E01"))
    }
}
