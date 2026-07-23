import SwiftUI

@main
struct hdhr_VCRApp: App {
    @StateObject private var appState = AppState()

    init() {
        glog("=== hdhrVCRplus launched ===")

        // Hide Dock icon — menu bar only.
        NSApplication.shared.setActivationPolicy(.accessory)
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
                .onAppear  { appState.menuIsOpen = true  }
                .onDisappear {
                    appState.menuIsOpen = false
                    // Refresh menu caches now that the menu is closed — guide loads or
                    // recording state changes that were suppressed while open are applied here.
                    appState.rebuildMenuEntries()
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
        .defaultSize(width: 420, height: 620)

        // Floating cable guide — single instance; opened from the Add Show guide step pop-out button
        Window("Cable Guide", id: "cable-guide") {
            FloatingGuideView()
                .environmentObject(appState)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 820)
    }

    // Silently open+close the menu so SwiftUI builds the view graph while the icon is still dimmed.
    // The startup opacity signals "not ready" so any accidental click during pre-warm is harmless.
    @ViewBuilder
    private var statusLabel: some View {
        if appState.isRecording {
            if let icon = appIconMenuBarRecording {
                Image(nsImage: icon)
                    .accessibilityLabel("hdhr VCR — recording in progress")
            } else {
                // Fallback: no bundle resources (e.g. direct swift build)
                Image(systemName: "record.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.red, .primary)
                    .accessibilityLabel("hdhr VCR — recording in progress")
            }
        } else if let mins = appState.nextShowMinutes, mins <= 30 {
            let minsInt = Int(mins.rounded())
            if let icon = appIconMenuBarUpNext {
                Image(nsImage: icon)
                    .accessibilityLabel("hdhr VCR — recording starting in \(minsInt) minute\(minsInt == 1 ? "" : "s")")
            } else {
                // Fallback: no bundle resources (e.g. direct swift build)
                Image(systemName: "clock.badge.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.orange, .primary)
                    .accessibilityLabel("hdhr VCR — recording starting in \(minsInt) minute\(minsInt == 1 ? "" : "s")")
            }
        } else if let icon = appIconMenuBar {
            Image(nsImage: icon)
                .opacity(appState.isReady ? 1.0 : 0.3)
                .accessibilityLabel("hdhr VCR")
        } else {
            // Fallback: no bundle resources (e.g. direct swift build)
            Image(systemName: "tv")
                .opacity(appState.isReady ? 1.0 : 0.3)
                .accessibilityLabel("hdhr VCR")
        }
    }
}
