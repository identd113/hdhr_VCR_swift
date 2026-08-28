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

    // Local Network permission status — see checkNetworkAccessIfNeeded() below. macOS only shows
    // its Local Network permission alert once discovery/lineup traffic actually happens, and
    // AppState's own launch-time discovery (hdhr_VCRApp's Task{startup()}) already fires it
    // automatically, uncoordinated with anything on screen — a user could easily miss a dialog
    // that appeared and vanished before this wizard even rendered. This section re-runs discovery
    // + a lineup fetch itself, right when Step 1 is visible, so the explanation and (if macOS
    // hasn't decided yet) the actual system prompt land together instead of the permission check
    // being an invisible background event with no correlated UI.
    private enum NetworkStatus { case checking, confirmed, notFound }
    @State private var networkStatus: NetworkStatus = .checking
    @State private var hasCheckedNetwork = false

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().opacity(0.5)

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

            Divider().opacity(0.5)
            HStack {
                if step == .notificationTiming {
                    Button("Back") { goBack() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("wizard-back")
                }
                Spacer()
                if step == .recordingDefaults {
                    Button("Next") { goNext() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("wizard-next")
                } else {
                    Button("Finish") { finish() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("wizard-finish")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        // Width only — height is deliberately NOT fixed (unlike the old 480×460), so the window
        // hugs each step's actual content instead of stretching the shorter step's Form to fill a
        // taller-than-needed frame (that mismatch used to leave a large dead gray gap below Step
        // 1's four rows). Same "fix width, let height follow content" choice DonationNagView
        // already makes for the same reason (frame(width: 400) there, no height).
        .frame(width: 460)
        // Same floating-panel chrome as DonationNagView — thickMaterial + 20pt rounded corners +
        // a faint border + drop shadow — so this reads as the same "app's own chrome" rather than
        // a bare Settings-style dialog in a hiddenTitleBar window with no material treatment.
        .background(.thickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 28, y: 14)
        .onAppear { loadCurrentValuesIfNeeded() }
        .task { await checkNetworkAccessIfNeeded() }
        // The wizard window is single-instance — if Settings' "Reset First-Run Setup" reopens it
        // while it's already alive in the background, openWindow(id:) just refocuses it without
        // re-running onAppear (see hdhr_VCRApp.swift's own comment on this), so re-load fresh
        // values whenever the flag transitions true → false (i.e. a reset just happened).
        .onChange(of: state.config.First_run_wizard_shown) { oldValue, newValue in
            if oldValue && !newValue {
                hasLoadedInitialValues = false
                hasFinished = false
                hasCheckedNetwork = false
                step = .recordingDefaults
                loadCurrentValuesIfNeeded()
                Task { await checkNetworkAccessIfNeeded() }
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

    // MARK: - Header

    // App icon + title band, matching DonationNagView's "unmistakably this app's own chrome"
    // treatment (same reasoning documented there) — plus the step-progress dots, which used to sit
    // immediately under the traffic lights with almost no breathing room.
    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                if let icon = appIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(.white.opacity(0.2), lineWidth: 1)
                        )
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Welcome to hdhrVCRplus").font(.headline)
                    Text("A few defaults before you get started.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 4) {
                ForEach([Step.recordingDefaults, .notificationTiming], id: \.self) { s in
                    Circle().fill(s == step ? Color.accentColor : .secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel({
                switch step {
                case .recordingDefaults:  return "Step 1 of 2: Recording Defaults"
                case .notificationTiming: return "Step 2 of 2: Notification Timing"
                }
            }())
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    // MARK: - Screens

    private var recordingDefaultsScreen: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 10) {
                    networkStatusIcon.frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(networkStatusTitle).font(.subheadline).bold()
                        Text(networkStatusDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if networkStatus == .notFound {
                        Button("Open Privacy Settings") { openPrivacySettings() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityIdentifier("wizard-open-privacy-settings")
                    }
                }
                .padding(.vertical, 2)
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recording Defaults").font(.headline)
                    Text("These control where and how new recordings are saved. You can change any of this later in Settings → Recording.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                RecordingDefaultsFields(
                    folderLabel: saveFolderLabel,
                    onChooseFolder: { chooseFolder() },
                    onResetFolder: saveFolder.isEmpty ? nil : { saveFolder = "" },
                    transcode: $transcode,
                    minFreeDiskGB: $minFreeDiskGB,
                    failThreshold: $failThreshold,
                    idPrefix: "wizard-recording"
                )
            }
        }
        .formStyle(.grouped)
        // Lets the panel's own .thickMaterial show through instead of the Form's default opaque
        // grouped-list background — without this the Form renders as a separate flat card nested
        // inside the rounded material panel rather than reading as one continuous surface.
        .scrollContentBackground(.hidden)
        // Form is List-backed and defaults to claiming more vertical space than its rows actually
        // need in this fixed-width/content-height window — without this it leaves a visible gap
        // below the last row instead of hugging its own content.
        .fixedSize(horizontal: false, vertical: true)
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
        .scrollContentBackground(.hidden)
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

    // MARK: - Local Network permission

    // Actively (re)runs discovery + a lineup fetch right when the wizard is on screen, instead of
    // relying purely on AppState's own launch-time discovery — see the @State declarations above
    // for why. Safe to call more than once: discoverDevices()/ensureLineupLoaded(for:) are already
    // used this way from Settings' "Rediscover Devices" button and AddShowView.
    private func checkNetworkAccessIfNeeded() async {
        guard !hasCheckedNetwork else { return }
        hasCheckedNetwork = true
        if state.config.Local_network_confirmed {
            networkStatus = .confirmed
            return
        }
        networkStatus = .checking
        await state.rediscoverDevices()
        guard !state.devices.isEmpty else {
            networkStatus = .notFound
            return
        }
        // Discovering a device's presence (mDNS/UDP) isn't itself proof of confirmed access —
        // AppState.confirmLocalNetworkAccessIfNeeded() only fires on an actual successful lineup
        // fetch (a real HTTP round trip to the device), so force that too rather than waiting for
        // the idle loop to eventually get to it on its own schedule. Concurrent, not sequential —
        // each device's fetch is independent, so a multi-tuner household shouldn't wait
        // N × latency here when max(latency) gets the same result.
        await withTaskGroup(of: Void.self) { group in
            for device in state.devices {
                group.addTask { await state.ensureLineupLoaded(for: device) }
            }
        }
        networkStatus = state.config.Local_network_confirmed ? .confirmed : .notFound
    }

    @ViewBuilder private var networkStatusIcon: some View {
        switch networkStatus {
        case .checking:
            ProgressView().controlSize(.small)
        case .confirmed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .notFound:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private var networkStatusTitle: String {
        switch networkStatus {
        case .checking:  return "Looking for your HDHomeRun tuner…"
        case .confirmed: return "Tuner found on your network"
        case .notFound:  return "No tuner found yet"
        }
    }

    private var networkStatusDetail: String {
        switch networkStatus {
        case .checking:
            return "If macOS asks for Local Network permission, click Allow — hdhrVCRplus needs it to find your tuner."
        case .confirmed:
            return "Local Network access is confirmed working."
        case .notFound:
            return "If macOS asked for Local Network permission and you clicked Don't Allow, open Privacy & Security below and turn it on for hdhrVCRplus under Local Network. Otherwise, make sure your HDHomeRun is powered on and on the same network."
        }
    }

    // The `?Privacy_LocalNetwork` anchor that's supposed to deep-link straight to the Local
    // Network row (the pattern many apps use) was tested live during development and did NOT
    // land there on this macOS version — it only opens the general Privacy & Security pane, same
    // as the plain com.apple.preference.security URL with no anchor at all. Button label/copy
    // reflects that honestly (asks the user to navigate the last step themselves) rather than
    // promising a jump that doesn't actually happen.
    private func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") else { return }
        NSWorkspace.shared.open(url)
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
