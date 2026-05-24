import SwiftUI
import AppKit
import ServiceManagement

private enum SettingsCategory: String, CaseIterable, Identifiable {
    var id: String { rawValue }
    case general       = "General"
    case recording     = "Recording"
    case guide         = "Guide"
    case notifications = "Notifications"
    case advanced      = "Advanced"
    case maintenance   = "Maintenance"
    case about         = "About"

    var icon: String {
        switch self {
        case .general:       return "gear"
        case .recording:     return "record.circle"
        case .guide:         return "tv"
        case .notifications: return "bell.badge"
        case .advanced:      return "terminal"
        case .maintenance:   return "wrench.and.screwdriver"
        case .about:         return "info.circle"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @AppStorage("addShowMode") private var addShowMode: AddShowMode = .menu
    @AppStorage("defaultSaveDirectory") private var defaultSaveDirectory: String = ""
    @AppStorage("simulatedMacOSVersion") private var simulatedMacOSVersion: Int = 0
    @State private var selection: SettingsCategory? = .general
    @State private var draft: AppConfig = AppConfig()
    // Shadow drafts for settings that live outside AppConfig — applied only on Save
    @State private var draftAddShowMode:   AddShowMode = .menu
    @State private var draftSaveDirectory: String      = ""
    @State private var draftLaunchAtLogin: Bool        = false
    @State private var draftSimulatedOS:   Int         = 0
    @State private var liveChangelog: String? = nil
    @State private var easterEggTaps = 0
    @State private var showEasterEgg = false
    @State private var maintenanceStatus: String = ""
    @State private var maintenanceBusy: Bool = false
    @State private var brewBusy: Bool = false
    @State private var brewStatus: String = ""

    private var isDirty: Bool {
        draft != state.config
            || draftAddShowMode   != addShowMode
            || draftSaveDirectory != defaultSaveDirectory
            || draftLaunchAtLogin != (SMAppService.mainApp.status == .enabled)
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
                if isDirty {
                    Text("Unsaved changes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Discard") {
                        draft              = state.config
                        draftAddShowMode   = addShowMode
                        draftSaveDirectory = defaultSaveDirectory
                        draftLaunchAtLogin = SMAppService.mainApp.status == .enabled
                        draftSimulatedOS   = simulatedMacOSVersion
                    }
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Save") { applyAndSave() }
                    .disabled(!isDirty)
                    .keyboardShortcut("s", modifiers: .command)
                Button("Save & Close") {
                    if isDirty { applyAndSave() }
                    NSApp.keyWindow?.close()
                }
                .buttonStyle(.borderedProminent)
                .tint(isDirty ? .orange : .accentColor)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 560, height: 520)
        .background(WindowCloseInterceptor(isDirty: isDirty, onSave: applyAndSave))
        .onAppear {
            draft               = state.config
            draftAddShowMode    = addShowMode
            draftSaveDirectory  = defaultSaveDirectory
            draftLaunchAtLogin  = SMAppService.mainApp.status == .enabled
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
            if simulatedMacOSVersion == real { simulatedMacOSVersion = 0 }
            draftSimulatedOS = simulatedMacOSVersion
        }
    }

    private func applyAndSave() {
        let intervalChanged   = draft.Idle_timer_interval != state.config.Idle_timer_interval
        let interfaceChanged  = draft.Network_interface   != state.config.Network_interface
        state.config = draft
        state.saveConfig()
        if intervalChanged { state.startTimer() }
        // Commit settings that live outside AppConfig
        addShowMode          = draftAddShowMode
        defaultSaveDirectory = draftSaveDirectory
        simulatedMacOSVersion = draftSimulatedOS
        let loginEnabled = SMAppService.mainApp.status == .enabled
        if draftLaunchAtLogin != loginEnabled {
            do {
                if draftLaunchAtLogin { try SMAppService.mainApp.register() }
                else                  { try SMAppService.mainApp.unregister() }
            } catch { print("[Settings] Login item: \(error)") }
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
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selection ?? .general {
        case .general:       generalView
        case .recording:     recordingView
        case .guide:         guideView
        case .notifications: notificationsView
        case .advanced:      advancedView
        case .maintenance:   maintenanceView
        case .about:         aboutView
        }
    }

    // MARK: - General

    private var generalView: some View {
        Form {
            Section("System") {
                Toggle("Launch at Login", isOn: $draftLaunchAtLogin)
            }

            Section("Add Show Method") {
                ForEach(AddShowMode.allCases, id: \.self) { mode in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: draftAddShowMode == mode ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(draftAddShowMode == mode ? Color.accentColor : .secondary)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.label).fontWeight(.medium)
                            Text(mode.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { draftAddShowMode = mode }
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

                Stepper(
                    "Min free disk: \(draft.Min_disk_free_gb, specifier: "%.0f") GB",
                    value: $draft.Min_disk_free_gb,
                    in: 1...100, step: 1
                )

                Stepper(
                    "Pause after \(draft.Fail_count_setting) failure(s)",
                    value: $draft.Fail_count_setting,
                    in: 1...10
                )

                if FileManager.default.fileExists(atPath: "/Applications/VLC.app") {
                    Toggle("Watch in VLC", isOn: $draft.Watch_in_VLC)
                        .help("Show a 'Watch in VLC' option for live and recording streams")
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
                Stepper(
                    "Series scan retry: \(draft.Series_scan_retry_hours) hr",
                    value: $draft.Series_scan_retry_hours,
                    in: 1...24
                )
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
                Stepper(
                    "Recording alert: \(Int(draft.Notify_recording)) min before",
                    value: Binding(
                        get: { Int(draft.Notify_recording) },
                        set: { draft.Notify_recording = Double($0) }
                    ),
                    in: 1...60
                )
                if draft.Notify_recording >= draft.Notify_upnext {
                    Label("Recording alert fires at or after Up Next — the Up Next notification won't appear first.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Discord Webhook") {
                TextField("https://discord.com/api/webhooks/…", text: $draft.Discord_webhook_url)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Text("Paste a Discord webhook URL to send rich notifications to a channel. Leave blank to disable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Discord — Recording Events") {
                discordRow("Recording Started",  event: "start",    isOn: $draft.Discord_on_start)
                discordRow("Recording Complete", event: "complete",  isOn: $draft.Discord_on_complete)
                discordRow("Recording Failed",   event: "failed",   isOn: $draft.Discord_on_failed)
            }
            .disabled(draft.Discord_webhook_url.isEmpty)
            .opacity(draft.Discord_webhook_url.isEmpty ? 0.4 : 1)

            Section("Discord — Show Management") {
                discordRow("Show Paused (max failures / no air days)", event: "paused",     isOn: $draft.Discord_on_paused)
                discordRow("Skipped — Disk Full",                      event: "skipped",    isOn: $draft.Discord_on_skipped)
                discordRow("Tuner Conflict",                           event: "conflict",   isOn: $draft.Discord_on_conflict)
                discordRow("Show Added",                               event: "show_added", isOn: $draft.Discord_on_show_added)
            }
            .disabled(draft.Discord_webhook_url.isEmpty)
            .opacity(draft.Discord_webhook_url.isEmpty ? 0.4 : 1)

            Section("Discord — Alerts") {
                discordRow("Up Next",        event: "upnext", isOn: $draft.Discord_on_upnext)
                discordRow("Recording Soon", event: "soon",   isOn: $draft.Discord_on_soon)
            }
            .disabled(draft.Discord_webhook_url.isEmpty)
            .opacity(draft.Discord_webhook_url.isEmpty ? 0.4 : 1)

            Section("Discord — Errors") {
                discordRow("Guide Load Failed", event: "guide_error", isOn: $draft.Discord_on_guide_error)
            }
            .disabled(draft.Discord_webhook_url.isEmpty)
            .opacity(draft.Discord_webhook_url.isEmpty ? 0.4 : 1)
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
            }

            Section("Logging") {
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

    // MARK: - Maintenance

    private var maintenanceView: some View {
        Form {
            Section("Shows") {
                maintenanceRow("Rescan Series",
                               "Re-check the guide for updated next-air times on all active SeriesID shows") {
                    let count = state.shows.filter { $0.show_active && $0.show_use_seriesid }.count
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
    private func discordRow(_ label: String, event: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(label)
            Spacer()
            Button("Test") { state.testDiscordEvent(event, webhookURL: draft.Discord_webhook_url) }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            Toggle("", isOn: isOn).labelsHidden()
        }
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
        let raw = liveChangelog ?? appChangelog
        let (filteredText, latestVersion) = Self.parseChangelog(raw)
        let updateVersion = latestVersion.flatMap { $0 > appVersion ? $0 : nil }

        return ScrollView {
            VStack(spacing: 20) {
                Group {
                    if let icon = appIconImage {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .cornerRadius(12)
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 80)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 180, height: 180)
                .onTapGesture {
                    easterEggTaps += 1
                    if easterEggTaps >= 5 {
                        state.config.Player_unlocked = true
                        draft.Player_unlocked = true
                        state.saveConfig()
                        showEasterEgg = true
                        easterEggTaps = 0
                    }
                }

                Text("hdhr_VCR").font(.largeTitle).bold()
                // appVersion is generated by deploy.sh before each build (format: YYMMDD-HHMM)
                Text("Version \(appVersion) — Swift/SwiftUI rewrite")
                    .foregroundStyle(.secondary)
                if state.config.Player_unlocked {
                    Text("In-App Player: Unlocked ✓")
                        .font(.caption).foregroundStyle(.secondary)
                }

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

                if let ver = updateVersion {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
                        Text("Update \(ver) is available")
                            .fontWeight(.medium).foregroundStyle(.blue)
                        Spacer()
                        Link("Releases",
                             destination: URL(string: "https://github.com/identd113/hdhr_VCR_swift/releases")!)
                            .buttonStyle(.bordered)
                    }
                }

                Text(updateVersion != nil ? "Changelog (current version)" : "Changelog")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                renderChangelog(filteredText)

                Link("View on GitHub",
                     destination: URL(string: "https://github.com/identd113/hdhr_VCR_swift")!)
                    .buttonStyle(.bordered)
            }
            .padding()
        }
        .navigationTitle("About")
        .task {
            guard liveChangelog == nil,
                  let url = URL(string: "https://raw.githubusercontent.com/identd113/hdhr_VCR_swift/main/CHANGELOG.md"),
                  let (data, resp) = try? await URLSession.shared.data(from: url),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let text = String(data: data, encoding: .utf8)
            else { return }
            liveChangelog = text
        }
        .alert("In-App Live Streaming Unlocked!", isPresented: $showEasterEgg) {
            Button("OK") {}
        } message: {
            Text("Tap \"Watch Now!\" in the cable guide or recording menus to play streams in a pop-out window. Volume and full-screen controls are built in.")
        }
    }

    // MARK: - Helpers

    private var saveDirLabel: String {
        if !draftSaveDirectory.isEmpty {
            return (draftSaveDirectory as NSString).lastPathComponent
        }
        if !state.config.Hdhr_setup_folder.isEmpty {
            return (state.config.Hdhr_setup_folder as NSString).lastPathComponent + " (from config)"
        }
        return "Movies (default)"
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

    @ViewBuilder
    private func renderChangelog(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("## ") {
                    Text(LocalizedStringKey(String(line.dropFirst(3))))
                        .font(.caption.bold())
                        .padding(.top, 8)
                } else if line.hasPrefix("- ") {
                    HStack(alignment: .top, spacing: 4) {
                        Text("•").font(.caption).padding(.leading, 4)
                        Text(LocalizedStringKey(String(line.dropFirst(2)))).font(.caption)
                    }
                } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(LocalizedStringKey(line)).font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
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

// MARK: - Window close interception

struct WindowCloseInterceptor: NSViewRepresentable {
    let isDirty: Bool
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
        context.coordinator.onSave  = onSave
    }

    func makeCoordinator() -> Coordinator { Coordinator(isDirty: isDirty, onSave: onSave) }

    class Coordinator: NSObject, NSWindowDelegate {
        var isDirty: Bool
        var onSave:  () -> Void

        init(isDirty: Bool, onSave: @escaping () -> Void) {
            self.isDirty = isDirty
            self.onSave  = onSave
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard isDirty else { return true }
            let alert = NSAlert()
            alert.messageText     = "Unsaved Settings"
            alert.informativeText = "Save your changes before closing?"
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:  onSave(); return true
            case .alertSecondButtonReturn: return true
            default:                       return false
            }
        }
    }
}
