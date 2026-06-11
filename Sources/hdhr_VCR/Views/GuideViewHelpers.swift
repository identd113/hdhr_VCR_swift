import SwiftUI

// Shared brand colors used by MenuContent, WatchNowView, and VLCPlayerView.
let watchNowBlue   = Color(red: 0.2, green: 0.6, blue: 1.0)
let watchNowOrange = Color(red: 1.0, green: 0.482, blue: 0.0)

// Shared DateFormatters used by WebServer, WatchNowView, and VLCPlayerView.
let origAirdateFormatter: DateFormatter = {
    let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
}()
let upcomingFormatter: DateFormatter = {
    let f = DateFormatter()
    // "Ejmm": E=short weekday, j=locale-preferred hour (12h or 24h), mm=minutes
    f.dateFormat = DateFormatter.dateFormat(fromTemplate: "Ejmm", options: 0, locale: .current)
    return f
}()
let timeRangeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = DateFormatter.dateFormat(fromTemplate: "jmm", options: 0, locale: .current)
    return f
}()

// Accessibility labels shared by FloatingGuideView and WatchNowView — single source of truth.
func watchInAppLabel(_ title: String) -> String { "Watch \(title)" }
func watchInVLCLabel(_ title: String) -> String { "Watch \(title) in VLC" }

func guideTimeRange(_ entry: GuideEntry) -> String {
    "\(timeRangeFormatter.string(from: entry.startDate)) – \(timeRangeFormatter.string(from: entry.endDate))"
}

func timeRemaining(until endDate: Date) -> String {
    let mins = Int(max(0, endDate.timeIntervalSinceNow) / 60)
    if mins < 1  { return "ending soon" }
    if mins < 60 { return "\(mins)m left" }
    let h = mins / 60; let m = mins % 60
    return m == 0 ? "\(h)h left" : "\(h)h \(m)m left"
}

func he(_ s: String) -> String {
    s.replacingOccurrences(of: "&",  with: "&amp;")
     .replacingOccurrences(of: "<",  with: "&lt;")
     .replacingOccurrences(of: ">",  with: "&gt;")
     .replacingOccurrences(of: "\"", with: "&quot;")
}

struct ManagedFlagView: View {
    var size: CGFloat = 20
    var recording: Bool = false
    var body: some View {
        Path { p in
            p.move(to: .zero)
            p.addLine(to: CGPoint(x: size, y: 0))
            p.addLine(to: CGPoint(x: size, y: size))
            p.closeSubpath()
        }
        .fill(recording ? Color(red: 1, green: 0.376, blue: 0.376) : Color.yellow)
        .frame(width: size, height: size)
        .accessibilityLabel(recording ? "Recording now" : "Already scheduled")
    }
}

// MARK: - Guide entry color

private let _genreColorMap: [String: Color] = [
    "drama":    Color(hue: 0.60,  saturation: 0.65, brightness: 0.62),
    "comedy":   Color(hue: 0.13,  saturation: 0.65, brightness: 0.62),
    "news":     Color(hue: 0.95,  saturation: 0.60, brightness: 0.58),
    "sports":   Color(hue: 0.33,  saturation: 0.65, brightness: 0.56),
    "reality":  Color(hue: 0.07,  saturation: 0.65, brightness: 0.62),
    "movie":    Color(hue: 0.75,  saturation: 0.80, brightness: 0.68),
    "talk":     Color(hue: 0.48,  saturation: 0.60, brightness: 0.58),
    "children": Color(hue: 0.875, saturation: 0.60, brightness: 0.62),
    "kids":     Color(hue: 0.875, saturation: 0.60, brightness: 0.62),
]

func guideEntryColor(for entry: GuideEntry, onAir: Bool) -> Color {
    let base = _genreColorMap[entry.firstGenre?.lowercased() ?? ""] ?? Color(white: 0.22)
    return onAir ? base : base.opacity(0.75)
}

// MARK: - Signal quality UI helpers

@MainActor
func signalBucket(guideName: String) -> SignalBucket {
    ChannelSignalStore.shared.buckets[ChannelSignalStore.key(for: guideName)] ?? .noData
}

struct SignalBarsView: View {
    let bucket: SignalBucket
    // When set, the bars become a tap target that shows a signal-stats popover.
    // Left nil in the menu (NSMenu can't host a SwiftUI popover); set in window contexts.
    var guideName: String? = nil
    @State private var showStats = false

    var body: some View {
        if bucket != .noData {
            if let guideName {
                Button { showStats.toggle() } label: { barsRow }
                    .buttonStyle(.plain)
                    // Enlarge the hit area — the bars themselves are only ~11pt wide.
                    .contentShape(Rectangle())
                    .help("Signal stats")
                    .popover(isPresented: $showStats, arrowEdge: .bottom) {
                        SignalStatsPopover(guideName: guideName)
                    }
            } else {
                barsRow
            }
        }
    }

    private var barsRow: some View {
        HStack(alignment: .bottom, spacing: 1) {
            bar(4); bar(7, bucket != .poor); bar(10, bucket == .good)
        }
    }

    private func bar(_ h: CGFloat, _ filled: Bool = true) -> some View {
        RoundedRectangle(cornerRadius: 0.5).frame(width: 3, height: h)
            .foregroundColor(filled ? barColor : Color.secondary.opacity(0.25))
    }

    private var barColor: Color {
        switch bucket {
        case .poor:          return .red
        case .fair:          return .yellow
        case .good, .noData: return .green
        }
    }
}

// Tap-to-inspect popover for the signal bars. Leads with freshness ("Last checked")
// since a stale reading says little about how recordable the channel is right now.
private struct SignalStatsPopover: View {
    let guideName: String

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .full; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(guideName).font(.headline)
            if let s = ChannelSignalStore.shared.stats(guideName: guideName) {
                grid(s)
            } else {
                Text("No signal data yet — run a scan.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 230)
    }

    private func grid(_ s: ChannelSignalStore.SignalStats) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            row("Signal", "\(label(s.bucket)) · \(s.avg)% avg")
            row("Last reading", "\(s.last)%")
            row("Range", "\(s.min)–\(s.max)%")
            row("Last checked", Self.relative.localizedString(for: s.lastSampled, relativeTo: Date()))
            row("Samples", "\(s.windowCount) recent / \(s.totalCount) total")
        }
        .font(.callout)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }

    private func label(_ b: SignalBucket) -> String {
        switch b {
        case .poor:   return "Poor"
        case .fair:   return "Fair"
        case .good:   return "Good"
        case .noData: return "No data"
        }
    }
}
