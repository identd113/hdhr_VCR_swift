import SwiftUI

// Over-the-air scan dashboard (docs/OTAScanView.md): a floating window that opens when a scan starts. The stations found run along the
// top as tabs; the one being read is selected automatically (until you click another) and below it are facts about that station and
// its channels, each with its episode count and the start of its earliest listing.
struct OTAScanView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var progress: OTAScanProgress
    @State private var pinnedRF: Int?       // a tab the person clicked: the selection stays there instead of following the scan
    @State private var followedRF: Int?     // the last station the scan was working on that has a tab
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
            if progress.rows.isEmpty {
                Text(progress.running ? "Looking for stations…" : "No stations found.").foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                tabStrip
                if let row = selectedRow { panel(row) }
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
        .frame(width: 480, height: 600)
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

    // MARK: tabs

    private var selectedRF: Int? {
        if let pinnedRF, progress.rows.contains(where: { $0.rf == pinnedRF }) { return pinnedRF }
        if let cur = progress.currentRF, progress.rows.contains(where: { $0.rf == cur }) { return cur }
        return followedRF.flatMap { f in progress.rows.contains(where: { $0.rf == f }) ? f : nil } ?? progress.rows.first?.rf
    }
    private var selectedRow: OTAMultiplexRow? { selectedRF.flatMap { rf in progress.rows.first { $0.rf == rf } } }

    private var tabStrip: some View {
        HStack(spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(spacing: 6) {
                        ForEach(progress.rows) { row in tab(row).id(row.rf) }
                    }
                    .padding(.vertical, 2)
                }
                .onChange(of: selectedRF) { _, rf in
                    if let rf { withAnimation { proxy.scrollTo(rf, anchor: .center) } }
                    if pinnedRF == nil, let rf { followedRF = rf }
                }
            }
            if pinnedRF != nil, progress.running {
                Button("Follow") { pinnedRF = nil }
                    .controlSize(.small)
                    .help("Go back to the station being read")
                    .accessibilityIdentifier("ota-scan-follow")
            }
        }
    }

    private func tab(_ row: OTAMultiplexRow) -> some View {
        let selected = row.rf == selectedRF
        return Button { pinnedRF = row.rf } label: {
            HStack(spacing: 5) {
                marker(row.state)
                VStack(alignment: .leading, spacing: 0) {
                    Text("RF \(row.rf)").font(.callout.bold())
                    Text("\(row.subChannels.count) ch").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? Color.accentColor : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("RF \(row.rf), \(row.subChannels.count) channels, \(stateWord(row.state))")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("ota-scan-tab-\(row.rf)")
    }

    // MARK: the selected station

    private func panel(_ row: OTAMultiplexRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                marker(row.state)
                Text("RF \(row.rf) · \(Self.mhz(row.info.frequencyMHz))").font(.headline)
                Text(stateWord(row.state)).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            facts(row)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(row.subChannels) { sub in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if row.state == .scanning {
                                if sub.done { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                                else { ProgressView().controlSize(.mini) }
                            }
                            Text("\(sub.number)  \(sub.name)").font(.callout)
                            Spacer(minLength: 8)
                            if !progress.lineupOnly {
                                if let text = sub.episodeText { Text(text).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                                else if row.state != .waiting && row.state != .scanning { Text("no guide").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("ota-scan-sub-\(sub.number)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.secondary.opacity(0.07)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("RF \(row.rf), \(row.subChannels.count) channels, \(stateWord(row.state))")
        .accessibilityIdentifier("ota-scan-mux-\(row.rf)")
    }

    /// What is interesting about the station itself, as label/value pairs in two columns.
    private func facts(_ row: OTAMultiplexRow) -> some View {
        let i = row.info
        var items: [(String, String)] = []
        let majors = i.majors.map { "\($0).x" }.joined(separator: ", ")
        items.append(("Carries", "\(row.subChannels.count) channels" + (majors.isEmpty ? "" : " (\(majors))")
                      + (i.audioChannels > 0 ? ", \(i.audioChannels) audio-only" : "")))
        if !progress.lineupOnly {
            if i.guideTablesAnnounced == 0, row.state != .scanning { items.append(("Guide", "none sent")) }
            else if i.episodes > 0 {
                var g = "\(i.episodes) episodes"
                if let hours = i.guideHoursAhead() { g += ", reaches \(Self.hoursText(hours)) ahead" }
                items.append(("Guide", g))
            } else { items.append(("Guide", "reading…")) }
            if let first = i.earliest { items.append(("Oldest listing", OTASubChannelRow.startText(first))) }
            if i.guideTablesAnnounced > 0 { items.append(("Listing tables", "\(i.guideTablesAnnounced) announced")) }
        }
        if i.strength != nil || i.quality != nil {
            items.append(("Signal", [i.strength.map { "strength \($0)%" }, i.quality.map { "quality \($0)%" }].compactMap { $0 }.joined(separator: ", ")))
        }
        if let mbps = i.mbps { items.append(("Data rate", String(format: "%.1f Mbit/s over %d s", mbps, Int(i.seconds.rounded())))) }
        if let off = i.clockOffset() { items.append(("Station clock", off == 0 ? "matches this Mac" : "\(off > 0 ? "+" : "")\(off) s vs this Mac")) }
        return LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)], alignment: .leading, spacing: 5) {
            ForEach(items, id: \.0) { item in
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.0).font(.caption2).foregroundStyle(.secondary)
                    Text(item.1).font(.caption)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("ota-scan-fact-\(item.0.replacingOccurrences(of: " ", with: "-").lowercased())")
            }
        }
    }

    static func mhz(_ v: Double) -> String { v == v.rounded() ? String(format: "%.0f MHz", v) : String(format: "%.1f MHz", v) }
    static func hoursText(_ h: Double) -> String { h < 48 ? "\(Int(h.rounded())) h" : String(format: "%.1f days", h / 24) }

    @ViewBuilder private func marker(_ s: OTAMultiplexRow.State) -> some View {
        switch s {
        case .waiting: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        case .scanning: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .noGuide: Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
        }
    }
}
