import SwiftUI

// Shared brand colors used by MenuContent, WatchNowView, and VLCPlayerView.
let watchNowBlue   = Color(red: 0.2, green: 0.6, blue: 1.0)
let watchNowOrange = Color(red: 1.0, green: 0.482, blue: 0.0)

// Shared DateFormatters used by AddShowView, FloatingGuideView, and CableGuideView.
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
    var body: some View {
        Path { p in
            p.move(to: .zero)
            p.addLine(to: CGPoint(x: size, y: 0))
            p.addLine(to: CGPoint(x: size, y: size))
            p.closeSubpath()
        }
        .fill(Color.yellow)
        .frame(width: size, height: size)
        .accessibilityLabel("Already scheduled")
    }
}

func sortedGuideChannels(_ channels: [GuideChannel], favorites: Set<String>) -> [GuideChannel] {
    channels.sorted { a, b in
        let af = favorites.contains(a.GuideNumber)
        let bf = favorites.contains(b.GuideNumber)
        if af != bf { return af }
        return a.GuideNumber.channelSortKey < b.GuideNumber.channelSortKey
    }
}
