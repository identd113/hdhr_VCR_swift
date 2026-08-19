import Foundation

final class ConfigManager {
    private let hostname: String
    private var configURL: URL

    // appSupportDir is a test seam only — production always passes nil and gets the real
    // ~/Library/Application Support/hdhrVCRplus/ (not TCC-protected, survives ad-hoc re-signs).
    // Without this, any test that exercises an AppState mutating path (deleteShow, addShow, …)
    // would silently overwrite the live user's config through the app's real save path.
    init(appSupportDir: URL? = nil) {
        hostname = ProcessInfo.processInfo.hostName
        let appSupport = appSupportDir ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
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

    // Copies the live config file to `url` — used by Settings' Export Config button. Removes an
    // existing file at `url` first since NSSavePanel's own overwrite confirmation only clears the
    // user prompt, not the file itself, and copyItem throws if the destination already exists.
    func exportConfig(to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.copyItem(at: configURL, to: url)
    }

    // Validates that `url` decodes as a well-formed ConfigFile (same decoder/date-format handling
    // as load()) before touching anything, then backs up the current config and replaces it —
    // used by Settings' Import Config button. Deliberately does not update any in-memory AppState
    // — a currently-recording show's live state (show_recording, discovered devices, tuner
    // occupancy) can't be safely reconciled against an arbitrary imported file mid-session, so the
    // caller is expected to prompt for an app restart instead.
    func importConfig(from url: URL) throws {
        let data = try Data(contentsOf: url)
        _ = try Self.makeDecoder().decode(ConfigFile.self, from: data)
        let backup = configURL.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: configURL, to: backup)
        try data.write(to: configURL, options: .atomic)
        glog("[Config] Imported config from \(url.lastPathComponent)")
    }

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

    // Allocated once — ISO8601DateFormatter is thread-safe per Apple docs, and decode runs on one thread anyway.
    private static let iso8601Formatter = ISO8601DateFormatter()

    // Handles both ISO8601 (v2) and legacy string/numeric epoch (v1) date formats.
    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            if let str = try? c.decode(String.self) {
                // v2: ISO8601
                if let date = iso8601Formatter.date(from: str) { return date }
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
