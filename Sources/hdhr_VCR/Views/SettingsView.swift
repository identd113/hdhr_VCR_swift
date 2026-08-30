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
    case sharing       = "Sharing"
    case maintenance   = "Maintenance"
    case about         = "About"

    var icon: String {
        switch self {
        case .general:       return "gear"
        case .recording:     return "record.circle"
        case .guide:         return "tv"
        case .notifications: return "bell.badge"
        case .advanced:      return "terminal"
        case .sharing:       return "globe"
        case .maintenance:   return "wrench.and.screwdriver"
        case .about:         return "info.circle"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow
    @AppStorage("defaultSaveDirectory") private var defaultSaveDirectory: String = ""
    @State private var selection: SettingsCategory? = .general
    @State private var draft: AppConfig = AppConfig()
    // Snapshot of state.config at the moment `draft` was last (re)synced — lets
    // resyncIfUntouched() below prove "draft still equals what it started as" (safe to silently
    // refresh from a since-changed state.config) apart from "draft was actually edited" (must not
    // touch). Without this, draft != state.config is ambiguous between those two very different
    // cases — see the 2026-08-10 ISSUES.md entry this exists to fix.
    @State private var draftBaseline: AppConfig = AppConfig()
    // Shadow drafts for settings that live outside AppConfig — applied only on Save
    @State private var draftSaveDirectory: String      = ""
    @State private var draftLaunchAtLogin: Bool        = false
    @State private var loginItemError: String          = ""
    @State private var terminalGuideOpenError: String  = ""

    private var launchAtLoginRegistered: Bool {
        SMAppService.mainApp.status == .enabled
    }
    @State private var logoTapCount  = 0
    @State private var changelogHeight: CGFloat = 0
    @State private var currentChangelogHeight: CGFloat = 0

    private static let changelogText: String = {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let raw = try? String(contentsOf: url, encoding: .utf8),
              let range = raw.range(of: "\n## ") else { return "" }
        // Strip the file title; return only the version sections
        return String(raw[range.lowerBound...]).trimmingCharacters(in: .newlines)
    }()
    @State private var maintenanceStatus: String = ""
    @State private var maintenanceBusy: Bool = false
    @State private var configIOStatus: String = ""
    @State private var guideRefreshInProgress: Bool = false
    @State private var updateCheckInProgress: Bool = false

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
                        // Stable per-tab handle for UI automation/accessibility tooling — the
                        // window's own title tracks the selected tab's .navigationTitle, so
                        // there's no fixed "Settings" window name to find these rows under, and
                        // a row's position/index shifts if SettingsCategory ever gains a case.
                        .accessibilityIdentifier("settings-tab-\(cat.id.lowercased().replacingOccurrences(of: " ", with: "-"))")
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
                        .accessibilityIdentifier("settings-discard")
                } else if webPortInvalid {
                    Label("Fix the web server port before saving", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Discard") { discardDraft() }
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings-discard")
                } else if isDirty {
                    Text("Unsaved changes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Discard") { discardDraft() }
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings-discard")
                }
                Spacer()
                let canSave = isDirty && !webhookNeedsTest && !webPortInvalid
                Button("Save") { applyAndSave() }
                    .disabled(!canSave)
                    .keyboardShortcut("s", modifiers: .command)
                    .accessibilityIdentifier("settings-save")
                Button("Save & Close") {
                    if canSave { applyAndSave() }
                    NSApp.keyWindow?.close()
                }
                .buttonStyle(.borderedProminent)
                .tint(canSave ? .orange : .accentColor)
                .keyboardShortcut(.defaultAction)
                .disabled(webhookNeedsTest || webPortInvalid)
                .accessibilityIdentifier("settings-save-close")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 560, height: 520)
        .background(WindowCloseInterceptor(isDirty: isDirty, canSave: !webhookNeedsTest && !webPortInvalid, onSave: applyAndSave, onBecomeKey: resyncIfUntouched))
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
        draftBaseline      = state.config
        draftSaveDirectory = defaultSaveDirectory
        draftLaunchAtLogin = launchAtLoginRegistered
        loginItemError = ""
        // Existing saved URL is considered verified (was tested when first saved)
        webhookTestStatus  = state.config.Discord_webhook_url.isEmpty ? .idle : .passed
    }

    private func discardDraft() { resetDrafts() }

    // Called from WindowCloseInterceptor's windowDidBecomeKey — fires on every real refocus of the
    // Settings window, not just its original creation (see WindowCloseInterceptor's doc comment for
    // why .onAppear alone isn't enough for a single-instance Window scene). Only silently pulls in
    // background config changes when `draft` provably hasn't been touched since it was last synced
    // (draft == draftBaseline) — if the user has actually edited something, draft has already
    // diverged from draftBaseline and this is a deliberate no-op so real in-progress edits are never
    // discarded just because the window lost and regained key status.
    private func resyncIfUntouched() {
        guard draft == draftBaseline, draft != state.config else { return }
        resetDrafts()
    }

    private func applyAndSave() {
        let old = state.config
        if draft.Network_interface   != old.Network_interface   { glog("[Settings] NetworkInterface: '\(old.Network_interface)' → '\(draft.Network_interface)'") }
        if draft.Discord_webhook_url != old.Discord_webhook_url { glog("[Settings] DiscordWebhook changed") }
        if draft.Discord_enabled     != old.Discord_enabled     { glog("[Settings] DiscordEnabled: \(old.Discord_enabled) → \(draft.Discord_enabled)") }
        if draft.Hdhr_setup_folder   != old.Hdhr_setup_folder   { glog("[Settings] SaveFolder: '\(old.Hdhr_setup_folder)' → '\(draft.Hdhr_setup_folder)'") }
        if draft.GuideHours          != old.GuideHours          { glog("[Settings] GuideHours: \(old.GuideHours) → \(draft.GuideHours)") }
        if draft.Default_transcode   != old.Default_transcode   { glog("[Settings] DefaultTranscode: '\(old.Default_transcode)' → '\(draft.Default_transcode)'") }
        if draft.Guide_use_xml       != old.Guide_use_xml       { glog("[Settings] GuideUseXml: \(old.Guide_use_xml) → \(draft.Guide_use_xml)") }
        if draft.Appearance_mode     != old.Appearance_mode     { glog("[Settings] AppearanceMode: '\(old.Appearance_mode)' → '\(draft.Appearance_mode)'") }
        let interfaceChanged  = draft.Network_interface   != old.Network_interface
        let webServerChanged  = draft.Web_server_enabled  != old.Web_server_enabled
                             || draft.Web_server_port     != old.Web_server_port
        let formatChanged     = draft.Guide_use_xml       != old.Guide_use_xml
        let dockModeChanged   = draft.Dock_icon_mode      != old.Dock_icon_mode
        state.config = draft
        state.saveConfig()
        // Keep the baseline in lockstep with what was just saved — otherwise resyncIfUntouched()
        // would see draft != draftBaseline forever after any save (since draft was never reset to
        // match) and wrongly treat every future reopen as having a real pending edit to protect.
        draftBaseline = draft
        // Apply an explicit Dock-icon override immediately rather than waiting for next launch —
        // "auto" is left alone here since its own switch-to-accessory point is
        // AppState.confirmLocalNetworkAccessIfNeeded, not a settings save.
        if dockModeChanged {
            switch draft.Dock_icon_mode {
            case "always": NSApplication.shared.setActivationPolicy(.regular)
            case "never":  NSApplication.shared.setActivationPolicy(.accessory)
            default: break
            }
        }
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
        case .sharing:       sharingView
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
                Picker(selection: $draft.Appearance_mode) {
                    Text("Auto").tag("auto")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                } label: {
                    HStack { Text("Appearance"); InfoButton("Controls the look of this app's own windows, and the web guide when it's shown inside one of them (e.g. Add Show). \"Auto\" follows macOS. A browser connecting to Sharing over your network keeps its own independent light/dark choice — this setting has no effect on it.") }
                }
            }

            Section("Guide") {
                Toggle(isOn: $draft.Guide_use_xml) {
                    HStack { Text("Use XMLTV guide format"); InfoButton("XMLTV provides richer genre tags and explicit paid-programming detection. The server controls the window (~2 days); Guide Hours (Guide tab) is ignored. Devices without DeviceAuth always use JSON.") }
                }
                if draft.Guide_use_xml {
                    CaveatBanner(text: "XMLTV ignores the Guide Hours setting (the server always sends ~2 days), and any device without DeviceAuth falls back to JSON regardless of this toggle.",
                                 systemImage: "exclamationmark.triangle")
                        .accessibilityIdentifier("settings-guide-xmltv-warning")
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
                RecordingDefaultsFields(
                    folderLabel: saveDirLabel,
                    onChooseFolder: { chooseFolder() },
                    onResetFolder: draftSaveDirectory.isEmpty ? nil : { draftSaveDirectory = "" },
                    transcode: $draft.Default_transcode,
                    minFreeDiskGB: $draft.Min_disk_free_gb,
                    failThreshold: $draft.Fail_count_setting,
                    idPrefix: "settings-recording"
                )

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

                Toggle(isOn: $draft.Write_metadata_sidecar) {
                    HStack { Text("Write metadata sidecar"); InfoButton("Saves a Kodi-style .nfo file alongside each recording (same folder, same name) with the guide's synopsis, season/episode, air date, and genre — lets a media server show real episode info instead of just the filename.") }
                }

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
                    HStack { Text("Show next \(draft.GuideHours) hours"); InfoButton("How far ahead guide data is fetched. Longer windows let you schedule further out. Capped at 28h — the cloud guide API silently truncates single-call requests beyond ~29h. The guide itself always re-fetches every hour regardless of this setting, to roll the window forward and pick up any schedule changes.") }
                }
                Stepper(value: $draft.Series_scan_retry_hours, in: 1...24) {
                    HStack { Text("Series scan retry: \(draft.Series_scan_retry_hours) hr"); InfoButton("How long to wait before re-checking the guide when a series show has no matching air time yet.") }
                }
                HStack {
                    busyButton("Update Guides Now", isBusy: $guideRefreshInProgress) { await state.refreshAll() }
                        .buttonStyle(.borderedProminent)
                    InfoButton("Force-refreshes guide data for all tuners immediately, without waiting for the auto-refresh window.")
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
                                "Skipped (disk full), skipped (already recorded or not a new episode), tuner conflict, and guide load failures.",
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
                Picker(selection: $draft.Dock_icon_mode) {
                    Text("Auto").tag("auto")
                    Text("Always").tag("always")
                    Text("Never").tag("never")
                } label: {
                    HStack { Text("Dock icon"); InfoButton("\"Auto\" shows a Dock icon only until the app has successfully reached your tuner once — a workaround for a macOS bug where background-only apps can fail to ever receive the Local Network permission prompt — then hides it. \"Always\"/\"Never\" override this permanently.") }
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
                HStack {
                    Button("Export Config…") { exportConfig() }
                    Button("Import Config…") { importConfig() }
                }
                if !configIOStatus.isEmpty {
                    Label(configIOStatus, systemImage: configIOStatus.hasPrefix("Error") ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(configIOStatus.hasPrefix("Error") ? .red : .green)
                        .font(.callout)
                }
            }

            Section("Updates") {
                Toggle(isOn: $draft.Check_for_updates) {
                    HStack { Text("Check for updates automatically"); InfoButton("Once a day, checks GitHub for a newer release and shows a link here and in the menu bar. Read-only — never downloads or installs anything.") }
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

    // MARK: - Sharing

    private var sharingView: some View {
        Form {
            Section("Sharing") {
                Toggle(isOn: $draft.Web_server_enabled) {
                    HStack { Text("Enable Sharing"); InfoButton("Serve the cable guide and recording controls as a web page on your local network — accessible from any browser on any device. Local network only; no authentication. Do not expose this port to the internet.") }
                }
                if draft.Web_server_enabled {
                    LabeledContent {
                        TextField("", value: $draft.Web_server_port, format: .number.grouping(.never))
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

                // hdhr_guide (docs/TUIGuide.md) only works while the web server it's showing
                // above is actually running — same gate as the Access section, so this row can
                // never point someone at a tool that will just fail to connect. Terminal_guide_enabled
                // is a separate sub-switch under that: the binary itself checks it (via
                // /api/guide.json's terminalGuideEnabled field) and refuses to run when off, letting
                // someone share the web guide with the household without also advertising/allowing
                // the terminal client, without needing a second AppState code path.
                let guideURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/hdhr_guide")
                // Checked once per body render (cheap: a single stat call), not cached — deploy.sh
                // always copies this file, so it's only ever missing via an unsupported dev flow
                // (plain `swift build` + direct binary, no .app bundle) or a corrupted install; in
                // either case the button should say so rather than silently no-op on click.
                let guideExists = FileManager.default.fileExists(atPath: guideURL.path)
                Section("Terminal Guide") {
                    Toggle(isOn: $draft.Terminal_guide_enabled) {
                        HStack { Text("Enable Terminal Guide"); InfoButton("Lets the bundled command-line client (path below) connect. On by default. Turning this off has no security effect — the same data is already reachable from any browser on the network whenever Sharing is on — it only hides/disables the terminal client specifically.") }
                    }
                    if draft.Terminal_guide_enabled {
                        Text(guideURL.path)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        if guideExists {
                            Button {
                                terminalGuideOpenError = ""
                                openInTerminal(guideURL) { errorMessage in
                                    terminalGuideOpenError = errorMessage
                                }
                            } label: {
                                Label("Open in Terminal", systemImage: "terminal")
                            }
                            if !terminalGuideOpenError.isEmpty {
                                Label(terminalGuideOpenError, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                            Text("Opens Terminal and starts the guide directly.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Label("Not found at this path — reinstall or rebuild the app.", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
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
        .navigationTitle("Sharing")
    }

    // Opens a new Terminal window and runs `executable` in it directly, via
    // NSWorkspace.open(_:withApplicationAt:configuration:) — not Process()/NSTask spawning
    // `/usr/bin/open` or Terminal itself, and not an AppleScript/Apple Events "do script" command
    // (which would need the com.apple.security.automation.apple-events entitlement plus a
    // user-facing automation-permission prompt). Handing an executable file's URL to Terminal.app
    // through NSWorkspace makes Terminal run it directly in a fresh window (verified live — the
    // same behavior double-clicking a .command file gets), the same LaunchServices-driven
    // mechanism Finder's "New Terminal at Folder" service uses for a folder URL. Since it's
    // LaunchServices doing the launch, not this process forking a child, it needs no new
    // entitlement even under a hypothetical future App Sandbox (docs/MAS_COMPLIANCE.md), unlike
    // this app's existing curl-spawning path for recording, which already is one.
    // `onFailure` surfaces a user-facing message next to the button (sharingView) in addition to
    // the glog() line — a launch failure here used to be visible only in the log file, leaving a
    // click that silently did nothing with no indication why.
    private func openInTerminal(_ executable: URL, onFailure: @escaping (String) -> Void) {
        guard let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            let msg = "Terminal.app not found."
            glog("openInTerminal: \(msg)")
            onFailure(msg)
            return
        }
        NSWorkspace.shared.open([executable], withApplicationAt: terminalURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            glog("openInTerminal: failed to open \(executable.path) in Terminal: \(error)")
            DispatchQueue.main.async { onFailure(error.localizedDescription) }
        }
    }

    // MARK: - Maintenance

    private var maintenanceView: some View {
        Form {
            Section("Setup") {
                maintenanceRow("Reset First-Run Setup",
                               "Run to clear the setup wizard's completed flag and walk through it again, prefilled with your current settings") {
                    state.config.First_run_wizard_shown = false
                    state.saveConfig()
                    openWindow(id: "first-run-wizard")
                    return "First-run setup wizard reopened"
                }
            }
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

    // Shared "swap for a spinner while a plain async action with no result runs" skeleton — the
    // Guide tab's "Update Guides Now" and the About tab's "Check for Updates" buttons both used to
    // hand-copy this same if-busy-then-ProgressView-else-Button block independently. Deliberately
    // separate from maintenanceRow below rather than folding all three into one: maintenanceRow's
    // shape (title + description + a status string shown after) fits a dedicated settings row,
    // not a bare button sitting inline next to a Stepper/InfoButton the way these two do — forcing
    // them through the same helper would need optional title/description/status params that don't
    // apply here, which is more indirection than the two callers actually save. `.buttonStyle`/
    // `.font` etc. are left for the caller to chain onto the result — applying to the ProgressView
    // branch too while busy is harmless (SwiftUI ignores buttonStyle on a non-Button, and
    // ProgressView's macOS `.small` circular style has no visible text for `.font` to affect).
    @ViewBuilder
    private func busyButton(_ label: String, isBusy: Binding<Bool>, action: @escaping () async -> Void) -> some View {
        if isBusy.wrappedValue {
            ProgressView().controlSize(.small)
        } else {
            Button(label) {
                isBusy.wrappedValue = true
                Task { @MainActor in
                    await action()
                    isBusy.wrappedValue = false
                }
            }
        }
    }

    @ViewBuilder
    private func maintenanceRow(_ title: String, _ description: String,
                                 action: @escaping () async throws -> String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            // No explicit spacing — matches every other Text+InfoButton pairing in the app
            // (SettingsView's other rows, RecordingDefaultsFields, FirstRunWizardView), which all
            // rely on HStack's default. This row used to hardcode `spacing: 6`, pulling the
            // Maintenance tab's info icons visibly closer to their labels than everywhere else.
            HStack {
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

    private var vlcInstalled: Bool {
        VLCBridge.locateApp() != nil
    }

    // MARK: - About

    private var aboutView: some View {
        let (sections, _) = Self.parseChangelog(Self.changelogText)
        let currentSection = sections.first
        let olderSections = sections.dropFirst().joined(separator: "\n\n")

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
                            .accessibilityLabel("hdhrVCRplus app icon")
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 80)).foregroundStyle(.secondary)
                            .accessibilityLabel("hdhrVCRplus app icon")
                    }
                }
                .frame(width: 180, height: 180)
                .onTapGesture { logoTapCount += 1 }

                Text("hdhrVCRplus").font(.largeTitle).bold()
                // appVersion is generated by deploy.sh before each build (format: YYMMDD-HHMM)
                Text("Version \(appVersion) — Swift/SwiftUI rewrite")
                    .foregroundStyle(.secondary)

                VStack(spacing: 4) {
                    if let update = state.updateCheckResult {
                        Link(destination: update.releaseURL) {
                            Label("Update available: v\(update.latestVersion)", systemImage: "arrow.down.circle.fill")
                        }
                        .font(.subheadline).bold()
                    } else if let last = state.lastUpdateCheckDate {
                        Text("Up to date (checked \(last, style: .relative) ago)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    busyButton("Check for Updates", isBusy: $updateCheckInProgress) { await state.checkForUpdateOnce() }
                        .font(.caption)
                }

                if state.config.Donation_unlocked {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                        Text("Registered supporter")
                            .font(.subheadline).bold()
                    }
                    if !state.config.Donation_unlock_code.isEmpty {
                        Text("Code: \(state.config.Donation_unlock_code)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } else {
                    Text("Not yet a registered supporter")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

                HStack {
                    Link("View on GitHub",
                         destination: URL(string: "https://github.com/identd113/hdhr_VCR_swift")!)
                        .buttonStyle(.bordered)
                    Spacer()
                }

                Text("Changelog")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let currentSection {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Current Version", systemImage: "checkmark.seal.fill")
                            .font(.caption).bold()
                            .foregroundStyle(.tint)
                        MarkdownView(markdown: currentSection, height: $currentChangelogHeight)
                            .frame(height: max(40, currentChangelogHeight))
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.4), lineWidth: 1))
                }
                if !olderSections.isEmpty {
                    MarkdownView(markdown: olderSections, height: $changelogHeight)
                        .frame(height: max(40, changelogHeight))
                }
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

    /// Splits `text` into sections by "## " headings, keeping only those whose date is
    /// ≤ `appVersion`'s own build date. Sections with no extractable date (e.g. "## Unreleased",
    /// or anything predating version stamping) are always kept. Returns up to `maxSections` kept
    /// sections — each a complete, independently-renderable "## "-prefixed markdown block, in
    /// original (newest-first) order — plus the latest version found (nil if none), so callers can
    /// show an update notice. Capped here (a display concern) rather than in CHANGELOG.md itself or
    /// the version-filtering logic above, which stay untouched — see TODO.md's About-tab entry.
    // Widened from `private` for direct test coverage — same "widen for testability" precedent
    // TODO.md documents for HDHRManager's discovery methods.
    static func parseChangelog(_ text: String, maxSections: Int = 6) -> (sections: [String], latestVersion: String?) {
        let sep = "\n## "
        let parts = text.components(separatedBy: sep)
        guard parts.count > 1 else { return (text.isEmpty ? [] : [text], nil) }
        var latestVersion: String? = nil
        var kept = [parts[0]]   // already "## "-prefixed — it's the head of the original string
        for part in parts.dropFirst() {
            let heading = String(part.prefix(while: { $0 != "\n" }))
            let ver = extractVersion(from: heading)
            if latestVersion == nil { latestVersion = ver }
            if let ver, ver > appVersion { continue }   // newer than this build — omit
            kept.append("## " + part)   // restore the heading marker the split consumed
        }
        return (Array(kept.prefix(maxSections)), latestVersion)
    }

    /// Extracts a "(YYMMDD-HHMM)" version stamp from a changelog heading string.
    // CHANGELOG.md headings (2026-08-12 rewrite) are "vX.Y.Z — YYYY-MM-DD" or bare "Unreleased" —
    // no longer the older "(YYMMDD-HHMM)" parenthetical this used to look for. Extracts the date
    // as "YYMMDD" (dropping the century) so it compares correctly against appVersion's own
    // "YYMMDD-HHMM" build stamp: a date-only prefix always sorts as "not newer" than a same-day
    // build with a time suffix (Swift String comparison treats a string as less than any longer
    // string it's a prefix of), so day-level granularity here is sufficient — this only needs to
    // gate out entries from a clearly *later* calendar date, not order same-day entries by time.
    private static func extractVersion(from heading: String) -> String? {
        guard let dashRange = heading.range(of: " — ") else { return nil }   // "Unreleased" has none
        let digits = heading[dashRange.upperBound...].filter(\.isNumber)
        guard digits.count == 8 else { return nil }   // not a recognizable YYYY-MM-DD date
        return String(digits.dropFirst(2))   // YYYYMMDD -> YYMMDD
    }

    private func exportConfig() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (state.configManager.configPath as NSString).lastPathComponent
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try state.configManager.exportConfig(to: url)
            configIOStatus = "Exported to \(url.lastPathComponent)"
        } catch {
            configIOStatus = "Error: \(error.localizedDescription)"
        }
    }

    private func importConfig() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a previously exported hdhrVCRplus config JSON file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try state.configManager.importConfig(from: url)
            // Deliberately not hot-reloaded into AppState — a currently-recording show's live
            // state (show_recording, discovered devices, tuner occupancy) can't be safely
            // reconciled against an arbitrary imported file mid-session (see importConfig's own
            // comment in ConfigManager.swift). Simplest safe option: write the file, restart to
            // pick it up — matches how a manually-copied-in config file already had to be applied.
            configIOStatus = "Imported — restart hdhrVCRplus for the change to take effect"
        } catch {
            configIOStatus = "Error: \(error.localizedDescription)"
        }
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

/// NSTextView-backed markdown renderer. `NSAttributedString(AttributedString)` bridges inline
/// styling (bold/italic/code/links) automatically but flattens every block onto one run with no
/// paragraph breaks or list markers — this walks each run's `PresentationIntent` to reproduce
/// block structure (headers, paragraph spacing, bulleted/nested lists) the naive bridge drops.
/// Reports its natural height via `height` so the caller can size the frame after the first
/// layout pass.
private struct MarkdownView: NSViewRepresentable {
    let markdown: String
    @Binding var height: CGFloat

    func makeNSView(context: Context) -> NSTextView {
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textColor = .labelColor
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainerInset = .zero
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        return tv
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        textView.textStorage?.setAttributedString(Self.render(markdown))

        DispatchQueue.main.async {
            guard let lm = textView.layoutManager, let tc = textView.textContainer else { return }
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc)
            height = ceil(used.height)
        }
    }

    private static let bulletStep: CGFloat = 16

    private enum BlockKind: Equatable {
        case header(level: Int)
        case listItem(depth: Int, ordered: Bool, ordinal: Int)
        case other
    }

    /// Reads a run's presentation intent to classify which block it belongs to, how deep any
    /// enclosing list nests (a list item's own intent chain includes one .unorderedList/
    /// .orderedList component per enclosing list level), and whether the *immediately* enclosing
    /// list is ordered, so numbered markdown lists (`1. `, `2. `) render with real numbers instead
    /// of bullets. `intent.components` runs `[paragraph, listItem(ordinal), unorderedList|
    /// orderedList, ...ancestors]` (verified directly against Foundation, not documented) — the
    /// first list-kind component encountered after `.listItem` sets `ordinal` is the directly
    /// enclosing list, which `listDepth == 1` (freshly incremented) identifies.
    private static func blockKind(for intent: PresentationIntent?) -> BlockKind {
        guard let intent else { return .other }
        var listDepth = 0
        var ordinal: Int?
        var ordered = false
        for component in intent.components {
            switch component.kind {
            case .header(let level):
                return .header(level: level)
            case .unorderedList:
                listDepth += 1
            case .orderedList:
                listDepth += 1
                if ordinal != nil && listDepth == 1 { ordered = true }
            case .listItem(let n):
                ordinal = n
            default:
                break
            }
        }
        guard let ordinal else { return .other }
        return .listItem(depth: max(listDepth, 1), ordered: ordered, ordinal: ordinal)
    }

    static func render(_ markdown: String) -> NSAttributedString {
        let attributed = (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .full)
        )) ?? AttributedString(markdown)

        let result = NSMutableAttributedString()
        var previousIdentity: Int?
        var previousWasListItem = false
        var pendingParagraphStyle: NSParagraphStyle?

        for run in attributed.runs {
            let intent = run.presentationIntent
            let kind = blockKind(for: intent)
            let isListItem = { if case .listItem = kind { return true } else { return false } }()
            // The innermost component (the run's own paragraph/header/list-item, not its
            // ancestor containers) uniquely identifies which block this run belongs to.
            let identity = intent?.components.first?.identity

            if identity != previousIdentity {
                if result.length > 0 {
                    result.append(NSAttributedString(string: (previousWasListItem && isListItem) ? "\n" : "\n\n"))
                }
                previousIdentity = identity
                previousWasListItem = isListItem

                if case .listItem(let depth, let ordered, let ordinal) = kind {
                    let indent = bulletStep * CGFloat(depth)
                    let style = NSMutableParagraphStyle()
                    style.headIndent = indent
                    style.firstLineHeadIndent = indent - bulletStep
                    style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
                    style.defaultTabInterval = indent
                    let marker = ordered ? "\(ordinal).\t" : "•\t"
                    result.append(NSAttributedString(
                        string: marker,
                        attributes: [.paragraphStyle: style]
                    ))
                    pendingParagraphStyle = style
                } else {
                    pendingParagraphStyle = nil
                }
            }

            let piece = NSMutableAttributedString(
                attributedString: NSAttributedString(AttributedString(attributed[run.range]))
            )
            let pieceRange = NSRange(location: 0, length: piece.length)

            if case .header(let level) = kind {
                let size = NSFont.systemFontSize + max(0, 4 - CGFloat(level))
                piece.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: .semibold), range: pieceRange)
            }
            if let style = pendingParagraphStyle {
                piece.addAttribute(.paragraphStyle, value: style, range: pieceRange)
            }

            result.append(piece)
        }

        // AttributedString(markdown:) leaves plain runs with no .foregroundColor attribute, and
        // NSTextView draws missing color as black rather than falling back to its .textColor —
        // near-invisible black-on-dark in dark mode. .labelColor is AppKit's adaptive system text
        // color (tracks light/dark + Increase Contrast automatically); fill it in only where a
        // run doesn't already specify one, so markdown links (which get their own color from the
        // parser) are left alone.
        let fullRange = NSRange(location: 0, length: result.length)
        result.enumerateAttribute(.foregroundColor, in: fullRange) { value, range, _ in
            if value == nil {
                result.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
            }
        }

        return result
    }
}

// MARK: - Window close interception

struct WindowCloseInterceptor: NSViewRepresentable {
    let isDirty: Bool
    let canSave: Bool
    let onSave: () -> Void
    // Single-instance Window scenes can't duplicate (see MenuContent.swift's open(_:)) — clicking
    // "Settings…" again while the window is already alive just refocuses it via openWindow(id:)
    // rather than recreating the view, so SettingsView's own .onAppear (where drafts are normally
    // synced from state.config) only ever fires once, on true first creation. Any background save
    // that touches state.config between that first open and a later reopen (this app has several —
    // idle loop, tuner probing, etc.) then makes `draft` silently stale, which can surface as a
    // false "Unsaved Settings" prompt on close even though nothing was edited through the UI (see
    // ISSUES.md's 2026-08-10 entry, found via WindowNavigationTests.swift's repeated-reopen test).
    // windowDidBecomeKey fires on every real refocus, not just creation — resyncing there closes
    // the gap .onAppear alone can't cover.
    let onBecomeKey: () -> Void

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
        context.coordinator.onBecomeKey = onBecomeKey
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isDirty: isDirty, canSave: canSave, onSave: onSave, onBecomeKey: onBecomeKey)
    }

    class Coordinator: NSObject, NSWindowDelegate {
        var isDirty: Bool
        var canSave: Bool
        var onSave:  () -> Void
        var onBecomeKey: () -> Void

        init(isDirty: Bool, canSave: Bool, onSave: @escaping () -> Void, onBecomeKey: @escaping () -> Void) {
            self.isDirty = isDirty
            self.canSave = canSave
            self.onSave  = onSave
            self.onBecomeKey = onBecomeKey
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

        func windowDidBecomeKey(_ notification: Notification) {
            onBecomeKey()
        }
    }
}
