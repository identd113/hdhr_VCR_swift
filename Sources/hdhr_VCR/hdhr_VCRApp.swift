import SwiftUI

@main
struct hdhr_VCRApp: App {
    @StateObject private var appState = AppState()

    init() {
        // Redirect stdout + stderr to ~/Library/Logs/hdhrVCRplus.log so all print()
        // calls are persisted regardless of how the app was launched (.app bundle,
        // Login Item, or direct binary). Truncate to 0 when the file exceeds 5 MB
        // so it doesn't grow without bound across many restarts.
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/hdhrVCRplus.log")
        let logPath = logURL.path
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
           let size = attrs[.size] as? Int, size > 5 * 1024 * 1024 {
            try? "".write(toFile: logPath, atomically: false, encoding: .utf8)
        }
        freopen(logPath, "a", stdout)
        freopen(logPath, "a", stderr)
        // Disable stdio buffering so every print() line lands on disk immediately.
        // Without this, output is fully buffered (8 KB chunks) when stdout is a file,
        // causing log entries to appear delayed or missing after a crash/kill.
        setbuf(stdout, nil)
        setbuf(stderr, nil)
        let stamp = ISO8601DateFormatter().string(from: Date())
        print("\n=== hdhrVCRplus launched \(stamp) ===")

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

        // Add Show window — resizable when in guide step (the view controls its own frame)
        WindowGroup("Add Show", id: "add-show") {
            AddShowView()
                .environmentObject(appState)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)

        // Edit Show window
        WindowGroup("Edit Show", id: "edit-show") {
            EditShowView()
                .environmentObject(appState)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 480, height: 520)

        // Settings window
        WindowGroup("Settings", id: "settings") {
            SettingsView()
                .environmentObject(appState)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 560, height: 440)

        // Floating cable guide — opened from the Add Show guide step pop-out button
        WindowGroup("Cable Guide", id: "cable-guide") {
            FloatingGuideView()
                .environmentObject(appState)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 820)
    }

    @ViewBuilder
    private var statusLabel: some View {
        if appState.isRecording {
            Image(systemName: "record.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.red, .primary)
        } else if let mins = appState.nextShowMinutes, mins <= 30 {
            Image(systemName: "clock.badge.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.orange, .primary)
        } else if let icon = appIconMenuBar {
            Image(nsImage: icon)
                .opacity(appState.isStartingUp ? 0.4 : 1.0)
        } else {
            // Fallback: no bundle resources (e.g. direct swift build)
            Image(systemName: "tv")
                .opacity(appState.isStartingUp ? 0.4 : 1.0)
        }
    }
}
