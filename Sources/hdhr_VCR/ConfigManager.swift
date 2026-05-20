import Foundation

final class ConfigManager {
    private let hostname: String
    private var configURL: URL

    init() {
        hostname = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        configURL = docs.appendingPathComponent("hdhr_VCR-\(hostname).json")
    }

    func load() -> ConfigFile? {
        guard let data = try? Data(contentsOf: configURL) else {
            print("[ConfigManager] No config at \(configURL.path)")
            return nil
        }
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(ConfigFile.self, from: data)
        } catch {
            print("[ConfigManager] Decode error: \(error)")
            return nil
        }
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
