import SwiftUI
import AppKit

// Shown once, automatically, on first launch (see hdhr_VCRApp.swift's openFirstRunWizardIfNeeded());
// re-openable any time via Settings → Maintenance → "Reset First-Run Setup". Every field defaults
// to the CURRENT config value (see loadCurrentValuesIfNeeded()), not a hardcoded factory default, so
// re-running this later is a "review what's set" flow, not a reset-to-factory dialog.
struct FirstRunWizardView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    // Plain local @State, NOT @AppStorage — every other field here only commits on Finish (see
    // finish()/onDisappear below), and binding this directly to UserDefaults would silently break
    // that: Choose…/Reset would persist immediately regardless of Escape/close-without-Finish.
    // Written to the same UserDefaults key AddShowView/SettingsView already use for this (see
    // AppState.defaultSaveDir's fallback chain: UserDefaults → Hdhr_setup_folder → localFallbackDir)
    // only inside finish(), same as every other field.
    @State private var saveFolder: String = ""

    enum Step: Int { case recordingDefaults, notificationTiming }
    @State private var step: Step = .recordingDefaults
    // Tracks slide direction: true = animating forward (Next), false = animating backward (Back).
    // Set immediately before the withAnimation block that changes `step`, in the same action
    // closure, so the transition the next render picks up already reflects the right direction.
    @State private var goingForward = true

    @State private var transcode: String = "none"
    @State private var minFreeDiskGB: Double = 30.0
    @State private var failThreshold: Int = 3
    @State private var upNextMinutes: Double = 35.0
    @State private var recordingSoonMinutes: Double = 15.5

    @State private var hasLoadedInitialValues = false
    // Guards onDisappear's fallback save so Finish's own save isn't redundantly repeated.
    @State private var hasFinished = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                ForEach([Step.recordingDefaults, .notificationTiming], id: \.self) { s in
                    Circle().fill(s == step ? Color.accentColor : .secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel({
                switch step {
                case .recordingDefaults:  return "Step 1 of 2: Recording Defaults"
                case .notificationTiming: return "Step 2 of 2: Notification Timing"
                }
            }())
            .padding(.horizontal).padding(.top, 12)

            Divider().padding(.top, 8)

            ZStack {
                switch step {
                case .recordingDefaults:
                    recordingDefaultsScreen
                        .transition(slideTransition)
                        .id(Step.recordingDefaults)
                case .notificationTiming:
                    notificationTimingScreen
                        .transition(slideTransition)
                        .id(Step.notificationTiming)
                }
            }
            .clipped()

            Divider()
            HStack {
                if step == .notificationTiming {
                    Button("Back") { goBack() }
                }
                Spacer()
                if step == .recordingDefaults {
                    Button("Next") { goNext() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Finish") { finish() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
        .frame(width: 480, height: 460)
        .onAppear { loadCurrentValuesIfNeeded() }
        // The wizard window is single-instance — if Settings' "Reset First-Run Setup" reopens it
        // while it's already alive in the background, openWindow(id:) just refocuses it without
        // re-running onAppear (see hdhr_VCRApp.swift's own comment on this), so re-load fresh
        // values whenever the flag transitions true → false (i.e. a reset just happened).
        .onChange(of: state.config.First_run_wizard_shown) { oldValue, newValue in
            if oldValue && !newValue {
                hasLoadedInitialValues = false
                hasFinished = false
                step = .recordingDefaults
                loadCurrentValuesIfNeeded()
            }
        }
        .onExitCommand { dismiss() }
        .onDisappear {
            // Closing by any means (Finish, Escape, red-close-button) counts as "dismissed" —
            // otherwise the wizard reappears every launch and the donation nag stays suppressed
            // forever. finish() already saved, so only the fallback case needs to save here.
            guard !hasFinished else { return }
            state.config.First_run_wizard_shown = true
            state.saveConfig()
        }
    }

    // MARK: - Screens

    private var recordingDefaultsScreen: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recording Defaults").font(.headline)
                    Text("These control where and how new recordings are saved. You can change any of this later in Settings → Recording.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent {
                    HStack {
                        Text(saveFolderLabel).foregroundStyle(.secondary)
                        Button("Choose…") { chooseFolder() }
                        if !saveFolder.isEmpty {
                            Button("Reset") { saveFolder = "" }.foregroundStyle(.secondary)
                        }
                    }
                } label: {
                    HStack { Text("Default folder"); InfoButton("Where recordings are saved. Falls back to ~/Movies/hdhr_videos when not set.") }
                }

                Picker(selection: $transcode) {
                    Text("None").tag("none")
                    Text("Heavy").tag("heavy")
                    Text("Mobile").tag("mobile")
                    Text("Internet 720").tag("internet720")
                } label: {
                    HStack { Text("Default transcode"); InfoButton("Applied to all new shows. None records the raw MPEG-2 stream — best quality, no re-encoding overhead. Not all tuner models support transcoding — if a recording fails immediately after picking a profile, switch back to None.") }
                }

                Stepper(value: $minFreeDiskGB, in: 1...100, step: 1) {
                    HStack { Text("Min free disk: \(minFreeDiskGB, specifier: "%.0f") GB"); InfoButton("Recordings are skipped when free space on the save drive drops below this threshold.") }
                }

                Stepper(value: $failThreshold, in: 1...10) {
                    HStack { Text("Pause after \(failThreshold) failure(s)"); InfoButton("A show is automatically paused after this many consecutive failures. Restore it via Maintenance → Reactivate Paused Shows.") }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var notificationTimingScreen: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notification Timing").font(.headline)
                    Text("How much of a heads-up you get before a show is about to record. You can change this later in Settings → Notifications.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Stepper(value: Binding(get: { Int(upNextMinutes) }, set: { upNextMinutes = Double($0) }), in: 5...120, step: 5) {
                    HStack { Text("Up Next: \(Int(upNextMinutes)) min before"); InfoButton("Early heads-up notification sent this many minutes before a show's scheduled start time.") }
                }
                Stepper(value: Binding(get: { Int(recordingSoonMinutes) }, set: { recordingSoonMinutes = Double($0) }), in: 1...60) {
                    HStack { Text("Recording alert: \(Int(recordingSoonMinutes)) min before"); InfoButton("A second, closer notification just before recording begins — set lower than Up Next so both fire in order.") }
                }
                if recordingSoonMinutes >= upNextMinutes {
                    Label("Recording alert fires at or after Up Next — the Up Next notification won't appear first.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Navigation

    private var slideTransition: AnyTransition {
        goingForward
            ? .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                           removal:   .move(edge: .leading).combined(with: .opacity))
            : .asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                           removal:   .move(edge: .trailing).combined(with: .opacity))
    }

    private func goNext() {
        goingForward = true
        withAnimation(.easeInOut(duration: 0.25)) { step = .notificationTiming }
    }

    private func goBack() {
        goingForward = false
        withAnimation(.easeInOut(duration: 0.25)) { step = .recordingDefaults }
    }

    // MARK: - Value loading / commit

    private func loadCurrentValuesIfNeeded() {
        guard !hasLoadedInitialValues else { return }
        hasLoadedInitialValues = true
        transcode            = state.config.Default_transcode
        minFreeDiskGB         = state.config.Min_disk_free_gb
        failThreshold         = state.config.Fail_count_setting
        upNextMinutes         = state.config.Notify_upnext
        recordingSoonMinutes  = state.config.Notify_recording
        saveFolder            = UserDefaults.standard.string(forKey: "defaultSaveDirectory")
            ?? (state.config.Hdhr_setup_folder.isEmpty ? "" : state.config.Hdhr_setup_folder)
    }

    private func finish() {
        hasFinished = true
        UserDefaults.standard.set(saveFolder, forKey: "defaultSaveDirectory")
        state.config.Default_transcode      = transcode
        state.config.Min_disk_free_gb       = minFreeDiskGB
        state.config.Fail_count_setting     = failThreshold
        state.config.Notify_upnext          = upNextMinutes
        state.config.Notify_recording       = recordingSoonMinutes
        state.config.First_run_wizard_shown = true
        state.saveConfig()
        dismiss()
    }

    private var saveFolderLabel: String {
        saveFolder.isEmpty ? "hdhr_videos (default)" : (saveFolder as NSString).lastPathComponent
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = state.defaultSaveDir
        if panel.runModal() == .OK, let url = panel.url { saveFolder = url.path }
    }
}
