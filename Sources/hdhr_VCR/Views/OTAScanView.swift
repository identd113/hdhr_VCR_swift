import SwiftUI

// Over-the-air scan window (docs/OTAScanView.md): a floating window that opens when a scan starts.
//   1. Overview: what the scan is doing, one progress bar for the whole scan, a time estimate and running totals.
//   2. The dial: the airwaves as one bar per RF channel (OTASpectrumDial); a station springs up when it is found, an arrow in the reading
//      tuner's colour bobs over the channel being read. Tap a bar to see that multiplex.
//   3. The tuners, one slim chip each.
//   4. The selected multiplex: its channels drawn as chips sharing one stream, then a list of them with their guide.
struct OTAScanView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var progress: OTAScanProgress
    @State private var pinnedRF: Int?       // a tab the person clicked: the selection stays there instead of following the scan
    @State private var followedRF: Int?     // the last station the scan was working on that has a tab
    @Environment(\.dismissWindow) private var dismissWindow

    /// One colour per tuner, used for its light, its progress bar and the dot on the tab of the station it is reading.
    static let laneColors: [Color] = [.teal, .indigo, .pink, .brown]
    private func laneColor(_ index: Int) -> Color { Self.laneColors[index % Self.laneColors.count] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            overview
            dialCard
            tunersSection
            multiplexSection
            footer
        }
        .padding(16)
        .frame(width: 540, height: 760)
        .accessibilityIdentifier("ota-scan-window")
        .background(WindowAction(trigger: true) { $0.level = .floating })
    }

    // MARK: 1. overview

    private var overview: some View {
        TimelineView(.periodic(from: .now, by: 2)) { context in
            let now = context.date
            let value = progress.running ? progress.fraction(now: now) : (progress.total > 0 ? 1 : 0)
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(.title3.bold())
                    if progress.running, progress.twoPass {
                        Text(progress.pass == 1 ? "Pass 1 of 2 · channel lists" : "Pass 2 of 2 · guides")
                            .font(.caption).padding(.horizontal, 7).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    }
                    Spacer(minLength: 0)
                    Text(timeLine(now: now)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityIdentifier("ota-scan-time-left")
                }
                ProgressView(value: value)
                    .animation(.linear(duration: 2), value: value)
                    .accessibilityLabel("Scan progress")
                    .accessibilityValue("\(progress.finished) of \(progress.total) \(progress.pass == 2 ? "stations" : "RF channels")")
                    .accessibilityIdentifier("ota-scan-progress")
                HStack {
                    Text("\(progress.finished) of \(progress.total) \(progress.pass == 2 ? "stations" : "RF channels")")
                        .font(.caption.monospacedDigit())
                        .accessibilityIdentifier("ota-scan-count")
                    Spacer()
                }
                HStack(spacing: 22) {
                    stat(progress.rows.count, "stations found", id: "ota-scan-multiplexes")
                    stat(progress.channelCount, "channels", id: "ota-scan-channels")
                    if !progress.lineupOnly { stat(progress.listingCount, "episodes", id: "ota-scan-listings") }
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))
        }
    }

    private var title: String {
        if progress.running { return progress.lineupOnly ? "Reading the channel list" : "Scanning the air" }
        let status = state.otaScanStatus
        if status.hasPrefix("Done") { return "Scan complete" }
        if status.localizedCaseInsensitiveContains("cancel") { return "Scan cancelled" }
        return progress.total == 0 ? "Scan" : "Scan finished"
    }

    private func timeLine(now: Date) -> String {
        if !progress.running { return progress.endedAt == nil ? "" : "took \(Self.clock(progress.elapsedSeconds(now: now)))" }
        guard let s = progress.estimatedSecondsRemaining(now: now) else { return "estimating…" }
        return s < 90 ? "about 1 min left" : "about \(Int((s / 60).rounded())) min left"
    }

    private func stat(_ n: Int, _ label: String, id: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(n)").font(.headline.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(n)")
        .accessibilityIdentifier(id)
    }

    // MARK: 2. the dial

    private var dialCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("The airwaves").font(.subheadline.bold())
                InfoButton("TV stations share the air like lanes on a road. The spectrum is cut into numbered slices called RF channels (2 to 13 in the VHF bands, 14 to 51 in UHF), each 6 MHz wide, and each bar here is one slice. A station uses one slice and fits several channels into it: that is a multiplex. The 5.1, 5.2 and 5.3 you tune are separate programs riding one shared stream of about 19.4 Mbit/s. The scan tunes every slice in turn; a tall bar is a slice with channels on it, and the more channels it carries, the taller the bar.")
                Spacer()
                Text(progress.running ? "Tuning…" : "\(progress.rows.count) multiplexes found")
                    .font(.caption).foregroundStyle(.secondary)
            }
            OTASpectrumDial(progress: progress, selectedRF: selectedRF, laneColor: laneColor) { pinnedRF = $0 }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))
    }

    // MARK: 3. tuners

    private var tunersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Tuners").font(.subheadline.bold())
                Picker("Tuners", selection: $state.otaTunerLimit) {
                    ForEach(1...max(1, state.otaTunerMax), id: \.self) { Text("use \($0)").tag($0) }
                }
                .labelsHidden().frame(width: 84)
                .accessibilityLabel("Tuners to use")
                .accessibilityIdentifier("ota-scan-tuners")
                Spacer()
                if let note = progress.note, progress.running {
                    Label(note, systemImage: "pause.circle").font(.caption).foregroundStyle(.orange).lineLimit(1)
                        .accessibilityIdentifier("ota-scan-status")
                } else if !progress.running, !state.otaScanStatus.isEmpty {
                    Text(state.otaScanStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .accessibilityIdentifier("ota-scan-status")
                }
            }
            TimelineView(.periodic(from: .now, by: 2)) { context in
                HStack(spacing: 10) {
                    ForEach(0..<max(1, state.otaTunerMax), id: \.self) { i in laneChip(i, now: context.date) }
                }
            }
        }
    }

    private enum LaneState { case reading, tuning, idle, steppedAside, off, ended }

    private func laneState(_ index: Int, lane: OTAScanLane?) -> LaneState {
        guard progress.running else { return .ended }
        if index >= state.otaTunerLimit && lane == nil { return .off }
        guard let lane else { return progress.note != nil ? .steppedAside : .idle }
        if let info = progress.rows.first(where: { $0.rf == lane.rf })?.info, info.bytes > 0, lane.elapsed() > 0 { return .reading }
        return .tuning
    }

    private func laneChip(_ index: Int, now: Date) -> some View {
        let lane = progress.lanes["tuner\(index)"]
        let st = laneState(index, lane: lane)
        let color = laneColor(index)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(laneLight(st)).frame(width: 9, height: 9)
                    .overlay(Circle().stroke(color, lineWidth: 1.5).frame(width: 14, height: 14))
                Text("Tuner \(index)").font(.caption.bold())
                Spacer(minLength: 0)
                Text(lane.map { "RF \($0.rf) · \(Self.mhz(Double(OTAScanner.frequencyHz(rf: $0.rf) ?? 0) / 1_000_000))" } ?? laneStateWord(st))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            ProgressView(value: lane?.fraction(now: now) ?? 0).tint(color)
                .animation(.linear(duration: 2), value: lane?.fraction(now: now))
                .opacity(lane == nil ? 0.25 : 1)
                .accessibilityLabel("Tuner \(index) progress")
                .accessibilityIdentifier("ota-scan-lane-progress-\(index)")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(lane == nil ? 0.04 : 0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(lane == nil ? 0.15 : 0.45), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tuner \(index)")
        .accessibilityValue(lane.map { "\(laneStateWord(st)), RF \($0.rf), \(Int($0.fraction(now: now) * 100)) percent" } ?? laneStateWord(st))
        .accessibilityIdentifier("ota-scan-lane-\(index)")
    }

    /// The tuner's light: green while reading, yellow while locking on, orange while stepped aside, grey otherwise.
    private func laneLight(_ st: LaneState) -> Color {
        switch st {
        case .reading: return .green
        case .tuning: return .yellow
        case .steppedAside: return .orange
        case .idle, .off, .ended: return .gray.opacity(0.5)
        }
    }

    private func laneStateWord(_ s: LaneState) -> String {
        switch s {
        case .reading: return "reading"
        case .tuning: return "tuning"
        case .idle: return "idle"
        case .steppedAside: return "stepped aside"
        case .off: return "not in use"
        case .ended: return "done"
        }
    }

    // MARK: 4. the selected multiplex

    fileprivate static let chipColors: [Color] = [.blue, .teal, .green, .orange, .pink, .purple, .indigo, .mint]

    private var multiplexSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let row = selectedRow {
                multiplexPanel(row)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "dot.radiowaves.left.and.right").font(.largeTitle).foregroundStyle(.tertiary)
                    Text(progress.running ? "Listening for stations…" : "No stations found.").foregroundStyle(.secondary)
                    if progress.running {
                        Text("Each bar above rises as a station is found. Tap one to see the channels it carries.")
                            .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(selectedRF.map { "ota-scan-mux-\($0)" } ?? "ota-scan-mux-none")
    }

    private var selectedRF: Int? {
        if let pinnedRF, progress.rows.contains(where: { $0.rf == pinnedRF }) { return pinnedRF }
        if let cur = progress.currentRF, progress.rows.contains(where: { $0.rf == cur }) { return cur }
        return followedRF.flatMap { f in progress.rows.contains(where: { $0.rf == f }) ? f : nil } ?? progress.rows.first?.rf
    }
    private var selectedRow: OTAMultiplexRow? { selectedRF.flatMap { rf in progress.rows.first { $0.rf == rf } } }

    private func multiplexPanel(_ row: OTAMultiplexRow) -> some View {
        let i = row.info
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                marker(row.state)
                Text("RF \(row.rf)").font(.title3.bold())
                Text(Self.mhz(i.frequencyMHz)).foregroundStyle(.secondary)
                Text(stateWord(row.state)).font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                Spacer(minLength: 0)
                if pinnedRF != nil, progress.running {
                    Button("Follow") { pinnedRF = nil }
                        .controlSize(.small)
                        .help("Go back to the station being read")
                        .accessibilityIdentifier("ota-scan-follow")
                }
                if let q = i.quality ?? i.strength {
                    HStack(spacing: 4) {
                        SignalBarsView(bucket: SignalBucket(Double(q) / 100))
                        Text("\(q)%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .help([i.strength.map { "Strength \($0)%" }, i.quality.map { "Quality \($0)%" }].compactMap { $0 }.joined(separator: " · "))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Signal")
                    .accessibilityValue([i.strength.map { "strength \($0) percent" }, i.quality.map { "quality \($0) percent" }].compactMap { $0 }.joined(separator: ", "))
                    .accessibilityIdentifier("ota-scan-signal")
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("One stream, shared by \(row.subChannels.count) channel\(row.subChannels.count == 1 ? "" : "s")").font(.subheadline.bold())
                    InfoButton("A multiplex is one transmitter on one slice of the spectrum. Its stream of about 19.4 Mbit/s is divided between the channels it carries, shown here as one block each. A channel number such as 5.2 reads station 5, sub-channel 2. Several stations' worth of channels can share a slice, which is why numbers from different networks can sit side by side. Tuning any one of these channels tunes the whole slice.")
                    Spacer(minLength: 0)
                    if let mbps = i.mbps { Text(String(format: "%.1f Mbit/s", mbps)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                }
                ChannelChips(row: row)
                    .id(row.rf)   // a different multiplex rebuilds the chips, so they slide in again
            }
            channelTable(row)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("RF \(row.rf), \(row.subChannels.count) channels, \(stateWord(row.state))")
    }

    private func channelTable(_ row: OTAMultiplexRow) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Channel").frame(maxWidth: .infinity, alignment: .leading)
                if !progress.lineupOnly {
                    Text("Episodes").frame(width: 64, alignment: .trailing)
                    Text("Reaches").frame(width: 66, alignment: .trailing)
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
            .padding(.bottom, 4)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(row.subChannels) { sub in
                        HStack(spacing: 6) {
                            Circle().fill(Self.chipColors[(row.subChannels.firstIndex(where: { $0.id == sub.id }) ?? 0) % Self.chipColors.count])
                                .frame(width: 7, height: 7)
                            Text(sub.number).font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                            Text(sub.name).font(.callout).lineLimit(1)
                            if sub.audioOnly {
                                Image(systemName: "speaker.wave.2").font(.caption).foregroundStyle(.secondary).help("Audio only")
                                    .accessibilityLabel("audio only")
                            }
                            Spacer(minLength: 4)
                            if !progress.lineupOnly {
                                Text(sub.listings > 0 ? "\(sub.listings)" : "–").font(.callout.monospacedDigit())
                                    .frame(width: 64, alignment: .trailing)
                                Text(sub.reachText() ?? (row.state == .scanning || row.state == .waiting ? "" : "no guide"))
                                    .font(.caption).foregroundStyle(.secondary)
                                    .frame(width: 66, alignment: .trailing)
                            }
                        }
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("ota-scan-sub-\(sub.number)")
                        Divider().opacity(0.4)
                    }
                }
            }
        }
    }

    // MARK: footer

    private var footer: some View {
        HStack {
            if progress.withoutSignal > 0 {
                Text("\(progress.withoutSignal) RF channel(s) with no signal").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if progress.running { Button("Cancel Scan") { state.cancelOTAScan() }.accessibilityIdentifier("ota-scan-cancel") }
            else { Button("Close") { dismissWindow(id: "ota-scan") }.accessibilityIdentifier("ota-scan-close") }
        }
    }

    // MARK: helpers

    static func mhz(_ v: Double) -> String { v == v.rounded() ? String(format: "%.0f MHz", v) : String(format: "%.1f MHz", v) }
    static func hoursText(_ h: Double) -> String { h < 48 ? "\(Int(h.rounded())) h" : String(format: "%.1f days", h / 24) }
    /// "6:12" / "1:02:30".
    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds)), h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    private func stateWord(_ s: OTAMultiplexRow.State) -> String {
        switch s { case .waiting: return "waiting for guide"; case .scanning: return "scanning"; case .done: return "done"; case .noGuide(let why): return "no guide: \(why)" }
    }

    @ViewBuilder private func marker(_ s: OTAMultiplexRow.State) -> some View {
        switch s {
        case .waiting: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        case .scanning: Image(systemName: "circle.inset.filled").foregroundStyle(Color.accentColor)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .noGuide: Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
        }
    }
}


/// The channels of one multiplex drawn as blocks of one shared stream, each in its own colour (the same colour as the dot in the list below),
/// sliding in one after the other when a multiplex is shown.
private struct ChannelChips: View {
    let row: OTAMultiplexRow
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(row.subChannels.enumerated()), id: \.element.id) { i, sub in
                let color = OTAScanView.chipColors[i % OTAScanView.chipColors.count]
                VStack(spacing: 1) {
                    Text(sub.number).font(.caption.monospacedDigit().bold())
                    if sub.audioOnly { Image(systemName: "speaker.wave.2").font(.system(size: 9)) }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(RoundedRectangle(cornerRadius: 6).fill(color.gradient))
                .scaleEffect(reduceMotion || shown ? 1 : 0.4)
                .opacity(reduceMotion || shown ? 1 : 0)
                .animation(.spring(response: 0.45, dampingFraction: 0.65).delay(Double(i) * 0.06), value: shown)
            }
        }
        .onAppear { shown = true }
        .accessibilityHidden(true)
    }
}
