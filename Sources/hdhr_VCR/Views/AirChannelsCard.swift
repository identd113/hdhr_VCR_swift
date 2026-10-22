import SwiftUI

// The first-run wizard's "Channels from the Air" card (docs/FirstRunWizardView.md): starts a quick channel-list scan (no guide) and shows its
// progress inline, instead of opening the scan window on top of the wizard. Optional: the same scan also runs by itself in the early
// hours when no list exists yet (AppState.startScheduledOTALineupRefreshIfDue), so skipping this step still ends up with one.
/// "Channel list: scanned Oct 21, 7:42 PM" / "Guide: never scanned" — when each saved over-the-air result was last completed. Shared by the wizard
/// card and Settings → Advanced; re-reads the saved files only when a scan starts or ends, never on every redraw.
struct AirLastScanLines: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var progress: OTAScanProgress
    var showGuide = true
    @State private var dates: (lineup: Date?, guide: Date?) = (nil, nil)

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            line("Channel list", dates.lineup, id: "ota-last-lineup")
            if showGuide { line("Guide", dates.guide, id: "ota-last-guide") }
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

struct AirChannelsCard: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var progress: OTAScanProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if state.recordableDevices.isEmpty {
                Label("No tuner found yet. You can skip this: the scan runs on its own once a tuner is found.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("wizard-air-no-tuner")
            } else if progress.running {
                runningView
            } else if let outcome {
                outcomeView(outcome)
            } else {
                Button { state.startOTAScan(lineupOnly: true, userInitiated: true, showWindow: false) } label: {
                    Label("Scan the air for channels", systemImage: "antenna.radiowaves.left.and.right")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("wizard-air-scan")
                Text("About three minutes. You can keep going through the setup while it runs.")
                    .font(.caption).foregroundStyle(.secondary)
                AirLastScanLines(progress: progress, showGuide: false)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// What the last scan found, once one has finished (nil before any).
    private var outcome: (stations: Int, channels: Int)? {
        guard progress.endedAt != nil || !progress.rows.isEmpty else { return nil }
        return (progress.rows.count, progress.channelCount)
    }

    private var runningView: some View {
        TimelineView(.periodic(from: .now, by: 2)) { context in
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: progress.fraction(now: context.date))
                    .animation(.linear(duration: 2), value: progress.fraction(now: context.date))
                    .accessibilityLabel("Channel scan progress")
                    .accessibilityIdentifier("wizard-air-progress")
                HStack {
                    Text("\(progress.finished) of \(progress.total) RF channels · \(progress.rows.count) stations · \(progress.channelCount) channels")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { state.cancelOTAScan() }
                        .buttonStyle(.link).font(.caption)
                        .accessibilityIdentifier("wizard-air-cancel")
                }
                if let note = progress.note {
                    Label(note, systemImage: "pause.circle").font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private func outcomeView(_ o: (stations: Int, channels: Int)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if progress.cancelled && o.channels == 0 {
                Label("Scan cancelled.", systemImage: "xmark.circle")
                    .foregroundStyle(.secondary).font(.callout.bold())
                    .accessibilityIdentifier("wizard-air-cancelled")
            } else if o.channels > 0 {
                Label("Found \(o.stations) \(o.stations == 1 ? "station" : "stations") with \(o.channels) \(o.channels == 1 ? "channel" : "channels").", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.callout.bold())
                    .accessibilityIdentifier("wizard-air-found")
                Text("Saved as a backup channel list. It is read again once a day at the time set below.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label("No stations found.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout.bold())
                    .accessibilityIdentifier("wizard-air-none")
                Text("Is an antenna connected to the tuner? You can try again from Settings → Guide → Lineup (Over the Air).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            AirLastScanLines(progress: progress, showGuide: false)
            Button("Scan again") { state.startOTAScan(lineupOnly: true, userInitiated: true, showWindow: false) }
                .buttonStyle(.link).font(.caption)
                .accessibilityIdentifier("wizard-air-rescan")
        }
    }
}
