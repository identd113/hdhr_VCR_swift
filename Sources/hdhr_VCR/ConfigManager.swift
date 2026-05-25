import Foundation

final class ConfigManager {
    private let hostname: String
    private var configURL: URL

    init() {
        hostname = ProcessInfo.processInfo.hostName
        // ~/Library/Application Support/hdhrVCRplus/ — not TCC-protected, survives ad-hoc re-signs
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("hdhrVCRplus")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        configURL = appSupport.appendingPathComponent("hdhr_VCR-\(hostname).json")
        migrateFromDocumentsIfNeeded()
    }

    // One-time migration: move the config from ~/Documents (TCC-protected) to Application Support.
    // After migration the old file is left in place so the AppleScript app can still use it.
    private func migrateFromDocumentsIfNeeded() {
        guard !FileManager.default.fileExists(atPath: configURL.path) else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let oldURL = docs.appendingPathComponent("hdhr_VCR-\(hostname).json")
        guard let data = try? Data(contentsOf: oldURL) else { return }
        try? data.write(to: configURL, options: .atomic)
        // Also copy backup so first save still has a prior version to back up from
        let oldBak = oldURL.appendingPathExtension("bak")
        if let bakData = try? Data(contentsOf: oldBak) {
            try? bakData.write(to: configURL.appendingPathExtension("bak"), options: .atomic)
        }
        glog("[ConfigManager] migrated config from ~/Documents to Application Support")
    }

    func load() -> ConfigFile? {
        let decoder = JSONDecoder()
        // Try main config first
        if let data = try? Data(contentsOf: configURL),
           let file = try? decoder.decode(ConfigFile.self, from: data) {
            return file
        }
        // Fall back to backup — restore it as the main file so future saves have a base
        let backup = configURL.appendingPathExtension("bak")
        if let data = try? Data(contentsOf: backup),
           let file = try? decoder.decode(ConfigFile.self, from: data) {
            glog("[ConfigManager] Main config missing/corrupt — restored from backup", level: .warning)
            try? data.write(to: configURL, options: .atomic)
            return file
        }
        glog("[ConfigManager] No config or backup — fresh install")
        return nil
    }

    func save(_ file: ConfigFile) throws {
        // Backup before write
        let backup = configURL.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: configURL, to: backup)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        try data.write(to: configURL, options: .atomic)
    }

    var configPath: String { configURL.path }
}
