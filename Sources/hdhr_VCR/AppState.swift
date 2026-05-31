import Foundation
import UserNotifications
import AppKit
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var shows: [Show] = []
    @Published var devices: [HDHRDevice] = []
    @Published var lineups: [String: [LineupEntry]] = [:]       // deviceId → channel lineup
    @Published var guideByDevice: [String: [GuideChannel]] = [:] {  // mirror of guideStore.channelsByDevice
        // Rebuild caches on guide load (infrequent). The 403 feedback loop is broken by
        // ensureGuideLoaded's success-only guard on guideByDevice assignment.
        didSet { rebuildMenuEntries() }
    }
    // Per-show guide entry for the scheduled menu label and info header — avoids O(series) scan per open.
    @Published var menuScheduledEntry: [String: GuideEntry] = [:]
    // Pre-computed upcoming slots for SeriesID shows — avoids O(series) nextEpisodes scan per open.
    @Published var menuUpcomingSlots: [String: [(channel: String, date: Date)]] = [:]
    // Pre-computed set of show IDs with scheduling conflicts — rebuilt alongside menu entries.
    var conflictingShowIDs: Set<String> = []
    // Tracks which show+episode windows have already fired a runtime conflict notification.
    // Key = "showID-show_next_epoch" so it auto-clears when show_next advances.
    private var conflictNotifiedKeys: Set<String> = []
    // O(1) managed-show lookup for entryMenu — rebuilt alongside menu entries.
    var managedShowBySeriesID: [String: Show] = [:]
    var managedShowByTitle:    [String: Show] = [:]
    // O(1) channel logo lookup for channelMenu — "deviceId:channelNum" → ImageURL — rebuilt alongside menu entries.
    var channelImageURLs: [String: String] = [:]
    @Published var guideRevision: Int = 0                        // increments each time guide data successfully loads
    @Published var config = AppConfig()
    @Published var statusMessage = "Starting…"
    @Published var notifyPermission = false
    private let notificationDelegate = NotificationActionDelegate()
    @Published var isStartingUp: Bool = true

    @Published var editingShowId: String? = nil
    @Published var watchNowDeviceId: String? = nil
    @Published var pendingAddEntry: (device: HDHRDevice, channel: LineupEntry, entry: GuideEntry)? = nil
    @Published var pendingAddEntryGeneration: Int = 0   // bumped each time a new entry is set; drives onChange in AddShowView
    @Published var pendingAddChannel: (device: HDHRDevice, channel: LineupEntry)? = nil
    @Published var pendingAddChannelGeneration: Int = 0  // bumped each time pendingAddChannel is set
    @Published var tunerStatus: [String: TunerStatus] = [:]         // showId → last polled vstatus
    @Published var deviceTunerOccupancy: [String: [DeviceTunerInfo]] = [:]  // deviceId → live status.json snapshot
    @Published var vlcCurrentURL: String = ""               // raw URL (no transcode query) playing in VLCPlayerView
    @Published var channelIconImages: [String: NSImage] = [:]  // ImageURL → NSImage; populated during prefetch for sync menu use

    // Tracks optimistically-toggled favorite state: [deviceId: [GuideNumber: expectedBool]]
    // Cleared per-device after the next lineup reload; mismatches are logged as warnings.
    private var pendingFavoriteToggles: [String: [String: Bool]] = [:]

    // True once at least one tuner is found with a populated lineup and guide data.
    // Drives the status icon opacity — stays dimmed until the app is genuinely usable.
    var isReady: Bool {
        !devices.isEmpty &&
        lineups.values.contains { !$0.isEmpty } &&
        guideByDevice.values.contains { !$0.isEmpty }
    }
    var isRecording: Bool      { shows.contains { $0.show_recording } }
    var recordingShows: [Show] { shows.filter { $0.show_recording && ($0.show_end ?? .distantPast) > Date() } }
    var activeShows: [Show]    { shows.filter { $0.show_active && !$0.show_recording && !$0.show_paused }
                                      .sorted { ($0.show_next ?? .distantFuture) < ($1.show_next ?? .distantFuture) } }
    var pausedShows: [Show]    { shows.filter { $0.show_active && $0.show_paused } }
    var inactiveShows: [Show]  { shows.filter { !$0.show_active } }

    var nextShowMinutes: Double? {
        activeShows
            .compactMap { $0.show_next.map { $0.timeIntervalSince(Date()) / 60 } }
            .filter { $0 > 0 }
            .min()
    }

    /// Devices that have both a non-empty lineup and guide data — the ones actually usable for recording.
    var availableDeviceCount: Int {
        devices.filter {
            !(lineups[$0.DeviceID]?.isEmpty ?? true) && !(guideByDevice[$0.DeviceID]?.isEmpty ?? true)
        }.count
    }


    let configManager    = ConfigManager()
    let hdhrManager      = HDHRManager()
    let recordingManager = RecordingManager()
    let guideStore       = GuideStore()

    // Exponential backoff for repeated guide API failures per device.
    // Delays: 1 min → 5 min → 15 min → 30 min → 1 hour (capped).
    // notifiedUser tracks whether we've sent a notification for the current failure streak.
    private struct APIBackoff {
        var failCount: Int = 0
        var nextRetry: Date = .distantPast
        var notifiedUser: Bool = false
        static let delays: [TimeInterval] = [60, 300, 900, 1800, 3600]
        var isBackedOff: Bool { Date() < nextRetry }
        var minutesUntilRetry: Int { max(1, Int(nextRetry.timeIntervalSinceNow / 60)) }
        mutating func recordFailure() {
            failCount += 1
            nextRetry = Date().addingTimeInterval(Self.delays[min(failCount - 1, Self.delays.count - 1)])
        }
        mutating func recordSuccess() { failCount = 0; nextRetry = .distantPast; notifiedUser = false }
    }

    private var idleTimer: Timer?
    private var lastGuideRefresh: Date    = .distantPast
    private var lastDeviceProbe: Date     = .distantPast
    private var guideRefreshInFlight: Bool = false
    // Tracks in-flight lineup fetches so concurrent callers don't fire duplicate requests
    private var loadingLineupDevices: Set<String> = []
    // Per-device exponential backoff after guide API failures (replaces flat guideLoadFailTimes).
    private var guideApiBackoff: [String: APIBackoff] = [:]
    private var failThreshold: Int { config.Fail_count_setting }
    private let maxDiskPct: Double = 93
    // Set true while the MenuBarExtra menu is open (tracked via MenuContent onAppear/onDisappear).
    // Guards guideByDevice.didSet and idle-loop rebuilds so @Published changes don't redraw the menu.
    var menuIsOpen: Bool = false

    init() { Task { await startup() } }

    // MARK: - Startup

    func startup() async {
        // 1. Config first — shows visible in menu immediately
        loadConfig()
        guideStore.verbose = config.Verbose_curl
        glog("[Startup] config loaded — \(shows.count) shows, GuideHours=\(config.GuideHours)")

        // Auto-enable Watch in VLC on first launch if VLC is installed
        if !config.Watch_in_VLC_initialized {
            config.Watch_in_VLC = FileManager.default.fileExists(atPath: "/Applications/VLC.app")
            config.Watch_in_VLC_initialized = true
            saveConfig()
        }

        // 2. Reattach any recordings that survived a restart
        await reattachRecordings()
        glog("[Startup] recordings reattached")

        // 3. Notification permission — fire-and-forget; must not block discovery
        Task { await requestNotifyPermission() }

        // 4. Discover tuners + lineups — 10 attempts, 1s apart
        let knownHosts = knownHostsFromShows()
        glog("[Startup] discovering — knownHosts=\(knownHosts)")
        await discoverDevices(knownHosts: knownHosts, attempts: 10)
        glog("[Startup] discovered \(devices.count) device(s)")
        for d in devices {
            glog("[Startup]   \(d.DeviceID)  LocalIP='\(d.LocalIP)'  DeviceAuth=\(d.DeviceAuth ?? "nil")")
        }

        // 5. Guide — only if tuners found; idleLoop will retry if this fails
        if !devices.isEmpty {
            await fetchAllGuides()
            let ch = guideByDevice.values.reduce(0) { $0 + $1.count }
            glog("[Startup] guide: \(ch) channels across \(guideByDevice.count) device(s)")
        } else {
            glog("[Startup] no devices — idleLoop will retry")
        }

        startTimer()
        isStartingUp = false
        glog("[Startup] complete")

        // Pre-warm SwiftUI's JIT compiler so the first menu click has no delay.
        // A minimal placeholder exercises the same view types (Text, Button, Menu, Divider)
        // without evaluating the live show/guide data — avoids the O(shows × entries) layout
        // cost of rendering full MenuContent at startup.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            let v = NSHostingView(rootView: MenuJITPlaceholder())
            v.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
            _ = v.fittingSize
        }
    }

    func logGuide(_ msg: String, level: LogLevel = .info) { glog(msg, level: level) }

    /// Extract unique device IPs from saved show stream URLs so discovery can try them directly.
    /// .local hostnames are excluded — they require mDNS resolution and add nothing over mDNSDiscover().
    private func knownHostsFromShows() -> [String] {
        var seen = Set<String>()
        return shows.compactMap { show -> String? in
            guard !show.show_url.isEmpty,
                  let host = URL(string: show.show_url)?.host,
                  !host.isEmpty,
                  !host.hasSuffix(".local"),
                  seen.insert(host).inserted else { return nil }
            return host
        }
    }

    func loadConfig() {
        guard let file = configManager.load() else { statusMessage = "No config found"; return }
        config = file.config
        let allShows = file.shows.map { var s = $0; s.show_recording = false; return s }
        let filtered = allShows.filter { $0.show_active }
        shows = filtered
        if filtered.count < allShows.count { saveConfig() }
        statusMessage = "\(shows.count) shows loaded"
        glog("[Startup] \(shows.count) show(s) loaded from config")
    }

    /// Scan ps for caffeinate recordings that survived an app restart and reattach their PIDs.
    private func reattachRecordings() async {
        // Run the blocking ps call off the main actor so the UI stays responsive.
        let output = await Task.detached(priority: .utility) { () -> String in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/ps")
            task.arguments = ["-Axo", "pid,args"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError  = FileHandle.nullDevice
            guard (try? task.run()) != nil else { return "" }
            // Read first — waitUntilExit() before reading can deadlock if ps output fills the pipe buffer
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        }.value

        let now    = Date()

        for line in output.components(separatedBy: "\n") {
            guard line.contains("caffeinate"),
                  line.contains("show_id:"),
                  line.contains("hdhrVCRplus") else { continue }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let cols    = trimmed.components(separatedBy: .whitespaces)
            guard let pidStr = cols.first, let pid = Int32(pidStr) else { continue }

            guard let idRange = line.range(of: "show_id:") else { continue }
            let tail   = String(line[idRange.upperBound...])
            let showId = String(tail.prefix(while: { !$0.isWhitespace && $0 != "'" && $0 != "\"" }))
            guard !showId.isEmpty else { continue }

            guard let i = shows.firstIndex(where: { $0.show_id == showId }),
                  let endDate = shows[i].show_end, endDate > now else { continue }

            shows[i].show_recording = true
            recordingManager.reattach(showId: showId, pid: pid)
            glog("[Startup] Reattached '\(shows[i].show_title)' pid=\(pid) ends \(endDate)")
        }
    }

    func saveConfig() {
        do {
            try configManager.save(ConfigFile(config: config, shows: shows))
        } catch {
            glog("[Config] Save failed: \(error)", level: .error)
            statusMessage = "Config save error — check log"
        }
    }

    func discoverDevices(knownHosts: [String] = [], attempts: Int = 3) async {
        for attempt in 1...max(1, attempts) {
            statusMessage = attempt == 1 ? "Searching for tuners…" : "Searching for tuners (\(attempt)/\(attempts))…"
            do {
                let found = try await hdhrManager.discoverDevices(knownHosts: knownHosts, interface: config.Network_interface)
                devices = found
                await fetchAllLineups(for: found)
                statusMessage = "\(devices.count) tuner(s) found"
                glog("[Discovery] \(devices.count) tuner(s): \(devices.map { "\($0.DeviceID) \($0.LocalIP)" }.joined(separator: ", "))")
                return
            } catch {
                glog("[Discovery] attempt \(attempt)/\(attempts) failed: \(error)", level: .warning) // surface failures instead of silently retrying
                if attempt < attempts {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
        statusMessage = "No tuners found — will keep trying"
    }

    /// Merge-only discovery: finds tuners not already in the devices list and adds them.
    /// Never removes existing entries so active recordings are never disrupted.
    private func probeForNewDevices() async {
        guard let found = try? await hdhrManager.discoverDevices(knownHosts: knownHostsFromShows(), interface: config.Network_interface) else { return }
        let existingIDs = Set(devices.map { $0.DeviceID })

        // Merge-update DeviceAuth + LocalIP on existing devices so cloud tokens stay fresh
        let freshByID = Dictionary(uniqueKeysWithValues: found.map { ($0.DeviceID, $0) })
        for i in devices.indices {
            guard let fresh = freshByID[devices[i].DeviceID] else { continue }
            if fresh.DeviceAuth != nil  { devices[i].DeviceAuth = fresh.DeviceAuth }
            if !fresh.LocalIP.isEmpty   { devices[i].LocalIP    = fresh.LocalIP    }
        }

        let newDevices  = found.filter { !existingIDs.contains($0.DeviceID) }
        guard !newDevices.isEmpty else { return }
        glog("[DeviceProbe] \(newDevices.count) new tuner(s): \(newDevices.map { $0.DeviceID }.joined(separator: ", "))")
        devices.append(contentsOf: newDevices)
        await fetchAllLineups(for: newDevices)
        let results = await guideStore.loadAll(devices: newDevices, hours: config.GuideHours)
        for (deviceId, ok) in results {
            if ok { guideApiBackoff.removeValue(forKey: deviceId) }
            else  { guideApiBackoff[deviceId, default: APIBackoff()].recordFailure() }
        }
        guideByDevice = guideStore.channelsByDevice
    }

    /// Fetch lineup for every device in parallel; stores results in `lineups[deviceID]`.
    /// After all lineups are fetched, checks whether any show's stored stream URL still uses
    /// a stale device IP and updates it from the fresh lineup data.
    /// Ensures lineup is available for `device`; re-fetches if missing or empty.
    /// Guards against silent `try?` failures in fetchAllLineups that leave lineups[deviceID] nil.
    /// Concurrent callers for the same device wait rather than firing duplicate network requests.
    func ensureLineupLoaded(for device: HDHRDevice) async {
        let id = device.DeviceID
        guard lineups[id]?.isEmpty ?? true else { return }
        // Coalesce concurrent callers: only the first proceeds; others wait for it to finish.
        guard !loadingLineupDevices.contains(id) else {
            var waited = 0
            while loadingLineupDevices.contains(id), waited < 50 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
            }
            return
        }
        loadingLineupDevices.insert(id)
        defer { loadingLineupDevices.remove(id) }
        glog("[Lineup] \(id) lineup missing — fetching on demand")
        await fetchAllLineups(for: [device])
    }

    private func fetchAllLineups(for devices: [HDHRDevice]) async {
        await withTaskGroup(of: (String, [LineupEntry]?).self) { group in
            for device in devices {
                group.addTask {
                    let lu = try? await self.hdhrManager.fetchLineup(for: device)
                    return (device.DeviceID, lu)
                }
            }
            for await (id, lu) in group {
                if let lu {
                    glog("[Lineup] \(id) loaded \(lu.count) channels")
                    reconcileFavorites(deviceId: id, freshLineup: lu)
                    lineups[id] = lu
                } else {
                    glog("[Lineup] \(id) fetch failed", level: .warning)
                }
            }
        }
        // After lineups are current, fix any stale show URLs caused by device IP changes
        updateShowURLsFromLineups()
    }

    /// Detects shows whose stored stream URL contains a stale device IP and replaces it
    /// with the fresh URL from the current lineup.  Called after every lineup fetch so a
    /// DHCP IP change is corrected automatically rather than waiting for the next recording.
    /// The lineup URL is authoritative — the device embeds its own current IP in it.
    private func updateShowURLsFromLineups() {
        var dirty = false
        let deviceMap = Dictionary(uniqueKeysWithValues: devices.map { ($0.DeviceID, $0) })
        for i in shows.indices {
            let show = shows[i]
            guard !show.show_url.isEmpty,
                  let device = deviceMap[show.hdhr_record],
                  let storedHost = URL(string: show.show_url)?.host,
                  storedHost != device.LocalIP,           // IP has changed since URL was saved
                  let lineup = lineups[show.hdhr_record],
                  let freshURL = hdhrManager.streamURL(for: show.show_channel, lineup: lineup)
            else { continue }

            shows[i].show_url = freshURL
            dirty = true
            glog("[AppState] show_url updated for '\(show.show_title)': \(storedHost) → \(device.LocalIP)")
        }
        if dirty { saveConfig() }
    }

    // MARK: - Guide cache

    /// Fetch guide for all known devices at startup (in parallel).
    func fetchAllGuides() async {
        guard !devices.isEmpty else { return }
        statusMessage = "Loading guide…"
        guideStore.verbose = config.Verbose_curl
        let results = await guideStore.loadAll(devices: devices, hours: config.GuideHours)
        guideByDevice = guideStore.channelsByDevice
        // Seed per-device backoff state from startup results (no notification — user may not have
        // granted permission yet; ensureGuideLoaded will notify when it retries and fails again).
        for (deviceId, ok) in results {
            if ok { guideApiBackoff.removeValue(forKey: deviceId) }
            else  { guideApiBackoff[deviceId, default: APIBackoff()].recordFailure() }
        }
        let loadedCount = guideByDevice.values.reduce(0) { $0 + $1.count }
        if loadedCount > 0 { lastGuideRefresh = Date(); guideRevision += 1 }
        statusMessage = "\(shows.count) show(s) — \(availableDeviceCount) tuner(s) ready"
        let allChannels = guideByDevice.values.flatMap { $0 }
        Task { await prefetchChannelIcons(allChannels) }
    }

    /// Refresh lineup + guide for all devices (called periodically from idleLoop).
    private func refreshGuides() async {
        guard !guideRefreshInFlight else { return }
        guideRefreshInFlight = true
        // Always stamp lastGuideRefresh — even on total failure. Without this, a complete
        // API outage causes idleLoop to call refreshGuides() every 10s (retry storm).
        // Per-device retries are handled separately by ensureGuideLoaded with exponential backoff.
        defer { guideRefreshInFlight = false; lastGuideRefresh = Date() }
        guideStore.invalidateAll()
        await fetchAllLineups(for: devices)
        guideStore.verbose = config.Verbose_curl
        let results = await guideStore.loadAll(devices: devices, hours: config.GuideHours)
        guideByDevice = guideStore.channelsByDevice
        // Update per-device backoff; notify once per failure streak
        for (deviceId, ok) in results {
            if ok {
                guideApiBackoff.removeValue(forKey: deviceId)
            } else {
                handleGuideLoadFailure(deviceId: deviceId)
            }
        }
        if guideByDevice.values.contains(where: { !$0.isEmpty }) { guideRevision += 1 }
        glog("[Guide] Refresh complete")
        let allChannels = guideByDevice.values.flatMap { $0 }
        Task { await prefetchChannelIcons(allChannels) }
    }

    /// Trigger a guide load for a single device (idleLoop / menu fallback).
    func ensureGuideLoaded(for deviceId: String) {
        // Exponential backoff: 1m → 5m → 15m → 30m → 1h after repeated API failures.
        // Prevents hammering the SiliconDust cloud API (e.g. 403 from EXTEND devices).
        if guideApiBackoff[deviceId]?.isBackedOff == true { return }
        guard !guideStore.isLoading(deviceId: deviceId),
              guideStore.channels(deviceId: deviceId).isEmpty,
              let device = devices.first(where: { $0.DeviceID == deviceId }) else { return }
        Task {
            guideStore.verbose = config.Verbose_curl
            let ok = await guideStore.load(for: device, hours: config.GuideHours)
            // Only update guideByDevice if channels actually loaded — a 403/network failure
            // leaves channels empty. Assigning guideByDevice unconditionally fires didSet →
            // rebuildMenuEntries → SwiftUI re-eval → ensureGuideLoaded again → 403 → loop.
            if ok {
                guideApiBackoff.removeValue(forKey: deviceId)
                guideByDevice = guideStore.channelsByDevice
                await prefetchChannelIcons(guideStore.channels(deviceId: deviceId))
            } else {
                // Notify user on first failure; subsequent backoff retries are silent
                handleGuideLoadFailure(deviceId: deviceId)
            }
        }
    }

    /// Download missing channel icons and warm the mem cache from disk; populate channelIconImages for sync menu lookup.
    private func prefetchChannelIcons(_ channels: [GuideChannel]) async {
        let urls = Array(Set(channels.compactMap { $0.ImageURL }.filter { !$0.isEmpty }))
        guard !urls.isEmpty else { return }
        let needed = await ChannelIconCache.shared.countMissing(in: urls)
        if needed > 0 { statusMessage = "Caching \(needed) channel icon(s)…" }
        // Always fetch all URLs — loads disk→mem even when nothing needs downloading
        await withTaskGroup(of: Void.self) { group in
            for url in urls {
                group.addTask { _ = await ChannelIconCache.shared.image(for: url) }
            }
        }
        if needed > 0 { statusMessage = "\(shows.count) show(s) — \(availableDeviceCount) tuner(s) ready" }
        // One actor hop to read the full mem dict; single @Published assignment regardless of icon count
        let fetched = await ChannelIconCache.shared.allCachedImages(for: urls)
        channelIconImages = channelIconImages.merging(fetched) { _, new in new }
    }

    func isGuideLoading(for deviceId: String) -> Bool {
        guideStore.isLoading(deviceId: deviceId)
    }

    /// Guide entries for a device+channel still airing or upcoming within GuideHours.
    func guideEntries(deviceId: String, channelNum: String) -> [GuideEntry] {
        guideStore.entries(deviceId: deviceId, channelNum: channelNum)
    }

    func bonusOverlapWarning(for entry: GuideEntry, channel: LineupEntry, deviceId: String) -> String? {
        let bonusMin = config.Sports_padding_minutes
        let bonusShows = shows.filter { $0.show_bonus_time }
        let bonusSeriesIDs = Set(bonusShows.compactMap { $0.show_seriesid.isEmpty ? nil : $0.show_seriesid })
        let bonusTitles   = Set(bonusShows.map { $0.show_title })
        let channelEntries = guideEntries(deviceId: deviceId, channelNum: channel.GuideNumber)
        for other in channelEntries {
            guard other.EndTime <= entry.StartTime else { continue }
            let isBonusShow = other.SeriesID.map { bonusSeriesIDs.contains($0) } ?? bonusTitles.contains(other.Title)
            guard isBonusShow else { continue }
            let bonusEndEpoch = other.EndTime + bonusMin * 60
            guard bonusEndEpoch > entry.StartTime else { continue }
            let overlapMin = max(1, (bonusEndEpoch - entry.StartTime) / 60)
            return "⚠️ First \(overlapMin) min overlap with extended recording of \"\(other.Title)\""
        }
        return nil
    }

    func rebuildMenuEntries() {
        let now = Date()

        // ── O(1) managed-show lookup dicts (WatchNowView + scheduledMenu) ─────
        var bySeriesID: [String: Show] = [:]
        var byTitle:    [String: Show] = [:]
        for show in shows {
            if !show.show_seriesid.isEmpty { bySeriesID[show.show_seriesid] = show }
            byTitle[show.show_title] = show
        }
        managedShowBySeriesID = bySeriesID
        managedShowByTitle    = byTitle

        // ── O(1) channel logo URL lookup for channelMenu ──────────────────────
        var imageURLs: [String: String] = [:]
        for (deviceId, channels) in guideByDevice {
            for ch in channels {
                if let url = ch.ImageURL, !url.isEmpty {
                    imageURLs["\(deviceId):\(ch.GuideNumber)"] = url
                }
            }
        }
        channelImageURLs = imageURLs

        // ── Scheduled menu: guide entry + upcoming slots per active show ──────
        var scheduledResult: [String: GuideEntry] = [:]
        var upcomingResult:  [String: [(channel: String, date: Date)]] = [:]
        for show in shows where show.show_active && !show.show_paused {
            let schNext = show.show_next ?? .distantFuture
            // Replicate scheduledMenu's schEntry logic: direct match first, series fallback
            let direct = guideStore.entries(deviceId: show.hdhr_record, channelNum: show.show_channel)
            if let hit = direct.first(where: { abs($0.startDate.timeIntervalSince(schNext)) < 5 * 60 }) {
                scheduledResult[show.show_id] = hit
            } else if show.show_use_seriesid, !show.show_seriesid.isEmpty {
                let ch  = show.show_use_seriesid_all ? nil : show.show_channel
                let dev = show.show_use_seriesid_all ? nil : show.hdhr_record
                scheduledResult[show.show_id] = guideStore.nextEpisode(
                    seriesID: show.show_seriesid, channelNum: ch, deviceId: dev,
                    after: schNext.addingTimeInterval(-3600)
                )?.entry
            }
            // Upcoming slots for SeriesID shows
            if show.show_use_seriesid, !show.show_seriesid.isEmpty {
                upcomingResult[show.show_id] = guideStore.nextEpisodes(
                    seriesID: show.show_seriesid, after: now, limit: 3
                ).map { ($0.channelNum, $0.entry.startDate) }
            }
        }
        menuScheduledEntry  = scheduledResult
        menuUpcomingSlots   = upcomingResult

        // ── Conflict detection: one O(N²) pass instead of one per menu open ──
        let deviceMap = Dictionary(uniqueKeysWithValues: devices.compactMap { d -> (String, Int)? in
            guard let t = d.TunerCount, t > 0 else { return nil }
            return (d.DeviceID, t)
        })
        // Include recording shows so a scheduled show that overlaps with an already-recording
        // show is correctly flagged — activeShows excludes show_recording == true shows.
        let candidateShows = shows.filter { $0.show_active && !$0.show_paused }
        var newConflicts = Set<String>()
        for show in candidateShows {
            guard let next = show.show_next,
                  let end  = show.show_end,
                  let tunerCount = deviceMap[show.hdhr_record] else { continue }
            let overlapping = candidateShows.filter { other in
                guard other.show_id != show.show_id,
                      other.hdhr_record == show.hdhr_record,
                      let oNext = other.show_next,
                      let oEnd  = other.show_end
                else { return false }
                return oNext < end && oEnd > next
            }.count
            if overlapping >= tunerCount { newConflicts.insert(show.show_id) }
        }
        conflictingShowIDs = newConflicts
    }

    /// Up to `limit` upcoming episodes for a given SeriesID across all devices/channels.
    func upcomingGuideEpisodes(seriesID: String, after: Date = Date(), limit: Int = 4) -> [(channel: String, entry: GuideEntry)] {
        guideStore.nextEpisodes(seriesID: seriesID, after: after, limit: limit)
            .map { ($0.channelNum, $0.entry) }
    }

    /// Next episode of a SeriesID show from the guide cache.
    func nextGuideEpisode(for show: Show) -> (channel: String, entry: GuideEntry)? {
        guard show.show_use_seriesid, !show.show_seriesid.isEmpty else { return nil }
        let channelFilter: String? = show.show_use_seriesid_all ? nil : show.show_channel
        let deviceFilter: String? = show.show_use_seriesid_all ? nil : show.hdhr_record
        guard let match = guideStore.nextEpisode(seriesID: show.show_seriesid,
                                                 channelNum: channelFilter,
                                                 deviceId: deviceFilter) else { return nil }
        return (match.channelNum, match.entry)
    }

    // MARK: - Add show from guide entry (called by menu)

    func addShowFromGuide(entry: GuideEntry, type: ShowState, device: HDHRDevice, channel: LineupEntry) {
        // Use the default directory automatically; user can override per-show via Edit.
        let folder = defaultSaveDir

        var show = Show.blank(channel: channel.GuideNumber, device: device.DeviceID)
        show.show_transcode = config.Default_transcode
        show.show_title     = entry.Title
        show.show_length    = entry.durationMinutes
        show.show_next      = entry.startDate
        show.show_end       = entry.endDate
        show.show_seriesid  = entry.SeriesID ?? ""
        show.show_logo_url  = entry.ImageURL ?? ""
        show.show_url       = channel.URL ?? ""
        show.show_genre     = entry.firstGenre ?? ""
        show.show_dir       = folder.path
        show.show_temp_dir  = NSHomeDirectory() + "/Movies/hdhr_videos"

        // Local decimal hour from guide start time (matches what the user sees in the guide)
        let comps = Calendar.current.dateComponents([.hour, .minute], from: entry.startDate)
        show.show_time = Double(comps.hour ?? 20) + Double(comps.minute ?? 0) / 60.0

        let allDays = ["Monday","Tuesday","Wednesday","Thursday","Friday","Saturday","Sunday"]
        switch type {
        case .single:
            show.show_is_series = false; show.show_use_seriesid = false; show.show_use_seriesid_all = false
            show.show_air_date = []
        case .dateTime:
            show.show_is_series = true; show.show_use_seriesid = false; show.show_use_seriesid_all = false
            let weekday = Calendar.current.component(.weekday, from: entry.startDate)
            show.show_air_date = [["Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"][weekday - 1]]
        case .seriesChannel:
            show.show_is_series = true; show.show_use_seriesid = true; show.show_use_seriesid_all = false
            show.show_air_date = allDays
            resolveSeriesAir(show: &show, device: device, isAll: false, channel: channel)
        case .seriesAll:
            show.show_is_series = true; show.show_use_seriesid = true; show.show_use_seriesid_all = true
            show.show_air_date = allDays
            resolveSeriesAir(show: &show, device: device, isAll: true, channel: channel)
        }

        if hasConflict(for: show) {
            notify("Recording Conflict", body: show.show_title,
                   subtitle: "All tuners on \(show.hdhr_record) are busy at \(shortTime(show.show_next))")
            discordShow("⚠️ Tuner Conflict", show: show, color: 0xF1C40F, enabled: config.Discord_on_conflict,
                        extra: [("Note", "All tuners on \(show.hdhr_record) are busy at \(shortTime(show.show_next))", false)])
        }
        addShow(show)
        notify("Show Added", body: show.show_title, subtitle: type.rawValue)
        discordShow("✅ Show Added", show: show, color: 0x1ABC9C, enabled: config.Discord_on_show_added,
                    extra: [("Type", type.rawValue, true)])
    }

    /// For SeriesID shows, find the earliest airing episode and update show_next/show_end/show_channel/show_url.
    /// Checks currently-airing first (so show_next may be in the past — idle loop records the remaining portion),
    /// then the next future episode. Falls back silently if neither is found (selected entry's times stay).
    func resolveSeriesAir(show: inout Show, device: HDHRDevice, isAll: Bool, channel: LineupEntry) {
        let chFilter  = isAll ? nil : channel.GuideNumber
        let devFilter = isAll ? nil : device.DeviceID
        let now       = Date()

        // Helper: apply a SeriesMatch to the show — uses m.deviceId for lineup lookup so
        // SeriesID(All) works correctly when the episode is on a different device than browsed.
        func apply(_ m: GuideStore.SeriesMatch) {
            show.show_next    = m.entry.startDate
            show.show_end     = m.entry.endDate
            show.show_channel = m.channelNum
            show.hdhr_record  = m.deviceId
            if let url = hdhrManager.streamURL(for: m.channelNum, lineup: lineups[m.deviceId] ?? []) {
                show.show_url = url
            }
        }

        if let m = guideStore.currentEpisode(seriesID: show.show_seriesid, channelNum: chFilter, deviceId: devFilter, at: now) {
            apply(m); return
        }
        // Fallback: title match on channelEntryIndex — handles guide entries where SeriesID is absent.
        if let ch = chFilter, let dev = devFilter,
           let m = guideStore.currentEntryByTitle(show.show_title, channelNum: ch, deviceId: dev, at: now) {
            apply(m); return
        }
        if let m = guideStore.nextEpisode(seriesID: show.show_seriesid, channelNum: chFilter, deviceId: devFilter, after: now) {
            apply(m); return
        }
        // Fallback: title match for next airing — handles guide entries where SeriesID is absent.
        if let ch = chFilter, let dev = devFilter,
           let m = guideStore.nextEntryByTitle(show.show_title, channelNum: ch, deviceId: dev, after: now) {
            apply(m); return
        }
    }

    /// The default recording folder: UserDefaults override → config Hdhr_setup_folder → ~/Movies/hdhr_videos.
    /// ~/Movies is TCC-free for non-sandboxed apps and visible in the Finder sidebar.
    var defaultSaveDir: URL {
        let stored = UserDefaults.standard.string(forKey: "defaultSaveDirectory") ?? ""
        if !stored.isEmpty { return URL(fileURLWithPath: stored) }
        if !config.Hdhr_setup_folder.isEmpty { return URL(fileURLWithPath: config.Hdhr_setup_folder) }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies/hdhr_videos")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Synchronous folder picker — opens NSOpenPanel after menu dismisses.
    /// Pre-selects defaultSaveDir. Returns nil only if the user cancels.
    func pickFolder(message: String) -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.message = message
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = defaultSaveDir
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: - Timer

    func startTimer() {
        idleTimer?.invalidate()
        let interval = TimeInterval(max(5, config.Idle_timer_interval))
        idleTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.idleLoop() }
        }
        idleTimer?.fire()
    }

    func idleLoop() async {
        let now = Date()
        var dirty = false

        // If startup discovery failed, keep retrying — single attempt per tick so we return quickly
        if devices.isEmpty {
            await discoverDevices(knownHosts: knownHostsFromShows(), attempts: 1)
            if !devices.isEmpty { await fetchAllGuides() }
            return
        }

        // If guide is missing for any device (fetch failed at startup), load it now
        for device in devices where guideStore.channels(deviceId: device.DeviceID).isEmpty {
            ensureGuideLoaded(for: device.DeviceID)
        }

        // Warn if any active show is assigned to a device we can no longer see
        let knownIDs = Set(devices.map { $0.DeviceID })
        for show in activeShows where !show.hdhr_record.isEmpty && !knownIDs.contains(show.hdhr_record) {
            glog("[\(show.show_title)] device \(show.hdhr_record) not found — show may miss its recording", level: .warning)
        }

        // Probe for newly-connected tuners every 5 minutes (merge-only — safe during active recordings)
        if now.timeIntervalSince(lastDeviceProbe) > 300 {
            lastDeviceProbe = now
            Task { await probeForNewDevices() }
        }

        // Refresh lineup + guide every GuideHours / 2 (default: every 12 h, min: 1 h)
        let refreshInterval = max(3600.0, Double(config.GuideHours) * 1800.0)
        if now.timeIntervalSince(lastGuideRefresh) > refreshInterval {
            Task { await refreshGuides() }
        }
        // Pass 1: stop all completed recordings before any new ones start
        for i in shows.indices {
            guard shows[i].show_active, shows[i].show_recording,
                  let end = shows[i].show_end, end <= now else { continue }
            await stopRecording(index: i, natural: true)
            dirty = true
        }

        // Pass 2: per-show housekeeping — notifications, fail detection, stranded advance
        for i in shows.indices {
            let show = shows[i]
            guard show.show_active else { continue }
            let nextDate = show.show_next ?? .distantFuture
            let endDate  = show.show_end  ?? .distantPast

            // Auto-resume paused shows:
            // - window expired (failed/stopped): advance to next airing and un-pause
            // - next airing imminent (skip): just un-pause so recording starts next tick
            if show.show_paused {
                if endDate <= now {
                    shows[i].show_paused = false
                    shows[i].clearFailures()
                    glog("[\(show.show_title)] auto-resuming — paused window expired, rescheduling")
                    await scheduleNextAir(index: i)
                    dirty = true
                } else if nextDate <= now + 10 {
                    shows[i].show_paused = false
                    shows[i].clearFailures()
                    glog("[\(show.show_title)] auto-resuming — next airing imminent")
                    dirty = true
                }
                continue
            }

            let minutesAway = nextDate.timeIntervalSince(now) / 60

            // "Up Next" notification — fires once at Notify_upnext minutes before
            let upNextDue = (show.notify_upnext_time ?? .distantPast) <= now
            if !show.show_recording, upNextDue, minutesAway > 0, minutesAway <= config.Notify_upnext {
                notify("Up Next", body: show.show_title, subtitle: "Starts in \(Int(minutesAway)) min on Channel \(show.show_channel)",
                       categoryIdentifier: "upnext", userInfo: ["show_id": show.show_id])
                discordShow("🔔 Up Next", show: show, color: 0x9B59B6, enabled: config.Discord_on_upnext,
                            extra: [("Starts In", "\(Int(minutesAway)) min", true)])
                shows[i].notify_upnext_time = now.addingTimeInterval(config.Notify_upnext * 60)
                dirty = true
            }

            // "Recording About to Start" notification — fires once at Notify_recording minutes before
            let recNotifyDue = (show.notify_recording_time ?? .distantPast) <= now
            if !show.show_recording, recNotifyDue, minutesAway > 0, minutesAway <= config.Notify_recording {
                notify("Recording Soon", body: show.show_title, subtitle: "Starts in \(Int(minutesAway)) min on Channel \(show.show_channel)",
                       categoryIdentifier: "recording.soon", userInfo: ["show_id": show.show_id])
                discordShow("⏱ Recording Soon", show: show, color: 0x9B59B6, enabled: config.Discord_on_soon,
                            extra: [("Starts In", "\(Int(minutesAway)) min", true)])
                shows[i].notify_recording_time = now.addingTimeInterval(config.Notify_recording * 60)
                dirty = true
            }

            // Show window is open and we're not recording — warn if we're past the start time
            // with no obvious reason (not tuner-full, not paused, not already handled above)
            if !show.show_recording, nextDate < now - 30, endDate > now {
                glog("[\(show.show_title)] MISSED START — window open since \(shortTime(show.show_next)), still not recording", level: .warning)
            }

            if show.show_recording, endDate > now, !recordingManager.isRunning(showId: show.show_id) {
                shows[i].show_recording = false
                shows[i].recordFailure(reason: "curl exited unexpectedly")
                glog("[\(show.show_title)] FAIL curl exited unexpectedly — fail_count=\(shows[i].show_fail_count)", level: .error)
                notify("Recording Failed", body: show.show_title, subtitle: "curl exited unexpectedly")
                discordShow("❌ Recording Failed", show: show, color: 0xE74C3C, enabled: config.Discord_on_failed,
                            extra: [("Reason", "curl exited unexpectedly", false), ("Fail Count", "\(shows[i].show_fail_count)", true)],
                            editMessageId: show.discord_start_msg_id.isEmpty ? nil : show.discord_start_msg_id)
                shows[i].discord_start_msg_id = ""
                dirty = true
            }

            // Discord progress update — edit start embed once per 5-min boundary during active recordings
            if show.show_recording, !show.discord_start_msg_id.isEmpty,
               config.Discord_on_progress, config.Discord_enabled, !config.Discord_webhook_url.isEmpty {
                let elapsedSec = Int(now.timeIntervalSince(show.show_next ?? now))
                let prevSec    = elapsedSec - config.Idle_timer_interval
                let interval   = 5 * 60
                if elapsedSec > 0, elapsedSec / interval > max(0, prevSec) / interval {
                    let elapsedMin   = elapsedSec / 60
                    let totalMin     = show.show_end.map { Int($0.timeIntervalSince(show.show_next ?? $0) / 60) } ?? show.show_length
                    let remainingMin = max(0, show.show_end.map { Int($0.timeIntervalSince(now) / 60) } ?? (totalMin - elapsedMin))
                    let progressText = "\(elapsedMin)m elapsed · \(remainingMin)m remaining"
                    let embed = buildDiscordShowEmbed(event: "⏺ Recording In Progress", show: show,
                                                     color: 0xE67E22, extra: [("Progress", progressText, false)])
                    editDiscordEmbed(webhookURL: config.Discord_webhook_url,
                                     messageId: show.discord_start_msg_id, embed: embed)
                }
            }
            // Advance shows stranded with a past window and show_recording = false.
            // Happens when the app restarts after curl exits normally but before the idle loop
            // fires the natural-stop handler above (which requires show_recording == true).
            if !show.show_recording, endDate <= now, nextDate < now {
                glog("[\(show.show_title)] stranded show_next in past — advancing", level: .warning)
                await scheduleNextAir(index: i); dirty = true
            }
        }

        // Start recordings in favorite-first order so favorited channels win the last tuner slot
        // when multiple shows compete for the same tuner at the same time.
        let readyIndices = shows.indices.filter { i in
            let s = shows[i]
            guard s.show_active, !s.show_recording, !s.show_paused,
                  let next = s.show_next, let end = s.show_end else { return false }
            return next <= now + 10 && end > now
        }.sorted { isFavoriteChannel(shows[$0]) && !isFavoriteChannel(shows[$1]) }
        if !readyIndices.isEmpty { dirty = true }
        for i in readyIndices { await startRecording(index: i) }

        if dirty { saveConfig() }

        // One /status.json fetch per device covers both menu-header occupancy counts and
        // per-recording vstatus — avoids O(tunerCount) separate HTTP calls per recording.
        for device in devices {
            Task { await fetchDeviceStatus(for: device) }
        }

        // Re-sync menu caches with current show states (show_next changes after recordings complete).
        // Skip while the menu is open — @Published changes would cause SwiftUI to redraw it mid-display.
        if !menuIsOpen { rebuildMenuEntries() }
    }

    // MARK: - Recording

    func startRecording(index: Int) async {
        var show = shows[index]
        // Enforce tuner limit: skip if all slots on this device are already occupied
        if let device = devices.first(where: { $0.DeviceID == show.hdhr_record }),
           let tunerCount = device.TunerCount {
            let active = recordingShows.filter { $0.hdhr_record == show.hdhr_record }.count
            if active >= tunerCount {
                glog("[\(show.show_title)] TUNER FULL \(show.hdhr_record): \(active)/\(tunerCount) — skipping start", level: .warning)
                // Fire conflict notification once per show+episode window to avoid per-tick spam.
                let key = "\(show.show_id)-\(show.show_next?.timeIntervalSince1970 ?? 0)"
                if !conflictNotifiedKeys.contains(key) {
                    conflictNotifiedKeys.insert(key)
                    notify("Tuner Conflict", body: show.show_title,
                           subtitle: "All tuners on \(show.hdhr_record) are busy")
                    discordShow("⚠️ Tuner Conflict", show: show, color: 0xF1C40F,
                                enabled: config.Discord_on_conflict,
                                extra: [("Note", "All \(tunerCount) tuners on \(show.hdhr_record) are busy", false)])
                }
                return
            }
        }
        if show.show_url.isEmpty {
            if let lu = lineups[show.hdhr_record],
               let url = hdhrManager.streamURL(for: show.show_channel, lineup: lu) {
                shows[index].show_url = url; show.show_url = url
            } else {
                glog("[\(show.show_title)] NO STREAM URL — ch=\(show.show_channel) device=\(show.hdhr_record)", level: .error)
                shows[index].recordFailure(reason: "No stream URL"); return
            }
        }
        if show.show_fail_count == failThreshold - 1 {
            glog("[\(show.show_title)] WARNING — fail_count=\(show.show_fail_count)/\(failThreshold), one more failure will pause this show", level: .warning)
        }
        guard show.show_fail_count < failThreshold else {
            glog("[\(show.show_title)] PAUSED — fail threshold \(failThreshold) reached", level: .warning)
            if show.state == .single {
                shows[index].show_active = false  // singles auto-clean on restart; no point keeping them
            } else {
                shows[index].show_paused = true   // recoverable; auto-resumes after window expires
            }
            notify("Recording Paused", body: show.show_title, subtitle: "Failed \(failThreshold)× — will retry next airing")
            discordShow("⏸ Recording Paused", show: show, color: 0xE67E22, enabled: config.Discord_on_paused,
                        extra: [("Reason", "Failed \(failThreshold)× — will retry next airing", false)])
            return
        }
        guard diskOK(for: show) else {
            glog("[\(show.show_title)] DISK FULL — skipping recording", level: .warning)
            shows[index].recordFailure(reason: "Disk too full")
            notify("Recording Skipped", body: show.show_title, subtitle: "Disk over \(Int(maxDiskPct))%")
            discordShow("💾 Recording Skipped", show: show, color: 0xE67E22, enabled: config.Discord_on_skipped,
                        extra: [("Reason", "Disk over \(Int(maxDiskPct))% — free up space", false)])
            return
        }
        let path = show.outputPath(date: show.show_next ?? Date())
        if !show.show_dir.isEmpty, show.posixRecordDir != show.show_dir {
            glog("[\(show.show_title)] Primary folder unavailable — recording to fallback: \(show.posixRecordDir)", level: .warning)
        }
        var endDate = show.show_end ?? Date().addingTimeInterval(Double(show.show_length) * 60)
        // Bonus Time: extend recording past the guide end for sports shows so overtime isn't cut off
        if config.Sports_padding_enabled && show.show_bonus_time {
            endDate = endDate.addingTimeInterval(Double(config.Sports_padding_minutes) * 60)
            glog("[\(show.show_title)] Bonus Time +\(config.Sports_padding_minutes) min applied")
        }
        // Always persist endDate so the idle-loop natural-stop check and notifications use it
        shows[index].show_end = endDate
        let remainingSecs = max(60, Int(endDate.timeIntervalSince(Date())))
        glog("[\(show.show_title)] START ch=\(show.show_channel) dur=\(remainingSecs)s transcode=\(show.show_transcode) → \(path)")
        do {
            try recordingManager.start(showId: show.show_id, url: show.show_url,
                                       outputPath: path, durationSeconds: remainingSecs,
                                       transcode: show.show_transcode, showEnd: endDate,
                                       verbose: config.Verbose_curl,
                                       networkInterface: config.Network_interface)
        } catch {
            glog("[\(show.show_title)] LAUNCH ERROR: \(error)", level: .error)
            shows[index].recordFailure(reason: "Launch failed: \(error.localizedDescription)")
            notify("Recording Failed", body: show.show_title, subtitle: "Could not launch — \(error.localizedDescription)")
            discordShow("❌ Recording Failed", show: show, color: 0xE74C3C, enabled: config.Discord_on_failed,
                        extra: [("Reason", "Launch failed: \(error.localizedDescription)", false)])
            return
        }
        shows[index].show_recording = true; shows[index].show_recording_path = path
        shows[index].show_fail_count = max(0, show.show_fail_count - 1)
        refreshTunerOccupancy()
        // Stamp notify_recording_time so the "Recording Soon" pre-notification won't re-fire
        shows[index].notify_recording_time = Date().addingTimeInterval(config.Notify_recording * 60)
        notify("Recording Started", body: show.show_title, subtitle: "Channel \(show.show_channel) — ends \(shortTime(endDate))",
               categoryIdentifier: "recording.started", userInfo: ["show_id": show.show_id])
        // Capture message ID so completion/failure can edit this embed in-place.
        if config.Discord_on_start, config.Discord_enabled, !config.Discord_webhook_url.isEmpty {
            let embed  = buildDiscordShowEmbed(event: "🔴 Recording Started", show: shows[index],
                                               color: 0x2ECC71, extra: [("Ends", shortTime(endDate), true)])
            let url    = config.Discord_webhook_url
            let showId = show.show_id
            Task {
                let msgId = await sendDiscordEmbedCapturing(to: url, embed: embed)
                if let i = shows.firstIndex(where: { $0.show_id == showId }) {
                    shows[i].discord_start_msg_id = msgId ?? ""
                }
            }
        }
    }

    func skipRecording(showId: String) async {
        guard let i = shows.firstIndex(where: { $0.show_id == showId }) else { return }
        glog("[\(shows[i].show_title)] SKIP — paused until next airing")
        recordingManager.stop(showId: showId)
        VLCPlayerWindowManager.shared.closeIfPlayingURL(shows[i].show_url)
        tunerStatus.removeValue(forKey: showId)
        shows[i].show_recording = false
        shows[i].show_last = Date()
        shows[i].show_paused = true
        shows[i].show_fail_reason = "Skipped"
        await scheduleNextAir(index: i)
        saveConfig()
    }

    func stopRecording(index: Int, natural: Bool) async {
        let show = shows[index]
        recordingManager.stop(showId: show.show_id)
        tunerStatus.removeValue(forKey: show.show_id)
        shows[index].show_recording = false
        refreshTunerOccupancy()
        shows[index].show_last = Date()

        if !natural {
            glog("[\(show.show_title)] STOP manual")
            shows[index].show_paused = true
            shows[index].show_fail_reason = "Manually stopped"
            saveConfig()
            return
        }

        // Verify the output file was actually created and is non-empty
        let path = show.show_recording_path
        let fileAttrs = path.isEmpty ? nil : (try? FileManager.default.attributesOfItem(atPath: path))
        let fileSize  = fileAttrs?[.size] as? Int ?? 0

        if !path.isEmpty && fileSize == 0 {
            shows[index].recordFailure(reason: "Output file missing or empty")
            glog("[\(show.show_title)] STOP file missing or empty — fail_count=\(shows[index].show_fail_count)", level: .error)
            notify("Recording Failed", body: show.show_title, subtitle: "File not written — check disk space and URL")
            discordShow("❌ Recording Failed", show: show, color: 0xE74C3C, enabled: config.Discord_on_failed,
                        extra: [("Reason", "Output file missing or empty — check disk space and stream URL", false)],
                        editMessageId: show.discord_start_msg_id.isEmpty ? nil : show.discord_start_msg_id)
            shows[index].discord_start_msg_id = ""
            await scheduleNextAir(index: index)
            return
        }
        if !path.isEmpty {
            glog("[\(show.show_title)] STOP natural size=\(fileSize / 1024)KB → \(path)")
        }

        // File info fields appended to every Recording Complete embed
        var fileFields: [(name: String, value: String, inline: Bool)] = []
        if !path.isEmpty && fileSize > 0 {
            let ext = URL(fileURLWithPath: path).pathExtension.uppercased()
            if !ext.isEmpty { fileFields.append(("Format", ext, true)) }
            fileFields.append(("File Size", Self.formatFileSize(fileSize), true))
        }

        await scheduleNextAir(index: index)
        let completedShow = shows[index]
        let startMsgId = show.discord_start_msg_id.isEmpty ? nil : show.discord_start_msg_id
        if !completedShow.show_active {
            notify("Recording Complete", body: show.show_title, subtitle: "Single episode recorded — show deactivated")
            discordShow("✅ Recording Complete", show: show, color: 0x3498DB, enabled: config.Discord_on_complete,
                        extra: fileFields + [("Note", "Single episode — show deactivated", false)],
                        editMessageId: startMsgId)
        } else if let next = completedShow.show_next {
            notify("Recording Complete", body: show.show_title, subtitle: "Next: \(Self.completionDateFormatter.string(from: next))")
            discordShow("✅ Recording Complete", show: show, color: 0x3498DB, enabled: config.Discord_on_complete,
                        extra: fileFields + [("Next Airing", Self.completionDateFormatter.string(from: next), false)],
                        editMessageId: startMsgId)
        } else {
            notify("Recording Complete", body: show.show_title, subtitle: "")
            discordShow("✅ Recording Complete", show: show, color: 0x3498DB, enabled: config.Discord_on_complete,
                        extra: fileFields, editMessageId: startMsgId)
        }
        shows[index].discord_start_msg_id = ""
    }

    func stopRecording(showId: String) {
        guard let i = shows.firstIndex(where: { $0.show_id == showId }) else { return }
        Task { await stopRecording(index: i, natural: false) }
    }

    // MARK: - Next-air scheduling

    func scheduleNextAir(index: Int) async {
        guard index < shows.count else { return }
        let show = shows[index]
        // Keys are "showId-epoch" — once show_next advances the old key is stale.
        // Remove on every reschedule so the set doesn't accumulate indefinitely.
        conflictNotifiedKeys = conflictNotifiedKeys.filter { !$0.hasPrefix("\(show.show_id)-") }
        switch show.state {
        case .single:
            glog("[\(show.show_title)] DONE single — deactivated")
            shows[index].show_active = false
        case .dateTime:
            if let next = nextDateTime(for: show) {
                shows[index].show_next = next
                shows[index].show_end  = next.addingTimeInterval(Double(show.show_length) * 60)
                glog("[\(show.show_title)] NEXT \(shortTime(next)) ch=\(show.show_channel)")
            } else {
                // No matching air day found (show_air_date is empty or invalid) — pause rather than loop forever
                glog("[\(show.show_title)] PAUSED — no air days configured", level: .warning)
                shows[index].show_paused = true
                shows[index].show_fail_reason = "No air days configured"
                notify("Show Paused", body: show.show_title, subtitle: "No air days configured — edit show to fix")
                discordShow("⏸ Show Paused", show: show, color: 0xE67E22, enabled: config.Discord_on_paused,
                            extra: [("Reason", "No air days configured — edit show to fix", false)])
            }
        case .seriesChannel, .seriesAll:
            if let device = devices.first(where: { $0.DeviceID == show.hdhr_record }) {
                let chFilter = show.state == .seriesAll ? nil : show.show_channel
                let devFilter = show.state == .seriesAll ? nil : device.DeviceID
                // If guide is stale or absent, reload before searching
                if !guideStore.isFresh(deviceId: device.DeviceID) {
                    guideStore.verbose = config.Verbose_curl
                    await guideStore.load(for: device, hours: config.GuideHours)
                    guideByDevice = guideStore.channelsByDevice
                }
                // Check for a currently-airing episode first (e.g. marathon, back-to-back airings).
                // Use match.deviceId for lineup lookup — SeriesID(All) may resolve to a different device.
                let now = Date()
                func applyMatch(_ match: GuideStore.SeriesMatch) {
                    shows[index].show_next    = match.entry.startDate
                    shows[index].show_end     = match.entry.endDate
                    shows[index].show_channel = match.channelNum
                    shows[index].show_genre   = match.entry.firstGenre ?? ""
                    shows[index].hdhr_record  = match.deviceId
                    if let url = hdhrManager.streamURL(for: match.channelNum, lineup: lineups[match.deviceId] ?? []) {
                        shows[index].show_url = url
                    }
                }
                if let match = guideStore.currentEpisode(seriesID: show.show_seriesid, channelNum: chFilter, deviceId: devFilter, at: now) {
                    glog("[\(show.show_title)] NEXT now (on-air) ch=\(match.channelNum) \(match.entry.Title)")
                    applyMatch(match); return
                }
                if let match = guideStore.nextEpisode(seriesID: show.show_seriesid,
                                                      channelNum: chFilter,
                                                      deviceId: devFilter) {
                    glog("[\(show.show_title)] NEXT \(shortTime(match.entry.startDate)) ch=\(match.channelNum) \(match.entry.Title)")
                    applyMatch(match); return
                }
                // Fallback: title match — handles guide entries where SeriesID is absent.
                if let ch = chFilter, let dev = devFilter {
                    if let match = guideStore.currentEntryByTitle(show.show_title, channelNum: ch, deviceId: dev, at: now) {
                        glog("[\(show.show_title)] NEXT now (title match, on-air) ch=\(match.channelNum)")
                        applyMatch(match); return
                    }
                    if let match = guideStore.nextEntryByTitle(show.show_title, channelNum: ch, deviceId: dev, after: now) {
                        glog("[\(show.show_title)] NEXT \(shortTime(match.entry.startDate)) ch=\(match.channelNum) (title match)")
                        applyMatch(match); return
                    }
                }
            }
            glog("[\(show.show_title)] no episode found — retry in \(config.Series_scan_retry_hours)h", level: .warning)
            shows[index].show_next = Date().addingTimeInterval(Double(config.Series_scan_retry_hours) * 3600)
        }
    }

    /// All DateTime show occurrences after `after`, up to `count`.
    /// Pass `after: Date()` to include today's airing if it hasn't happened yet (menu display).
    /// Pass `after: startOfTomorrow` to always skip today (rescheduling after a completed recording).
    func nextDateTimeOccurrences(for show: Show, after: Date = Date(), count: Int = 1) -> [Date] {
        let cal = Calendar.current
        let dayNames = ["sunday","monday","tuesday","wednesday","thursday","friday","saturday"]
        let airIndices = show.show_air_date.compactMap { dayNames.firstIndex(of: $0.lowercased()) }
        guard !airIndices.isEmpty else { return [] }
        let hours   = Int(show.show_time)
        let minutes = Int((show.show_time - Double(hours)) * 60)
        let baseWeekday = cal.component(.weekday, from: after) - 1  // 0 = Sunday
        let weeksNeeded = max(2, (count / max(1, airIndices.count)) + 2)
        var candidates: [Date] = []
        for target in airIndices {
            let daysUntil = (target - baseWeekday + 7) % 7
            for week in 0..<weeksNeeded {
                guard let base = cal.date(byAdding: .day, value: daysUntil + week * 7, to: after) else { continue }
                var c = cal.dateComponents([.year, .month, .day], from: base)
                c.hour = hours; c.minute = minutes; c.second = 0
                if let d = cal.date(from: c), d > after { candidates.append(d) }
            }
        }
        return Array(candidates.sorted().prefix(count))
    }

    func nextDateTime(for show: Show) -> Date? {
        // Always skip today — a completed recording should never reschedule to the same day.
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1,
                           to: Calendar.current.startOfDay(for: Date()))!
        return nextDateTimeOccurrences(for: show, after: tomorrow).first
    }

    // MARK: - Show CRUD

    func addShow(_ show: Show) {
        guard !shows.contains(where: { $0.show_id == show.show_id }) else { return }
        glog("[Show] Added '\(show.show_title)' ch=\(show.show_channel) \(show.show_is_series ? "series" : "single")")
        shows.append(show); saveConfig()
    }
    func updateShow(_ show: Show) {
        guard let i = shows.firstIndex(where: { $0.show_id == show.show_id }) else { return }
        glog("[Show] Updated '\(show.show_title)'")
        shows[i] = show; saveConfig()
    }


    // MARK: - Favorites

    /// True when the show's scheduled channel is marked favorite on its device.
    func isFavoriteChannel(_ show: Show) -> Bool {
        lineups[show.hdhr_record]?.first { $0.GuideNumber == show.show_channel }?.isFavorite ?? false
    }

    /// Optimistically toggle favorite: mutates lineups in place immediately (instant UI update),
    /// fires the POST in the background, and reverts on failure. Next natural lineup reload
    /// reconciles against the device's actual state via reconcileFavorites.
    /// Synchronous entry point — called directly from Button action on MainActor.
    /// Mutates lineups immediately (SwiftUI sees the change this render frame),
    /// then fires the POST in a background Task. Reverts only if POST fails.
    func toggleFavorite(device: HDHRDevice, channel: LineupEntry) {
        let newFav   = !channel.isFavorite
        let deviceId = device.DeviceID
        let chNum    = channel.GuideNumber
        let arrow    = "\(channel.isFavorite ? "★" : "☆") → \(newFav ? "★" : "☆")"

        // Immediate lineup mutation — fires objectWillChange right now, no Task overhead
        if var entries = lineups[deviceId],
           let idx = entries.firstIndex(where: { $0.GuideNumber == chNum }) {
            entries[idx].Favorite = newFav ? 1 : 0
            lineups[deviceId] = entries
            glog("[Favorite] ch \(chNum) \(arrow) — UI updated, POST firing")
        } else {
            glog("[Favorite] ch \(chNum) \(arrow) — lineup missing for \(deviceId)", level: .warning)
        }
        pendingFavoriteToggles[deviceId, default: [:]][chNum] = newFav

        Task {
            do {
                try await hdhrManager.setFavorite(device: device, channel: channel, favorite: newFav)
                glog("[Favorite] ch \(chNum) \(arrow) — POST 200 OK")
            } catch {
                glog("[Favorite] ch \(chNum) \(arrow) — POST failed (\(error)), reverting", level: .error)
                if var entries = lineups[deviceId],
                   let idx = entries.firstIndex(where: { $0.GuideNumber == chNum }) {
                    entries[idx].Favorite = newFav ? 0 : 1
                    lineups[deviceId] = entries
                }
                pendingFavoriteToggles[deviceId]?.removeValue(forKey: chNum)
            }
        }
    }

    /// Called by fetchAllLineups after a fresh lineup arrives. Logs any channel whose
    /// actual Favorite value doesn't match what we optimistically set.
    private func reconcileFavorites(deviceId: String, freshLineup: [LineupEntry]) {
        guard let pending = pendingFavoriteToggles[deviceId], !pending.isEmpty else { return }
        for (chNum, expected) in pending {
            if let actual = freshLineup.first(where: { $0.GuideNumber == chNum }),
               actual.isFavorite != expected {
                glog("[Favorite] mismatch on reload ch \(chNum): expected \(expected), device says \(actual.isFavorite)", level: .warning)
            }
        }
        pendingFavoriteToggles.removeValue(forKey: deviceId)
    }

    func pauseShow(_ show: Show) {
        guard let i = shows.firstIndex(where: { $0.show_id == show.show_id }) else { return }
        glog("[\(show.show_title)] PAUSED manual")
        shows[i].show_paused = true; shows[i].show_fail_reason = "Manually paused"; saveConfig()
    }
    func resumeShow(_ show: Show) {
        guard let i = shows.firstIndex(where: { $0.show_id == show.show_id }) else { return }
        glog("[\(show.show_title)] RESUMED")
        shows[i].show_paused = false; shows[i].clearFailures(); saveConfig()
    }
    func deleteShow(_ show: Show) {
        glog("[Show] Deleted '\(show.show_title)'")
        recordingManager.stop(showId: show.show_id)
        VLCPlayerWindowManager.shared.closeIfPlayingURL(show.show_url)
        shows.removeAll { $0.show_id == show.show_id }
        saveConfig()
    }

    /// Shows a delete confirmation alert with the show's poster image (fetched async).
    /// Calls `then()` after deletion — use for dismiss() in EditShowView.
    func confirmAndDeleteShow(_ show: Show, then completion: @escaping () -> Void = {}) {
        Task {
            let imageURL: String?
            if show.show_use_seriesid {
                imageURL = nextGuideEpisode(for: show)?.entry.ImageURL
            } else {
                let entries = guideEntries(deviceId: show.hdhr_record, channelNum: show.show_channel)
                imageURL = entries.first { $0.Title == show.show_title }?.ImageURL
                    ?? entries.first?.ImageURL
            }
            var icon: NSImage? = nil
            if let urlStr = imageURL, let url = URL(string: urlStr),
               let (data, _) = try? await URLSession.shared.data(from: url) {
                icon = NSImage(data: data)
            }
            let alert = NSAlert()
            alert.messageText     = "Delete \"\(show.show_title)\"?"
            alert.informativeText = "This cannot be undone."
            if let icon { alert.icon = icon }
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            if alert.runModal() == .alertFirstButtonReturn {
                deleteShow(show)
                completion()
            }
        }
    }

    // MARK: - Maintenance actions (Settings → Maintenance panel)

    /// Re-run scheduleNextAir for every active SeriesID show using the current guide cache.
    func rescheduleAllSeries() async {
        let indices = shows.indices.filter { shows[$0].show_active && !shows[$0].show_paused && shows[$0].show_use_seriesid }
        for i in indices { await scheduleNextAir(index: i) }
        saveConfig()
    }

    /// Force a full guide reload (invalidate + re-fetch all devices).
    func refreshGuide() async { await refreshGuides() }

    /// Re-run device discovery seeded from known show URLs, same path as startup.
    func rediscoverDevices() async {
        await discoverDevices(knownHosts: knownHostsFromShows(), attempts: 5)
    }

    /// Zero out fail counts on every show without changing active/inactive state.
    func resetAllFailCounts() {
        for i in shows.indices { shows[i].clearFailures() }
        saveConfig()
    }

    /// Reactivate all paused/inactive shows and clear their fail counts.
    func reactivatePausedShows() {
        for i in shows.indices {
            if shows[i].show_paused { shows[i].show_paused = false }
            else if !shows[i].show_active { shows[i].show_active = true }
            shows[i].clearFailures()
        }
        saveConfig()
    }

    // MARK: - Utilities

    func refreshAll() {
        glog("[Guide] refreshAll() — triggering discovery + refreshGuides()")
        guideByDevice = [:]
        // Discovery first (updates device IPs), then refreshGuides() which invalidates and reloads.
        // Previously this called fetchAllGuides() directly AND set lastGuideRefresh = .distantPast,
        // causing the idle loop to ALSO call refreshGuides() concurrently — two loadAll calls,
        // the faster "skipped" one would return with 0 channels, and lastGuideRefresh was stamped
        // before the real data arrived, creating a persistent retry storm.
        Task { await discoverDevices(); await refreshGuides() }
    }

    func diskOK(for show: Show) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: show.posixRecordDir),
              let total = attrs[.systemSize] as? Double, let free = attrs[.systemFreeSize] as? Double,
              total > 0 else { return true }
        let minFreeBytes = config.Min_disk_free_gb * 1_073_741_824
        let freeGB = free / 1_073_741_824
        // Warn when within 2× the minimum threshold so there's time to act before recordings are skipped
        if free < minFreeBytes * 2 {
            glog("[\(show.show_title)] DISK LOW — \(String(format: "%.1f", freeGB)) GB free (threshold \(config.Min_disk_free_gb) GB)", level: .warning)
        }
        return ((total - free) / total * 100) < maxDiskPct && free > minFreeBytes
    }

    func notify(_ title: String, body: String, subtitle: String,
                categoryIdentifier: String = "", userInfo: [AnyHashable: Any] = [:]) {
        guard notifyPermission else { return }
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body
        if !subtitle.isEmpty { c.subtitle = subtitle }
        c.sound = .default
        if !categoryIdentifier.isEmpty { c.categoryIdentifier = categoryIdentifier }
        if !userInfo.isEmpty { c.userInfo = userInfo }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    func requestNotifyPermission() async {
        notifyPermission = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        let skipAction = UNNotificationAction(identifier: "SKIP_AIRING",    title: "Skip This Airing", options: [])
        let stopAction = UNNotificationAction(identifier: "STOP_RECORDING", title: "Stop Recording",    options: [.destructive])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: "upnext",            actions: [skipAction], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "recording.soon",    actions: [skipAction], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "recording.started", actions: [stopAction], intentIdentifiers: [], options: [])
        ])
        notificationDelegate.appState = self
        UNUserNotificationCenter.current().delegate = notificationDelegate
    }

    // MARK: - Discord

    private static let discordTimeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short; return f
    }()

    // Finds the guide entry matching show_next for a given show, used to enrich Discord embeds.
    private func guideEntryForShow(_ show: Show) -> GuideEntry? {
        guard let startDate = show.show_next else { return nil }
        let target = Int(startDate.timeIntervalSince1970)
        let entries = guideStore.entries(deviceId: show.hdhr_record, channelNum: show.show_channel,
                                         after: startDate.addingTimeInterval(-60))
        return entries.first { abs($0.StartTime - target) < 120 }
    }

    /// Sends a minimal test embed and returns true if the webhook responds with HTTP 2xx.
    func checkWebhookURL(_ url: String) async -> Bool {
        guard !url.isEmpty,
              let parsed = URL(string: url),
              let host = parsed.host,
              host.contains("discord") else { return false }
        var req = URLRequest(url: parsed, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let embed: [String: Any] = ["embeds": [["title": "hdhrVCRplus — Connection test ✓",
                                                 "description": "Webhook verified. Ready to send notifications.",
                                                 "color": 0x2ECC71]]]
        guard let body = try? JSONSerialization.data(withJSONObject: embed) else { return false }
        req.httpBody = body
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    // Builds the embed dict for a show event. Shared by discordShow and the async capturing path.
    private func buildDiscordShowEmbed(event: String, show: Show, color: Int,
                                       extra: [(name: String, value: String, inline: Bool)]) -> [String: Any] {
        let entry = guideEntryForShow(show)

        let channel = guideStore.channels(deviceId: show.hdhr_record)
                                .first { $0.GuideNumber == show.show_channel }

        var descLines: [String] = ["**\(show.show_title)**"]
        let epNum   = entry?.EpisodeNumber?.trimmingCharacters(in: .whitespaces) ?? ""
        let epTitle = entry?.EpisodeTitle?.trimmingCharacters(in: .whitespaces) ?? ""
        if !epNum.isEmpty || !epTitle.isEmpty {
            descLines.append([epNum, epTitle].filter { !$0.isEmpty }.joined(separator: " · "))
        }
        if let synopsis = entry?.Synopsis, !synopsis.isEmpty {
            let s = synopsis.count > 200 ? String(synopsis.prefix(200)) + "…" : synopsis
            descLines.append(s)
        }

        var fields: [[String: Any]] = [
            ["name": "Channel", "value": show.show_channel,   "inline": true],
            ["name": "Type",    "value": show.state.rawValue, "inline": true]
        ]
        if let start = show.show_next, let end = show.show_end {
            let range = "\(Self.discordTimeFmt.string(from: start)) – \(Self.discordTimeFmt.string(from: end))"
            fields.append(["name": "Time", "value": range, "inline": true])
        }
        for e in extra { fields.append(["name": e.name, "value": e.value, "inline": e.inline]) }

        let tags = entry?.Filter ?? (show.show_genre.isEmpty ? [] : [show.show_genre])
        if !tags.isEmpty {
            fields.append(["name": "Tags", "value": tags.map { "`\($0)`" }.joined(separator: " "), "inline": false])
        }

        var authorDict: [String: Any] = ["name": "CH \(show.show_channel)\(channel.map { " · \($0.GuideName)" } ?? "")"]
        if let iconURL = channel?.ImageURL, !iconURL.isEmpty { authorDict["icon_url"] = iconURL }

        var embed: [String: Any] = [
            "author":      authorDict,
            "title":       event,
            "description": descLines.joined(separator: "\n"),
            "color":       color,
            "fields":      fields,
            "footer":      ["text": "hdhr VCR  ·  \(show.hdhr_record)"]
        ]
        if !show.show_logo_url.isEmpty { embed["thumbnail"] = ["url": show.show_logo_url] }
        return embed
    }

    private func discordShow(_ event: String, show: Show, color: Int, enabled: Bool,
                             extra: [(name: String, value: String, inline: Bool)] = [],
                             webhookURL: String? = nil,
                             editMessageId: String? = nil) {
        let url = webhookURL ?? config.Discord_webhook_url
        glog("[Discord] discordShow \(event) enabled=\(enabled) urlEmpty=\(url.isEmpty) masterEnabled=\(config.Discord_enabled)")
        guard enabled, !url.isEmpty else { return }
        if webhookURL == nil { guard config.Discord_enabled else { return } }

        let embed = buildDiscordShowEmbed(event: event, show: show, color: color, extra: extra)
        if let msgId = editMessageId, !msgId.isEmpty {
            editDiscordEmbed(webhookURL: url, messageId: msgId, embed: embed)
        } else {
            sendDiscordEmbed(to: url, embed: embed)
        }
    }

    private func handleGuideLoadFailure(deviceId: String) {
        guideApiBackoff[deviceId, default: APIBackoff()].recordFailure()
        guard var backoff = guideApiBackoff[deviceId], !backoff.notifiedUser else { return }
        backoff.notifiedUser = true
        guideApiBackoff[deviceId] = backoff
        let mins = backoff.minutesUntilRetry
        notify("Guide Load Failed", body: deviceId, subtitle: "API error — retry in \(mins) min")
        discordError("Guide Load Failed", detail: "Device \(deviceId) — API error, retry in \(mins) min", color: 0x95A5A6, enabled: config.Discord_on_guide_error)
    }

    private func discordError(_ event: String, detail: String, color: Int = 0x95A5A6, enabled: Bool,
                              webhookURL: String? = nil) {
        let url = webhookURL ?? config.Discord_webhook_url
        guard enabled, !url.isEmpty else { return }
        if webhookURL == nil { guard config.Discord_enabled else { return } }
        let embed: [String: Any] = [
            "title":       event,
            "description": detail,
            "color":       color,
            "footer":      ["text": "hdhr VCR"]
        ]
        sendDiscordEmbed(to: url, embed: embed)
    }

    private static func formatFileSize(_ bytes: Int) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        let gb = mb / 1024
        if gb >= 1 { return String(format: "%.2f GB", gb) }
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }

    func testDiscordEvent(_ eventType: String, webhookURL: String) {
        guard !webhookURL.isEmpty else { return }
        let testShow = recordingShows.first ?? activeShows.first ?? shows.first
        switch eventType {
        case "start":
            if let show = testShow { discordShow("🔴 Recording Started",  show: show, color: 0x2ECC71, enabled: true, webhookURL: webhookURL) }
        case "complete":
            if let show = testShow { discordShow("✅ Recording Complete", show: show, color: 0x3498DB, enabled: true,
                                                  extra: [("Format", "TS", true), ("File Size", "2.34 GB", true)], webhookURL: webhookURL) }
        case "failed":
            if let show = testShow { discordShow("❌ Recording Failed",   show: show, color: 0xE74C3C, enabled: true,
                                                  extra: [("Reason", "curl error 6 — could not resolve host", false)], webhookURL: webhookURL) }
        case "paused":
            if let show = testShow { discordShow("⏸ Recording Paused",   show: show, color: 0xE67E22, enabled: true,
                                                  extra: [("Reason", "Max failures reached", false)], webhookURL: webhookURL) }
        case "skipped":
            if let show = testShow { discordShow("💾 Recording Skipped",  show: show, color: 0xE67E22, enabled: true,
                                                  extra: [("Reason", "Only 4 GB free — limit: \(Int(config.Min_disk_free_gb)) GB", false)], webhookURL: webhookURL) }
        case "conflict":
            if let show = testShow { discordShow("⚠️ Tuner Conflict",     show: show, color: 0xF1C40F, enabled: true, webhookURL: webhookURL) }
        case "show_added":
            if let show = testShow { discordShow("✅ Show Added",          show: show, color: 0x1ABC9C, enabled: true, webhookURL: webhookURL) }
        case "upnext":
            if let show = testShow { discordShow("🔔 Up Next",            show: show, color: 0x9B59B6, enabled: true,
                                                  extra: [("Starts In", "\(Int(config.Notify_upnext)) min", true)], webhookURL: webhookURL) }
        case "soon":
            if let show = testShow { discordShow("⏱ Recording Soon",     show: show, color: 0x9B59B6, enabled: true,
                                                  extra: [("Starts In", "\(Int(config.Notify_recording)) min", true)], webhookURL: webhookURL) }
        case "guide_error":
            discordError("🚫 Guide Load Failed",
                         detail: "Test — guide could not be fetched for device \(devices.first?.DeviceID ?? "unknown")",
                         color: 0x95A5A6, enabled: true, webhookURL: webhookURL)
        default: break
        }
    }

    // Static — shortTime is called per notification and per scheduled menu render
    private static let shortTimeFormatter: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; return f
    }()

    private static let completionDateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short; return f
    }()

    func shortTime(_ date: Date?) -> String {
        guard let d = date else { return "?" }
        return Self.shortTimeFormatter.string(from: d)
    }

    func watchInApp(url: String, title: String, deviceId: String? = nil, transcode: String? = nil) {
        guard VLCBridge.shared.isAvailable else { return }
        let device = devices.first { $0.DeviceID == (deviceId ?? "") } ?? devices.first
        guard let device else { return }
        let profile = (transcode ?? config.Default_transcode).lowercased().trimmingCharacters(in: .whitespaces)
        let streamURL = (profile.isEmpty || profile == "none") ? url : "\(url)?transcode=\(profile)"
        let mgr = VLCPlayerWindowManager.shared

        Task {
            // If this exact channel is already playing, just surface the window — don't restart
            // the stream or mute. Re-opening the same channel from WatchNow while it's playing
            // would otherwise call setVolume(0) in mgr.open() with no posterHidden reset, leaving
            // the user with no audio and no Start button to recover from it.
            let rawBase = url.components(separatedBy: "?").first ?? url
            let alreadyPlaying = mgr.currentDeviceID == device.DeviceID
                && (VLCBridge.shared.currentURL?.components(separatedBy: "?").first ?? "") == rawBase
            if alreadyPlaying { mgr.focus(); return }

            // Switching channels in an already-open player on this device reuses the same slot —
            // skip the availability check so we don't block a legal channel switch.
            if mgr.currentDeviceID != device.DeviceID {
                if let statusURL = URL(string: device.statusURL),
                   let (data, _) = try? await URLSession.shared.data(from: statusURL),
                   let tuners = try? JSONDecoder().decode([DeviceTunerInfo].self, from: data) {
                    let tunerCount = device.TunerCount ?? 2
                    let active = tuners.filter { $0.VctNumber != nil }.count
                    if active >= tunerCount {
                        let alert = NSAlert()
                        alert.messageText = "No Tuner Available"
                        alert.informativeText = "All \(tunerCount) tuner\(tunerCount == 1 ? "" : "s") on \(device.DeviceID) are in use. Stop a recording or close another stream to free up a tuner."
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "OK")
                        alert.runModal()
                        return
                    }
                }
            }
            vlcCurrentURL = url
            mgr.open(url: streamURL, title: title, device: device, appState: self)
            refreshTunerOccupancy()
        }
    }

    func watchInVLC(url: String, transcode: String? = nil, deviceId: String? = nil) {
        let profile = (transcode ?? config.Default_transcode).lowercased().trimmingCharacters(in: .whitespaces)
        let raw = profile.isEmpty || profile == "none" ? url : "\(url)?transcode=\(profile)"
        guard config.Watch_in_VLC,
              let streamURL = URL(string: raw) else { return }
        let vlcPath = "/Applications/VLC.app"
        guard FileManager.default.fileExists(atPath: vlcPath) else { return }
        let vlcApp = URL(fileURLWithPath: vlcPath) // URL(fileURLWithPath:) handles spaces/special chars correctly
        let device = devices.first { $0.DeviceID == (deviceId ?? "") }
        Task {
            if let device,
               let statusURL = URL(string: device.statusURL),
               let (data, _) = try? await URLSession.shared.data(from: statusURL),
               let tuners = try? JSONDecoder().decode([DeviceTunerInfo].self, from: data) {
                let tunerCount = device.TunerCount ?? 2
                let active = tuners.filter { $0.VctNumber != nil }.count
                if active >= tunerCount {
                    let alert = NSAlert()
                    alert.messageText = "No Tuner Available"
                    alert.informativeText = "All \(tunerCount) tuner\(tunerCount == 1 ? "" : "s") on \(device.DeviceID) are in use. Stop a recording or close another stream to free up a tuner."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                    return
                }
            }
            NSWorkspace.shared.open([streamURL], withApplicationAt: vlcApp,
                                    configuration: .init()) { _, _ in }
        }
    }

    // MARK: - Tuner signal status

    /// Polls every device's /status.json immediately after any tuner-affecting event
    /// (recording start/stop, VLC open/close/channel-switch) so the menu header stays current.
    func refreshTunerOccupancy() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)   // 1.5s — let device register the change
            for device in devices { await fetchDeviceStatus(for: device) }
        }
    }

    /// Fetches /status.json once per device, updates occupancy for the menu header, then
    /// fetches /tunerN/vstatus for each recording show on that device using the tuner index
    /// from the status response — O(1) vstatus calls per show instead of O(tunerCount).
    private func fetchDeviceStatus(for device: HDHRDevice) async {
        guard let url = URL(string: device.statusURL),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let tuners = try? JSONDecoder().decode([DeviceTunerInfo].self, from: data)
        else { return }

        deviceTunerOccupancy[device.DeviceID] = tuners

        let active   = tuners.filter { $0.VctNumber != nil }.count
        let recCount = recordingShows.filter { $0.hdhr_record == device.DeviceID }.count
        let vlcOpen  = VLCPlayerWindowManager.shared.currentDeviceID == device.DeviceID ? 1 : 0
        glog("[TunerAudit] \(device.DeviceID): \(active)/\(device.TunerCount ?? 0) active  rec=\(recCount) vlc=\(vlcOpen)")

        for show in recordingShows where show.hdhr_record == device.DeviceID {
            // Prefer tuner whose VctNumber matches the show's channel; fall back to any locked tuner.
            // VctNumber format (e.g. "5.1") should match GuideNumber, but device firmware may differ.
            let match = tuners.first(where: { $0.VctNumber == show.show_channel })
                     ?? tuners.first(where: { $0.VctNumber != nil })
            guard let match,
                  let idx = Int(match.Resource.dropFirst(5))   // "tuner0" → 0
            else { continue }
            guard let vsURL = URL(string: "http://\(device.LocalIP)/tuner\(idx)/vstatus"),
                  let (vsData, _) = try? await URLSession.shared.data(from: vsURL),
                  let text = String(data: vsData, encoding: .utf8)
            else { continue }

            var kv: [String: String] = [:]
            for token in text.split(separator: " ") {
                let parts = token.split(separator: "=", maxSplits: 1)
                if parts.count == 2 { kv[String(parts[0])] = String(parts[1]) }
            }
            let lock = kv["lock"] ?? "none"
            guard lock != "none" else { continue }
            tunerStatus[show.show_id] = TunerStatus(
                signalStrength: Int(kv["ss"]  ?? "0") ?? 0,
                signalQuality:  Int(kv["snq"] ?? "0") ?? 0,
                lockType:       lock,
                bitrateMbps:    Double(kv["bps"] ?? "0").map { $0 / 1_000_000 } ?? 0
            )
        }
    }

    // MARK: - Conflict detection

    func hasConflict(for show: Show) -> Bool {
        guard let next = show.show_next,
              let end  = show.show_end,
              let device = devices.first(where: { $0.DeviceID == show.hdhr_record }),
              let tunerCount = device.TunerCount,
              tunerCount > 0 else { return false }
        let overlapping = shows.filter { other in
            guard other.show_active, !other.show_paused,
                  other.show_id != show.show_id,
                  other.hdhr_record == show.hdhr_record,
                  let oNext = other.show_next,
                  let oEnd  = other.show_end
            else { return false }
            return oNext < end && oEnd > next
        }
        return overlapping.count >= tunerCount
    }

    func quit() {
        guard isRecording else {
            VLCBridge.shared.releasePlayer(); recordingManager.stopAll(); saveConfig(); NSApplication.shared.terminate(nil); return
        }
        let alert = NSAlert()
        alert.messageText = "Recordings in progress"
        let list = recordingShows.map { "• \($0.show_title) (Channel \($0.show_channel))" }.joined(separator: "\n")
        alert.informativeText = "These recordings will be stopped:\n\n\(list)\n\nChoose \"Keep Recording\" to exit while recordings continue — relaunch the app to reconnect."
        alert.addButton(withTitle: "Keep Recording & Quit") // default (Return key) — caffeinate+curl survive as orphans; reattachRecordings() reconnects on next launch
        alert.addButton(withTitle: "Stop Recordings & Quit")
        alert.addButton(withTitle: "Go Back")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:  // keep recordings running, quit
            VLCBridge.shared.releasePlayer(); saveConfig(); NSApplication.shared.terminate(nil)
        case .alertSecondButtonReturn: // stop all, then quit
            VLCBridge.shared.releasePlayer(); recordingManager.stopAll(); saveConfig(); NSApplication.shared.terminate(nil)
        default:                       // Go Back — cancel
            break
        }
    }
}

// MARK: - JIT Warmup Placeholder

/// Minimal SwiftUI view used only at startup to pre-warm the JIT compiler for menu rendering.
/// Uses the same primitive types as MenuContent (Text, Button, Menu, Divider) without accessing
/// any live app state, so layout cost is O(1) rather than O(shows × guide entries).
private struct MenuJITPlaceholder: View {
    var body: some View {
        Text("").font(.headline)
        Text("").foregroundStyle(Color.secondary)
        Button("") {}
        Menu("") { Text(""); Divider(); Button("") {} }
        Divider()
        Text("").font(.footnote).foregroundStyle(Color.secondary)
    }
}

// MARK: - Notification Action Delegate

// UNUserNotificationCenterDelegate requires NSObject — use a small forwarder rather than making AppState inherit NSObject.
final class NotificationActionDelegate: NSObject, UNUserNotificationCenterDelegate {
    weak var appState: AppState?

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let showId = response.notification.request.content.userInfo["show_id"] as? String ?? ""
        guard !showId.isEmpty else { return }
        switch response.actionIdentifier {
        case "SKIP_AIRING":    await appState?.skipRecording(showId: showId)
        case "STOP_RECORDING": await MainActor.run { appState?.stopRecording(showId: showId) }
        default: break
        }
    }
}
