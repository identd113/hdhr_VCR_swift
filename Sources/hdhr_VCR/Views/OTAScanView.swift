import SwiftUI

// Over-the-air scan dashboard (docs/OTAScanView.md): a small floating window that opens when a scan starts. Multiplexes as a vertical
// list; the one being read shows its sub-channels with spinners, a finished one collapses to a green check.
struct OTAScanView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var progress: OTAScanProgress
    @State private var expanded: Set<Int> = []   // finished stations whose channels are unfolded
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ProgressView(value: Double(progress.finished), total: Double(max(progress.total, 1)))
                .accessibilityLabel("Scan progress")
                .accessibilityValue("\(progress.finished) of \(progress.total) RF channels")
                .accessibilityIdentifier("ota-scan-progress")
            HStack {
                Text((progress.twoPass ? (progress.pass == 1 ? "Pass 1 of 2, channel lists: " : "Pass 2 of 2, guides: ") : "") + "\(progress.finished) of \(progress.total) \(progress.pass == 2 ? "stations" : "RF channels")").font(.caption.monospacedDigit())
                    .accessibilityIdentifier("ota-scan-count")
                Spacer()
                Text(timeLine).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("ota-scan-time-left")
            }
            HStack {
                Text("Tuners")
                Picker("Tuners", selection: $state.otaTunerLimit) {
                    ForEach(1...max(1, state.otaTunerMax), id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden().frame(width: 60)
                .accessibilityLabel("Tuners to use")
                .accessibilityIdentifier("ota-scan-tuners")
                Spacer()
                Text(progress.running ? statusLine : state.otaScanStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityIdentifier("ota-scan-status")
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if progress.rows.isEmpty {
                        Text(progress.running ? "Looking for stations…" : "No stations found.").foregroundStyle(.secondary)
                    }
                    ForEach(progress.rows) { row in multiplexView(row) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if progress.withoutSignal > 0 {
                    Text("\(progress.withoutSignal) RF channel(s) with no signal").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if progress.running { Button("Cancel Scan") { state.cancelOTAScan() }.accessibilityIdentifier("ota-scan-cancel") }
                else { Button("Close") { dismissWindow(id: "ota-scan") }.accessibilityIdentifier("ota-scan-close") }
            }
        }
        .padding(16)
        .frame(width: 380, height: 460)
        .accessibilityIdentifier("ota-scan-window")
        .background(WindowAction(trigger: true) { $0.level = .floating })
    }

    private var header: some View {
        HStack(spacing: 18) {
            stat(progress.rows.count, "multiplexes", id: "ota-scan-multiplexes")
            stat(progress.channelCount, "channels", id: "ota-scan-channels")
            if !progress.lineupOnly { stat(progress.listingCount, "episodes", id: "ota-scan-listings") }
            Spacer()
        }
    }

    private func stat(_ n: Int, _ label: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(n)").font(.title2.monospacedDigit().bold())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(n)")
        .accessibilityIdentifier(id)
    }

    private var statusLine: String {
        let rfs = progress.tuning.sorted()
        return rfs.isEmpty ? "" : "Tuning RF " + rfs.map(String.init).joined(separator: ", RF ")
    }

    private var timeLine: String {
        guard progress.running else { return "" }
        guard let s = progress.estimatedSecondsRemaining() else { return "estimating…" }
        return s < 90 ? "about 1 min left" : "about \(Int((s / 60).rounded())) min left"
    }

    private func stateWord(_ s: OTAMultiplexRow.State) -> String {
        switch s { case .waiting: return "waiting for guide"; case .scanning: return "scanning"; case .done: return "done"; case .noGuide(let why): return "no guide: \(why)" }
    }

    private func isFinished(_ s: OTAMultiplexRow.State) -> Bool {
        switch s { case .done, .noGuide: return true; case .waiting, .scanning: return false }
    }

    /// A finished station folds its channels away; one still being read, or waiting for its guide, shows the channels it carries.
    private func showsChannels(_ row: OTAMultiplexRow) -> Bool {
        switch row.state {
        case .scanning, .waiting: return true
        case .done, .noGuide: return expanded.contains(row.rf)
        }
    }

    @ViewBuilder private func multiplexView(_ row: OTAMultiplexRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                marker(row.state)
                Text("RF \(row.rf)").bold()
                Text("\(row.subChannels.count) channels" + (progress.lineupOnly || row.listings == 0 ? "" : " · \(row.listings) episodes"))
                    .font(.caption).foregroundStyle(.secondary)
                if case .noGuide(let why) = row.state { Text(why).font(.caption).foregroundStyle(.orange) }
                Spacer(minLength: 0)
                if isFinished(row.state) {
                    Button { if expanded.contains(row.rf) { expanded.remove(row.rf) } else { expanded.insert(row.rf) } } label: {
                        Image(systemName: expanded.contains(row.rf) ? "chevron.down" : "chevron.right").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(expanded.contains(row.rf) ? "Hide channels" : "Show channels")
                    .accessibilityIdentifier("ota-scan-expand-\(row.rf)")
                }
            }
            if showsChannels(row) {
                ForEach(row.subChannels) { sub in
                    HStack(spacing: 6) {
                        if row.state == .scanning {
                            if sub.done { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                            else { ProgressView().controlSize(.mini) }
                        }
                        Text("\(sub.number)  \(sub.name)").font(.callout)
                        if !progress.lineupOnly {
                            if let text = sub.episodeText { Text(text).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                            else if row.state != .waiting && row.state != .scanning { Text("no guide").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .padding(.leading, 22)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("ota-scan-sub-\(sub.number)")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("RF \(row.rf), \(row.subChannels.count) channels, \(stateWord(row.state))")
        .accessibilityIdentifier("ota-scan-mux-\(row.rf)")
    }

    @ViewBuilder private func marker(_ s: OTAMultiplexRow.State) -> some View {
        switch s {
        case .waiting: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        case .scanning: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .noGuide: Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
        }
    }
}
