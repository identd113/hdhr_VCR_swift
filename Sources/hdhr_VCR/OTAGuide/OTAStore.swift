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

    /// Per-multiplex bookkeeping: when each RF channel's channel list and guide were last read to the end (`mux.json`).
    struct MuxRecord: Codable, Equatable, Sendable {
        var rf: Int
        var lineupDate: Date?
        var guideDate: Date?
        var channels: Int
        var events: Int
        /// Consecutive scans that found nothing on this RF channel. A station is dropped only on its second miss in a row, so one slow lock or a
        /// busy tuner never deletes it. nil (and absent in older files) = none.
        var noSignalMisses: Int? = nil
    }

    /// Scans in a row that must find no signal on an RF channel before its saved channels and listings are removed.
    static let noSignalMissesToDrop = 2

    static func muxFile(deviceId: String, root: URL = OTAStore.root) -> URL { folder(deviceId: deviceId, root: root).appendingPathComponent("mux.json") }

    /// What is known per multiplex. A saved scan from before `mux.json` existed gets its channel-list date from `lineup.json`'s own date.
    static func muxRecords(deviceId: String, root: URL = OTAStore.root) -> [Int: MuxRecord] {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: muxFile(deviceId: deviceId, root: root)), let list = try? decoder.decode([MuxRecord].self, from: data) {
            return Dictionary(list.map { ($0.rf, $0) }, uniquingKeysWith: { first, _ in first })
        }
        guard let lineup = allSavedLineup(deviceId: deviceId, root: root), let date = lineupDate(deviceId: deviceId, root: root) else { return [:] }
        return Dictionary(grouping: lineup, by: \.RF).mapValues { MuxRecord(rf: $0[0].RF, lineupDate: date, guideDate: nil, channels: $0.count, events: 0) }
    }

    /// The saved channel list as written, hidden and protected services included.
    static func allSavedLineup(deviceId: String, root: URL = OTAStore.root) -> [OTALineupEntry]? {
        guard let data = try? Data(contentsOf: folder(deviceId: deviceId, root: root).appendingPathComponent("lineup.json")) else { return nil }
        return try? JSONDecoder().decode([OTALineupEntry].self, from: data)
    }

    private static func sortedByNumber<T>(_ items: [T], _ number: (T) -> String) -> [T] {
        items.sorted { (number($0).split(separator: ".").compactMap { Int($0) }).lexicographicallyPrecedes(number($1).split(separator: ".").compactMap { Int($0) }) }
    }

    /// Saves what a finished scan read, **per multiplex**: every RF channel the scan read replaces that RF's channels and listings (and its record in `mux.json`), and every RF
    /// it found with no signal is dropped; the other multiplexes keep what they had, so one station can be refreshed on its own. A lineup-only scan updates only channel lists (it
    /// seeds listings for channels that have none, never replacing an earlier guide). Returns the summary of what this scan read, or nil if it found nothing usable (an empty scan
    /// never replaces a good earlier one). `scan.json` (the "a full scan ran" record) is written only by a full scan, not by a one-station refresh (`partial`).
    @discardableResult
    static func save(_ outcome: OTAScanOutcome, deviceId: String, lineupOnly: Bool = false, partial: Bool = false, root: URL = OTAStore.root) -> OTAScanSummary? {
        let results = outcome.multiplexes.sorted { $0.rf < $1.rf }
        let guideNew = OTAGuideConverter.guideChannels(from: results.map(\.result))
        guard !guideNew.isEmpty else { return nil }
        let lineupNew: [OTALineupEntry] = results.flatMap { m in
            m.result.channels.map { c in
                OTALineupEntry(GuideNumber: c.number, GuideName: c.name, RF: m.rf, Frequency: m.frequencyHz, ProgramNumber: c.program,
                               ServiceType: c.serviceType, Hidden: c.hidden, Protected: c.accessControlled)
            }
        }
        let now = Date()
        let summary = OTAScanSummary(
            date: now, deviceId: deviceId, multiplexes: results.count, channels: guideNew.count,
            events: guideNew.reduce(0) { $0 + ($1.Guide?.count ?? 0) },
            skipped: Dictionary(uniqueKeysWithValues: outcome.skipped.map { ("RF \($0.key)", $0.value) }), cancelled: outcome.cancelled)
        let dir = folder(deviceId: deviceId, root: root)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601

            // Which RF channels this scan speaks for: the ones it read, and the ones that now have nothing on them.
            let read = Set(results.map(\.rf))
            // Of those, the ones whose guide this scan really read (a channel-list-only read of a station, e.g. one whose guide read failed in a full scan, never replaces listings).
            let guideRead = Set(results.filter { !lineupOnly && $0.guideRead }.map(\.rf))
            let silent = Set(outcome.skipped.filter { $0.value == "no signal" }.keys).subtracting(read)
            var records = muxRecords(deviceId: deviceId, root: root)   // before lineup.json is rewritten: an old save without mux.json takes its dates from the file
            // A station is dropped on its second silent scan in a row; the first only counts a miss and keeps what was saved. (A silent RF with no record has nothing to keep.)
            var gone = Set<Int>()
            for rf in silent {
                guard var rec = records[rf] else { continue }
                let misses = (rec.noSignalMisses ?? 0) + 1
                if misses >= Self.noSignalMissesToDrop { gone.insert(rf) } else { rec.noSignalMisses = misses; records[rf] = rec }
            }
            let replaced = read.union(gone)
            let oldLineup = allSavedLineup(deviceId: deviceId, root: root) ?? []
            let oldNumbers = Set(oldLineup.filter { guideRead.union(gone).contains($0.RF) }.map(\.GuideNumber))
            let goneNumbers = Set(oldLineup.filter { gone.contains($0.RF) }.map(\.GuideNumber))
            let lineup = sortedByNumber(oldLineup.filter { !replaced.contains($0.RF) } + lineupNew, { $0.GuideNumber })
            try encoder.encode(lineup).write(to: dir.appendingPathComponent("lineup.json"), options: .atomic)

            let oldGuide = (try? decoder.decode([GuideChannel].self, from: Data(contentsOf: guideFile(deviceId: deviceId, root: root)))) ?? []
            // Listings are replaced only for stations whose guide was read; everything else keeps what it had, and a channel with no listings yet is just added.
            let readNumbers = Set(OTAGuideConverter.guideChannels(from: results.filter { guideRead.contains($0.rf) }.map(\.result)).map(\.GuideNumber))
            let have = Set(oldGuide.map(\.GuideNumber)).subtracting(oldNumbers)
            var guide = oldGuide.filter { !oldNumbers.contains($0.GuideNumber) && !readNumbers.contains($0.GuideNumber) && !goneNumbers.contains($0.GuideNumber) }
            guide += guideNew.filter { readNumbers.contains($0.GuideNumber) || !have.contains($0.GuideNumber) }
            guide = sortedByNumber(guide, { $0.GuideNumber })
            // A channel-list-only save that changed nothing leaves guide.json (and its date, which the 36-hour freshness test reads) alone.
            if !lineupOnly || guide.count != oldGuide.count || Set(guide.map(\.GuideNumber)) != Set(oldGuide.map(\.GuideNumber)) {
                try encoder.encode(guide).write(to: guideFile(deviceId: deviceId, root: root), options: .atomic)
            }

            // Per-multiplex dates: this scan completed these RF channels now.
            for rf in gone { records[rf] = nil }
            for m in results {
                let numbers = Set(m.result.channels.map(\.number))
                var rec = records[m.rf] ?? MuxRecord(rf: m.rf, lineupDate: nil, guideDate: nil, channels: 0, events: 0)
                rec.lineupDate = now
                rec.noSignalMisses = nil   // heard again: the streak of silent scans ends
                rec.channels = numbers.count
                if !lineupOnly, m.guideRead {
                    rec.guideDate = now
                    rec.events = m.result.events.count
                }
                records[m.rf] = rec
            }
            try encoder.encode(records.values.sorted { $0.rf < $1.rf }).write(to: muxFile(deviceId: deviceId, root: root), options: .atomic)

            // The scan record means "a full scan ran" (the schedule reads its date): only a full scan writes it.
            if !lineupOnly, !partial { try encoder.encode(summary).write(to: dir.appendingPathComponent("scan.json"), options: .atomic) }
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
        var seen = Set<String>()   // one entry per channel number (two multiplexes can carry the same virtual number): ids stay unique
        let entries = saved.filter { ($0.ServiceType == 2 || $0.ServiceType == 3) && !$0.Hidden && !$0.Protected && seen.insert($0.GuideNumber).inserted }.map { e in
            LineupEntry(GuideNumber: e.GuideNumber, GuideName: e.GuideName, URL: "http://\(host):5004/auto/ch\(e.Frequency)-\(e.ProgramNumber)",
                        HD: nil, Favorite: nil, VideoCodec: nil, AudioCodec: nil)
        }
        return entries.sorted {
            ($0.GuideNumber.split(separator: ".").compactMap { Int($0) }).lexicographicallyPrecedes($1.GuideNumber.split(separator: ".").compactMap { Int($0) })
        }
    }

    /// Every real channel of the saved air lineup (video and audio services, no hidden or protected ones), whatever its age; nil when none is saved.
    static func savedLineup(deviceId: String, root: URL = OTAStore.root) -> [OTALineupEntry]? {
        guard let saved = allSavedLineup(deviceId: deviceId, root: root) else { return nil }
        var seen = Set<String>()   // first entry per channel number wins (as `airOnly` does), so list/picker ids are unique
        return saved.filter { ($0.ServiceType == 2 || $0.ServiceType == 3) && !$0.Hidden && !$0.Protected && seen.insert($0.GuideNumber).inserted }
    }

    /// The listings a scan saved, by channel number (empty when none). Decodes the whole saved guide: callers cache it by the file's date.
    static func savedListings(deviceId: String, only numbers: Set<String>, root: URL = OTAStore.root) -> [String: [GuideEntry]] {
        guard !numbers.isEmpty, let data = try? Data(contentsOf: guideFile(deviceId: deviceId, root: root)),
              let channels = try? JSONDecoder().decode([GuideChannel].self, from: data) else { return [:] }
        var out: [String: [GuideEntry]] = [:]
        for c in channels where numbers.contains(c.GuideNumber) { out[c.GuideNumber] = (c.Guide ?? []).sorted { $0.StartTime < $1.StartTime } }
        return out
    }

    /// The air channels the tuner's own lineup does not have (matched by channel number), sorted by number: what the web guide's "Air only" section lists.
    static func airOnly(saved: [OTALineupEntry], tunerLineup: [LineupEntry]) -> [OTALineupEntry] {
        let known = Set(tunerLineup.map(\.GuideNumber))
        var seen = Set<String>()
        return saved.filter { !known.contains($0.GuideNumber) && seen.insert($0.GuideNumber).inserted }.sorted {
            ($0.GuideNumber.split(separator: ".").compactMap { Int($0) }).lexicographicallyPrecedes($1.GuideNumber.split(separator: ".").compactMap { Int($0) })
        }
    }

    /// Developer purge: removes a device's saved air data. `guide` = guide.json + scan.json, `lineup` = lineup.json; the per-multiplex dates follow.
    static func deleteSaved(deviceId: String, guide: Bool, lineup: Bool, root: URL = OTAStore.root) {
        let dir = folder(deviceId: deviceId, root: root)
        if guide { for f in ["guide.json", "scan.json"] { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) } }
        if lineup { try? FileManager.default.removeItem(at: dir.appendingPathComponent("lineup.json")) }
        var records = muxRecords(deviceId: deviceId, root: root)
        guard !records.isEmpty else { return }
        for rf in records.keys {
            if guide { records[rf]?.guideDate = nil; records[rf]?.events = 0 }
            if lineup { records[rf]?.lineupDate = nil; records[rf]?.channels = 0 }
        }
        let kept = records.values.filter { $0.lineupDate != nil || $0.guideDate != nil }.sorted { $0.rf < $1.rf }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        if kept.isEmpty { try? FileManager.default.removeItem(at: muxFile(deviceId: deviceId, root: root)) }
        else { try? encoder.encode(kept).write(to: muxFile(deviceId: deviceId, root: root), options: .atomic) }
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
