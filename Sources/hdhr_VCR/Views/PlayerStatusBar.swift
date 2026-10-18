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
    var isNew: Bool
    var source: Source
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

    @State private var logo: NSImage?
    @State private var nextPoster: NSImage?
    @State private var nextIndex = 0

    private var nextEntry: GuideEntry? { upcoming.indices.contains(nextIndex) ? upcoming[nextIndex] : upcoming.first }

    var body: some View {
        HStack(spacing: 14) {
            thumbnail(poster ?? logo, width: 56, height: 32)
            titleBlock
            tunerBlock
            if let next = nextEntry { nextCard(next) }
        }
        .padding(.horizontal, 10)
        .frame(height: VLCPlayerWindowManager.playerStatusBarHeight)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vlc-status-bar")
        .task(id: channelLogoURL) {
            guard let url = channelLogoURL else { logo = nil; return }
            logo = await ChannelIconCache.shared.image(for: url)
        }
        .task(id: nextEntry?.ImageURL) {
            guard let url = nextEntry?.ImageURL else { nextPoster = nil; return }
            nextPoster = await ChannelIconCache.shared.image(for: url)
        }
        .onChange(of: upcoming.first?.StartTime) { _, _ in nextIndex = 0 }
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
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(info.title)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
                ForEach(info.genres, id: \.self) { tag in tagPill(tag, highlighted: false) }
                if info.isNew { tagPill("NEW", highlighted: true) }
            }
            Text([info.episodeLine, info.timeRange].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var tunerBlock: some View {
        let quality: Int? = { if case .liveTuner(_, let q) = info.source { return q } else { return nil } }()
        let health = PlayerStatusFormat.health(throughput: bridge.throughput.state, signalQuality: quality)
        return HStack(spacing: 6) {
            Circle().fill(PlayerStatusFormat.color(health)).frame(width: 9, height: 9)
            (Text(health.label).bold()
                + Text(" · " + PlayerStatusFormat.sourceText(info.source))
                + Text(bridge.throughput.currentMbps.map { String(format: " · %.1f Mbps", $0) } ?? "")
                    .foregroundColor(bridge.throughput.state.color))
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: 300, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Stream health")
        .accessibilityIdentifier("vlc-status-health")
    }

    // MARK: Next on this channel

    private func nextCard(_ next: GuideEntry) -> some View {
        let now = Date()
        let isFirst = nextIndex == 0
        let after = upcoming.dropFirst(nextIndex + 1).prefix(2)
        return HStack(spacing: 8) {
            thumbnail(nextPoster ?? logo, width: 48, height: 27)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(isFirst ? "NEXT" : "LATER") · \(Self.shortTime(next.startDate, now: now))")
                    .font(.system(size: 9, weight: .semibold)).tracking(0.4)
                    .foregroundStyle(.secondary).lineLimit(1)
                Text(next.Title).font(.system(size: 11.5, weight: .bold)).lineLimit(1)
                if !after.isEmpty {
                    Text("Then " + after.map { "\(Self.shortTime($0.startDate, now: now, dropWeekday: true)) \($0.Title)" }.joined(separator: " · "))
                        .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 2) {
                stepButton("chevron.left", label: "Previous show", enabled: nextIndex > 0) { nextIndex -= 1 }
                stepButton("chevron.right", label: "Later show", enabled: nextIndex < upcoming.count - 1) { nextIndex += 1 }
            }
            if canRecordUpcoming, let channel, !next.isInfomercial { recordMenu(entry: next, channel: channel) }
        }
        .padding(.horizontal, 8)
        .frame(minWidth: 200, idealWidth: 240, maxWidth: 270)
        .frame(height: 42)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vlc-status-next")
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
            Image(systemName: "record.circle").foregroundStyle(.red)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
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
