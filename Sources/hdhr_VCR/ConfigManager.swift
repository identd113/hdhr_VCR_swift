import Foundation

final class ConfigManager {
    private let hostname: String
    private var configURL: URL

    init() {
        hostname = ProcessInfo.processInfo.hostName
        // ~/Library/Application Support/hdhrVCRplus/ — not TCC-protected, survives ad-hoc re-signs
        let appSupport = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("hdhrVCRplus")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        configURL = appSupport.appendingPathComponent("hdhr_VCR-\(hostname).json")
    }

    func load() -> ConfigFile? {
        let decoder = Self.makeDecoder()
        // Try main config
        if let data = try? Data(contentsOf: configURL),
           let file = try? decoder.decode(ConfigFile.self, from: data) {
            return maybeUpgrade(file)
        }
        // Fall back to backup — restore as main so future saves have a base
        let backup = configURL.appendingPathExtension("bak")
        if let data = try? Data(contentsOf: backup),
           let file = try? decoder.decode(ConfigFile.self, from: data) {
            glog("[ConfigManager] Main config missing/corrupt — restored from backup", level: .warning)
            try? data.write(to: configURL, options: .atomic)
            return maybeUpgrade(file)
        }
        // Final fallback: ~/Documents (last-ever migration from old TCC-protected location)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let docsURL = docs.appendingPathComponent("hdhr_VCR-\(hostname).json")
        if let data = try? Data(contentsOf: docsURL),
           let file = try? decoder.decode(ConfigFile.self, from: data) {
            glog("[ConfigManager] Migrated config from ~/Documents")
            return maybeUpgrade(file)
        }
        glog("[ConfigManager] No config found — fresh install")
        return nil
    }

    func save(_ file: ConfigFile) throws {
        let backup = configURL.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: configURL, to: backup)
        let data = try Self.makeEncoder().encode(file)
        try data.write(to: configURL, options: .atomic)
        glog("[Config] Saved \(configURL.lastPathComponent)")
    }

    var configPath: String { configURL.path }

    // MARK: - Private

    private func maybeUpgrade(_ file: ConfigFile) -> ConfigFile {
        guard file.config.Config_version != "2" else { return file }
        // Warn about any Mac alias paths that will no longer auto-convert
        for show in file.shows where show.show_temp_dir.contains(":") && !show.show_temp_dir.hasPrefix("/") {
            glog("[ConfigManager] '\(show.show_title)' has Mac alias path '\(show.show_temp_dir)' — clear show_temp_dir if recording path is wrong", level: .warning)
        }
        var upgraded = file
        upgraded.config.Config_version = "2"
        do {
            try save(upgraded)
            glog("[ConfigManager] Migrated config to v2 (ISO8601 dates, 'shows' key)")
        } catch {
            glog("[ConfigManager] v2 migration save failed — will retry next launch: \(error)", level: .warning)
        }
        return upgraded
    }

    // Handles both ISO8601 (v2) and legacy string/numeric epoch (v1) date formats.
    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            if let str = try? c.decode(String.self) {
                // v2: ISO8601
                if let date = ISO8601DateFormatter().date(from: str) { return date }
                // v1: string epoch ("1748613600")
                if let epoch = Double(str), epoch > 0 { return Date(timeIntervalSince1970: epoch) }
                // "missing value", "0", empty — throw so try? decodes as nil
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not a valid date: \(str)")
            }
            // v1: numeric epoch
            if let epoch = try? c.decode(Double.self), epoch > 0 {
                return Date(timeIntervalSince1970: epoch)
            }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Cannot decode date")
        }
        return d
    }

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}
