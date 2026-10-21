import SwiftUI

// Over-the-air scan dashboard (docs/OTAScanView.md): a floating window that opens when a scan starts.
//   1. Overview: what the scan is doing, one smooth progress bar for the whole scan, a time estimate and running totals.
//   2. One lane per tuner: a light (reading / tuning / idle / stepped aside / off), the station it is on, a progress bar for that read
//      (time so far against the longest it can take) and live readings. Each tuner has its own colour, repeated on the station tabs.
//   3. The stations found, as tabs: the one being read is selected automatically (until you click another), with its guide reach,
//      its channels and how many episodes each has.
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
            lanesSection
            stationsSection
            footer
        }
        .padding(16)
        .frame(width: 520, height: 700)
        .accessibilityIdentifier("ota-scan-window")
        .background(WindowAction(trigger: true) { $0.level = .floating })
    }

    // MARK: 1. overview

    private var overview: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
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
                    .accessibilityLabel("Scan progress")
                    .accessibilityValue("\(progress.finished) of \(progress.total) \(progress.pass == 2 ? "stations" : "RF channels")")
                    .accessibilityIdentifier("ota-scan-progress")
                HStack {
                    Text("\(progress.finished) of \(progress.total) \(progress.pass == 2 ? "stations" : "RF channels")")
                        .font(.caption.monospacedDigit())
                        .accessibilityIdentifier("ota-scan-count")
                    Spacer()
                    Text("elapsed \(Self.clock(progress.elapsedSeconds(now: now)))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
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

    // MARK: 2. tuner lanes

    private var lanesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
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
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                HStack(spacing: 10) {
                    ForEach(0..<max(1, state.otaTunerMax), id: \.self) { i in laneCard(i, now: context.date) }
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

    private func laneCard(_ index: Int, now: Date) -> some View {
        let tuner = "tuner\(index)"
        let lane = progress.lanes[tuner]
        let st = laneState(index, lane: lane)
        let color = laneColor(index)
        let info = lane.flatMap { l in progress.rows.first(where: { $0.rf == l.rf })?.info }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                light(st, color: color)
                Text("Tuner \(index)").font(.caption.bold())
                Spacer(minLength: 0)
                Text(laneStateWord(st)).font(.caption2).foregroundStyle(laneStateColor(st))
            }
            if let lane {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("RF \(lane.rf)").font(.title3.bold())
                    Text(Self.mhz(Double(OTAScanner.frequencyHz(rf: lane.rf) ?? 0) / 1_000_000)).font(.caption).foregroundStyle(.secondary)
                }
                ProgressView(value: lane.fraction(now: now)).tint(color)
                    .accessibilityLabel("Tuner \(index) progress")
                    .accessibilityIdentifier("ota-scan-lane-progress-\(index)")
                Text("\(Int(lane.elapsed(now: now))) s of up to \(Int(lane.expectedSeconds)) s")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                Text(laneReadings(info)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text(laneIdleText(st)).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 112, maxHeight: 112, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(lane == nil ? 0.04 : 0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(lane == nil ? 0.15 : 0.45), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tuner \(index)")
        .accessibilityValue(lane.map { "\(laneStateWord(st)), RF \($0.rf), \(Int($0.fraction(now: now) * 100)) percent" } ?? laneStateWord(st))
        .accessibilityIdentifier("ota-scan-lane-\(index)")
    }

    /// The tuner's light: green while reading, yellow while locking on, orange while stepped aside, grey otherwise.
    @ViewBuilder private func light(_ st: LaneState, color: Color) -> some View {
        let lit: Color = {
            switch st {
            case .reading: return .green
            case .tuning: return .yellow
            case .steppedAside: return .orange
            case .idle, .off, .ended: return .gray.opacity(0.5)
            }
        }()
        ZStack {
            Circle().stroke(color.opacity(0.6), lineWidth: 1.5).frame(width: 14, height: 14)
            Image(systemName: "circle.fill").font(.system(size: 8)).foregroundStyle(lit)
                .symbolEffect(.pulse, options: .repeating, isActive: st == .reading || st == .tuning)
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
    private func laneStateColor(_ s: LaneState) -> Color {
        switch s { case .reading: return .green; case .tuning: return .yellow; case .steppedAside: return .orange; default: return .secondary }
    }
    private func laneIdleText(_ s: LaneState) -> String {
        switch s {
        case .off: return "Left out: the scan is using \(state.otaTunerLimit) of \(state.otaTunerMax) tuners."
        case .steppedAside: return progress.note ?? "Stepped aside."
        case .ended: return "Finished."
        default: return "Waiting for the next station."
        }
    }
    /// Live readings for the station on this tuner: what has been found so far, the data rate and the tuner's signal.
    private func laneReadings(_ info: OTAMuxInfo?) -> String {
        guard let info, info.bytes > 0 else { return "locking on…" }
        var parts: [String] = []
        if let mbps = info.mbps { parts.append(String(format: "%.1f Mbit/s", mbps)) }
        if let q = info.quality { parts.append("signal \(q)%") }
        return parts.isEmpty ? "reading…" : parts.joined(separator: " · ")
    }

    // MARK: 3. stations

    private var stationsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Stations").font(.subheadline.bold())
                if !progress.rows.isEmpty { Text("\(progress.rows.count)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
            }
            if progress.rows.isEmpty {
                Text(progress.running ? "Looking for stations…" : "No stations found.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                Spacer(minLength: 0)
            } else {
                tabStrip
                if let row = selectedRow { panel(row) }
            }
        }
    }

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
        let readingOn = progress.lanes.filter { $0.value.rf == row.rf }.keys.compactMap { Int($0.dropFirst("tuner".count)) }.sorted()
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
            // A dot in each reading tuner's colour, so a lane above and the tab it is working on match.
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 2) { ForEach(readingOn, id: \.self) { Circle().fill(laneColor($0)).frame(width: 7, height: 7) } }
                    .padding(3)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("RF \(row.rf), \(row.subChannels.count) channels, \(stateWord(row.state))")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("ota-scan-tab-\(row.rf)")
    }

    // MARK: the selected station

    private func panel(_ row: OTAMultiplexRow) -> some View {
        let i = row.info
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                marker(row.state)
                Text("RF \(row.rf)").font(.title3.bold())
                Text(Self.mhz(i.frequencyMHz)).foregroundStyle(.secondary)
                Text(stateWord(row.state)).font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                Spacer(minLength: 0)
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
            HStack(spacing: 8) {
                tile("\(row.subChannels.count)", "channels", id: "channels")
                if !progress.lineupOnly {
                    tile(i.episodes > 0 ? "\(i.episodes)" : "–", "episodes", id: "episodes")
                    tile(guideTileValue(row), "guide ahead", id: "guide")
                }
            }
            channelTable(row)
            Text(footnote(row)).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                .accessibilityIdentifier("ota-scan-facts")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("RF \(row.rf), \(row.subChannels.count) channels, \(stateWord(row.state))")
        .accessibilityIdentifier("ota-scan-mux-\(row.rf)")
    }

    private func tile(_ value: String, _ label: String, id: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.title3.monospacedDigit().bold()).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.10)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
        .accessibilityIdentifier("ota-scan-tile-\(id)")
    }

    /// How far ahead the station's guide reaches, or why there is none.
    private func guideTileValue(_ row: OTAMultiplexRow) -> String {
        let i = row.info
        if let hours = i.guideHoursAhead() { return Self.hoursText(hours) }
        if i.guideTablesAnnounced == 0, row.state != .scanning { return "none sent" }
        return "reading…"
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
                            Group {
                                if row.state == .scanning && !sub.done { ProgressView().controlSize(.mini) }
                                else if row.state == .scanning { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                                else { Color.clear }
                            }
                            .frame(width: 14)
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

    /// The technical readings, kept small: data rate, listing tables announced, the station's clock against this Mac's.
    private func footnote(_ row: OTAMultiplexRow) -> String {
        let i = row.info
        var parts: [String] = []
        if let mbps = i.mbps { parts.append(String(format: "%.1f Mbit/s over %d s", mbps, Int(i.seconds.rounded()))) }
        if i.guideTablesAnnounced > 0, !progress.lineupOnly { parts.append("\(i.guideTablesAnnounced) listing tables") }
        if let off = i.clockOffset() { parts.append(abs(off) <= 2 ? "clock in step with this Mac" : "clock \(off > 0 ? "+" : "")\(off) s vs this Mac") }
        return parts.joined(separator: " · ")
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
        case .scanning: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .noGuide: Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
        }
    }
}
