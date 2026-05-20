import Foundation
import UserNotifications
import AppKit

@MainActor
final class AppState: ObservableObject {
    @Published var shows: [Show] = []
    @Published var devices: [HDHRDevice] = []
    @Published var lineups: [String: [LineupEntry]] = [:]       // deviceId → channel lineup
    @Published var guideByDevice: [String: [GuideChannel]] = [:] // mirror of guideStore.channelsByDevice
    @Published var config = AppConfig()
    @Published var statusMessage = "Starting…"
    @Published var notifyPermission = false
    @Published var isStartingUp: Bool = true

    @Published var editingShowId: String? = nil

    var isRecording: Bool       { shows.contains { $0.show_recording } }
    var recordingShows: [Show]  { shows.filter { $0.show_recording && ($0.show_end.date ?? .distantPast) > Date() } }
    var activeShows: [Show]     { shows.filter { $0.show_active && !$0.show_recording }
                                       .sorted { ($0.show_next.date ?? .distantFuture) < ($1.show_next.date ?? .distantFuture) } }
    var inactiveShows: [Show]   { shows.filter { !$0.show_active } }

    let configManager    = ConfigManager()
    let hdhrManager      = HDHRManager()
    let recordingManager = RecordingManager()
    let guideStore       = GuideStore()

    private var idleTimer: Timer?
    private var lastGuideRefresh: Date = .distantPast
    private var failThreshold: Int { config.Fail_count_setting }
    private let maxDiskPct: Double = 93

    init() { Task { await startup() } }

    // MARK: - Startup

    func startup() async {
        await requestNotifyPermission()
        loadConfig()
        guideStore.verbose = config.Verbose_curl
        await reattachRecordings()
        await discoverDevices(knownHosts: knownHostsFromShows())
        await fetchAllGuides()
        startTimer()
        isStartingUp = false
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
        shows  = file.the_shows.map { var s = $0; s.show_recording = false; return s }
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
            task.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
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

    func discoverDevices(knownHosts: [String] = []) async {
        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            statusMessage = attempt == 1 ? "Searching for tuners…" : "Retrying… (\(attempt)/\(maxAttempts))"
            do {
                let found = try await hdhrManager.discoverDevices(knownHosts: knownHosts)
                devices = found
                for device in found {
                    if let lu = try? await hdhrManager.fetchLineup(for: device) {
                        lineups[device.DeviceID] = lu
                    }
                }
                statusMessage = "\(devices.count) tuner(s) found"
                return
            } catch {
                if attempt < maxAttempts {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                } else {
                    statusMessage = "No tuners found — check network"
                }
            }
        }
    }

    // MARK: - Guide cache

    /// Fetch guide for all known devices at startup (in parallel).
    func fetchAllGuides() async {
        guard !devices.isEmpty else { return }
        statusMessage = "Loading guide…"
        guideStore.verbose = config.Verbose_curl
        await guideStore.loadAll(devices: devices, hours: config.GuideHours)
        guideByDevice = guideStore.channelsByDevice
        lastGuideRefresh = Date()
        statusMessage = "\(shows.count) show(s) — \(devices.count) tuner(s) ready"
    }

    /// Refresh lineup + guide for all devices (called periodically from idleLoop).
    private func refreshGuides() async {
        guideStore.invalidateAll()
        for device in devices {
            if let lu = try? await hdhrManager.fetchLineup(for: device) {
                lineups[device.DeviceID] = lu
            }
        }
        guideStore.verbose = config.Verbose_curl
        await guideStore.loadAll(devices: devices, hours: config.GuideHours)
        guideByDevice = guideStore.channelsByDevice
        lastGuideRefresh = Date()
        print("[Guide] Refresh complete")
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
        }
    }

    func isGuideLoading(for deviceId: String) -> Bool {
        guideStore.isLoading(deviceId: deviceId)
    }

    /// Guide entries for a device+channel still airing or upcoming within GuideHours.
    func guideEntries(deviceId: String, channelNum: String) -> [GuideEntry] {
        guideStore.entries(deviceId: deviceId, channelNum: channelNum)
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
        show.show_dir       = folder.path
        show.show_temp_dir  = folder.path

        // UTC decimal hour from guide start time
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC")!
        let comps = utcCal.dateComponents([.hour, .minute], from: entry.startDate)
        show.show_time = Double(comps.hour ?? 20) + Double(comps.minute ?? 0) / 60.0

        let allDays = ["Monday","Tuesday","Wednesday","Thursday","Friday","Saturday","Sunday"]
        switch type {
        case .single:
            show.show_is_series = false; show.show_use_seriesid = false; show.show_use_seriesid_all = false
            show.show_air_date = []
        case .dateTime:
            show.show_is_series = true; show.show_use_seriesid = false; show.show_use_seriesid_all = false
            // Use UTC calendar to match nextDateTime(), which also works in UTC
            var utcCal = Calendar(identifier: .gregorian)
            utcCal.timeZone = TimeZone(identifier: "UTC")!
            let weekday = utcCal.component(.weekday, from: entry.startDate)
            show.show_air_date = [["Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"][weekday - 1]]
        case .seriesChannel:
            show.show_is_series = true; show.show_use_seriesid = true; show.show_use_seriesid_all = false
            show.show_air_date = allDays
        case .seriesAll:
            show.show_is_series = true; show.show_use_seriesid = true; show.show_use_seriesid_all = true
            show.show_air_date = allDays
        }

        addShow(show)
        notify("Show Added", body: show.show_title, subtitle: type.rawValue)
    }

    /// The default recording folder: UserDefaults override → config Hdhr_setup_folder → ~/Movies.
    var defaultSaveDir: URL {
        let stored = UserDefaults.standard.string(forKey: "defaultSaveDirectory") ?? ""
        if !stored.isEmpty { return URL(fileURLWithPath: stored) }
        if !config.Hdhr_setup_folder.isEmpty { return URL(fileURLWithPath: config.Hdhr_setup_folder) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
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

        // If startup discovery failed, keep retrying until we have devices
        if devices.isEmpty {
            await discoverDevices(knownHosts: knownHostsFromShows())
            if !devices.isEmpty { await fetchAllGuides() }
            return
        }

        // If guide is missing for any device (fetch failed at startup), load it now
        for device in devices where guideStore.channels(deviceId: device.DeviceID).isEmpty {
            ensureGuideLoaded(for: device.DeviceID)
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
        let endDate = show.show_end.date ?? Date().addingTimeInterval(Double(show.show_length) * 60)
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
                if let match = guideStore.nextEpisode(seriesID: show.show_seriesid,
                                                      channelNum: chFilter,
                                                      deviceId: devFilter) {
                    shows[index].show_next    = EpochDate(match.entry.startDate)
                    shows[index].show_end     = EpochDate(match.entry.endDate)
                    shows[index].show_channel = match.channelNum
                    if let url = hdhrManager.streamURL(for: match.channelNum, lineup: lineups[device.DeviceID] ?? []) {
                        shows[index].show_url = url
                    }
                    return
                }
            }
            shows[index].show_next = EpochDate(Date().addingTimeInterval(Double(config.Series_scan_retry_hours) * 3600))
        }
    }

    func nextDateTime(for show: Show) -> Date? {
        let dayMap = ["Sunday":1,"Monday":2,"Tuesday":3,"Wednesday":4,"Thursday":5,"Friday":6,"Saturday":7]
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC")!
        let h = Int(show.show_time)
        let m = Int((show.show_time.truncatingRemainder(dividingBy: 1)) * 60)
        for offset in 1...7 {
            let candidate = Date().addingTimeInterval(Double(offset) * 86400)
            let weekday = utcCal.component(.weekday, from: candidate)
            let dayName = dayMap.first { $0.value == weekday }?.key ?? ""
            guard show.show_air_date.contains(dayName) else { continue }
            var comps = utcCal.dateComponents([.year, .month, .day], from: candidate)
            comps.hour = h; comps.minute = m; comps.second = 0
            comps.timeZone = TimeZone(identifier: "UTC")!
            return utcCal.date(from: comps)
        }
        return nil
    }

    // MARK: - Show CRUD

    func addShow(_ show: Show)    { shows.append(show); saveConfig() }
    func updateShow(_ show: Show) {
        guard let i = shows.firstIndex(where: { $0.show_id == show.show_id }) else { return }
        shows[i] = show; saveConfig()
    }
    func toggleActive(_ show: Show) {
        guard let i = shows.firstIndex(where: { $0.show_id == show.show_id }) else { return }
        shows[i].show_active.toggle(); shows[i].show_fail_count = 0; shows[i].show_fail_reason = ""; saveConfig()
    }
    func deleteShow(_ show: Show) { recordingManager.stop(showId: show.show_id); shows.removeAll { $0.show_id == show.show_id }; saveConfig() }

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

    func shortTime(_ date: Date?) -> String {
        guard let d = date else { return "?" }
        let f = DateFormatter(); f.timeStyle = .short; return f.string(from: d)
    }

    func quit() {
        guard isRecording else {
            recordingManager.stopAll(); saveConfig(); NSApplication.shared.terminate(nil); return
        }
        let alert = NSAlert()
        alert.messageText = "Recordings in progress"
        let list = recordingShows.map { "• \($0.show_title) (ch \($0.show_channel))" }.joined(separator: "\n")
        alert.informativeText = "These recordings will be stopped:\n\n\(list)"
        alert.addButton(withTitle: "Stop Recordings & Quit")
        alert.addButton(withTitle: "Go Back")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            recordingManager.stopAll(); saveConfig(); NSApplication.shared.terminate(nil)
        }
    }
}
