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

    @Test func nilWhenSkipRecordedEpisodesDisabled() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(atPath: base) }
        try writeFile("\(base)/Show/Season 01", "Show_S01E01_5.1_20260101_2000.ts")

        let state = makeTestAppState()
        state.config.Skip_recorded_episodes = false
        #expect(state.duplicateEpisodeTag(title: "Show", episodeTag: "S01E01", baseDir: base) == nil)
    }

    @Test func nilForSeasonOnlyTag() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(atPath: base) }
        // Even a season-only on-disk file wouldn't help — the regex below requires E<n> too.
        try writeFile("\(base)/Show/Season 01", "Show_S01_5.1_20260101_2000.ts")

        let state = makeTestAppState()
        state.config.Skip_recorded_episodes = true
        #expect(state.duplicateEpisodeTag(title: "Show", episodeTag: "S01", baseDir: base) == nil)
    }

    @Test func returnsUppercasedTagWhenMatchOnDisk() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(atPath: base) }
        try writeFile("\(base)/Show/Season 01", "Show_S01E01_5.1_20260101_2000.ts")

        let state = makeTestAppState()
        state.config.Skip_recorded_episodes = true
        #expect(state.duplicateEpisodeTag(title: "Show", episodeTag: "S01E01", baseDir: base) == "S01E01")
    }

    @Test func lowercaseInputTagMatchesUppercaseOnDiskTag() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(atPath: base) }
        try writeFile("\(base)/Show/Season 01", "Show_S01E01_5.1_20260101_2000.ts")

        let state = makeTestAppState()
        state.config.Skip_recorded_episodes = true
        #expect(state.duplicateEpisodeTag(title: "Show", episodeTag: "s01e01", baseDir: base) == "S01E01")
    }

    @Test func nilWhenNoMatchingFileOnDisk() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(atPath: base) }
        try writeFile("\(base)/Show/Season 01", "Show_S01E01_5.1_20260101_2000.ts")

        let state = makeTestAppState()
        state.config.Skip_recorded_episodes = true
        #expect(state.duplicateEpisodeTag(title: "Show", episodeTag: "S01E02", baseDir: base) == nil)
    }
}
