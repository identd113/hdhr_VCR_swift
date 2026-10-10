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
    /// Bumped by invalidateAll() — lets fetchAndIndex detect that an in-flight fetch it started
    /// before the invalidation was requested is now stale, and should not resurrect old data after
    /// the fact. See invalidateAll()'s own doc comment.
    private var invalidationEpoch = 0

    // Injected at init so tests can supply a mock session
    private let session: URLSession
    /// Where the last successful fetch of each device's guide is kept (raw response body). nil =
    /// disk cache disabled (tests, and any GuideStore built without it).
    private let diskCacheDir: URL?
    /// How old a cached guide may be and still stand in for a network fetch on a startup/on-demand load.
    static let startupCacheMaxAge: TimeInterval = 3600

    init(session: URLSession = .shared, diskCacheDir: URL? = nil) {
        self.session = session
        self.diskCacheDir = diskCacheDir
        if let diskCacheDir { try? FileManager.default.createDirectory(at: diskCacheDir, withIntermediateDirectories: true) }
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

    // One in-flight load per device. A second caller (scheduleNextAir's stale-guide reload racing the
    // periodic refreshGuides, say) JOINS it and gets its real result, rather than being told `false`
    // — which every caller read as a failed fetch (60 s backoff + a "Guide Load Failed" notification /
    // Discord card for a guide that in fact loaded fine). 2026-10-05 triage T06.
    private var inFlightLoads: [String: Task<Bool, Never>] = [:]

    /// Fetch and index guide for one device. If a load for this device is already running, waits for it
    /// and returns ITS result instead of starting another (or failing).
    /// Pass useXML: true to use the XMLTV endpoint; devices without DeviceAuth fall back to JSON.
    /// Returns true if channels were successfully loaded, false on any error.
    @discardableResult
    func load(for device: HDHRDevice, hours: Int = 12, useXML: Bool = false, maxCacheAge: TimeInterval? = nil) async -> Bool {
        let id = device.DeviceID
        if let existing = inFlightLoads[id] {
            glog("[\(id)] guide load already in flight — waiting for it instead of starting another")
            return await existing.value
        }
        let task = Task { await self.loadNow(for: device, hours: hours, useXML: useXML, maxCacheAge: maxCacheAge) }
        inFlightLoads[id] = task
        // Remove only our own entry: invalidateAll() clears the table and a newer load may have
        // registered under the same id while this (stale) one was still finishing.
        defer { if inFlightLoads[id] == task { inFlightLoads.removeValue(forKey: id) } }
        return await task.value
    }

    @discardableResult
    private func loadNow(for device: HDHRDevice, hours: Int, useXML: Bool, maxCacheAge: TimeInterval?) async -> Bool {
        // XMLTV is cloud-only; devices without DeviceAuth fall through to JSON path
        if useXML, device.DeviceAuth != nil {
            return await loadXMLTV(for: device, hours: hours, maxCacheAge: maxCacheAge)
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

        return await fetchAndIndex(id: id, url: url, cacheFile: cacheFile(id: id, kind: "json", hours: hours), maxCacheAge: maxCacheAge) { data in
            let channels: [GuideChannel]
            do {
                channels = try JSONDecoder().decode([GuideChannel].self, from: data)
            } catch {
                glog("[\(id)] PARSE ERROR: \(error)", level: .error)
                if let full = String(data: data.prefix(2000), encoding: .utf8) {
                    glog("[\(id)] raw response (2000 chars): \(full)", level: .error)
                }
                return nil
            }

            // A 200 with zero channels (expired/rotated DeviceAuth, cloud hiccup) must not replace a
            // good guide with an empty one and count as fresh — fail so the old data is kept.
            if channels.isEmpty {
                glog("[\(id)] ERROR: guide response decoded to 0 channels — keeping previous data", level: .error)
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
    private func loadXMLTV(for device: HDHRDevice, hours: Int, maxCacheAge: TimeInterval?) async -> Bool {
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

        return await fetchAndIndex(id: id, url: url, cacheFile: cacheFile(id: id, kind: "xml", hours: hours), maxCacheAge: maxCacheAge) { data in
            let (channels, parsedOK) = XmltvParser().parse(data)
            guard parsedOK else {
                glog("[\(id)] ERROR: XMLTV parse failed/truncated — discarding partial result", level: .error)
                return nil
            }
            if channels.isEmpty {
                glog("[\(id)] ERROR: XMLTV response had 0 channels — keeping previous data", level: .error)
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
    private func fetchAndIndex(id: String, url: URL, cacheFile: URL? = nil, maxCacheAge: TimeInterval? = nil,
                               parse: @escaping @Sendable (Data) -> [GuideChannel]?) async -> Bool {
        loadingDevices.insert(id)
        // Captured before the network+decode await below — see the epochAtStart guard right
        // before applyIndex for why.
        let epochAtStart = invalidationEpoch
        // After an invalidateAll() the loading set was already cleared and a newer load may own
        // this id — only the load from the current epoch may release it.
        defer { if invalidationEpoch == epochAtStart { loadingDevices.remove(id) } }

        // Public guide API: reuse a recent on-disk copy instead of calling it again (relaunches /
        // deploys). The file is only trusted when it parses and still covers the present — otherwise
        // fall through to the normal network fetch below.
        if let cacheFile, let maxCacheAge {
            if await applyDiskCache(id: id, file: cacheFile, maxAge: maxCacheAge, epochAtStart: epochAtStart, parse: parse) != nil {
                return true
            }
            glog("[\(id)] disk-cached guide unusable (parse failed or no longer covers now) — fetching from network")
        }

        // The network fetch below can fail for reasons outside this app (2026-10-09: SiliconDust's
        // *.hdhomerun.com certificate expired, so every guide.php call failed TLS). A device with no
        // guide in memory — a relaunch, a deploy — would then sit with an empty guide, and every
        // guide-confirmed series recording would be skipped ("guide no longer confirms"). So on any
        // failure below, a device that has nothing loaded falls back to the newest on-disk copy that
        // still covers the present, however old (up to `staleFallbackMaxAge`). The failure is still
        // reported (return false → the usual retry cadence continues), and loadTimestamps keeps the
        // file's own age so isFresh stays false. A guide already in memory is never replaced by an
        // older disk copy.
        func failed(_ why: LoadFailure) async -> Bool {
            lastFailure[id] = why
            if (channelsByDevice[id] ?? []).isEmpty, let cacheFile,
               let modified = await applyDiskCache(id: id, file: cacheFile, maxAge: Self.staleFallbackMaxAge,
                                                   epochAtStart: epochAtStart, parse: parse) {
                glog("[\(id)] guide refresh failed — using the on-disk copy from \(Int(Date().timeIntervalSince(modified) / 60)) min ago until it succeeds", level: .warning)
            }
            return false
        }

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
                return await failed(.http(status))
            }

            guard !data.isEmpty else {
                glog("[\(id)] ERROR: empty response body", level: .error)
                return await failed(.badResponse)
            }

            // JSON/XMLTV decode + per-channel sort scale with GuideHours/lineup size (~1.4MB,
            // ~2500 entries per device isn't unusual) — run off the main actor so a big guide
            // fetch (this runs periodically per device — cadence configurable, ~3h by default) doesn't block WebServer requests or the UI for
            // the duration of the parse. Only the final dictionary merge (applyIndex) needs
            // MainActor, since it reads/mutates existing instance state.
            guard let prepared = await Task.detached(priority: .utility, operation: { () -> PreparedIndex? in
                guard let channels = parse(data) else { return nil }
                return Self.prepareIndex(deviceId: id, channels: channels)
            }).value else { return await failed(.badResponse) }

            // A call to invalidateAll() while the fetch/decode above was suspended means this
            // result is now stale — a fresh, correct reload for this device may have already
            // started or completed in response to whatever triggered the invalidation (e.g. a
            // Guide_use_xml/network-interface Settings change). Applying it anyway would silently
            // resurrect old (possibly wrong-format) data with a fresh loadTimestamps entry, making
            // isFresh() report the corrupted data as good for up to the next refresh interval —
            // found in code review 2026-09-28, no live report yet.
            guard invalidationEpoch == epochAtStart else {
                glog("[\(id)] guide cache was invalidated while this fetch was in flight — discarding stale result", level: .warning)
                return false
            }

            applyIndex(prepared)
            loadTimestamps[id] = Date()
            lastFailure.removeValue(forKey: id)
            if let cacheFile { Self.writeCache(data, to: cacheFile); pruneDiskCache() }
            glog("[\(id)] index built and timestamp set — guide ready")
            return true

        } catch {
            glog("[\(id)] NETWORK ERROR: \(error)", level: .error)
            return await failed(Self.classify(error))
        }
    }

    /// Why a device's last guide fetch failed — lets the caller say something useful instead of a
    /// generic "API error" (a certificate problem is on the guide server's side, not the user's).
    enum LoadFailure: Equatable {
        case certificate(String)   // TLS/certificate trouble reaching the guide service (the reason, user-readable)
        case network(String)       // anything else that kept the request from completing
        case http(Int)             // the service answered, but not with 200
        case badResponse           // empty or undecodable body
    }

    /// The most recent failure per device; cleared when a network fetch for it succeeds.
    private(set) var lastFailure: [String: LoadFailure] = [:]

    /// True while a device has no guide in memory, or its last fetch failed (so what it has may be a
    /// saved copy from before an outage). Drives the quick, backed-off retry in AppState — without the
    /// second half, a guide restored from disk by the failure fallback would never be retried until
    /// the next periodic refresh, hours away.
    func needsRecovery(deviceId: String) -> Bool {
        channels(deviceId: deviceId).isEmpty || lastFailure[deviceId] != nil
    }

    /// 2026-10-09: SiliconDust's *.hdhomerun.com certificate expired and every guide call failed with
    /// NSURLErrorSecureConnectionFailed (-1200) carrying a peer-trust error — a generic "API error"
    /// hid that completely.
    nonisolated static func classify(_ error: Error) -> LoadFailure {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return .network(ns.localizedDescription) }
        switch ns.code {
        case URLError.Code.serverCertificateHasBadDate.rawValue, URLError.Code.serverCertificateNotYetValid.rawValue:
            return .certificate("its certificate has expired or isn't valid yet")
        case URLError.Code.serverCertificateUntrusted.rawValue, URLError.Code.serverCertificateHasUnknownRoot.rawValue:
            return .certificate("its certificate isn't trusted")
        case URLError.Code.secureConnectionFailed.rawValue:
            return .certificate("a TLS error — usually an expired or untrusted certificate")
        default:
            return .network(ns.localizedDescription)
        }
    }

    /// How old an on-disk guide may be when it's used only because the network fetch failed. A guide
    /// covers ~GuideHours (≤ 28) from when it was fetched, and the coverage check below still has to
    /// pass, so this mainly bounds how stale "what's on" can be after a long outage.
    nonisolated static let staleFallbackMaxAge: TimeInterval = 36 * 3600

    /// Parses `file` and, if it decodes and still covers the present, applies it. Returns the file's
    /// modification date when applied, nil otherwise (missing/too old/unparseable/stale epoch).
    private func applyDiskCache(id: String, file: URL, maxAge: TimeInterval, epochAtStart: Int,
                                parse: @escaping @Sendable (Data) -> [GuideChannel]?) async -> Date? {
        guard let cached = Self.readFreshCache(file, maxAge: maxAge) else { return nil }
        let nowEpoch = Int(Date().timeIntervalSince1970)
        guard let prepared = await Task.detached(priority: .utility, operation: { () -> PreparedIndex? in
            guard let channels = parse(cached.data) else { return nil }
            return Self.prepareIndex(deviceId: id, channels: channels)
        }).value,
              prepared.channelEntryIndex.values.contains(where: { $0.contains { $0.EndTime > nowEpoch } }),
              invalidationEpoch == epochAtStart else { return nil }
        applyIndex(prepared)
        loadTimestamps[id] = cached.modified
        glog("[\(id)] guide loaded from disk cache (\(Int(Date().timeIntervalSince(cached.modified)))s old, \(cached.data.count) bytes)")
        return cached.modified
    }

    // MARK: - On-disk guide cache

    /// One file per device + format + window length — a GuideHours or XMLTV/JSON setting change
    /// never reuses a differently-shaped response. nil when the disk cache is disabled.
    private func cacheFile(id: String, kind: String, hours: Int) -> URL? {
        diskCacheDir?.appendingPathComponent("\(id.safeFileComponent)-\(kind)-\(hours)h.guide")
    }

    nonisolated private static func readFreshCache(_ file: URL, maxAge: TimeInterval) -> (data: Data, modified: Date)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let modified = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < maxAge,
              let data = try? Data(contentsOf: file), !data.isEmpty else { return nil }
        return (data, modified)
    }

    nonisolated private static func writeCache(_ data: Data, to file: URL) {
        do { try data.write(to: file, options: .atomic) }
        catch { glog("[GuideCache] could not write \(file.lastPathComponent): \(error.localizedDescription)", level: .warning) }
    }

    /// Drops saved guides too old for the 36 h restore window (a changed GuideHours/XML setting or a
    /// departed device otherwise leaves a ~1.4 MB file behind forever). Off the main actor; no-op when the
    /// disk cache is disabled. Called at launch and after each successful write.
    func pruneDiskCache() {
        guard let dir = diskCacheDir else { return }
        Task.detached(priority: .utility) {
            CachePruner.logSummary("guide cache", CachePruner.pruneGuideCache(in: dir))
        }
    }

    /// Fetch guide for all devices in parallel. Returns per-device success map.
    @discardableResult
    func loadAll(devices: [HDHRDevice], hours: Int = 12, useXML: Bool = false, maxCacheAge: TimeInterval? = nil) async -> [String: Bool] {
        guard !devices.isEmpty else {
            glog("loadAll called with 0 devices — nothing to do")
            return [:]
        }
        glog("loadAll: \(devices.count) device(s), hours=\(hours)")
        var results: [String: Bool] = [:]
        await withTaskGroup(of: (String, Bool).self) { group in
            for device in devices {
                group.addTask { (device.DeviceID, await self.load(for: device, hours: hours, useXML: useXML, maxCacheAge: maxCacheAge)) }
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
    //
    // Split into prepareIndex (pure, off-actor-safe — the CPU-heavy sort) + applyIndex (the
    // MainActor merge into existing instance state) so fetchAndIndex can run the heavy part in
    // Task.detached; buildIndex itself just chains them synchronously for callers (tests) that
    // want the old all-at-once behavior.
    func buildIndex(deviceId: String, channels: [GuideChannel]) {
        applyIndex(Self.prepareIndex(deviceId: deviceId, channels: channels))
    }

    // A device's fetch result, pre-sorted and pre-indexed but not yet merged into GuideStore's
    // instance dictionaries. Plain Sendable data so it can cross the actor boundary from
    // Task.detached back to applyIndex.
    private struct PreparedIndex {
        let deviceId: String
        let sortedChannels: [GuideChannel]
        let channelEntryIndex: [String: [GuideEntry]]  // this device's channels only
        let seriesEntries: [String: [SeriesMatch]]      // seriesID → matches, this device only
    }

    // Sort each channel's Guide and build this device's slice of the two indexes. No access to
    // GuideStore's instance state — safe to run off the main actor.
    nonisolated private static func prepareIndex(deviceId: String, channels: [GuideChannel]) -> PreparedIndex {
        var sortedChannels = channels
        var channelEntryIndex: [String: [GuideEntry]] = [:]
        var seriesEntries: [String: [SeriesMatch]] = [:]
        for i in sortedChannels.indices {
            let key = "\(deviceId):\(sortedChannels[i].GuideNumber)"
            guard let guide = sortedChannels[i].Guide else {
                channelEntryIndex[key] = []
                continue
            }
            let chNum  = sortedChannels[i].GuideNumber
            var sorted = guide.sorted { $0.StartTime < $1.StartTime }
            sorted = sorted.map { entry in
                var e = entry; e.deviceId = deviceId; e.channelNum = chNum
                e.cachedSeriesTitle = Show.seriesTitle(from: e.Title); return e
            }
            sortedChannels[i].Guide = sorted
            channelEntryIndex[key]  = sorted
            for entry in sorted {
                guard let sid = entry.SeriesID else { continue }
                seriesEntries[sid, default: []].append(
                    SeriesMatch(deviceId: deviceId, channelNum: chNum, entry: entry)
                )
            }
        }
        return PreparedIndex(deviceId: deviceId, sortedChannels: sortedChannels,
                              channelEntryIndex: channelEntryIndex, seriesEntries: seriesEntries)
    }

    // Merges a prepared device fetch into the shared indexes. Cheap (dictionary inserts over
    // this device's own entries) compared to the sort/decode that already happened — fine to run
    // on the main actor.
    private func applyIndex(_ prepared: PreparedIndex) {
        let deviceId = prepared.deviceId

        // Drop stale entries for this device from series index
        for key in seriesIndex.keys {
            seriesIndex[key]?.removeAll { $0.deviceId == deviceId }
        }
        seriesIndex = seriesIndex.filter { !$1.isEmpty }

        // Drop this device's channelEntryIndex keys for channels no longer in the fresh fetch —
        // same idea as the seriesIndex prune above. Without this, a channel dropped from a
        // device's lineup between fetches left its old "device:channel" entry lingering with
        // stale data instead of being cleared, for up to the last fetch's GuideHours window.
        let freshChannelNumbers = Set(prepared.sortedChannels.map(\.GuideNumber))
        let devicePrefix = "\(deviceId):"
        for key in channelEntryIndex.keys where key.hasPrefix(devicePrefix) {
            let channelNum = String(key.dropFirst(devicePrefix.count))
            if !freshChannelNumbers.contains(channelNum) {
                channelEntryIndex.removeValue(forKey: key)
            }
        }

        glog("[\(deviceId)] buildIndex: \(prepared.sortedChannels.count) channels")

        for (key, entries) in prepared.channelEntryIndex {
            channelEntryIndex[key] = entries
        }
        for (sid, matches) in prepared.seriesEntries {
            seriesIndex[sid, default: []].append(contentsOf: matches)
            unsortedSeries.insert(sid)
        }
        channelsByDevice[deviceId] = prepared.sortedChannels
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

    /// Up to `limit` upcoming episodes matching seriesID with StartTime > after, optionally
    /// constrained by channelNum/deviceId (same filter contract as `nextEpisode`/`currentEpisode`)
    /// — pass both nil to intentionally span every device/channel carrying this SeriesID (the
    /// "Other Upcoming Airings" preview's own use case).
    /// The index is already sorted by StartTime so no additional sort is needed.
    func nextEpisodes(seriesID: String, channelNum: String? = nil, deviceId: String? = nil, after: Date = Date(), limit: Int = 4) -> [SeriesMatch] {
        sortIfNeeded(seriesID)
        let epoch = Int(after.timeIntervalSince1970)
        let all = seriesIndex[seriesID]?.filter { m in
            m.entry.StartTime > epoch
                && (channelNum == nil || m.channelNum == channelNum)
                && (deviceId == nil || m.deviceId == deviceId)
        } ?? []
        // Same airing appears once per device when multiple tuners share a channel lineup;
        // keep only the first occurrence per (channel, StartTime) to avoid duplicate menu rows.
        // Only matters for the unfiltered (deviceId == nil) cross-device case above — a
        // device-scoped call can't have more than one match per (channel, StartTime) anyway.
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
        if let isNotRecorded {
            let unrecorded = candidates.filter { isNotRecorded($0.entry) }
            // Every currently-airing candidate — including the single-candidate case, where
            // there's nothing to tie-break against — is already a recorded duplicate. Unlike
            // nextEpisode's future candidates (whose duplicate status can still change before they
            // actually air, so picking `first` there just defers the real check to record time),
            // this is a stable fact known right now: scheduleNextAir calls this again immediately
            // after startRecording's duplicate skip, so returning `first` here would re-select this
            // exact on-air duplicate every ~10s for the rest of its broadcast window instead of
            // falling through to nextEpisode to find the actual next distinct airing.
            if unrecorded.isEmpty { return nil }
            // 2+ unrecorded candidates (a 3-or-more-way simulcast with a mixed recorded/unrecorded
            // split): the favorite tie-break below must run over `unrecorded`, not `candidates` —
            // both real callers (resolveSeriesAir, scheduleNextAir) always pass a non-nil
            // preferFavorite, so falling back to plain `first` here could silently hand back the
            // recorded duplicate (if it sorts first and nothing is favorited), reintroducing the
            // exact re-pick loop this whole check exists to prevent.
            guard let isFavorite else { return unrecorded[0] }
            return unrecorded.first { isFavorite($0.deviceId, $0.channelNum) } ?? unrecorded[0]
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
    ///
    /// Pass `preferFavorite`/`preferUnrecorded` to break a multi-channel-simulcast tie the same
    /// way `currentEpisode`/`nextEpisode` do — without them, the no-channelNum scan below still
    /// resolves ties deterministically (via `titleFallbackScanKeys`'s lineup order), just not
    /// toward a favorited/unrecorded channel specifically.
    func currentEntryByTitle(
        _ title: String, channelNum: String? = nil, deviceId: String? = nil, at date: Date = Date(),
        preferUnrecorded isNotRecorded: ((_ entry: GuideEntry) -> Bool)? = nil,
        preferFavorite isFavorite: ((_ deviceId: String, _ channelNum: String) -> Bool)? = nil
    ) -> SeriesMatch? {
        let epoch = Int(date.timeIntervalSince1970)
        if let channelNum, let deviceId {
            let candidates = (channelEntryIndex["\(deviceId):\(channelNum)"] ?? []).filter {
                $0.StartTime <= epoch && $0.EndTime > epoch && $0.seriesTitle == title
            }
            guard !candidates.isEmpty else { return nil }
            // Same reasoning as currentEpisode's own single-candidate check (see its comment) —
            // a currently-airing duplicate on the one channel a seriesChannel show is pinned to is
            // a stable fact right now, not a tie to break: scheduleNextAir calls this again
            // immediately after startRecording's duplicate skip, so returning it unconditionally
            // (as this single-channel fast path used to, unlike the multi-channel scan below,
            // which already applied this filter) would re-select the exact same on-air duplicate
            // every ~10s for the rest of its broadcast window instead of falling through to
            // nextEntryByTitle to find the actual next distinct airing. Caught live 2026-08-24 —
            // see ISSUES.md.
            if let isNotRecorded {
                guard let entry = candidates.first(where: isNotRecorded) else { return nil }
                return SeriesMatch(deviceId: deviceId, channelNum: channelNum, entry: entry)
            }
            return SeriesMatch(deviceId: deviceId, channelNum: channelNum, entry: candidates[0])
        }
        // Explicit types + steps (not one flatMap→filter chain): the older Swift toolchain on the laptop could not
        // type-check the chained form in reasonable time ("unable to type-check this expression").
        let scanned: [GuideEntry] = titleFallbackScanKeys(deviceId: deviceId).flatMap { (key: String) -> [GuideEntry] in
            channelEntryIndex[key] ?? []
        }
        let candidates: [GuideEntry] = scanned.filter { (e: GuideEntry) -> Bool in
            guard e.StartTime <= epoch, e.EndTime > epoch, e.seriesTitle == title else { return false }
            return channelNum == nil || e.channelNum == channelNum
        }
        guard let first = candidates.first else { return nil }
        // Same reasoning as currentEpisode: every candidate here is airing right now, so there's
        // no StartTime-tied subset to narrow to first — preferUnrecorded/preferFavorite apply
        // across all of `candidates` directly.
        if let isNotRecorded {
            let unrecorded = candidates.filter { isNotRecorded($0) }
            if unrecorded.isEmpty { return nil }
            guard let isFavorite else {
                let e = unrecorded[0]; return SeriesMatch(deviceId: e.deviceId, channelNum: e.channelNum, entry: e)
            }
            let e = unrecorded.first { isFavorite($0.deviceId, $0.channelNum) } ?? unrecorded[0]
            return SeriesMatch(deviceId: e.deviceId, channelNum: e.channelNum, entry: e)
        }
        guard let isFavorite else {
            return SeriesMatch(deviceId: first.deviceId, channelNum: first.channelNum, entry: first)
        }
        let e = candidates.first { isFavorite($0.deviceId, $0.channelNum) } ?? first
        return SeriesMatch(deviceId: e.deviceId, channelNum: e.channelNum, entry: e)
    }

    /// Next entry with StartTime > after matching `title`, regardless of SeriesID. Fallback for
    /// when the guide omits SeriesID from some airings of a series — see `currentEntryByTitle`'s
    /// doc comment for why `entry.Title` is stripped before comparing, why the filters are
    /// independently optional, and what `preferFavorite`/`preferUnrecorded` do.
    func nextEntryByTitle(
        _ title: String, channelNum: String? = nil, deviceId: String? = nil, after: Date = Date(),
        preferUnrecorded isNotRecorded: ((_ entry: GuideEntry) -> Bool)? = nil,
        preferFavorite isFavorite: ((_ deviceId: String, _ channelNum: String) -> Bool)? = nil
    ) -> SeriesMatch? {
        let epoch = Int(after.timeIntervalSince1970)
        if let channelNum, let deviceId {
            guard let entry = channelEntryIndex["\(deviceId):\(channelNum)"]?.first(where: {
                $0.StartTime > epoch && $0.seriesTitle == title
            }) else { return nil }
            return SeriesMatch(deviceId: deviceId, channelNum: channelNum, entry: entry)
        }
        // titleFallbackScanKeys gives a fixed lineup order (not channelEntryIndex's arbitrary
        // dictionary order), so picking the *first* minimal-StartTime candidate below resolves a
        // multi-channel StartTime tie (e.g. a simulcast) the same way on every call instead of
        // flipping across guide rebuilds — min(by:) returns the first-encountered minimum on a
        // tie, matching what the old full sort + prefix(while:) produced, in one O(n) pass instead
        // of an O(n log n) sort + materialize.
        let scanned: [GuideEntry] = titleFallbackScanKeys(deviceId: deviceId).flatMap { (key: String) -> [GuideEntry] in
            channelEntryIndex[key] ?? []
        }
        let candidates: [GuideEntry] = scanned.filter { (e: GuideEntry) -> Bool in
            guard e.StartTime > epoch, e.seriesTitle == title else { return false }
            return channelNum == nil || e.channelNum == channelNum
        }
        guard let first = candidates.min(by: { $0.StartTime < $1.StartTime }) else { return nil }
        guard isNotRecorded != nil || isFavorite != nil else {
            return SeriesMatch(deviceId: first.deviceId, channelNum: first.channelNum, entry: first)
        }
        // filter (order-preserving) over the unsorted candidates gives the same relative order as
        // the old sorted+prefix(while:) did for the tied subset.
        let tied = candidates.filter { $0.StartTime == first.StartTime }
        guard tied.count > 1 else {
            return SeriesMatch(deviceId: first.deviceId, channelNum: first.channelNum, entry: first)
        }
        if let isNotRecorded {
            let unrecorded = tied.filter { isNotRecorded($0) }
            if unrecorded.count == 1 {
                let e = unrecorded[0]; return SeriesMatch(deviceId: e.deviceId, channelNum: e.channelNum, entry: e)
            }
        }
        guard let isFavorite else {
            return SeriesMatch(deviceId: first.deviceId, channelNum: first.channelNum, entry: first)
        }
        let e = tied.first { isFavorite($0.deviceId, $0.channelNum) } ?? first
        return SeriesMatch(deviceId: e.deviceId, channelNum: e.channelNum, entry: e)
    }

    /// Deterministic channel scan order for the title-fallback functions above — lineup order
    /// (mirrors `buildIndex`'s own channel-iteration order, the same source of determinism
    /// `seriesIndex`'s stable sort relies on), never `channelEntryIndex`'s raw dictionary order,
    /// which is hash-based and can silently reorder across guide rebuilds.
    private func titleFallbackScanKeys(deviceId: String?) -> [String] {
        if let deviceId {
            return (channelsByDevice[deviceId] ?? []).map { "\(deviceId):\($0.GuideNumber)" }
        }
        return channelsByDevice.keys.sorted().flatMap { dev in
            (channelsByDevice[dev] ?? []).map { "\(dev):\($0.GuideNumber)" }
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

    func invalidateAll() {
        // Bumped first, before clearing anything else — any fetchAndIndex already in flight
        // captured the old epoch before its network+decode await and will discard its own result
        // instead of applying it after this invalidation, once it resumes. See fetchAndIndex's own
        // epochAtStart guard.
        invalidationEpoch += 1
        loadingDevices.removeAll()
        // A load() issued right after this must start fresh, not join a stale in-flight task that
        // will discard its own result (epoch mismatch) and report failure.
        inFlightLoads.removeAll()
        channelsByDevice = [:]
        channelEntryIndex = [:]
        seriesIndex = [:]
        unsortedSeries = []
        loadTimestamps = [:]
        glog("All guide caches invalidated")
    }

}
