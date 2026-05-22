import Foundation

final class ConfigManager {
    private let hostname: String
    private var configURL: URL

    init() {
        hostname = ProcessInfo.processInfo.hostName
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        configURL = docs.appendingPathComponent("hdhr_VCR-\(hostname).json")
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
            print("[ConfigManager] Main config missing/corrupt — restored from backup")
            try? data.write(to: configURL, options: .atomic)
            return file
        }
        print("[ConfigManager] No config or backup — fresh install")
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
