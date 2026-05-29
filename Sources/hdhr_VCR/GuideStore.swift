import Foundation

/// Unified guide cache for all HDHomeRun devices.
///
/// Single source of truth for guide data: builds URLs, fetches JSON, decodes it,
/// stores the raw channels, and maintains two secondary indexes for fast lookup:
///   - channelEntryIndex: "deviceId:channelNum" → [GuideEntry] sorted by StartTime
///   - seriesIndex:       seriesID              → [SeriesMatch] sorted by StartTime
///
/// All methods run on @MainActor (AppState's executor), so mutations are inherently
/// serial. Network calls yield the actor during I/O; state is only written after
/// the response arrives.
@MainActor
final class GuideStore {

    // MARK: - Types

    struct SeriesMatch {
        let deviceId: String
        let channelNum: String
        let entry: GuideEntry
    }

    // MARK: - State

    private(set) var channelsByDevice: [String: [GuideChannel]] = [:]
    private var channelEntryIndex: [String: [GuideEntry]] = [:]   // "devId:chNum" → sorted entries
    private var seriesIndex: [String: [SeriesMatch]] = [:]         // seriesID → sorted matches
    private var loadingDevices: Set<String> = []
    private var loadTimestamps: [String: Date] = [:]

    var verbose: Bool = false

    static let guideLogPath = NSHomeDirectory() + "/Library/Logs/hdhrVCRplus.log"

    // Injected at init so tests can supply a mock session
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
        glog("=== GuideStore initialised ===")
    }

    // MARK: - URL building

    /// Canonical guide URL for a device. Duration is always in seconds.
    /// - Cloud devices (has DeviceAuth): SiliconDust cloud API
    /// - Local devices: device's own /guide.json endpoint
    nonisolated static func guideURL(for device: HDHRDevice, hours: Int = 12) -> URL? {
        let durationSecs = hours * 3600
        if let auth = device.DeviceAuth {
            return URL(string: "https://api.hdhomerun.com/api/guide.php?DeviceAuth=\(auth)&Duration=\(durationSecs)")
        }
        if device.LocalIP.isEmpty { return nil }
        return URL(string: "http://\(device.LocalIP)/guide.json?Duration=\(durationSecs)")
    }

    // MARK: - Loading

    /// Fetch and index guide for one device. No-op if already loading.
    /// Returns true if channels were successfully loaded, false on any error.
    @discardableResult
    func load(for device: HDHRDevice, hours: Int = 12) async -> Bool {
        let id = device.DeviceID
        glog("[\(id)] load() called — DeviceAuth:\(device.DeviceAuth ?? "nil")  LocalIP:'\(device.LocalIP)'  hours:\(hours)")

        guard !loadingDevices.contains(id) else {
            glog("[\(id)] already loading — skipped")
            return false
        }
        guard let url = Self.guideURL(for: device, hours: hours) else {
            glog("[\(id)] ERROR: could not build guide URL — DeviceAuth:\(device.DeviceAuth != nil ? "present" : "nil")  LocalIP:'\(device.LocalIP)'", level: .error)
            return false
        }

        loadingDevices.insert(id)
        defer { loadingDevices.remove(id) }

        glog("[\(id)] GET \(url.absoluteString)")
        let t0 = Date()
        do {
            let (data, response) = try await session.data(from: url)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let levelHttp: LogLevel = status == 200 ? .info : .warning
            glog("[\(id)] HTTP \(status)  \(data.count) bytes  \(ms)ms", level: levelHttp)

            // Log first 500 chars of raw response to help diagnose unexpected formats
            if let preview = String(data: data.prefix(500), encoding: .utf8) {
                glog("[\(id)] response preview: \(preview)")
            } else {
                glog("[\(id)] response is not UTF-8 — binary or empty", level: .warning)
            }

            guard status == 200 else {
                glog("[\(id)] ERROR: non-200 status, aborting parse", level: .error)
                return false
            }

            guard !data.isEmpty else {
                glog("[\(id)] ERROR: empty response body", level: .error)
                return false
            }

            let channels: [GuideChannel]
            do {
                channels = try JSONDecoder().decode([GuideChannel].self, from: data)
            } catch {
                glog("[\(id)] PARSE ERROR: \(error)", level: .error)
                // Log more of the raw response on parse failure for diagnosis
                if let full = String(data: data.prefix(2000), encoding: .utf8) {
                    glog("[\(id)] raw response (2000 chars): \(full)", level: .error)
                }
                return false
            }

            let entryCount = channels.reduce(0) { $0 + ($1.Guide?.count ?? 0) }
            glog("[\(id)] parsed \(channels.count) channels, \(entryCount) total guide entries")

            // Log per-channel summary
            for ch in channels.prefix(5) {
                glog("[\(id)]   ch \(ch.GuideNumber) \(ch.GuideName): \(ch.Guide?.count ?? 0) entries")
            }
            if channels.count > 5 {
                glog("[\(id)]   ... and \(channels.count - 5) more channels")
            }

            if entryCount == 0 {
                glog("[\(id)] WARNING: channels loaded but ALL have 0 guide entries — check GuideHours setting or API response", level: .warning)
            }

            buildIndex(deviceId: id, channels: channels)
            loadTimestamps[id] = Date()
            glog("[\(id)] index built and timestamp set — guide ready")
            return true

        } catch {
            glog("[\(id)] NETWORK ERROR: \(error)", level: .error)
            return false
        }
    }

    /// Fetch guide for all devices in parallel. Returns per-device success map.
    @discardableResult
    func loadAll(devices: [HDHRDevice], hours: Int = 12) async -> [String: Bool] {
        guard !devices.isEmpty else {
            glog("loadAll called with 0 devices — nothing to do")
            return [:]
        }
        glog("loadAll: \(devices.count) device(s), hours=\(hours)")
        var results: [String: Bool] = [:]
        await withTaskGroup(of: (String, Bool).self) { group in
            for device in devices {
                group.addTask { (device.DeviceID, await self.load(for: device, hours: hours)) }
            }
            for await (id, ok) in group { results[id] = ok }
        }
        let total = channelsByDevice.values.reduce(0) { $0 + $1.count }
        glog("loadAll complete — \(total) total channels across \(channelsByDevice.count) device(s)")
        return results
    }

    // MARK: - Indexing

    private func buildIndex(deviceId: String, channels: [GuideChannel]) {
        // Drop stale entries for this device from series index
        for key in seriesIndex.keys {
            seriesIndex[key]?.removeAll { $0.deviceId == deviceId }
        }
        seriesIndex = seriesIndex.filter { !$1.isEmpty }

        channelsByDevice[deviceId] = channels
        let nilCount   = channels.filter { $0.Guide == nil }.count
        let emptyCount = channels.filter { $0.Guide?.isEmpty == true }.count
        glog("[\(deviceId)] buildIndex: \(channels.count) channels — \(nilCount) Guide=nil, \(emptyCount) Guide=[]")

        for ch in channels {
            let key = "\(deviceId):\(ch.GuideNumber)"
            let sorted = (ch.Guide ?? []).sorted { $0.StartTime < $1.StartTime }
            channelEntryIndex[key] = sorted
            for entry in sorted {
                guard let sid = entry.SeriesID else { continue }
                seriesIndex[sid, default: []].append(
                    SeriesMatch(deviceId: deviceId, channelNum: ch.GuideNumber, entry: entry)
                )
            }
        }
        // Keep series index sorted so nextEpisode can do a linear scan and stop early
        for key in seriesIndex.keys {
            seriesIndex[key]?.sort { $0.entry.StartTime < $1.entry.StartTime }
        }
    }

    // MARK: - Queries

    /// All channels for a device.
    func channels(deviceId: String) -> [GuideChannel] {
        channelsByDevice[deviceId] ?? []
    }

    /// Guide entries for a device+channel whose EndTime is after `after` (default: now).
    func entries(deviceId: String, channelNum: String, after: Date = Date()) -> [GuideEntry] {
        let epoch = Int(after.timeIntervalSince1970)
        return (channelEntryIndex["\(deviceId):\(channelNum)"] ?? [])
            .filter { $0.EndTime > epoch }
    }

    /// First episode matching seriesID with StartTime > after, optionally constrained by
    /// channelNum (for SeriesID-channel shows) or deviceId.
    func nextEpisode(
        seriesID: String,
        channelNum: String? = nil,
        deviceId: String? = nil,
        after: Date = Date()
    ) -> SeriesMatch? {
        let epoch = Int(after.timeIntervalSince1970)
        return seriesIndex[seriesID]?.first { m in
            m.entry.StartTime > epoch
                && (channelNum == nil || m.channelNum == channelNum)
                && (deviceId == nil || m.deviceId == deviceId)
        }
    }

    /// Up to `limit` upcoming episodes matching seriesID with StartTime > after.
    /// The index is already sorted by StartTime so no additional sort is needed.
    func nextEpisodes(seriesID: String, after: Date = Date(), limit: Int = 4) -> [SeriesMatch] {
        let epoch = Int(after.timeIntervalSince1970)
        let all = seriesIndex[seriesID]?.filter { $0.entry.StartTime > epoch } ?? []
        // Same airing appears once per device when multiple tuners share a channel lineup;
        // keep only the first occurrence per (channel, StartTime) to avoid duplicate menu rows.
        var seen = Set<String>()
        let deduped = all.filter { seen.insert("\($0.channelNum):\($0.entry.StartTime)").inserted }
        return Array(deduped.prefix(limit))
    }

    /// Episode matching seriesID whose broadcast window spans `at` (StartTime ≤ at < EndTime).
    /// Used to detect a partially-airing episode so recording can be scheduled from the beginning.
    func currentEpisode(
        seriesID: String,
        channelNum: String? = nil,
        deviceId: String? = nil,
        at date: Date = Date()
    ) -> SeriesMatch? {
        let epoch = Int(date.timeIntervalSince1970)
        return seriesIndex[seriesID]?.first { m in
            m.entry.StartTime <= epoch && m.entry.EndTime > epoch
                && (channelNum == nil || m.channelNum == channelNum)
                && (deviceId == nil || m.deviceId == deviceId)
        }
    }

    /// Currently-airing entry matching `title` on a specific channel, regardless of SeriesID.
    /// Fallback for when the guide omits SeriesID from some airings of a series.
    func currentEntryByTitle(_ title: String, channelNum: String, deviceId: String, at date: Date = Date()) -> SeriesMatch? {
        let epoch = Int(date.timeIntervalSince1970)
        guard let entry = channelEntryIndex["\(deviceId):\(channelNum)"]?.first(where: {
            $0.StartTime <= epoch && $0.EndTime > epoch && $0.Title == title
        }) else { return nil }
        return SeriesMatch(deviceId: deviceId, channelNum: channelNum, entry: entry)
    }

    /// Next entry with StartTime > after matching `title` on a specific channel, regardless of SeriesID.
    /// Fallback for when the guide omits SeriesID from some airings of a series.
    func nextEntryByTitle(_ title: String, channelNum: String, deviceId: String, after: Date = Date()) -> SeriesMatch? {
        let epoch = Int(after.timeIntervalSince1970)
        guard let entry = channelEntryIndex["\(deviceId):\(channelNum)"]?.first(where: {
            $0.StartTime > epoch && $0.Title == title
        }) else { return nil }
        return SeriesMatch(deviceId: deviceId, channelNum: channelNum, entry: entry)
    }

    // MARK: - State queries

    func isLoading(deviceId: String) -> Bool { loadingDevices.contains(deviceId) }

    /// True if guide data for this device was loaded within `interval` seconds (default: 1 hour).
    func isFresh(deviceId: String, within interval: TimeInterval = 3600) -> Bool {
        guard let ts = loadTimestamps[deviceId] else { return false }
        return Date().timeIntervalSince(ts) < interval
    }

    // MARK: - Invalidation

    func invalidate(deviceId: String) {
        channelsByDevice.removeValue(forKey: deviceId)
        channelEntryIndex = channelEntryIndex.filter { !$0.key.hasPrefix("\(deviceId):") }
        for key in seriesIndex.keys {
            seriesIndex[key]?.removeAll { $0.deviceId == deviceId }
        }
        seriesIndex = seriesIndex.filter { !$1.isEmpty }
        loadTimestamps.removeValue(forKey: deviceId)
        glog("[\(deviceId)] cache invalidated")
    }

    func invalidateAll() {
        channelsByDevice = [:]
        channelEntryIndex = [:]
        seriesIndex = [:]
        loadTimestamps = [:]
        glog("All guide caches invalidated")
    }

}
