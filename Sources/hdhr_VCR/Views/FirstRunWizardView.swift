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

    enum Step: Int { case intro, recordingDefaults, notificationTiming }
    // Resting default is .recordingDefaults, NOT .intro — the splash is only ever entered
    // deliberately (see the .onAppear/.onChange below), so every "step starts at
    // .recordingDefaults" assumption elsewhere (sizing, header, nav bar) stays true by default,
    // and reduce-motion users never instantiate IntroSplashOverlay at all.
    @State private var step: Step = .recordingDefaults
    // Tracks slide direction: true = animating forward (Next), false = animating backward (Back).
    // Set immediately before the withAnimation block that changes `step`, in the same action
    // closure, so the transition the next render picks up already reflects the right direction.
    @State private var goingForward = true

    // Guards the one-time intro splash so it plays exactly once per wizard-open (reset alongside
    // hasLoadedInitialValues/hasCheckedNetwork below). Reduce Motion skips the splash entirely — a
    // different code path, not a faster version of the same one.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasPlayedIntro = false
    // Finish-flourish: a one-shot glow pulse behind the header icon (keyframeAnimator, triggered
    // by incrementing this counter) + button-label morph, same visual language as DonationNagView's
    // own appear-glow. A trigger counter — not a plain "flourishing" Bool — because the glow must
    // start AND end hidden with a visible pulse in between; a two-state withAnimation toggle can
    // only tween between its two endpoints; it can't rest at "hidden" both before and after while
    // also being visible mid-flourish. This also means there's nothing to reset in
    // resetForFreshRun() below — the animator's own initialValue is always the at-rest (hidden)
    // state until the next trigger fires.
    @State private var finishGlowTrigger = 0
    @State private var finishTask: Task<Void, Never>?

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

    // Presentational device-aware view of the tri-state above, for TunerDiscoveryCard — this is
    // the only thing that changed about network detection; checkNetworkAccessIfNeeded()'s actual
    // discovery/confirmation logic below is untouched. Falls back to a deviceless .foundSingle
    // (identity line just doesn't render) if `confirmed` is true but state.devices hasn't
    // populated yet (e.g. Local_network_confirmed was already persisted from a prior session and
    // AppState's own startup() discovery hasn't finished this launch) — still an honest "found"
    // state, just without device details available yet.
    private var discoveryStatus: TunerDiscoveryStatus {
        switch networkStatus {
        case .checking: return TunerDiscoveryStatus(kind: .checking)
        case .notFound: return TunerDiscoveryStatus(kind: .notFound)
        case .confirmed:
            let counts = Dictionary(uniqueKeysWithValues: state.devices.map {
                ($0.DeviceID, state.lineups[$0.DeviceID]?.count ?? 0)
            })
            return TunerDiscoveryStatus(kind: state.devices.count > 1 ? .foundMultiple : .foundSingle,
                                         devices: state.devices, channelCounts: counts)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if step != .intro {
                header
                Divider().opacity(0.5)
            }

            ZStack {
                switch step {
                case .intro:
                    // Real content is the .overlay below (needs to render unclipped past this
                    // VStack's own bounds) — this branch exists only so the switch stays
                    // exhaustive and reserves no space of its own.
                    Color.clear
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

            if step != .intro {
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
                        finishButton
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
        }
        // Width only normally — height follows content (see the old comment this replaces: the
        // old fixed 460×460 left a dead gap below Step 1's rows). During .intro the frame grows to
        // a fixed 640×480 "stage" so the splash's tiles have real room to fan out and fly off
        // before the panel shrinks back down on hand-off — animated in the same withAnimation
        // transaction as the step change (goNext()/goBack() already animate step this way; the
        // intro hand-off in finishIntro() below does the same).
        .frame(width: step == .intro ? 640 : 460, height: step == .intro ? 480 : nil)
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
        // Splash tiles live in a SECOND overlay, attached after the shadow/clip chain above rather
        // than inside the clipped VStack — .overlay content is unclipped by default, so tiles can
        // fly past the panel's own rounded-rect edges within the 640×480 stage. See
        // docs/FirstRunWizardView.md's "Intro Splash" section.
        .overlay {
            if step == .intro {
                IntroSplashOverlay(onFinished: finishIntro)
            }
        }
        .onAppear {
            // This single-instance Window's @State persists across even a FULL close (Escape/red
            // button → dismiss()) — reopening later via openWindow(id:) still refires onAppear
            // (a genuine close→open transition), but with stale flags from the previous run, not
            // freshly-initialized ones. state.config.First_run_wizard_shown being false is the
            // reliable "this appearance needs a fresh run" signal (true first launch OR a reopen
            // after a full close) — the onChange below only catches the OTHER case (Settings'
            // reset firing while this window is already open/visible in the background, per
            // hdhr_VCRApp.swift's own comment on why openWindow(id:) doesn't refire onAppear
            // there). Both paths call the same reset; doing it twice in some edge case is harmless.
            if !state.config.First_run_wizard_shown {
                resetForFreshRun()
            }
            loadCurrentValuesIfNeeded()
            playIntroIfNeeded()
        }
        .task { await checkNetworkAccessIfNeeded() }
        .onChange(of: state.config.First_run_wizard_shown) { oldValue, newValue in
            if oldValue && !newValue {
                resetForFreshRun()
                loadCurrentValuesIfNeeded()
                playIntroIfNeeded()
                Task { await checkNetworkAccessIfNeeded() }
            }
        }
        .onExitCommand { dismiss() }
        .onDisappear {
            finishTask?.cancel()
            // Closing by any means (Finish, Escape, red-close-button) counts as "dismissed" —
            // otherwise the wizard reappears every launch and the donation nag stays suppressed
            // forever. finish() already saved, so only the fallback case needs to save here.
            guard !hasFinished else { return }
            state.config.First_run_wizard_shown = true
            state.saveConfig()
        }
    }

    // MARK: - Intro splash

    // Shared by both onAppear and onChange above — see onAppear's own comment for why both call
    // sites are needed (they cover complementary reopen scenarios).
    private func resetForFreshRun() {
        hasLoadedInitialValues = false
        hasFinished = false
        hasCheckedNetwork = false
        hasPlayedIntro = false
        step = .recordingDefaults
    }

    // Entered deliberately (never the resting default — see `step`'s own comment). Reduce Motion
    // skips straight past: a different code path, not a faster version of the same one.
    private func playIntroIfNeeded() {
        guard !hasPlayedIntro, !reduceMotion else { return }
        hasPlayedIntro = true
        withAnimation(.easeInOut(duration: 0.3)) { step = .intro }
    }

    // Splash's own hand-off — identical shape to goNext(): same withAnimation, same target step,
    // so the panel's shrink-back-down and Step 1's slide-in ride the one transition mechanism the
    // whole wizard already uses, not a second bespoke one.
    private func finishIntro() {
        goingForward = true
        withAnimation(.easeInOut(duration: 0.25)) { step = .recordingDefaults }
    }

    // MARK: - Header

    // App icon + title band, matching DonationNagView's "unmistakably this app's own chrome"
    // treatment (same reasoning documented there) — plus the step-progress dots, which used to sit
    // immediately under the traffic lights with almost no breathing room.
    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                if let icon = appIconImage {
                    ZStack {
                        // Finish-flourish glow — same RadialGradient DonationNagView's own header
                        // uses on appear, reused here on completion instead: a small, consistent
                        // "something nice just happened" language for this app's chrome. At rest
                        // (before finishGlowTrigger ever fires) this renders at its keyframe
                        // initialValue — hidden (opacity 0) — so nothing shows behind the icon
                        // during Steps 1/2; finish() increments the trigger to pop it in and fade
                        // it back out again.
                        Circle()
                            .fill(RadialGradient(colors: [.orange.opacity(0.55), .clear],
                                                  center: .center, startRadius: 1, endRadius: 26))
                            .frame(width: 52, height: 52)
                            .keyframeAnimator(initialValue: FinishGlowValues(), trigger: finishGlowTrigger) { view, v in
                                view.scaleEffect(v.scale).opacity(v.opacity)
                            } keyframes: { _ in
                                KeyframeTrack(\.scale) { CubicKeyframe(1.3, duration: 0.35) }
                                KeyframeTrack(\.opacity) {
                                    LinearKeyframe(0.9, duration: 0.05)
                                    LinearKeyframe(0.0, duration: 0.3)
                                }
                            }
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
                case .intro:              return ""   // header isn't rendered during .intro
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
                TunerDiscoveryCard(status: discoveryStatus, onOpenPrivacySettings: openPrivacySettings)
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

    // Label morphs Finish → checkmark during the flourish delay (finish()'s finishTask) instead
    // of just disappearing with the window — a small, cheap "yes, that worked" confirmation.
    private var finishButton: some View {
        Button(action: finish) {
            if hasFinished {
                Image(systemName: "checkmark")
                    .transition(.scale.combined(with: .opacity))
            } else {
                Text("Finish")
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(hasFinished)
        .accessibilityIdentifier("wizard-finish")
        .animation(.easeOut(duration: 0.18), value: hasFinished)
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
        guard !hasFinished else { return }   // no-op on a double-click during the flourish delay
        hasFinished = true
        UserDefaults.standard.set(saveFolder, forKey: "defaultSaveDirectory")
        state.config.Default_transcode      = transcode
        state.config.Min_disk_free_gb       = minFreeDiskGB
        state.config.Fail_count_setting     = failThreshold
        state.config.Notify_upnext          = upNextMinutes
        state.config.Notify_recording       = recordingSoonMinutes
        state.config.First_run_wizard_shown = true
        state.saveConfig()
        // Flourish, then dismiss — 380ms total, well under a ~500-700ms ceiling. .onExitCommand
        // and the red-close-button both call dismiss() directly and immediately regardless of
        // this pending task, so Escape mid-flourish still works exactly as before.
        finishGlowTrigger += 1
        finishTask = Task {
            try? await Task.sleep(for: .milliseconds(380))
            guard !Task.isCancelled else { return }
            dismiss()
        }
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

// File-scope per StarburstBadge.swift's own note: @KeyframesBuilder type inference fails on a
// type nested inside the view. Starts hidden (opacity 0) — the finish-flourish keyframeAnimator's
// own initialValue/rest state — and is driven from there by finishGlowTrigger.
private struct FinishGlowValues: Animatable {
    var scale: CGFloat = 0.7
    var opacity: Double = 0

    var animatableData: AnimatablePair<CGFloat, Double> {
        get { AnimatablePair(scale, opacity) }
        set { scale = newValue.first; opacity = newValue.second }
    }
}
