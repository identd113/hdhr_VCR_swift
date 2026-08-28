import SwiftUI

// Runs the /Applications relocation check (AppRelocator.swift) once AppKit has fully finished
// launching — an NSAlert shown from App.init() (before the run loop is up) is unreliable, so this
// waits for the one lifecycle point SwiftUI's App protocol doesn't otherwise expose.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppRelocator.relocateToApplicationsIfNeeded()
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
                    // the local flags confine the wizard/nag to firing once per run each. The
                    // wizard check runs first so a genuinely first launch shows it before the
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
                .onChange(of: appState.config.First_run_wizard_shown) { _, shown in
                    if shown {
                        needsFirstRunWizard = false
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
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)

        // Edit Show window — single instance; reloads via onChange(editingShowId) on reopen
        Window("Edit Show", id: "edit-show") {
            EditShowView()
                .environmentObject(appState)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 480, height: 520)

        // Settings window — single instance
        Window("Settings", id: "settings") {
            SettingsView()
                .environmentObject(appState)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 560, height: 440)

        // Watch Now window — single instance; shows currently-airing shows as poster cards
        Window("Watch Now", id: "watch-now") {
            WatchNowView()
                .environmentObject(appState)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
        // 420 was too narrow once a recording row's action row grew a second stylized button
        // ("Watch Now!" + "Watch from Beginning" side by side, replacing a single-button pull-down
        // menu) — "Watch from Beginning" was clipping. Still user-resizable/shrinkable below this.
        .defaultSize(width: 480, height: 620)

        // Donation nag — single instance; opened via openDonationNagIfNeeded() on launch and
        // after a show is added (native or web), see DonationNagView.swift / docs/DonationNagView.md.
        // hiddenTitleBar (no title text, traffic lights remain) + DonationNagView's own
        // FloatingWindowLevelSetter for a modern floating-panel look, distinct from the other
        // standard-titled windows above.
        Window("Support hdhrVCRplus", id: "donation-nag") {
            DonationNagView()
                .environmentObject(appState)
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
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }

    // No-op once Donation_unlocked is set. openWindow(id:) on an already-open single-instance
    // Window scene just re-focuses it (Window scenes can't duplicate — see docs/MenuContent.md's
    // "No duplicate windows" note), so this is safe to call repeatedly without checking first.
    private func openDonationNagIfNeeded() {
        // Wait for the first-run wizard to be dismissed first, so the two windows never compete
        // for focus on a brand-new install — see the onChange(of: First_run_wizard_shown) above,
        // which re-checks this (and flips needsFirstRunWizard false) the moment the wizard flips
        // it. Reads needsFirstRunWizard, not the live appState.config.First_run_wizard_shown —
        // see that property's own comment for why the live value isn't safe to read here.
        guard !needsFirstRunWizard else { return }
        guard !appState.config.Donation_unlocked else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: "donation-nag")
    }

    // No-op once needsFirstRunWizard is false. Same shape as openDonationNagIfNeeded() above.
    private func openFirstRunWizardIfNeeded() {
        guard needsFirstRunWizard else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: "first-run-wizard")
    }

    // Silently open+close the menu so SwiftUI builds the view graph while the icon is still dimmed.
    // The startup opacity signals "not ready" so any accidental click during pre-warm is harmless.
    @ViewBuilder
    private var statusLabel: some View {
        if appState.isRecording {
            blinkableIcon(litImage: appIconMenuBarRecording,
                          litSystemName: "record.circle.fill",
                          litColor: .red,
                          accessibilityLabel: "hdhrVCRplus — recording in progress")
        } else if let mins = appState.nextShowMinutes, mins <= 30 {
            let minsInt = Int(mins.rounded())
            blinkableIcon(litImage: appIconMenuBarUpNext,
                          litSystemName: "clock.badge.fill",
                          litColor: .orange,
                          accessibilityLabel: "hdhrVCRplus — recording starting in \(minsInt) minute\(minsInt == 1 ? "" : "s")")
        } else if let icon = appIconMenuBar {
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
