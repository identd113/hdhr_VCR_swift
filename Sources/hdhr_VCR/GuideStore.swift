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

    // Injected at init so tests can supply a mock session
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
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
        return URL(string: "http://\(device.LocalIP)/guide.json?Duration=\(durationSecs)")
    }

    // MARK: - Loading

    /// Fetch and index guide for one device. No-op if already loading.
    func load(for device: HDHRDevice, hours: Int = 12) async {
        let id = device.DeviceID
        guard !loadingDevices.contains(id) else {
            log("[\(id)] already loading — skipped")
            return
        }
        guard let url = Self.guideURL(for: device, hours: hours) else {
            print("[GuideStore] [\(id)] could not build guide URL — DeviceAuth: \(device.DeviceAuth != nil ? "yes" : "nil"), LocalIP: '\(device.LocalIP)'")
            return
        }

        loadingDevices.insert(id)
        defer { loadingDevices.remove(id) }

        log("[\(id)] GET \(url.absoluteString)")
        let t0 = Date()
        do {
            let (data, response) = try await session.data(from: url)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            log("[\(id)] \(data.count) bytes, HTTP \(status), \(ms)ms")

            let channels = try JSONDecoder().decode([GuideChannel].self, from: data)
            let entryCount = channels.reduce(0) { $0 + ($1.Guide?.count ?? 0) }
            log("[\(id)] \(channels.count) channels, \(entryCount) total entries")

            buildIndex(deviceId: id, channels: channels)
            loadTimestamps[id] = Date()
        } catch {
            // Always print fetch errors so failures are visible without verbose mode
            print("[GuideStore] [\(id)] fetch error: \(error.localizedDescription)")
            log("[\(id)] fetch error: \(error.localizedDescription)")
        }
    }

    /// Fetch guide for all devices in parallel.
    func loadAll(devices: [HDHRDevice], hours: Int = 12) async {
        guard !devices.isEmpty else { return }
        log("Starting guide load for \(devices.count) device(s), hours=\(hours)")
        await withTaskGroup(of: Void.self) { group in
            for device in devices {
                group.addTask { await self.load(for: device, hours: hours) }
            }
        }
        log("Guide load complete — \(channelsByDevice.values.reduce(0) { $0 + $1.count }) total channels across \(channelsByDevice.count) device(s)")
    }

    // MARK: - Indexing

    private func buildIndex(deviceId: String, channels: [GuideChannel]) {
        // Drop stale entries for this device from series index
        for key in seriesIndex.keys {
            seriesIndex[key]?.removeAll { $0.deviceId == deviceId }
        }
        seriesIndex = seriesIndex.filter { !$1.isEmpty }

        channelsByDevice[deviceId] = channels

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
        log("[\(deviceId)] cache invalidated")
    }

    func invalidateAll() {
        channelsByDevice = [:]
        channelEntryIndex = [:]
        seriesIndex = [:]
        loadTimestamps = [:]
        log("All guide caches invalidated")
    }

    // MARK: - Logging

    private func log(_ msg: String) {
        guard verbose else { return }
        let ts = ISO8601DateFormatter().string(from: Date())
        print("[GuideStore \(ts)] \(msg)")
    }
}
