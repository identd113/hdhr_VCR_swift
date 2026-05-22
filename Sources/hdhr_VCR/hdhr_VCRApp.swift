import SwiftUI

@main
struct hdhr_VCRApp: App {
    @StateObject private var appState = AppState()

    init() {
        // Hide Dock icon — menu bar only.
        // In Xcode: Target → Info → add "Application is agent (UIElement)" = YES
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(appState)
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
