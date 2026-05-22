import Foundation
import UserNotifications
import AppKit
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var shows: [Show] = []
    @Published var devices: [HDHRDevice] = []
    @Published var lineups: [String: [LineupEntry]] = [:]       // deviceId → channel lineup
    @Published var guideByDevice: [String: [GuideChannel]] = [:] // mirror of guideStore.channelsByDevice
    @Published var guideRevision: Int = 0                        // increments each time guide data successfully loads
    @Published var config = AppConfig()
    @Published var statusMessage = "Starting…"
    @Published var notifyPermission = false
    @Published var isStartingUp: Bool = true

    @Published var editingShowId: String? = nil

    var isRecording: Bool      { shows.contains { $0.show_recording } }
    var recordingShows: [Show] { shows.filter { $0.show_recording && ($0.show_end.date ?? .distantPast) > Date() } }
    var activeShows: [Show]    { shows.filter { $0.show_active && !$0.show_recording }
                                      .sorted { ($0.show_next.date ?? .distantFuture) < ($1.show_next.date ?? .distantFuture) } }
    var inactiveShows: [Show]  { shows.filter { !$0.show_active } }

    var nextShowMinutes: Double? {
        activeShows
            .compactMap { $0.show_next.date.map { $0.timeIntervalSince(Date()) / 60 } }
            .filter { $0 > 0 }
            .min()
    }

    let configManager    = ConfigManager()
    let hdhrManager      = HDHRManager()
    let recordingManager = RecordingManager()
    let guideStore       = GuideStore()

    private var idleTimer: Timer?
    private var lastGuideRefresh: Date = .distantPast
    private var lastDeviceProbe: Date  = .distantPast
    private var failThreshold: Int { config.Fail_count_setting }
    private let maxDiskPct: Double = 93

    init() { Task { await startup() } }

    // MARK: - Startup

    func startup() async {
        // 1. Config first — shows visible in menu immediately
        loadConfig()
        guideStore.verbose = config.Verbose_curl
        glog("[Startup] config loaded — \(shows.count) shows, GuideHours=\(config.GuideHours)")

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

        // Pre-warm SwiftUI's JIT compiler for MenuContent so first menu click has no delay.
        // Creating an NSHostingView forces a full layout pass; the view is discarded immediately.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            let v = NSHostingView(rootView: MenuContent().environmentObject(self))
            v.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
            _ = v.fittingSize
        }
    }

    func logGuide(_ msg: String) { glog(msg) }

    // Static — ISO8601DateFormatter is expensive; single MainActor caller makes static safe
    private static let logFormatter = ISO8601DateFormatter()

    private func glog(_ msg: String) {
        print(msg)
        let ts = Self.logFormatter.string(from: Date())
        let line = "[\(ts)] \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        let path = GuideStore.guideLogPath
        if FileManager.default.fileExists(atPath: path) {
            if let fh = FileHandle(forWritingAtPath: path) {
                fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
            }
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }

    /// Extract unique device IPs from saved show stream URLs so discovery can try them directly.
    private func knownHostsFromShows() -> [String] {
        var seen = Set<String>()
        return shows.compactMap { show -> String? in
            guard !show.show_url.isEmpty,
                  let host = URL(string: show.show_url)?.host,
                  !host.isEmpty,
                  seen.insert(host).inserted else { return nil }
            return host
        }
    }

    func loadConfig() {
        guard let file = configManager.load() else { statusMessage = "No config found"; return }
        config = file.config
        let allShows = file.the_shows.map { var s = $0; s.show_recording = false; return s }
        let filtered = allShows.filter { !($0.state == .single && !$0.show_active) }
        shows = filtered
        if filtered.count < allShows.count { saveConfig() }
        statusMessage = "\(shows.count) shows loaded"
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
                  line.contains("hdhr_VCR_swift") else { continue }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let cols    = trimmed.components(separatedBy: .whitespaces)
            guard let pidStr = cols.first, let pid = Int32(pidStr) else { continue }

            guard let idRange = line.range(of: "show_id:") else { continue }
            let tail   = String(line[idRange.upperBound...])
            let showId = String(tail.prefix(while: { !$0.isWhitespace && $0 != "'" && $0 != "\"" }))
            guard !showId.isEmpty else { continue }

            guard let i = shows.firstIndex(where: { $0.show_id == showId }),
                  let endDate = shows[i].show_end.date, endDate > now else { continue }

            shows[i].show_recording = true
            recordingManager.reattach(showId: showId, pid: pid)
            print("[Startup] Reattached '\(shows[i].show_title)' pid=\(pid) ends \(endDate)")
        }
    }

    func saveConfig() {
        try? configManager.save(ConfigFile(config: config, the_shows: shows))
    }

    func discoverDevices(knownHosts: [String] = [], attempts: Int = 3) async {
        for attempt in 1...max(1, attempts) {
            statusMessage = attempt == 1 ? "Searching for tuners…" : "Searching for tuners (\(attempt)/\(attempts))…"
            do {
                let found = try await hdhrManager.discoverDevices(knownHosts: knownHosts)
                devices = found
                await fetchAllLineups(for: found)
                statusMessage = "\(devices.count) tuner(s) found"
                return
            } catch {
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
        guard let found = try? await hdhrManager.discoverDevices(knownHosts: knownHostsFromShows()) else { return }
        let existingIDs = Set(devices.map { $0.DeviceID })
        let newDevices  = found.filter { !existingIDs.contains($0.DeviceID) }
        guard !newDevices.isEmpty else { return }
        glog("[DeviceProbe] \(newDevices.count) new tuner(s): \(newDevices.map { $0.DeviceID }.joined(separator: ", "))")
        devices.append(contentsOf: newDevices)
        await fetchAllLineups(for: newDevices)
        await guideStore.loadAll(devices: newDevices, hours: config.GuideHours)
        guideByDevice = guideStore.channelsByDevice
    }

    /// Fetch lineup for every device in parallel; stores results in `lineups[deviceID]`.
    /// After all lineups are fetched, checks whether any show's stored stream URL still uses
    /// a stale device IP and updates it from the fresh lineup data.
    private func fetchAllLineups(for devices: [HDHRDevice]) async {
        await withTaskGroup(of: (String, [LineupEntry]?).self) { group in
            for device in devices {
                group.addTask {
                    let lu = try? await self.hdhrManager.fetchLineup(for: device)
                    return (device.DeviceID, lu)
                }
            }
            for await (id, lu) in group {
                if let lu { lineups[id] = lu }
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
        for i in shows.indices {
            let show = shows[i]
            guard !show.show_url.isEmpty,
                  let device = devices.first(where: { $0.DeviceID == show.hdhr_record }),
                  let storedHost = URL(string: show.show_url)?.host,
                  storedHost != device.LocalIP,           // IP has changed since URL was saved
                  let lineup = lineups[show.hdhr_record],
                  let freshURL = hdhrManager.streamURL(for: show.show_channel, lineup: lineup)
            else { continue }

            shows[i].show_url = freshURL
            dirty = true
            print("[AppState] show_url updated for '\(show.show_title)': \(storedHost) → \(device.LocalIP)")
        }
        if dirty { saveConfig() }
    }

    // MARK: - Guide cache

    /// Fetch guide for all known devices at startup (in parallel).
    func fetchAllGuides() async {
        guard !devices.isEmpty else { return }
        statusMessage = "Loading guide…"
        guideStore.verbose = config.Verbose_curl
        await guideStore.loadAll(devices: devices, hours: config.GuideHours)
        guideByDevice = guideStore.channelsByDevice
        // Only stamp the refresh time if at least one device actually loaded channels.
        // A failed load must NOT reset lastGuideRefresh — the idle loop's ensureGuideLoaded
        // retries for empty-channel devices every tick, so skipping the stamp lets the
        // periodic refresh also retry at the normal interval.
        let loadedCount = guideByDevice.values.reduce(0) { $0 + $1.count }
        if loadedCount > 0 { lastGuideRefresh = Date(); guideRevision += 1 }
        statusMessage = "\(shows.count) show(s) — \(devices.count) tuner(s) ready"
        let allChannels = guideByDevice.values.flatMap { $0 }
        Task { await prefetchChannelIcons(allChannels) }
    }

    /// Refresh lineup + guide for all devices (called periodically from idleLoop).
    private func refreshGuides() async {
        guideStore.invalidateAll()
        await fetchAllLineups(for: devices)
        guideStore.verbose = config.Verbose_curl
        await guideStore.loadAll(devices: devices, hours: config.GuideHours)
        guideByDevice = guideStore.channelsByDevice
        lastGuideRefresh = Date()
        print("[Guide] Refresh complete")
        let allChannels = guideByDevice.values.flatMap { $0 }
        Task { await prefetchChannelIcons(allChannels) }
    }

    /// Trigger a guide load for a single device (idleLoop / menu fallback).
    func ensureGuideLoaded(for deviceId: String) {
        guard !guideStore.isLoading(deviceId: deviceId),
              guideStore.channels(deviceId: deviceId).isEmpty,
              let device = devices.first(where: { $0.DeviceID == deviceId }) else { return }
        Task {
            guideStore.verbose = config.Verbose_curl
            await guideStore.load(for: device, hours: config.GuideHours)
            guideByDevice = guideStore.channelsByDevice
            await prefetchChannelIcons(guideStore.channels(deviceId: deviceId))
        }
    }

    /// Download any channel icons not already on disk; update menu bar status while working.
    private func prefetchChannelIcons(_ channels: [GuideChannel]) async {
        let urls = Array(Set(channels.compactMap { $0.ImageURL }.filter { !$0.isEmpty }))
        guard !urls.isEmpty else { return }
        let needed = await ChannelIconCache.shared.countMissing(in: urls)
        guard needed > 0 else { return }
        statusMessage = "Caching \(needed) channel icon(s)…"
        await withTaskGroup(of: Void.self) { group in
            for url in urls {
                group.addTask { _ = await ChannelIconCache.shared.image(for: url) }
            }
        }
        statusMessage = "\(shows.count) show(s) — \(devices.count) tuner(s) ready"
    }

    func isGuideLoading(for deviceId: String) -> Bool {
        guideStore.isLoading(deviceId: deviceId)
    }

    /// Guide entries for a device+channel still airing or upcoming within GuideHours.
    func guideEntries(deviceId: String, channelNum: String) -> [GuideEntry] {
        guideStore.entries(deviceId: deviceId, channelNum: channelNum)
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
        show.show_next      = EpochDate(entry.startDate)
        show.show_end       = EpochDate(entry.endDate)
        show.show_seriesid  = entry.SeriesID ?? ""
        show.show_logo_url  = entry.ImageURL ?? ""
        show.show_url       = channel.URL ?? ""
        show.show_genre     = entry.firstGenre ?? ""
        show.show_dir       = folder.path
        show.show_temp_dir  = folder.path

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

        addShow(show)
        notify("Show Added", body: show.show_title, subtitle: type.rawValue)
    }

    /// For SeriesID shows, find the earliest airing episode and update show_next/show_end/show_channel/show_url.
    /// Checks currently-airing first (so show_next may be in the past — idle loop records the remaining portion),
    /// then the next future episode. Falls back silently if neither is found (selected entry's times stay).
    private func resolveSeriesAir(show: inout Show, device: HDHRDevice, isAll: Bool, channel: LineupEntry) {
        let chFilter  = isAll ? nil : channel.GuideNumber
        let devFilter = isAll ? nil : device.DeviceID
        let now       = Date()

        // Helper: apply a SeriesMatch to the show — uses m.deviceId for lineup lookup so
        // SeriesID(All) works correctly when the episode is on a different device than browsed.
        func apply(_ m: GuideStore.SeriesMatch) {
            show.show_next    = EpochDate(m.entry.startDate)
            show.show_end     = EpochDate(m.entry.endDate)
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

    /// The default recording folder: UserDefaults override → config Hdhr_setup_folder → ~/Documents/hdhr_videos.
    var defaultSaveDir: URL {
        let stored = UserDefaults.standard.string(forKey: "defaultSaveDirectory") ?? ""
        if !stored.isEmpty { return URL(fileURLWithPath: stored) }
        if !config.Hdhr_setup_folder.isEmpty { return URL(fileURLWithPath: config.Hdhr_setup_folder) }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/hdhr_videos")
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
        for i in shows.indices {
            let show = shows[i]
            guard show.show_active else { continue }
            let nextDate = show.show_next.date ?? .distantFuture
            let endDate  = show.show_end.date  ?? .distantPast

            let minutesAway = nextDate.timeIntervalSince(now) / 60

            // "Up Next" notification — fires once at Notify_upnext minutes before
            let upNextDue = (show.notify_upnext_time.date ?? .distantPast) <= now
            if !show.show_recording, upNextDue, minutesAway > 0, minutesAway <= config.Notify_upnext {
                notify("Up Next", body: show.show_title, subtitle: "Starts in \(Int(minutesAway)) min on ch \(show.show_channel)")
                shows[i].notify_upnext_time = EpochDate(now.addingTimeInterval(config.Notify_upnext * 60))
                dirty = true
            }

            // "Recording About to Start" notification — fires once at Notify_recording minutes before
            let recNotifyDue = (show.notify_recording_time.date ?? .distantPast) <= now
            if !show.show_recording, recNotifyDue, minutesAway > 0, minutesAway <= config.Notify_recording {
                notify("Recording Soon", body: show.show_title, subtitle: "Starts in \(Int(minutesAway)) min on ch \(show.show_channel)")
                shows[i].notify_recording_time = EpochDate(now.addingTimeInterval(config.Notify_recording * 60))
                dirty = true
            }

            if !show.show_recording, nextDate <= now + 10, endDate > now {
                await startRecording(index: i); dirty = true
            }
            if show.show_recording, endDate <= now {
                await stopRecording(index: i, natural: true); dirty = true
            }
            if show.show_recording, endDate > now, !recordingManager.isRunning(showId: show.show_id) {
                shows[i].show_recording = false; shows[i].show_fail_count += 1
                shows[i].show_fail_reason = "curl exited unexpectedly"
                notify("Recording Failed", body: show.show_title, subtitle: "curl exited unexpectedly")
                dirty = true
            }
        }
        if dirty { saveConfig() }
    }

    // MARK: - Recording

    func startRecording(index: Int) async {
        var show = shows[index]
        // Enforce tuner limit: skip if all slots on this device are already occupied
        if let device = devices.first(where: { $0.DeviceID == show.hdhr_record }),
           let tunerCount = device.TunerCount {
            let active = recordingShows.filter { $0.hdhr_record == show.hdhr_record }.count
            if active >= tunerCount {
                glog("[\(show.show_title)] TUNER FULL \(show.hdhr_record): \(active)/\(tunerCount) — skipping start")
                return
            }
        }
        if show.show_url.isEmpty {
            if let lu = lineups[show.hdhr_record],
               let url = hdhrManager.streamURL(for: show.show_channel, lineup: lu) {
                shows[index].show_url = url; show.show_url = url
            } else {
                shows[index].show_fail_count += 1; shows[index].show_fail_reason = "No stream URL"; return
            }
        }
        guard show.show_fail_count < failThreshold else {
            shows[index].show_active = false
            notify("Recording Paused", body: show.show_title, subtitle: "Failed \(failThreshold)× — deactivated"); return
        }
        guard diskOK(for: show) else {
            shows[index].show_fail_count += 1; shows[index].show_fail_reason = "Disk too full"
            notify("Recording Skipped", body: show.show_title, subtitle: "Disk over \(Int(maxDiskPct))%"); return
        }
        let path = show.outputPath(date: show.show_next.date ?? Date())
        var endDate = show.show_end.date ?? Date().addingTimeInterval(Double(show.show_length) * 60)
        // Bonus Time: extend recording past the guide end for sports shows so overtime isn't cut off
        if config.Sports_padding_enabled && show.show_genre.lowercased().contains("sports") {
            endDate = endDate.addingTimeInterval(Double(config.Sports_padding_minutes) * 60)
            // Update stored show_end so the idle loop's natural-stop check uses the padded time
            shows[index].show_end = EpochDate(endDate)
        }
        let remainingSecs = max(60, Int(endDate.timeIntervalSince(Date())))
        recordingManager.start(showId: show.show_id, url: show.show_url,
                               outputPath: path, durationSeconds: remainingSecs,
                               transcode: show.show_transcode, showEnd: endDate,
                               verbose: config.Verbose_curl)
        shows[index].show_recording = true; shows[index].show_recording_path = path
        shows[index].show_fail_count = max(0, show.show_fail_count - 1)
        // Stamp notify_recording_time so the "Recording Soon" pre-notification won't re-fire
        shows[index].notify_recording_time = EpochDate(Date().addingTimeInterval(config.Notify_recording * 60))
        notify("Recording Started", body: show.show_title, subtitle: "ch \(show.show_channel) — ends \(shortTime(show.show_end.date))")
    }

    func stopRecording(index: Int, natural: Bool) async {
        let show = shows[index]
        recordingManager.stop(showId: show.show_id)
        shows[index].show_recording = false
        shows[index].show_last = EpochDate(Date())

        if !natural {
            // Manual stop: deactivate the show so it moves to Paused in the menu
            // and won't reschedule automatically — user can reactivate from Paused section
            shows[index].show_active = false
            shows[index].show_fail_reason = "Manually stopped"
            saveConfig()
            return
        }

        if natural {
            // Verify the output file was actually created and is non-empty
            let path = show.show_recording_path
            if !path.isEmpty {
                let attrs = try? FileManager.default.attributesOfItem(atPath: path)
                let size = attrs?[.size] as? Int ?? 0
                if size == 0 {
                    shows[index].show_fail_count += 1
                    shows[index].show_fail_reason = "Output file missing or empty"
                    notify("Recording Failed", body: show.show_title, subtitle: "File not written — check disk space and URL")
                    await scheduleNextAir(index: index)
                    return
                }
            }
            await scheduleNextAir(index: index)
            let completedShow = shows[index]
            if !completedShow.show_active {
                notify("Recording Complete", body: show.show_title, subtitle: "Single episode recorded — show deactivated")
            } else if let next = completedShow.show_next.date {
                let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short
                notify("Recording Complete", body: show.show_title, subtitle: "Next: \(f.string(from: next))")
            } else {
                notify("Recording Complete", body: show.show_title, subtitle: "")
            }
        }
    }

    func stopRecording(showId: String) {
        guard let i = shows.firstIndex(where: { $0.show_id == showId }) else { return }
        Task { await stopRecording(index: i, natural: false) }
    }

    // MARK: - Next-air scheduling

    func scheduleNextAir(index: Int) async {
        guard index < shows.count else { return }
        let show = shows[index]
        switch show.state {
        case .single:
            shows[index].show_active = false
        case .dateTime:
            if let next = nextDateTime(for: show) {
                shows[index].show_next = EpochDate(next)
                shows[index].show_end  = EpochDate(next.addingTimeInterval(Double(show.show_length) * 60))
            } else {
                // No matching air day found (show_air_date is empty or invalid) — pause rather than loop forever
                shows[index].show_active = false
                shows[index].show_fail_reason = "No air days configured"
                notify("Show Paused", body: show.show_title, subtitle: "No air days configured — edit show to fix")
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
                    shows[index].show_next    = EpochDate(match.entry.startDate)
                    shows[index].show_end     = EpochDate(match.entry.endDate)
                    shows[index].show_channel = match.channelNum
                    shows[index].show_genre   = match.entry.firstGenre ?? ""
                    shows[index].hdhr_record  = match.deviceId
                    if let url = hdhrManager.streamURL(for: match.channelNum, lineup: lineups[match.deviceId] ?? []) {
                        shows[index].show_url = url
                    }
                }
                if let match = guideStore.currentEpisode(seriesID: show.show_seriesid, channelNum: chFilter, deviceId: devFilter, at: now) {
                    applyMatch(match); return
                }
                if let match = guideStore.nextEpisode(seriesID: show.show_seriesid,
                                                      channelNum: chFilter,
                                                      deviceId: devFilter) {
                    applyMatch(match); return
                }
                // Fallback: title match — handles guide entries where SeriesID is absent.
                if let ch = chFilter, let dev = devFilter {
                    if let match = guideStore.currentEntryByTitle(show.show_title, channelNum: ch, deviceId: dev, at: now) {
                        applyMatch(match); return
                    }
                    if let match = guideStore.nextEntryByTitle(show.show_title, channelNum: ch, deviceId: dev, after: now) {
                        applyMatch(match); return
                    }
                }
            }
            shows[index].show_next = EpochDate(Date().addingTimeInterval(Double(config.Series_scan_retry_hours) * 3600))
        }
    }

    func nextDateTime(for show: Show) -> Date? {
        let dayMap = ["Sunday":1,"Monday":2,"Tuesday":3,"Wednesday":4,"Thursday":5,"Friday":6,"Saturday":7]
        let cal = Calendar.current
        let h = Int(show.show_time)
        let m = Int((show.show_time.truncatingRemainder(dividingBy: 1)) * 60)
        for offset in 1...7 {
            let candidate = Date().addingTimeInterval(Double(offset) * 86400)
            let weekday = cal.component(.weekday, from: candidate)
            let dayName = dayMap.first { $0.value == weekday }?.key ?? ""
            guard show.show_air_date.contains(dayName) else { continue }
            var comps = cal.dateComponents([.year, .month, .day], from: candidate)
            comps.hour = h; comps.minute = m; comps.second = 0
            return cal.date(from: comps)
        }
        return nil
    }

    // MARK: - Show CRUD

    func addShow(_ show: Show)    { guard !shows.contains(where: { $0.show_id == show.show_id }) else { return }; shows.append(show); saveConfig() }
    func updateShow(_ show: Show) {
        guard let i = shows.firstIndex(where: { $0.show_id == show.show_id }) else { return }
        shows[i] = show; saveConfig()
    }
    func toggleActive(_ show: Show) {
        guard let i = shows.firstIndex(where: { $0.show_id == show.show_id }) else { return }
        shows[i].show_active.toggle(); shows[i].show_fail_count = 0; shows[i].show_fail_reason = ""; saveConfig()
    }
    func deleteShow(_ show: Show) { recordingManager.stop(showId: show.show_id); shows.removeAll { $0.show_id == show.show_id }; saveConfig() }

    // MARK: - Maintenance actions (Settings → Maintenance panel)

    /// Re-run scheduleNextAir for every active SeriesID show using the current guide cache.
    func rescheduleAllSeries() async {
        let indices = shows.indices.filter { shows[$0].show_active && shows[$0].show_use_seriesid }
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
        for i in shows.indices { shows[i].show_fail_count = 0; shows[i].show_fail_reason = "" }
        saveConfig()
    }

    /// Reactivate all paused shows and clear their fail counts.
    func reactivatePausedShows() {
        for i in shows.indices where !shows[i].show_active {
            shows[i].show_active = true; shows[i].show_fail_count = 0; shows[i].show_fail_reason = ""
        }
        saveConfig()
    }

    // MARK: - Utilities

    func refreshAll() {
        guideStore.invalidateAll()
        guideByDevice = [:]
        lastGuideRefresh = .distantPast
        Task { await discoverDevices(); await fetchAllGuides() }
    }

    func diskOK(for show: Show) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: show.posixRecordDir),
              let total = attrs[.systemSize] as? Double, let free = attrs[.systemFreeSize] as? Double,
              total > 0 else { return true }
        let minFreeBytes = config.Min_disk_free_gb * 1_073_741_824
        return ((total - free) / total * 100) < maxDiskPct && free > minFreeBytes
    }

    func notify(_ title: String, body: String, subtitle: String) {
        guard notifyPermission else { return }
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body
        if !subtitle.isEmpty { c.subtitle = subtitle }
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    func requestNotifyPermission() async {
        notifyPermission = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    // Static — shortTime is called per notification and per scheduled menu render
    private static let shortTimeFormatter: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; return f
    }()

    func shortTime(_ date: Date?) -> String {
        guard let d = date else { return "?" }
        return Self.shortTimeFormatter.string(from: d)
    }

    func watchInVLC(url: String) {
        guard config.Watch_in_VLC,
              let streamURL = URL(string: url) else { return }
        let vlcPath = "/Applications/VLC.app"
        guard FileManager.default.fileExists(atPath: vlcPath),
              let vlcApp = URL(string: "file://\(vlcPath)") else { return }
        NSWorkspace.shared.open([streamURL], withApplicationAt: vlcApp,
                                configuration: .init()) { _, _ in }
    }

    func quit() {
        guard isRecording else {
            recordingManager.stopAll(); saveConfig(); NSApplication.shared.terminate(nil); return
        }
        let alert = NSAlert()
        alert.messageText = "Recordings in progress"
        let list = recordingShows.map { "• \($0.show_title) (ch \($0.show_channel))" }.joined(separator: "\n")
        alert.informativeText = "These recordings will be stopped:\n\n\(list)\n\nChoose \"Keep Recording\" to exit while recordings continue — relaunch the app to reconnect."
        alert.addButton(withTitle: "Keep Recording & Quit") // default (Return key) — caffeinate+curl survive as orphans; reattachRecordings() reconnects on next launch
        alert.addButton(withTitle: "Stop Recordings & Quit")
        alert.addButton(withTitle: "Go Back")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:  // keep recordings running, quit
            saveConfig(); NSApplication.shared.terminate(nil)
        case .alertSecondButtonReturn: // stop all, then quit
            recordingManager.stopAll(); saveConfig(); NSApplication.shared.terminate(nil)
        default:                       // Go Back — cancel
            break
        }
    }
}
