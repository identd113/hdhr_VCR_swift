import SwiftUI
import AppKit

// Shown once, automatically, on first launch (see hdhr_VCRApp.swift's openFirstRunWizardIfNeeded());
// re-openable any time via Settings → Maintenance → "Reset First-Run Setup". Every field defaults
// to the CURRENT config value (see loadCurrentValuesIfNeeded()), not a hardcoded factory default, so
// re-running this later is a "review what's set" flow, not a reset-to-factory dialog.
struct FirstRunWizardView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    /// Non-nil when this wizard is a card inside the launch splash's window (first run): closes the card, and the window
    /// setup below is skipped — that window belongs to the splash.
    @Environment(\.embeddedCardClose) private var embeddedClose
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Plain local @State, NOT @AppStorage — every other field here only commits on Finish (see
    // finish()/onDisappear below), and binding this directly to UserDefaults would silently break
    // that: Choose…/Reset would persist immediately regardless of Escape/close-without-Finish.
    // Written to the same UserDefaults key AddShowView/SettingsView already use for this (see
    // AppState.defaultSaveDir's fallback chain: UserDefaults → Hdhr_setup_folder → localFallbackDir)
    // only inside finish(), same as every other field.
    @State private var saveFolder: String = ""

    enum Step: Int, CaseIterable { case recordingDefaults, airChannels, vlcRequired, webLAN, terminalGuide, recordingRelay, notificationTiming }
    @State private var step: Step = .recordingDefaults
    // Tracks slide direction: true = animating forward (Next), false = animating backward (Back).
    // Set immediately before the withAnimation block that changes `step`, in the same action
    // closure, so the transition the next render picks up already reflects the right direction.
    @State private var goingForward = true

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

    @State private var sharingEnabled: Bool = false
    @State private var terminalGuideEnabled: Bool = false
    @State private var relayEnabled: Bool = false
    @State private var airScanHour: Int = 3   // hour of the daily air rescan, -1 = never (saved on Finish)
    @State private var transcode: String = "none"
    @State private var minFreeDiskGB: Double = 30.0
    @State private var failThreshold: Int = 3
    @State private var timeMachineExcludeMode: String = "off"
    @State private var upNextMinutes: Double = 35.0
    @State private var recordingSoonMinutes: Double = 15.5

    // VLC-requirement step (added 2026-09-12, alongside removing the external "Open in VLC"
    // feature) — no config to persist here, purely a live install-status check + install helper,
    // so unlike the @State fields above this has nothing to save in finish()/loadCurrentValuesIfNeeded().
    // Re-checked in .onAppear/via the "Check Again" button, not cached forever, since installing
    // VLC is exactly the kind of thing that can happen mid-wizard (switch to Terminal, come back).
    @State private var vlcInstalled: Bool = false
    @State private var vlcInstallCopyFeedback: String?

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
            // recordableDevices — a discovered virtual relay device (another instance's in-progress
            // recording, VirtualTunerService.swift) isn't a real tuner this brand-new install could
            // ever record on; counting/showing it here would misreport "found a tuner" during
            // first-run setup for a machine that may have zero real ones. Local Network access can
            // come back "confirmed" purely from successfully reaching a relay's own /lineup.json
            // (AppState.confirmLocalNetworkAccessIfNeeded fires on ANY successful lineup fetch —
            // legitimate proof the permission works, even though it says nothing about whether this
            // specific machine has any real tuner) — .notFound here isn't quite right either (the
            // network access truly IS fine), but it's a closer match than falsely claiming a single
            // real tuner was found with nothing to show for it.
            guard !state.recordableDevices.isEmpty else {
                return TunerDiscoveryStatus(kind: .notFound)
            }
            let counts = Dictionary(firstWinsOf: state.recordableDevices.map {
                ($0.DeviceID, state.lineups[$0.DeviceID]?.count ?? 0)
            })
            return TunerDiscoveryStatus(kind: state.recordableDevices.count > 1 ? .foundMultiple : .foundSingle,
                                         devices: state.recordableDevices, channelCounts: counts)
        }
    }

    static let panelWidth: CGFloat = LaunchCard.width
    static let headerIconSize: CGFloat = 44

    /// Close the wizard: the splash's card when embedded, else its own window.
    private func closeWizard() { if let embeddedClose { embeddedClose() } else { dismiss() } }

    /// Fixed window height for every step: tall enough for the longest page, never taller than the screen.
    /// A fixed (bounded) height — not `nil` — is what makes the ScrollView below safe; an unbounded ideal height inside
    /// `.windowResizability(.contentSize)` is what crashed the Recording FEED step before. Header and Back/Next sit
    /// outside the scroll view, so the Next button can never be pushed off the bottom.
    private var stepHeight: CGFloat {
        embeddedClose != nil ? LaunchCard.designHeight : LaunchCard.height
    }

    @ViewBuilder private func stepScroll<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        ScrollView { content() }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)

            stepScroll {
            ZStack {
                switch step {
                case .recordingDefaults:
                    recordingDefaultsScreen
                        .transition(slideTransition)
                        .id(Step.recordingDefaults)
                case .airChannels:
                    airChannelsScreen
                        .transition(slideTransition)
                        .id(Step.airChannels)
                case .vlcRequired:
                    vlcRequiredScreen
                        .transition(slideTransition)
                        .id(Step.vlcRequired)
                case .webLAN:
                    webLANScreen
                        .transition(slideTransition)
                        .id(Step.webLAN)
                case .terminalGuide:
                    terminalGuideScreen
                        .transition(slideTransition)
                        .id(Step.terminalGuide)
                case .recordingRelay:
                    recordingRelayScreen
                        .transition(slideTransition)
                        .id(Step.recordingRelay)
                case .notificationTiming:
                    notificationTimingScreen
                        .transition(slideTransition)
                        .id(Step.notificationTiming)
                }
            }
            }
            .clipped()

            Divider().opacity(0.5)
            HStack {
                if step != .recordingDefaults {
                    Button("Back") { goBack() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("wizard-back")
                }
                Spacer()
                if step != .notificationTiming {
                    Button("Next") { goNext() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("wizard-next")
                } else {
                    finishButton
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        // Fixed step height (a bounded frame — see stepHeight) and a fixed width (`LaunchCard`, shared by every launch card).
        .frame(width: Self.panelWidth, height: stepHeight)
        // Re-centers the wizard's own window whenever the visible step changes. Height genuinely
        // varies per step by design, but `.windowResizability(.contentSize)` only resizes the
        // window -- it doesn't reposition it, and AppKit's default resize keeps the window's top edge
        // fixed and grows the bottom edge downward, which can push the Back/Next row off-screen.
        // Centering after every step change keeps any extra height growing symmetrically. The
        // window is also made see-through (clear, non-opaque) so the rounded dark panel below floats
        // like the launch splash does instead of sitting on a rectangular system window background.
        // See Views/WindowAction.swift for the shared NSViewRepresentable idiom.
        .background(WindowAction(trigger: step) { w in
            guard embeddedClose == nil else { return }
            // Pin the window to the size this step asks for. Left to `.windowResizability(.contentSize)` alone, a window
            // AppKit restored at an earlier (shorter) frame kept it — the Back/Next row sat below the bottom edge.
            w.setContentSize(NSSize(width: Self.panelWidth, height: stepHeight))
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = true
            w.center()
        })
        // The launch splash's look: always dark, a soft warm glow from the logo corner and a vignette, white type —
        // rounded 20pt panel with a faint border and the same drop shadow DonationNagView uses.
        // In its own window the wizard draws the dark panel; as a launch card the splash's persistent panel is already there.
        .launchCardChrome(applied: embeddedClose == nil)
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
        }
        .task { await checkNetworkAccessIfNeeded() }
        .onChange(of: state.config.First_run_wizard_shown) { oldValue, newValue in
            if oldValue && !newValue {
                resetForFreshRun()
                loadCurrentValuesIfNeeded()
                Task { await checkNetworkAccessIfNeeded() }
            }
        }
        .onExitCommand { closeWizard() }
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

    // MARK: - Fresh run

    // Shared by both onAppear and onChange above — see onAppear's own comment for why both call
    // sites are needed (they cover complementary reopen scenarios).
    private func resetForFreshRun() {
        hasLoadedInitialValues = false
        hasFinished = false
        hasCheckedNetwork = false
        step = .recordingDefaults
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
                                // Reduce Motion: no glow pulse at all (the circle stays at its hidden rest state).
                                if reduceMotion { view.opacity(0) } else { view.scaleEffect(v.scale).opacity(v.opacity) }
                            } keyframes: { _ in
                                KeyframeTrack(\.scale) { CubicKeyframe(1.3, duration: 0.35) }
                                KeyframeTrack(\.opacity) {
                                    LinearKeyframe(0.9, duration: 0.05)
                                    LinearKeyframe(0.0, duration: 0.3)
                                }
                            }
                        // Same logo treatment as the launch splash (soft shadow, rounded corners).
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: Self.headerIconSize, height: Self.headerIconSize)
                            .clipShape(RoundedRectangle(cornerRadius: Self.headerIconSize * 0.2, style: .continuous))
                            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                            .accessibilityHidden(true)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Welcome to hdhrVCRplus").font(.system(size: 20, weight: .bold, design: .rounded))
                    Text("A few defaults before you get started.")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.8))
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 4) {
                ForEach(orderedSteps, id: \.self) { s in
                    Circle().fill(s == step ? Color.accentColor : .secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            // Derived from orderedSteps rather than a hardcoded "Step N of 5" per case, so adding,
            // removing, or reordering a wizard step can't leave this announcement silently stale
            // the way a hand-maintained switch could.
            .accessibilityLabel({
                let n = (orderedSteps.firstIndex(of: step) ?? 0) + 1
                return "Step \(n) of \(orderedSteps.count): \(Self.stepTitle(step))"
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
                TunerDiscoveryCard(status: discoveryStatus, onOpenPrivacySettings: openPrivacySettings,
                                   onCheckAgain: {
                                       // Reset the checked-guard and re-run discovery from scratch.
                                       hasCheckedNetwork = false
                                       networkStatus = .checking
                                       Task { await checkNetworkAccessIfNeeded(force: true) }
                                   })
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
                    timeMachineExcludeMode: $timeMachineExcludeMode,
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

    /// Step 2 (added 2026-10-21): a quick scan that reads the channel list the stations broadcast, so a backup channel list exists
    /// from day one. Optional and non-blocking; see AirChannelsCard.
    private var airChannelsScreen: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Channels from the Air").font(.headline)
                    Text("Besides the SiliconDust guide, your tuner can read the channel names and numbers that stations broadcast with their signal. It takes about three minutes, uses only idle tuners and steps aside whenever a recording or a viewer needs one. It is how the app finds stations the SiliconDust lineup is missing; they show up in the web guide as watch-only. Once it exists, it is read again once a day at the time you pick below.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                AirChannelsCard(progress: state.otaProgress)
            }
            Section {
                Picker(selection: $airScanHour) {
                    Text("Never").tag(-1)
                    ForEach(0..<24, id: \.self) { h in Text(String(format: "Daily at %02d:00", h)).tag(h) }
                } label: {
                    HStack { Text("Rescan the channel list"); InfoButton("Once a day from this hour on, on idle tuners only, the app rereads the channel list from the air. The scan steps aside whenever a recording or a viewer needs a tuner. The guide from the air is scanned only if the SiliconDust guide cannot be loaded: you are asked first, and with no answer in an hour the scan starts by itself. You can change this later in Settings → Advanced → Over-the-Air Guide.") }
                }
                .accessibilityIdentifier("wizard-air-schedule")
            }
            Section {
                Text("Using the air for guide data is a separate choice: Settings → Over the Air.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .fixedSize(horizontal: false, vertical: true)
    }

    // Step 3. Added 2026-09-12, same day the external "Open in VLC" feature (Watch_in_VLC config setting,
    // AppState.watchInVLC/watchRecordingInVLC) was removed — that removal didn't reduce the VLC
    // *dependency* at all, since the in-app player itself dynamically loads libvlc from an
    // installed VLC.app (VLCBridge.locateApp()/isAvailable, docs/VLCBridge.md) for every watching
    // feature in the app, in-app player included. Every watch-triggering surface elsewhere
    // (MenuContent, WatchNowView, SettingsView's FEED transcode picker) already dims/labels itself
    // "(Requires VLC)" via VLCBridge.shared.isAvailable/gatedLabel when VLC is missing — this step
    // is what makes that requirement visible up front, with an actual path to fix it, instead of a
    // new user discovering it only once they click a dimmed button somewhere later.
    private var vlcRequiredScreen: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("VLC Required for Watching").font(.headline)
                    Text("hdhrVCRplus uses VLC's own playback engine for everything you watch — live TV, in-progress recordings, and a FEED session from another Mac. Without VLC.app installed, those features stay visible but dimmed, labeled \"Requires VLC,\" until it's installed. Recording itself doesn't need VLC at all — only watching does.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: vlcInstalled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(vlcInstalled ? Color(NSColor.systemGreen) : Color(NSColor.systemOrange))
                        Text(vlcInstalled ? "VLC is installed." : "VLC is not installed yet.")
                            .font(.callout.bold())
                        Spacer()
                        Button("Check Again") { recheckVLCInstalled() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityIdentifier("wizard-vlc-recheck")
                    }

                    if !vlcInstalled {
                        if homebrewInstalled {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Homebrew detected — the fastest way to install VLC:")
                                    .font(.callout)
                                Button {
                                    installVLCViaHomebrew()
                                } label: {
                                    Label("Copy Install Command & Open Terminal", systemImage: "terminal")
                                }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("wizard-vlc-brew-install")
                                if let vlcInstallCopyFeedback {
                                    Text(vlcInstallCopyFeedback)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Download it directly from VideoLAN:")
                                    .font(.callout)
                                Button {
                                    NSWorkspace.shared.open(Self.vlcDownloadURL)
                                } label: {
                                    Label("Download VLC", systemImage: "arrow.down.circle")
                                }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("wizard-vlc-download")
                            }
                        }
                        Text("After installing, come back to this app — it checks automatically and will prompt you to relaunch, which is needed to actually load VLC's playback engine.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        // Re-checks every time this step becomes visible (not just once at wizard launch) — the
        // realistic flow is: land here, see "not installed," switch to Terminal/browser to install,
        // come back and click Next/Back past this step and back again (or just re-open the wizard)
        // to confirm before moving on. A one-shot check at wizard launch would never reflect that.
        .onAppear { vlcInstalled = VLCBridge.locateApp() != nil }
        // Coming back from Terminal/the browser after installing: AppState only posts a relaunch notification for a
        // fresh install, it doesn't touch this step's own state, so refresh the checklist whenever the app is re-activated.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            recheckVLCInstalled()
        }
    }

    private static let vlcDownloadURL = URL(string: "https://www.videolan.org/vlc/download-macosx.html")!

    private var homebrewInstalled: Bool {
        FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew") ||
        FileManager.default.fileExists(atPath: "/usr/local/bin/brew")
    }

    private func recheckVLCInstalled() {
        vlcInstalled = VLCBridge.locateApp() != nil
    }

    // Copies the install command to the clipboard and opens Terminal.app (via NSWorkspace, the
    // same technique SettingsView.openInTerminal already uses for the Terminal Guide feature) —
    // deliberately never Process()/AppleScript-System-Events to type or run it automatically. A
    // brew-install UI existed once and was removed entirely (2026-08-19, see docs/MAS_COMPLIANCE.md)
    // specifically because spawning `brew` via Process() is forbidden under Mac App Store
    // sandboxing; typing the command into Terminal via System Events would reopen the same class of
    // problem via the Apple Events automation entitlement instead. Copy-and-paste needs neither.
    private func installVLCViaHomebrew() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("brew install --cask vlc", forType: .string)
        if let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.open(terminalURL)
        }
        vlcInstallCopyFeedback = "Command copied — switch to Terminal, paste (⌘V), and press Return."
    }

    private var webLANScreen: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Web LAN").font(.headline)
                    Text("Reach your guide and recordings from any browser on your home network. Off by default. You can change this later in Settings → Sharing.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    WebLANDiagram()
                    Text("Turns this Mac into a small local web server — any browser on your network can view the guide and start or manage recordings, the same way you would here.")
                        .font(.callout)
                    Toggle(isOn: $sharingEnabled) {
                        HStack { Text("Enable Web LAN"); InfoButton("Local network only — no authentication, so don't expose this port to the internet.") }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var terminalGuideScreen: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Terminal Guide").font(.headline)
                    Text("A command-line version of the same guide, for browsing and recording from a terminal instead of a browser. Off by default. You can change this later in Settings → Sharing.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    TerminalTypingDiagram()
                    Text(sharingEnabled
                         ? "Connects to the same local server Web LAN just turned on — no separate listener of its own."
                         : "Uses the same server as Web LAN — turn that on first (previous step) for this to do anything.")
                        .font(.callout)
                        .foregroundStyle(sharingEnabled ? Color.primary : .secondary)
                    Toggle(isOn: $terminalGuideEnabled) {
                        HStack { Text(gatedLabel("Enable Terminal Guide", met: sharingEnabled, requirement: "Web LAN")); InfoButton("Requires Web LAN (previous step) to be on — the terminal client connects to that same local server, not a separate one.") }
                    }
                    .disabled(!sharingEnabled)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .fixedSize(horizontal: false, vertical: true)
    }

    // Was the tallest wizard step — an extra Label plus a third, separate Section just for the
    // toggle pushed it past what the other steps need, and on at least one real machine that extra
    // height crashed the app outright (see issues_resolved.md's "First-Run Wizard's Recording FEED
    // step crashed the app outright" entry for the investigation; neither a ScrollView wrapper nor
    // removing NetworkFlowDiagram's animation was the cause). Resolution: a plain Form structurally
    // matching every sibling step (ending in the same `.fixedSize(vertical: true)`), with the content
    // shortened — toggle folded into the single diagram/text Section, the "Watch-only" Label folded into
    // the toggle's InfoButton. The one ScrollView is the shared `stepScroll` wrapper in `body`, which sits
    // inside a fixed-height frame and so has a well-defined size.
    private var recordingRelayScreen: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recording FEED (Beta)").font(.headline)
                    Text("Watch a recording that's already in progress from another Mac — live, without spending a second tuner. You can change this later in Settings → Sharing. Occasional playback hiccups, and switching audio/CC tracks while watching, are known limitations still being worked on.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    NetworkFlowDiagram(
                        leftBadgeColor: Color(NSColor.systemRed),
                        leftCaption: "Recording",
                        leftCaptionSystemImage: "circle.fill",
                        rightSystemImage: "desktopcomputer",
                        rightCaption: "Watching",
                        rightCaptionSystemImage: "play.tv.fill"
                    )
                    Text("While a show is recording, this Mac briefly shows up on your home network as an extra tuner. Another Mac running this app can watch that same recording straight off disk, instead of opening a second tuner to record it again.")
                        .font(.callout)
                    Toggle(isOn: $relayEnabled) {
                        HStack { Text("Rebroadcast In-Progress Recordings"); InfoButton("Off by default. Turn this on if you'd like another Mac running this app to watch a recording already in progress. Watch-only — it can't start a new recording, on this Mac or any other, and only exists on your local network while something is actively recording. Beta: occasional playback hiccups on the watching Mac are a known limitation still being worked on.") }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
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
        // Every other step ends with this — this one was missing it (see issues_resolved.md's
        // "First-Run Wizard's Recording FEED step crashed the app outright" entry, follow-up
        // finding): without an explicit ideal vertical size, this step's height — made genuinely
        // dynamic by the conditional warning Label above, which appears/disappears as the Steppers
        // change — left this content-fitted window's height ambiguous/unstable, tripping the same
        // AppKit "Update Constraints" safety-limit crash the FEED step's own (already-fixed) bug did.
        // Confirmed present unchanged in the v2.3.0 release too (not gated behind any feature flag —
        // this is the wizard's last step, shown to everyone); also fixed on `main` directly.
        .fixedSize(horizontal: false, vertical: true)
    }

    // Label morphs Finish → checkmark during the flourish delay (finish()'s finishTask) instead
    // of just disappearing with the window — a small, cheap "yes, that worked" confirmation.
    private var finishButton: some View {
        Button(action: finish) {
            if hasFinished {
                Image(systemName: "checkmark")
                    .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                    .accessibilityLabel("Finished")
            } else {
                Text("Finish")
            }
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(hasFinished)
        .accessibilityIdentifier("wizard-finish")
        .animation(.easeOut(duration: 0.18), value: hasFinished)
    }

    // MARK: - Navigation

    private var slideTransition: AnyTransition {
        reduceMotion ? .opacity :   // Reduce Motion: cross-fade instead of sliding
        goingForward
            ? .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                           removal:   .move(edge: .leading).combined(with: .opacity))
            : .asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                           removal:   .move(edge: .trailing).combined(with: .opacity))
    }

    // Linear order every Next/Back press walks, one step at a time. Derived from Step.allCases
    // (Step is CaseIterable, added 2026-09-11) rather than a hand-typed literal parallel to the
    // case list — a hand-typed array meant a new Step case compiled cleanly (stepTitle's switch
    // and the rendering switch are both exhaustive, compiler-enforced) but could silently drop out
    // of Next/Back navigation, the progress dots, and the VoiceOver step count if this array wasn't
    // separately remembered — the exact drift class the 2026-09-05 VoiceOver "Step N of X" fix
    // closed one level up. Deriving from allCases with an opt-*out* filter instead means a new case
    // is included by default (shows up in the wizard) unless explicitly excluded here, the safer
    // failure mode.
    // Instance property (not static) so .recordingRelay can be dropped while
    // AppConfig.FEED_feature_enabled is off — the feature's master hide switch, 2026-09-10 — without
    // touching recordingRelayScreen or any of its own save logic below, so re-enabling the flag
    // brings the step straight back.
    private var orderedSteps: [Step] {
        Step.allCases.filter { step in
            switch step {
            case .recordingRelay: return state.config.FEED_feature_enabled
            default: return true
            }
        }
    }

    private static func stepTitle(_ step: Step) -> String {
        switch step {
        case .recordingDefaults:  return "Recording Defaults"
        case .airChannels:        return "Channels from the Air"
        case .vlcRequired:        return "VLC"
        case .webLAN:             return "Web LAN"
        case .terminalGuide:      return "Terminal Guide"
        case .recordingRelay:     return "Recording FEED (Beta)"
        case .notificationTiming: return "Notification Timing"
        }
    }

    private func goNext() {
        goingForward = true
        guard let i = orderedSteps.firstIndex(of: step), i + 1 < orderedSteps.count else { return }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .easeInOut(duration: 0.25)) { step = orderedSteps[i + 1] }
    }

    private func goBack() {
        goingForward = false
        guard let i = orderedSteps.firstIndex(of: step), i > 0 else { return }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .easeInOut(duration: 0.25)) { step = orderedSteps[i - 1] }
    }

    // MARK: - Local Network permission

    // Actively (re)runs discovery + a lineup fetch right when the wizard is on screen, instead of
    // relying purely on AppState's own launch-time discovery — see the @State declarations above
    // for why. Safe to call more than once: discoverDevices()/ensureLineupLoaded(for:) are already
    // used this way from Settings' "Rediscover Devices" button and AddShowView.
    private func checkNetworkAccessIfNeeded(force: Bool = false) async {
        guard !hasCheckedNetwork else { return }
        hasCheckedNetwork = true
        if state.config.Local_network_confirmed && !force {
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
        sharingEnabled        = state.config.Web_server_enabled
        terminalGuideEnabled  = state.config.Terminal_guide_enabled
        relayEnabled         = state.config.Virtual_tuner_relay_enabled
        airScanHour          = state.config.OTA_lineup_hour
        transcode            = state.config.Default_transcode
        minFreeDiskGB         = state.config.Min_disk_free_gb
        failThreshold         = state.config.Fail_count_setting
        timeMachineExcludeMode = state.config.TimeMachine_exclude_mode
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
        state.config.TimeMachine_exclude_mode = timeMachineExcludeMode
        state.config.Notify_upnext          = upNextMinutes
        state.config.Notify_recording       = recordingSoonMinutes
        let webServerChanged = sharingEnabled != state.config.Web_server_enabled
        state.config.Web_server_enabled     = sharingEnabled
        // The terminal client rides on the Web LAN server, so it is only saved on when Web LAN is on too.
        state.config.Terminal_guide_enabled = terminalGuideEnabled && sharingEnabled
        let relayChanged = relayEnabled != state.config.Virtual_tuner_relay_enabled
        state.config.Virtual_tuner_relay_enabled = relayEnabled
        state.config.OTA_lineup_hour         = airScanHour
        state.config.First_run_wizard_shown = true
        state.saveConfig()
        // Same commit pattern as SettingsView.save(): only (re)start the listener if the toggle
        // actually changed, rather than unconditionally calling setupWebServer() every Finish.
        if webServerChanged { state.setupWebServer() }
        // Re-evaluate immediately — same reasoning as SettingsView's save path — in the unlikely
        // case a recording is already active while this wizard is still open (e.g. a reopen via
        // Settings → Maintenance → "Reset First-Run Setup" while something happens to be recording).
        if relayChanged { state.updateVirtualTunerPresence() }
        // Flourish, then dismiss — 380ms total, well under a ~500-700ms ceiling. .onExitCommand
        // and the red-close-button both call dismiss() directly and immediately regardless of
        // this pending task, so Escape mid-flourish still works exactly as before.
        finishGlowTrigger += 1
        finishTask = Task {
            try? await Task.sleep(for: .milliseconds(380))
            guard !Task.isCancelled else { return }
            closeWizard()
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
        Dialogs.choose(panel) { url in if let url { saveFolder = url.path } }
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
