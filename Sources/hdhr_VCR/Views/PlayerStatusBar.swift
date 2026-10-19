import SwiftUI
import AppKit

// The optional status bar under the player's video — docs/VLCPlayerView.md, "Status bar". A fixed 52 pt row that is
// part of the player window: poster (falling back to the channel's logo), title with genre tags and NEW, episode and
// time, the source's health with the live bitrate, and a small card for the next show on the channel.
//
// Everything shown is data the player already has — the current guide entry, the poster cache, the channel logo
// URLs, the guide's upcoming entries, VLC's throughput tracker, the tuner's signal quality — assembled by
// VLCPlayerView into a `PlayerStatusInfo`. This file holds that value type, the pure formatting/health rules (unit
// tested), and the view.

extension ThroughputTracker.State {
    /// Green steady, yellow trending down, red stalled; secondary (no color) while still measuring.
    var color: Color {
        switch self {
        case .measuring: return .secondary
        case .steady:    return .green
        case .trending:  return .yellow
        case .stalled:   return .red
        }
    }
}

/// What the bar shows, assembled by VLCPlayerView.
struct PlayerStatusInfo: Equatable {
    enum Source: Equatable {
        case liveTuner(deviceID: String, signalQuality: Int?)
        case recording                 // a recording played back from disk (the local relay): no tuner involved
        case feed(host: String?)       // another Mac's recording over the network: no tuner either
    }
    var title: String
    var episodeLine: String?           // "S02E05 · Episode title"
    var timeRange: String?             // "7:30 – 8:00 PM"
    var genres: [String]
    var detailLine: String?            // the synopsis, or "First aired …" when there is none
    var isNew: Bool
    var source: Source
    var airing: DateInterval? = nil     // when the show airs; drives the progress line (live tuner only)
    var slotEnd: Date? = nil           // when the guide says this show ends; past it while still on screen = running over
    var accent: Color? = nil           // the show's genre color (same palette as the guide grid); tints the bar
}

/// Pure formatting and rules for the bar.
enum PlayerStatusFormat {
    enum Health: Equatable {
        case measuring, good, fair, poor
        var label: String {
            switch self {
            case .measuring: return "Starting"
            case .good:      return "Good"
            case .fair:      return "Fair"
            case .poor:      return "Poor"
            }
        }
    }

    /// "7:30 – 8:00 PM", or "11:30 PM – 12:30 AM" when the two ends differ in AM/PM.
    static func timeRange(start: Date, end: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let withMeridiem = DateFormatter()
        withMeridiem.locale = locale; withMeridiem.timeZone = timeZone
        withMeridiem.setLocalizedDateFormatFromTemplate("jmm")
        let startText = withMeridiem.string(from: start), endText = withMeridiem.string(from: end)
        // Drop the first AM/PM only when both ends share it (US 12-hour style); 24-hour locales have none to drop.
        for marker in [" AM", " PM", "\u{202F}AM", "\u{202F}PM"] where startText.hasSuffix(marker) && endText.hasSuffix(marker) {
            return "\(startText.dropLast(marker.count)) – \(endText)"
        }
        return "\(startText) – \(endText)"
    }

    /// Up to `limit` genre tags from the guide's Filter list, upper-cased, without the "Series" meta-tag.
    static func genreTags(_ entry: GuideEntry, limit: Int = 2) -> [String] {
        var seen = Set<String>()
        var tags: [String] = []
        for raw in entry.Filter ?? [] {
            let tag = (raw.lowercased() == "movies" ? "Movie" : raw)
            guard tag.lowercased() != "series", seen.insert(tag.lowercased()).inserted else { continue }
            tags.append(tag.uppercased())
            if tags.count == limit { break }
        }
        return tags
    }

    /// Entries from `entries` that start at or after the current show's end, soonest first, within `horizon` seconds
    /// of `now`, at most `limit`.
    static func upcoming(after current: GuideEntry, in entries: [GuideEntry], now: Date = Date(),
                         horizon: TimeInterval = 6 * 3600, limit: Int = 8) -> [GuideEntry] {
        entries
            .filter { $0.StartTime >= current.EndTime && $0.startDate < now.addingTimeInterval(horizon) }
            .sorted { $0.StartTime < $1.StartTime }
            .prefix(limit)
            .map { $0 }
    }

    /// The bar's third line: the synopsis when the guide has one, else when the episode first aired (not for a NEW one), else nothing.
    static func detailLine(synopsis: String?, originalAirdate: Int?, isNew: Bool = false) -> String? {
        if let text = synopsis?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return text }
        guard !isNew, let oad = originalAirdate else { return nil }   // a NEW show's air date adds nothing
        return "First aired " + origAirdateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(oad)))
    }

    /// "33% smaller" / "50% larger" for the picture on screen against the video file's own size (by width), or nil
    /// when they match to the nearest percent.
    static func scaleNote(displayed: CGSize, native: CGSize) -> String? {
        guard native.width > 0, displayed.width > 0 else { return nil }
        let change = Int(((displayed.width / native.width - 1) * 100).rounded())
        if change == 0 { return nil }
        return change < 0 ? "\(-change)% smaller" : "\(change)% larger"
    }

    /// How far through the show `now` is, 0...1.
    static func progress(start: Date, end: Date, now: Date = Date()) -> Double {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return min(1, max(0, now.timeIntervalSince(start) / total))
    }

    /// "22 min left", "1 h 05 min left", "Ending", or nil before the show has started.
    static func remainingText(end: Date, now: Date = Date()) -> String {
        let minutes = Int((end.timeIntervalSince(now) / 60).rounded(.up))
        guard minutes > 0 else { return "Ending" }
        return minutes >= 60 ? String(format: "%d h %02d min left", minutes / 60, minutes % 60) : "\(minutes) min left"
    }

    /// The tuner/source text next to the health word.
    static func sourceText(_ source: PlayerStatusInfo.Source) -> String {
        switch source {
        case .liveTuner(let id, let quality):
            return "HDHR-\(id.uppercased())" + (quality.map { " · quality \($0)%" } ?? "")
        case .recording:
            return "From disk · no tuner used"
        case .feed(let host):
            return "FEED · \(host ?? "another Mac")"
        }
    }

    /// One health word from the stream's throughput state and, for a live tuner, its signal quality. The worse of the
    /// two wins; while throughput is still being measured, only a weak signal can move it off "Starting".
    static func health(throughput: ThroughputTracker.State, signalQuality: Int?) -> Health {
        func severity(_ h: Health) -> Int {
            switch h { case .measuring: return 0; case .good: return 1; case .fair: return 2; case .poor: return 3 }
        }
        let fromThroughput: Health
        switch throughput {
        case .measuring: fromThroughput = .measuring
        case .steady:    fromThroughput = .good
        case .trending:  fromThroughput = .fair
        case .stalled:   fromThroughput = .poor
        }
        let fromSignal: Health?
        if let q = signalQuality { fromSignal = q < 40 ? .poor : (q < 70 ? .fair : nil) } else { fromSignal = nil }
        guard let fromSignal else { return fromThroughput }
        return severity(fromSignal) > severity(fromThroughput) ? fromSignal : fromThroughput
    }

    /// Dot color for a health word.
    static func color(_ health: Health) -> Color {
        switch health {
        case .measuring: return .secondary
        case .good:      return .green
        case .fair:      return .yellow
        case .poor:      return .red
        }
    }
}

struct PlayerStatusBar: View {
    @ObservedObject var state: AppState
    @ObservedObject private var bridge = VLCBridge.shared
    let device: HDHRDevice
    let channel: LineupEntry?
    let info: PlayerStatusInfo
    let poster: NSImage?                 // the current show's image, already loaded by the player
    let channelLogoURL: String?          // the network logo to fall back to when the show has no image
    let upcoming: [GuideEntry]           // the channel's next shows, soonest first
    let canRecordUpcoming: Bool
    var shimmerToken = 0                     // bumped each time the bar opens; runs one shimmer wave across the current show's block
    var accessibilityID = "vlc-status-bar"   // the brief slide-up copy uses its own, so tests can tell the two apart

    @State private var logo: NSImage?
    @State private var shine: CGFloat = -1   // -1...1.6, the wave's position, animated here so nothing else interferes
    @State private var leadingID: Int?        // StartTime of the card at the left of the strip

    var body: some View {
        HStack(spacing: 14) {
            thumbnail(poster ?? logo, width: 56, height: 32)
            titleBlock
            if !upcoming.isEmpty {
                Rectangle().fill(Color.primary.opacity(0.28)).frame(width: 1.5, height: 38)   // now playing | up next
                nextStrip
            }
        }
        .padding(.horizontal, 10)
        .frame(height: VLCPlayerWindowManager.playerStatusBarHeight)
        .frame(maxWidth: .infinity)
        .background {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                if let accent = info.accent { accent.opacity(0.22) }
            }
        }
        .overlay(alignment: .top) {
            ZStack(alignment: .top) {
                Rectangle().fill(Color.primary.opacity(0.35)).frame(height: 1.5)   // edge between picture and bar
                if let airing = info.airing { progressLine(airing) }
            }
        }
        .focusEffectDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityID)
        .task(id: channelLogoURL) {
            guard let url = channelLogoURL else { logo = nil; return }
            logo = await ChannelIconCache.shared.image(for: url)
        }
        .onChange(of: upcoming.first?.StartTime) { _, _ in leadingID = nil }
        .task(id: shimmerToken) {
            guard shimmerToken > 0 else { return }
            shine = -1
            try? await Task.sleep(for: .milliseconds(900))   // let the bar drop and settle first
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 1.2)) { shine = 1.6 }
            try? await Task.sleep(for: .milliseconds(1300))
            shine = -1
        }
    }

    /// The image, or the app icon stand-in while neither the show's image nor the network logo is available.
    private func thumbnail(_ image: NSImage?, width: CGFloat, height: CGFloat) -> some View {
        Image(nsImage: image ?? stationLogoPlaceholder)
            .resizable()
            .scaledToFit()
            .frame(width: width, height: height)
            .background(Color.secondary.opacity(0.25), in: RoundedRectangle(cornerRadius: 3))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .accessibilityHidden(true)
    }

    private var titleBlock: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            // Running over: the guide's slot for this show has ended but we are still watching it (a Bonus Time
            // recording, or a FEED/recording playing past its slot) while the next show has already begun.
            let overrun: Bool = {
                guard let end = info.slotEnd, ctx.date > end.addingTimeInterval(30) else { return false }
                return true
            }()
            let nextStarted = upcoming.first.map { $0.startDate <= ctx.date } ?? false
            VStack(alignment: .leading, spacing: 1) {
                Text(headerLine(overrun: overrun, now: ctx.date))
                    .font(.system(size: 9, weight: .semibold)).tracking(0.4)
                    .foregroundStyle(overrun ? Color.orange : Color.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(info.title)
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1)
                    ForEach(info.genres, id: \.self) { tag in tagPill(tag, highlighted: false) }
                    if info.isNew { tagPill("NEW", highlighted: true) }
                }
                if overrun, nextStarted, let next = upcoming.first {
                    Text("Running over — \(next.Title) started at \(PlayerStatusBar.shortTime(next.startDate, now: ctx.date))")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.orange)
                        .lineLimit(1)
                } else {
                    let line = [info.episodeLine, info.detailLine].compactMap { $0 }.joined(separator: " · ")
                    if !line.isEmpty {
                        Text(line)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(line)
                    }
                }
            }
        }
        .frame(minWidth: 220, maxWidth: 560, alignment: .leading)
        .overlay { shimmer }
        .layoutPriority(1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vlc-status-title")
    }

    /// A slight, soft band of light that passes once over the current show's block to draw the eye.
    private var shimmer: some View {
        GeometryReader { g in
            // A soft, wide band: bright enough to catch the eye, slow and feathered enough not to distract.
            LinearGradient(stops: [.init(color: .clear, location: 0),
                                   .init(color: .white.opacity(0.14), location: 0.3),
                                   .init(color: .white.opacity(0.34), location: 0.5),
                                   .init(color: .white.opacity(0.14), location: 0.7),
                                   .init(color: .clear, location: 1)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: g.size.width * 0.5)
                .offset(x: shine * g.size.width - g.size.width * 0.25)
                .opacity(shine > -1 && shine < 1.4 ? 1 : 0)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// "NOW · 6:00 – 7:00 AM · 22 min left", or "OVER TIME · SCHEDULED 6:00 – 7:00 AM" once the slot has ended.
    private func headerLine(overrun: Bool, now: Date) -> String {
        if overrun { return "OVER TIME · SCHEDULED " + (info.timeRange ?? "") }
        return (["NOW", info.timeRange, info.airing.map { PlayerStatusFormat.remainingText(end: $0.end, now: now) }]
            .compactMap { $0 }).joined(separator: " · ")
    }

    /// A 2 pt line along the top edge: how far through the show we are.
    private func progressLine(_ airing: DateInterval) -> some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            GeometryReader { geo in
                Rectangle()
                    .fill(info.accent ?? Color.accentColor)
                    .frame(width: geo.size.width * PlayerStatusFormat.progress(start: airing.start, end: airing.end, now: ctx.date), height: 2)
            }
            .frame(height: 2)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func tagPill(_ text: String, highlighted: Bool) -> some View {
        Text(text)
            .font(.system(size: 8.5, weight: .bold))
            .tracking(0.5)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .foregroundStyle(highlighted ? Color.white : Color.secondary)
            .background(highlighted ? Color.accentColor : Color.secondary.opacity(0.18), in: Capsule())
            .fixedSize()
    }

    // MARK: Next on this channel

    private var leadingIndex: Int { upcoming.firstIndex { $0.StartTime == leadingID } ?? 0 }

    /// The channel's next shows side by side, filling the rest of the bar. The strip scrolls sideways (no scroll bar) and the arrows step one show at a time.
    private var nextStrip: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(Array(upcoming.enumerated()), id: \.element.StartTime) { index, entry in
                        UpcomingShowCard(entry: entry, label: entry.startDate <= Date() ? "STARTED" : (index == 0 ? "NEXT" : "LATER"), logo: logo) {
                            if canRecordUpcoming, let channel, !entry.isInfomercial { recordMenu(entry: entry, channel: channel) }
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $leadingID, anchor: .leading)
            .scrollTargetBehavior(.viewAligned)
            VStack(spacing: 2) {
                stepButton("chevron.left", label: "Previous show", enabled: leadingIndex > 0) { step(-1) }
                stepButton("chevron.right", label: "Later show", enabled: leadingIndex < upcoming.count - 1) { step(1) }
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 46)
        .background(Color.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vlc-status-next")
    }

    private func step(_ delta: Int) {
        let target = min(max(leadingIndex + delta, 0), upcoming.count - 1)
        withAnimation(.easeOut(duration: 0.25)) { leadingID = upcoming[target].StartTime }
    }

    private func stepButton(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold)).frame(width: 18, height: 16)
        }
        .buttonStyle(.plain)
        .background(Color.secondary.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
        .opacity(enabled ? 1 : 0.35)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    /// The same four recording types as the toolbar's Record button, applied to the shown upcoming show. Goes through
    /// `AppState.recordUpcoming`, not `quickRecord`: that one refuses while the device's tuners are full *right now*,
    /// which is the wrong test for a show that has not started.
    private func recordMenu(entry: GuideEntry, channel: LineupEntry) -> some View {
        Menu {
            ForEach(ShowState.allCases, id: \.self) { type in
                Button {
                    state.recordUpcoming(type: type, entry: entry, device: device, channel: channel)
                } label: {
                    Text(type.rawValue)
                    Text(recordTypeDescription[type] ?? "")
                }
            }
        } label: {
            Image(systemName: "record.circle")
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .foregroundStyle(.red)
        .fixedSize()
        .accessibilityLabel("Record \(entry.Title)")
        .accessibilityIdentifier("vlc-status-record-next")
        .help("Record \(entry.Title)")
    }

    /// "8:00 PM" today, "Sat 9:00 AM" on another day (`dropWeekday` keeps the compact "Then …" line short).
    static func shortTime(_ date: Date, now: Date, dropWeekday: Bool = false) -> String {
        let f = DateFormatter()
        if Calendar.current.isDate(date, inSameDayAs: now) || dropWeekday {
            f.setLocalizedDateFormatFromTemplate("jmm")
        } else {
            f.setLocalizedDateFormatFromTemplate("Ejmm")
        }
        return f.string(from: date)
    }
}

/// One upcoming show: its image, when it starts, its title, tinted with its genre color like the current show's bar.
struct UpcomingShowCard<Trailing: View>: View {
    let entry: GuideEntry
    let label: String          // "NEXT" or "LATER"
    let logo: NSImage?
    @ViewBuilder var trailing: () -> Trailing
    @State private var poster: NSImage?

    var body: some View {
        let tint: Color = entry.firstGenre == nil ? Color.secondary : guideEntryColor(for: entry, onAir: true)
        HStack(spacing: 8) {
            Image(nsImage: poster ?? logo ?? stationLogoPlaceholder)
                .resizable().scaledToFit()
                .frame(width: 48, height: 27)
                .background(Color.secondary.opacity(0.25), in: RoundedRectangle(cornerRadius: 3))
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(label) · \(PlayerStatusBar.shortTime(entry.startDate, now: Date()))")
                    .font(.system(size: 9, weight: .semibold)).tracking(0.4)
                    .foregroundStyle(.secondary).lineLimit(1)
                Text(entry.Title).font(.system(size: 11.5, weight: .bold)).lineLimit(1)
                if let line = PlayerStatusFormat.genreTags(entry, limit: 1).first {
                    Text(line).font(.system(size: 8.5, weight: .semibold)).tracking(0.5).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.horizontal, 8)
        .frame(width: 250, height: 42)
        .background {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                tint.opacity(entry.firstGenre == nil ? 0.12 : 0.30)
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .task(id: entry.ImageURL) {
            guard let url = entry.ImageURL else { poster = nil; return }
            poster = await ChannelIconCache.shared.image(for: url)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vlc-status-next-card")
    }
}

/// A small line graph of the throughput window (oldest reading on the left) with the 2-minute average as a dashed line.
/// Used by the player's stream popover.
struct ThroughputGraph: View {
    let samples: [Double]
    let average: Double?

    var body: some View {
        Canvas { context, size in
            guard samples.count > 1 else { return }
            let top = max(samples.max() ?? 1, (average ?? 0) * 1.1, 1)
            func point(_ index: Int, _ value: Double) -> CGPoint {
                CGPoint(x: size.width * CGFloat(index) / CGFloat(samples.count - 1),
                        y: size.height * (1 - CGFloat(value / top)))
            }
            var line = Path()
            line.move(to: point(0, samples[0]))
            for i in 1..<samples.count { line.addLine(to: point(i, samples[i])) }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(.primary.opacity(0.08)))
            context.stroke(line, with: .color(.primary.opacity(0.85)), lineWidth: 1.5)
            if let average {
                let y = size.height * (1 - CGFloat(average / top))
                var dashed = Path()
                dashed.move(to: CGPoint(x: 0, y: y))
                dashed.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(dashed, with: .color(.secondary), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
    }
}
