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
        // menuIsOpen guard mirrors the idle-loop guard — prevents mid-display redraws when a
        // background guide refresh assigns guideByDevice while the menu is open.
        didSet { guideGeneration += 1; if !menuIsOpen { rebuildChannelImageURLs(); rebuildMenuEntries() } }
    }
    // Bumped every time guideByDevice is reassigned (~hourly, or on-demand) — a cheap freshness
    // signal for views that cache a guide-derived computation and need to know when to recompute,
    // without re-deriving from guideByDevice's actual contents (AddShowView's otherAiringsCache).
    @Published var guideGeneration: Int = 0
    // Per-show guide entry for the scheduled menu label and info header — avoids O(series) scan per open.
    @Published var menuScheduledEntry: [String: GuideEntry] = [:]
    // Pre-computed upcoming slots for SeriesID shows — avoids O(series) nextEpisodes scan per open.
    @Published var menuUpcomingSlots: [String: [(channel: String, date: Date)]] = [:]
    // Pre-computed set of show IDs that will actually lose a tuner — rebuilt alongside menu
    // entries. Only the loser(s) of an over-capacity cluster are included, not every member.
    var conflictingShowIDs: Set<String> = []
    // Subset of conflictingShowIDs where the loss is specifically to a favorited competitor —
    // lets the UI say "a favorited channel has priority" instead of a generic busy message.
    var conflictBeatenByFavorite: Set<String> = []
    // Tracks which shows have already fired a runtime conflict notification.
    // Value = show_next epoch (TimeInterval) for which the notification was sent;
    // clears on reschedule so a new time slot can notify again.
    // Not `private`: deleteShow's cleanup test reads this directly (@testable import doesn't
    // reach true `private`) rather than via a hand-duplicated shadow list that could itself
    // drift out of sync with deleteShow's own cleanup.
    var conflictNotifiedEpochs: [String: TimeInterval] = [:]
    // "channelNum:startTime" keys for guide entries already logged as now-airing without a genre tag.
    private var loggedNowAiring: Set<String> = []
    // Last time the NowAiring diagnostic scan (below) ran — gates it to a coarse cadence since
    // it's a full device×channel guide walk purely for discovering untagged infomercial
    // SeriesIDs, not anything requiring sub-minute freshness.
    private var lastNowAiringScan: Date = .distantPast
    // Same pattern as conflictNotifiedEpochs, for MISSED START warnings.
    var missedStartNotifiedEpochs: [String: TimeInterval] = [:]
    // Shows whose recording was interrupted by an app quit and will be relaunched this session.
    // Suppresses the duplicate Discord "Recording Started" on the first relaunch after startup.
    var suppressStartDiscord: Set<String> = []
    // Shows whose "Recording Started" embed is deferred until the first idle-loop tick confirms
    // the curl process is still alive — prevents a Discord ping for a recording that fails instantly.
    var pendingDiscordStart: Set<String> = []
    // Shows that recorded at least one mid-recording FAIL event during the *current* recording
    // attempt (inserted in the idle-loop FAIL branch, cleared when a fresh attempt starts).
    // stopRecording's empty-output-file check consumes this to decide whether show_fail_reason
    // still describes this attempt or is stale detail left over from an earlier, resolved one —
    // show_fail_count alone can't tell the difference since a success only decrements it.
    var failedThisAttempt: Set<String> = []
    // Per-attempt marker: set in startRecording only when show_ignore_duplicate_once actually
    // suppressed a real duplicate-skip for the airing being recorded right now. stopRecording's
    // natural-success path consumes this to decide whether to clear the override — so enabling
    // it preemptively on a recording that was never actually a duplicate doesn't silently burn
    // the one-shot before the rerun it was meant for ever airs.
    var duplicateOverrideUsedThisAttempt: Set<String> = []
    // Retained DispatchSource for SIGTERM — saves config before the process exits so
    // show_recording_path and discord_start_msg_id survive pkill during development.
    private var sigtermSource: DispatchSourceSignal?
    // O(1) managed-show lookup for entryMenu — rebuilt alongside menu entries.
    var managedShowBySeriesID: [String: Show] = [:]
    var managedShowByTitle:    [String: [Show]] = [:]
    // O(1) channel logo lookup for channelMenu — "deviceId:channelNum" → ImageURL — rebuilt alongside menu entries.
    var channelImageURLs: [String: String] = [:]
    @Published var guideRevision: Int = 0                        // increments each time guide data successfully loads
    @Published var config = AppConfig()
    @Published var statusMessage = "Starting…"
    @Published var notifyPermission = false
    private let notificationDelegate = NotificationActionDelegate()
    @Published var isStartingUp: Bool = true
    // Set to true in tests: startup() returns immediately, preventing idleLoop from running.
    var skipStartup = false

    @Published var editingShowId: String? = nil
    @Published var watchNowDeviceId: String? = nil
    @Published var pendingAddEntry: (device: HDHRDevice, channel: LineupEntry, entry: GuideEntry)? = nil
    @Published var pendingAddEntryGeneration: Int = 0   // bumped each time a new entry is set; drives onChange in AddShowView
    @Published var pendingAddChannel: (device: HDHRDevice, channel: LineupEntry)? = nil
    @Published var pendingAddChannelGeneration: Int = 0  // bumped each time pendingAddChannel is set
    @Published var pendingDonationNagTrigger: Int = 0    // bumped after a show is added (native or web); drives onChange in MenuContent to open the donation nag window
    @Published var tunerStatus: [String: TunerStatus] = [:]         // showId → last polled vstatus
    @Published var deviceTunerOccupancy: [String: [DeviceTunerInfo]] = [:]  // deviceId → live status.json snapshot
    private var lastTunerAudit: [String: String] = [:]                      // deviceId → last logged audit string; suppresses unchanged lines
    // deviceId → last time a real tuner-count change was allowed to write while the menu was
    // open (see fetchDeviceStatusUncached). Bounds disruption to at most once per cooldown window
    // even if the count keeps flapping tick-to-tick (e.g. an external consumer channel-surfing) —
    // without this, a rapidly flapping count could re-glitch the open menu on every single tick.
    private var lastMenuOpenTunerWrite: [String: Date] = [:]
    private static let menuOpenTunerWriteCooldown: TimeInterval = 30
    @Published var vlcCurrentURL: String = ""               // raw URL (no transcode query) playing in VLCPlayerView
    @Published var channelIconImages: [String: NSImage] = [:]  // ImageURL → NSImage; populated during prefetch for sync menu use
    @Published var signalScanProgress: String? = nil

    private var signalScanTask:     Task<Void, Never>? = nil
    var signalDropoutTicks: [String: Int] = [:]               // showId → consecutive low-snq ticks

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
    // Menu bar "blink" state for Settings → "Blink menu bar icon"; driven by statusLightTimer
    // (see startStatusLightTimer/tickStatusLight below), read by hdhr_VCRApp's statusLabel.
    // Deliberately a real @Published rather than a view-local TimelineView — a TimelineView
    // inside the MenuBarExtra label broke click-to-open-menu (AppKit's NSStatusItem stops
    // forwarding clicks once its label content free-runs on its own render loop).
    @Published var statusLightOn: Bool = true
    var isRecording: Bool      { shows.contains { $0.show_recording } }
    var recordingShows: [Show] { shows.filter { $0.show_recording && ($0.show_end ?? .distantPast) > Date() } }
    var activeShows: [Show]    { shows.filter { $0.show_active && !$0.show_recording && !$0.show_paused }
                                      .sorted { ($0.show_next ?? .distantFuture) < ($1.show_next ?? .distantFuture) } }
    var pausedShows: [Show]    { shows.filter { $0.show_active && $0.show_paused } }
    var inactiveShows: [Show]  { shows.filter { !$0.show_active } }
    var unavailableDeviceIDs: Set<String> { Set(devices.filter { !$0.isAvailable }.map { $0.DeviceID }) }
    // Discovered AND reachable — the web guide treats these as "active" tuners.
    var usableDeviceIDs: Set<String> { Set(devices.filter { $0.isAvailable }.map { $0.DeviceID }) }
    var unavailableDeviceShows: [Show] {
        guard !unavailableDeviceIDs.isEmpty else { return [] }
        return shows.filter { $0.show_active && unavailableDeviceIDs.contains($0.hdhr_record) }
    }

    // Returns one (channel, entry) pair per unique on-air channel for the given device,
    // sorted favorites-first, then by channel number.
    func onAirNow(for device: HDHRDevice, at date: Date = Date()) -> [(channel: LineupEntry, entry: GuideEntry)] {
        var seen = Set<String>()
        return (lineups[device.DeviceID] ?? [])
            .compactMap { ch -> (channel: LineupEntry, entry: GuideEntry)? in
                guard seen.insert(ch.GuideNumber).inserted else { return nil }
                guard let entry = guideEntries(deviceId: device.DeviceID, channelNum: ch.GuideNumber)
                    .first(where: { $0.startDate <= date && $0.endDate > date })
                else { return nil }
                return (ch, entry)
            }
            .sorted { a, b in
                if a.channel.isFavorite != b.channel.isFavorite { return a.channel.isFavorite }
                return a.channel.GuideNumber.channelSortKey < b.channel.GuideNumber.channelSortKey
            }
    }

    var nextShowMinutes: Double? {
        activeShows
            .compactMap { $0.show_next.map { $0.timeIntervalSince(Date()) / 60 } }
            .filter { $0 > 0 }
            .min()
    }

    var availableDeviceCount: Int {
        devices.filter {
            !(lineups[$0.DeviceID]?.isEmpty ?? true) && !(guideByDevice[$0.DeviceID]?.isEmpty ?? true)
        }.count
    }


    let configManager: ConfigManager
    let hdhrManager      = HDHRManager()
    let recordingManager = RecordingManager()
    let guideStore       = GuideStore()
    let webServer        = WebServer()
    @Published var webServerRunning: Bool    = false
    @Published var webServerError:   String? = nil
    private var internalWebServerUseCount = 0  // ref count: each open WKWebView guide window increments
    private var recordingRelayActive = false   // true while watchRecordingInApp holds an internal-web-server claim

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
    }

    private var idleTimer: Timer?
    private var statusLightTimer: Timer?
    private var lastRefreshHour: Int?     = nil  // hour on which guide was last refreshed; triggers new refresh when hour changes
    // Guards the fast lineup-only retry below — separate from guideRefreshInFlight (refreshGuides'
    // own guard) since this fires on every idle tick, not just the hourly boundary, and a
    // permission-blocked fetch is exactly the kind of call that could plausibly hang past one tick.
    private var lineupConfirmRetryInFlight = false
    private var lastDeviceProbe: Date     = .distantPast
    private var nextQuickProbe: Date?     = nil   // set when any device misses a probe; cleared when all are seen
    // idleLoop() launches probeForNewDevices() as a detached `Task { }`, not awaited — its own
    // idleLoopRunning guard only prevents overlapping idleLoop() bodies, not this background probe
    // outliving one tick. Without this, a probe slower than the ~60s/300s trigger interval (e.g.
    // discoverDevices stalling under network stress) could have a second probe start while the
    // first is still in flight; both would capture `existingIDs` before either appends, appending
    // the same first-seen device twice and corrupting occupancy counts/menu/dev-bar for the session.
    private var probeInFlight = false
    // Deadline past which a device with TunerCount == nil (otherwise available — UDP-alive, HTTP
    // dead) stops re-arming the 60s quick-probe cadence (see probeForNewDevices) and falls back to
    // the normal 5-min cadence, so a device whose HTTP server is permanently unreachable (rather
    // than just slow to start) doesn't pin the fast cadence for the rest of the session. Stores the
    // deadline itself (not the start time), matching showRetryAfter/nextQuickProbe's shape. Cleared
    // once TunerCount is restored or the device becomes unavailable.
    private var tunerCountFallbackAt: [String: Date] = [:]
    private var guideRefreshInFlight: Bool = false
    // In-flight fetchDeviceStatus(for:) calls, keyed by device — coalesces concurrent callers onto
    // the same real fetch (mirrors ensureLineupLoaded's loadingLineupTasks idiom) instead of a
    // second caller silently skipping and reading stale tunerStatus. That distinction matters here:
    // watchInApp/watchInVLC specifically await this call to force a fresh poll before deciding
    // whether tuners are full, so a skip-and-return-immediately guard would defeat the whole point
    // of awaiting it whenever the idle loop's own per-tick call happened to already be in flight.
    private var fetchStatusTasks: [String: Task<Void, Never>] = [:]
    // Tracks in-flight lineup fetches so concurrent callers await the same Task instead of polling
    private var loadingLineupTasks: [String: Task<Void, Never>] = [:]
    // Per-device exponential backoff after guide API failures (replaces flat guideLoadFailTimes).
    private var guideApiBackoff: [String: APIBackoff] = [:]
    // Per-show cooldown after a recording failure, expressed in idle-loop ticks (scales with
    // Idle_timer_interval) rather than wall-clock time. 1st consecutive failure waits 2 ticks;
    // every failure after that waits 3 (capped) until show_fail_count reaches Fail_count_setting
    // and the show pauses. Mirrors APIBackoff's escalating-delay shape above. Not persisted —
    // resets to "no backoff" on relaunch.
    private static let retryBackoffLoops: [Int] = [2, 3]
    var showRetryAfter: [String: Date] = [:]
    private var failThreshold: Int { config.Fail_count_setting }
    private let maxDiskPct: Double = 93
    // Set true while the MenuBarExtra menu is open (tracked via MenuContent onAppear/onDisappear).
    // Guards guideByDevice.didSet and idle-loop rebuilds so @Published changes don't redraw the menu.
    var menuIsOpen: Bool = false

    // configManager param is a test seam only — real app startup (hdhr_VCRApp.swift) always uses
    // the default, which points at the real on-disk config; see ConfigManager.init's own comment.
    init(configManager: ConfigManager = ConfigManager()) {
        self.configManager = configManager
        // Keep vlcCurrentURL in sync with VLCBridge.currentURL so any close path that
        // nils currentURL (releasePlayer → stopAndClearState) automatically clears the
        // "now watching" indicator without every caller needing to do it explicitly.
        VLCBridge.shared.$currentURL
            .map { $0?.urlBase ?? "" }
            .assign(to: &$vlcCurrentURL)
        Task { await startup() }
    }

    // MARK: - Startup

    func startup() async {
        guard !skipStartup else { return }
        // Intercept SIGTERM (pkill, launchd stop) to flush config before the process dies.
        // Re-raises SIGTERM with the default handler so the process exits normally without
        // triggering the quit dialog — recordings survive as orphans via POSIX_SPAWN_SETSID.
        signal(SIGTERM, SIG_IGN)
        sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigtermSource?.setEventHandler { [weak self] in
            guard let self else { signal(SIGTERM, SIG_DFL); raise(SIGTERM); return }
            Task { @MainActor in
                // Give any in-flight Discord card send a bounded window to finish and clear
                // discord_start_msg_id before the final save — otherwise a pkill mid-send
                // (deploy.sh's normal stop-before-rebuild step) can persist a stale id that
                // reattachRecordings() later mistakes for an unfinished recording, posting a
                // bogus recovery embed on next launch. Skipped entirely when nothing is
                // pending (the overwhelmingly common case), so a normal deploy isn't slowed.
                let pending = Array(self.discordCardTasks.values)
                if !pending.isEmpty {
                    await withTaskGroup(of: Void.self) { group in
                        group.addTask { try? await Task.sleep(nanoseconds: 2_000_000_000) } // 2s cap
                        group.addTask { for t in pending { _ = await t.value } }
                        await group.next() // first of {timeout, all-sends-done} wins
                        group.cancelAll()
                    }
                }
                self.saveConfig()
                signal(SIGTERM, SIG_DFL)
                raise(SIGTERM)
            }
        }
        sigtermSource?.resume()

        // 1. Config first — shows visible in menu immediately
        loadConfig()
        glog("[Startup] config loaded — \(shows.count) shows, GuideHours=\(config.GuideHours)")

        // Auto-enable Watch in VLC on first launch if VLC is installed
        if !config.Watch_in_VLC_initialized {
            config.Watch_in_VLC = VLCBridge.locateApp() != nil
            config.Watch_in_VLC_initialized = true
            saveConfig()
        }

        // 2. Reattach any recordings that survived a restart
        await reattachRecordings()
        glog("[Startup] recordings reattached")

        // 3. Start the web server now — port binding doesn't need devices or guide data.
        //    Starting here means the server is up within ~1s of launch instead of waiting
        //    for the full discovery + guide fetch sequence to complete.
        setupWebServer()

        // 4. Notification permission — fire-and-forget; must not block discovery
        Task { await requestNotifyPermission() }

        // 6. Load persisted signal history before first guide fetch
        await ChannelSignalStore.shared.load()

        // 7. Discover tuners + lineups — 10 attempts, 1s apart
        let knownHosts = knownHostsFromShows()
        glog("[Startup] discovering — knownHosts=\(knownHosts)")
        await discoverDevices(knownHosts: knownHosts, attempts: 10)
        glog("[Startup] discovered \(devices.count) device(s)")
        // Prime deviceTunerOccupancy immediately after discovery so the first web page load
        // has accurate tuner counts instead of the empty dict it would otherwise start with.
        for device in devices { Task { await fetchDeviceStatus(for: device) } }
        for d in devices {
            glog("[Startup]   \(d.DeviceID)  LocalIP='\(d.LocalIP)'  DeviceAuth=\(d.DeviceAuth ?? "nil")")
        }

        // 7. Guide — only if tuners found; idleLoop will retry if this fails
        if !devices.isEmpty {
            await fetchAllGuides()
            let ch = guideByDevice.values.reduce(0) { $0 + $1.count }
            glog("[Startup] guide: \(ch) channels across \(guideByDevice.count) device(s)")
        } else {
            glog("[Startup] no devices — idleLoop will retry")
        }

        startTimer()
        startStatusLightTimer()
        isStartingUp = false
        glog("[Startup] complete")

        // Resume an incomplete signal scan: only if the store already has data (meaning a scan
        // was started before) and at least one channel still needs a sample.
        if config.Signal_quality_enabled, !ChannelSignalStore.shared.buckets.isEmpty {
            let anyNeeded = devices.contains { device in
                (lineups[device.DeviceID] ?? []).contains {
                    ChannelSignalStore.shared.needsSample(guideName: $0.GuideName)
                }
            }
            if anyNeeded {
                glog("[Signal] resuming incomplete scan from startup")
                startSignalScan()
            }
        }

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

    func setupWebServer() {
        guard config.Web_server_enabled else {
            // Only tear the listener down if no internal holder still needs it. AddShowView's
            // guide step and the Watch-Now-from-disk relay (watchRecordingInApp) both keep the
            // localhost server alive via internalWebServerUseCount independent of this LAN-exposure
            // toggle — an unconditional stop() here would kill an in-app guide's WKWebView or a live
            // relay stream mid-playback. releaseInternalWebServer uses the same count==0 gate.
            if internalWebServerUseCount == 0 {
                webServer.stop()                   // no-op (and silent) if already stopped
                if webServerRunning { webServerRunning = false }
            }
            if webServerError != nil { webServerError = nil }
            return
        }
        webServerError = nil
        webServer.start(port: config.Web_server_port, appState: self) { [weak self] errorMsg in
            self?.applyWebServerState(errorMsg)
        }
    }

    // Called by each in-app WKWebView guide window on appear; reference-counted so the server
    // stops when the last window closes (unless permanently enabled in Settings).
    func ensureWebServerRunning() {
        internalWebServerUseCount += 1
        guard !webServerRunning else { return }
        webServerError = nil
        webServer.start(port: config.Web_server_port, appState: self) { [weak self] errorMsg in
            self?.applyWebServerState(errorMsg)
        }
    }

    private func applyWebServerState(_ errorMsg: String?) {
        webServerRunning = (errorMsg == nil)
        webServerError   = errorMsg
        if errorMsg == nil { webServer.updateTXTRecord() }
    }

    func releaseInternalWebServer() {
        guard internalWebServerUseCount > 0 else { return }
        internalWebServerUseCount -= 1
        guard internalWebServerUseCount == 0, !config.Web_server_enabled else { return }
        webServer.stop()
        webServerRunning = false
    }

    // .local hostnames excluded — mDNS resolution happens in mDNSDiscover(), no benefit adding them here.
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
            guard line.contains("show_id:"),
                  line.contains("hdhrVCRplus"),
                  line.contains("/usr/bin/curl") else { continue }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let cols    = trimmed.components(separatedBy: .whitespaces)
            guard let pidStr = cols.first, let pid = Int32(pidStr) else { continue }

            guard let idRange = line.range(of: "show_id:") else { continue }
            let tail   = String(line[idRange.upperBound...])
            let showId = String(tail.prefix(while: { !$0.isWhitespace && $0 != "'" && $0 != "\"" }))
            guard !showId.isEmpty else { continue }

            if let i = shows.firstIndex(where: { $0.show_id == showId }),
               let endDate = shows[i].show_end, endDate > now {
                shows[i].show_recording = true
                shows[i].show_tuner_resource = ""   // will be re-captured by captureResourceHeaders()
                recordingManager.reattach(showId: showId, pid: pid, title: shows[i].show_title, endDate: endDate)
                glog("[Startup] Reattached '\(shows[i].show_title)' pid=\(pid) ends \(endDate)")
            } else {
                // No matching show in config (deleted while recording, config reset, etc.) or past end —
                // kill the orphaned curl process so it doesn't hold a tuner indefinitely.
                // Use SIGKILL: orphans may have inherited SIG_IGN for SIGTERM from the parent app.
                kill(pid, SIGKILL)
                glog("[Startup] Killed orphaned curl pid=\(pid) showId=\(showId)", level: .warning)
            }
        }

        // Any show with a discord_start_msg_id that wasn't reattached as actively recording
        // had its completion/failure embed skipped over the restart. Send a recovery embed now
        // and clear the ID so it doesn't linger into the next recording cycle.
        var needsSave = false
        for i in shows.indices {
            guard !shows[i].discord_start_msg_id.isEmpty, !shows[i].show_recording else { continue }
            let show  = shows[i]
            let msgId = show.discord_start_msg_id
            let path  = show.show_recording_path
            let fileSize = path.isEmpty ? 0 :
                ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0)

            // Clear before the network send — a crash during send won't re-trigger on next launch.
            shows[i].discord_start_msg_id = ""
            // Suppress the duplicate "Recording Started" Discord embed when the idle loop
            // relaunches this show — the "Interrupted" embed already tells the story.
            suppressStartDiscord.insert(show.show_id)
            needsSave = true

            glog("[Startup] Recovering Discord embed for '\(show.show_title)' — file size \(fileSize / 1024)KB")

            if fileSize > 0 {
                var fileFields: [(name: String, value: String, inline: Bool)] = []
                let ext = URL(fileURLWithPath: path).pathExtension.uppercased()
                if !ext.isEmpty { fileFields.append(("Format", ext, true)) }
                fileFields.append(("File Size", Self.formatFileSize(fileSize), true))
                fileFields.append(("Note", "Completed before app restart", false))
                discordShow("✅ Recording Complete", show: show, color: 0x3498DB,
                            enabled: config.Discord_on_complete,
                            extra: fileFields, editMessageId: msgId)
            } else {
                discordShow("⚠️ Recording Interrupted", show: show, color: 0xE67E22,
                            enabled: config.Discord_on_failed,
                            extra: [("Note", "App restarted — recording status unknown", false)],
                            editMessageId: msgId)
            }
        }
        if needsSave { saveConfig() }
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

    // Never removes entries — avoids disrupting active recordings; isAvailable goes false after 3 missed probes.
    private func probeForNewDevices() async {
        guard !probeInFlight else { return }
        probeInFlight = true
        defer { probeInFlight = false }
        // Use a nil `found` to mean discovery itself failed (network error) — still counts as a miss
        // so a device that's offline AND causing discovery failures still reaches the unavailable threshold.
        let found = try? await hdhrManager.discoverDevices(knownHosts: knownHostsFromShows(), interface: config.Network_interface)
        let existingIDs = Set(devices.map { $0.DeviceID })

        // Merge-update DeviceAuth + LocalIP on seen devices; increment missedProbes on unseen ones.
        // freshByID is empty when discovery threw — all existing devices count as unseen this cycle.
        let freshByID = Dictionary(uniqueKeysWithValues: (found ?? []).map { ($0.DeviceID, $0) })
        for i in devices.indices {
            if let fresh = freshByID[devices[i].DeviceID] {
                let wasUnavailable = !devices[i].isAvailable
                devices[i].missedProbes = 0
                if fresh.DeviceAuth != nil { devices[i].DeviceAuth = fresh.DeviceAuth }
                if !fresh.LocalIP.isEmpty  { devices[i].LocalIP    = fresh.LocalIP    }
                // Restore hardware capacity when a probe reaches the device's HTTP server. A
                // UDP-only startup (device HTTP briefly down) caches a bare device with
                // TunerCount == nil; without re-applying it here it stays nil for the whole
                // session, and computeDevTuners renders no tuner badge at all when total == 0 —
                // so the app shows "no active tuner" even while both tuners are recording.
                if fresh.TunerCount != nil { devices[i].TunerCount = fresh.TunerCount }
                if fresh.FirmwareVersion != nil { devices[i].FirmwareVersion = fresh.FirmwareVersion }
                if wasUnavailable {
                    glog("[DeviceProbe] \(devices[i].DeviceID) is back online")
                    webServer.broadcastDeviceBarEvent(type: "deviceOnline", deviceId: devices[i].DeviceID, state: self)
                }
            } else {
                devices[i].missedProbes += 1
                let missed = devices[i].missedProbes
                if missed == 3 {
                    let affected = shows.filter { $0.show_active && $0.hdhr_record == devices[i].DeviceID }
                    glog("[DeviceProbe] \(devices[i].DeviceID) not seen for 3 probes — marking unavailable (\(affected.count) show(s) affected)", level: .warning)
                    webServer.broadcastDeviceBarEvent(type: "deviceOffline", deviceId: devices[i].DeviceID, state: self)
                } else if missed > 3 {
                    glog("[DeviceProbe] \(devices[i].DeviceID) still missing (missed \(missed))", level: .warning)
                }
            }
        }

        // Track how long each available device has had TunerCount == nil, bounding the quick-probe
        // re-arm below to the first 5 minutes of that state — a device whose HTTP server never
        // comes up (as opposed to one that's merely slow to start after UDP replies) falls back to
        // the normal 5-min probe cadence instead of pinning the fast one for the whole session.
        let now = Date()
        var tunerCountRecentlyMissing = false
        for device in devices {
            guard device.TunerCount == nil, device.isAvailable else {
                tunerCountFallbackAt.removeValue(forKey: device.DeviceID)
                continue
            }
            let deadline = tunerCountFallbackAt[device.DeviceID] ?? now.addingTimeInterval(300)
            tunerCountFallbackAt[device.DeviceID] = deadline
            if now < deadline { tunerCountRecentlyMissing = true }
        }

        // Schedule a 60 s follow-up probe until the device is confirmed unavailable (3 misses).
        // <= 3 (not < 3) so the tick that crosses the threshold also schedules a follow-up,
        // enabling faster recovery detection rather than reverting to the 5-min idle interval.
        // Also re-probe quickly while any *available* device has recently started missing its
        // TunerCount (UDP-only startup with the HTTP fetch down) so its capacity — and the tuner
        // badge — is restored within ~60 s of the device's HTTP server becoming reachable, not up
        // to 5 min later. The isAvailable guard (plus the 5-min bound above) is essential: a device
        // that never yields a discover.json TunerCount (e.g. the fake FFFF0001 test device, or a
        // real device whose HTTP server is permanently down rather than just slow) would otherwise
        // pin the quick-probe cadence at 60 s for the whole session instead of settling back to it.
        if devices.contains(where: { $0.missedProbes > 0 && $0.missedProbes <= 3 })
            || tunerCountRecentlyMissing {
            nextQuickProbe = Date().addingTimeInterval(60)
        }

        let newDevices = (found ?? []).filter { !existingIDs.contains($0.DeviceID) }
        guard !newDevices.isEmpty else { return }
        glog("[DeviceProbe] \(newDevices.count) new tuner(s): \(newDevices.map { $0.DeviceID }.joined(separator: ", "))")
        devices.append(contentsOf: newDevices)
        await fetchAllLineups(for: newDevices)
        let results = await guideStore.loadAll(devices: newDevices, hours: config.GuideHours, useXML: config.Guide_use_xml)
        for (deviceId, ok) in results {
            if ok { guideApiBackoff.removeValue(forKey: deviceId) }
            else  { guideApiBackoff[deviceId, default: APIBackoff()].recordFailure() }
        }
        guideByDevice = guideStore.channelsByDevice
        webServer.broadcastDeviceBarEvent(type: "deviceOnline", deviceId: newDevices.map { $0.DeviceID }.joined(separator: ","), state: self)
    }

    // Coalesces concurrent callers — only the first fetches; others await its Task directly. Guards
    // against a logged-but-still-real fetchAllLineups failure leaving lineups[deviceID] nil.
    func ensureLineupLoaded(for device: HDHRDevice) async {
        let id = device.DeviceID
        guard lineups[id]?.isEmpty ?? true else { return }
        // Coalesce concurrent callers: only the first proceeds; others await its in-flight Task.
        if let existing = loadingLineupTasks[id] {
            await existing.value
            return
        }
        let task = Task {
            glog("[Lineup] \(id) lineup missing — fetching on demand")
            await self.fetchAllLineups(for: [device])
        }
        loadingLineupTasks[id] = task
        defer { loadingLineupTasks.removeValue(forKey: id) }
        await task.value
    }

    private func fetchAllLineups(for devices: [HDHRDevice]) async {
        await withTaskGroup(of: (String, [LineupEntry]?).self) { group in
            for device in devices {
                group.addTask {
                    do {
                        let lu = try await self.hdhrManager.fetchLineup(for: device)
                        return (device.DeviceID, lu)
                    } catch {
                        glog("[Lineup] \(device.DeviceID) fetch failed: \(error)", level: .warning)
                        return (device.DeviceID, nil)
                    }
                }
            }
            for await (id, lu) in group {
                if let lu {
                    glog("[Lineup] \(id) loaded \(lu.count) channels")
                    reconcileFavorites(deviceId: id, freshLineup: lu)
                    lineups[id] = lu
                    confirmLocalNetworkAccessIfNeeded()
                }
            }
        }
        // After lineups are current, fix any stale show URLs caused by device IP changes
        updateShowURLsFromLineups()
    }

    // First confirmed successful lineup fetch means Local Network access is genuinely working —
    // see TODO.md's "Show Stoppers" entry and hdhr_VCRApp.init()'s Dock-icon heuristic. Persists
    // so future launches start directly as accessory (no Dock icon) without re-proving it every
    // time, and switches the currently-running process back immediately if this launch started
    // as .regular per that heuristic (only matters in "auto" mode — an explicit user override
    // stays put either way).
    private func confirmLocalNetworkAccessIfNeeded() {
        guard !config.Local_network_confirmed else { return }
        config.Local_network_confirmed = true
        saveConfig()
        if config.Dock_icon_mode == "auto" {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }

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

    func fetchAllGuides() async {
        guard !devices.isEmpty else { return }
        statusMessage = "Loading guide…"
        let results = await guideStore.loadAll(devices: devices, hours: config.GuideHours, useXML: config.Guide_use_xml)
        guideByDevice = guideStore.channelsByDevice
        // didSet already ran these when the menu is closed — only the menu-open case (where
        // didSet's own guard skips them) needs the explicit call here, so guide load doesn't
        // populate channelImageURLs/menu caches twice back-to-back when it's closed.
        if menuIsOpen { rebuildChannelImageURLs(); rebuildMenuEntries() }
        // Seed per-device backoff state from startup results (no notification — user may not have
        // granted permission yet; ensureGuideLoaded will notify when it retries and fails again).
        for (deviceId, ok) in results {
            if ok { guideApiBackoff.removeValue(forKey: deviceId) }
            else  { guideApiBackoff[deviceId, default: APIBackoff()].recordFailure() }
        }
        let loadedCount = guideByDevice.values.reduce(0) { $0 + $1.count }
        // Stamp the refresh hour so the first idle-loop tick doesn't immediately
        // re-fetch the guide that startup just loaded.
        if loadedCount > 0 { guideRevision += 1; lastRefreshHour = Calendar.current.component(.hour, from: Date()) }
        statusMessage = "\(shows.count) show(s) — \(availableDeviceCount) tuner(s) ready"
        let allChannels = guideByDevice.values.flatMap { $0 }
        Task { await prefetchChannelIcons(allChannels) }
        if loadedCount > 0 { webServer.prebuildPageHTML(state: self) }
    }

    private func refreshGuides() async {
        guard !guideRefreshInFlight else { return }
        guideRefreshInFlight = true
        // Per-device retries are handled separately by ensureGuideLoaded with exponential backoff.
        // Hourly refresh boundary in idleLoop naturally prevents retry storms.
        defer { guideRefreshInFlight = false }
        // Deliberately no guideStore.invalidateAll() here (unlike SettingsView's user-initiated
        // rescan/setting-change callers, where an immediate wipe-then-reload is expected and the
        // brief empty window is fine). This runs silently in the background every hour, and
        // buildIndex(deviceId:channels:) already atomically replaces each device's stale data
        // with fresh data the moment its own fetch succeeds — devices are never removed from
        // `devices` in this app, so nothing is ever orphaned by skipping an upfront wipe here.
        // A prior version DID invalidate eagerly, and it raced with anything reading guideStore
        // between the wipe and loadAll's completion — e.g. a "Recording Started" Discord embed
        // built in that window would see zero guide entries and fall back to a bare title with
        // no episode/matchup info, easy to hit whenever a show's start time lands near the hour
        // boundary (as this refresh does), even though the guide data had been correct all day.
        await fetchAllLineups(for: devices)
        let results = await guideStore.loadAll(devices: devices, hours: config.GuideHours, useXML: config.Guide_use_xml)
        guideByDevice = guideStore.channelsByDevice
        // Update per-device backoff; notify once per failure streak
        for (deviceId, ok) in results {
            if ok {
                guideApiBackoff.removeValue(forKey: deviceId)
            } else {
                handleGuideLoadFailure(deviceId: deviceId)
            }
        }
        let anyLoaded = guideByDevice.values.contains(where: { !$0.isEmpty })
        if anyLoaded { guideRevision += 1 }
        glog("[Guide] Refresh complete")
        let allChannels = guideByDevice.values.flatMap { $0 }
        Task { await prefetchChannelIcons(allChannels) }
        // Re-evaluate all series shows against fresh guide data so any that were bumped
        // past the guide window get scheduled as soon as a matching episode appears.
        await rescheduleAllSeries()
        // Notify connected web clients that guide data has changed so they can refresh the grid.
        // Builds the grid once and reuses it for both the page cache and the SSE broadcast.
        if anyLoaded {
            webServer.refreshPageAndBroadcastGuideChange(type: "guide_refreshed", state: self)
        }
    }

    func ensureGuideLoaded(for deviceId: String) {
        // Exponential backoff: 1m → 5m → 15m → 30m → 1h after repeated API failures.
        // Prevents hammering the SiliconDust cloud API (e.g. 403 from EXTEND devices).
        if guideApiBackoff[deviceId]?.isBackedOff == true { return }
        guard !guideStore.isLoading(deviceId: deviceId),
              guideStore.channels(deviceId: deviceId).isEmpty,
              let device = devices.first(where: { $0.DeviceID == deviceId }) else { return }
        Task {
            let ok = await guideStore.load(for: device, hours: config.GuideHours, useXML: config.Guide_use_xml)
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

    private func prefetchChannelIcons(_ channels: [GuideChannel]) async {
        let urls = Array(Set(channels.compactMap { $0.ImageURL }.filter { !$0.isEmpty }))
        guard !urls.isEmpty else { return }
        let needed = await ChannelIconCache.shared.countMissing(in: urls)

        if needed == 0 {
            // Warm cache: load disk→mem in one pass, single @Published assignment — no UI churn.
            await withTaskGroup(of: Void.self) { group in
                for url in urls {
                    group.addTask { _ = await ChannelIconCache.shared.image(for: url) }
                }
            }
            let fetched = await ChannelIconCache.shared.allCachedImages(for: urls)
            channelIconImages = channelIconImages.merging(fetched) { _, new in new }
            return
        }

        // Cold cache: all downloads run concurrently (total time ≈ slowest single download,
        // not a sum of sequential waves); completed icons are published in batches of 16 so
        // they appear in the UI as they arrive without per-icon @Published churn.
        statusMessage = "Caching \(needed) channel icon(s)…"
        await withTaskGroup(of: (String, NSImage?).self) { group in
            for url in urls {
                group.addTask { (url, await ChannelIconCache.shared.image(for: url)) }
            }
            var batch: [String: NSImage] = [:]
            for await (url, img) in group {
                if let img { batch[url] = img }
                if batch.count >= 16 {
                    channelIconImages = channelIconImages.merging(batch) { _, new in new }
                    batch.removeAll()
                }
            }
            if !batch.isEmpty {
                channelIconImages = channelIconImages.merging(batch) { _, new in new }
            }
        }
        glog("[Icons] downloaded \(needed) new icon(s) — \(urls.count) total cached")
        statusMessage = "\(shows.count) show(s) — \(availableDeviceCount) tuner(s) ready"
        // Only the cold-cache path above writes new files, so this is the point to check the
        // disk cap — once per prefetch batch, not per file (see pruneDiskCacheIfNeeded's comment).
        await ChannelIconCache.shared.pruneDiskCacheIfNeeded()
    }

    func isGuideLoading(for deviceId: String) -> Bool {
        guideStore.isLoading(deviceId: deviceId)
    }

    func guideEntries(deviceId: String, channelNum: String) -> [GuideEntry] {
        guideStore.entries(deviceId: deviceId, channelNum: channelNum)
    }


    // O(1) channel logo URL lookup for channelMenu — depends only on guideByDevice, which
    // changes on guide load (~hourly), not per idle tick. Called from guideByDevice's didSet
    // and once after fetchAllGuides — deliberately NOT from rebuildMenuEntries() itself, since
    // that also runs every idle tick and guideByDevice won't have changed on most of those.
    private func rebuildChannelImageURLs() {
        var imageURLs: [String: String] = [:]
        for (deviceId, channels) in guideByDevice {
            for ch in channels {
                if let url = ch.ImageURL, !url.isEmpty {
                    imageURLs["\(deviceId):\(ch.GuideNumber)"] = url
                }
            }
        }
        channelImageURLs = imageURLs
    }

    func rebuildMenuEntries() {
        let now = Date()

        // ── O(1) managed-show lookup dicts (WatchNowView + scheduledMenu) ─────
        var bySeriesID: [String: Show] = [:]
        var byTitle:    [String: [Show]] = [:]
        for show in shows {
            if !show.show_seriesid.isEmpty { bySeriesID[show.show_seriesid] = show }
            byTitle[show.show_title, default: []].append(show)
        }
        managedShowBySeriesID = bySeriesID
        managedShowByTitle    = byTitle

        // ── Scheduled menu: guide entry + upcoming slots per active show ──────
        // Include recording shows in candidateShows so conflict detection catches them too.
        let candidateShows = shows.filter { $0.show_active && !$0.show_paused }
        var scheduledResult: [String: GuideEntry] = [:]
        var upcomingResult:  [String: [(channel: String, date: Date)]] = [:]
        for show in candidateShows {
            let schNext = show.show_next ?? .distantFuture
            // Replicate scheduledMenu's schEntry logic: direct match first, series fallback
            let direct = guideStore.entries(deviceId: show.hdhr_record, channelNum: show.show_channel)
            if let hit = direct.first(where: { abs($0.startDate.timeIntervalSince(schNext)) < 5 * 60 }) {
                scheduledResult[show.show_id] = hit
            } else if show.show_use_seriesid, !show.show_seriesid.isEmpty {
                // dev is always the show's assigned tuner — SeriesID(All) differs from
                // SeriesID(Channel) only in channel scope, not device scope.
                let ch  = show.show_use_seriesid_all ? nil : show.show_channel
                let dev = show.hdhr_record
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

        // ── Conflict detection: per-device greedy tuner-slot simulation, one pass instead of
        // one per menu open. Flags only the show(s) that would actually lose a tuner — not
        // every member of an over-capacity cluster — by walking each device's shows in
        // (show_next, favorite-first tiebreak) order and assigning the first free slot,
        // mirroring the real recording-start priority (see the favorite-first sort below in
        // this same function). Not a lookahead optimizer — real arbitration is retry-based at
        // runtime — but this tracks the same priority signal the real system uses.
        let deviceMap = Dictionary(uniqueKeysWithValues: devices.compactMap { d -> (String, Int)? in
            guard let t = d.TunerCount, t > 0 else { return nil }
            return (d.DeviceID, t)
        })
        var newConflicts = Set<String>()
        var newBeatenByFavorite = Set<String>()
        let byDevice = Dictionary(grouping: candidateShows.filter { $0.show_next != nil && $0.show_end != nil },
                                   by: { $0.hdhr_record })
        for (deviceId, deviceShows) in byDevice {
            guard let tunerCount = deviceMap[deviceId] else { continue }
            let ordered = deviceShows.sorted { a, b in
                let an = a.show_next!, bn = b.show_next!
                if an != bn { return an < bn }
                let af = isFavoriteChannel(a), bf = isFavoriteChannel(b)
                if af != bf { return af && !bf }
                return a.show_id < b.show_id
            }
            var slotFreeAt = [Date](repeating: .distantPast, count: tunerCount)
            for show in ordered {
                let next = show.show_next!, end = show.show_end!
                if let slot = slotFreeAt.firstIndex(where: { $0 <= next }) {
                    slotFreeAt[slot] = end
                } else {
                    newConflicts.insert(show.show_id)
                    if !isFavoriteChannel(show) {
                        let beatenByFavorite = ordered.contains { other in
                            other.show_id != show.show_id && isFavoriteChannel(other)
                            && other.show_next! <= next && other.show_end! > next
                        }
                        if beatenByFavorite { newBeatenByFavorite.insert(show.show_id) }
                    }
                }
            }
        }
        conflictingShowIDs = newConflicts
        conflictBeatenByFavorite = newBeatenByFavorite
    }

    // Refreshes the menu cache (gated on menuIsOpen to avoid the documented menu-rebuild-churn
    // glitch) and pushes the change to the web UI, in that order — every show lifecycle path
    // (add/update/pause/resume/delete, plus the mid-flight re-broadcasts after scheduleNextAir
    // resolves real data) does this same pair so the web guide's conflict badge and schedule
    // reflect the change immediately instead of waiting for the next unrelated rebuild.
    func pushShowUpdate(type: String, channel: String, device: String, rebuildMenu: Bool = true) {
        if rebuildMenu, !menuIsOpen { rebuildMenuEntries() }
        webServer.broadcastGuideChangeEvent(type: type, extra: ["channel": channel, "device": device], state: self)
    }

    func upcomingGuideEpisodes(seriesID: String, after: Date = Date(), limit: Int = 4) -> [(channel: String, entry: GuideEntry)] {
        guideStore.nextEpisodes(seriesID: seriesID, after: after, limit: limit)
            .map { ($0.channelNum, $0.entry) }
    }

    func nextGuideEpisode(for show: Show) -> (channel: String, entry: GuideEntry)? {
        guard show.show_use_seriesid, !show.show_seriesid.isEmpty else { return nil }
        // deviceFilter is always the show's assigned tuner (hdhr_record) — SeriesID(All) differs
        // from SeriesID(Channel) only in channel scope, not device scope.
        let channelFilter: String? = show.show_use_seriesid_all ? nil : show.show_channel
        let deviceFilter: String? = show.hdhr_record
        guard let match = guideStore.nextEpisode(seriesID: show.show_seriesid,
                                                 channelNum: channelFilter,
                                                 deviceId: deviceFilter) else { return nil }
        return (match.channelNum, match.entry)
    }

    // MARK: - Add show from guide entry (called by menu)

    func addShowFromGuide(entry: GuideEntry, type: ShowState, device: HDHRDevice, channel: LineupEntry, airDays: [String]? = nil, transcode: String? = nil, bonusTime: Bool = false, titleOverride: String? = nil) {
        // Use the default directory automatically; user can override per-show via Edit.
        let folder = defaultSaveDir

        var show = Show.blank(channel: channel.GuideNumber, device: device.DeviceID)
        show.show_transcode  = transcode ?? config.Default_transcode
        show.show_bonus_time = bonusTime
        // For SeriesID types, strip any episode-specific suffix (e.g. " S24E116 Trey Parker…")
        // so the show is named after the series, not a single airing.
        let rawTitle = entry.Title
        show.show_title = (type == .seriesChannel || type == .seriesAll)
            ? Show.seriesTitle(from: rawTitle)
            : rawTitle
        if let override = titleOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            show.show_title = override
        }
        show.show_length    = entry.durationMinutes
        show.show_next      = entry.startDate
        show.show_end       = entry.endDate
        show.show_seriesid  = entry.SeriesID ?? ""
        show.show_logo_url  = entry.ImageURL ?? ""
        show.show_url       = channel.URL ?? ""
        show.show_genre     = entry.firstGenre ?? ""
        show.show_dir       = folder.path
        show.show_temp_dir  = Show.localFallbackDir

        // Local decimal hour from guide start time (matches what the user sees in the guide)
        let comps = Calendar.current.dateComponents([.hour, .minute], from: entry.startDate)
        show.show_time = Double(comps.hour ?? 20) + Double(comps.minute ?? 0) / 60.0

        let allDays = Show.weekdayNames
        switch type {
        case .single:
            show.show_is_series = false; show.show_use_seriesid = false; show.show_use_seriesid_all = false
            show.show_air_date = airDays ?? []
        case .dateTime:
            show.show_is_series = true; show.show_use_seriesid = false; show.show_use_seriesid_all = false
            if let days = airDays, !days.isEmpty {
                show.show_air_date = days
            } else {
                let weekday = Calendar.current.component(.weekday, from: entry.startDate)
                show.show_air_date = [Show.weekdayNames[weekday - 1]]
            }
        case .seriesChannel:
            show.show_is_series = true; show.show_use_seriesid = true; show.show_use_seriesid_all = false
            show.show_air_date = allDays
            resolveSeriesAir(show: &show, device: device, isAll: false, channel: channel)
        case .seriesAll:
            show.show_is_series = true; show.show_use_seriesid = true; show.show_use_seriesid_all = true
            show.show_air_date = allDays
            resolveSeriesAir(show: &show, device: device, isAll: true, channel: channel)
        }

        addShow(show) // conflict check, "Show Added" notify/Discord, and web broadcast all happen there
    }

    // Tie-break for SeriesID(All) shows simulcast/rerun on multiple channels of the same device
    // at the identical time — prefer the channel the user has favorited over the arbitrary
    // insertion-order winner GuideStore would otherwise return. See GuideStore.nextEpisode/currentEpisode.
    func isFavoriteChannel(deviceId: String, channelNum: String) -> Bool {
        lineups[deviceId]?.first(where: { $0.GuideNumber == channelNum })?.isFavorite ?? false
    }

    // Checks currently-airing first so show_next may be in the past — idle loop records the remaining portion.
    // devFilter is always the device being added from — SeriesID(All) differs from SeriesID(Channel)
    // only in channel scope (any channel on that device vs. one fixed channel), not device scope;
    // both are confined to a single assigned tuner (see CLAUDE.md's "Web guide managed markers"
    // invariant and the seriesAll-scoping fix this is part of).
    func resolveSeriesAir(show: inout Show, device: HDHRDevice, isAll: Bool, channel: LineupEntry) {
        let chFilter  = isAll ? nil : channel.GuideNumber
        let devFilter = device.DeviceID
        let now       = Date()

        // Helper: apply a SeriesMatch to the show — uses m.deviceId for lineup lookup. devFilter
        // above pins every search to `device.DeviceID`, so m.deviceId is always that same device
        // for both SeriesID(All) and SeriesID(Channel); this just keeps that assignment explicit
        // rather than assuming it.
        func apply(_ m: GuideStore.SeriesMatch) {
            // SeriesID is trusted as authoritative by currentEpisode/nextEpisode (a differently
            // formatted display title across affiliates is normal for a genuinely correct match),
            // so this doesn't reject the match — but a title this far off is exactly the shape of a
            // guide-provider crosswalk error (an unrelated program mistagged with this show's own
            // SeriesID). Log loudly so a real mistagging incident is visible instead of silently
            // scheduling the wrong episode.
            if Show.seriesTitle(from: m.entry.Title) != show.show_title {
                glog("[\(show.show_title)] resolveSeriesAir: matched entry title is \"\(m.entry.Title)\" — possible guide provider mistagging, using it anyway", level: .warning)
            }
            show.show_next    = m.entry.startDate
            show.show_end     = m.entry.endDate
            show.show_channel = m.channelNum
            show.hdhr_record  = m.deviceId
            if let url = hdhrManager.streamURL(for: m.channelNum, lineup: lineups[m.deviceId] ?? []) {
                show.show_url = url
            }
        }

        if let m = guideStore.currentEpisode(seriesID: show.show_seriesid, channelNum: chFilter, deviceId: devFilter, at: now, preferFavorite: isFavoriteChannel) {
            apply(m); return
        }
        // Fallback: title match on channelEntryIndex — handles guide entries where SeriesID is
        // absent. chFilter is nil for SeriesID(All) (scans every channel on devFilter's device);
        // devFilter is always set, so this never scans devices beyond the one being added from.
        if let m = guideStore.currentEntryByTitle(show.show_title, channelNum: chFilter, deviceId: devFilter, at: now) {
            apply(m); return
        }
        if let m = guideStore.nextEpisode(seriesID: show.show_seriesid, channelNum: chFilter, deviceId: devFilter, after: now, preferFavorite: isFavoriteChannel) {
            apply(m); return
        }
        // Fallback: title match for next airing — handles guide entries where SeriesID is absent.
        if let m = guideStore.nextEntryByTitle(show.show_title, channelNum: chFilter, deviceId: devFilter, after: now) {
            apply(m); return
        }
    }

    // ~/Movies is TCC-free for non-sandboxed apps and visible in the Finder sidebar.
    var defaultSaveDir: URL {
        let stored = UserDefaults.standard.string(forKey: "defaultSaveDirectory") ?? ""
        if !stored.isEmpty { return URL(fileURLWithPath: stored) }
        if !config.Hdhr_setup_folder.isEmpty { return URL(fileURLWithPath: config.Hdhr_setup_folder) }
        let dir = URL(fileURLWithPath: Show.localFallbackDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
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

    // Lightweight 1Hz timer driving the menu bar blink (independent of the idle-loop timer above,
    // which does much heavier network/bookkeeping work on a much slower cadence).
    func startStatusLightTimer() {
        statusLightTimer?.invalidate()
        statusLightTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickStatusLight() }
        }
    }

    // 6s cycle: lit 5s, off 1s. No-ops (beyond resetting to lit) when blink is disabled or nothing
    // is recording/up-next. Deliberately NOT gated on menuIsOpen — unlike rebuildMenuEntries() and
    // friends, this only feeds the MenuBarExtra *label* (never MenuContent, the dropdown itself),
    // and menuIsOpen can get stuck true from SwiftUI's eager startup build of the dropdown content
    // (see the "Silently open+close" comment on statusLabel in hdhr_VCRApp.swift) — gating on it
    // here would silently block the blink indefinitely on a fresh launch until the user's first
    // real menu open/close.
    private func tickStatusLight() {
        guard config.Status_light_blink_enabled,
              isRecording || (nextShowMinutes.map { $0 <= 30 } ?? false) else {
            if !statusLightOn { statusLightOn = true }
            return
        }
        let cyclePosition = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 6.0)
        let newValue = cyclePosition < 5.0
        if statusLightOn != newValue { statusLightOn = newValue }
    }

    // Reentrancy guard: startTimer() fires a new Task every Idle_timer_interval regardless of
    // whether the previous idleLoop() finished. Pass 1/Pass 2 below await real network calls
    // (scheduleNextAir → guideStore.load) that can exceed the tick interval under network stress;
    // without this guard, two overlapping idleLoop() runs could both act on `shows` at once.
    private var idleLoopRunning = false

    func idleLoop() async {
        guard !idleLoopRunning else { return }
        idleLoopRunning = true
        defer { idleLoopRunning = false }
        let now = Date()
        var dirty = false

        // If startup discovery failed, keep retrying — single attempt per tick so we return quickly.
        // Falls through to Pass 1/Pass 2 below even while devices is empty, so stale show_recording
        // flags (e.g. a reattached recording whose show_end has passed) still get cleared during a
        // prolonged discovery outage instead of leaving the menu bar stuck showing "recording".
        if devices.isEmpty {
            await discoverDevices(knownHosts: knownHostsFromShows(), attempts: 1)
            if !devices.isEmpty { await fetchAllGuides() }
        }

        if !devices.isEmpty {
            // If guide is missing for any device (fetch failed at startup), load it now
            for device in devices where guideStore.channels(deviceId: device.DeviceID).isEmpty {
                ensureGuideLoaded(for: device.DeviceID)
            }

            // Warn if any active show is assigned to a device we can no longer see
            let knownIDs = Set(devices.map { $0.DeviceID })
            for show in activeShows where !show.hdhr_record.isEmpty && !knownIDs.contains(show.hdhr_record) {
                glog("[\(show.show_title)] device \(show.hdhr_record) not found — show may miss its recording", level: .warning)
            }

            // Probe for newly-connected tuners every 5 minutes.
            // If any device was missed on a probe, follow up every 60 s until confirmed gone (3 misses).
            let quickProbeDue = nextQuickProbe.map { now >= $0 } ?? false
            if now.timeIntervalSince(lastDeviceProbe) > 300 {
                lastDeviceProbe = now
                nextQuickProbe = nil
                Task { await probeForNewDevices() }
            } else if quickProbeDue {
                nextQuickProbe = nil
                Task { await probeForNewDevices() }
            }
        }

        // Refresh lineup + guide at each hour boundary (aligned with web UI's 30-min window slide)
        let currentHour = Calendar.current.component(.hour, from: now)
        if lastRefreshHour != currentHour {
            lastRefreshHour = currentHour
            Task { await refreshGuides() }
        }
        // While Local Network permission hasn't been confirmed working yet, retry the lineup
        // fetch on every idle-loop tick instead of only the hourly boundary above — see TODO.md's
        // "Show Stoppers" entry. The system's permission prompt can be granted at any moment
        // independent of anything this app does (confirmed: a reboot triggered it once), and
        // there's no public API to detect that directly; polling on the existing idle cadence
        // means success is picked up within one tick instead of requiring a manual relaunch or
        // waiting up to an hour. Stops mattering on its own once
        // confirmLocalNetworkAccessIfNeeded() flips the flag.
        if !config.Local_network_confirmed, !devices.isEmpty, !lineupConfirmRetryInFlight {
            lineupConfirmRetryInFlight = true
            Task {
                await fetchAllLineups(for: devices)
                lineupConfirmRetryInFlight = false
            }
        }
        // Pass 1: stop all completed recordings before any new ones start.
        // Iterate by show_id, not index — stopRecording awaits (scheduleNextAir's guide fetch
        // among others), during which `shows` can be mutated by an interleaved event (a web-UI
        // delete, another overlapping tick if the reentrancy guard above is ever bypassed). An
        // index captured before the loop started could be out of range or point at a different
        // show by the time it's used; re-resolving by show_id each iteration is always safe.
        let stopIds = shows.indices.compactMap { i -> String? in
            guard shows[i].show_active, shows[i].show_recording,
                  let end = shows[i].show_end, end <= now else { return nil }
            return shows[i].show_id
        }
        for showId in stopIds {
            guard let i = shows.firstIndex(where: { $0.show_id == showId }),
                  shows[i].show_active, shows[i].show_recording,
                  let end = shows[i].show_end, end <= now else { continue }
            await stopRecording(index: i, natural: true)
            dirty = true
        }

        // Pass 2: per-show housekeeping — notifications, fail detection, stranded advance.
        // Same show_id re-resolution as Pass 1 above, for the same reason (this loop also awaits
        // scheduleNextAir at two points below).
        for showId in shows.map({ $0.show_id }) {
            guard let i = shows.firstIndex(where: { $0.show_id == showId }) else { continue }
            let show = shows[i]
            guard show.show_active else { continue }
            let nextDate = show.show_next ?? .distantFuture
            let endDate  = show.show_end  ?? .distantPast

            // Auto-resume paused shows:
            // - window expired (failed/stopped): advance to next airing and un-pause
            // - next airing imminent (skip): just un-pause so recording starts next tick
            // The `nextDate > now` guard on the second branch is load-bearing: after a
            // fail-threshold pause, show_next still points at the *airing that just failed*
            // (already in the past) until scheduleNextAir runs. Without the guard,
            // `nextDate <= now + 10` was trivially true every tick for the rest of that
            // show's window, so a signal dropout mid-episode retried in a ~20s loop for the
            // whole remaining hour instead of staying paused until the window actually ended.
            // Because show_next never moves while paused, this second branch can now only fire
            // for a show that pauses with its *own* show_next still in the near future (e.g. an
            // instant pre-recording failure with no retry cooldown) — most fail-threshold pauses
            // happen well after show_next has passed, so expect `endDate <= now` above to be the
            // common resume path in practice.
            if show.show_paused {
                if endDate <= now {
                    shows[i].show_paused = false
                    shows[i].clearFailures()
                    showRetryAfter.removeValue(forKey: show.show_id)
                    glog("[\(show.show_title)] auto-resuming — paused window expired, rescheduling")
                    await scheduleNextAir(index: i)
                    dirty = true
                } else if nextDate > now, nextDate <= now + 10 {
                    shows[i].show_paused = false
                    shows[i].clearFailures()
                    showRetryAfter.removeValue(forKey: show.show_id)
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

            // Show window is open and we're not recording — warn once per window if we're past
            // the start time with no obvious reason (not tuner-full, not paused, not handled above).
            // Fires once per "showId-epoch" key so retrying shows don't spam the log every tick.
            if !show.show_recording, nextDate < now - 30, endDate > now {
                let missedEpoch = show.show_next?.timeIntervalSince1970 ?? 0
                if missedStartNotifiedEpochs[show.show_id] != missedEpoch {
                    missedStartNotifiedEpochs[show.show_id] = missedEpoch
                    glog("[\(show.show_title)] MISSED START — window open since \(shortTime(show.show_next)), still not recording", level: .warning)
                }
            }

            if show.show_recording, endDate > now, !recordingManager.isRunning(showId: show.show_id) {
                pendingDiscordStart.remove(show.show_id) // never confirmed; skip the start embed
                // readAndClearHDHRError must run before teardownRecordingState — teardown calls
                // stop() which clears the header file entry, losing the error before we can read it.
                let hdhrReason = recordingManager.readAndClearHDHRError(showId: show.show_id)
                let exitReason = recordingManager.readAndClearExitStatus(showId: show.show_id)
                teardownRecordingState(index: i) // kills pid (harmless), releases assertion, clears caches
                let failReason = hdhrReason ?? exitReason ?? "curl exited unexpectedly"
                recordShowFailure(index: i, reason: failReason)
                failedThisAttempt.insert(show.show_id) // consumed by stopRecording's empty-file check
                glog("[\(show.show_title)] FAIL \(failReason) — fail_count=\(shows[i].show_fail_count)", level: .error)
                // Only notify on persistent failures (2+ in a row) to avoid spamming user during transient retries.
                // Show will be paused and notified if fail_count reaches the threshold.
                if shows[i].show_fail_count > 1 {
                    notify("Recording Failed", body: show.show_title, subtitle: failReason)
                    // Reuse this recording's card (created by the start or a prior failure) so the
                    // eventual start/complete stays on the same card. Don't clear the id on failure.
                    fireDiscordCard(showId: show.show_id, event: "❌ Recording Failed", color: 0xE74C3C,
                                    enabled: config.Discord_on_failed,
                                    extra: [("Reason", failReason, false), ("Fail Count", "\(shows[i].show_fail_count)", true)])
                }
                dirty = true
            }

            // First idle-loop confirmation: curl is alive — now send the deferred "Recording Started" embed
            if show.show_recording, pendingDiscordStart.contains(show.show_id),
               recordingManager.isRunning(showId: show.show_id) {
                pendingDiscordStart.remove(show.show_id)
                let endsStr = shortTime(shows[i].show_end ?? Date())
                fireDiscordCard(showId: show.show_id, event: "🔴 Recording Started", color: 0x2ECC71,
                                enabled: true, extra: [("Ends", endsStr, true)])
            }

            // Discord progress update — edit start embed once per 5-min boundary during active recordings
            // isRunning guard is load-bearing: the mid-recording FAIL branch above tears down the
            // recording (show_recording = false, live) but does not `continue`, so `show` here is a
            // stale snapshot still reading show_recording == true with discord_start_msg_id set —
            // without the liveness check this would post a bogus "In Progress" edit for a just-died
            // recording, bypassing the discordCardTasks serialization chain.
            if show.show_recording, recordingManager.isRunning(showId: show.show_id),
               !show.discord_start_msg_id.isEmpty,
               config.Discord_on_progress, config.Discord_enabled, !config.Discord_webhook_url.isEmpty {
                guard let showStart = show.show_next else { continue }
                let elapsedSec = Int(now.timeIntervalSince(showStart))
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
            guard next <= now + 10 && end > now else { return false }
            if let retryAfter = showRetryAfter[s.show_id], now < retryAfter { return false }
            return true
        }.sorted { isFavoriteChannel(shows[$0]) && !isFavoriteChannel(shows[$1]) }
        if !readyIndices.isEmpty { dirty = true }
        // Re-resolve each show by show_id inside the loop rather than reusing the captured Int
        // index across `await startRecording`. startRecording can now suspend internally (its
        // SeriesID re-check calls `await scheduleNextAir` on a failed guide reconfirmation) —
        // resolving by id (and re-checking the ready predicate) right before each call keeps
        // this consistent with Pass 1/Pass 2 so that suspension can't act on a stale/
        // out-of-range index after an interleaved delete/add mutates `shows`.
        let readyIds = readyIndices.map { shows[$0].show_id }
        for id in readyIds {
            guard let i = shows.firstIndex(where: { $0.show_id == id }) else { continue }
            let s = shows[i]
            guard s.show_active, !s.show_recording, !s.show_paused,
                  let next = s.show_next, let end = s.show_end, next <= now + 10, end > now else { continue }
            if let retryAfter = showRetryAfter[s.show_id], now < retryAfter { continue }
            await startRecording(index: i)
        }

        if dirty { saveConfig() }

        // One /status.json fetch per device covers both menu-header occupancy counts and
        // per-recording vstatus — avoids O(tunerCount) separate HTTP calls per recording.
        for device in devices {
            Task { await fetchDeviceStatus(for: device) }
        }

        // Re-sync menu caches with current show states (show_next changes after recordings complete).
        // Skip while the menu is open — @Published changes would cause SwiftUI to redraw it mid-display.
        if !menuIsOpen { rebuildMenuEntries() }

        if webServerRunning { webServer.updateTXTRecord() }

        // Log untagged (no genre) guide entries as they start airing, once per slot.
        // Helps discover new infomercial SeriesIDs to add to the hidden-by-default filter.
        // Gated to every 5 minutes rather than every tick — this is a full device×channel guide
        // walk (guideStore.entries() filters each channel's entries) purely for diagnostic
        // discovery, not anything a program's actual air time depends on.
        if now.timeIntervalSince(lastNowAiringScan) > 300 {
            lastNowAiringScan = now
            for device in devices {
                for ch in (lineups[device.DeviceID] ?? []) {
                    let entries = guideStore.entries(deviceId: device.DeviceID, channelNum: ch.GuideNumber)
                    for e in entries where e.StartTime <= Int(now.timeIntervalSince1970) && e.EndTime > Int(now.timeIntervalSince1970) {
                        guard e.firstGenre == nil else { continue }
                        let key = "\(ch.GuideNumber):\(e.StartTime)"
                        guard !loggedNowAiring.contains(key) else { continue }
                        // Bound growth on a long-running session — keys use absolute StartTimes that
                        // never recur, so reset once large (a rare re-log burst is fine for a diagnostic).
                        if loggedNowAiring.count > 2000 { loggedNowAiring.removeAll(keepingCapacity: true) }
                        loggedNowAiring.insert(key)
                        let sid = e.SeriesID ?? "none"
                        if !GuideEntry.knownInfomercialSeriesIDs.contains(sid) && e.Title != "Paid Programming" {
                            glog("[NowAiring] \(ch.GuideNumber) \(ch.GuideName) — \(e.Title) SeriesID=\(sid)")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Recording

    // Records a failed recording attempt and starts a cooldown so the idle loop's readyIndices
    // filter won't retry the same show again until it expires — avoids burning through
    // Fail_count_setting in rapid-fire retries (one per Idle_timer_interval) on a transient blip.
    private func recordShowFailure(index: Int, reason: String) {
        shows[index].recordFailure(reason: reason)
        let loops = Self.retryBackoffLoops[min(shows[index].show_fail_count - 1, Self.retryBackoffLoops.count - 1)]
        showRetryAfter[shows[index].show_id] = Date().addingTimeInterval(Double(loops) * Double(config.Idle_timer_interval))
    }

    func startRecording(index: Int) async {
        var show = shows[index]
        guard !show.show_recording else { return }
        // Skip if the assigned device is absent or unavailable — avoids burning fail count on a dead tuner.
        guard let device = devices.first(where: { $0.DeviceID == show.hdhr_record }) else {
            glog("[\(show.show_title)] device \(show.hdhr_record) not in device list — skipping recording start", level: .warning)
            return
        }
        if !device.isAvailable {
            glog("[\(show.show_title)] device \(show.hdhr_record) unavailable — skipping recording start", level: .warning)
            return
        }
        // SeriesID-based shows only: show_next may have been locked in from an earlier
        // successful guide match and never reconfirmed since (see scheduleNextAir's "no
        // episode found in guide — show_next already future, leaving unchanged" warning) —
        // recording would otherwise fire blind on a stale time and capture whatever's
        // actually airing, not necessarily this show (e.g. a live preemption the guide has
        // since caught up to). Final live re-check, same SeriesID-then-title trust tiers
        // scheduleNextAir itself uses, right before actually recording.
        if show.show_use_seriesid {
            // The title-only fallback must run even when show_seriesid is empty — a series
            // show added from a guide entry that lacked SeriesID data (GuideStore's
            // currentEntryByTitle/nextEntryByTitle exist specifically for this, and
            // scheduleNextAir already calls the title tier unconditionally) would otherwise
            // get zero protection from this guard, the exact gap it exists to close.
            let confirmed = (!show.show_seriesid.isEmpty && guideStore.currentEpisode(seriesID: show.show_seriesid,
                                channelNum: show.show_channel, deviceId: show.hdhr_record, at: Date()) != nil)
                         || guideStore.currentEntryByTitle(show.show_title,
                                channelNum: show.show_channel, deviceId: show.hdhr_record, at: Date()) != nil
            if !confirmed {
                glog("[\(show.show_title)] guide no longer confirms this airing at record time — skipping, will re-resolve", level: .warning)
                notify("Recording Skipped", body: show.show_title, subtitle: "Guide no longer confirms this airing")
                shows[index].show_next = nil
                await scheduleNextAir(index: index)
                // Re-resolve by show_id — scheduleNextAir may have moved this show to a
                // different channel/device (seriesAll) or reordered `shows` via its own
                // internal awaits. Mirrors updateShow's identical re-broadcast pattern.
                if let updated = shows.first(where: { $0.show_id == show.show_id }) {
                    pushShowUpdate(type: "show_updated", channel: updated.show_channel, device: updated.hdhr_record, rebuildMenu: false)
                }
                return
            }
        }
        // Enforce tuner limit: skip if all slots on this device are already occupied
        if tunersFull(for: show.hdhr_record) {
            let tunerCount = device.TunerCount ?? 0
            glog("[\(show.show_title)] TUNER FULL \(show.hdhr_record) — skipping start", level: .warning)
            // Fire conflict notification once per show+episode window to avoid per-tick spam.
            let conflictEpoch = show.show_next?.timeIntervalSince1970 ?? 0
            if conflictNotifiedEpochs[show.show_id] != conflictEpoch {
                conflictNotifiedEpochs[show.show_id] = conflictEpoch
                notify("Tuner Conflict", body: show.show_title,
                       subtitle: "All tuners on \(show.hdhr_record) are busy")
                discordShow("⚠️ Tuner Conflict", show: show, color: 0xF1C40F,
                            enabled: config.Discord_on_conflict,
                            extra: [("Note", "All \(tunerCount) tuners on \(show.hdhr_record) are busy", false)])
            }
            return
        }
        if show.show_url.isEmpty {
            if let lu = lineups[show.hdhr_record],
               let url = hdhrManager.streamURL(for: show.show_channel, lineup: lu) {
                shows[index].show_url = url; show.show_url = url
            } else {
                glog("[\(show.show_title)] NO STREAM URL — ch=\(show.show_channel) device=\(show.hdhr_record)", level: .error)
                recordShowFailure(index: index, reason: "No stream URL for ch \(show.show_channel) on \(show.hdhr_record)"); return
            }
        }
        if show.show_fail_count == failThreshold - 1 {
            glog("[\(show.show_title)] WARNING — fail_count=\(show.show_fail_count)/\(failThreshold), one more failure will pause this show", level: .warning)
        }
        guard show.show_fail_count < failThreshold else {
            let lastReason = show.show_fail_reason.isEmpty ? "unknown" : show.show_fail_reason
            glog("[\(show.show_title)] PAUSED — fail threshold \(failThreshold) reached (last: \(lastReason))", level: .warning)
            if show.state == .single {
                shows[index].show_active = false  // singles auto-clean on restart; no point keeping them
            } else {
                shows[index].show_paused = true   // recoverable; auto-resumes after window expires
            }
            notify("Recording Paused", body: show.show_title, subtitle: "Failed \(failThreshold)× (\(lastReason)) — will retry next airing")
            // Terminal for this lifecycle: update the failure card to "Paused" (reusing/capturing
            // the same message id as every other event in this recording's lifecycle — never a
            // fresh POST), then clear the id so the next airing's attempt starts a fresh card.
            fireDiscordCard(showId: show.show_id, event: "⏸ Recording Paused", color: 0xE67E22,
                            enabled: config.Discord_on_paused,
                            extra: [("Reason", "Failed \(failThreshold)× (\(lastReason)) — will retry next airing", false)],
                            clearIdAfter: true)
            conflictNotifiedEpochs.removeValue(forKey: show.show_id)
            missedStartNotifiedEpochs.removeValue(forKey: show.show_id)
            return
        }
        guard diskOK(for: show) else {
            glog("[\(show.show_title)] DISK FULL — skipping recording", level: .warning)
            recordShowFailure(index: index, reason: "Disk over \(Int(maxDiskPct))% — free up space")
            notify("Recording Skipped", body: show.show_title, subtitle: "Disk over \(Int(maxDiskPct))%")
            fireDiscordCard(showId: show.show_id, event: "💾 Recording Skipped", color: 0xE67E22,
                            enabled: config.Discord_on_skipped,
                            extra: [("Reason", "Disk over \(Int(maxDiskPct))% — free up space", false)])
            return
        }
        var seriesSubfolder: String? = nil
        var episodeTag: String? = nil
        if config.Series_subfolder_enabled && show.isSeries {
            let safeTitle = show.show_title.replacingOccurrences(of: "/", with: "-")
            let epNum = guideEntryForShow(show)?.EpisodeNumber
            episodeTag = epNum
            if let epNum, let season = seasonNumber(from: epNum) {
                seriesSubfolder = "\(safeTitle)/Season \(String(format: "%02d", season))"
            } else {
                seriesSubfolder = safeTitle
            }
        }
        // Skip already-recorded episode: if this exact SxxExx is already on disk for this series,
        // advance to the next airing instead of recording a duplicate (rerun/simulcast). Gated under
        // Series subfolders; needs a full season+episode tag (season-only can't identify one episode).
        // show_ignore_duplicate_once is a per-show override (set in the Add/Edit dialog) that bypasses
        // this — checked regardless of the override so duplicateOverrideUsedThisAttempt only records
        // that the override actually suppressed a real skip, not merely that it happened to be on.
        // Reset first — fresh attempt — so a marker left over from an earlier attempt on this same
        // show that never reached stopRecording (e.g. LAUNCH ERROR below) can't cause a later,
        // genuinely non-duplicate success to be misread as "this is the one that used the override".
        duplicateOverrideUsedThisAttempt.remove(show.show_id)
        if let tag = episodeTag,
           duplicateEpisodeTag(title: show.show_title, episodeTag: tag, baseDir: show.posixRecordDir) != nil {
            if show.show_ignore_duplicate_once {
                duplicateOverrideUsedThisAttempt.insert(show.show_id)
            } else {
                glog("[\(show.show_title)] SKIP \(tag) — already recorded")
                notify("Recording Skipped", body: show.show_title, subtitle: "\(tag) already recorded")
                fireDiscordCard(showId: show.show_id, event: "🔁 Skipped — already recorded",
                                color: 0x95A5A6, enabled: config.Discord_on_duplicate,
                                extra: [("Episode", tag, true)])
                await scheduleNextAir(index: index)   // like a completed airing — no fail-count change
                return
            }
        }
        let path = show.outputPath(date: show.show_next ?? Date(), subfolder: seriesSubfolder, episodeTag: episodeTag)
        let recordDir = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: recordDir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            glog("[\(show.show_title)] createDirectory failed for \(recordDir): \(error)", level: .error)
        }
        if !show.show_dir.isEmpty, show.posixRecordDir != show.show_dir {
            glog("[\(show.show_title)] Primary folder unavailable — recording to fallback: \(show.posixRecordDir)", level: .warning)
        }
        var endDate = show.show_end ?? Date().addingTimeInterval(Double(show.show_length) * 60)
        // Bonus Time: extend recording past the guide end when enabled on a show
        if config.Sports_padding_enabled && show.show_bonus_time {
            endDate = endDate.addingTimeInterval(Double(config.Sports_padding_minutes) * 60)
            glog("[\(show.show_title)] Bonus Time +\(config.Sports_padding_minutes) min applied")
        }
        // Always persist endDate so the idle-loop natural-stop check and notifications use it
        shows[index].show_end = endDate
        let remainingSecs = max(60, Int(endDate.timeIntervalSince(Date())))
        glog("[\(show.show_title)] START ch=\(show.show_channel) dur=\(remainingSecs)s transcode=\(show.show_transcode) → \(path)")
        do {
            try recordingManager.start(showId: show.show_id, title: show.show_title,
                                       url: show.show_url,
                                       outputPath: path, durationSeconds: remainingSecs,
                                       transcode: show.show_transcode, showEnd: endDate,
                                       verbose: config.Verbose_curl,
                                       networkInterface: config.Network_interface)
        } catch {
            glog("[\(show.show_title)] LAUNCH ERROR: \(error)", level: .error)
            recordShowFailure(index: index, reason: "Launch failed: \(error.localizedDescription)")
            notify("Recording Failed", body: show.show_title, subtitle: "Could not launch — \(error.localizedDescription)")
            fireDiscordCard(showId: show.show_id, event: "❌ Recording Failed", color: 0xE74C3C,
                            enabled: config.Discord_on_failed,
                            extra: [("Reason", "Launch failed: \(error.localizedDescription)", false)])
            return
        }
        shows[index].show_recording = true; shows[index].show_recording_path = path
        failedThisAttempt.remove(show.show_id) // fresh attempt — any earlier FAIL no longer describes "this" recording
        webServer.broadcastRecordingEvent(type: "recording_started", channel: shows[index].show_channel, device: shows[index].hdhr_record, state: self)
        refreshTunerOccupancy()
        // Stamp notify_recording_time so the "Recording Soon" pre-notification won't re-fire
        shows[index].notify_recording_time = Date().addingTimeInterval(config.Notify_recording * 60)
        // Save immediately so show_recording_path is on disk before any signal can kill the app.
        // The idle loop also saves at the end of the tick, but this closes the SIGKILL window.
        saveConfig()
        notify("Recording Started", body: show.show_title, subtitle: "Channel \(show.show_channel) — ends \(shortTime(endDate))",
               categoryIdentifier: "recording.started", userInfo: ["show_id": show.show_id])
        // Capture message ID so completion/failure can edit this embed in-place.
        // Skip the Discord embed on the first relaunch after a quit-interrupted recording —
        // the startup "Recording Interrupted" embed already covered this session.
        let resumedAfterQuit = suppressStartDiscord.remove(show.show_id) != nil
        // Defer the "Recording Started" embed until the first idle-loop tick confirms the process
        // is still alive — avoids a Discord ping for a recording that fails in the first few seconds.
        if !resumedAfterQuit, config.Discord_on_start, config.Discord_enabled, !config.Discord_webhook_url.isEmpty {
            pendingDiscordStart.insert(show.show_id)
        }
    }

    func skipRecording(showId: String) async {
        guard let i = shows.firstIndex(where: { $0.show_id == showId }) else { return }
        glog("[\(shows[i].show_title)] SKIP — paused until next airing")
        pendingDiscordStart.remove(showId)
        recordingManager.stop(showId: showId)
        VLCPlayerWindowManager.shared.closeIfPlaying(showId: shows[i].show_id, url: shows[i].show_url)
        tunerStatus.removeValue(forKey: showId)
        // Clear signalDropoutTicks too, matching teardownRecordingState — skip doesn't route
        // through teardown, so otherwise a dropout tick count would linger past the skip.
        signalDropoutTicks.removeValue(forKey: showId)
        shows[i].show_recording = false
        shows[i].show_last = Date()
        shows[i].show_paused = true
        shows[i].show_fail_reason = "Skipped"
        let channel = shows[i].show_channel, device = shows[i].hdhr_record
        await scheduleNextAir(index: i)
        saveConfig()
        pushShowUpdate(type: "show_updated", channel: channel, device: device, rebuildMenu: false)
    }

    private func teardownRecordingState(index: Int) {
        let show = shows[index]
        recordingManager.stop(showId: show.show_id)
        tunerStatus.removeValue(forKey: show.show_id)
        signalDropoutTicks.removeValue(forKey: show.show_id)
        shows[index].show_recording = false
        shows[index].show_tuner_resource = ""
        // Optimistically clear this tuner's hardware-reported lock so the immediate broadcast
        // below (and activeTunerCount's max(hw, rec+vlc)) doesn't over-report occupancy for the
        // ~1.5s until refreshTunerOccupancy's next poll confirms the release.
        if !show.show_tuner_resource.isEmpty,
           let tuners = deviceTunerOccupancy[show.hdhr_record],
           let idx = tuners.firstIndex(where: { $0.Resource.lowercased() == show.show_tuner_resource }) {
            deviceTunerOccupancy[show.hdhr_record]?[idx] = DeviceTunerInfo(
                Resource: tuners[idx].Resource, VctNumber: nil,
                TargetIP: tuners[idx].TargetIP, SignalQualityPercent: tuners[idx].SignalQualityPercent)
        }
        webServer.broadcastRecordingEvent(type: "recording_stopped", channel: show.show_channel, device: show.hdhr_record, state: self)
    }

    func stopRecording(index: Int, natural: Bool) async {
        // Must read before teardownRecordingState — it calls RecordingManager.stop(), which
        // clears the curl header-dump file, losing any X-HDHomeRun-Error before the empty-file
        // check below could see it. Only relevant for natural stops (manual stop doesn't report
        // a failure reason).
        let hdhrReason = natural ? recordingManager.readAndClearHDHRError(showId: shows[index].show_id) : nil
        teardownRecordingState(index: index)
        let show = shows[index]
        refreshTunerOccupancy()
        shows[index].show_last = Date()

        if !natural {
            glog("[\(show.show_title)] STOP manual")
            pendingDiscordStart.remove(show.show_id) // embed not yet sent; discard pending
            shows[index].show_paused = true
            shows[index].show_fail_reason = "Manually stopped"
            conflictNotifiedEpochs.removeValue(forKey: show.show_id)
            missedStartNotifiedEpochs.removeValue(forKey: show.show_id)
            saveConfig()
            return
        }

        // Verify the output file was actually created and is non-empty
        let path = show.show_recording_path
        let fileAttrs = path.isEmpty ? nil : (try? FileManager.default.attributesOfItem(atPath: path))
        let fileSize  = fileAttrs?[.size] as? Int ?? 0

        if !path.isEmpty && fileSize == 0 {
            // Prefer the device-reported HDHR error captured above (freshest, most precise).
            // Otherwise fold in show_fail_reason, but only when failedThisAttempt confirms a FAIL
            // was actually recorded during *this* recording attempt — show_fail_count alone can't
            // tell "this attempt already failed" from "count hasn't fully decayed from an
            // unrelated failure several episodes ago," since a success only decrements the count
            // without clearing the reason.
            let hadFailThisAttempt = failedThisAttempt.remove(show.show_id) != nil
            let underlying = hdhrReason ?? (hadFailThisAttempt ? show.show_fail_reason : nil)
            let emptyFileDetail = "output file missing or empty"
            let reason: String
            if let underlying, !underlying.isEmpty {
                // Idempotent: don't re-append the suffix if a prior compounding of this exact
                // branch (or a resumed attempt) already carries it, so the reason can't grow
                // without bound across repeated empty-file failures.
                reason = underlying.hasSuffix(emptyFileDetail) ? underlying : "\(underlying) — \(emptyFileDetail)"
            } else {
                reason = "Output file missing or empty — check disk space"
            }
            recordShowFailure(index: index, reason: reason)
            glog("[\(show.show_title)] STOP file missing or empty — fail_count=\(shows[index].show_fail_count) reason=\(reason)", level: .error)
            notify("Recording Failed", body: show.show_title, subtitle: reason)
            // Reuse/capture the same card as every other event in this lifecycle — never a fresh POST.
            fireDiscordCard(showId: show.show_id, event: "❌ Recording Failed", color: 0xE74C3C,
                            enabled: config.Discord_on_failed, extra: [("Reason", reason, false)],
                            clearIdAfter: true)
            await scheduleNextAir(index: index)
            return
        }
        if !path.isEmpty {
            glog("[\(show.show_title)] STOP natural size=\(fileSize / 1024)KB → \(path)")
            // Only credit a success once data is confirmed on disk — decrement here rather than
            // on launch so a show that starts but immediately fails (bad path, stream error) can't
            // cancel out its own failure and prevent the threshold from being reached.
            if fileSize > 0 {
                shows[index].show_fail_count = max(0, shows[index].show_fail_count - 1)
                runPostRecordingScript(path: path, show: show, fileSize: fileSize)
                // One-shot: the override exists to force past a single already-recorded rerun,
                // not to permanently disable dedup for this series — clear it once the recording
                // that actually needed it lands, so the next rerun goes back to being skipped as a
                // duplicate. Gated on duplicateOverrideUsedThisAttempt (set in startRecording only
                // when the override actually suppressed a real skip for this attempt), not merely
                // on the flag being on — otherwise turning it on ahead of time and having it "spend
                // itself" on some unrelated, non-duplicate recording would leave the real rerun
                // un-protected later.
                if duplicateOverrideUsedThisAttempt.remove(show.show_id) != nil {
                    shows[index].show_ignore_duplicate_once = false
                    glog("[\(show.show_title)] OVERRIDE CLEARED — duplicate-recording override used up")
                    // Flips the exact flag WebServer's willSkip reads for the green/gold corner
                    // flag — without this, an open web guide window keeps showing the stale flag
                    // until the next unrelated rebuild (hourly refresh, another show's edit, etc.).
                    pushShowUpdate(type: "show_updated", channel: show.show_channel, device: show.hdhr_record, rebuildMenu: false)
                }
            }
        }

        // File info fields appended to every Recording Complete embed
        var fileFields: [(name: String, value: String, inline: Bool)] = []
        if !path.isEmpty && fileSize > 0 {
            let ext = URL(fileURLWithPath: path).pathExtension.uppercased()
            if !ext.isEmpty { fileFields.append(("Format", ext, true)) }
            fileFields.append(("File Size", Self.formatFileSize(fileSize), true))
        }

        await scheduleNextAir(index: index)
        // Re-resolve by show_id — scheduleNextAir's own internal guide-fetch await can let `shows`
        // mutate (e.g. an interleaved delete) while this call was suspended; the original `index`
        // parameter is no longer guaranteed valid or to still refer to this show.
        guard let curIndex = shows.firstIndex(where: { $0.show_id == show.show_id }) else { return }
        let completedShow = shows[curIndex]
        // Route through fireDiscordCard (not the old direct discordShow(editMessageId:) call) so
        // this terminal event is chained behind any in-flight send like every other lifecycle
        // event — otherwise a still-in-flight "Recording Started" CREATE (slow webhook) could
        // race this read of discord_start_msg_id, posting an orphan ID-less "Complete" message
        // while the Started card's id lands afterward with nothing to clear it.
        if !completedShow.show_active {
            notify("Recording Complete", body: show.show_title, subtitle: "Single episode recorded — show deactivated")
            fireDiscordCard(showId: show.show_id, event: "✅ Recording Complete", color: 0x3498DB,
                            enabled: config.Discord_on_complete,
                            extra: fileFields + [("Note", "Single episode — show deactivated", false)],
                            clearIdAfter: true)
        } else if let next = completedShow.show_next {
            notify("Recording Complete", body: show.show_title, subtitle: "Next: \(Self.completionDateFormatter.string(from: next))")
            fireDiscordCard(showId: show.show_id, event: "✅ Recording Complete", color: 0x3498DB,
                            enabled: config.Discord_on_complete,
                            extra: fileFields + [("Next Airing", Self.completionDateFormatter.string(from: next), false)],
                            clearIdAfter: true)
        } else {
            notify("Recording Complete", body: show.show_title, subtitle: "")
            fireDiscordCard(showId: show.show_id, event: "✅ Recording Complete", color: 0x3498DB,
                            enabled: config.Discord_on_complete, extra: fileFields, clearIdAfter: true)
        }
    }

    func stopRecording(showId: String) {
        guard shows.contains(where: { $0.show_id == showId }) else { return }
        // Re-derive the index inside the Task rather than capturing it now — `shows` can mutate
        // (e.g. a delete) before this deferred Task actually runs on the MainActor.
        Task { @MainActor in
            guard let i = self.shows.firstIndex(where: { $0.show_id == showId }) else { return }
            await self.stopRecording(index: i, natural: false)
        }
    }

    // Launches the user-configured post-recording script via /bin/sh (no executable bit or shebang required).
    // scriptPath becomes $0, recording path becomes $1; all metadata also in HDHR_* env vars.
    private func runPostRecordingScript(path: String, show: Show, fileSize: Int) {
        let scriptPath = config.Post_recording_script
        guard !scriptPath.isEmpty else { return }
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            glog("[PostScript] '\(scriptPath)' not found", level: .warning)
            return
        }
        // Extract SxxExx tag embedded in the filename by outputPath(), e.g. "_S03E18_"
        let fname = URL(fileURLWithPath: path).lastPathComponent
        var epTag = ""
        if let r = fname.range(of: #"_(S\d+(?:E\d+)?)_"#, options: [.regularExpression, .caseInsensitive]) {
            epTag = String(fname[r]).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        }
        let process = Process()
        // Run via /bin/sh so the script needs no executable bit or shebang.
        // scriptPath → $0, path → $1; all metadata available as HDHR_* env vars.
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptPath, path]
        var env = ProcessInfo.processInfo.environment
        // Prepend Homebrew paths so tools like comskip are found without full path.
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:"
                    + (env["PATH"] ?? "/usr/bin:/bin")
        env["HDHR_PATH"]      = path
        env["HDHR_TITLE"]     = show.show_title
        env["HDHR_CHANNEL"]   = show.show_channel
        env["HDHR_TRANSCODE"] = show.show_transcode.isEmpty ? "none" : show.show_transcode
        env["HDHR_EPISODE"]   = epTag
        env["HDHR_DEVICE"]    = show.hdhr_record
        env["HDHR_SERIES"]    = show.isSeries ? "1" : "0"
        env["HDHR_FILESIZE"]  = String(fileSize)
        process.environment = env
        process.terminationHandler = { p in
            glog("[PostScript] '\((scriptPath as NSString).lastPathComponent)' exited \(p.terminationStatus) for '\(show.show_title)'")
        }
        do {
            try process.run()
            glog("[PostScript] pid=\(process.processIdentifier) '\((scriptPath as NSString).lastPathComponent)' → '\(show.show_title)' \(path)")
        } catch {
            glog("[PostScript] launch failed '\(scriptPath)': \(error.localizedDescription)", level: .error)
        }
    }

    // MARK: - Next-air scheduling

    func scheduleNextAir(index: Int) async {
        guard index < shows.count else { return }
        let show = shows[index]
        // Working index, re-resolved by show_id after any await below — `shows` can be mutated
        // (e.g. this show deleted by an interleaved web-UI request) while this function is
        // suspended on the guide-load call further down, which would leave the original `index`
        // parameter stale (out of range, or silently pointing at a different show after removal).
        var idx = index
        // Keys are "showId-epoch" — once show_next advances the old key is stale.
        // Remove on every reschedule so the set doesn't accumulate indefinitely.
        conflictNotifiedEpochs.removeValue(forKey: show.show_id)
        missedStartNotifiedEpochs.removeValue(forKey: show.show_id)
        switch show.state {
        case .single:
            glog("[\(show.show_title)] DONE single — deactivated")
            shows[idx].show_active = false
        case .dateTime:
            if let next = nextDateTime(for: show) {
                shows[idx].show_next = next
                shows[idx].show_end  = next.addingTimeInterval(Double(show.show_length) * 60)
                glog("[\(show.show_title)] NEXT \(shortTime(next)) ch=\(show.show_channel)")
            } else {
                // No matching air day found (show_air_date is empty or invalid) — pause rather than loop forever
                glog("[\(show.show_title)] PAUSED — no air days configured", level: .warning)
                shows[idx].show_paused = true
                shows[idx].show_fail_reason = "No air days configured"
                notify("Show Paused", body: show.show_title, subtitle: "No air days configured — edit show to fix")
                discordShow("⏸ Show Paused", show: show, color: 0xE67E22, enabled: config.Discord_on_paused,
                            extra: [("Reason", "No air days configured — edit show to fix", false)])
            }
        case .seriesChannel, .seriesAll:
            if let device = devices.first(where: { $0.DeviceID == show.hdhr_record }) {
                // devFilter is always the show's current assigned tuner — SeriesID(All) differs
                // from SeriesID(Channel) only in channel scope (any channel on that tuner vs. one
                // fixed channel), not device scope. Pinning the device here (rather than nil for
                // SeriesID(All)) is what keeps a show from hopping to a different tuner every
                // reschedule — applyMatch below always sets hdhr_record = match.deviceId, which
                // would otherwise silently migrate the show to whichever device happened to have
                // the next matching episode, risking two tuners recording the same series at once.
                let chFilter = show.state == .seriesAll ? nil : show.show_channel
                let devFilter = device.DeviceID
                // If guide is stale or absent, reload before searching
                if !guideStore.isFresh(deviceId: device.DeviceID) {
                    await guideStore.load(for: device, hours: config.GuideHours, useXML: config.Guide_use_xml)
                    guideByDevice = guideStore.channelsByDevice
                    // Re-resolve after the await — bail out entirely if this show was deleted
                    // while the guide fetch was in flight.
                    guard let reIdx = shows.firstIndex(where: { $0.show_id == show.show_id }) else { return }
                    idx = reIdx
                }
                // Check for a currently-airing episode first (e.g. marathon, back-to-back airings).
                let now = Date()
                func applyMatch(_ match: GuideStore.SeriesMatch) {
                    // See resolveSeriesAir's identical check — SeriesID is trusted as authoritative
                    // here too, so this doesn't reject the match, but logs loudly if the title looks
                    // like it belongs to an unrelated program (a guide-provider crosswalk error).
                    if Show.seriesTitle(from: match.entry.Title) != show.show_title {
                        glog("[\(show.show_title)] scheduleNextAir: matched entry title is \"\(match.entry.Title)\" — possible guide provider mistagging, using it anyway", level: .warning)
                    }
                    shows[idx].show_next    = match.entry.startDate
                    shows[idx].show_end     = match.entry.endDate
                    shows[idx].show_channel = match.channelNum
                    shows[idx].show_genre   = match.entry.firstGenre ?? ""
                    shows[idx].hdhr_record  = match.deviceId
                    if let url = hdhrManager.streamURL(for: match.channelNum, lineup: lineups[match.deviceId] ?? []) {
                        shows[idx].show_url = url
                    }
                }
                if let match = guideStore.currentEpisode(seriesID: show.show_seriesid, channelNum: chFilter, deviceId: devFilter, at: now, preferFavorite: isFavoriteChannel) {
                    glog("[\(show.show_title)] NEXT now (on-air) ch=\(match.channelNum) \(match.entry.Title)")
                    applyMatch(match); return
                }
                if let match = guideStore.nextEpisode(seriesID: show.show_seriesid,
                                                      channelNum: chFilter,
                                                      deviceId: devFilter,
                                                      preferFavorite: isFavoriteChannel) {
                    glog("[\(show.show_title)] NEXT \(shortTime(match.entry.startDate)) ch=\(match.channelNum) \(match.entry.Title)")
                    applyMatch(match); return
                }
                // Fallback: title match — handles guide entries where SeriesID is absent.
                // chFilter is nil for SeriesID(All) (scans every channel on devFilter's device);
                // devFilter is always set, so this never scans devices beyond the assigned one.
                if let match = guideStore.currentEntryByTitle(show.show_title, channelNum: chFilter, deviceId: devFilter, at: now) {
                    glog("[\(show.show_title)] NEXT now (title match, on-air) ch=\(match.channelNum)")
                    applyMatch(match); return
                }
                if let match = guideStore.nextEntryByTitle(show.show_title, channelNum: chFilter, deviceId: devFilter, after: now) {
                    glog("[\(show.show_title)] NEXT \(shortTime(match.entry.startDate)) ch=\(match.channelNum) (title match)")
                    applyMatch(match); return
                }
            }
            // Bump show_next if stranded (nil or past). If it's already a future guide match,
            // leave it — rescheduleAllSeries will override it when a real episode appears.
            if shows[idx].show_next.map({ $0 <= Date() }) ?? true {
                glog("[\(show.show_title)] no episode found — retry in \(config.Series_scan_retry_hours)h", level: .warning)
                shows[idx].show_next = Date().addingTimeInterval(Double(config.Series_scan_retry_hours) * 3600)
            } else {
                glog("[\(show.show_title)] no episode found in guide — show_next already future, leaving unchanged", level: .warning)
            }
            // Neither branch above sources a fresh show_end alongside show_next the way applyMatch
            // does — without this, show_end keeps whatever a much earlier successful match last set
            // it to, however stale. Routine for a weekly show (SNL, 20/20): the guide's ~29h window
            // rarely contains their next airing, so this fallback runs for days at a stretch between
            // real matches, and show_end can end up months behind show_next — a mismatched pair that
            // reads as a nonsensical Time range in any Discord card/menu built before the next real
            // match refreshes both fields together. Re-derive a reasonable estimate from show_length
            // instead of leaving it stale.
            if let next = shows[idx].show_next {
                let oldEnd = shows[idx].show_end
                let newEnd = next.addingTimeInterval(Double(show.show_length) * 60)
                // Only log when this actually corrects meaningful drift (not every routine tick where
                // show_end was already in sync) — the gap size doubles as a signal for how stale it
                // had gotten, useful for confirming this fix is doing something on a real install.
                if oldEnd == nil || abs(oldEnd!.timeIntervalSince(newEnd)) > 60 {
                    let oldStr = oldEnd.map { Self.completionDateFormatter.string(from: $0) } ?? "nil"
                    glog("[\(show.show_title)] show_end re-synced to show_next+length (was \(oldStr), now \(Self.completionDateFormatter.string(from: newEnd)))", level: .info)
                }
                shows[idx].show_end = newEnd
            }
        }
    }

    // Pass after: Date() to include today (menu display); after: startOfTomorrow to always skip today (rescheduling).
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
        // Conflict check + notifications live here (not left to each caller) so every path that
        // adds a show — the guide's "Record" action, the native Add Show wizard, any future
        // caller — gets the same tuner-conflict warning and "Show Added" confirmation
        // unconditionally, matching the pushShowUpdate call just below. The native
        // wizard used to skip both entirely (only addShowFromGuide, the web/quick-add path, fired
        // them), so adding a conflicting show there gave no warning until it silently failed or
        // queued later, and enabling Discord's "Show Added" notification never covered shows
        // added from the native app.
        if hasConflict(for: show) {
            notify("Recording Conflict", body: show.show_title,
                   subtitle: "All tuners on \(show.hdhr_record) are busy at \(shortTime(show.show_next))")
            discordShow("⚠️ Tuner Conflict", show: show, color: 0xF1C40F, enabled: config.Discord_on_conflict,
                        extra: [("Note", "All tuners on \(show.hdhr_record) are busy at \(shortTime(show.show_next))", false)])
        }
        shows.append(show); saveConfig()
        notify("Show Added", body: show.show_title, subtitle: show.state.rawValue)
        discordShow("✅ Show Added", show: show, color: 0x1ABC9C, enabled: config.Discord_on_show_added,
                    extra: [("Type", show.state.rawValue, true)])
        // Broadcast here (not left to each caller) so every path that adds a show — the guide's
        // "Record" action, the native Add Show wizard, any future caller — pushes to the web UI
        // unconditionally instead of depending on the caller remembering to.
        pushShowUpdate(type: "show_added", channel: show.show_channel, device: show.hdhr_record)
        // Donation nag — covers both the native wizard and the web guide's Record action
        // (addShowFromGuide ends by calling this same function), so a single hook here reaches
        // both. No-op once the shared unlock code has been entered.
        if !config.Donation_unlocked { pendingDonationNagTrigger += 1 }
        // If the show is currently airing, don't wait for the idle loop — start immediately.
        // Capture show_id (not index) so the Task re-derives position after any interleaved mutation.
        let now = Date()
        if let next = show.show_next, let end = show.show_end, next <= now + 10, end > now {
            let id = show.show_id
            Task {
                if let j = shows.firstIndex(where: { $0.show_id == id }) {
                    await startRecording(index: j)
                }
            }
        }
    }
    func updateShow(_ show: Show) {
        guard let i = shows.firstIndex(where: { $0.show_id == show.show_id }) else { return }
        glog("[Show] Updated '\(show.show_title)'")
        shows[i] = show; saveConfig()
        // Broadcast here (not left to each caller) so every path that edits a show — the guide's
        // edit modal, the native Edit Show window, any future caller — pushes to the web UI
        // unconditionally instead of depending on the caller remembering to.
        pushShowUpdate(type: "show_updated", channel: show.show_channel, device: show.hdhr_record)
        // Re-run scheduleNextAir immediately so a type/channel/device change (e.g. seriesChannel →
        // seriesAll) takes effect without waiting for the next idle-loop tick.
        guard show.show_active, !show.show_paused, !show.show_recording, show.state != .single else { return }
        Task { [weak self] in
            guard let self, let j = self.shows.firstIndex(where: { $0.show_id == show.show_id }) else { return }
            await self.scheduleNextAir(index: j)
            self.saveConfig()
            // Re-broadcast now that scheduleNextAir resolved the real show_next/channel — the
            // broadcast above fired immediately with pre-reschedule data, so on a type change
            // (e.g. seriesChannel → seriesAll) web guide viewers would otherwise keep seeing
            // stale schedule info until an unrelated event happened to trigger another push.
            if let updated = self.shows.first(where: { $0.show_id == show.show_id }) {
                self.pushShowUpdate(type: "show_updated", channel: updated.show_channel, device: updated.hdhr_record)
            }
        }
    }


    // MARK: - Favorites

    func isFavoriteChannel(_ show: Show) -> Bool {
        lineups[show.hdhr_record]?.first { $0.GuideNumber == show.show_channel }?.isFavorite ?? false
    }

    // Optimistic: mutates lineups immediately for instant UI feedback, reverts if the POST fails.
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
        pushShowUpdate(type: "show_updated", channel: show.show_channel, device: show.hdhr_record)
    }
    func resumeShow(_ show: Show) {
        guard let i = shows.firstIndex(where: { $0.show_id == show.show_id }) else { return }
        glog("[\(show.show_title)] RESUMED")
        shows[i].show_paused = false; shows[i].clearFailures(); showRetryAfter.removeValue(forKey: show.show_id); saveConfig()
        pushShowUpdate(type: "show_updated", channel: show.show_channel, device: show.hdhr_record)
    }
    func deleteShow(_ show: Show) {
        glog("[Show] Deleted '\(show.show_title)'")
        // Route through the full teardown (tuner-occupancy clear, recording_stopped broadcast,
        // tunerStatus/signalDropoutTicks cleanup) when deleting a show that's actively recording —
        // a bare recordingManager.stop() skipped all of that, leaving the web UI showing a
        // recording tuner for up to one idle-tick until the next hardware poll self-corrected.
        if let i = shows.firstIndex(where: { $0.show_id == show.show_id }), shows[i].show_recording {
            teardownRecordingState(index: i)
        } else {
            recordingManager.stop(showId: show.show_id)
        }
        VLCPlayerWindowManager.shared.closeIfPlaying(showId: show.show_id, url: show.show_url)
        shows.removeAll { $0.show_id == show.show_id }
        // Purge every show_id-keyed side table — show_id is never reused, so leaving entries
        // behind here would grow these dictionaries/sets without bound over a long-running
        // session as shows are added and deleted over time.
        showRetryAfter.removeValue(forKey: show.show_id)
        conflictNotifiedEpochs.removeValue(forKey: show.show_id)
        missedStartNotifiedEpochs.removeValue(forKey: show.show_id)
        pendingDiscordStart.remove(show.show_id)
        failedThisAttempt.remove(show.show_id)
        duplicateOverrideUsedThisAttempt.remove(show.show_id)
        suppressStartDiscord.remove(show.show_id)
        // Clear unconditionally (not just via teardownRecordingState) — a non-recording delete
        // takes the else branch above and skips teardown, so without this a show that was skipped
        // mid-dropout (skipRecording leaves signalDropoutTicks set) then deleted would leak these
        // show_id-keyed entries for the session. Harmless if teardown already removed them.
        tunerStatus.removeValue(forKey: show.show_id)
        signalDropoutTicks.removeValue(forKey: show.show_id)
        // Safe to drop unconditionally even if a send for this show is still running — removing
        // the dict entry doesn't affect an already-started Task, it only stops a future call from
        // chaining behind it (and there won't be one for a deleted show).
        discordCardTasks.removeValue(forKey: show.show_id)
        saveConfig()
        pushShowUpdate(type: "show_deleted", channel: show.show_channel, device: show.hdhr_record)
    }

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

    func rescheduleAllSeries() async {
        // Iterate by show_id, not a snapshotted index — scheduleNextAir's internal guide-fetch
        // await can let `shows` mutate between iterations. Re-checking the filter after
        // re-resolving guards against acting on an unrelated show that shifted into a stale slot
        // (scheduleNextAir itself only guards index < shows.count, not "is this still the show
        // and state I meant to reschedule").
        let ids = shows.indices.filter { shows[$0].show_active && !shows[$0].show_paused && !shows[$0].show_recording && shows[$0].show_use_seriesid }
            .map { shows[$0].show_id }
        for id in ids {
            guard let i = shows.firstIndex(where: { $0.show_id == id }),
                  shows[i].show_active, !shows[i].show_paused, !shows[i].show_recording, shows[i].show_use_seriesid
            else { continue }
            await scheduleNextAir(index: i)
        }
        saveConfig()
    }

    func refreshGuide() async { await refreshGuides() }

    func rediscoverDevices() async {
        await discoverDevices(knownHosts: knownHostsFromShows(), attempts: 5)
    }

    func resetAllFailCounts() {
        for i in shows.indices { shows[i].clearFailures() }
        showRetryAfter.removeAll()
        saveConfig()
    }

    func reactivatePausedShows() {
        for i in shows.indices {
            if shows[i].show_paused { shows[i].show_paused = false }
            else if !shows[i].show_active { shows[i].show_active = true }
            shows[i].clearFailures()
        }
        showRetryAfter.removeAll()
        saveConfig()
    }

    // "_S02E04_" or " S22E125 " → "S02E04"/"S22E125". Shared by organizeSeriesRecordings (season
    // subfolder placement) and recordedEpisodeTags (duplicate-episode detection) so both parse
    // recording filenames identically. nonisolated: touches no actor-isolated state, so it (and
    // recordedEpisodeTags below) can run off @MainActor when called from a detached task — see
    // duplicateEpisodeTag(for:isSeries:baseDir:).
    private nonisolated func episodeTag(inFilename filename: String) -> String? {
        guard let tagRange = filename.range(of: #"[_ ](S\d+(?:E\d+)?)"#, options: [.regularExpression, .caseInsensitive])
        else { return nil }
        return String(filename[tagRange].dropFirst())  // drop leading "_" or " "
    }

    func organizeSeriesRecordings() -> String {
        // Paths currently being written to — never touch these.
        let activePaths = Set(shows.filter { $0.show_recording }
                                   .map { $0.show_recording_path }
                                   .filter { !$0.isEmpty })
        var movedCount = 0
        var errorCount = 0
        var pathUpdates: [String: String] = [:]
        var scanned = Set<String>()   // baseDir|safeTitle — skip duplicate show entries

        for show in shows where show.isSeries {
            let baseDir   = show.posixRecordDir
            let rawTitle  = show.show_title
            let safeTitle = rawTitle.replacingOccurrences(of: "/", with: "-")
            // Strip any episode-specific suffix for folder naming (handles shows saved before this fix).
            let safeFolderTitle = Show.seriesTitle(from: rawTitle).replacingOccurrences(of: "/", with: "-")
            let key = "\(baseDir)|\(safeTitle)"
            guard scanned.insert(key).inserted else { continue }

            // Scan the flat root for files belonging to this show.
            // Match both new format (title_channel_date) and old format (title SxxExx guests_channel_date).
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: baseDir) else { continue }
            for filename in files where (filename.hasPrefix("\(safeFolderTitle)_") || filename.hasPrefix("\(safeFolderTitle) "))
                                    && Show.isRecordingFile(filename) {
                let src = (baseDir as NSString).appendingPathComponent(filename)
                guard !activePaths.contains(src) else { continue }

                // Extract episode tag from either separator style: "_S02E04_" or " S22E125 ".
                let subfolder: String
                if let tag = episodeTag(inFilename: filename) {
                    if let season = seasonNumber(from: tag) {
                        subfolder = "\(safeFolderTitle)/Season \(String(format: "%02d", season))"
                    } else {
                        subfolder = safeFolderTitle
                    }
                } else {
                    subfolder = safeFolderTitle
                }

                let destDir  = (baseDir as NSString).appendingPathComponent(subfolder)
                let destPath = (destDir as NSString).appendingPathComponent(filename)
                guard src != destPath else { continue }

                do {
                    try FileManager.default.createDirectory(atPath: destDir,
                                                            withIntermediateDirectories: true,
                                                            attributes: nil)
                    try FileManager.default.moveItem(atPath: src, toPath: destPath)
                    pathUpdates[src] = destPath
                    movedCount += 1
                    glog("[Maintenance] Moved \(filename) → \(subfolder)/")
                } catch {
                    glog("[Maintenance] organizeSeriesRecordings: failed to move \(filename): \(error)",
                         level: .error)
                    errorCount += 1
                }
            }
        }

        // Keep show_recording_path in sync for any file that moved.
        if !pathUpdates.isEmpty {
            for i in shows.indices {
                if let updated = pathUpdates[shows[i].show_recording_path] {
                    shows[i].show_recording_path = updated
                }
            }
            saveConfig()
        }

        if movedCount == 0 && errorCount == 0 { return "No files to organize" }
        var result = "Moved \(movedCount) file(s) into subfolders"
        if errorCount > 0 { result += " (\(errorCount) error(s) — see log)" }
        return result
    }

    // MARK: - Utilities

    func refreshAll() {
        glog("[Guide] refreshAll() — triggering discovery + refreshGuides()")
        guideByDevice = [:]
        // Discovery first (updates device IPs), then refreshGuides() reloads. guideByDevice is
        // cleared eagerly right above (unlike refreshGuides()'s own guideStore, which is left in
        // place until fresh data lands) because this is a user-initiated "Update Guides Now" action
        // (SettingsView) — an immediate visual clear is expected here, unlike the silent automatic
        // hourly refresh. The idle loop checks hour boundaries, so concurrent calls are naturally throttled.
        Task { await discoverDevices(); await refreshGuides() }
    }

    func diskOK(for show: Show) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: show.posixRecordDir),
              let total = attrs[.systemSize] as? Double, let free = attrs[.systemFreeSize] as? Double,
              total > 0 else {
            glog("[\(show.show_title)] diskOK: could not read filesystem stats for \(show.posixRecordDir) — assuming OK", level: .warning)
            return true
        }
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
        glog("[Notify] \(title) — \(body)\(subtitle.isEmpty ? "" : " (\(subtitle))")")
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
    private func seasonNumber(from epString: String) -> Int? {
        // Single case-insensitive pattern handles both S01E05 and bare S01; anchored to prevent mid-string false matches.
        guard let range = epString.range(of: #"^S(\d+)(?:E\d+)?$"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let sub = epString[range].dropFirst()   // drop leading "S"
        return Int(sub.prefix(while: { $0.isNumber }))
    }

    /// Uppercased SxxExx (or bare SxxE-less) episode tags already recorded on disk for a series,
    /// scanning `<baseDir>/<safeTitle>` (flat files) plus each `Season NN` subfolder. Used by the
    /// skip-already-recorded feature (record-time skip + the web-guide SKIP pill). Reuses the same
    /// filename tag parsing (`episodeTag(inFilename:)`) as `organizeSeriesRecordings` so both stay
    /// consistent. Files under
    /// ~1 MB are treated as crashed/zero-byte stubs and ignored, so a prior failed attempt never
    /// masks a real re-record.
    ///
    /// `nonisolated` — pure `FileManager` I/O, no actor-isolated state touched. Existing callers
    /// on `@MainActor` (`buildGuideGridHTML`, the synchronous `duplicateEpisodeTag` overload) are
    /// unaffected — a nonisolated method still runs inline/synchronously when called from an
    /// isolated context. What this enables is `duplicateEpisodeTag(for:isSeries:baseDir:)`
    /// invoking it from a detached background task instead, so a slow-to-wake external/NAS-backed
    /// recording drive can't block the whole app on @MainActor for that one call site.
    nonisolated func recordedEpisodeTags(forTitle safeTitle: String, baseDir: String) -> Set<String> {
        let fm = FileManager.default
        let seriesDir = (baseDir as NSString).appendingPathComponent(safeTitle)
        // No recursive enumerator elsewhere in the codebase — walk exactly two levels: the title
        // dir itself and its "Season NN" children (where season subfolders place their files).
        var dirs = [seriesDir]
        if let children = try? fm.contentsOfDirectory(atPath: seriesDir) {
            for child in children where child.hasPrefix("Season ") {
                let sub = (seriesDir as NSString).appendingPathComponent(child)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: sub, isDirectory: &isDir), isDir.boolValue { dirs.append(sub) }
            }
        }
        var tags = Set<String>()
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for filename in files where Show.isRecordingFile(filename) {
                guard let tag = episodeTag(inFilename: filename) else { continue }
                let full = (dir as NSString).appendingPathComponent(filename)
                let size = ((try? fm.attributesOfItem(atPath: full))?[.size] as? Int) ?? 0
                if size < 1_000_000 { continue }   // ignore failed/stub files
                tags.insert(tag.uppercased())
            }
        }
        return tags
    }

    /// Returns the uppercased episode tag (e.g. "S51E20") if `episodeTag` is a full season+episode
    /// tag, the skip-already-recorded feature is on, and a matching file already exists on disk for
    /// `title` — nil otherwise. Shared by the record-time skip in `startRecording` and the Add/Edit
    /// dialog's "already on disk" warning so both reflect the exact same on-disk check.
    func duplicateEpisodeTag(title: String, episodeTag: String, baseDir: String) -> String? {
        guard config.Skip_recorded_episodes,
              episodeTag.range(of: #"^S\d+E\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil
        else { return nil }
        let safeTitle = title.replacingOccurrences(of: "/", with: "-")
        let upper = episodeTag.uppercased()
        return recordedEpisodeTags(forTitle: safeTitle, baseDir: baseDir).contains(upper) ? upper : nil
    }

    /// UI convenience: looks up `show`'s next-airing episode tag from the guide and checks it via
    /// the same on-disk logic as `duplicateEpisodeTag(title:episodeTag:baseDir:)`. Used by the
    /// Add/Edit dialog to warn that a scheduled recording will be skipped as a duplicate unless
    /// `show_ignore_duplicate_once` is set. Takes `isSeries`/`baseDir` explicitly rather than
    /// reading `show.isSeries`/`show.posixRecordDir` because in the Add wizard those `Show` fields
    /// aren't written until Save — the caller's live `seriesType`/`recordFolder` picker state is
    /// the only accurate source before then. Excludes a show that's currently recording (its own
    /// in-progress file would otherwise flag itself as a duplicate), mirroring the `!isEntryRec`
    /// exclusion in WebServer's `.g-st-skip` logic.
    ///
    /// `async`, unlike the title-based overload above: the guide lookup and config checks below
    /// are in-memory and stay on @MainActor, but the actual disk scan (`recordedEpisodeTags`,
    /// `nonisolated`) is dispatched to a detached background task — this is the one call site
    /// (`ShowFormSection`'s debounced duplicate check, live while the user types in the Add/Edit
    /// dialog) where a slow-to-wake external/NAS-backed recording drive blocking @MainActor would
    /// stall the whole app, not just this one field. `startRecording`'s one-shot check keeps using
    /// the synchronous title-based overload instead — a single check right before a curl launch
    /// has no live-typing debounce to protect, so there's nothing to gain by detaching it too.
    func duplicateEpisodeTag(for show: Show, isSeries: Bool, baseDir: String) async -> String? {
        guard config.Skip_recorded_episodes, config.Series_subfolder_enabled, isSeries, !show.show_recording,
              let tag = guideEntryForShow(show)?.EpisodeNumber,
              tag.range(of: #"^S\d+E\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil
        else { return nil }
        let safeTitle = show.show_title.replacingOccurrences(of: "/", with: "-")
        let upper = tag.uppercased()
        return await Task.detached(priority: .userInitiated) { [weak self] in
            self?.recordedEpisodeTags(forTitle: safeTitle, baseDir: baseDir).contains(upper) == true ? upper : nil
        }.value
    }

    // Rerun/multiplex channels (e.g. H&I) air many unrelated series back-to-back on one channel
    // number, hour by hour — several different Star Trek series plus MacGyver, Walker, CSI, etc.
    // A bare channel+time match can silently latch onto whichever program actually occupies that
    // slot if show_next is even slightly stale relative to the current guide (a provider schedule
    // correction, or a guide refresh landing between when show_next was set and when this runs) —
    // producing a card/subfolder/episode-tag with the right show_title but a wrong show's episode
    // number and synopsis. Confirm identity via SeriesID when both sides have one; otherwise fall
    // back to a title compare (stripped the same way `GuideStore.currentEntryByTitle` is, since
    // show.show_title is already stripped for a series show).
    private func guideEntryForShow(_ show: Show) -> GuideEntry? {
        guard let startDate = show.show_next else { return nil }
        let target = Int(startDate.timeIntervalSince1970)
        let entries = guideStore.entries(deviceId: show.hdhr_record, channelNum: show.show_channel,
                                         after: startDate.addingTimeInterval(-60))
        guard let entry = entries.first(where: { abs($0.StartTime - target) < 120 }) else { return nil }
        // Only a series show's stored title has had an episode suffix stripped at add time
        // (Show.seriesTitle(from:)) — a Single/DateTime show's show_title is the raw, possibly
        // still-suffixed guide title as originally selected, so stripping entry.Title before
        // comparing would compare a normalized value against an unnormalized one and could
        // never match, breaking this check for every Single/DateTime show with a suffixed title.
        let entryTitle = show.isSeries ? Show.seriesTitle(from: entry.Title) : entry.Title
        let titlesAgree = entryTitle == show.show_title
        if let sid = entry.SeriesID, !sid.isEmpty, !show.show_seriesid.isEmpty {
            guard sid == show.show_seriesid else {
                glog("[\(show.show_title)] guideEntryForShow: rejected channel+time match — SeriesID \(sid) != \(show.show_seriesid) (entry title: \(entry.Title))", level: .warning)
                return nil
            }
            // SeriesID matched, but the title still doesn't line up — SeriesID is trusted as
            // authoritative here (a correct match can legitimately have a differently-formatted
            // display title across affiliates), so this doesn't reject the entry, but it's exactly
            // the shape of a guide-provider crosswalk error (a real one: an H&I "MacGyver" rerun
            // entry carrying this show's own Star Trek SeriesID) — log loudly so a real mistagging
            // incident is visible instead of silently producing a wrong-episode card/subfolder.
            if !titlesAgree {
                glog("[\(show.show_title)] guideEntryForShow: SeriesID matched but entry title is \"\(entry.Title)\" — possible guide provider mistagging, using it anyway", level: .warning)
            }
            return entry
        }
        guard titlesAgree else {
            glog("[\(show.show_title)] guideEntryForShow: rejected channel+time match — title \"\(entry.Title)\" doesn't match", level: .warning)
            return nil
        }
        return entry
    }

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
            "footer":      ["text": "hdhrVCRplus  ·  \(show.hdhr_record)"]
        ]
        if !show.show_logo_url.isEmpty { embed["thumbnail"] = ["url": show.show_logo_url] }
        return embed
    }

    // Called by WebServer when a recording is stopped or deleted via the web UI.
    // Edits the existing "Recording Started" Discord embed in-place (if one exists).
    // Uses Discord_on_start (not on_complete) — the embed was created under that flag,
    // so the update should follow the same gate rather than completion-notification prefs.
    @MainActor
    func discordWebDelete(_ show: Show) {
        guard show.show_recording, !show.discord_start_msg_id.isEmpty else { return }
        discordShow("🛑 Recording Stopped", show: show, color: 0xE67E22,
                    enabled: config.Discord_on_start,
                    extra: [("Via", "Web UI", false)],
                    editMessageId: show.discord_start_msg_id)
    }

    private func discordEffectiveURL(enabled: Bool, webhookURL: String?) -> String? {
        let url = webhookURL ?? config.Discord_webhook_url
        guard enabled, !url.isEmpty else { return nil }
        if webhookURL == nil, !config.Discord_enabled { return nil }
        return url
    }

    // One Discord card per recording-attempt lifecycle. The first event (a failure or the
    // start) creates a captured message and stores its id in show.discord_start_msg_id;
    // subsequent events (a start after a failure, paused, complete) edit that same card.
    // The id is cleared only at terminal events (complete / paused) so the next airing begins
    // a fresh card — so a failure → start → end shows as a single, updated card.
    @MainActor
    private func discordRecordingCard(showId: String, event: String, color: Int, enabled: Bool,
                                      extra: [(name: String, value: String, inline: Bool)] = []) async {
        guard let url = discordEffectiveURL(enabled: enabled, webhookURL: nil),
              let i = shows.firstIndex(where: { $0.show_id == showId }) else { return }
        glog("[Discord] \(event) — \(shows[i].show_title)")
        let embed = buildDiscordShowEmbed(event: event, show: shows[i], color: color, extra: extra)
        let existing = shows[i].discord_start_msg_id
        if !existing.isEmpty {
            editDiscordEmbed(webhookURL: url, messageId: existing, embed: embed)
        } else if let msgId = await sendDiscordEmbedCapturing(to: url, embed: embed),
                  let j = shows.firstIndex(where: { $0.show_id == showId }) {
            shows[j].discord_start_msg_id = msgId
        }
    }

    // Per-show serialization for lifecycle-card sends: each new call for a show_id chains behind
    // whatever call is already running for that same show_id, so at most one discordRecordingCard
    // is ever actually in flight per show. Without this, two events racing for the same show —
    // e.g. a "Recording Started" confirmation firing while a fail-threshold "Paused" card from
    // the previous attempt is still awaiting a slow webhook's CREATE round trip — could both
    // observe discord_start_msg_id empty, each capture their own new message id, and the loser's
    // card becomes a permanent orphan (or a later id-clear stomps a card a concurrent send just
    // made). Mirrors ensureLineupLoaded's Task-caching idiom (loadingLineupTasks) rather than a
    // busy-poll: no latency floor waiting for a lock, and clearing a stale dict entry (deleteShow)
    // can never race a still-running send, since nothing here treats presence-in-dict as a lock.
    var discordCardTasks: [String: Task<Void, Never>] = [:]

    /// Fires a Discord lifecycle card update from a detached, per-show-chained Task so a slow/hung
    /// webhook can't stall the idle loop's per-tick show processing. Pass `clearIdAfter: true` for
    /// terminal events (paused, empty-output-file failure) so the next airing's attempt starts a
    /// fresh card — safe to clear unconditionally here because the chain guarantees this is the
    /// only send touching `discord_start_msg_id` for this show at that moment.
    private func fireDiscordCard(showId: String, event: String, color: Int, enabled: Bool,
                                 extra: [(name: String, value: String, inline: Bool)] = [],
                                 clearIdAfter: Bool = false) {
        let previous = discordCardTasks[showId]
        discordCardTasks[showId] = Task { @MainActor in
            _ = await previous?.value
            await self.discordRecordingCard(showId: showId, event: event, color: color, enabled: enabled, extra: extra)
            if clearIdAfter, let j = self.shows.firstIndex(where: { $0.show_id == showId }) {
                self.shows[j].discord_start_msg_id = ""
            }
            self.saveConfig()
        }
    }

    private func discordShow(_ event: String, show: Show, color: Int, enabled: Bool,
                             extra: [(name: String, value: String, inline: Bool)] = [],
                             webhookURL: String? = nil,
                             editMessageId: String? = nil) {
        guard let url = discordEffectiveURL(enabled: enabled, webhookURL: webhookURL) else { return }
        glog("[Discord] \(event) — \(show.show_title)")
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
        guard let url = discordEffectiveURL(enabled: enabled, webhookURL: webhookURL) else { return }
        glog("[Discord] \(event) — \(detail)")
        let embed: [String: Any] = [
            "title":       event,
            "description": detail,
            "color":       color,
            "footer":      ["text": "hdhrVCRplus"]
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

    // Fresh hw poll folded into tunersFull's max(hw, recordingShows+vlc) — a raw status.json
    // read alone misses a just-started recording (docs/AppState.md). Alerts the user and returns
    // false if every tuner on `device` is busy; callers should bail out without proceeding.
    private func tunerAvailable(_ device: HDHRDevice, context: String? = nil) async -> Bool {
        await fetchDeviceStatus(for: device)
        guard tunersFull(for: device.DeviceID) else { return true }
        let tunerCount = device.TunerCount ?? 2
        let suffix = context.map { "; '\($0)' not opened" } ?? ""
        glog("[Watch] BLOCKED — all \(tunerCount) tuner(s) on \(device.DeviceID) in use\(suffix)", level: .warning)
        alertTunerFull(tunerCount: tunerCount, deviceId: device.DeviceID)
        return false
    }

    func watchInApp(url: String, title: String, deviceId: String? = nil, transcode: String? = nil, guideNumber: String? = nil) {
        guard VLCBridge.shared.isAvailable else { return }
        let device = devices.first { $0.DeviceID == (deviceId ?? "") } ?? devices.first
        guard let device else { return }
        // A missing/empty lineup URL (stale or incomplete lineup data) passed straight to
        // libvlc can leave it never confirming either Playing or Error state — the player
        // window would open and sit stuck on a disabled "Connecting…" UI forever, with no
        // error ever surfaced. Catch it here instead, before opening the window at all.
        guard !url.isEmpty else {
            glog("[Watch] BLOCKED — empty stream URL for '\(title)' on \(device.DeviceID)", level: .warning)
            let alert = NSAlert()
            alert.messageText = "No Stream URL"
            alert.informativeText = "\"\(title)\" has no stream URL in the current lineup — try refreshing the lineup or guide."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        let streamURL = config.applyTranscode(url, override: transcode)
        let mgr = VLCPlayerWindowManager.shared

        Task {
            // If this exact channel is already playing, just surface the window — don't restart
            // the stream or mute. Re-opening the same channel from WatchNow while it's playing
            // would otherwise call setVolume(0) in mgr.open() with no posterHidden reset, leaving
            // the user with no audio and no Start button to recover from it.
            let rawBase = url.urlBase
            @MainActor func isAlreadyPlaying() -> Bool {
                mgr.currentDeviceID == device.DeviceID && (VLCBridge.shared.currentURL?.urlBase ?? "") == rawBase
            }
            if isAlreadyPlaying() { mgr.focus(); return }

            // Switching channels in an already-open player on this device reuses the same slot —
            // skip the availability check so we don't block a legal channel switch.
            if mgr.currentDeviceID != device.DeviceID {
                guard await tunerAvailable(device, context: title) else { return }
            }
            // Re-check after the await above: neither currentDeviceID nor currentURL change until
            // mgr.open() actually runs below, so a second watchInApp call for this same channel
            // (e.g. a double-click) that got scheduled while this call was suspended on
            // fetchDeviceStatus would see the same stale "not yet playing" state the first check
            // above saw, and — without this second check — call mgr.open() a second time, muting
            // an already-playing stream with no recovery UI.
            if isAlreadyPlaying() { mgr.focus(); return }
            glog("[Watch] '\(title)' on \(device.DeviceID)")
            if let gn = guideNumber {
                let now = Date()
                if let entry = guideEntries(deviceId: device.DeviceID, channelNum: gn)
                    .first(where: { $0.startDate <= now && $0.endDate > now }) {
                    let duration = max(60, entry.endDate.timeIntervalSinceNow) + 300
                    recordingManager.preventSleep(id: "vlc", reason: "Watching: \(title)", duration: duration)
                }
            }
            mgr.open(url: streamURL, title: title, device: device, appState: self, channelNumber: guideNumber)
            refreshTunerOccupancy()
        }
    }

    func watchInVLC(url: String, transcode: String? = nil, deviceId: String? = nil) {
        let raw = config.applyTranscode(url, override: transcode)
        guard config.Watch_in_VLC,
              let streamURL = URL(string: raw) else { return }
        guard let vlcApp = VLCBridge.locateApp() else { return }
        let device = devices.first { $0.DeviceID == (deviceId ?? "") }
        Task {
            if let device {
                guard await tunerAvailable(device) else { return }
            }
            NSWorkspace.shared.open([streamURL], withApplicationAt: vlcApp,
                                    configuration: .init()) { _, _ in }
        }
    }

    // A currently-recording show is already occupying a tuner; re-requesting the same channel
    // for "Watch Now" would open a second TCP connection and consume a second tuner — HDHomeRun's
    // port 5004 allocates one tuner per connection with no client-multiplexing (docs/HDHRFindings.md).
    // Play the file being written to disk instead, so watching a recording never costs a tuner.
    //
    // Not plain file:// playback — VLC's local-file access module snapshots the file's length at
    // open time and won't read past it even though curl keeps appending, so a direct file:// URL
    // stalls/ends once playback catches up to where it started. Routed instead through the
    // WebServer's `/api/watch-recording` relay (WebServer.swift), which serves the file as an
    // open-ended HTTP stream — same shape as the real tuner stream, which VLC already handles.
    // Uses ensureWebServerRunning()/releaseInternalWebServer() (the same refcounted internal-use
    // path AddShowView's guide step uses) so this works even when the user has the LAN web UI
    // disabled in Settings; releaseRecordingRelayIfNeeded() balances the count when the player
    // window closes.
    // How far behind the live edge Watch Now! starts a recording-relay session — enough that the
    // file already has a few seconds buffered past the start point (avoids opening right at the
    // write pointer), while still landing the viewer close to "now" instead of the recording's
    // start. Purely a starting-position default; the scrub bar can reach anywhere from 0 to live.
    private static let recordingLiveEdgeBackoffSeconds: Double = 30

    private func recordingElapsedSeconds(_ show: Show) -> Double {
        max(1, Date().timeIntervalSince(show.show_next ?? Date()))
    }

    // Raw MPEG-TS has no index — this estimates a byte offset from a constant-bitrate assumption
    // (bytes written so far / seconds recorded so far), aligned to a 188-byte TS packet boundary.
    // Approximate, not frame-accurate; good enough for casual scrubbing.
    private func recordingByteOffset(for show: Show, atSeconds targetSeconds: Double) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: show.show_recording_path),
              let size = attrs[.size] as? Int, size > 0 else { return nil }
        let elapsed = recordingElapsedSeconds(show)
        let bytesPerSec = Double(size) / elapsed
        let clamped = max(0, min(targetSeconds, elapsed))
        let raw = Int(clamped * bytesPerSec)
        return max(0, raw - raw % 188)
    }

    func watchRecordingInApp(_ show: Show) {
        guard VLCBridge.shared.isAvailable else { return }
        guard !show.show_recording_path.isEmpty,
              FileManager.default.fileExists(atPath: show.show_recording_path) else {
            watchInApp(url: show.show_url, title: show.show_title, deviceId: show.hdhr_record, transcode: show.show_transcode)
            return
        }
        let device = devices.first { $0.DeviceID == show.hdhr_record } ?? devices.first
        guard let device else { return }
        if !recordingRelayActive {
            recordingRelayActive = true
            ensureWebServerRunning()
        }
        let recordingStart = show.show_next ?? Date()
        let elapsed         = recordingElapsedSeconds(show)
        let startSeconds    = max(0, elapsed - Self.recordingLiveEdgeBackoffSeconds)
        let startOffset     = recordingByteOffset(for: show, atSeconds: startSeconds) ?? 0
        let relayURL = "http://127.0.0.1:\(config.Web_server_port)/api/watch-recording?show=\(show.show_id)&start=\(startOffset)"
        let mgr = VLCPlayerWindowManager.shared

        // Compares by show id, not the relay URL — startOffset moves every call (it's derived
        // from live elapsed time), so comparing full URLs would almost never match even when this
        // exact show is already open, causing a needless reconnect (remute + rebuffer) instead of
        // just focusing the window.
        let alreadyPlaying = mgr.currentDeviceID == device.DeviceID && VLCBridge.shared.recordingShowId == show.show_id
        if alreadyPlaying { mgr.focus(); return }

        glog("[Watch] '\(show.show_title)' from disk via local relay, starting ~\(Int(elapsed - startSeconds))s behind live (recording in progress): \(show.show_recording_path)")
        mgr.open(url: relayURL, title: show.show_title, device: device, appState: self)
        // Deferred to the next run-loop turn: mgr.open() synchronously creates the player window,
        // and SwiftUI's first render of its toolbar happens inside that same call — setting the
        // scrub-bar anchor synchronously right after lands in the same transaction and never
        // produces a visible update (confirmed: beginRecordingSeek logged, but the toolbar's
        // recordingShowId-driven view never re-rendered). Posting it as a separate main-queue turn
        // makes it a distinct SwiftUI update the toolbar reliably picks up.
        DispatchQueue.main.async {
            VLCBridge.shared.beginRecordingSeek(showId: show.show_id, recordingStart: recordingStart, seekBaseSeconds: startSeconds)
        }
    }

    /// Balances the ensureWebServerRunning() call in watchRecordingInApp(_:) — called from
    /// VLCPlayerWindowManager.playerWindowDidClose() on every player window close, a no-op unless
    /// this session actually used the recording relay.
    func releaseRecordingRelayIfNeeded() {
        guard recordingRelayActive else { return }
        recordingRelayActive = false
        releaseInternalWebServer()
    }

    /// Scrubs the in-progress-recording player (VLCPlayerView's scrub bar) to an approximate point
    /// in the recording. Reconnecting calls VLCBridge.play(url:) directly (not
    /// VLCPlayerWindowManager.open), so it doesn't re-mute or re-show the Start overlay the way a
    /// channel switch does.
    func seekRecording(showId: String, toSeconds seconds: Double) {
        guard let show = shows.first(where: { $0.show_id == showId }),
              !show.show_recording_path.isEmpty,
              let byteOffset = recordingByteOffset(for: show, atSeconds: seconds) else { return }
        let started        = show.show_next ?? Date()
        let clampedSeconds  = max(0, min(seconds, recordingElapsedSeconds(show)))
        let relayURL = "http://127.0.0.1:\(config.Web_server_port)/api/watch-recording?show=\(showId)&start=\(byteOffset)"
        glog("[Watch] seeking '\(show.show_title)' to \(Int(clampedSeconds))s (byte \(byteOffset))")
        VLCBridge.shared.play(url: relayURL)
        VLCBridge.shared.beginRecordingSeek(showId: showId, recordingStart: started, seekBaseSeconds: clampedSeconds)
    }

    /// Jumps a recording-relay session back to the live edge (the same ~30s-behind-live default
    /// watchRecordingInApp starts at) — used by the toolbar's "catch up" button for a recording
    /// session. VLCBridge.catchUpToLive() alone just replays the current URL verbatim, which for
    /// the relay means reconnecting at the same stale &start= byte offset — doing nothing toward
    /// "live" despite the button's tooltip, since that offset never changes on its own.
    func seekRecordingToLiveEdge(showId: String) {
        guard let show = shows.first(where: { $0.show_id == showId }) else { return }
        let elapsed = recordingElapsedSeconds(show)
        seekRecording(showId: showId, toSeconds: max(0, elapsed - Self.recordingLiveEdgeBackoffSeconds))
    }

    func watchRecordingInVLC(_ show: Show) {
        guard !show.show_recording_path.isEmpty,
              FileManager.default.fileExists(atPath: show.show_recording_path) else {
            watchInVLC(url: show.show_url, transcode: show.show_transcode, deviceId: show.hdhr_record)
            return
        }
        guard config.Watch_in_VLC, let vlcApp = VLCBridge.locateApp() else { return }
        let fileURL = URL(fileURLWithPath: show.show_recording_path)
        glog("[Watch] '\(show.show_title)' from disk in external VLC: \(show.show_recording_path)")
        NSWorkspace.shared.open([fileURL], withApplicationAt: vlcApp, configuration: .init()) { _, _ in }
    }

    private func alertTunerFull(tunerCount: Int, deviceId: String) {
        let alert = NSAlert()
        alert.messageText = "No Tuner Available"
        alert.informativeText = "All \(tunerCount) tuner\(tunerCount == 1 ? "" : "s") on \(deviceId) are in use. Stop a recording or close another stream to free up a tuner."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Tuner signal status

    // 1.5s delay lets the device register the change before we poll.
    func refreshTunerOccupancy() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)   // 1.5s — let device register the change
            captureResourceHeaders()
            for device in devices { await fetchDeviceStatus(for: device) }
            releaseAssertionsIfIdle()
        }
    }

    // Requires no recording shows and no VLC session to avoid releasing during the tuner lock-in gap.
    private func releaseAssertionsIfIdle() {
        let anyTunerActive = devices.compactMap { deviceTunerOccupancy[$0.DeviceID] }
            .contains { $0.contains { $0.VctNumber != nil } }
        guard !anyTunerActive,
              recordingShows.isEmpty,
              VLCPlayerWindowManager.shared.currentDeviceID == nil
        else { return }
        recordingManager.releaseAllAssertions()
    }

    private func captureResourceHeaders() {
        for i in shows.indices where shows[i].show_recording && shows[i].show_tuner_resource.isEmpty {
            if let resource = recordingManager.readHDHRResource(showId: shows[i].show_id) {
                shows[i].show_tuner_resource = resource
                glog("[Rec] \(shows[i].show_title) tuner resource: \(resource)")
            }
        }
    }

    // Coalesces concurrent callers for the same device onto one real fetch — several call sites
    // (idle-loop per-tick, startup, probes, watchInApp/watchInVLC forcing a fresh poll before
    // checking tuner availability) can all target the same device within a short window. A second
    // caller awaits the same in-flight Task rather than either stacking up redundant requests or
    // (the wrong fix) skipping and returning immediately with stale data — watchInApp/watchInVLC
    // specifically need the awaited call to reflect an actually-fresh poll.
    private func fetchDeviceStatus(for device: HDHRDevice) async {
        let id = device.DeviceID
        if let existing = fetchStatusTasks[id] {
            await existing.value
            return
        }
        let task = Task { await self.fetchDeviceStatusUncached(for: device) }
        fetchStatusTasks[id] = task
        defer { fetchStatusTasks.removeValue(forKey: id) }
        await task.value
    }

    // Fetches /tunerN/vstatus via the tuner index from status.json — O(1) vstatus calls per show.
    private func fetchDeviceStatusUncached(for device: HDHRDevice) async {
        guard let url = URL(string: device.statusURL),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let tuners = try? JSONDecoder().decode([DeviceTunerInfo].self, from: data)
        else { return }

        // Write only when the active-tuner *count* actually changed — regardless of menuIsOpen.
        // Deliberately compares just the count, not the full tuners array/struct: per-tuner fields
        // like SignalQualityPercent fluctuate on essentially every poll even when nothing about
        // occupancy changed, so a full-struct comparison would defeat the point (every tick would
        // look "changed"). Tradeoff: per-tuner identity (Resource/VctNumber/TargetIP) in the
        // stored value can now go stale whenever the count doesn't move, even with the menu
        // closed — a real widening vs. the old behavior, where staleness was bounded to "while
        // the menu happens to be open." Two known readers of that per-tuner detail (not just the
        // count): stopRecording's optimistic tuner-clear (AppState.swift), and the web UI's
        // per-tuner dev-bar dropdown (WebServer.swift's recsByDevJS, docs/WebServer.md) — both
        // just display/copy through whatever's stored, so a stale entry there self-heals on the
        // next count-changing poll rather than needing anything more. A stale "X/Y" menu-header
        // count for as long as the menu happens to be open (this app's own tuner usage never
        // changes that fast, but an external consumer — another machine running this app, a TV,
        // any other client hitting the same physical tuner — can, and the whole point of this
        // count is to reflect that) is worse than the occasional submenu dismiss a genuine count
        // change could cause (see CLAUDE.md's "Menu rebuild churn" invariant). Signal alerting
        // always runs regardless, further down — not
        // display-only.
        //
        // While the menu is open specifically, that "worth the rare dismiss" reasoning only holds
        // if the dismiss really is rare — the count-changed check alone doesn't bound how *often*
        // it can fire. An external consumer channel-surfing can legitimately flip the locked/
        // unlocked count on consecutive ~10s idle-loop ticks, which would otherwise re-glitch the
        // open menu every tick for as long as the surfing continues — exactly the scenario a user
        // opening the menu to check "who's using my tuner" would hit. The cooldown below caps
        // real-change disruption to once per menuOpenTunerWriteCooldown regardless; closed-menu
        // writes are never throttled (no glitch risk there).
        let newActiveCount = tuners.filter { $0.VctNumber != nil }.count
        let oldActiveCount = deviceTunerOccupancy[device.DeviceID]?.filter { $0.VctNumber != nil }.count
        let countChanged = newActiveCount != oldActiveCount
        let cooldownElapsed = lastMenuOpenTunerWrite[device.DeviceID].map {
            Date().timeIntervalSince($0) >= Self.menuOpenTunerWriteCooldown
        } ?? true
        if countChanged && (!menuIsOpen || cooldownElapsed) {
            if menuIsOpen { lastMenuOpenTunerWrite[device.DeviceID] = Date() }
            deviceTunerOccupancy[device.DeviceID] = tuners

            let active   = tuners.filter { $0.VctNumber != nil }.count
            let recCount = recordingShows.filter { $0.hdhr_record == device.DeviceID }.count
            let vlcOpen  = VLCPlayerWindowManager.shared.currentDeviceID == device.DeviceID ? 1 : 0
            let auditLine = "\(device.DeviceID): \(active)/\(device.TunerCount ?? 0) active  rec=\(recCount) vlc=\(vlcOpen)"
            if lastTunerAudit[device.DeviceID] != auditLine {
                lastTunerAudit[device.DeviceID] = auditLine
                glog("[TunerAudit] \(auditLine)")
            }
        }

        for show in recordingShows where show.hdhr_record == device.DeviceID {
            // Prefer exact tuner from the X-HDHomeRun-Resource response header (captured at stream start).
            // Fall back to VctNumber channel match, then any locked tuner.
            let match = (!show.show_tuner_resource.isEmpty
                            ? tuners.first(where: { $0.Resource.lowercased() == show.show_tuner_resource })
                            : nil)
                     ?? tuners.first(where: { $0.VctNumber == show.show_channel })
                     ?? tuners.first(where: { $0.VctNumber != nil })
            guard let match,
                  let idx = Int(match.Resource.dropFirst(5))   // "tuner0" → 0
            else { continue }

            // Passive signal collection + alerts use status.json snq — works on all device types
            // including EXTEND (which returns 404 for /tunerN/vstatus).
            // Key uses LineupEntry.Frequency (same source views use for lookup) not status.json Frequency.
            let statusSnq = match.SignalQualityPercent ?? 0
            if let entry = lineups[device.DeviceID]?.first(where: { $0.GuideNumber == show.show_channel }) {
                ChannelSignalStore.shared.record(guideName: entry.GuideName, snq: statusSnq)
            }
            if statusSnq < 30 {
                let ticks = (signalDropoutTicks[show.show_id] ?? 0) + 1
                signalDropoutTicks[show.show_id] = ticks
                if ticks == 2 { sendSignalAlert(show: show, snq: statusSnq, isRecovery: false) }
            } else {
                let wasDown = (signalDropoutTicks[show.show_id] ?? 0) >= 2
                signalDropoutTicks[show.show_id] = 0
                if wasDown { sendSignalAlert(show: show, snq: statusSnq, isRecovery: true) }
            }

            // vstatus: additional detail (lock type, bitrate) for the menu signal display.
            // Optional — EXTEND returns 404 here; collection above already ran.
            // tunerStatus is @Published — skip the fetch entirely while menu is open.
            guard !menuIsOpen else { continue }
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
            // The vstatus fetch above suspends on a real network await — a web-UI delete landing
            // during that window already ran deleteShow's tunerStatus cleanup for this show_id;
            // writing here afterward would silently re-add a display-only leak that nothing will
            // ever clear again (the show is gone, so deleteShow never runs on it a second time).
            guard shows.contains(where: { $0.show_id == show.show_id }) else { continue }
            tunerStatus[show.show_id] = TunerStatus(
                signalStrength: Int(kv["ss"]  ?? "0") ?? 0,
                lockType:       lock,
                bitrateMbps:    Double(kv["bps"] ?? "0").map { $0 / 1_000_000 } ?? 0
            )
        }
    }

    // MARK: - Signal quality helpers

    func startSignalScan(force: Bool = false) {
        signalScanTask?.cancel()
        signalScanTask = Task {
            // Only scan channels that don't already have fresh data — lets us resume a
            // partial scan and skip work after a clean full scan. force=true bypasses this.
            let pendingByDevice: [(HDHRDevice, [LineupEntry])] = devices.compactMap { device in
                let entries = lineups[device.DeviceID] ?? []
                let needed = force ? entries : entries.filter {
                    ChannelSignalStore.shared.needsSample(guideName: $0.GuideName)
                }
                return needed.isEmpty ? nil : (device, needed)
            }
            let total = pendingByDevice.reduce(0) { $0 + $1.1.count }
            guard total > 0 else { glog("[Signal] scan: nothing to do (all channels fresh)"); return }
            glog("[Signal] scan starting — \(total) channel(s) need samples")
            var scanned = 0

            outer: for (device, entries) in pendingByDevice {
                let batchSize = 1
                var j = 0
                while j < entries.count {
                    guard !Task.isCancelled else { break outer }
                    let batch  = Array(entries[j ..< min(j + batchSize, entries.count)])
                    j       += batchSize
                    scanned += batch.count

                    await MainActor.run {
                        signalScanProgress = "Scanning \(batch[0].GuideName) (\(scanned)/\(total))…"
                    }

                    // Open one stream per channel in the batch concurrently (locks each tuner),
                    // then read status.json 3 times (500ms apart) to collect 3 SNQ samples per
                    // channel — gives the rolling average enough data on the first scan.
                    let statusURL = URL(string: device.statusURL)!
                    var gotSample = Set<String>()
                    await withTaskGroup(of: Void.self) { group in
                        for entry in batch {
                            // Device-reported lineup URL — same source every other stream URL in the
                            // app derives from (show_url, Watch Now, etc.) — not a hardcoded port.
                            guard let urlString = entry.URL, let url = URL(string: urlString) else { continue }
                            group.addTask { _ = try? await URLSession.shared.data(from: url) }
                        }
                        for _ in 0..<3 {
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            if let (statusData, _) = try? await URLSession.shared.data(from: statusURL),
                               let tunerInfos = try? JSONDecoder().decode([DeviceTunerInfo].self, from: statusData) {
                                for entry in batch {
                                    guard let match = tunerInfos.first(where: { $0.VctNumber == entry.GuideNumber }),
                                          let snq = match.SignalQualityPercent else { continue }
                                    ChannelSignalStore.shared.record(guideName: entry.GuideName, snq: snq)
                                    gotSample.insert(ChannelSignalStore.key(for: entry.GuideName))
                                }
                            }
                        }
                        group.cancelAll()  // release tuners; stream tasks observe cancellation and exit
                    }
                    // Channels that never locked during the 3 polls get snq=0 so they render
                    // as a red 1-bar indicator rather than staying invisible (noData).
                    for entry in batch where !gotSample.contains(ChannelSignalStore.key(for: entry.GuideName)) {
                        ChannelSignalStore.shared.record(guideName: entry.GuideName, snq: 0)
                    }

                    // Flush after each batch so partial progress survives a quit.
                    ChannelSignalStore.shared.flush()

                    for entry in batch {
                        let key = ChannelSignalStore.key(for: entry.GuideName)
                        webServer.broadcastEvent(["type": "signal_update",
                                                  "gname": key,
                                                  "bucket": ChannelSignalStore.shared.buckets[key]?.rawValue ?? "noData"])
                    }
                }
            }

            glog("[Signal] scan complete — \(scanned) channel(s) sampled")
            await MainActor.run { signalScanProgress = nil }
        }
    }

    func cancelSignalScan() {
        signalScanTask?.cancel()
        signalScanTask = nil
        signalScanProgress = nil
    }

    private func sendSignalAlert(show: Show, snq: Int, isRecovery: Bool) {
        let verb = isRecovery ? "recovered" : "degraded"
        let msg  = "Signal \(verb) on \(show.show_title) (\(show.show_channel)): snq=\(snq)%"
        glog("[SignalAlert] \(msg)", level: isRecovery ? .info : .warning)
        guard config.Signal_quality_alert_notify else { return }
        notify("Signal \(isRecovery ? "Recovered" : "Degraded")", body: msg, subtitle: "")
        discordError("Signal \(isRecovery ? "Recovered" : "Degraded")", detail: msg,
                     color: isRecovery ? 0x4CAF50 : 0xE53935, enabled: true)
    }

    // MARK: - Conflict detection

    // True only when the in-app VLC window is open on this device AND playing a live device
    // stream — not the recording-playback relay (bridge.recordingShowId != nil), which reads an
    // already-recording show from disk over a loopback connection and occupies no tuner of its
    // own. Without this distinction, watching your own in-progress recording via Watch Now! would
    // make the app think a tuner is in use that isn't — exactly the cost this feature exists to
    // avoid (docs/WebServer.md's /api/watch-recording relay).
    func vlcOccupiesTuner(for deviceId: String) -> Bool {
        VLCPlayerWindowManager.shared.currentDeviceID == deviceId && VLCBridge.shared.recordingShowId == nil
    }

    // Uses activeTunerCount's hardware-polled status.json count (not just this instance's own
    // recordingShows) so a tuner locked by another machine running this app against the same
    // physical HDHomeRun device is also honored — not just tuners this instance started itself.
    func tunersFull(for deviceId: String) -> Bool {
        guard let device = devices.first(where: { $0.DeviceID == deviceId }),
              let tunerCount = device.TunerCount, tunerCount > 0 else { return false }
        return activeTunerCount(for: deviceId) >= tunerCount
    }

    // Live active-tuner count for a device, consistent with the guide's status.json-based badge.
    // Takes the max of hardware occupancy (catches externally-used tuners) and this app's
    // recordings + VLC stream (catches a just-started capture not yet reflected in status.json).
    // Never count recordings alone — the in-app VLC stream also occupies a tuner (unless it's
    // playing the recording relay — see vlcOccupiesTuner).
    func activeTunerCount(for deviceId: String) -> Int {
        let hw  = deviceTunerOccupancy[deviceId]?.filter { $0.VctNumber != nil }.count ?? 0
        let rec = recordingShows.filter { $0.hdhr_record == deviceId }.count
        let vlc = vlcOccupiesTuner(for: deviceId) ? 1 : 0
        return max(hw, rec + vlc)
    }

    // Same overlap definition as hasConflict, but returns the other show(s) so the menu can
    // list what's actually contending for the tuner instead of just flagging that it conflicts.
    func conflictingShows(for show: Show) -> [Show] {
        guard let next = show.show_next, let end = show.show_end else { return [] }
        return shows.filter { other in
            guard other.show_active, !other.show_paused,
                  other.show_id != show.show_id,
                  other.hdhr_record == show.hdhr_record,
                  let oNext = other.show_next, let oEnd = other.show_end
            else { return false }
            return oNext < end && oEnd > next
        }.sorted { $0.show_channel < $1.show_channel }
    }

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
            glog("=== hdhrVCRplus quit ===")
            VLCBridge.shared.releasePlayer()
            recordingManager.stopAll()
            webServer.stop()
            saveConfig()
            NSApplication.shared.terminate(nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Recordings in progress"
        let list = recordingShows.map { "• \($0.show_title) (Channel \($0.show_channel))" }.joined(separator: "\n")
        alert.informativeText = "These recordings will be stopped:\n\n\(list)\n\nChoose \"Keep Recording\" to exit while recordings continue — relaunch the app to reconnect."
        alert.addButton(withTitle: "Keep Recording & Quit") // default (Return key) — curl survives as an orphan; reattachRecordings() reconnects on next launch
        alert.addButton(withTitle: "Stop Recordings & Quit")
        alert.addButton(withTitle: "Go Back")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:  // keep recordings running, quit
            glog("=== hdhrVCRplus quit (recordings kept running) ===")
            VLCBridge.shared.releasePlayer()
            webServer.stop()
            saveConfig()
            NSApplication.shared.terminate(nil)
        case .alertSecondButtonReturn: // stop all, then quit
            glog("=== hdhrVCRplus quit (recordings stopped) ===")
            VLCBridge.shared.releasePlayer()
            recordingManager.stopAll()
            webServer.stop()
            saveConfig()
            NSApplication.shared.terminate(nil)
        default:                       // Go Back — cancel
            break
        }
    }
}

// MARK: - JIT Warmup Placeholder

// Exercises the same SwiftUI primitives as MenuContent at O(1) cost — no live state access.
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
