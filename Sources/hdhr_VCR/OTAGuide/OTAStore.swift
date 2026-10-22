import Foundation

// Part of the over-the-air guide (overtime/APP_PLAN.md). Where a scan's result lives on disk, per device:
//   ~/Library/Application Support/hdhrVCRplus/ota/<DeviceID>/guide.json   [GuideChannel]: what GuideStore loads
//   .../lineup.json                                                      [OTALineupEntry]: channels seen on the air
//   .../scan.json                                                        OTAScanSummary: when, how long, what was skipped and why
// Writes are atomic. Nothing here touches the main actor.

struct OTALineupEntry: Codable, Equatable, Sendable {
    var GuideNumber: String
    var GuideName: String
    var RF: Int
    var Frequency: Int
    var ProgramNumber: Int
    var ServiceType: Int
    var Hidden: Bool
    var Protected: Bool
}

struct OTAScanSummary: Codable, Equatable, Sendable {
    var date: Date
    var deviceId: String
    var multiplexes: Int
    var channels: Int
    var events: Int
    var skipped: [String: String]   // "RF 25" → reason
    var cancelled: Bool
}

enum OTAStore {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("hdhrVCRplus/ota", isDirectory: true)
    }
    static func folder(deviceId: String, root: URL = OTAStore.root) -> URL { root.appendingPathComponent(deviceId, isDirectory: true) }
    static func guideFile(deviceId: String, root: URL = OTAStore.root) -> URL { folder(deviceId: deviceId, root: root).appendingPathComponent("guide.json") }

    /// Builds and saves the guide, lineup and summary for a finished scan. Returns the summary, or nil if nothing usable was found
    /// (an empty scan never replaces a good earlier one).
    @discardableResult
    static func save(_ outcome: OTAScanOutcome, deviceId: String, lineupOnly: Bool = false, root: URL = OTAStore.root) -> OTAScanSummary? {
        let results = outcome.multiplexes.sorted { $0.rf < $1.rf }
        let guide = OTAGuideConverter.guideChannels(from: results.map(\.result))
        guard !guide.isEmpty else { return nil }
        let lineup: [OTALineupEntry] = results.flatMap { m in
            m.result.channels.map { c in
                OTALineupEntry(GuideNumber: c.number, GuideName: c.name, RF: m.rf, Frequency: m.frequencyHz, ProgramNumber: c.program,
                               ServiceType: c.serviceType, Hidden: c.hidden, Protected: c.accessControlled)
            }
        }
        let summary = OTAScanSummary(
            date: Date(), deviceId: deviceId, multiplexes: results.count, channels: guide.count,
            events: guide.reduce(0) { $0 + ($1.Guide?.count ?? 0) },
            skipped: Dictionary(uniqueKeysWithValues: outcome.skipped.map { ("RF \($0.key)", $0.value) }), cancelled: outcome.cancelled)
        let dir = folder(deviceId: deviceId, root: root)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(lineup).write(to: dir.appendingPathComponent("lineup.json"), options: .atomic)
            // A lineup-only scan carries no listings: it never replaces an earlier guide or its scan record, it only seeds a guide when none exists.
            let hasGuide = FileManager.default.fileExists(atPath: dir.appendingPathComponent("guide.json").path)
            if !lineupOnly || !hasGuide { try encoder.encode(guide).write(to: dir.appendingPathComponent("guide.json"), options: .atomic) }
            // The scan record means "a full scan ran" (the schedule reads its date), so a lineup-only scan never writes it.
            if !lineupOnly { try encoder.encode(summary).write(to: dir.appendingPathComponent("scan.json"), options: .atomic) }
            return summary
        } catch {
            glog("[OTA] could not save the scan: \(error.localizedDescription)", level: .warning)
            return nil
        }
    }

    /// True when a saved guide for this device exists and is no older than `maxAge` (the same 36 h GuideStore.loadOTA accepts).
    static func hasFreshGuide(deviceId: String, maxAge: TimeInterval = GuideStore.staleFallbackMaxAge, root: URL = OTAStore.root) -> Bool {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: guideFile(deviceId: deviceId, root: root).path))?[.modificationDate] as? Date
        else { return false }
        return Date().timeIntervalSince(modified) <= maxAge
    }

    /// The saved air lineup as the app's own `LineupEntry`s (no copy-protected or hidden services), tuned by frequency and program number:
    /// `http://<tuner>:5004/auto/ch<Hz>-<program>` (verified live: the tuner filters the stream to that one program). Nil when there is
    /// no saved scan or it is older than `maxAge`.
    static func lineupEntries(deviceId: String, host: String, maxAge: TimeInterval = GuideStore.staleFallbackMaxAge, root: URL = OTAStore.root) -> [LineupEntry]? {
        let file = folder(deviceId: deviceId, root: root).appendingPathComponent("lineup.json")
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) <= maxAge,
              let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode([OTALineupEntry].self, from: data) else { return nil }
        let entries = saved.filter { ($0.ServiceType == 2 || $0.ServiceType == 3) && !$0.Hidden && !$0.Protected }.map { e in
            LineupEntry(GuideNumber: e.GuideNumber, GuideName: e.GuideName, URL: "http://\(host):5004/auto/ch\(e.Frequency)-\(e.ProgramNumber)",
                        HD: nil, Favorite: nil, VideoCodec: nil, AudioCodec: nil)
        }
        return entries.sorted {
            ($0.GuideNumber.split(separator: ".").compactMap { Int($0) }).lexicographicallyPrecedes($1.GuideNumber.split(separator: ".").compactMap { Int($0) })
        }
    }

    /// Every real channel of the saved air lineup (video and audio services, no hidden or protected ones), whatever its age; nil when none is saved.
    static func savedLineup(deviceId: String, root: URL = OTAStore.root) -> [OTALineupEntry]? {
        let file = folder(deviceId: deviceId, root: root).appendingPathComponent("lineup.json")
        guard let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([OTALineupEntry].self, from: data) else { return nil }
        return saved.filter { ($0.ServiceType == 2 || $0.ServiceType == 3) && !$0.Hidden && !$0.Protected }
    }

    /// The air channels the tuner's own lineup does not have (matched by channel number), sorted by number: what the web guide's "Air only" section lists.
    static func airOnly(saved: [OTALineupEntry], tunerLineup: [LineupEntry]) -> [OTALineupEntry] {
        let known = Set(tunerLineup.map(\.GuideNumber))
        var seen = Set<String>()
        return saved.filter { !known.contains($0.GuideNumber) && seen.insert($0.GuideNumber).inserted }.sorted {
            ($0.GuideNumber.split(separator: ".").compactMap { Int($0) }).lexicographicallyPrecedes($1.GuideNumber.split(separator: ".").compactMap { Int($0) })
        }
    }

    /// Developer purge: removes a device's saved air data. `guide` = guide.json + scan.json, `lineup` = lineup.json.
    static func deleteSaved(deviceId: String, guide: Bool, lineup: Bool, root: URL = OTAStore.root) {
        let dir = folder(deviceId: deviceId, root: root)
        if guide { for f in ["guide.json", "scan.json"] { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) } }
        if lineup { try? FileManager.default.removeItem(at: dir.appendingPathComponent("lineup.json")) }
    }

    /// When this device's saved channel list was written, or nil when there is none.
    static func lineupDate(deviceId: String, root: URL = OTAStore.root) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: folder(deviceId: deviceId, root: root).appendingPathComponent("lineup.json").path))?[.modificationDate] as? Date
    }

    /// When this device's channel list and guide were last scanned to the end (nil = never, or the scan was cancelled before it finished).
    static func lastCompletedScans(deviceId: String, root: URL = OTAStore.root) -> (lineup: Date?, guide: Date?) {
        let guide = loadSummary(deviceId: deviceId, root: root).flatMap { $0.cancelled ? nil : $0.date }
        return (lineupDate(deviceId: deviceId, root: root), guide)
    }

    static func loadSummary(deviceId: String, root: URL = OTAStore.root) -> OTAScanSummary? {
        guard let data = try? Data(contentsOf: folder(deviceId: deviceId, root: root).appendingPathComponent("scan.json")) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(OTAScanSummary.self, from: data)
    }
}
