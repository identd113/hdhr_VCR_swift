import Testing
import Foundation
@testable import hdhr_VCR

// Covers AppState.duplicateEpisodeTag(title:episodeTag:baseDir:) — the on-disk duplicate
// check shared by startRecording's skip logic and the Add/Edit dialog's "already on disk"
// warning. Builds on the same on-disk scan RecordedEpisodeTagsTests.swift covers; this file
// exercises the extra gating this function adds on top (Skip_recorded_episodes, the
// season+episode-only `^S\d+E\d+$` tag shape).
@MainActor
struct DuplicateEpisodeTagTests {

    private func writeFile(_ dir: String, _ name: String, bytes: Int = 2_000_000) throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent(name)
        try Data(count: bytes).write(to: URL(fileURLWithPath: path))
    }

    private func tempBase() -> String {
        (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("hdhrDupTest-\(UUID().uuidString)")
    }

    // One (on-disk file, Skip_recorded_episodes, queried tag → expected) table — every row writes
    // one file, sets the config flag, queries one tag, and checks the result.
    @Test(arguments: [
        (diskFile: "Show_S01E01_5.1_20260101_2000.ts", skipEnabled: false, episodeTag: "S01E01", expected: nil as String?),  // nilWhenSkipRecordedEpisodesDisabled
        // Even a season-only on-disk file wouldn't help — the regex requires E<n> too.
        (diskFile: "Show_S01_5.1_20260101_2000.ts",     skipEnabled: true,  episodeTag: "S01",    expected: nil),            // nilForSeasonOnlyTag
        (diskFile: "Show_S01E01_5.1_20260101_2000.ts",  skipEnabled: true,  episodeTag: "S01E01", expected: "S01E01"),       // returnsUppercasedTagWhenMatchOnDisk
        (diskFile: "Show_S01E01_5.1_20260101_2000.ts",  skipEnabled: true,  episodeTag: "s01e01", expected: "S01E01"),       // lowercaseInputTagMatchesUppercaseOnDiskTag
        (diskFile: "Show_S01E01_5.1_20260101_2000.ts",  skipEnabled: true,  episodeTag: "S01E02", expected: nil),            // nilWhenNoMatchingFileOnDisk
    ])
    func duplicateCheck(_ row: (diskFile: String, skipEnabled: Bool, episodeTag: String, expected: String?)) throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(atPath: base) }
        try writeFile("\(base)/Show/Season 01", row.diskFile)

        let state = makeTestAppState()
        state.config.Skip_recorded_episodes = row.skipEnabled
        #expect(state.duplicateEpisodeTag(title: "Show", episodeTag: row.episodeTag, baseDir: base) == row.expected)
    }
}
