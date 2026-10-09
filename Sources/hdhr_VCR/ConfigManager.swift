import Foundation

final class ConfigManager {
    private let hostname: String
    private var configURL: URL
    /// Directory holding the config file (and, under it, other on-disk app state such as the guide cache).
    let supportDir: URL
    /// Where the last-ever migration fallback looks (the old TCC-protected location). A test seam like
    /// `appSupportDir`: without it, any test of `load()`'s fallbacks reads this Mac's real ~/Documents.
    private let documentsDir: URL

    // appSupportDir is a test seam only — production always passes nil and gets the real
    // ~/Library/Application Support/hdhrVCRplus/ (not TCC-protected, survives ad-hoc re-signs).
    // Without this, any test that exercises an AppState mutating path (deleteShow, addShow, …)
    // would silently overwrite the live user's config through the app's real save path.
    init(appSupportDir: URL? = nil, documentsDir: URL? = nil) {
        hostname = ProcessInfo.processInfo.hostName
        self.documentsDir = documentsDir ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let appSupport = appSupportDir ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("hdhrVCRplus")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        supportDir = appSupport
        configURL = appSupport.appendingPathComponent("hdhr_VCR-\(hostname).json")
    }

    func load() -> ConfigFile? {
        let decoder = Self.makeDecoder()
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
        let docsURL = documentsDir.appendingPathComponent("hdhr_VCR-\(hostname).json")
        if let data = try? Data(contentsOf: docsURL),
           let file = try? decoder.decode(ConfigFile.self, from: data) {
            glog("[ConfigManager] Migrated config from ~/Documents")
            return maybeUpgrade(file)
        }
        // The file is keyed by the machine's hostname, which isn't stable (DHCP-assigned name, a
        // ".local" vs ".lan" suffix, a rename, a VPN) — a changed name would otherwise look like a
        // fresh install: no shows, first-run wizard again, and the old file orphaned. This folder is
        // per-user, per-machine, so any other hdhr_VCR-*.json in it is this install's config under an
        // earlier name. Adopt the most recently saved one that decodes, as a copy (the original stays).
        if let (adopted, file) = newestOtherHostConfig(decoder: decoder) {
            glog("[ConfigManager] No config for hostname '\(hostname)' — adopting \(adopted.lastPathComponent) (hostname changed?)", level: .warning)
            if let data = try? Data(contentsOf: adopted) { try? data.write(to: configURL, options: .atomic) }
            return maybeUpgrade(file)
        }
        glog("[ConfigManager] No config found — fresh install")
        return nil
    }

    /// The most recently modified `hdhr_VCR-<other host>.json` (never a `.bak`, never the current
    /// host's own file) in the support directory that decodes as a ConfigFile.
    private func newestOtherHostConfig(decoder: JSONDecoder) -> (URL, ConfigFile)? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: supportDir.path) else { return nil }
        let candidates = names
            .filter { $0.hasPrefix("hdhr_VCR-") && $0.hasSuffix(".json") && $0 != configURL.lastPathComponent }
            .map { supportDir.appendingPathComponent($0) }
            .compactMap { url -> (URL, Date)? in
                guard let m = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return nil }
                return (url, m)
            }
            .sorted { $0.1 > $1.1 }
        for (url, _) in candidates {
            if let data = try? Data(contentsOf: url), let file = try? decoder.decode(ConfigFile.self, from: data) {
                return (url, file)
            }
        }
        return nil
    }

    // Set by importConfig — from then until the app restarts, every save is skipped. Without this
    // the next idle-loop dirty save, or teardownForExit's save on Quit, wrote the old in-memory
    // config/shows straight back over the just-imported file (2026-10-01 review finding #5).
    private let importLock = NSLock()
    private var _savesSuppressedAfterImport = false
    var savesSuppressedAfterImport: Bool { importLock.withLock { _savesSuppressedAfterImport } }

    func save(_ file: ConfigFile) throws {
        if savesSuppressedAfterImport {
            glog("[Config] Save skipped — a config was imported this session; restart to load it")
            return
        }
        let backup = configURL.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: configURL, to: backup)
        let data = try Self.makeEncoder().encode(file)
        try data.write(to: configURL, options: .atomic)
        glog("[Config] Saved \(configURL.lastPathComponent)")
    }

    // Serial so writes stay strictly in call order — save(_:) does a remove+copy+atomic-write, and
    // running two concurrently on a shared DispatchQueue.concurrentPerform-style queue could let an
    // older snapshot's write land after a newer one's, leaving stale content as the final on-disk
    // file. FIFO on a serial queue guarantees each call's I/O completes before the next one starts.
    private let saveQueue = DispatchQueue(label: "hdhr_VCR.ConfigManager.save", qos: .utility)

    // Runs save(_:)'s file I/O on a private background queue instead of the caller's own thread.
    // AppState.saveConfig() is this method's one real caller and runs on @MainActor for 26 call
    // sites covering essentially every show mutation — WebServer hops onto that same actor for
    // nearly every request touching AppState, so synchronous disk I/O here previously stalled every
    // web request queued behind it (see TODO.md's "ConfigManager.save's disk write runs
    // synchronously on the MainActor" entry, and ISSUES.md's "Web guide feels laggy" root-cause
    // chain). Mirrors the same nonisolated-background-work shape already used for
    // writeMetadataSidecar/recordedEpisodeTags. `onFailure` (called off the calling thread) exists
    // so a caller that needs to react to a failed save — AppState.saveConfig() sets a user-visible
    // statusMessage — still can, without saveAsync itself needing to be async/throwing.
    func saveAsync(_ file: ConfigFile, onFailure: ((Error) -> Void)? = nil) {
        saveQueue.async { [self] in
            do {
                try save(file)
            } catch {
                glog("[Config] Save failed: \(error)", level: .error)
                onFailure?(error)
            }
        }
    }

    // Blocks the caller until every saveAsync(_:) enqueued so far has actually finished writing to
    // disk — call only right before the process is about to exit (the SIGTERM handler,
    // AppState.teardownForExit()), where a fire-and-forget save could otherwise still be sitting in
    // the queue when the process dies, silently discarding it. Everywhere else, saveAsync's whole
    // point is to keep this exact wait off the caller (usually @MainActor), so don't call this from
    // a normal show-mutation path. Safe (returns immediately) when nothing is pending.
    func flushPendingSaves() {
        saveQueue.sync {}
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
        // On saveQueue so a saveAsync already queued can't land *after* the import and overwrite
        // it; the suppression flag is set in the same step for every save after it.
        try saveQueue.sync {
            let backup = configURL.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: configURL, to: backup)
            try data.write(to: configURL, options: .atomic)
            importLock.withLock { _savesSuppressedAfterImport = true }
        }
        glog("[Config] Imported config from \(url.lastPathComponent) — saves suppressed until restart")
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
