import SwiftUI

// Last-scan lines shared by Settings → Over the Air and Advanced. (The wizard's inline scan card was removed 2026-11-15: its last step now
// offers a background scan when Finish is pressed.)
/// "Channel list: scanned Oct 21, 7:42 PM" / "Guide: never scanned" — when each saved over-the-air result was last completed. Shared by the wizard
/// card and Settings → Advanced; re-reads the saved files only when a scan starts or ends, never on every redraw.
struct AirLastScanLines: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var progress: OTAScanProgress
    var showGuide = true
    /// Settings → Over the Air: a button that reopens the scan window on the saved result (the menu bar only offers the window while a scan runs).
    var showOpenButton = false
    @Environment(\.openWindow) private var openWindow
    @State private var dates: (lineup: Date?, guide: Date?) = (nil, nil)

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            line("Channel list", dates.lineup, id: "ota-last-lineup")
            if showGuide { line("Guide", dates.guide, id: "ota-last-guide") }
            if showOpenButton, !progress.running, dates.lineup != nil || dates.guide != nil {
                Button("Show Last Scan Result…") {
                    state.otaWindowActivates = true
                    openWindow(id: "ota-scan")
                }
                .accessibilityIdentifier("settings-ota-show-last")
                .padding(.top, 4)
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .onAppear(perform: reload)
        .onChange(of: progress.running) { _, _ in reload() }
        .onChange(of: state.recordableDevices.map(\.DeviceID)) { _, _ in reload() }
    }

    private func line(_ name: String, _ date: Date?, id: String) -> some View {
        Text("\(name): \(progress.running ? "scanning now…" : date.map { "last scanned \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "never scanned")")
            .accessibilityIdentifier(id)
    }

    private func reload() {
        guard let id = OTAScanView.scanDeviceId(state) else { dates = (nil, nil); return }
        dates = OTAStore.lastCompletedScans(deviceId: id)
    }
}
