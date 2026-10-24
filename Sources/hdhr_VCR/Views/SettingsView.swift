import SwiftUI
import AppKit
import ServiceManagement

enum SettingsCategory: String, CaseIterable, Identifiable {
    var id: String { rawValue }
    case general       = "General"
    case recording     = "Recording"
    case overTheAir    = "Over the Air"
    case guide         = "Guide"
    case notifications = "Notifications"
    case advanced      = "Advanced"
    // The tab is "Sharing": an umbrella over the web server ("Web LAN" section), Terminal Guide and Recording FEED.
    case sharing       = "Sharing"
    case maintenance   = "Maintenance"
    #if DEBUG
    // Developer tools (guide format switch, purges): compiled out of release builds entirely.
    case developer     = "Developer"
    #endif
    case about         = "About"

    var icon: String {
        switch self {
        case .general:       return "gear"
        case .recording:     return "record.circle"
        case .guide:         return "tv"
        case .overTheAir:    return "dot.radiowaves.left.and.right"
        case .notifications: return "bell.badge"
        case .advanced:      return "terminal"
        case .sharing:       return "globe"
        case .maintenance:   return "wrench.and.screwdriver"
        #if DEBUG
        case .developer:     return "hammer"
        #endif
        case .about:         return "info.circle"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow
    @AppStorage("defaultSaveDirectory") private var defaultSaveDirectory: String = ""
    @State private var selection: SettingsCategory? = .general
    @State private var signalScanDeviceID: String = ""      // Signal Strength Scan picker; "" = all tuners
    @State private var storageSizes = StorageSizes()
    @State private var aboutStoryExpanded = false      // About → The story (collapsed by default)
    @State private var aboutOlderExpanded = false      // About → Earlier versions (collapsed by default)
    // Maintenance → Guides & Devices: which actions are ticked (remembered between visits) and the run state.
    @AppStorage("maintenanceRunDiscover") private var runDiscover = false
    @AppStorage("maintenanceRunLineups") private var runLineups = false
    @AppStorage("maintenanceRunGuide") private var runGuide = false
    @AppStorage("maintenanceRunChannelScan") private var runChannelScan = false
    @AppStorage("maintenanceRunSeries") private var runSeries = false
    @State private var guidesDevicesRunning = false
    @State private var guidesDevicesStatus = ""
    @State private var organizeStatus = ""          // result line of Recording → Series → Organize Existing Recordings
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

    // Cached: SMAppService.status, the interface walk, the VLC lookup and the helper stat are all
    // syscalls, and SettingsView re-renders on every AppState publish (isDirty alone read the login
    // status each time). Refreshed in refreshSystemCaches() — onAppear, window refocus, after Save.
    @State private var launchAtLoginRegistered: Bool = SettingsView.readLaunchAtLoginRegistered()
    @State private var netInterfaces: [NetworkInterfaceInfo] = []
    @State private var vlcInstalled: Bool = false
    @State private var terminalGuideExists: Bool = false
    @State private var settingsWindow: NSWindow?

    private static func readLaunchAtLoginRegistered() -> Bool {
        // .requiresApproval = register() succeeded and macOS is waiting on the user (System Settings
        // → Login Items); counting it as not-registered left the draft permanently "dirty".
        let s = SMAppService.mainApp.status
        return s == .enabled || s == .requiresApproval
    }

    private static var terminalGuideURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/hdhr_guide")
    }

    private func refreshSystemCaches() {
        launchAtLoginRegistered = Self.readLaunchAtLoginRegistered()
        netInterfaces = availableNetworkInterfaces()
        vlcInstalled = VLCBridge.locateApp() != nil
        terminalGuideExists = FileManager.default.fileExists(atPath: Self.terminalGuideURL.path)
    }
    @State private var changelogHeight: CGFloat = 0
    @State private var currentChangelogHeight: CGFloat = 0

    private static let changelogText: String = {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let raw = try? String(contentsOf: url, encoding: .utf8),
              let range = raw.range(of: "\n## ") else { return "" }
        // Strip the file title; return only the version sections
        return String(raw[range.lowerBound...]).trimmingCharacters(in: .newlines)
    }()
    // Computed once (like changelogText above), not inside aboutView's computed-property body —
    // aboutView re-runs on every SwiftUI re-render of the whole SettingsView (this observes
    // @EnvironmentObject state, so any @Published AppState mutation while the About tab happens to
    // be open re-triggers it: idle-loop ticks, tuner-status polls, guide refreshes, signal-scan
    // progress, all firing continuously in this 24/7 menu-bar app), yet changelogText/its parsed
    // sections never change after launch (found in code review 2026-09-25).
    private static let parsedChangelogSections: [String] = parseChangelog(changelogText).sections
    @State private var maintenanceStatus: String = ""
    @State private var maintenanceBusy: Bool = false     // Developer tab's Purges Run button
    @State private var busyRow: String?                  // title of the maintenance row currently running
    @State private var purgeMemory = true
    @State private var purgeSDCache = false
    @State private var purgeAirGuide = false
    @State private var purgeAirLineup = false
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
        // Computed once per render (each reads draft/state.config comparisons).
        let dirty = isDirty
        let needsTest = webhookNeedsTest
        let portBad = webPortInvalid
        let savesPaused = state.configManager.savesSuppressedAfterImport
        return VStack(spacing: 0) {
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
                if savesPaused {
                    // After Import Config every save is suppressed until restart (ConfigManager) — say so here
                    // instead of letting Save look like it worked.
                    Label("Import pending — restart to apply; saving is paused", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("settings-import-pending")
                } else if needsTest && !portBad {
                    Label("Discord webhook not tested yet (you can still save)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Show") { selection = .notifications }
                        .controlSize(.small)
                        .accessibilityIdentifier("settings-show-webhook")
                    Button("Discard") { discardDraft() }
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings-discard")
                } else if portBad {
                    Label("Fix the web server port before saving", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Show") { selection = .sharing }
                        .controlSize(.small)
                        .accessibilityIdentifier("settings-show-port")
                    Button("Discard") { discardDraft() }
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings-discard")
                } else if dirty {
                    Text("Unsaved changes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Discard") { discardDraft() }
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings-discard")
                }
                if Self.resetKeys(for: selection ?? .general) != nil {
                    Button("Reset This Tab to Defaults") { resetCurrentTab() }
                        .controlSize(.small)
                        .disabled(currentTabIsAtDefaults)
                        .help("Puts every setting on this tab back to its default. Nothing changes until you press Save.")
                        .accessibilityIdentifier("settings-reset-tab")
                }
                Spacer()
                let canSave = dirty && !portBad && !savesPaused
                Button("Save") { applyAndSave() }
                    .disabled(!canSave)
                    .keyboardShortcut("s", modifiers: .command)
                    .accessibilityIdentifier("settings-save")
                Button("Save & Close") {
                    if canSave { applyAndSave() }
                    // This window, not NSApp.keyWindow — a sheet (open/save panel, alert) may be key.
                    (settingsWindow ?? NSApp.keyWindow)?.close()
                }
                .buttonStyle(.borderedProminent)
                .tint(canSave ? .orange : .accentColor)
                .keyboardShortcut(.defaultAction)
                .disabled(portBad || savesPaused)
                .accessibilityIdentifier("settings-save-close")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 560, idealWidth: 560, maxWidth: .infinity,
               minHeight: 420, idealHeight: 520, maxHeight: .infinity)
        // Remember the user's chosen size across opens and restarts.
        .background(WindowAction(trigger: true) { $0.setFrameAutosaveName("SettingsWindow") })
        .onChange(of: selection) { maintenanceStatus = ""; if selection == .maintenance { refreshStorageSizes() } }   // a result from one tab shouldn't linger on another
        .background(WindowCloseInterceptor(isDirty: dirty, canSave: !portBad && !savesPaused, onSave: applyAndSave,
                                           onBecomeKey: { refreshSystemCaches(); resyncIfUntouched() },
                                           onWindow: { settingsWindow = $0 }))
        .onAppear {
            refreshSystemCaches()
            resetDrafts()
            // A saved interface that isn't connected right now (VPN down, adapter unplugged) is NO LONGER
            // cleared here: merely opening Settings used to wipe the user's choice from the saved config,
            // so it was gone when the VPN came back. The app instead falls back to Auto at the point of
            // use (AppState.effectiveNetworkInterface — discovery, recordings, FEED pulls) and the saved
            // name is kept until the user changes it (2026-10-05 triage T09).
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

    // MARK: reset a tab to its defaults

    /// The AppConfig fields each tab edits (the names in the saved JSON), nil for tabs with nothing to reset. Resetting changes the
    /// draft only: nothing is saved until Save, and Discard puts everything back.
    static func resetKeys(for tab: SettingsCategory) -> [String]? {
        switch tab {
        case .general:       return ["Appearance_mode", "Show_launch_splash", "Status_light_blink_enabled"]
        case .recording:     return ["Default_transcode", "Fail_count_setting", "Min_disk_free_gb", "Post_recording_script", "Series_subfolder_enabled",
                                     "Skip_recorded_episodes", "Sports_padding_minutes", "TimeMachine_exclude_mode", "Write_metadata_sidecar", "Hdhr_setup_folder"]
        case .guide:         return ["Guide_refresh_interval_divisor", "Guide_use_xml", "OTA_always_use"]
        case .overTheAir:    return ["OTA_enabled", "OTA_lineup_hour"]
        case .notifications: return ["Discord_enabled", "Discord_webhook_url", "Notify_upnext", "Discord_on_start", "Discord_on_complete",
                                     "Discord_on_failed", "Discord_on_paused", "Discord_on_skipped", "Discord_on_duplicate", "Discord_on_conflict",
                                     "Discord_on_guide_error", "Discord_on_upnext", "Discord_on_soon", "Discord_on_show_added"]
        case .advanced:      return ["Notify_recording", "Check_for_updates", "Dock_icon_mode", "Network_interface", "Signal_quality_alert_notify", "Signal_quality_enabled"]
        case .sharing:       return ["Home_assistant_status_enabled", "Terminal_guide_enabled", "Virtual_tuner_relay_default_transcode", "Virtual_tuner_relay_enabled",
                                     "Web_server_enabled", "Web_server_port", "Web_streaming_enabled"]
        default:             return nil
        }
    }

    private func jsonObject<T: Encodable>(_ value: T) -> [String: Any] {
        ((try? JSONEncoder().encode(value)).flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:]
    }

    /// True when every setting on the current tab already equals its default (the button is dimmed then).
    private var currentTabIsAtDefaults: Bool {
        let tab = selection ?? .general
        guard let keys = Self.resetKeys(for: tab) else { return true }
        let current = jsonObject(draft), defaults = jsonObject(AppConfig())
        let configSame = keys.allSatisfy { key in
            let a = (current[key] as AnyObject?) ?? NSNull(), b = (defaults[key] as AnyObject?) ?? NSNull()
            return a.isEqual(b)
        }
        let extrasSame = (tab != .general || !draftLaunchAtLogin) && (tab != .recording || draftSaveDirectory.isEmpty)
        return configSame && extrasSame
    }

    private func resetCurrentTab() {
        let tab = selection ?? .general
        guard let keys = Self.resetKeys(for: tab) else { return }
        var current = jsonObject(draft)
        let defaults = jsonObject(AppConfig())
        for key in keys { current[key] = defaults[key] }
        if let data = try? JSONSerialization.data(withJSONObject: current), let reset = try? JSONDecoder().decode(AppConfig.self, from: data) { draft = reset }
        if tab == .general { draftLaunchAtLogin = false }
        if tab == .recording { draftSaveDirectory = "" }
        if tab == .notifications { webhookTestStatus = .idle }
        glog("[Settings] reset the \(tab.rawValue) tab to its defaults (not saved yet)")
    }

    /// Short hint shown beside a button that acts on SAVED values while there are unsaved edits (the button is disabled).
    @ViewBuilder private var saveFirstHint: some View {
        if isDirty {
            Text("Save first").font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("settings-save-first-hint")
        }
    }

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
        if draft.Guide_refresh_interval_divisor != old.Guide_refresh_interval_divisor {
            glog("[Settings] GuideRefreshIntervalDivisor: 1/\(old.Guide_refresh_interval_divisor) → 1/\(draft.Guide_refresh_interval_divisor)")
        }
        if draft.Default_transcode   != old.Default_transcode   { glog("[Settings] DefaultTranscode: '\(old.Default_transcode)' → '\(draft.Default_transcode)'") }
        if draft.Virtual_tuner_relay_default_transcode != old.Virtual_tuner_relay_default_transcode {
            glog("[Settings] RelayDefaultTranscode: '\(old.Virtual_tuner_relay_default_transcode)' → '\(draft.Virtual_tuner_relay_default_transcode)'")
        }
        if draft.Guide_use_xml       != old.Guide_use_xml       { glog("[Settings] GuideUseXml: \(old.Guide_use_xml) → \(draft.Guide_use_xml)") }
        if draft.OTA_enabled         != old.OTA_enabled         { glog("[Settings] OTAEnabled: \(old.OTA_enabled) → \(draft.OTA_enabled)") }
        if draft.OTA_always_use      != old.OTA_always_use      { glog("[Settings] OTAAlwaysUse: \(old.OTA_always_use) → \(draft.OTA_always_use)") }
        if draft.OTA_lineup_hour     != old.OTA_lineup_hour     { glog("[Settings] OTALineupHour: \(old.OTA_lineup_hour) → \(draft.OTA_lineup_hour)") }
        if draft.Appearance_mode     != old.Appearance_mode     { glog("[Settings] AppearanceMode: '\(old.Appearance_mode)' → '\(draft.Appearance_mode)'") }
        let interfaceChanged  = draft.Network_interface   != old.Network_interface
        let webServerChanged  = draft.Web_server_enabled  != old.Web_server_enabled
                             || draft.Web_server_port     != old.Web_server_port
        let formatChanged     = draft.Guide_use_xml       != old.Guide_use_xml
        let airSourceChanged  = draft.OTA_enabled != old.OTA_enabled || (draft.OTA_enabled && draft.OTA_always_use != old.OTA_always_use)
        let dockModeChanged   = draft.Dock_icon_mode      != old.Dock_icon_mode
        // WebServer.buildGuideJSON caches its skip-already-recorded on-disk scan
        // (cachedRecordedTagsByShow, warmed by buildGuideGridHTML) rather than repeating it on
        // every /api/guide.json poll — see that property's own comment. Toggling either setting
        // changes what buildGuideJSON's willSkip should compute from, but the cache itself only
        // refreshes on a guide-changing event/periodic refresh, none of which this save triggers on
        // its own — without an explicit rebuild here, hdhr_guide (TUI) could keep showing/omitting
        // the "already recorded" skip badge based on the pre-toggle state for up to an hour.
        let skipConfigChanged = draft.Skip_recorded_episodes  != old.Skip_recorded_episodes
                             || draft.Series_subfolder_enabled != old.Series_subfolder_enabled
        let relayEnabledChanged = draft.Virtual_tuner_relay_enabled != old.Virtual_tuner_relay_enabled
        // Apply only what was edited in this window onto the live config — saving the whole draft
        // reverted anything changed elsewhere since it loaded (Donation unlock, the embedded
        // guide's appearance bridge, Local_network_confirmed…; 2026-10-01 review #22).
        let merged = codableApplyingEdits(live: state.config, original: draftBaseline, edited: draft) ?? draft
        state.config = merged
        state.saveConfig()
        // Keep the baseline in lockstep with what was just saved — otherwise resyncIfUntouched()
        // would see draft != draftBaseline forever after any save (since draft was never reset to
        // match) and wrongly treat every future reopen as having a real pending edit to protect.
        draft = merged
        draftBaseline = merged
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
            launchAtLoginRegistered = Self.readLaunchAtLoginRegistered()
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
        // Re-evaluate immediately rather than waiting for the next recording start/stop — toggling
        // this off while a show happens to be recording should tear the relay down right away, not
        // leave it advertised until that recording ends.
        if relayEnabledChanged { state.updateVirtualTunerPresence() }
        if airSourceChanged && !formatChanged && !interfaceChanged { Task { @MainActor in await state.airSourceChanged() } }
        if formatChanged {
            state.guideStore.invalidateAll()
            state.guideByDevice = [:]
            Task { @MainActor in await state.refreshGuide() }
        }
        // formatChanged already forces a full refetch-and-rebuild above, which naturally rewarms
        // this cache too — only need the lightweight local rebuild here when that didn't already fire.
        if skipConfigChanged && !formatChanged && !interfaceChanged {
            state.webServer.refreshPageAndBroadcastGuideChange(type: "guide_refreshed", state: state)
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selection ?? .general {
        case .general:       generalView
        case .recording:     recordingView
        case .guide:         guideView
        case .overTheAir:    overTheAirView
        case .notifications: notificationsView
        case .advanced:      advancedView
        case .sharing:       sharingView
        case .maintenance:   maintenanceView
        #if DEBUG
        case .developer:     developerView
        #endif
        case .about:         aboutView
        }
    }

    // MARK: - General

    private var generalView: some View {
        Form {
            Section("System") {
                Toggle(isOn: $draftLaunchAtLogin) {
                    HStack { Text("Launch at Login"); InfoButton("Start hdhr_VCR automatically when you log in, so scheduled recordings are never missed while the app is closed.", about: "Launch at Login") }
                }
                .accessibilityIdentifier("settings-launch-at-login")
                if !loginItemError.isEmpty {
                    Label(loginItemError, systemImage: "xmark.circle.fill")
                        .font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle(isOn: $draft.Status_light_blink_enabled) {
                    HStack { Text("Blink menu bar icon"); InfoButton("Blink the menu bar icon's status light while a recording is in progress or a show is starting soon, instead of showing it lit continuously.", about: "Blink menu bar icon") }
                }
                .accessibilityIdentifier("settings-blink-icon")
                Toggle(isOn: $draft.Show_launch_splash) {
                    HStack { Text("Show launch splash"); InfoButton("Show a brief logo screen when the app starts, while it finds your tuner and loads the guide. It ends by pointing at the menu bar icon — or, on a first run, by flowing into the setup wizard.", about: "Show launch splash") }
                }
                .accessibilityIdentifier("settings-launch-splash")
                Picker(selection: $draft.Appearance_mode) {
                    Text("Auto").tag("auto")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                } label: {
                    HStack { Text("Appearance"); InfoButton("Controls the look of this app's own windows, and the web guide when it's shown inside one of them (e.g. Add Show). \"Auto\" follows macOS. A browser connecting to Web LAN over your network keeps its own independent light/dark choice — this setting has no effect on it.", about: "Appearance") }
                }
            }

        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }

    // MARK: - Recording

    private var recordingView: some View {
        Form {
            Section("Defaults") {
                RecordingDefaultsFields(
                    folderLabel: saveDirLabel,
                    onChooseFolder: { chooseFolder() },
                    onResetFolder: draftSaveDirectory.isEmpty ? nil : { draftSaveDirectory = "" },
                    transcode: $draft.Default_transcode,
                    minFreeDiskGB: $draft.Min_disk_free_gb,
                    failThreshold: $draft.Fail_count_setting,
                    timeMachineExcludeMode: $draft.TimeMachine_exclude_mode,
                    idPrefix: "settings-recording",
                    folderPath: draftSaveDirectory.isEmpty ? state.config.Hdhr_setup_folder : draftSaveDirectory
                )

                Stepper(value: $draft.Sports_padding_minutes, in: 10...60, step: 5) {
                    HStack { Text("Bonus Time: \(draft.Sports_padding_minutes) min past guide end"); InfoButton("How long a recording runs past the guide's listed end when its show has Bonus Time on. Each show chooses that itself; sports shows start with it on.", about: "Bonus Time") }
                }
            }

            Section("Series") {
                Toggle(isOn: Binding(get: { draft.Series_subfolder_enabled },
                                     set: { draft.Series_subfolder_enabled = $0; draft.Skip_recorded_episodes = $0 })) {
                    HStack { Text("Organize series and skip duplicates"); InfoButton("Save SeriesID recordings into Title/Season XX/ subfolders, and skip an episode when a file with the same season and episode (e.g. S02E04) is already in the show's folder; the show then moves on to the next airing without a failure. Needs season data from the guide. Date-scheduled shows always use a flat path.", about: "Organize series and skip duplicates") }
                }
                .accessibilityIdentifier("settings-series-organize")
                if draft.Series_subfolder_enabled {
                    // Sorts recordings made before the switch was on into Title/Season XX/ folders. Acts on the saved setting, so it waits for Save.
                    HStack {
                        Button("Organize Existing Recordings") { organizeStatus = state.organizeSeriesRecordings() }
                            .disabled(isDirty)
                            .accessibilityIdentifier("settings-series-organize-now")
                        InfoButton("Sorts series recordings you already have into Title/Season XX/ folders. New recordings are organized as they are made.", about: "Organize Existing Recordings")
                        saveFirstHint
                    }
                    if !organizeStatus.isEmpty {
                        Text(organizeStatus).font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("settings-series-organize-status")
                    }
                }
            }

            Section("Post-Processing") {
                Toggle(isOn: $draft.Write_metadata_sidecar) {
                    HStack { Text("Write metadata sidecar"); InfoButton("Saves a Kodi-style .nfo file alongside each recording (same folder, same name) with the guide's synopsis, season/episode, air date, and genre — lets a media server show real episode info instead of just the filename.", about: "Write metadata sidecar") }
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
                    HStack { Text("Post-recording script"); InfoButton("Shell script run after each successful recording. File path is $1; env vars: HDHR_PATH, HDHR_TITLE, HDHR_CHANNEL, HDHR_TRANSCODE, HDHR_EPISODE, HDHR_DEVICE, HDHR_SERIES, HDHR_FILESIZE. Example scripts are in tools/post_recording/.", about: "Post-recording script") }
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
            Section("Source") {
                Picker(selection: guideFormatBinding) {
                    Text("JSON").tag(GuideFormat.json)
                    Text("XMLTV").tag(GuideFormat.xmltv)
                    if draft.OTA_enabled { Text("OTA").tag(GuideFormat.air) }
                } label: {
                    HStack { Text("Guide format"); InfoButton("JSON and XMLTV both come from SiliconDust's cloud guide service and describe the same shows; JSON is the default. OTA (the air) appears here once you allow guide data from the air in Over the Air: it replaces SiliconDust's lineup and guide with what the stations broadcast. Devices without DeviceAuth always use JSON.", about: "Guide format") }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings-guide-format")
                if !draft.OTA_enabled {
                    Text("To use the air as a source, allow guide data from the air in Settings → Over the Air.")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings-guide-format-ota-hint")
                }
                HStack(alignment: .top, spacing: 10) {
                    guideFormatCard("JSON (default)", selected: guideFormatBinding.wrappedValue == .json, id: "settings-guide-format-json",
                        pros: ["A complete timeline: shows that already ended in the last hour are included, so the guide grid has no gaps behind \"now\".",
                               "Fetches 28 hours ahead, including the hour just past.",
                               "Works for a device with no DeviceAuth (its own local guide)."],
                        cons: ["Genres are coarse (about 9 tags such as Sports or Drama) and often empty, so paid programming is spotted by a blocklist.",
                               "No network name (affiliate)."])
                    guideFormatCard("XMLTV", selected: guideFormatBinding.wrappedValue == .xmltv, id: "settings-guide-format-xmltv",
                        pros: ["Richer genres (about 60 real categories), which help the genre colours and the Bonus Time default for sports.",
                               "Paid programming is marked explicitly.",
                               "Includes the network name (affiliate)."],
                        cons: ["Never contains a show that has already ended, so the last hour of the guide shows empty gaps where earlier shows were.",
                               "The server sets the window (about 2 days), not the app.",
                               "Cloud only: a device with no DeviceAuth uses JSON anyway."])
                    if draft.OTA_enabled {
                        guideFormatCard("OTA (the air)", selected: guideFormatBinding.wrappedValue == .air, id: "settings-guide-format-air",
                            pros: ["Everything the stations broadcast, including channels SiliconDust lacks. No SiliconDust guide or internet needed.",
                                   "Saved listings are kept ahead by reading again when they run out within 6 hours."],
                            cons: ["No series IDs (series recording falls back on titles), no genre tags or images.",
                                   "Depth varies by station, from about 12 hours to 3 days; some stations send no guide.",
                                   "Needs idle tuners to scan, and favorites do not apply."])
                    }
                }
            }

            Section("Fetch") {
                Picker(selection: $draft.Guide_refresh_interval_divisor) {
                    Text("1/2 (~\(formattedGuideRefreshInterval(divisor: 2)))").tag(2)
                    Text("1/4 (~\(formattedGuideRefreshInterval(divisor: 4)))").tag(4)
                    Text("1/8 (~\(formattedGuideRefreshInterval(divisor: 8)))").tag(8)
                } label: {
                    HStack { Text("Auto-refresh"); InfoButton("How often guide data is automatically re-fetched in the background, as a fraction of the 28-hour guide window — 1/4 refreshes roughly every 7 hours. A shorter fraction keeps the far end of the guide fresher; a longer one makes fewer requests. The exact timing is randomized within the final hour of the interval each time, rather than always landing at the same predictable offset. \"Update Guides Now\" always refreshes immediately regardless of this setting.", about: "Auto-refresh") }
                }
                HStack {
                    busyButton("Update Guides Now", isBusy: $guideRefreshInProgress) { await state.refreshAll() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("settings-update-guides")
                    InfoButton("Force-refreshes guide data for all tuners immediately, without waiting for the auto-refresh window.")
                }
            }

        }
        .formStyle(.grouped)
        .navigationTitle("Guide")
    }


    // MARK: - Over the Air

    private var overTheAirView: some View {
        Form {
            // The channel scan is the core of this tab and needs no permission: it reads only the channel names and numbers, on idle tuners,
            // early in the morning. It is how the app learns which stations SiliconDust's lineup lacks.
            Section("Channel scan") {
                Picker(selection: $draft.OTA_lineup_hour) {
                    Text("Never").tag(-1)
                    ForEach(0..<24, id: \.self) { h in Text(String(format: "Daily at %02d:00", h)).tag(h) }
                } label: {
                    HStack { Text("Scan for channels"); InfoButton("Reads just the channel names and numbers from the stations your tuner receives (a few minutes, no guide) once a day from this hour on, on idle tuners only. The scan steps aside whenever a recording or a viewer needs a tuner. It is how the app finds stations SiliconDust's lineup is missing; they are listed in the web guide under AIR ONLY · WATCH.", about: "Scan for channels") }
                }
                .accessibilityIdentifier("settings-ota-lineup-hour")
                Text("Every TV channel is tuned in turn; the channel list takes a few minutes. It uses idle tuners only and steps aside for a recording or a viewer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                AirLastScanLines(progress: state.otaProgress, showGuide: draft.OTA_enabled)
                if state.otaScanTask != nil {
                    Label(state.otaScanStatus, systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption)
                    Button("Cancel Scan") { state.cancelOTAScan() }
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("settings-ota-cancel")
                } else {
                    if !state.otaScanStatus.isEmpty {
                        Text(state.otaScanStatus).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Scan Channel List Now") { state.startOTAScan(lineupOnly: true) }
                            .disabled(state.recordableDevices.isEmpty || isDirty)
                            .accessibilityIdentifier("settings-ota-lineup-scan")
                        InfoButton("Reads just the channel names and numbers from each station, about 10 seconds per station with signal (a couple of minutes in all).", about: "Scan Channel List Now")
                        saveFirstHint
                    }
                }
            }
            if !draft.OTA_always_use || !draft.OTA_enabled { missingFromSiliconDustSection }
            // Everything below needs the person's permission: it uses the tuners for much longer and can change which guide is used.
            Section("Guide data from the air") {
                Toggle(isOn: Binding(get: { draft.OTA_enabled }, set: { draft.OTA_enabled = $0; if !$0 { draft.OTA_always_use = false } })) {
                    HStack {
                        Text("Use the air for guide data")
                        InfoButton("SiliconDust's lineup and guide are sometimes missing stations or shows that are really on the air. Allowing this lets the app read their listings from the air (a minute or so per station, on idle tuners, stepping aside for recordings and viewers), use the saved air guide as a backup if SiliconDust's cannot be loaded, and offers OTA as a guide source under Guide → Guide format. Off, only the channel scan above runs. (If SiliconDust's guide cannot be loaded at all, the app still asks whether to scan the air for a backup.)", about: "Use the air for guide data")
                    }
                }
                .accessibilityIdentifier("settings-ota-enabled")
                if draft.OTA_enabled {
                    Text(draft.OTA_always_use
                         ? "OTA is the guide source (Guide → Guide format): everything the air carries is used, and saved listings are read again when they run out within 6 hours."
                         : "SiliconDust stays the guide. Only the multiplexes holding stations it is missing are read from the air for listings, and read again when the saved listings run out within 6 hours.")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings-ota-source-note")
                    if state.otaScanTask == nil {
                        HStack {
                            Button("Scan the Air Now") { state.startOTAScan() }
                                .disabled(state.recordableDevices.isEmpty || isDirty)
                                .accessibilityIdentifier("settings-ota-scan")
                            InfoButton("Tunes every TV channel and reads the full listings stations broadcast, about 15 minutes in all. Uses idle tuners only and steps aside for a recording or a viewer.", about: "Scan the Air Now")
                            saveFirstHint
                        }
                    }
                } else {
                    Text("Off. Only the channel scan above runs; if SiliconDust's guide cannot be loaded at all, the app still asks first.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Over the Air")
    }

    /// Which multiplexes hold stations SiliconDust's lineup lacks (matched by channel number; the RF comes from the saved air lineup) — the ones the gap-fill reads once guide data from the air is allowed.
    @ViewBuilder
    private var missingFromSiliconDustSection: some View {
        let deviceId = OTAScanView.scanDeviceId(state)
        let missing = deviceId.map { OTAStore.missingMultiplexes(airOnly: state.airOnlyChannels(deviceId: $0)) } ?? []
        let records = deviceId.map { OTAStore.muxRecords(deviceId: $0) } ?? [:]
        Section("Missing from SiliconDust") {
            if missing.isEmpty {
                Text(deviceId.flatMap { OTAStore.lineupDate(deviceId: $0) } == nil
                     ? "No channel list yet. Run \"Scan Channel List Now\" above to find out which stations SiliconDust lacks."
                     : "Every station on the air is in SiliconDust's lineup.")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings-ota-missing-none")
            } else {
                ForEach(missing, id: \.rf) { mux in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("RF \(mux.rf) · \(mux.channels.count) channel\(mux.channels.count == 1 ? "" : "s")")
                        Text(mux.channels.map { "\($0.GuideNumber) \($0.GuideName)" }.joined(separator: ", ")
                             + " · " + (records[mux.rf]?.guideDate.map { "guide read \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "guide not read yet"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("settings-ota-missing-\(mux.rf)")
                }
            }
        }
    }

    private enum GuideFormat: Hashable { case json, xmltv, air }

    /// The three-way Guide format picker over the two settings behind it: XMLTV or JSON (`Guide_use_xml`) and the air as the source (`OTA_always_use`,
    /// only while guide data from the air is allowed). Picking the air leaves the XMLTV choice alone, so going back restores it.
    private var guideFormatBinding: Binding<GuideFormat> {
        Binding(
            get: { draft.OTA_enabled && draft.OTA_always_use ? .air : (draft.Guide_use_xml ? .xmltv : .json) },
            set: { format in
                switch format {
                case .json:  draft.OTA_always_use = false; draft.Guide_use_xml = false
                case .xmltv: draft.OTA_always_use = false; draft.Guide_use_xml = true
                case .air:   draft.OTA_always_use = true
                }
            })
    }

    /// One side of the JSON / XMLTV / OTA comparison under the Guide format picker: what the format is good and bad at. The chosen side is outlined.
    private func guideFormatCard(_ title: String, selected: Bool, id: String, pros: [String], cons: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline.weight(.semibold))
            ForEach(pros, id: \.self) { line in
                Label { Text(line).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "plus.circle.fill").foregroundStyle(.green) }
            }
            ForEach(cons, id: \.self) { line in
                Label { Text(line).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "minus.circle.fill").foregroundStyle(.orange) }
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.08) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: selected ? 1.5 : 1))
        .opacity(selected ? 1 : 0.8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    // Live preview for the auto-refresh Picker's option labels — reuses the exact same
    // calculation idleLoop uses (AppState.guideRefreshIntervalSeconds), so the displayed value
    // can never drift from what the app actually does, and updates live as draft.GuideHours changes.
    private func formattedGuideRefreshInterval(divisor: Int) -> String {
        let seconds = AppState.guideRefreshIntervalSeconds(guideHours: draft.GuideHours, divisor: divisor)
        let minutes = seconds / 60
        guard minutes >= 60 else { return "\(Int(minutes.rounded())) min" }
        let hours = minutes / 60
        return hours.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(hours)) hr" : String(format: "%.1f hr", hours)
    }

    // MARK: - Notifications

    private var notificationsView: some View {
        Form {
            Section("Reminders") {
                Stepper(value: Binding(get: { Int(draft.Notify_upnext) }, set: { draft.Notify_upnext = Double($0) }), in: 5...120, step: 5) {
                    HStack { Text("Up Next: \(Int(draft.Notify_upnext)) min before"); InfoButton("Early heads-up notification sent this many minutes before a show's scheduled start time.") }
                }
            }

            Section("Discord") {
                Toggle(isOn: $draft.Discord_enabled) {
                    HStack { Text("Enable Discord notifications"); InfoButton("Post recording status updates to a Discord channel via webhook. Requires a webhook URL from your server's channel settings.", about: "Enable Discord notifications") }
                }
                .accessibilityIdentifier("settings-discord-enabled")

                if draft.Discord_enabled {
                    HStack(spacing: 8) {
                        TextField("https://discord.com/api/webhooks/…", text: $draft.Discord_webhook_url)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Webhook URL")
                            .accessibilityIdentifier("settings-discord-url")
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
                            .accessibilityIdentifier("settings-discord-test")
                        }
                    }
                    if draft.Discord_webhook_url.isEmpty {
                        Text("Paste a webhook URL to enable notifications")
                            .font(.caption).foregroundStyle(.secondary)
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
                                "Show added.",
                                fields: [\.Discord_on_show_added])
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
            HStack { Text(label); InfoButton(info, about: label) }
        }
    }

    // MARK: - Advanced

    private var advancedView: some View {
        Form {
            Section("Reminder timing") {
                Stepper(value: Binding(get: { Int(draft.Notify_recording) }, set: { draft.Notify_recording = Double($0) }), in: 1...60) {
                    HStack { Text("Recording alert: \(Int(draft.Notify_recording)) min before"); InfoButton("A second, closer notification just before recording begins — set lower than Up Next so both fire in order.") }
                }
                if draft.Notify_recording >= draft.Notify_upnext {
                    Label("Recording alert fires at or after Up Next — the Up Next notification won't appear first.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Section("Network") {
                Picker(selection: $draft.Network_interface) {
                    Text("Auto").tag("")
                    let available = netInterfaces
                    // The saved interface isn't connected right now: keep it selectable (so the Picker has a
                    // matching tag and the choice isn't lost) and say it is currently falling back to Auto.
                    if !draft.Network_interface.isEmpty, !available.contains(where: { $0.name == draft.Network_interface }) {
                        Text("\(draft.Network_interface) — not connected (using Auto)").tag(draft.Network_interface)
                    }
                    ForEach(available) { iface in
                        Text(iface.displayLabel).tag(iface.name)
                    }
                } label: {
                    HStack { Text("Discovery & recording interface"); InfoButton("Binds UDP discovery and curl recordings to a specific interface. VPN tunnels are listed (utun*, tun*, cscotun*, gpd*, etc.) — use one if your HDHomeRun is on a remote network reachable via VPN.", about: "Discovery & recording interface") }
                }
                Picker(selection: $draft.Dock_icon_mode) {
                    Text("Auto").tag("auto")
                    Text("Always").tag("always")
                    Text("Never").tag("never")
                } label: {
                    HStack { Text("Dock icon"); InfoButton("\"Auto\" shows a Dock icon only until the app has successfully reached your tuner once — a workaround for a macOS bug where background-only apps can fail to ever receive the Local Network permission prompt — then hides it. \"Always\"/\"Never\" override this permanently.", about: "Dock icon") }
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

                Text(state.configManager.configPath)
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Button("Show config in Finder") {
                    NSWorkspace.shared.selectFile(state.configManager.configPath,
                                                  inFileViewerRootedAtPath: "")
                }
                HStack {
                    Button("Export Config…") { exportConfig() }
                        .disabled(isDirty)   // exports the saved file, not the unsaved draft
                        .accessibilityIdentifier("settings-export-config")
                    Button("Import Config…") { importConfig() }
                        .disabled(isDirty)
                        .accessibilityIdentifier("settings-import-config")
                    saveFirstHint
                }
                if !configIOStatus.isEmpty {
                    Label(configIOStatus, systemImage: configIOStatus.hasPrefix("Error") ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(configIOStatus.hasPrefix("Error") ? .red : .green)
                        .font(.callout)
                }
            }

            Section("Updates") {
                Toggle(isOn: $draft.Check_for_updates) {
                    HStack { Text("Check for updates automatically"); InfoButton("Once a day, checks GitHub for a newer release and shows a link here and in the menu bar. Read-only — never downloads or installs anything.", about: "Check for updates automatically") }
                }
            }

            Section("Signal Quality") {
                Toggle(isOn: $draft.Signal_quality_enabled) {
                    HStack { Text("Show signal bars in guide"); InfoButton("Display signal strength bars in the guide grid and Watch Now view. Signal data is always collected during recordings regardless of this toggle.", about: "Show signal bars in guide") }
                }
                Toggle(isOn: $draft.Signal_quality_alert_notify) {
                    HStack { Text("Send alerts on signal dropout"); InfoButton("Send a notification and Discord message when a recording's signal drops below 30% for ~20 seconds. Logging is always active.", about: "Send alerts on signal dropout") }
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
                        // recordableDevices — a discovered virtual relay device (VirtualTunerService.swift)
                        // has no real signal to measure; see AppState.startSignalScan's own comment.
                        // "" = every tuner. A selection whose device has gone away behaves as "All Tuners".
                        let scanTarget = state.recordableDevices.contains { $0.DeviceID == signalScanDeviceID } ? signalScanDeviceID : ""
                        Picker("Tuner", selection: $signalScanDeviceID) {
                            Text("All Tuners").tag("")
                            ForEach(state.recordableDevices) { device in
                                Text(device.FriendlyName.map { "\($0) (\(device.DeviceID))" } ?? device.DeviceID).tag(device.DeviceID)
                            }
                        }
                        // force=true: manual scan always re-measures, even channels with fresh data
                        HStack {
                            Button("Measure Signal") { state.startSignalScan(force: true, deviceId: scanTarget.isEmpty ? nil : scanTarget) }
                                .disabled(state.recordableDevices.isEmpty || isDirty)
                                .accessibilityIdentifier("settings-measure-signal")
                            saveFirstHint
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
            Section("Web LAN") {
                Toggle(isOn: $draft.Web_server_enabled) {
                    HStack { Text("Enable Web LAN"); InfoButton("Serve the channel guide and recording controls as a web page on your local network — accessible from any browser on any device. Local network only; no authentication. Do not expose this port to the internet.", about: "Enable Web LAN") }
                }
                if draft.Web_server_enabled {
                    LabeledContent {
                        TextField("Port", value: $draft.Web_server_port, format: .number.grouping(.never))
                            .labelsHidden()
                            .accessibilityIdentifier("settings-web-port")
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                    } label: {
                        HStack { Text("Port"); InfoButton("Port number (1025–65534). macOS requires root for ports below 1024. Default: 1980. Changes and mDNS registration update immediately on Save.", about: "Port") }
                    }
                    if webPortInvalid {
                        Label("Port must be between 1025 and 65534", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                if state.config.Web_server_enabled && state.webServerRunning {
                    let urlStr = "http://\(lanIP()):\(state.config.Web_server_port)"
                    urlRow(urlStr)
                }
            }

            // hdhr_guide (docs/TUIGuide.md) connects to the exact same internal web server Web LAN
            // exposes — there's no separate port/listener for it — so its own toggle is
            // always visible but disabled (dimmed, "(Requires Web LAN)") while Web LAN is off,
            // the same "show it, don't hide it" pattern used for VLC-gated features elsewhere in
            // this app, rather than the whole section vanishing. Gated on `draft.Web_server_enabled`
            // (the pending toggle), matching every other reveal-on-toggle control in this form (the
            // Port field above, the FEED's transcode picker below) — not the Recording FEED
            // toggle, which is deliberately independent of Web LAN: it holds its own internal
            // web-server claim (`AppState.ensureWebServerRunning()`) specifically so it keeps
            // working with Web LAN off, so it isn't gated here at all. Terminal_guide_enabled itself
            // is a separate sub-switch under that: the binary checks it (via /api/guide.json's
            // terminalGuideEnabled field) and refuses to run when off, letting someone share the web
            // guide with the household without also advertising/allowing the terminal client.
            let lanEnabled = draft.Web_server_enabled
            Section("Web Streaming (Beta)") {
                Toggle(isOn: $draft.Web_streaming_enabled) {
                    HStack {
                        Text(gatedLabel("Watch recordings in a browser", met: lanEnabled, requirement: "Web LAN"))
                        InfoButton("Lets anyone who can open the web guide on your network play a recording that is in progress, in Safari, Chrome, Firefox or Edge. This Mac converts the video as it plays, so it uses some CPU while someone is watching. Off by default. Turning it off stops every web stream right away; no restart needed.")
                    }
                }
                .disabled(!lanEnabled)
            }
            Section("Terminal Guide") {
                Toggle(isOn: $draft.Terminal_guide_enabled) {
                    HStack {
                        Text(gatedLabel("Enable Terminal Guide", met: lanEnabled, requirement: "Web LAN"))
                        InfoButton("Lets the bundled command-line client (path below) connect. Off by default. Turning this off has no security effect — the same data is already reachable from any browser on the network whenever Web LAN is on — it only hides/disables the terminal client specifically. Requires Web LAN above to be on: the terminal client connects to that exact same local web server, not a separate one.")
                    }
                }
                .disabled(!lanEnabled)
                if draft.Terminal_guide_enabled && lanEnabled {
                    if state.config.Web_server_enabled && state.webServerRunning {
                        // hdhr_guide (docs/TUIGuide.md) only works while the web server it's
                        // showing above is actually running — same gate as the Access section, so
                        // this row can never point someone at a tool that will just fail to connect.
                        let guideURL = Self.terminalGuideURL
                        // Existence is cached (terminalGuideExists, refreshed on appear/refocus):
                        // deploy.sh always copies this file, so it's only ever missing via an
                        // unsupported dev flow (plain `swift build` + direct binary, no .app bundle)
                        // or a corrupted install; in either case the button should say so rather
                        // than silently no-op on click.
                        HStack {
                            Text(guideURL.path)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .layoutPriority(1)
                            Spacer()
                            copyButton(guideURL.path)
                        }
                        if terminalGuideExists {
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
                    } else {
                        // Draft toggles are on but not yet Saved (or Web LAN hasn't finished
                        // starting) — the actual listener isn't up yet, so there's nothing to
                        // connect to. Matches this same "not live yet" distinction the Access
                        // section above already draws between draft and `state.config`/`webServerRunning`.
                        Text("Save to activate — the terminal client can connect once Web LAN is running.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Same shape/gating as Terminal Guide above — a sub-switch under Web LAN that's
            // .disabled (not hidden) while Web LAN is off, dimmed via gatedLabel's own
            // "(Requires Web LAN)" suffix. Unlike Terminal Guide's toggle, though, this one is a
            // real security-relevant gate, not just a courtesy one — see
            // Home_assistant_status_enabled's doc comment (Models.swift) for why.
            Section("Home Assistant") {
                Toggle(isOn: $draft.Home_assistant_status_enabled) {
                    HStack {
                        Text(gatedLabel("Enable status endpoint", met: lanEnabled, requirement: "Web LAN"))
                        InfoButton("Exposes /api/tuner-status.json — per-tuner occupancy plus Recording/Up Next/Scheduled/Paused shows, as JSON, for polling by something like a Home Assistant REST sensor. Off by default. Requires Web LAN above to be on: this rides the exact same local web server, not a separate one. There's no further authentication — anything on your local network can read it once both toggles are on, same as the rest of Web LAN.") }
                }
                .disabled(!lanEnabled)
                if draft.Home_assistant_status_enabled && lanEnabled {
                    if state.config.Web_server_enabled && state.webServerRunning {
                        let urlStr = "http://\(lanIP()):\(state.config.Web_server_port)/api/tuner-status.json"
                        urlRow(urlStr)
                    } else {
                        Text("Save to activate — the endpoint responds once Web LAN is running.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Visible by default as of v2.5.0 (AppConfig.FEED_feature_enabled's own doc comment) —
            // was hidden 2026-09-10 while the feature needed more work; the VLC playback-stall bug
            // is now fixed and CC track switching is confirmed working. Flip that flag false by
            // hand-editing the config JSON to hide this section again if ever needed.
            if state.config.FEED_feature_enabled {
            Section("Recording FEED (Beta)") {
                Toggle(isOn: $draft.Virtual_tuner_relay_enabled) {
                    HStack { Text("Rebroadcast In-Progress Recordings"); InfoButton("While a show is recording, this Mac briefly advertises itself as an extra HDHomeRun-style tuner on the local network, so another Mac running hdhrVCRplus can watch the recording without tying up a second real tuner. Off by default. It can never be used to start a new recording — only to watch one already in progress — and works independently of Web LAN above. Beta: occasional playback hiccups on the watching Mac, and switching audio tracks while watching, are known limitations still being worked on.", about: "Rebroadcast In-Progress Recordings") }
                }
                if draft.Virtual_tuner_relay_enabled {
                    Picker(selection: $draft.Virtual_tuner_relay_default_transcode) {
                        Text("Heavy").tag("heavy")
                        Text("Internet 720").tag("internet720")
                        Text("Internet 540").tag("internet540")
                        Text("Internet 480").tag("internet480")
                        Text("Internet 360").tag("internet360")
                        Text("Internet 240").tag("internet240")
                        Text("Mobile").tag("mobile")
                    } label: {
                        HStack {
                            Text(gatedLabel("Default transcode level", met: vlcInstalled, requirement: "VLC"))
                            InfoButton("Applied whenever a viewer of the rebroadcast above asks for any transcode — the specific profile their own client requests only decides whether to transcode at all, not which level; this Mac always uses the level chosen here instead. Every level keeps the source's own resolution and frame rate, so only the target bitrate differs — Heavy is the highest quality/bitrate, Mobile the lowest. Without VLC installed, a transcode request is served as untranscoded, passthrough bytes instead — the rebroadcast itself still works.")
                        }
                    }
                    .accessibilityIdentifier("settings-relay-default-transcode")
                    .disabled(!vlcInstalled)
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

    // Long monospaced URL/path row: wraps to two lines, middle-truncates beyond that, keeps the
    // Open link and Copy button at their natural size so they never get squeezed out.
    @ViewBuilder
    private func urlRow(_ urlStr: String) -> some View {
        HStack {
            Text(urlStr)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .layoutPriority(1)
            Spacer()
            if let url = URL(string: urlStr) { Link("Open", destination: url).fixedSize() }
            copyButton(urlStr)
        }
    }

    private func copyButton(_ string: String) -> some View {
        Button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(string, forType: .string)
        }
        .fixedSize()
    }

    // MARK: - Maintenance

    private var maintenanceView: some View {
        Form {
            guidesAndDevicesSection
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
            }
            Section("Storage") {
                storageRow("Guide cache", "The SiliconDust guide files kept on disk so the guide survives a restart or an outage. Emptying it also drops the guide in memory and fetches it again.",
                           bytes: storageSizes.guideCache, button: "Empty") {
                    state.guideStore.invalidateAll()
                    state.guideByDevice = [:]
                    let removed = state.guideStore.clearDiskCache()
                    await state.refreshGuide()
                    return "Guide cache emptied (\(removed) file(s)) and the guide fetched again"
                }
                storageRow("Saved air guide and lineup", "What the over-the-air scans found (channels and listings). Deleting it means the next channel scan starts from nothing; stations SiliconDust lacks disappear until then.",
                           bytes: storageSizes.airData, button: "Delete") {
                    if state.otaScanTask != nil { return "A scan is running — cancel it first" }
                    let result = state.purgeSavedAirData(guide: true, lineup: true)
                    await state.reloadLineups()
                    return result
                }
                storageRow("Channel logos", "Station logos downloaded for the guide and menus. They download again as needed.",
                           bytes: storageSizes.icons, button: "Empty") {
                    let removed = await ChannelIconCache.shared.clearAll()
                    return "Deleted \(removed) logo file(s)"
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

    // MARK: Maintenance → Guides & Devices

    private var guidesDevicesSelectionCount: Int { [runDiscover, runLineups, runGuide, runChannelScan, runSeries].filter { $0 }.count }

    /// The first thing in Maintenance: tick what to redo and press one button. Any unsaved settings are saved first, so the actions use what you see.
    @ViewBuilder
    private var guidesAndDevicesSection: some View {
        Section {
            Toggle(isOn: $runDiscover) {
                HStack { Text("Find tuners again"); InfoButton("Searches the network for HDHomeRun tuners again. Use it when a tuner is missing from the device list, or after a router, Wi-Fi or network change (the app may still be holding the old address).", about: "Find tuners again") }
            }
            .accessibilityIdentifier("settings-gd-discover")
            Toggle(isOn: $runLineups) {
                HStack { Text("Reload channel lineups"); InfoButton("Asks each tuner for its channel list again (and, with the air as the source, reads the saved air lineup). Use it when channels you expect are missing, renamed or still showing as old after a rescan.", about: "Reload channel lineups") }
            }
            .accessibilityIdentifier("settings-gd-lineups")
            Toggle(isOn: $runGuide) {
                HStack { Text("Refresh the guide"); InfoButton("Fetches the program guide again from every tuner right now, instead of waiting for the next automatic refresh, and re-checks every series show against it. Use it when listings look stale or wrong, or a series show is not finding its next airing. If that does not help, empty the guide cache under Storage below.", about: "Refresh the guide") }
            }
            .accessibilityIdentifier("settings-gd-guide")
            Toggle(isOn: $runChannelScan) {
                HStack { Text("Scan for channels over the air"); InfoButton("Starts the channel scan now (a few minutes, idle tuners only) instead of waiting for tomorrow morning's. Use it after moving the antenna, or when a station you should get is missing from the list of channels SiliconDust lacks.", about: "Scan for channels over the air") }
            }
            .accessibilityIdentifier("settings-gd-channel-scan")
            Toggle(isOn: $runSeries) {
                HStack { Text("Re-check series shows"); InfoButton("Looks again in the guide for the next airing of every SeriesID show. This already happens after every guide refresh; use it only if a series show is still not scheduled after refreshing the guide.", about: "Re-check series shows") }
            }
            .accessibilityIdentifier("settings-gd-series")
            HStack {
                Button { runGuidesAndDevices() } label: {
                    Label(isDirty ? "Save Settings & Run" : "Run Selected", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(guidesDevicesSelectionCount == 0 || guidesDevicesRunning)
                .accessibilityIdentifier("settings-gd-run")
                if guidesDevicesRunning { ProgressView().controlSize(.small) }
                if isDirty && !guidesDevicesRunning {
                    Text("Your unsaved settings are saved first").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                InfoButton("Runs every ticked action in order: find tuners, reload lineups, refresh the guide, start the channel scan, re-check series. Unsaved settings are saved first so the actions use them. Your ticks are remembered for next time.", about: "Guides & Devices")
            }
            if !guidesDevicesStatus.isEmpty {
                Label(guidesDevicesStatus, systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
                    .accessibilityIdentifier("settings-gd-status")
            }
        } header: {
            Label("Guides & Devices", systemImage: "arrow.triangle.2.circlepath").font(.headline)
        }
    }

    private func runGuidesAndDevices() {
        guard !guidesDevicesRunning, guidesDevicesSelectionCount > 0 else { return }
        if isDirty {
            if webPortInvalid || state.configManager.savesSuppressedAfterImport {
                guidesDevicesStatus = "Settings can't be saved yet — fix them first"
                return
            }
            applyAndSave()
        }
        guidesDevicesRunning = true
        guidesDevicesStatus = ""
        let discover = runDiscover, lineups = runLineups, guide = runGuide, scan = runChannelScan, series = runSeries
        Task { @MainActor in
            var done: [String] = []
            if discover {
                await state.rediscoverDevices()
                done.append("\(state.devices.count) tuner(s) found")
            }
            if lineups {
                await state.reloadLineups()
                done.append("lineups reloaded (\(state.lineups.values.map(\.count).reduce(0, +)) channels)")
            }
            if guide {
                await state.refreshGuide()   // also re-checks every series show
                done.append("guide refreshed (\(state.guideByDevice.values.flatMap { $0 }.count) channels)")
            } else if series {
                await state.rescheduleAllSeries()
                done.append("series shows re-checked")
            }
            if scan {
                done.append(state.startOTAScan(lineupOnly: true))
            }
            guidesDevicesStatus = done.joined(separator: " · ")
            guidesDevicesRunning = false
        }
    }

    // MARK: storage sizes (Maintenance → Storage)

    private struct StorageSizes: Equatable { var guideCache: Int64 = 0; var airData: Int64 = 0; var icons: Int64 = 0 }

    /// Total bytes of the regular files under `url` (0 when it does not exist). Read off the main actor.
    nonisolated private static func folderSize(_ url: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    private func refreshStorageSizes() {
        let guideDir = state.configManager.supportDir.appendingPathComponent("guide_cache", isDirectory: true)
        let airDir = OTAStore.root
        let iconDir = ChannelIconCache.defaultDirectory
        Task { @MainActor in
            let sizes = await Task.detached(priority: .utility) {
                StorageSizes(guideCache: Self.folderSize(guideDir), airData: Self.folderSize(airDir), icons: Self.folderSize(iconDir))
            }.value
            storageSizes = sizes
        }
    }

    /// A Maintenance row for something that takes disk space: its name, how big it is now, and a button that clears it.
    private func storageRow(_ title: String, _ description: String, bytes: Int64, button: String,
                            action: @escaping () async -> String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            HStack {
                Text(title).fontWeight(.medium)
                InfoButton(description, about: title)
            }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                .accessibilityIdentifier("settings-storage-size-" + title.lowercased().replacingOccurrences(of: " ", with: "-"))
            saveFirstHint
            if busyRow == title {
                ProgressView().controlSize(.small)
            } else {
                Button(button) {
                    busyRow = title
                    maintenanceStatus = ""
                    Task { @MainActor in
                        maintenanceStatus = await action()
                        refreshStorageSizes()
                        if busyRow == title { busyRow = nil }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isDirty || bytes == 0)
                .accessibilityIdentifier("settings-storage-" + title.lowercased().replacingOccurrences(of: " ", with: "-"))
            }
        }
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

    #if DEBUG
    // MARK: - Developer (debug builds only; docs/SettingsView.md "Developer")

    private var developerView: some View {
        Form {
            Section("Logging") {
                Toggle(isOn: $draft.Verbose_curl) {
                    HStack { Text("Verbose curl logging"); InfoButton("Log full curl request/response headers for each recording. Use when diagnosing why a recording fails to start.", about: "Verbose curl logging") }
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
            }
            Section("Tools") {
                maintenanceRow("Preview Launch Splash",
                               "Play the launch splash now — show posters fly in, the checklist fills, and the logo flies to the menu bar icon") {
                    NSApp.activate(ignoringOtherApps: true)
                    LaunchSplashController.shared.play(state: state, offersDonation: false)
                    return "Launch splash playing"
                }
                maintenanceRow("Rescan Series",
                               "Re-checks the guide for the next air time of every series show (this already happens after every guide refresh)") {
                    let count = state.shows.filter { $0.show_active && !$0.show_paused && !$0.show_recording && $0.show_use_seriesid }.count
                    await state.rescheduleAllSeries()
                    return "\(count) series show(s) rescheduled"
                }
                maintenanceRow("Reset Fail Counts",
                               "Clears the error counters of every show without unpausing any") {
                    let total = state.shows.count
                    state.resetAllFailCounts()
                    return "Cleared fail counts on \(total) show(s)"
                }
            }
            Section("Guide source") {
                Picker("Guide", selection: Binding(
                    get: { state.guideSourceChoice },
                    set: { choice in Task { @MainActor in await state.setGuideSource(choice) } })) {
                    ForEach(AppState.GuideSourceChoice.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("dev-guide-source")
                Text("Switching saves the choice, drops the guide in memory and fetches it again from the new source. The same switch exists under Guide → Source (XMLTV).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Lineup") {
                maintenanceRow("Reload Lineup", "Fetches the lineup again (from the tuner, or the saved air scan in \"Always use\" mode)") {
                    await state.reloadLineups()
                    return "Lineup reloaded — \(state.lineups.values.map(\.count).reduce(0, +)) channel(s)"
                }
            }
            Section("Purges") {
                Toggle("Guide in memory", isOn: $purgeMemory)
                Toggle("Cached SiliconDust guide files", isOn: $purgeSDCache)
                Toggle("Saved air guide", isOn: $purgeAirGuide)
                Toggle("Saved air lineup", isOn: $purgeAirLineup)
                HStack {
                    Text("Removes what is ticked, reloads the guide, then starts a new air scan and opens its window (channel list only when just the air lineup was ticked).")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if maintenanceBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Run") {
                            if state.otaScanTask != nil {   // a running scan would save straight over whatever was just purged
                                maintenanceStatus = "An air scan is running — cancel it first (Guide → Lineup)."
                                return
                            }
                            maintenanceBusy = true
                            maintenanceStatus = ""
                            Task { @MainActor in
                                var done: [String] = []
                                if purgeSDCache { done.append(state.purgeGuideDiskCache()) }
                                if purgeAirGuide || purgeAirLineup {
                                    done.append(state.purgeSavedAirData(guide: purgeAirGuide, lineup: purgeAirLineup))
                                }
                                if purgeMemory {
                                    state.guideStore.invalidateAll()
                                    state.guideByDevice = [:]
                                }
                                if purgeMemory || purgeSDCache || purgeAirGuide { await state.refreshGuide() }
                                if purgeAirLineup { await state.reloadLineups() }
                                done.append(state.startOTAScan(lineupOnly: !(purgeMemory || purgeSDCache || purgeAirGuide)))
                                maintenanceStatus = done.isEmpty ? "Nothing ticked" : done.joined(separator: " · ")
                                maintenanceBusy = false
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(!(purgeMemory || purgeSDCache || purgeAirGuide || purgeAirLineup) || isDirty)
                        saveFirstHint
                    }
                }
            }
            if !maintenanceStatus.isEmpty {
                Section { Label(maintenanceStatus, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Developer")
    }
    #endif

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
                InfoButton(description, about: title)
            }
            Spacer()
            saveFirstHint
            if busyRow == title {
                ProgressView().controlSize(.small)
            } else {
                Button("Run") {
                    busyRow = title
                    maintenanceStatus = ""
                    Task { @MainActor in
                        do { maintenanceStatus = try await action() }
                        catch { maintenanceStatus = "Error: \(error.localizedDescription)" }
                        if busyRow == title { busyRow = nil }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isDirty)   // maintenance acts on saved settings
                .accessibilityLabel("Run \(title)")
                .accessibilityIdentifier("settings-maint-" + title.lowercased().replacingOccurrences(of: " ", with: "-"))
            }
        }
        .padding(.vertical, 2)
    }

    // Best-effort LAN IP for the Web LAN / Home Assistant "Open"/copy rows — shared so both agree
    // on the same address instead of each resolving it independently. Prefers the explicitly
    // configured interface, else physical Ethernet/Wi-Fi, else any non-VPN interface.
    private func lanIP() -> String {
        let ifaces = netInterfaces
        if !state.config.Network_interface.isEmpty,
           let match = ifaces.first(where: { $0.name == state.config.Network_interface }) {
            return match.ip
        }
        return ifaces.first(where: { $0.name.hasPrefix("en") || $0.name.hasPrefix("wlan") })?.ip
            ?? ifaces.first(where: { !isPointToPointInterface($0.name) })?.ip
            ?? "localhost"
    }

    // MARK: - About

    private var aboutView: some View {
        let sections = Self.parsedChangelogSections
        let currentRaw = sections.first
        let headline = currentRaw.flatMap { Self.splitHeadline($0) }
        let currentSection = headline?.rest ?? currentRaw
        let olderSections = sections.dropFirst().joined(separator: "\n\n")

        return ScrollView {
            VStack(spacing: 16) {
                // Name and version first, then the touchable status-light logo, then everything else in cards below.
                VStack(spacing: 4) {
                    Text("hdhrVCRplus").font(.largeTitle).bold()
                        .accessibilityIdentifier("about-title")
                    // appVersion is generated by deploy.sh before each build (format: YYMMDD-HHMM)
                    Text("Version \(appVersion)")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("about-version")
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

                AboutStatusLight(light: state.statusLight, blinkEnabled: state.config.Status_light_blink_enabled)

                aboutCard {
                    if state.config.Donation_unlocked {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                            Text("Registered supporter").font(.subheadline).bold()
                        }
                        if !state.config.Donation_unlock_code.isEmpty {
                            Text("Code: \(state.config.Donation_unlock_code)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    } else {
                        Text("Not yet a registered supporter")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }

                aboutCard {
                    DisclosureGroup(isExpanded: $aboutStoryExpanded) {
                        Text("""
                        hdhr_VCR began in 2016 as an AppleScript application for recording \
                        live TV from HDHomeRun network tuners. Built to fill the gap left by \
                        discontinued recording software, it grew to support SeriesID-based \
                        recording, multi-device discovery, and guide-driven scheduling — all \
                        from a simple macOS script.

                        This Swift/SwiftUI rewrite brings a native menu bar experience, a \
                        channel-guide grid, persistent settings, and modern macOS features like \
                        Launch at Login and user notifications, while staying fully compatible \
                        with the original AppleScript config format.
                        """)
                        .font(.callout)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                    } label: {
                        Text("The story").font(.headline)
                    }
                    .accessibilityIdentifier("about-story")
                }

                aboutCard {
                    HStack {
                        Text("Links").font(.headline)
                        Spacer()
                        Link("View on GitHub",
                             destination: URL(string: "https://github.com/identd113/hdhr_VCR_swift")!)
                            .buttonStyle(.bordered)
                    }
                    // In-app playback dlopens libvlc from the user's own separately-installed
                    // VLC.app (VLCBridge.swift) — never bundled/redistributed, so this is
                    // attribution for a runtime dependency, not a bundled-library notice.
                    HStack(spacing: 4) {
                        Text("Playback powered by")
                        Link("VLC media player", destination: URL(string: "https://www.videolan.org/vlc/")!)
                        Text("— © VideoLAN, GPL/LGPL.").foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }

                if let headline, let title = headline.paragraphs.first {
                    // The version's big feature, then what is coming (beta). Same text as the headline in RELEASES.md.
                    VStack(alignment: .leading, spacing: 8) {
                        Text("BIG FEATURE").font(.caption2.weight(.semibold)).foregroundStyle(.tint)
                        Text(title.replacingOccurrences(of: "**", with: "")).font(.title2.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(Array(headline.paragraphs.dropFirst().enumerated()), id: \.offset) { _, paragraph in
                            Text(LocalizedStringKey(paragraph)).font(.callout)
                                .foregroundStyle(paragraph.hasPrefix("**Coming soon") ? .secondary : .primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Link("Release notes", destination: URL(string: "https://github.com/identd113/hdhr_VCR_swift/blob/main/RELEASES.md")!)
                            .font(.callout)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.10)))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor.opacity(0.35), lineWidth: 1))
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("about-headline")
                }

                Text("What's new")
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
                    aboutCard {
                        DisclosureGroup(isExpanded: $aboutOlderExpanded) {
                            MarkdownView(markdown: olderSections, height: $changelogHeight)
                                .frame(height: max(40, changelogHeight))
                                .padding(.top, 6)
                        } label: {
                            Text("Earlier versions").font(.headline)
                        }
                        .accessibilityIdentifier("about-earlier-versions")
                    }
                }
            }
            .padding()
        }
        .navigationTitle("About")
    }

    /// A soft rounded card for the About tab's groups.
    private func aboutCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
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

    /// A version's headline: the paragraphs between `<!-- headline -->` and `<!-- /headline -->` at the top of its changelog section — a title, a
    /// blurb, and optionally a "coming soon / in testing" note. Returns them (blank-line separated, trimmed) and the section without the block;
    /// a section with no block returns nil and is unchanged. (The same text is written into RELEASES.md at release time.)
    static func splitHeadline(_ section: String) -> (paragraphs: [String], rest: String)? {
        guard let open = section.range(of: "<!-- headline -->"), let close = section.range(of: "<!-- /headline -->"), open.upperBound <= close.lowerBound else { return nil }
        let inner = section[open.upperBound..<close.lowerBound]
        let paragraphs = inner.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var rest = section
        rest.removeSubrange(open.lowerBound..<close.upperBound)
        return (paragraphs, rest.replacingOccurrences(of: "\n\n\n", with: "\n\n"))
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
        Dialogs.choose(panel) { url in
            guard let url else { return }
            do {
                try state.configManager.exportConfig(to: url)
                configIOStatus = "Exported to \(url.lastPathComponent)"
            } catch {
                configIOStatus = "Error: \(error.localizedDescription)"
            }
        }
    }

    private func importConfig() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a previously exported hdhrVCRplus config JSON file"
        Dialogs.choose(panel) { url in
            guard let url else { return }
            importConfig(from: url)
        }
    }

    private func importConfig(from url: URL) {
        do {
            try state.configManager.importConfig(from: url)
            // Deliberately not hot-reloaded into AppState — a currently-recording show's live
            // state (show_recording, discovered devices, tuner occupancy) can't be safely
            // reconciled against an arbitrary imported file mid-session (see importConfig's own
            // comment in ConfigManager.swift). Simplest safe option: write the file, restart to
            // pick it up — matches how a manually-copied-in config file already had to be applied.
            configIOStatus = "Imported — restart hdhrVCRplus to load it. Changes made before restarting won't be saved."
            // A status label is easy to miss, and from here every save is suppressed — say it loudly.
            let alert = NSAlert()
            alert.messageText = "Config imported — restart required"
            alert.informativeText = "Changes made before restarting hdhrVCRplus will not be saved. Quit now, then reopen the app to load the imported config?"
            alert.addButton(withTitle: "Quit Now")
            alert.addButton(withTitle: "Later")
            Dialogs.show(alert) { response in if response == .alertFirstButtonReturn { NSApp.terminate(nil) } }
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
        Dialogs.choose(panel) { url in if let url { draftSaveDirectory = url.path } }
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
        Dialogs.choose(panel) { url in if let url { draft.Post_recording_script = url.path } }
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

    // Tracks the markdown string last actually rendered, across updateNSView calls — SwiftUI calls
    // updateNSView on every re-render of whatever ancestor view hosts this (e.g. the whole About
    // tab, which observes @EnvironmentObject state and so re-renders on any @Published AppState
    // mutation while it's open), not just when `markdown` itself changed. Without this, the
    // markdown-to-NSAttributedString rebuild below — and its layout-measuring height recompute —
    // reran on every unrelated idle-loop tick/poll/refresh while this tab happened to be visible
    // (found in code review 2026-09-25).
    final class Coordinator { var lastRendered: String? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateNSView(_ textView: NSTextView, context: Context) {
        guard context.coordinator.lastRendered != markdown else { return }
        context.coordinator.lastRendered = markdown
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
    // Hands the hosting window back to the caller (SettingsView's Save & Close closes exactly this
    // window rather than NSApp.keyWindow, which may be a sheet or panel).
    var onWindow: ((NSWindow) -> Void)? = nil

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.delegate = context.coordinator
            if let w = view.window { onWindow?(w) }
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

        /// Set once the user has answered the unsaved-changes prompt, so the `close()` that follows isn't intercepted again.
        private var allowClose = false
        private var promptShowing = false

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard isDirty, !allowClose else { return true }
            // Ask without blocking (a sheet on this window, not runModal — the web server keeps answering),
            // refuse this close now, and close for real once the user has chosen.
            guard !promptShowing else { return false }
            promptShowing = true
            Task { @MainActor [weak self, weak sender] in
                guard let self else { return }
                let choice = await promptUnsavedChanges(
                    title: "Unsaved Settings", canSave: canSave,
                    savePrompt: "Save your changes before closing?",
                    blockedPrompt: "Settings can't be saved yet — fix the validation error first. Discard changes?",
                    on: sender
                )
                promptShowing = false
                switch choice {
                case .save:    onSave(); allowClose = true; sender?.close(); allowClose = false
                case .discard: allowClose = true; sender?.close(); allowClose = false
                case .cancel:  break
                }
            }
            return false
        }

        func windowDidBecomeKey(_ notification: Notification) {
            onBecomeKey()
        }
    }
}
