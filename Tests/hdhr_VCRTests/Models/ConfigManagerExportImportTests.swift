import Testing
import Foundation
@testable import hdhr_VCR

// MARK: - ConfigManager.exportConfig(to:) / importConfig(from:)
//
// Settings → Advanced's Export/Import Config buttons (TODO.md's "No export / import of config"
// item). Both are pure file-level operations — no AppState hot-reload — so this file only needs
// a bare ConfigManager instance, not a full AppState.

@Suite("ConfigManager export/import")
struct ConfigManagerExportImportTests {

    private func makeManager() -> (ConfigManager, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hdhrCfgIOTest-\(UUID().uuidString)")
        return (ConfigManager(appSupportDir: dir), dir)
    }

    private func write(_ json: String, to manager: ConfigManager) throws {
        try Data(json.utf8).write(to: URL(fileURLWithPath: manager.configPath))
    }

    private let validConfigJSON = #"""
    {"config": {"Config_version": "2"},
     "shows": [{"show_id": "a", "show_title": "Exported Show"}]}
    """#

    @Test func exportConfig_copiesLiveFileToDestination() throws {
        let (mgr, dir) = makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(validConfigJSON, to: mgr)

        let dest = dir.appendingPathComponent("exported.json")
        try mgr.exportConfig(to: dest)

        let exportedData = try Data(contentsOf: dest)
        let liveData = try Data(contentsOf: URL(fileURLWithPath: mgr.configPath))
        #expect(exportedData == liveData)
    }

    @Test func exportConfig_overwritesExistingDestination() throws {
        let (mgr, dir) = makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(validConfigJSON, to: mgr)

        let dest = dir.appendingPathComponent("exported.json")
        try Data("stale content from a previous export".utf8).write(to: dest)
        try mgr.exportConfig(to: dest)

        let exportedData = try Data(contentsOf: dest)
        let liveData = try Data(contentsOf: URL(fileURLWithPath: mgr.configPath))
        #expect(exportedData == liveData)
    }

    @Test func importConfig_validJSON_replacesLiveConfig() throws {
        let (mgr, dir) = makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(#"""
        {"config": {"Config_version": "2"},
         "shows": [{"show_id": "original", "show_title": "Original Show"}]}
        """#, to: mgr)

        let importSrc = dir.appendingPathComponent("import-me.json")
        try Data(#"""
        {"config": {"Config_version": "2"},
         "shows": [{"show_id": "imported", "show_title": "Imported Show"}]}
        """#.utf8).write(to: importSrc)

        try mgr.importConfig(from: importSrc)

        let reloaded = mgr.load()
        #expect(reloaded?.shows.first?.show_id == "imported")
        #expect(reloaded?.shows.first?.show_title == "Imported Show")
    }

    @Test func importConfig_createsBackupOfPreviousConfig() throws {
        let (mgr, dir) = makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(#"""
        {"config": {"Config_version": "2"},
         "shows": [{"show_id": "original", "show_title": "Original Show"}]}
        """#, to: mgr)

        let importSrc = dir.appendingPathComponent("import-me.json")
        try Data(validConfigJSON.utf8).write(to: importSrc)
        try mgr.importConfig(from: importSrc)

        let backupURL = URL(fileURLWithPath: mgr.configPath).appendingPathExtension("bak")
        let backupData = try Data(contentsOf: backupURL)
        let backupJSON = try JSONSerialization.jsonObject(with: backupData) as? [String: Any]
        let backupShows = backupJSON?["shows"] as? [[String: Any]]
        #expect(backupShows?.first?["show_id"] as? String == "original")
    }

    @Test func importConfig_malformedJSON_throwsAndLeavesLiveConfigUnchanged() throws {
        let (mgr, dir) = makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(validConfigJSON, to: mgr)
        let liveDataBefore = try Data(contentsOf: URL(fileURLWithPath: mgr.configPath))

        let importSrc = dir.appendingPathComponent("bogus.json")
        try Data("not json at all".utf8).write(to: importSrc)

        #expect(throws: (any Error).self) { try mgr.importConfig(from: importSrc) }

        let liveDataAfter = try Data(contentsOf: URL(fileURLWithPath: mgr.configPath))
        #expect(liveDataBefore == liveDataAfter, "A malformed import must never touch the live config")
    }
}
