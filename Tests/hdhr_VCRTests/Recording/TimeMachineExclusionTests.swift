import Testing
import Foundation
import CoreServices
@testable import hdhr_VCR

// MARK: - Time Machine exclusion (Settings → Recording → "Exclude from Time Machine")
//
// Three modes in `AppConfig.TimeMachine_exclude_mode`: "off" (default), "perFile" (RecordingManager.start
// tags each recording's own file) and "perFolder" (AppState tags the show's folder once). These tests
// exercise the real `CSBackupSetItemExcluded` xattr write on temp files/folders — the same call the app
// makes — and RecordingManager's per-file switch through the mock-curl seam. The "perFolder" branch lives
// inside AppState.startRecording (not separately callable), so it's covered here at the unit it delegates
// to (`excludeFromTimeMachine` on a folder) plus the config decoding that selects it.

@Suite("Time Machine exclusion")
struct TimeMachineExclusionTests {

    private func isExcluded(_ path: String) -> Bool {
        var byPath = DarwinBoolean(false)
        let status = CSBackupIsItemExcluded(URL(fileURLWithPath: path) as CFURL, &byPath)
        // `status` is the API's own "is this item excluded" Boolean, not an OSStatus.
        return status
    }

    private func tempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "hdhrVCRplus-tm-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func excludeFromTimeMachine_tagsAnExistingFile() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/rec.ts"
        FileManager.default.createFile(atPath: file, contents: Data([0]))
        #expect(isExcluded(file) == false)
        excludeFromTimeMachine(file)
        #expect(isExcluded(file) == true)
    }

    @Test func excludeFromTimeMachine_tagsAFolder_andFilesCreatedLaterAreCovered() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        excludeFromTimeMachine(dir)
        #expect(isExcluded(dir) == true)
        // "perFolder" mode tags the containing directory once and relies on it covering every future
        // episode (a new season subfolder included) — CSBackupIsItemExcluded reports items inside an
        // excluded folder as excluded, which is the behavior that mode depends on.
        let later = dir + "/S01E02.ts"
        FileManager.default.createFile(atPath: later, contents: Data([0]))
        #expect(isExcluded(later) == true)
        let sub = dir + "/Season 2"
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        #expect(isExcluded(sub) == true)
    }

    @Test func excludeFromTimeMachine_onAMissingPath_doesNotCrashOrTagAnything() {
        let missing = NSTemporaryDirectory() + "hdhrVCRplus-tm-missing-\(UUID().uuidString)"
        excludeFromTimeMachine(missing)   // logs a warning, must not throw/crash
        #expect(FileManager.default.fileExists(atPath: missing) == false)
    }

    @Test func configDefaultsToOff_andRoundTripsEachMode() throws {
        #expect(AppConfig().TimeMachine_exclude_mode == "off")
        for mode in ["off", "perFile", "perFolder"] {
            var cfg = AppConfig()
            cfg.TimeMachine_exclude_mode = mode
            let data = try JSONEncoder().encode(cfg)
            let back = try JSONDecoder().decode(AppConfig.self, from: data)
            #expect(back.TimeMachine_exclude_mode == mode)
        }
    }

    @Test func configMissingTheKey_decodesAsOff() throws {
        let back = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(back.TimeMachine_exclude_mode == "off")
    }

    // MARK: RecordingManager per-file switch

    @Test @MainActor func start_withExcludeFromBackup_preCreatesAndTagsTheOutputFile() async throws {
        let script = try writeMockCurlScript()
        defer { try? FileManager.default.removeItem(atPath: script) }
        let manager = RecordingManager(curlExecutablePath: script)
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let out = dir + "/tagged.ts"
        let showId = "test-\(UUID().uuidString)"
        try manager.start(showId: showId, title: "T", url: "http://192.0.2.1/auto/v5.1",
                          outputPath: out, durationSeconds: 60, transcode: "none",
                          showEnd: Date().addingTimeInterval(60), excludeFromBackup: true)
        defer { manager.stop(showId: showId) }
        #expect(FileManager.default.fileExists(atPath: out))
        #expect(isExcluded(out) == true)
    }

    @Test @MainActor func start_withoutExcludeFromBackup_leavesTheFileUntagged() async throws {
        let script = try writeMockCurlScript(outputBytes: 16)
        defer { try? FileManager.default.removeItem(atPath: script) }
        let manager = RecordingManager(curlExecutablePath: script)
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let out = dir + "/plain.ts"
        let showId = "test-\(UUID().uuidString)"
        try manager.start(showId: showId, title: "T", url: "http://192.0.2.1/auto/v5.1",
                          outputPath: out, durationSeconds: 60, transcode: "none",
                          showEnd: Date().addingTimeInterval(60))
        defer { manager.stop(showId: showId) }
        await waitUntil { FileManager.default.fileExists(atPath: out) }
        if FileManager.default.fileExists(atPath: out) { #expect(isExcluded(out) == false) }
    }
}
