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
}
