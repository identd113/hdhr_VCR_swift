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
    case about         = "About"

    var icon: String {
        switch self {
        case .general:       return "gear"
        case .recording:     return "record.circle"
        case .guide:         return "tv"
        case .notifications: return "bell.badge"
        case .advanced:      return "terminal"
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
    @State private var easterEggTaps = 0
    @State private var showEasterEgg = false

    private var isDirty: Bool { draft != state.config }

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
                    Button("Discard") { draft = state.config }
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Save") { applyAndSave() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isDirty)
                    .keyboardShortcut("s", modifiers: .command)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 560, height: 520)
        .background(WindowCloseInterceptor(isDirty: isDirty, onSave: applyAndSave))
        .onAppear { draft = state.config }
    }

    private func applyAndSave() {
        let intervalChanged = draft.Idle_timer_interval != state.config.Idle_timer_interval
        state.config = draft
        state.saveConfig()
        if intervalChanged { state.startTimer() }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selection ?? .general {
        case .general:       generalView
        case .recording:     recordingView
        case .guide:         guideView
        case .notifications: notificationsView
        case .advanced:      advancedView
        case .about:         aboutView
        }
    }

    // MARK: - General

    private var generalView: some View {
        Form {
            Section("System") {
                Toggle("Launch at Login", isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { enable in
                        do {
                            if enable { try SMAppService.mainApp.register() }
                            else       { try SMAppService.mainApp.unregister() }
                        } catch {
                            print("[Settings] Login item: \(error)")
                        }
                    }
                ))
            }

            Section("Add Show Method") {
                ForEach(AddShowMode.allCases, id: \.self) { mode in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: addShowMode == mode ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(addShowMode == mode ? Color.accentColor : .secondary)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.label).fontWeight(.medium)
                            Text(mode.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { addShowMode = mode }
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
                        if !defaultSaveDirectory.isEmpty {
                            Button("Reset") { defaultSaveDirectory = "" }.foregroundStyle(.secondary)
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

    // MARK: - About

    private var aboutView: some View {
        ScrollView {
            VStack(spacing: 20) {
                AsyncImage(url: URL(string: "https://raw.githubusercontent.com/identd113/hdhr_VCR-AS/main/app.jpg")) { img in
                    img.resizable().aspectRatio(contentMode: .fit).cornerRadius(12)
                } placeholder: {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 80)).foregroundStyle(.secondary)
                }
                .frame(width: 180, height: 180)
                .onTapGesture {
                    easterEggTaps += 1
                    if easterEggTaps >= 5 { showEasterEgg = true; easterEggTaps = 0 }
                }

                Text("hdhr_VCR").font(.largeTitle).bold()
                Text("Version 1.0 — Swift/SwiftUI rewrite")
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

                Link("View on GitHub",
                     destination: URL(string: "https://github.com/identd113/hdhr_VCR_swift")!)
                    .buttonStyle(.bordered)
            }
            .padding()
        }
        .navigationTitle("About")
        .alert("You found it!", isPresented: $showEasterEgg) {
            Button("OK") {}
        } message: {
            Text("Congratulations! You clicked the logo 5 times.\n\nYou are now an honorary HDHomeRun power user. Your tuner count has been increased by zero.")
        }
    }

    // MARK: - Helpers

    private var saveDirLabel: String {
        if !defaultSaveDirectory.isEmpty {
            return (defaultSaveDirectory as NSString).lastPathComponent
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
        if panel.runModal() == .OK, let url = panel.url { defaultSaveDirectory = url.path }
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
