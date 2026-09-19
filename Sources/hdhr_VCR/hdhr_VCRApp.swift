import SwiftUI

// A parsed `hdhrvcrplus://watch?dev=<deviceId>&channel=<channelNumber>[&transcode=1]` request —
// added 2026-09-07 so a FEED's "Watch"/"Watch (H.264)" action can be triggered non-interactively
// (`open 'hdhrvcrplus://...'` over SSH, via Launch Services) for cross-machine testing. An
// AppleScript/System Events UI-scripting path for the same menu item already existed (and still
// does, in WindowNavigationTests.swift) but only works from an interactive Terminal session that
// already holds Accessibility permission — invoked over a plain SSH command instead, `osascript`
// hangs indefinitely with no interactive session to grant/hold that permission for. This URL
// scheme closes that gap without needing Accessibility at all. Takes device+channel, mirroring the
// real HDHomeRun device's own `/auto/v<channel>?dev=<deviceId>` addressing
// (`docs/VirtualTunerService.md`) — deliberately not a raw pre-built relay URL, so this can't be
// pointed at an arbitrary string; the app resolves the real URL itself from
// `AppState.remoteRelayEntries`, the same source `MenuContent`'s own Watch buttons use.
struct WatchURLRequest: Equatable {
    let deviceId: String
    let channel: String
    let wantsTranscode: Bool

    /// Pure parse — extracted for direct unit testing without a real NSApplication/AppState,
    /// matching this codebase's established pattern (`WebServer.alignedToTSPacketBoundary`,
    /// `effectiveTranscodeProfile`, etc.). Returns nil for anything not shaped like this scheme.
    static func parse(_ url: URL) -> WatchURLRequest? {
        guard url.scheme == "hdhrvcrplus", url.host == "watch",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let deviceId = components.queryItems?.first(where: { $0.name == "dev" })?.value, !deviceId.isEmpty,
              let channel = components.queryItems?.first(where: { $0.name == "channel" })?.value, !channel.isEmpty
        else { return nil }
        let wantsTranscode = components.queryItems?.first(where: { $0.name == "transcode" })?.value == "1"
        return WatchURLRequest(deviceId: deviceId, channel: channel, wantsTranscode: wantsTranscode)
    }
}

// Runs the /Applications relocation check (AppRelocator.swift) once AppKit has fully finished
// launching — an NSAlert shown from App.init() (before the run loop is up) is unreliable, so this
// waits for the one lifecycle point SwiftUI's App protocol doesn't otherwise expose.
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Set by hdhr_VCRApp.init() right after both it and AppState exist — @NSApplicationDelegateAdaptor
    // and @StateObject are two independently-managed objects with no reference to each other by
    // default, so this is the one link between them an AppKit-level delegate callback (below) needs.
    weak var appState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppRelocator.relocateToApplicationsIfNeeded()
    }

    // AppKit's modern replacement for the older kAEGetURL Apple Event handler — called for both
    // file opens and a registered CFBundleURLTypes scheme's own opens (tools/Info.plist.template).
    // A LAN-only, same-Mac trigger (Launch Services only delivers this to an already-running
    // instance of *this* app), but still resolved defensively against live state rather than
    // trusted blindly, matching this app's own no-auth-but-validate-inputs stance elsewhere
    // (CLAUDE.md's WebServer note) — an unrecognized shape or a dev/channel with no matching,
    // currently-available FEED both just log and no-op, never crash or guess.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let appState else { return }
        for url in urls {
            guard let request = WatchURLRequest.parse(url) else {
                glog("[URLScheme] ignoring unrecognized URL: \(url.absoluteString)", level: .warning)
                continue
            }
            Task { @MainActor in
                guard let pair = appState.remoteRelayEntries.first(where: {
                    $0.device.DeviceID == request.deviceId && $0.entry.GuideNumber == request.channel
                }) else {
                    glog("[URLScheme] watch request for dev=\(request.deviceId) channel=\(request.channel) — no matching available FEED", level: .warning)
                    return
                }
                let title = pair.entry.virtualRelayShowTitle ?? pair.entry.GuideName
                // Same "auto" convention MenuContent's own H.264 button uses — any non-empty,
                // non-"none" string only tells the remote relay "transcode this," never decides
                // the level (WebServer.effectiveTranscodeProfile's own doc comment).
                let relayURL = request.wantsTranscode ? (pair.entry.URL ?? "") + "&transcode=auto" : (pair.entry.URL ?? "")
                glog("[URLScheme] watch request resolved — dev=\(request.deviceId) channel=\(request.channel) transcode=\(request.wantsTranscode)")
                appState.watchRemoteRelay(url: relayURL, title: title, device: pair.device)
            }
        }
    }
}

@main
struct hdhr_VCRApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    @Environment(\.openWindow) private var openWindow
    // Guards the launch-time donation nag so it fires exactly once per run, not on every
    // real menu open (the onAppear below also fires on every user menu-open, not just launch).
    @State private var launchDonationNagShown = false
    // Same guard, for the first-run setup wizard — checked first so a genuinely first launch
    // shows the wizard before the donation nag (see openDonationNagIfNeeded()'s own guard below).
    @State private var launchFirstRunWizardShown = false
    // Whether the wizard still needs to run, decided once from the synchronous config peek below
    // (NOT from appState.config — see that peek's own comment for why: AppState's real config load
    // is an unawaited async Task, so appState.config could still read AppConfig()'s bare-default
    // false at the exact moment the launch onAppear fires, even for a returning user whose real
    // persisted flag is true, which would reopen the wizard on every single launch for them). Kept
    // in sync afterward by the onChange(of: appState.config.First_run_wizard_shown) below, once
    // that value is guaranteed live — openDonationNagIfNeeded() reads this, not the live config, so
    // its own suppression guard is race-free at every call site, not just the launch-time one.
    @State private var needsFirstRunWizard: Bool

    init() {
        glog("=== hdhrVCRplus launched ===")

        // Dock icon visibility — see TODO.md's "Show Stoppers" entry. LSUIElement no longer
        // forces accessory (no Dock icon) unconditionally at process start (Info.plist), because
        // a background-only process may never get the system's Local Network permission prompt
        // surfaced to the user at all — a real, currently-unresolved macOS bug independent of
        // this app, but this is a plausible low-risk mitigation to try. Until a lineup fetch has
        // actually succeeded once (config.Local_network_confirmed, set by
        // AppState.confirmLocalNetworkAccessIfNeeded), "auto" mode starts as a regular foreground
        // app (Dock icon) so the OS has a normal app to attach the prompt to, then switches back
        // to accessory once access is confirmed working. A synchronous peek at the persisted
        // config here, independent of AppState's own (later, async) load — @StateObject's
        // AppState() hasn't loaded its real config by this point in init().
        let cfg = ConfigManager().load()?.config
        let dockMode = cfg?.Dock_icon_mode ?? "auto"
        let localNetworkConfirmed = cfg?.Local_network_confirmed ?? false
        _needsFirstRunWizard = State(initialValue: !(cfg?.First_run_wizard_shown ?? false))
        let showDock: Bool
        switch dockMode {
        case "always": showDock = true
        case "never":  showDock = false
        default:       showDock = !localNetworkConfirmed   // "auto"
        }
        NSApplication.shared.setActivationPolicy(showDock ? .regular : .accessory)

        // Set app icon from bundled app.jpg so it appears in Force Quit and Activity Monitor.
        if let icon = appIconImage {
            NSApplication.shared.applicationIconImage = icon
        }

        // Hands AppDelegate the one reference it needs for application(_:open:) above — both
        // appDelegate and appState (the latter via its default-value property-wrapper expression)
        // are already fully constructed by this point in a custom init(), even though they're two
        // independently-managed property wrappers with no reference to each other otherwise.
        appDelegate.appState = appState
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(appState)
                // Track menu open/closed so the idle loop skips rebuildMenuEntries() while
                // the user is navigating — prevents @Published changes from glitching the menu.
                .onAppear  {
                    appState.menuIsOpen = true
                    // This onAppear also fires on the app's forced silent open+close at launch
                    // (see statusLabel's comment below), which is what makes it a reliable,
                    // race-free launch hook — but it also fires on every real user menu-open, so
                    // the local flags confine the wizard/nag to firing once per run each.
                    // (2026-09-11: this was briefly also used to trigger AppState.startup() —
                    // reverted the same day when a real deploy showed the MenuBarExtra status
                    // item, and therefore this onAppear, sometimes never renders/fires at all on
                    // this machine/OS — the app sat fully idle, web server never bound, nothing
                    // scheduled. Not reliable enough for something this load-bearing; startup()
                    // is triggered from AppState.init() again, see that comment for the real fix.)
                    // The wizard check runs first so a genuinely first launch shows it before the
                    // donation nag (which stays suppressed until the wizard is dismissed — see
                    // openDonationNagIfNeeded()'s own guard).
                    if !launchFirstRunWizardShown {
                        launchFirstRunWizardShown = true
                        openFirstRunWizardIfNeeded()
                    }
                    if !launchDonationNagShown {
                        launchDonationNagShown = true
                        openDonationNagIfNeeded()
                    }
                }
                .onDisappear {
                    appState.menuIsOpen = false
                    // Refresh menu caches now that the menu is closed — guide loads or
                    // recording state changes that were suppressed while open are applied here.
                    appState.rebuildMenuEntries()
                }
                .onChange(of: appState.pendingDonationNagTrigger) { _, _ in openDonationNagIfNeeded() }
                // The launch-time call above no-ops until the wizard is dismissed (its own guard),
                // and the launch onAppear only fires once — so re-check right when the wizard's
                // flag flips true, the same way pendingDonationNagTrigger re-checks after a show add.
                // Also handles the reverse transition (true → false): Settings → Maintenance →
                // "Reset First-Run Setup" flips this back to false and reopens the wizard directly
                // (not through openFirstRunWizardIfNeeded()'s own guard) — without re-arming
                // needsFirstRunWizard here too, openDonationNagIfNeeded()'s guard would stay stale
                // from the original run and let the nag pop up alongside the reopened wizard.
                .onChange(of: appState.config.First_run_wizard_shown) { _, shown in
                    needsFirstRunWizard = !shown
                    if shown {
                        openDonationNagIfNeeded()
                    }
                }
        } label: {
            statusLabel
        }
        .menuBarExtraStyle(.menu)

        // Single-instance Window (not WindowGroup) so openWindow(id:) always targets the one
        // instance and can never spawn a duplicate. The view reacts to pendingAddEntryGeneration
        // to refresh on reopen. Resizable when in guide step (the view controls its own frame).
        Window("Add Show", id: "add-show") {
            AddShowView()
                .environmentObject(appState)
                .preferredColorScheme(resolvedColorScheme)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)

        // Edit Show window — single instance; reloads via onChange(editingShowId) on reopen
        Window("Edit Show", id: "edit-show") {
            EditShowView()
                .environmentObject(appState)
                .preferredColorScheme(resolvedColorScheme)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 480, height: 520)

        // Settings window — single instance
        Window("Settings", id: "settings") {
            SettingsView()
                .environmentObject(appState)
                .preferredColorScheme(resolvedColorScheme)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 560, height: 440)

        // Watch Now window — single instance; shows currently-airing shows as poster cards
        Window("Watch Now", id: "watch-now") {
            WatchNowView()
                .environmentObject(appState)
                .preferredColorScheme(resolvedColorScheme)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
        // 420 was too narrow once a recording row's action row grew a second stylized button
        // ("Watch Now!" + "Watch from Beginning" side by side, replacing a single-button pull-down
        // menu) — "Watch from Beginning" was clipping. Still user-resizable/shrinkable below this.
        .defaultSize(width: 480, height: 620)

        // Add Picture-in-Picture picker — single instance; lets the user start a PIP corner
        // thumbnail directly (Live TV or a discovered FEED source), without anything already
        // playing in the primary pane. Opened from MenuContent's "Add Picture-in-Picture…" button
        // and from VLCPlayerView's right-click context menu on the main video pane.
        Window("Add Picture-in-Picture", id: "pip-picker") {
            PiPPickerView()
                .environmentObject(appState)
                .preferredColorScheme(resolvedColorScheme)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 420, height: 520)

        // Donation nag — single instance; opened via openDonationNagIfNeeded() on launch and
        // after a show is added (native or web), see DonationNagView.swift / docs/DonationNagView.md.
        // hiddenTitleBar (no title text, traffic lights remain) + DonationNagView's own
        // WindowAction-based floating level for a modern floating-panel look, distinct from the
        // other standard-titled windows above.
        Window("Support hdhrVCRplus", id: "donation-nag") {
            DonationNagView()
                .environmentObject(appState)
                .preferredColorScheme(resolvedColorScheme)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        // First-run setup wizard — single instance; auto-opens once on a fresh install (or after
        // an upgrade from a version predating this feature) via openFirstRunWizardIfNeeded()
        // below, and suppresses the donation nag until dismissed (see openDonationNagIfNeeded()'s
        // own guard). Also reopened on demand from Settings → Maintenance → "Reset First-Run
        // Setup". hiddenTitleBar matches the donation nag's own "modern floating panel" look —
        // fitting for a focused onboarding flow rather than a document-style window.
        Window("Welcome to hdhrVCRplus", id: "first-run-wizard") {
            FirstRunWizardView()
                .environmentObject(appState)
                .preferredColorScheme(resolvedColorScheme)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }

    // nil ("auto") lets each window follow the system appearance the normal SwiftUI way — only
    // "dark"/"light" actually override it. Read live off appState.config, so every window scene
    // above re-renders the instant Settings → General's Appearance picker (or an in-app embedded
    // web guide's own theme switcher, via AddShowWebView's native bridge) changes it — no separate
    // propagation step needed beyond what @Published already gives every one of these views.
    private var resolvedColorScheme: ColorScheme? {
        switch appState.config.Appearance_mode {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    // Shared by both launch-gate functions below: bring the app forward and (re)focus a
    // single-instance Window. openWindow(id:) on one that's already open just re-focuses it
    // (Window scenes can't duplicate — see docs/MenuContent.md's "No duplicate windows" note), so
    // this is safe to call repeatedly without checking first.
    private func activateAndOpen(windowId: String) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: windowId)
    }

    // No-op once Donation_unlocked is set.
    private func openDonationNagIfNeeded() {
        // Wait for the first-run wizard to be dismissed first, so the two windows never compete
        // for focus on a brand-new install — see the onChange(of: First_run_wizard_shown) above,
        // which keeps this guard in sync with both directions of that flag. Reads
        // needsFirstRunWizard, not the live appState.config.First_run_wizard_shown — see that
        // property's own comment for why the live value isn't safe to read here.
        guard !needsFirstRunWizard else { return }
        guard !appState.config.Donation_unlocked else { return }
        activateAndOpen(windowId: "donation-nag")
    }

    // No-op once needsFirstRunWizard is false. Same shape as openDonationNagIfNeeded() above.
    private func openFirstRunWizardIfNeeded() {
        guard needsFirstRunWizard else { return }
        activateAndOpen(windowId: "first-run-wizard")
    }

    // Silently open+close the menu so SwiftUI builds the view graph while the icon is still dimmed.
    // The startup opacity signals "not ready" so any accidental click during pre-warm is harmless.
    // Switches on appState.activeStatusLight rather than re-deriving isRecording/nextShowMinutes/
    // hasAvailableRemoteFeed priority here — AppState.tickStatusLight() already resolved which
    // status (if more than one is active) should be showing *this instant*, including cycling
    // between recording/feed when both are true; this view only has to render whichever one it's
    // told.
    @ViewBuilder
    private var statusLabel: some View {
        switch appState.activeStatusLight {
        case .recording:
            blinkableIcon(litImage: appIconMenuBarRecording,
                          litSystemName: "record.circle.fill",
                          litColor: .red,
                          accessibilityLabel: "hdhrVCRplus — recording in progress")
        case .upNext(let minsInt):
            blinkableIcon(litImage: appIconMenuBarUpNext,
                          litSystemName: "clock.badge.fill",
                          litColor: .orange,
                          accessibilityLabel: "hdhrVCRplus — recording starting in \(minsInt) minute\(minsInt == 1 ? "" : "s")")
        case .feedAvailable:
            // Same baked-artwork treatment as recording/up-next (app-feed.jpg — the same mark,
            // just a blue status dot instead of red/amber), so a FEED being available reads as
            // clearly "part of the same family" of status lights rather than a generic system
            // glyph. "play.tv.fill" + watchNowBlue remain as the bundle-less fallback, matching the
            // same Watch-button icon/color MenuContent's own "Recording on Another Mac" entries use.
            blinkableIcon(litImage: appIconMenuBarFeed,
                          litSystemName: "play.tv.fill",
                          litColor: watchNowBlue,
                          accessibilityLabel: "hdhrVCRplus — a recording is available to watch from another Mac")
        case nil:
            if let icon = appIconMenuBar {
                Image(nsImage: icon)
                    .opacity(appState.isReady ? 1.0 : 0.3)
                    .accessibilityLabel("hdhrVCRplus")
            } else {
                // Fallback: no bundle resources (e.g. direct swift build)
                Image(systemName: "tv")
                    .opacity(appState.isReady ? 1.0 : 0.3)
                    .accessibilityLabel("hdhrVCRplus")
            }
        }
    }

    // Renders the recording/up-next status light, optionally blinking it (Settings → "Blink menu
    // bar icon"). Reads appState.statusLightOn — driven by AppState's own 1Hz timer — rather than
    // a view-local TimelineView: a TimelineView inside the MenuBarExtra label broke click-to-open
    // (AppKit's NSStatusItem stopped forwarding clicks once the label free-ran its own render loop).
    @ViewBuilder
    private func blinkableIcon(litImage: NSImage?, litSystemName: String, litColor: Color,
                                accessibilityLabel: String) -> some View {
        blinkFrame(lightOn: appState.statusLightOn, litImage: litImage, litSystemName: litSystemName, litColor: litColor)
            .accessibilityLabel(accessibilityLabel)
    }

    // "Off" frame reuses the existing idle/dim mark (appIconMenuBar) — no new assets needed.
    @ViewBuilder
    private func blinkFrame(lightOn: Bool, litImage: NSImage?, litSystemName: String, litColor: Color) -> some View {
        if lightOn {
            if let litImage {
                Image(nsImage: litImage)
            } else {
                // Fallback: no bundle resources (e.g. direct swift build)
                Image(systemName: litSystemName)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(litColor, .primary)
            }
        } else if let idle = appIconMenuBar {
            Image(nsImage: idle)
        } else {
            Image(systemName: "tv")
                .opacity(0.3)
        }
    }
}
