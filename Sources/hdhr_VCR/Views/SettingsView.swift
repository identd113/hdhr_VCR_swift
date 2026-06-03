import SwiftUI
import AppKit

private enum SettingsCategory: String, CaseIterable, Identifiable {
    var id: String { rawValue }
    case general       = "General"
    case recording     = "Recording"
    case guide         = "Guide"
    case notifications = "Notifications"
    case advanced      = "Advanced"
    case webServer     = "Web Server"
    case maintenance   = "Maintenance"
    case about         = "About"

    var icon: String {
        switch self {
        case .general:       return "gear"
        case .recording:     return "record.circle"
        case .guide:         return "tv"
        case .notifications: return "bell.badge"
        case .advanced:      return "terminal"
        case .webServer:     return "globe"
        case .maintenance:   return "wrench.and.screwdriver"
        case .about:         return "info.circle"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @AppStorage("defaultSaveDirectory") private var defaultSaveDirectory: String = ""
    @AppStorage("simulatedMacOSVersion") private var simulatedMacOSVersion: Int = 0
    @State private var selection: SettingsCategory? = .general
    @State private var draft: AppConfig = AppConfig()
    // Shadow drafts for settings that live outside AppConfig — applied only on Save
    @State private var draftSaveDirectory: String      = ""
    @State private var draftLaunchAtLogin: Bool        = false
    @State private var draftSimulatedOS:   Int         = 0
    @State private var loginItemError: String          = ""

    private var launchAgentPlistURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LaunchAgents/com.hdhr.vcrplus.plist")
    }

    // LaunchAgent plist — works regardless of code signing, no BTM approval needed
    private var launchAtLoginRegistered: Bool {
        FileManager.default.fileExists(atPath: launchAgentPlistURL.path)
    }

    private func writeLaunchAgent() throws {
        let plist: [String: Any] = [
            "Label": "com.hdhr.vcrplus",
            "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundleURL.path],
            "RunAtLoad": true
        ]
        let dir = launchAgentPlistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: launchAgentPlistURL)
    }
    @State private var logoTapCount  = 0
    @State private var changelogHeight: CGFloat = 0

    private static let changelogText: String = {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let raw = try? String(contentsOf: url, encoding: .utf8),
              let range = raw.range(of: "\n## ") else { return "" }
        // Strip the file title; return only the version sections
        return String(raw[range.lowerBound...]).trimmingCharacters(in: .newlines)
    }()
    @State private var maintenanceStatus: String = ""
    @State private var maintenanceBusy: Bool = false
    @State private var brewBusy: Bool = false
    @State private var brewStatus: String = ""

    // Discord webhook test state
    private enum WebhookTestStatus { case idle, untested, testing, passed, failed }
    @State private var webhookTestStatus: WebhookTestStatus = .idle
    @State private var webhookTestInProgress: Bool = false

    private var webhookNeedsTest: Bool {
        draft.Discord_enabled
            && !draft.Discord_webhook_url.isEmpty
            && draft.Discord_webhook_url != state.config.Discord_webhook_url
            && webhookTestStatus != .passed
    }

    private var webPortInvalid: Bool {
        draft.Web_server_enabled
            && (draft.Web_server_port < 1025 || draft.Web_server_port > 65534)
    }

    private var isDirty: Bool {
        draft != state.config
            || draftSaveDirectory != defaultSaveDirectory
            || draftLaunchAtLogin != launchAtLoginRegistered
            || draftSimulatedOS   != simulatedMacOSVersion
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                List(SettingsCategory.allCases, selection: $selection) { cat in
                    Label(cat.rawValue, systemImage: cat.icon)
                        .tag(cat)
                }
                .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 200)
            } detail: {
                detailContent
            }

            Divider()

            // ── Persistent save bar ────────────────────────────────────────
            HStack {
                if webhookNeedsTest {
                    Label("Test the webhook before saving", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Discard") { discardDraft() }
                        .foregroundStyle(.secondary)
                } else if webPortInvalid {
                    Label("Fix the web server port before saving", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Discard") { discardDraft() }
                        .foregroundStyle(.secondary)
                } else if isDirty {
                    Text("Unsaved changes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Discard") { discardDraft() }
                        .foregroundStyle(.secondary)
                }
                Spacer()
                let canSave = isDirty && !webhookNeedsTest && !webPortInvalid
                Button("Save") { applyAndSave() }
                    .disabled(!canSave)
                    .keyboardShortcut("s", modifiers: .command)
                Button("Save & Close") {
                    if canSave { applyAndSave() }
                    NSApp.keyWindow?.close()
                }
                .buttonStyle(.borderedProminent)
                .tint(canSave ? .orange : .accentColor)
                .keyboardShortcut(.defaultAction)
                .disabled(webhookNeedsTest || webPortInvalid)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 560, height: 520)
        .background(WindowCloseInterceptor(isDirty: isDirty, canSave: !webhookNeedsTest && !webPortInvalid, onSave: applyAndSave))
        .onAppear {
            resetDrafts()
            // Clear a stale saved interface: if the named NIC isn't available right now
            // (e.g. VPN disconnected), reset to Auto immediately in both draft AND live
            // config. Without the live-config clear, a Discard-and-close would leave the
            // dead interface name in state.config, causing every subsequent curl recording
            // to fail with "interface not found" until the user manually Saves.
            let available = Set(availableNetworkInterfaces().map { $0.name })
            if !draft.Network_interface.isEmpty && !available.contains(draft.Network_interface) {
                draft.Network_interface = ""
                state.config.Network_interface = ""
                state.saveConfig()
            }
            // Migrate: a previous build stored realVersion for "current"; normalize to 0.
            let real = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
            if simulatedMacOSVersion == real {
                simulatedMacOSVersion = 0
                draftSimulatedOS = 0   // re-sync after migration
            }
        }
    }

    private func resetDrafts() {
        draft              = state.config
        draftSaveDirectory = defaultSaveDirectory
        draftLaunchAtLogin = launchAtLoginRegistered
        loginItemError = ""
        draftSimulatedOS   = simulatedMacOSVersion
        // Existing saved URL is considered verified (was tested when first saved)
        webhookTestStatus  = state.config.Discord_webhook_url.isEmpty ? .idle : .passed
    }

    private func discardDraft() { resetDrafts() }

    private func applyAndSave() {
        let old = state.config
        if draft.Idle_timer_interval != old.Idle_timer_interval { glog("[Settings] IdleTimerInterval: \(old.Idle_timer_interval) → \(draft.Idle_timer_interval)") }
        if draft.Network_interface   != old.Network_interface   { glog("[Settings] NetworkInterface: '\(old.Network_interface)' → '\(draft.Network_interface)'") }
        if draft.Discord_webhook_url != old.Discord_webhook_url { glog("[Settings] DiscordWebhook changed") }
        if draft.Discord_enabled     != old.Discord_enabled     { glog("[Settings] DiscordEnabled: \(old.Discord_enabled) → \(draft.Discord_enabled)") }
        if draft.Hdhr_setup_folder   != old.Hdhr_setup_folder   { glog("[Settings] SaveFolder: '\(old.Hdhr_setup_folder)' → '\(draft.Hdhr_setup_folder)'") }
        if draft.GuideHours          != old.GuideHours          { glog("[Settings] GuideHours: \(old.GuideHours) → \(draft.GuideHours)") }
        if draft.Default_transcode   != old.Default_transcode   { glog("[Settings] DefaultTranscode: '\(old.Default_transcode)' → '\(draft.Default_transcode)'") }
        let intervalChanged   = draft.Idle_timer_interval != old.Idle_timer_interval
        let interfaceChanged  = draft.Network_interface   != old.Network_interface
        let webServerChanged  = draft.Web_server_enabled  != old.Web_server_enabled
                             || draft.Web_server_port     != old.Web_server_port
        state.config = draft
        state.saveConfig()
        if intervalChanged { state.startTimer() }
        // Commit settings that live outside AppConfig
        defaultSaveDirectory = draftSaveDirectory
        simulatedMacOSVersion = draftSimulatedOS
        loginItemError = ""
        if draftLaunchAtLogin != launchAtLoginRegistered {
            do {
                if draftLaunchAtLogin { try writeLaunchAgent() }
                else                  { try FileManager.default.removeItem(at: launchAgentPlistURL) }
            } catch {
                glog("[Settings] Login item: \(error)", level: .error)
                draftLaunchAtLogin = launchAtLoginRegistered
                loginItemError = error.localizedDescription
            }
        }
        // Changing the network interface requires fresh device discovery and guide data
        // so curl and UDP both bind to the correct NIC immediately.
        if interfaceChanged {
            state.guideStore.invalidateAll()
            state.guideByDevice = [:]
            Task { @MainActor in
                await state.rediscoverDevices()
                await state.refreshGuide()
            }
        }
        if webServerChanged { state.setupWebServer() }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selection ?? .general {
        case .general:       generalView
        case .recording:     recordingView
        case .guide:         guideView
        case .notifications: notificationsView
        case .advanced:      advancedView
        case .webServer:     webServerView
        case .maintenance:   maintenanceView
        case .about:         aboutView
        }
    }

    // MARK: - General

    private var generalView: some View {
        Form {
            Section("System") {
                Toggle("Launch at Login", isOn: $draftLaunchAtLogin)
                if !loginItemError.isEmpty {
                    Label(loginItemError, systemImage: "xmark.circle.fill")
                        .font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }

    // MARK: - Recording

    private var recordingView: some View {
        Form {
            Section("Recording") {
                LabeledContent("Default folder") {
                    HStack {
                        Text(saveDirLabel).foregroundStyle(.secondary)
                        Button("Choose…") { chooseFolder() }
                        if !draftSaveDirectory.isEmpty {
                            Button("Reset") { draftSaveDirectory = "" }.foregroundStyle(.secondary)
                        }
                    }
                }

                Picker("Default transcode", selection: $draft.Default_transcode) {
                    Text("None").tag("none")
                    Text("Heavy").tag("heavy")
                    Text("Mobile").tag("mobile")
                    Text("Internet 720").tag("internet720")
                }
                .help("Applied to all new shows unless overridden per show. None keeps the raw MPEG stream (recommended).")

                Stepper(
                    "Min free disk: \(draft.Min_disk_free_gb, specifier: "%.0f") GB",
                    value: $draft.Min_disk_free_gb,
                    in: 1...100, step: 1
                )
                .help("Recordings are skipped when the save drive has less free space than this threshold.")

                Stepper(
                    "Pause after \(draft.Fail_count_setting) failure(s)",
                    value: $draft.Fail_count_setting,
                    in: 1...10
                )
                .help("A show is automatically paused after this many consecutive recording failures. Reset using Maintenance → Reactivate Paused Shows, or Edit Show → Reset.")

                if FileManager.default.fileExists(atPath: "/Applications/VLC.app") {
                    Toggle("Watch in VLC", isOn: $draft.Watch_in_VLC)
                        .help("Show a 'Watch in VLC' option for live and recording streams")

                    Picker("Min buffer rate", selection: $draft.Player_buffer_min_rate) {
                        ForEach(Array(stride(from: 90, through: 100, by: 1)), id: \.self) { pct in
                            Text(pct == 100 ? "100% (disabled)" : "\(pct)%").tag(pct)
                        }
                    }
                    .help("Floor playback speed for the in-app player. Lower fills the 8-second live buffer faster; 100% disables buffering.")
                }

                // Bonus Time: add extra recording past the guide end for sports shows
                Toggle("Bonus Time for sports", isOn: $draft.Sports_padding_enabled)
                    .help("Records extra time after the guide end for shows tagged as sports, to capture overtime")
                if draft.Sports_padding_enabled {
                    // Stepper visible only when Bonus Time is on; step by 5 min for convenience
                    Stepper("Bonus Time: \(draft.Sports_padding_minutes) min",
                            value: $draft.Sports_padding_minutes, in: 10...60, step: 5)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Recording")
    }

    // MARK: - Guide

    private var guideView: some View {
        Form {
            Section("Guide") {
                Stepper(
                    "Show next \(draft.GuideHours) hours",
                    value: $draft.GuideHours,
                    in: 1...48
                )
                .help("How many hours of future programming the guide fetches and displays. Longer windows let you schedule further out but take more time to download.")
                Stepper(
                    "Series scan retry: \(draft.Series_scan_retry_hours) hr",
                    value: $draft.Series_scan_retry_hours,
                    in: 1...24
                )
                .help("How often hdhr_VCR re-checks the guide to find an upcoming episode for series shows that have no scheduled air time.")
                Button("Update Guides Now") {
                    state.refreshAll()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Guide")
    }

    // MARK: - Notifications

    private var notificationsView: some View {
        Form {
            Section("Notifications") {
                Stepper(
                    "Up Next: \(Int(draft.Notify_upnext)) min before",
                    value: Binding(
                        get: { Int(draft.Notify_upnext) },
                        set: { draft.Notify_upnext = Double($0) }
                    ),
                    in: 5...120, step: 5
                )
                .help("A macOS notification is sent this many minutes before a show's scheduled start — an early heads-up that a recording is coming.")
                Stepper(
                    "Recording alert: \(Int(draft.Notify_recording)) min before",
                    value: Binding(
                        get: { Int(draft.Notify_recording) },
                        set: { draft.Notify_recording = Double($0) }
                    ),
                    in: 1...60
                )
                .help("A second macOS notification fires this many minutes before recording begins — a last-minute reminder, firing closer to start than Up Next.")
                if draft.Notify_recording >= draft.Notify_upnext {
                    Label("Recording alert fires at or after Up Next — the Up Next notification won't appear first.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Discord") {
                Toggle("Enable Discord notifications", isOn: $draft.Discord_enabled)
                    .help("Post recording status updates to a Discord channel via webhook URL.")

                if draft.Discord_enabled {
                    HStack(spacing: 8) {
                        TextField("Webhook URL", text: $draft.Discord_webhook_url)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .onChange(of: draft.Discord_webhook_url) {
                                if draft.Discord_webhook_url != state.config.Discord_webhook_url {
                                    webhookTestStatus = draft.Discord_webhook_url.isEmpty ? .idle : .untested
                                } else {
                                    webhookTestStatus = draft.Discord_webhook_url.isEmpty ? .idle : .passed
                                }
                            }

                        if webhookTestStatus == .testing {
                            ProgressView().controlSize(.small).frame(width: 60)
                        } else {
                            Button("Test") {
                                webhookTestStatus = .testing
                                Task {
                                    let ok = await state.checkWebhookURL(draft.Discord_webhook_url)
                                    webhookTestStatus = ok ? .passed : .failed
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(draft.Discord_webhook_url.isEmpty)
                            .frame(width: 60)
                        }
                    }

                    switch webhookTestStatus {
                    case .passed:
                        Label("Verified", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).font(.caption)
                    case .failed:
                        Label("Connection failed — check the URL", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red).font(.caption)
                    case .untested:
                        Text("Test the webhook before saving.")
                            .foregroundStyle(.orange).font(.caption)
                    default:
                        EmptyView()
                    }
                }
            }

            if draft.Discord_enabled && !draft.Discord_webhook_url.isEmpty {
                Section("Notify when…") {
                    Toggle("Recording started",             isOn: $draft.Discord_on_start)
                    Toggle("Recording complete",            isOn: $draft.Discord_on_complete)
                    Toggle("Recording failed",              isOn: $draft.Discord_on_failed)
                    Toggle("Show paused",                   isOn: $draft.Discord_on_paused)
                    Toggle("Skipped — disk full",           isOn: $draft.Discord_on_skipped)
                    Toggle("Tuner conflict",                isOn: $draft.Discord_on_conflict)
                    Toggle("Guide load failed",             isOn: $draft.Discord_on_guide_error)
                    Toggle("Show added",                    isOn: $draft.Discord_on_show_added)
                    Toggle("Up Next reminder",              isOn: $draft.Discord_on_upnext)
                    Toggle("Recording Soon reminder",       isOn: $draft.Discord_on_soon)
                    Toggle("Progress updates (every 5 min)", isOn: $draft.Discord_on_progress)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Notifications")
    }

    // MARK: - Advanced

    private var advancedView: some View {
        Form {
            Section("Network") {
                Picker("Discovery & recording interface", selection: $draft.Network_interface) {
                    Text("Auto").tag("")
                    ForEach(availableNetworkInterfaces()) { iface in
                        Text(iface.displayLabel).tag(iface.name)
                    }
                }
                Text("Binds UDP discovery and curl recordings to a specific interface. VPN tunnels are listed (utun*, tun*, cscotun*, gpd*, etc.) — use one if your HDHomeRun is on a remote network reachable via VPN.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Performance") {
                Stepper(
                    "Idle check: every \(draft.Idle_timer_interval) sec",
                    value: $draft.Idle_timer_interval,
                    in: 5...60, step: 5
                )
                .help("How often the app checks for recordings due to start or end. Lower values give more precise timing at the cost of slightly more CPU.")
            }

            Section("Logging") {
                Button("Show App Log in Console") {
                    // Opens Console.app and pre-fills the search field with the subsystem.
                    // macOS 12+ supports the x-apple.systempreferences: URL for Console;
                    // falling back to direct launch keeps it working on older builds.
                    let subsystem = "com.hdhr.vcrplus"
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Console?subsystem=\(subsystem)") {
                        NSWorkspace.shared.open(url)
                    } else {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"))
                    }
                }
                Text("Filter: subsystem == \"\(Bundle.main.bundleIdentifier ?? "com.hdhr.vcrplus")\"")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)

                Toggle("Verbose curl logging", isOn: $draft.Verbose_curl)
                if draft.Verbose_curl {
                    Text("curl stderr → \(RecordingManager.curlLogPath)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("Show curl log in Finder") {
                        let path = RecordingManager.curlLogPath
                        if FileManager.default.fileExists(atPath: path) {
                            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                        } else {
                            NSWorkspace.shared.selectFile(
                                NSHomeDirectory() + "/Library/Logs",
                                inFileViewerRootedAtPath: ""
                            )
                        }
                    }
                }
            }

            Section("Config File") {
                Text(state.configManager.configPath)
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Button("Show config in Finder") {
                    NSWorkspace.shared.selectFile(state.configManager.configPath,
                                                  inFileViewerRootedAtPath: "")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Advanced")
    }

    // MARK: - Web Server

    private var webServerView: some View {
        Form {
            Section("Web Server") {
                Toggle("Enable Web Server", isOn: $draft.Web_server_enabled)
                    .help("Serve a Watch Now web page on your local network. No authentication — trusted LAN use only.")
                if draft.Web_server_enabled {
                    HStack {
                        Text("Port")
                        TextField("1980", value: $draft.Web_server_port, format: .number)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                    }
                    .help("Port number (1025–65534). macOS requires root for ports below 1024. Default: 1980.")
                    if draft.Web_server_port < 1025 || draft.Web_server_port > 65534 {
                        Label("Port must be between 1025 and 65534", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Text("Local network access only. No authentication. Do not expose this port to the internet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if state.config.Web_server_enabled && state.webServerRunning {
                let ip = availableNetworkInterfaces().first(where: { !$0.name.hasPrefix("utun") })?.ip ?? "localhost"
                let urlStr = "http://\(ip):\(state.config.Web_server_port)"
                Section("Access") {
                    HStack {
                        Text(urlStr)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Link("Open", destination: URL(string: urlStr)!)
                    }
                    Text("Open in a browser on any device on your local network.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let err = state.webServerError {
                Section {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Web Server")
    }

    // MARK: - Maintenance

    private var maintenanceView: some View {
        Form {
            Section("Shows") {
                maintenanceRow("Rescan Series",
                               "Re-check the guide for updated next-air times on all active SeriesID shows") {
                    let count = state.shows.filter { $0.show_active && !$0.show_paused && !$0.show_recording && $0.show_use_seriesid }.count
                    await state.rescheduleAllSeries()
                    return "\(count) series show(s) rescheduled"
                }
                maintenanceRow("Reset Fail Counts",
                               "Zero out failure counters on every show without changing active/paused state") {
                    let total = state.shows.count
                    state.resetAllFailCounts()
                    return "Cleared fail counts on \(total) show(s)"
                }
                maintenanceRow("Reactivate Paused Shows",
                               "Reactivate all shows that were paused due to failures and reset their counts") {
                    let count = state.inactiveShows.count
                    state.reactivatePausedShows()
                    return count > 0 ? "\(count) show(s) reactivated" : "No paused shows"
                }
            }
            Section("Guide & Devices") {
                maintenanceRow("Refresh Guide",
                               "Force-reload guide data from all tuners (full network re-fetch)") {
                    await state.refreshGuide()
                    let ch = state.guideByDevice.values.flatMap { $0 }.count
                    return "Guide refreshed — \(ch) channel(s) loaded"
                }
                maintenanceRow("Clear Guide Cache",
                               "Discard all cached guide data — the next guide step will fetch fresh") {
                    state.guideStore.invalidateAll()
                    state.guideByDevice = [:]
                    return "Guide cache cleared"
                }
                maintenanceRow("Rediscover Devices",
                               "Scan the network for HDHomeRun tuners (mDNS + UDP + known hosts)") {
                    await state.rediscoverDevices()
                    return "\(state.devices.count) device(s) found"
                }
            }
            if let brew = brewPath {
                Section("Tools") {
                    brewInstallRow(
                        name: "VLC",
                        description: "Media player used for Watch in VLC — brew install --cask vlc",
                        installed: vlcInstalled,
                        brew: brew,
                        args: ["install", "--cask", "vlc"]
                    )
                    brewInstallRow(
                        name: "HDHomeRun CLI",
                        description: "hdhomerun_config command-line tool — brew install libhdhomerun",
                        installed: hdhrCliInstalled,
                        brew: brew,
                        args: ["install", "libhdhomerun"]
                    )
                    if !brewStatus.isEmpty {
                        Label(brewStatus, systemImage: brewStatus.hasPrefix("Error") ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(brewStatus.hasPrefix("Error") ? .red : .green)
                            .font(.callout)
                    }
                }
            }
            let realVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
            if realVersion > 13 {
                Section("Developer") {
                    Picker("Simulate macOS version", selection: $draftSimulatedOS) {
                        Text("macOS \(realVersion) (current)").tag(0)
                        if realVersion >= 15 { Text("macOS 14 (Sonoma)").tag(14) }
                    }
                    if draftSimulatedOS > 0 {
                        Label("Simulating macOS \(draftSimulatedOS) — reopen guide or wizard to see effect",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            if !maintenanceStatus.isEmpty {
                Section {
                    Label(maintenanceStatus, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Maintenance")
    }

    @ViewBuilder
    private func maintenanceRow(_ title: String, _ description: String,
                                 action: @escaping () async throws -> String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if maintenanceBusy {
                ProgressView().controlSize(.small)
            } else {
                Button("Run") {
                    maintenanceBusy = true
                    maintenanceStatus = ""
                    Task { @MainActor in
                        do { maintenanceStatus = try await action() }
                        catch { maintenanceStatus = "Error: \(error.localizedDescription)" }
                        maintenanceBusy = false
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Brew helpers

    private var brewPath: String? {
        for path in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private var vlcInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Applications/VLC.app")
    }

    private var hdhrCliInstalled: Bool {
        for path in ["/opt/homebrew/bin/hdhomerun_config", "/usr/local/bin/hdhomerun_config"] {
            if FileManager.default.isExecutableFile(atPath: path) { return true }
        }
        return false
    }

    @ViewBuilder
    private func brewInstallRow(name: String, description: String, installed: Bool,
                                brew: String, args: [String]) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).fontWeight(.medium)
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if installed {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            } else if brewBusy {
                ProgressView().controlSize(.small)
            } else {
                Button("Install") {
                    brewBusy = true
                    brewStatus = ""
                    Task {
                        do {
                            try await runBrew(brew, args: args)
                            await MainActor.run {
                                brewStatus = "\(name) installed"
                                brewBusy = false
                            }
                        } catch {
                            await MainActor.run {
                                brewStatus = "Error: \(error.localizedDescription)"
                                brewBusy = false
                            }
                        }
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 2)
    }

    private func runBrew(_ brew: String, args: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: brew)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { p in
                _ = pipe.fileHandleForReading.readDataToEndOfFile()
                if p.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "brew", code: Int(p.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "brew exited with status \(p.terminationStatus)"]
                    ))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    // MARK: - About

    private var aboutView: some View {
        let (filteredText, _) = Self.parseChangelog(Self.changelogText)

        return ScrollView {
            VStack(spacing: 20) {
                ZStack {
                    SignalRing(delay: .milliseconds(0),   trigger: logoTapCount)
                    SignalRing(delay: .milliseconds(150), trigger: logoTapCount)
                    SignalRing(delay: .milliseconds(300), trigger: logoTapCount)
                    if let icon = appIconImage {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .cornerRadius(12)
                            .accessibilityLabel("hdhr VCR app icon")
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 80)).foregroundStyle(.secondary)
                            .accessibilityLabel("hdhr VCR app icon")
                    }
                }
                .frame(width: 180, height: 180)
                .onTapGesture { logoTapCount += 1 }

                Text("hdhr_VCR").font(.largeTitle).bold()
                // appVersion is generated by deploy.sh before each build (format: YYMMDD-HHMM)
                Text("Version \(appVersion) — Swift/SwiftUI rewrite")
                    .foregroundStyle(.secondary)

                Divider()

                Text("""
                hdhr_VCR began in 2016 as an AppleScript application for recording \
                live TV from HDHomeRun network tuners. Built to fill the gap left by \
                discontinued recording software, it grew to support SeriesID-based \
                recording, multi-device discovery, and guide-driven scheduling — all \
                from a simple macOS script.

                This Swift/SwiftUI rewrite brings a native menu bar experience, a \
                cable-guide grid, persistent settings, and modern macOS features like \
                Launch at Login and user notifications, while staying fully compatible \
                with the original AppleScript config format.
                """)
                .font(.callout)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                HStack {
                    Button("Check for Updates") { state.checkForUpdates() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Link("View on GitHub",
                         destination: URL(string: "https://github.com/identd113/hdhr_VCR_swift")!)
                        .buttonStyle(.bordered)
                }

                Text("Changelog")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                MarkdownView(markdown: filteredText, height: $changelogHeight)
                    .frame(height: max(100, changelogHeight))
            }
            .padding()
        }
        .navigationTitle("About")
    }

    // MARK: - Helpers

    private var saveDirLabel: String {
        if !draftSaveDirectory.isEmpty {
            return (draftSaveDirectory as NSString).lastPathComponent
        }
        if !state.config.Hdhr_setup_folder.isEmpty {
            return (state.config.Hdhr_setup_folder as NSString).lastPathComponent + " (from config)"
        }
        return "hdhr_videos (default)"
    }

    // MARK: - Changelog parsing

    /// Splits `text` into sections by "## " headings, keeping only those whose
    /// "(YYMMDD-HHMM)" version stamp is ≤ `appVersion`. Sections with no stamp are
    /// always kept (they predate version stamping). Returns the filtered text and the
    /// latest version found (nil if none), so callers can show an update notice.
    private static func parseChangelog(_ text: String) -> (filtered: String, latestVersion: String?) {
        let sep = "\n## "
        let parts = text.components(separatedBy: sep)
        guard parts.count > 1 else { return (text, nil) }
        var latestVersion: String? = nil
        var kept = [parts[0]]
        for part in parts.dropFirst() {
            let heading = String(part.prefix(while: { $0 != "\n" }))
            let ver = extractVersion(from: heading)
            if latestVersion == nil { latestVersion = ver }
            if let ver, ver > appVersion { continue }   // newer than this build — omit
            kept.append(part)
        }
        return (kept.joined(separator: sep), latestVersion)
    }

    /// Extracts a "(YYMMDD-HHMM)" version stamp from a changelog heading string.
    private static func extractVersion(from heading: String) -> String? {
        guard let open  = heading.firstIndex(of: "("),
              let close = heading.firstIndex(of: ")"),
              open < close else { return nil }
        let inner = String(heading[heading.index(after: open)..<close])
        let parts = inner.components(separatedBy: "-")
        guard parts.count == 2,
              parts[0].count == 6, parts[0].allSatisfy(\.isNumber),
              parts[1].count == 4, parts[1].allSatisfy(\.isNumber) else { return nil }
        return inner
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = state.defaultSaveDir
        if panel.runModal() == .OK, let url = panel.url { draftSaveDirectory = url.path }
    }
}

// MARK: - Signal pulse ring

/// One concentric ring that expands and fades on each logo tap.
/// Three of these staggered by `delay` produce a broadcast-signal pulse.
private struct SignalRing: View {
    let delay:   Duration
    let trigger: Int

    @State private var scale:   CGFloat = 0.5
    @State private var opacity: CGFloat = 0

    var body: some View {
        Circle()
            .stroke(Color.accentColor.opacity(opacity), lineWidth: 2)
            .scaleEffect(scale)
            .task(id: trigger) {
                guard trigger > 0 else { return }
                try? await Task.sleep(for: delay)
                opacity = 0.6
                withAnimation(.easeOut(duration: 0.8)) {
                    scale   = 1.75
                    opacity = 0
                }
                try? await Task.sleep(for: .milliseconds(850))
                scale = 0.5
            }
    }
}

// MARK: - Markdown renderer

/// NSTextView-backed markdown renderer. Reports its natural height via `height` so the
/// caller can size the frame after the first layout pass.
private struct MarkdownView: NSViewRepresentable {
    let markdown: String
    @Binding var height: CGFloat

    func makeNSView(context: Context) -> NSTextView {
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainerInset = .zero
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        return tv
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        let parsed = (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .full)
        )).map { NSAttributedString($0) } ?? NSAttributedString(string: markdown)
        textView.textStorage?.setAttributedString(parsed)

        DispatchQueue.main.async {
            guard let lm = textView.layoutManager, let tc = textView.textContainer else { return }
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc)
            height = ceil(used.height)
        }
    }
}

// MARK: - Window close interception

struct WindowCloseInterceptor: NSViewRepresentable {
    let isDirty: Bool
    let canSave: Bool
    let onSave: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.delegate = context.coordinator
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isDirty = isDirty
        context.coordinator.canSave = canSave
        context.coordinator.onSave  = onSave
    }

    func makeCoordinator() -> Coordinator { Coordinator(isDirty: isDirty, canSave: canSave, onSave: onSave) }

    class Coordinator: NSObject, NSWindowDelegate {
        var isDirty: Bool
        var canSave: Bool
        var onSave:  () -> Void

        init(isDirty: Bool, canSave: Bool, onSave: @escaping () -> Void) {
            self.isDirty = isDirty
            self.canSave = canSave
            self.onSave  = onSave
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard isDirty else { return true }
            let alert = NSAlert()
            alert.messageText = "Unsaved Settings"
            if canSave {
                alert.informativeText = "Save your changes before closing?"
                alert.addButton(withTitle: "Save")
                alert.addButton(withTitle: "Discard")
                alert.addButton(withTitle: "Cancel")
                switch alert.runModal() {
                case .alertFirstButtonReturn:  onSave(); return true
                case .alertSecondButtonReturn: return true
                default:                       return false
                }
            } else {
                alert.informativeText = "Settings can't be saved yet — fix the validation error first. Discard changes?"
                alert.addButton(withTitle: "Discard Changes")
                alert.addButton(withTitle: "Cancel")
                switch alert.runModal() {
                case .alertFirstButtonReturn: return true
                default:                      return false
                }
            }
        }
    }
}
