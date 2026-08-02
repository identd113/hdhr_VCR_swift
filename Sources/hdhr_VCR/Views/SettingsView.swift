import SwiftUI
import AppKit
import ServiceManagement

private struct InfoButton: View {
    let text: String
    @State private var isPresented = false
    init(_ text: String) { self.text = text }
    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .padding(12)
                .frame(maxWidth: 280)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

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
    @State private var selection: SettingsCategory? = .general
    @State private var draft: AppConfig = AppConfig()
    // Shadow drafts for settings that live outside AppConfig — applied only on Save
    @State private var draftSaveDirectory: String      = ""
    @State private var draftLaunchAtLogin: Bool        = false
    @State private var loginItemError: String          = ""

    private var launchAtLoginRegistered: Bool {
        SMAppService.mainApp.status == .enabled
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
        }
    }

    private func resetDrafts() {
        draft              = state.config
        draftSaveDirectory = defaultSaveDirectory
        draftLaunchAtLogin = launchAtLoginRegistered
        loginItemError = ""
        // Existing saved URL is considered verified (was tested when first saved)
        webhookTestStatus  = state.config.Discord_webhook_url.isEmpty ? .idle : .passed
    }

    private func discardDraft() { resetDrafts() }

    private func applyAndSave() {
        let old = state.config
        if draft.Network_interface   != old.Network_interface   { glog("[Settings] NetworkInterface: '\(old.Network_interface)' → '\(draft.Network_interface)'") }
        if draft.Discord_webhook_url != old.Discord_webhook_url { glog("[Settings] DiscordWebhook changed") }
        if draft.Discord_enabled     != old.Discord_enabled     { glog("[Settings] DiscordEnabled: \(old.Discord_enabled) → \(draft.Discord_enabled)") }
        if draft.Hdhr_setup_folder   != old.Hdhr_setup_folder   { glog("[Settings] SaveFolder: '\(old.Hdhr_setup_folder)' → '\(draft.Hdhr_setup_folder)'") }
        if draft.GuideHours          != old.GuideHours          { glog("[Settings] GuideHours: \(old.GuideHours) → \(draft.GuideHours)") }
        if draft.Default_transcode   != old.Default_transcode   { glog("[Settings] DefaultTranscode: '\(old.Default_transcode)' → '\(draft.Default_transcode)'") }
        if draft.Guide_use_xml       != old.Guide_use_xml       { glog("[Settings] GuideUseXml: \(old.Guide_use_xml) → \(draft.Guide_use_xml)") }
        let interfaceChanged  = draft.Network_interface   != old.Network_interface
        let webServerChanged  = draft.Web_server_enabled  != old.Web_server_enabled
                             || draft.Web_server_port     != old.Web_server_port
        let formatChanged     = draft.Guide_use_xml       != old.Guide_use_xml
        state.config = draft
        state.saveConfig()
        // Commit settings that live outside AppConfig
        defaultSaveDirectory = draftSaveDirectory
        loginItemError = ""
        if draftLaunchAtLogin != launchAtLoginRegistered {
            do {
                if draftLaunchAtLogin { try SMAppService.mainApp.register() }
                else                  { try SMAppService.mainApp.unregister() }
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
        if formatChanged {
            state.guideStore.invalidateAll()
            state.guideByDevice = [:]
            Task { @MainActor in await state.refreshGuide() }
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
        case .webServer:     webServerView
        case .maintenance:   maintenanceView
        case .about:         aboutView
        }
    }

    // MARK: - General

    private var generalView: some View {
        Form {
            Section("System") {
                Toggle(isOn: $draftLaunchAtLogin) {
                    HStack { Text("Launch at Login"); InfoButton("Start hdhr_VCR automatically when you log in, so scheduled recordings are never missed while the app is closed.") }
                }
                if !loginItemError.isEmpty {
                    Label(loginItemError, systemImage: "xmark.circle.fill")
                        .font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle(isOn: $draft.Status_light_blink_enabled) {
                    HStack { Text("Blink menu bar icon"); InfoButton("Blink the menu bar icon's status light while a recording is in progress or a show is starting soon, instead of showing it lit continuously.") }
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
                LabeledContent {
                    HStack {
                        Text(saveDirLabel).foregroundStyle(.secondary)
                        Button("Choose…") { chooseFolder() }
                        if !draftSaveDirectory.isEmpty {
                            Button("Reset") { draftSaveDirectory = "" }.foregroundStyle(.secondary)
                        }
                    }
                } label: {
                    HStack { Text("Default folder"); InfoButton("Where recordings are saved. Falls back to ~/Movies/hdhr_videos when not set.") }
                }

                Picker(selection: $draft.Default_transcode) {
                    Text("None").tag("none")
                    Text("Heavy").tag("heavy")
                    Text("Mobile").tag("mobile")
                    Text("Internet 720").tag("internet720")
                } label: {
                    HStack { Text("Default transcode"); InfoButton("Applied to all new shows. None records the raw MPEG-2 stream — best quality, no re-encoding overhead.") }
                }

                Stepper(value: $draft.Min_disk_free_gb, in: 1...100, step: 1) {
                    HStack { Text("Min free disk: \(draft.Min_disk_free_gb, specifier: "%.0f") GB"); InfoButton("Recordings are skipped when free space on the save drive drops below this threshold.") }
                }

                Stepper(value: $draft.Fail_count_setting, in: 1...10) {
                    HStack { Text("Pause after \(draft.Fail_count_setting) failure(s)"); InfoButton("A show is automatically paused after this many consecutive failures. Restore it via Maintenance → Reactivate Paused Shows.") }
                }

                if vlcInstalled {
                    Toggle(isOn: $draft.Watch_in_VLC) {
                        HStack { Text("Watch in VLC"); InfoButton("Adds Watch in VLC buttons for live and recorded streams throughout the app.") }
                    }
                }

                Toggle(isOn: $draft.Sports_padding_enabled) {
                    HStack { Text("Bonus Time"); InfoButton("Records extra time past the guide end. Sports shows default to on — covers live events that run over.") }
                }
                if draft.Sports_padding_enabled {
                    Stepper("Bonus Time: \(draft.Sports_padding_minutes) min",
                            value: $draft.Sports_padding_minutes, in: 10...60, step: 5)
                }
            }

            Section("Post-Processing") {
                Toggle(isOn: $draft.Series_subfolder_enabled) {
                    HStack { Text("Series subfolders"); InfoButton("Save SeriesID recordings into Title/Season XX/ subfolders. Requires season data from the guide (e.g. S02E04). Date-scheduled shows always use a flat path.") }
                }

                Toggle(isOn: $draft.Skip_recorded_episodes) {
                    HStack { Text("Skip already-recorded episodes"); InfoButton("Before recording a series episode, skip it if a file with the same season/episode (e.g. S02E04) already exists in the show's folder. Advances to the next airing without a failure. Requires Series subfolders and season/episode data from the guide.") }
                }
                .disabled(!draft.Series_subfolder_enabled)

                LabeledContent {
                    HStack {
                        Text(draft.Post_recording_script.isEmpty
                             ? "None"
                             : (draft.Post_recording_script as NSString).lastPathComponent)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { chooseScript() }
                        if !draft.Post_recording_script.isEmpty {
                            Button("Clear") { draft.Post_recording_script = "" }
                                .foregroundStyle(.secondary)
                        }
                    }
                } label: {
                    HStack { Text("Post-recording script"); InfoButton("Shell script run after each successful recording. File path is $1; env vars: HDHR_PATH, HDHR_TITLE, HDHR_CHANNEL, HDHR_TRANSCODE, HDHR_EPISODE, HDHR_DEVICE, HDHR_SERIES, HDHR_FILESIZE. Example scripts are in tools/post_recording/.") }
                }
                if !draft.Post_recording_script.isEmpty {
                    Text("$1 · HDHR_PATH · HDHR_TITLE · HDHR_CHANNEL · HDHR_TRANSCODE · HDHR_EPISODE · HDHR_DEVICE · HDHR_SERIES · HDHR_FILESIZE")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Recording")
    }

    // MARK: - Guide

    private var guideView: some View {
        Form {
            Section("Fetch") {
                // Capped at 28, not the old 48: GuideStore.load() makes a single API call, and the
                // cloud guide.php endpoint silently truncates any Duration beyond ~29h regardless
                // of what's requested (confirmed in docs/HDHRFindings.md) — a higher setting would
                // look accepted but never actually fetch further out, with no error surfaced.
                Stepper(value: $draft.GuideHours, in: 1...28) {
                    HStack { Text("Show next \(draft.GuideHours) hours"); InfoButton("How far ahead guide data is fetched and how long before it auto-refreshes. Longer windows let you schedule further out. Capped at 28h — the cloud guide API silently truncates single-call requests beyond ~29h.") }
                }
                Stepper(value: $draft.Series_scan_retry_hours, in: 1...24) {
                    HStack { Text("Series scan retry: \(draft.Series_scan_retry_hours) hr"); InfoButton("How long to wait before re-checking the guide when a series show has no matching air time yet.") }
                }
                HStack {
                    Button("Update Guides Now") { state.refreshAll() }
                        .buttonStyle(.borderedProminent)
                    InfoButton("Force-refreshes guide data for all tuners immediately, without waiting for the auto-refresh window.")
                }
            }

            Section("Format") {
                Toggle(isOn: $draft.Guide_use_xml) {
                    HStack { Text("Use XMLTV guide format"); InfoButton("XMLTV provides richer genre tags and explicit paid-programming detection. The server controls the window (~2 days); Guide Hours is ignored. Devices without DeviceAuth always use JSON.") }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Guide")
    }

    // MARK: - Notifications

    private var notificationsView: some View {
        Form {
            Section("Notifications") {
                Stepper(value: Binding(get: { Int(draft.Notify_upnext) }, set: { draft.Notify_upnext = Double($0) }), in: 5...120, step: 5) {
                    HStack { Text("Up Next: \(Int(draft.Notify_upnext)) min before"); InfoButton("Early heads-up notification sent this many minutes before a show's scheduled start time.") }
                }
                Stepper(value: Binding(get: { Int(draft.Notify_recording) }, set: { draft.Notify_recording = Double($0) }), in: 1...60) {
                    HStack { Text("Recording alert: \(Int(draft.Notify_recording)) min before"); InfoButton("A second, closer notification just before recording begins — set lower than Up Next so both fire in order.") }
                }
                if draft.Notify_recording >= draft.Notify_upnext {
                    Label("Recording alert fires at or after Up Next — the Up Next notification won't appear first.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Discord") {
                Toggle(isOn: $draft.Discord_enabled) {
                    HStack { Text("Enable Discord notifications"); InfoButton("Post recording status updates to a Discord channel via webhook. Requires a webhook URL from your server's channel settings.") }
                }

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
                                // Capture the URL under test; if the field changes before the
                                // async check returns, discard the stale result instead of
                                // overwriting whatever status now describes the *new* URL (e.g.
                                // the .untested the onChange handler above just set) — otherwise
                                // an old test's "passed" could mark a since-edited, never-tested
                                // URL as verified, defeating the save-gate this status drives.
                                let testingURL = draft.Discord_webhook_url
                                webhookTestStatus = .testing
                                Task {
                                    let ok = await state.checkWebhookURL(testingURL)
                                    guard draft.Discord_webhook_url == testingURL else { return }
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
                // Grouped into 4 clusters instead of 12 flat toggles — each cluster's Toggle
                // reflects "all its events on" and flips every member field together. The
                // underlying Discord_on_* fields stay independent (fireDiscordCard checks each
                // one on its own); this only reduces how many controls Settings exposes.
                Section("Notify when…") {
                    groupToggle("Lifecycle events",
                                "Recording started, completed, failed, or paused.",
                                fields: [\.Discord_on_start, \.Discord_on_complete, \.Discord_on_failed, \.Discord_on_paused])
                    groupToggle("Reminders",
                                "Up Next and Recording Soon heads-up notifications.",
                                fields: [\.Discord_on_upnext, \.Discord_on_soon])
                    groupToggle("Problems",
                                "Skipped (disk full), skipped (already recorded), tuner conflict, and guide load failures.",
                                fields: [\.Discord_on_skipped, \.Discord_on_duplicate, \.Discord_on_conflict, \.Discord_on_guide_error])
                    groupToggle("Other",
                                "Show added, and progress updates every 5 minutes while recording.",
                                fields: [\.Discord_on_show_added, \.Discord_on_progress])
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Notifications")
    }

    /// A single Toggle that reads/writes several AppConfig bool fields together — "on" only
    /// when every field in the group is on; toggling sets them all to the new value at once.
    private func groupToggle(_ label: String, _ info: String, fields: [WritableKeyPath<AppConfig, Bool>]) -> some View {
        Toggle(isOn: Binding(
            get: { fields.allSatisfy { draft[keyPath: $0] } },
            set: { newValue in for f in fields { draft[keyPath: f] = newValue } }
        )) {
            HStack { Text(label); InfoButton(info) }
        }
    }

    // MARK: - Advanced

    private var advancedView: some View {
        Form {
            Section("Network") {
                Picker(selection: $draft.Network_interface) {
                    Text("Auto").tag("")
                    ForEach(availableNetworkInterfaces()) { iface in
                        Text(iface.displayLabel).tag(iface.name)
                    }
                } label: {
                    HStack { Text("Discovery & recording interface"); InfoButton("Binds UDP discovery and curl recordings to a specific interface. VPN tunnels are listed (utun*, tun*, cscotun*, gpd*, etc.) — use one if your HDHomeRun is on a remote network reachable via VPN.") }
                }
            }

            Section("Logging") {
                Button("Show App Log in Console") {
                    // Console.app has a launch constraint that SIGKILLs it ("Code Signature
                    // Invalid") if exec'd directly via Process() — must go through LaunchServices.
                    // Pass --predicate so Console opens pre-filtered to this app's subsystem.
                    let config = NSWorkspace.OpenConfiguration()
                    config.arguments = ["--predicate", "subsystem == \"\(Bundle.main.bundleIdentifier ?? "com.hdhr.vcrplus")\""]
                    NSWorkspace.shared.openApplication(
                        at: URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"),
                        configuration: config
                    )
                }
                Text("Filter: subsystem == \"\(Bundle.main.bundleIdentifier ?? "com.hdhr.vcrplus")\"")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)

                Toggle(isOn: $draft.Verbose_curl) {
                    HStack { Text("Verbose curl logging"); InfoButton("Log full curl request/response headers for each recording. Use when diagnosing why a recording fails to start.") }
                }
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
                Text(state.configManager.configPath)
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Button("Show config in Finder") {
                    NSWorkspace.shared.selectFile(state.configManager.configPath,
                                                  inFileViewerRootedAtPath: "")
                }
            }

            Section("Signal Quality") {
                Toggle(isOn: $draft.Signal_quality_enabled) {
                    HStack { Text("Show signal bars in guide"); InfoButton("Display signal strength bars in the guide grid and Watch Now view. Signal data is always collected during recordings regardless of this toggle.") }
                }
                Toggle(isOn: $draft.Signal_quality_alert_notify) {
                    HStack { Text("Send alerts on signal dropout"); InfoButton("Send a notification and Discord message when a recording's signal drops below 30% for ~20 seconds. Logging is always active.") }
                }
            }

            if draft.Signal_quality_enabled {
                Section("Signal Strength Scan") {
                    Text("Briefly tunes each channel to measure signal quality. Results are stored and shown as bars in the guide.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let progress = state.signalScanProgress {
                        Label(progress, systemImage: "antenna.radiowaves.left.and.right")
                            .font(.caption)
                        Button("Cancel Scan") { state.cancelSignalScan() }
                            .foregroundStyle(.red)
                    } else {
                        ForEach(state.devices) { device in
                            // force=true: manual scan always re-measures, even channels with fresh data
                            Button("Measure Signal: \(device.DeviceID)") { state.startSignalScan(force: true) }
                        }
                    }
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
                Toggle(isOn: $draft.Web_server_enabled) {
                    HStack { Text("Enable Web Server"); InfoButton("Serve the cable guide and recording controls as a web page on your local network — accessible from any browser on any device. Local network only; no authentication. Do not expose this port to the internet.") }
                }
                if draft.Web_server_enabled {
                    LabeledContent {
                        TextField("1980", value: $draft.Web_server_port, format: .number.grouping(.never))
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                    } label: {
                        HStack { Text("Port"); InfoButton("Port number (1025–65534). macOS requires root for ports below 1024. Default: 1980. Changes and mDNS registration update immediately on Save.") }
                    }
                    if draft.Web_server_port < 1025 || draft.Web_server_port > 65534 {
                        Label("Port must be between 1025 and 65534", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            if state.config.Web_server_enabled && state.webServerRunning {
                let ip: String = {
                    let ifaces = availableNetworkInterfaces()
                    // Explicit interface selected — use its IP
                    if !state.config.Network_interface.isEmpty,
                       let match = ifaces.first(where: { $0.name == state.config.Network_interface }) {
                        return match.ip
                    }
                    // Auto — prefer physical Ethernet/Wi-Fi (en*, wlan*), then any non-VPN
                    return ifaces.first(where: { $0.name.hasPrefix("en") || $0.name.hasPrefix("wlan") })?.ip
                        ?? ifaces.first(where: { !isPointToPointInterface($0.name) })?.ip
                        ?? "localhost"
                }()
                let urlStr = "http://\(ip):\(state.config.Web_server_port)"
                Section("Access") {
                    HStack {
                        Text(urlStr)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Link("Open", destination: URL(string: urlStr)!)
                    }
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
                maintenanceRow("Reactivate Paused Shows",
                               "Run after fixing what caused failures — restores all shows paused by repeated errors") {
                    let count = state.inactiveShows.count
                    state.reactivatePausedShows()
                    return count > 0 ? "\(count) show(s) reactivated" : "No paused shows"
                }
                maintenanceRow("Rescan Series",
                               "Run if a series show isn't scheduling — re-checks the guide for its next air time") {
                    let count = state.shows.filter { $0.show_active && !$0.show_paused && !$0.show_recording && $0.show_use_seriesid }.count
                    await state.rescheduleAllSeries()
                    return "\(count) series show(s) rescheduled"
                }
                maintenanceRow("Reset Fail Counts",
                               "Run to clear error counters after fixing an issue, without unpausing shows") {
                    let total = state.shows.count
                    state.resetAllFailCounts()
                    return "Cleared fail counts on \(total) show(s)"
                }
                maintenanceRow("Organize Series Recordings",
                               "Run after enabling Series Subfolders to sort existing flat recordings into Title/Season XX/ folders") {
                    state.organizeSeriesRecordings()
                }
            }
            Section("Guide & Devices") {
                maintenanceRow("Rediscover Devices",
                               "Run if a tuner is missing from the device bar, or after a network or router change") {
                    await state.rediscoverDevices()
                    return "\(state.devices.count) device(s) found"
                }
                maintenanceRow("Refresh Guide",
                               "Run if guide data looks stale or wrong — forces a full re-fetch from all tuners") {
                    await state.refreshGuide()
                    let ch = state.guideByDevice.values.flatMap { $0 }.count
                    return "Guide refreshed — \(ch) channel(s) loaded"
                }
                maintenanceRow("Clear Guide Cache",
                               "Run if Refresh Guide doesn't fix stale data, or after switching between JSON and XMLTV") {
                    state.guideStore.invalidateAll()
                    state.guideByDevice = [:]
                    return "Guide cache cleared"
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
            HStack(spacing: 6) {
                Text(title).fontWeight(.medium)
                InfoButton(description)
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
        VLCBridge.locateApp() != nil
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
            HStack(spacing: 6) {
                Text(name).fontWeight(.medium)
                InfoButton(description)
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
                    Link("View on GitHub",
                         destination: URL(string: "https://github.com/identd113/hdhr_VCR_swift")!)
                        .buttonStyle(.bordered)
                    Spacer()
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

    private func chooseScript() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a script or executable to run after each recording completes"
        panel.prompt = "Select"
        // Default to the example scripts folder next to the app bundle (repo layout)
        let examplesDir = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("tools/post_recording")
        if FileManager.default.fileExists(atPath: examplesDir.path) {
            panel.directoryURL = examplesDir
        }
        if panel.runModal() == .OK, let url = panel.url { draft.Post_recording_script = url.path }
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
            switch promptUnsavedChanges(
                title: "Unsaved Settings", canSave: canSave,
                savePrompt: "Save your changes before closing?",
                blockedPrompt: "Settings can't be saved yet — fix the validation error first. Discard changes?"
            ) {
            case .save:    onSave(); return true
            case .discard: return true
            case .cancel:  return false
            }
        }
    }
}
