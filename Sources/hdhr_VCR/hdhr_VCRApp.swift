import SwiftUI

@main
struct hdhr_VCRApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.openWindow) private var openWindow
    // Guards the launch-time donation nag so it fires exactly once per run, not on every
    // real menu open (the onAppear below also fires on every user menu-open, not just launch).
    @State private var launchDonationNagShown = false

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
                    // the local flag confines the donation nag to firing once per run.
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
        .defaultSize(width: 420, height: 620)

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
    }

    // No-op once Donation_unlocked is set. openWindow(id:) on an already-open single-instance
    // Window scene just re-focuses it (Window scenes can't duplicate — see docs/MenuContent.md's
    // "No duplicate windows" note), so this is safe to call repeatedly without checking first.
    private func openDonationNagIfNeeded() {
        guard !appState.config.Donation_unlocked else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: "donation-nag")
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
