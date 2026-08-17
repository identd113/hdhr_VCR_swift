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
    private var unsortedSeries: Set<String> = []                   // series needing sort on next query
    private var loadingDevices: Set<String> = []
    private var loadTimestamps: [String: Date] = [:]

    // Injected at init so tests can supply a mock session
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
        glog("=== GuideStore initialised ===")
    }

    /// Masks a DeviceAuth query-param value before it reaches any log line. DeviceAuth is a live
    /// bearer credential for the user's SiliconDust cloud account — logging it in the clear would
    /// hand it to anyone who tails/shares hdhrVCRplus.log (which the app's own troubleshooting flow
    /// explicitly asks users to do), and the log's ~2.5-week retention would accumulate every
    /// rotated token over time.
    nonisolated private static func redactingDeviceAuth(_ urlString: String) -> String {
        guard let range = urlString.range(of: "DeviceAuth=") else { return urlString }
        let valueStart = range.upperBound
        let valueEnd = urlString[valueStart...].firstIndex(of: "&") ?? urlString.endIndex
        return urlString.replacingCharacters(in: valueStart..<valueEnd, with: "REDACTED")
    }

    // MARK: - URL building

    /// Canonical guide URL for a device. Duration is in hours (the API accepts hours directly).
    /// - Cloud devices (has DeviceAuth): SiliconDust cloud API
    /// - Local devices: device's own /guide.json endpoint
    nonisolated static func guideURL(for device: HDHRDevice, hours: Int = 12) -> URL? {
        // Start 1 hour before now so displayStart's 60-90 min lookback always has data.
        // Duration +1 preserves the configured future window despite the earlier start.
        let start = Int(Date().timeIntervalSince1970) - 3600
        if let auth = device.DeviceAuth {
            return URL(string: "https://api.hdhomerun.com/api/guide.php?DeviceAuth=\(auth)&Start=\(start)&Duration=\(hours + 1)")
        }
        if device.LocalIP.isEmpty { return nil }
        return URL(string: "http://\(device.LocalIP)/guide.json?Start=\(start)&Duration=\(hours + 1)")
    }

    /// XMLTV cloud guide URL — no Start/Duration params; server determines the window.
    /// Returns nil if the device has no DeviceAuth (XMLTV is cloud-only).
    nonisolated static func xmltvURL(for device: HDHRDevice) -> URL? {
        guard let auth = device.DeviceAuth else { return nil }
        return URL(string: "https://api.hdhomerun.com/api/xmltv?DeviceAuth=\(auth)")
    }

    // MARK: - Loading

    /// Fetch and index guide for one device. No-op if already loading.
    /// Pass useXML: true to use the XMLTV endpoint; devices without DeviceAuth fall back to JSON.
    /// Returns true if channels were successfully loaded, false on any error.
    @discardableResult
    func load(for device: HDHRDevice, hours: Int = 12, useXML: Bool = false) async -> Bool {
        // XMLTV is cloud-only; devices without DeviceAuth fall through to JSON path
        if useXML, device.DeviceAuth != nil {
            return await loadXMLTV(for: device)
        }
        let id = device.DeviceID
        glog("[\(id)] load() called — DeviceAuth:\(device.DeviceAuth != nil ? "present" : "nil")  LocalIP:'\(device.LocalIP)'  hours:\(hours)")

        guard !loadingDevices.contains(id) else {
            glog("[\(id)] already loading — skipped")
            return false
        }
        guard let url = Self.guideURL(for: device, hours: hours) else {
            glog("[\(id)] ERROR: could not build guide URL — DeviceAuth:\(device.DeviceAuth != nil ? "present" : "nil")  LocalIP:'\(device.LocalIP)'", level: .error)
            return false
        }

        return await fetchAndIndex(id: id, url: url) { data in
            let channels: [GuideChannel]
            do {
                channels = try JSONDecoder().decode([GuideChannel].self, from: data)
            } catch {
                glog("[\(id)] PARSE ERROR: \(error)", level: .error)
                // Log more of the raw response on parse failure for diagnosis
                if let full = String(data: data.prefix(2000), encoding: .utf8) {
                    glog("[\(id)] raw response (2000 chars): \(full)", level: .error)
                }
                return nil
            }

            let entryCount = channels.reduce(0) { $0 + ($1.Guide?.count ?? 0) }
            glog("[\(id)] parsed \(channels.count) channels, \(entryCount) total guide entries")

            if entryCount == 0 {
                glog("[\(id)] WARNING: channels loaded but ALL have 0 guide entries — check GuideHours setting or API response", level: .warning)
            }
            return channels
        }
    }

    /// Fetch XMLTV guide for one device. No-op if already loading.
    /// Returns true if channels were successfully loaded, false on any error.
    @discardableResult
    private func loadXMLTV(for device: HDHRDevice) async -> Bool {
        let id = device.DeviceID
        glog("[\(id)] loadXMLTV() called — DeviceAuth:\(device.DeviceAuth != nil ? "present" : "nil")")

        guard !loadingDevices.contains(id) else {
            glog("[\(id)] already loading — skipped")
            return false
        }
        guard let url = Self.xmltvURL(for: device) else {
            glog("[\(id)] ERROR: could not build XMLTV URL — DeviceAuth missing", level: .error)
            return false
        }

        return await fetchAndIndex(id: id, url: url) { data in
            let (channels, parsedOK) = XmltvParser().parse(data)
            guard parsedOK else {
                glog("[\(id)] ERROR: XMLTV parse failed/truncated — discarding partial result", level: .error)
                return nil
            }
            let entryCount = channels.reduce(0) { $0 + ($1.Guide?.count ?? 0) }
            glog("[\(id)] XMLTV parsed \(channels.count) channels, \(entryCount) total guide entries")

            if entryCount == 0 {
                glog("[\(id)] WARNING: channels loaded but ALL have 0 guide entries", level: .warning)
            }
            return channels
        }
    }

    /// Shared fetch + parse + index scaffolding for `load()`/`loadXMLTV()` — GET, timing log,
    /// HTTP-status/empty-body guards, and post-parse indexing are identical between the two;
    /// only URL building and the parse step (via `parse`) differ. The "already loading"/URL-build
    /// guards stay in each caller (not here) so their exact glog lines/ordering are unaffected by
    /// this refactor. `parse` returns nil on failure — it owns its own failure logging, since the
    /// JSON and XMLTV parse-failure messages intentionally read differently.
    private func fetchAndIndex(id: String, url: URL, parse: (Data) -> [GuideChannel]?) async -> Bool {
        loadingDevices.insert(id)
        defer { loadingDevices.remove(id) }

        glog("[\(id)] GET \(Self.redactingDeviceAuth(url.absoluteString))")
        let t0 = Date()
        do {
            let (data, response) = try await session.data(from: url)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let levelHttp: LogLevel = status == 200 ? .info : .warning
            glog("[\(id)] HTTP \(status)  \(data.count) bytes  \(ms)ms", level: levelHttp)

            guard status == 200 else {
                glog("[\(id)] ERROR: non-200 status, aborting parse", level: .error)
                return false
            }

            guard !data.isEmpty else {
                glog("[\(id)] ERROR: empty response body", level: .error)
                return false
            }

            guard let channels = parse(data) else { return false }

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
    func loadAll(devices: [HDHRDevice], hours: Int = 12, useXML: Bool = false) async -> [String: Bool] {
        guard !devices.isEmpty else {
            glog("loadAll called with 0 devices — nothing to do")
            return [:]
        }
        glog("loadAll: \(devices.count) device(s), hours=\(hours)")
        var results: [String: Bool] = [:]
        await withTaskGroup(of: (String, Bool).self) { group in
            for device in devices {
                group.addTask { (device.DeviceID, await self.load(for: device, hours: hours, useXML: useXML)) }
            }
            for await (id, ok) in group { results[id] = ok }
        }
        let total = channelsByDevice.values.reduce(0) { $0 + $1.count }
        glog("loadAll complete — \(total) total channels across \(channelsByDevice.count) device(s)")
        return results
    }

    // MARK: - Indexing

    // internal (not private) so tests can seed real on-air guide entries directly — needed to
    // exercise WatchNowView's ScrollView branch, which only appears once onAirNow() finds a
    // currently-airing entry. See SnapshotTests.swift's watchNowOnAir case.
    func buildIndex(deviceId: String, channels: [GuideChannel]) {
        // Drop stale entries for this device from series index
        for key in seriesIndex.keys {
            seriesIndex[key]?.removeAll { $0.deviceId == deviceId }
        }
        seriesIndex = seriesIndex.filter { !$1.isEmpty }

        glog("[\(deviceId)] buildIndex: \(channels.count) channels")

        // Sort each channel's Guide in-place so consumers read pre-sorted data.
        var sortedChannels = channels
        for i in sortedChannels.indices {
            let key    = "\(deviceId):\(sortedChannels[i].GuideNumber)"
            guard let guide = sortedChannels[i].Guide else {
                channelEntryIndex[key] = []
                continue
            }
            let chNum  = sortedChannels[i].GuideNumber
            var sorted = guide.sorted { $0.StartTime < $1.StartTime }
            sorted = sorted.map { entry in
                var e = entry; e.deviceId = deviceId; e.channelNum = chNum; return e
            }
            sortedChannels[i].Guide = sorted
            channelEntryIndex[key]  = sorted
            for entry in sorted {
                guard let sid = entry.SeriesID else { continue }
                seriesIndex[sid, default: []].append(
                    SeriesMatch(deviceId: deviceId, channelNum: sortedChannels[i].GuideNumber, entry: entry)
                )
                unsortedSeries.insert(sid)
            }
        }
        channelsByDevice[deviceId] = sortedChannels
        // Series sort is deferred to first query via sortIfNeeded(_:) — avoids
        // O(series × entries log entries) on the main actor at guide load time.
    }

    private func sortIfNeeded(_ seriesID: String) {
        guard unsortedSeries.contains(seriesID) else { return }
        seriesIndex[seriesID]?.sort { $0.entry.StartTime < $1.entry.StartTime }
        unsortedSeries.remove(seriesID)
    }

    // MARK: - Queries

    /// All channels for a device.
    func channels(deviceId: String) -> [GuideChannel] {
        channelsByDevice[deviceId] ?? []
    }

    /// Guide entries for a device+channel whose EndTime is after `after` (default: now).
    func entries(deviceId: String, channelNum: String, after: Date = Date()) -> [GuideEntry] {
        entries(key: "\(deviceId):\(channelNum)", after: after)
    }

    /// Pre-built key overload — avoids string allocation at call sites that already have the key.
    private func entries(key: String, after: Date = Date()) -> [GuideEntry] {
        let epoch = Int(after.timeIntervalSince1970)
        return (channelEntryIndex[key] ?? []).filter { $0.EndTime > epoch }
    }

    /// First episode matching seriesID with StartTime > after, optionally constrained by
    /// channelNum (for SeriesID-channel shows) or deviceId.
    ///
    /// When multiple channels air the identical next episode at the same StartTime (e.g. a
    /// SeriesID(All) show simulcast/rerun on several channels of one device), the tie would
    /// otherwise resolve to whichever channel happened to sort first (insertion order from the
    /// guide fetch, since the underlying sort is StartTime-only and stable) — not a deliberate
    /// choice. Pass `preferFavorite` to break that tie toward a favorited channel instead.
    func nextEpisode(
        seriesID: String,
        channelNum: String? = nil,
        deviceId: String? = nil,
        after: Date = Date(),
        preferUnrecorded isNotRecorded: ((_ entry: GuideEntry) -> Bool)? = nil,
        preferFavorite isFavorite: ((_ deviceId: String, _ channelNum: String) -> Bool)? = nil
    ) -> SeriesMatch? {
        sortIfNeeded(seriesID)
        let epoch = Int(after.timeIntervalSince1970)
        let candidates = seriesIndex[seriesID]?.filter { m in
            m.entry.StartTime > epoch
                && (channelNum == nil || m.channelNum == channelNum)
                && (deviceId == nil || m.deviceId == deviceId)
        } ?? []
        guard let first = candidates.first else { return nil }
        guard isNotRecorded != nil || isFavorite != nil else { return first }
        let tied = Array(candidates.prefix(while: { $0.entry.StartTime == first.entry.StartTime }))
        guard tied.count > 1 else { return first }
        // Prefer a candidate that isn't already recorded — checked before the favorite tie-break
        // below (an already-recorded duplicate loses even to a non-favorited channel). Only
        // decisive when it actually distinguishes the tied set: if every candidate is (or isn't)
        // already recorded, that carries no information and this falls through to favorite/first.
        if let isNotRecorded {
            let unrecorded = tied.filter { isNotRecorded($0.entry) }
            if unrecorded.count == 1 { return unrecorded[0] }
        }
        guard let isFavorite else { return first }
        return tied.first { isFavorite($0.deviceId, $0.channelNum) } ?? first
    }

    /// Up to `limit` upcoming episodes matching seriesID with StartTime > after.
    /// The index is already sorted by StartTime so no additional sort is needed.
    func nextEpisodes(seriesID: String, after: Date = Date(), limit: Int = 4) -> [SeriesMatch] {
        sortIfNeeded(seriesID)
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
    ///
    /// Pass `preferFavorite` to break a multi-channel-simulcast tie toward a favorited channel —
    /// see `nextEpisode(seriesID:channelNum:deviceId:after:preferUnrecorded:preferFavorite:)` for
    /// the rationale. `preferUnrecorded` (checked first, same reasoning as `nextEpisode`) applies
    /// across every currently-airing candidate here, not just a StartTime-tied subset — unlike
    /// `nextEpisode`, "currently airing" candidates are inherently concurrent regardless of when
    /// each individually started.
    func currentEpisode(
        seriesID: String,
        channelNum: String? = nil,
        deviceId: String? = nil,
        at date: Date = Date(),
        preferUnrecorded isNotRecorded: ((_ entry: GuideEntry) -> Bool)? = nil,
        preferFavorite isFavorite: ((_ deviceId: String, _ channelNum: String) -> Bool)? = nil
    ) -> SeriesMatch? {
        sortIfNeeded(seriesID)
        let epoch = Int(date.timeIntervalSince1970)
        let candidates = seriesIndex[seriesID]?.filter { m in
            m.entry.StartTime <= epoch && m.entry.EndTime > epoch
                && (channelNum == nil || m.channelNum == channelNum)
                && (deviceId == nil || m.deviceId == deviceId)
        } ?? []
        guard let first = candidates.first else { return nil }
        if let isNotRecorded, candidates.count > 1 {
            let unrecorded = candidates.filter { isNotRecorded($0.entry) }
            if unrecorded.count == 1 { return unrecorded[0] }
        }
        guard let isFavorite else { return first }
        return candidates.first { isFavorite($0.deviceId, $0.channelNum) } ?? first
    }

    /// Currently-airing entry matching `title`, regardless of SeriesID. Fallback for when the
    /// guide omits SeriesID from some airings of a series. `title` is the stored show_title,
    /// which — for a series show — has had any episode-specific suffix (e.g. " S24E116 Trey
    /// Parker…") stripped via `Show.seriesTitle(from:)` since it's meant to name the series, not
    /// one airing. A raw `entry.Title` for an individual airing missing SeriesID can still carry
    /// that suffix, so it's stripped the same way here before comparing — an exact
    /// `$0.Title == title` would otherwise never match a stripped stored title against a
    /// suffixed guide entry, silently breaking this fallback for exactly the shows it exists for.
    ///
    /// `channelNum`/`deviceId` default `nil` and are applied independently (like
    /// `currentEpisode`/`nextEpisode`) — needed for SeriesID(All) shows, which pass a fixed
    /// `deviceId` (their assigned tuner) but `nil` channelNum (any channel on that tuner) to
    /// `currentEpisode`/`nextEpisode` too (see `AppState.resolveSeriesAir`/`scheduleNextAir`); a
    /// version requiring both-or-neither would silently ignore deviceId for that case and scan
    /// every device instead of just the assigned one.
    func currentEntryByTitle(_ title: String, channelNum: String? = nil, deviceId: String? = nil, at date: Date = Date()) -> SeriesMatch? {
        let epoch = Int(date.timeIntervalSince1970)
        if let channelNum, let deviceId {
            guard let entry = channelEntryIndex["\(deviceId):\(channelNum)"]?.first(where: {
                $0.StartTime <= epoch && $0.EndTime > epoch && Show.seriesTitle(from: $0.Title) == title
            }) else { return nil }
            return SeriesMatch(deviceId: deviceId, channelNum: channelNum, entry: entry)
        }
        guard let entry = channelEntryIndex.values.flatMap({ $0 }).first(where: {
            $0.StartTime <= epoch && $0.EndTime > epoch && Show.seriesTitle(from: $0.Title) == title
                && (channelNum == nil || $0.channelNum == channelNum)
                && (deviceId == nil || $0.deviceId == deviceId)
        }) else { return nil }
        return SeriesMatch(deviceId: entry.deviceId, channelNum: entry.channelNum, entry: entry)
    }

    /// Next entry with StartTime > after matching `title`, regardless of SeriesID. Fallback for
    /// when the guide omits SeriesID from some airings of a series — see `currentEntryByTitle`'s
    /// doc comment for why `entry.Title` is stripped before comparing and why the filters are
    /// independently optional.
    func nextEntryByTitle(_ title: String, channelNum: String? = nil, deviceId: String? = nil, after: Date = Date()) -> SeriesMatch? {
        let epoch = Int(after.timeIntervalSince1970)
        if let channelNum, let deviceId {
            guard let entry = channelEntryIndex["\(deviceId):\(channelNum)"]?.first(where: {
                $0.StartTime > epoch && Show.seriesTitle(from: $0.Title) == title
            }) else { return nil }
            return SeriesMatch(deviceId: deviceId, channelNum: channelNum, entry: entry)
        }
        // Each per-device-channel list is itself sorted by StartTime, but concatenating them via
        // flatMap is not — dictionary iteration order is arbitrary, so picking .first here would
        // pick an arbitrary matching airing rather than the soonest one across all devices/channels.
        guard let entry = channelEntryIndex.values.flatMap({ $0 })
            .filter({ $0.StartTime > epoch && Show.seriesTitle(from: $0.Title) == title
                && (channelNum == nil || $0.channelNum == channelNum)
                && (deviceId == nil || $0.deviceId == deviceId) })
            .min(by: { $0.StartTime < $1.StartTime })
        else { return nil }
        return SeriesMatch(deviceId: entry.deviceId, channelNum: entry.channelNum, entry: entry)
    }

    // MARK: - State queries

    func isLoading(deviceId: String) -> Bool { loadingDevices.contains(deviceId) }

    /// True if guide data for this device was loaded within `interval` seconds (default: 1 hour).
    func isFresh(deviceId: String, within interval: TimeInterval = 3600) -> Bool {
        guard let ts = loadTimestamps[deviceId] else { return false }
        return Date().timeIntervalSince(ts) < interval
    }

    // MARK: - Invalidation

    func invalidateAll() {
        loadingDevices.removeAll()
        channelsByDevice = [:]
        channelEntryIndex = [:]
        seriesIndex = [:]
        unsortedSeries = []
        loadTimestamps = [:]
        glog("All guide caches invalidated")
    }

}
