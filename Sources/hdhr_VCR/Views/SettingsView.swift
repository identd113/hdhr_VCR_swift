import SwiftUI
import ServiceManagement

private enum SettingsCategory: String, CaseIterable, Identifiable {
    var id: String { rawValue }
    case general       = "General"
    case recording     = "Recording"
    case guide         = "Guide"
    case notifications = "Notifications"
    case advanced      = "Advanced"

    var icon: String {
        switch self {
        case .general:       return "gear"
        case .recording:     return "record.circle"
        case .guide:         return "tv"
        case .notifications: return "bell.badge"
        case .advanced:      return "terminal"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @AppStorage("addShowMode") private var addShowMode: AddShowMode = .menu
    @AppStorage("defaultSaveDirectory") private var defaultSaveDirectory: String = ""
    @State private var selection: SettingsCategory? = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsCategory.allCases, selection: $selection) { cat in
                Label(cat.rawValue, systemImage: cat.icon)
                    .tag(cat)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 200)
        } detail: {
            detailContent
        }
        .frame(width: 560, height: 440)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selection ?? .general {
        case .general:       generalView
        case .recording:     recordingView
        case .guide:         guideView
        case .notifications: notificationsView
        case .advanced:      advancedView
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

                Picker("Default transcode", selection: Binding(
                    get: { state.config.Default_transcode },
                    set: { state.config.Default_transcode = $0; state.saveConfig() }
                )) {
                    Text("None").tag("none")
                    Text("Heavy").tag("heavy")
                    Text("Mobile").tag("mobile")
                    Text("Internet 720").tag("internet720")
                }

                Stepper(
                    "Min free disk: \(state.config.Min_disk_free_gb, specifier: "%.0f") GB",
                    value: Binding(
                        get: { state.config.Min_disk_free_gb },
                        set: { state.config.Min_disk_free_gb = $0; state.saveConfig() }
                    ),
                    in: 1...100, step: 1
                )

                Stepper(
                    "Pause after \(state.config.Fail_count_setting) failure(s)",
                    value: Binding(
                        get: { state.config.Fail_count_setting },
                        set: { state.config.Fail_count_setting = $0; state.saveConfig() }
                    ),
                    in: 1...10
                )
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
                    "Show next \(state.config.GuideHours) hours",
                    value: Binding(
                        get: { state.config.GuideHours },
                        set: { state.config.GuideHours = $0; state.saveConfig() }
                    ),
                    in: 1...48
                )
                Stepper(
                    "Series scan retry: \(state.config.Series_scan_retry_hours) hr",
                    value: Binding(
                        get: { state.config.Series_scan_retry_hours },
                        set: { state.config.Series_scan_retry_hours = $0; state.saveConfig() }
                    ),
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
                    "Up Next: \(Int(state.config.Notify_upnext)) min before",
                    value: Binding(
                        get: { Int(state.config.Notify_upnext) },
                        set: { state.config.Notify_upnext = Double($0); state.saveConfig() }
                    ),
                    in: 5...120, step: 5
                )
                Stepper(
                    "Recording alert: \(Int(state.config.Notify_recording)) min before",
                    value: Binding(
                        get: { Int(state.config.Notify_recording) },
                        set: { state.config.Notify_recording = Double($0); state.saveConfig() }
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
                    "Idle check: every \(state.config.Idle_timer_interval) sec",
                    value: Binding(
                        get: { state.config.Idle_timer_interval },
                        set: { state.config.Idle_timer_interval = $0; state.saveConfig(); state.startTimer() }
                    ),
                    in: 5...60, step: 5
                )
            }

            Section("Logging") {
                Toggle("Verbose curl logging", isOn: Binding(
                    get: { state.config.Verbose_curl },
                    set: { state.config.Verbose_curl = $0; state.saveConfig() }
                ))
                if state.config.Verbose_curl {
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
