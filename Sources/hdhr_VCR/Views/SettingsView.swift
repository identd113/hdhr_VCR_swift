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
    @State private var selection: SettingsCategory? = .general
    @State private var draft: AppConfig = AppConfig()
    // Shadow drafts for settings that live outside AppConfig — applied only on Save
    @State private var draftAddShowMode:   AddShowMode = .menu
    @State private var draftSaveDirectory: String      = ""
    @State private var draftLaunchAtLogin: Bool        = false
    @State private var liveChangelog: String? = nil
    @State private var easterEggTaps = 0
    @State private var showEasterEgg = false
    @State private var maintenanceStatus: String = ""
    @State private var maintenanceBusy: Bool = false

    private var isDirty: Bool {
        draft != state.config
            || draftAddShowMode   != addShowMode
            || draftSaveDirectory != defaultSaveDirectory
            || draftLaunchAtLogin != (SMAppService.mainApp.status == .enabled)
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
                    }
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Save & Close") {
                    applyAndSave()
                    NSApp.keyWindow?.close()
                }
                .disabled(!isDirty)
                Button("Save") { applyAndSave() }
                    .buttonStyle(.borderedProminent)
                    // Turn orange when dirty so it visually demands attention
                    .tint(isDirty ? .orange : .accentColor)
                    .disabled(!isDirty)
                    .keyboardShortcut("s", modifiers: .command)
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
        }
    }

    private func applyAndSave() {
        let intervalChanged = draft.Idle_timer_interval != state.config.Idle_timer_interval
        state.config = draft
        state.saveConfig()
        if intervalChanged { state.startTimer() }
        // Commit settings that live outside AppConfig
        addShowMode          = draftAddShowMode
        defaultSaveDirectory = draftSaveDirectory
        let loginEnabled = SMAppService.mainApp.status == .enabled
        if draftLaunchAtLogin != loginEnabled {
            do {
                if draftLaunchAtLogin { try SMAppService.mainApp.register() }
                else                  { try SMAppService.mainApp.unregister() }
            } catch { print("[Settings] Login item: \(error)") }
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
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Notifications")
    }

    // MARK: - Advanced

    private var advancedView: some View {
        Form {
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
                maintenanceRow("Rediscover Devices",
                               "Scan the network for HDHomeRun tuners (mDNS + UDP + known hosts)") {
                    await state.rediscoverDevices()
                    return "\(state.devices.count) device(s) found"
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

    // MARK: - About

    private var aboutView: some View {
        ScrollView {
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
                    if easterEggTaps >= 5 { showEasterEgg = true; easterEggTaps = 0 }
                }

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

                Text("Changelog")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(liveChangelog ?? appChangelog)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)

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
        .alert("You found it!", isPresented: $showEasterEgg) {
            Button("OK") {}
        } message: {
            Text("Congratulations! You clicked the logo 5 times.\n\nYou are now an honorary HDHomeRun power user. Your tuner count has been increased by zero.")
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

private struct WindowCloseInterceptor: NSViewRepresentable {
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
