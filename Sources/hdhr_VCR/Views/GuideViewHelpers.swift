import SwiftUI
import AppKit

// Shared brand colors used by MenuContent, WatchNowView, and VLCPlayerView.
let watchNowBlue   = Color(red: 0.2, green: 0.6, blue: 1.0)
let watchNowOrange = Color(red: 1.0, green: 0.482, blue: 0.0)
// Matches the web guide's Record button (WebServer.swift, `#c0392b`) — same "record" red everywhere.
let recordRed      = Color(red: 0.753, green: 0.224, blue: 0.169)
// Matches the web guide's --fav CSS custom property (WebServer.swift: #e8a000 dark / #a05800
// light) — same favorites amber everywhere. Source of truth is the Guide; other views adapt to it.
let favAmber = Color(NSColor(name: nil) { appearance in
    let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    return isDark
        ? NSColor(srgbRed: 0xE8 / 255.0, green: 0xA0 / 255.0, blue: 0x00 / 255.0, alpha: 1)
        : NSColor(srgbRed: 0xA0 / 255.0, green: 0x58 / 255.0, blue: 0x00 / 255.0, alpha: 1)
})

// MARK: - Quick-record menu

// Kept in sync by hand with guide.js's recOpts[].d — same four strings, same order, describing
// the same four ShowState cases. (Web guide's own Record modal has its own richer UI — folder,
// transcode, bonus time, other-airings panel — so it doesn't share this; this is specifically
// the pared-down "just pick a type" version for surfaces with no room for a full form.)
let recordTypeDescription: [ShowState: String] = [
    .single:        "Record this airing only",
    .dateTime:      "Record at this time each week",
    .seriesChannel: "Record new episodes on this channel",
    .seriesAll:     "Record new episodes on any channel",
]

// Four-type pulldown wrapping AppState.quickRecord(type:entry:device:channel:) — which goes
// straight through addShowFromGuide(...), the same function the web guide's own quick-record
// path (WebServer.swift's handleRecord) already uses, with every optional left at its default
// (transcode/bonusTime/airDays) — rather than opening the Add Show wizard. Shared by
// WatchNowRow's Record button and VLCPlayerView's toolbar Record button so the two don't
// duplicate the same Menu-building code and description strings.
//
// Also exposes the same four picks as accessibility custom actions on the control itself, not
// just as menu items reachable by opening the popup: (1) a real accessibility win — VoiceOver
// users get "Record Single"/"Record DateTime"/etc. on the rotor without needing to visually
// navigate an ephemeral popup — and (2) unlike the popup (a stock SwiftUI Menu, not worth
// scripting), a custom accessibility action can be invoked directly and reliably via AppleScript/
// System Events' `perform action`, no NSMenu-tracking flakiness involved, for anyone who does
// want to drive this via UI automation later.
@MainActor @ViewBuilder
func quickRecordMenu<Content: View>(
    state: AppState, entry: GuideEntry, device: HDHRDevice, channel: LineupEntry,
    tunerFullAlert: Binding<Bool>, @ViewBuilder label: () -> Content
) -> some View {
    // Mirrors the web guide's own withholding of a real Record affordance for paid programming
    // (data-inf gates the genre-filter's "hide infomercials" mode there); this is the one place
    // both native surfaces that use this control (WatchNowRow, VLCPlayerView toolbar) can pick it
    // up for free, per entry.isInfomercial's own doc comment.
    if entry.isInfomercial {
        EmptyView()
    } else {
        Menu {
            ForEach(ShowState.allCases, id: \.self) { type in
                Button {
                    if !state.quickRecord(type: type, entry: entry, device: device, channel: channel) {
                        tunerFullAlert.wrappedValue = true
                    }
                } label: {
                    Text(type.rawValue)
                    Text(recordTypeDescription[type] ?? "")
                }
            }
        } label: {
            label()
        }
        .accessibilityAction(named: Text(ShowState.single.rawValue)) {
            if !state.quickRecord(type: .single, entry: entry, device: device, channel: channel) { tunerFullAlert.wrappedValue = true }
        }
        .accessibilityAction(named: Text(ShowState.dateTime.rawValue)) {
            if !state.quickRecord(type: .dateTime, entry: entry, device: device, channel: channel) { tunerFullAlert.wrappedValue = true }
        }
        .accessibilityAction(named: Text(ShowState.seriesChannel.rawValue)) {
            if !state.quickRecord(type: .seriesChannel, entry: entry, device: device, channel: channel) { tunerFullAlert.wrappedValue = true }
        }
        .accessibilityAction(named: Text(ShowState.seriesAll.rawValue)) {
            if !state.quickRecord(type: .seriesAll, entry: entry, device: device, channel: channel) { tunerFullAlert.wrappedValue = true }
        }
    }
}

// MARK: - Unsaved-changes alert

// Shared by EditShowView (onExitCommand + onChange(of: state.editingShowId)) and SettingsView's
// WindowCloseInterceptor — all three ran the same NSAlert shape independently before this.
enum UnsavedChangesChoice { case save, discard, cancel }

@MainActor
func promptUnsavedChanges(title: String, canSave: Bool, savePrompt: String, blockedPrompt: String) -> UnsavedChangesChoice {
    let alert = NSAlert()
    alert.messageText = title
    if canSave {
        alert.informativeText = savePrompt
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:  return .save
        case .alertSecondButtonReturn: return .discard
        default:                       return .cancel
        }
    } else {
        alert.informativeText = blockedPrompt
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .discard
        default:                      return .cancel
        }
    }
}

// Shared DateFormatters used by WebServer, WatchNowView, and VLCPlayerView.
let origAirdateFormatter: DateFormatter = {
    // OriginalAirdate from the guide API is midnight UTC for the air date — force UTC so US
    // timezones don't roll it back to the previous day's evening.
    let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
    f.timeZone = TimeZone(identifier: "UTC"); return f
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

// Appends "(Requires <requirement>)" to a control's label whenever the gating condition (VLC
// installed, Web LAN on, etc.) isn't met — the single place this hand-rolled-everywhere ternary
// pattern lives, used by MenuContent/WatchNowView/SettingsView/FirstRunWizardView so the wording
// can't drift between call sites the way "Requires Web LAN" vs "Requires VLC" phrasing already had.
func gatedLabel(_ base: String, met: Bool, requirement: String) -> String {
    met ? base : "\(base) (Requires \(requirement))"
}

// Accessibility labels for WatchNowView's Watch/Watch-in-VLC buttons.
func watchInAppLabel(_ title: String) -> String { "Watch \(title)" }
func watchInVLCLabel(_ title: String) -> String { "Watch \(title) in VLC" }
// Accessibility labels for the two choices offered when watching a currently-recording show.
func watchFromBeginningLabel(_ title: String) -> String { "Watch \(title) from the beginning" }
func watchLiveLabel(_ title: String) -> String { "Watch \(title) live" }

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

// Returns true when OriginalAirdate (midnight UTC for the broadcast calendar date) matches
// today or tonight in the server's local timezone — a proxy for "new/first-run today."
func isNewEpisode(_ entry: GuideEntry) -> Bool {
    guard let oad = entry.OriginalAirdate else { return false }
    var utcCal = Calendar(identifier: .gregorian)
    utcCal.timeZone = TimeZone(identifier: "UTC")!
    let localCal   = Calendar.current
    let nowDate    = Date()
    let oadComps   = utcCal.dateComponents([.year, .month, .day],
                         from: Date(timeIntervalSince1970: TimeInterval(oad)))
    let todayComps = localCal.dateComponents([.year, .month, .day], from: nowDate)
    if oadComps == todayComps { return true }
    // Late-night shows after midnight whose broadcast date is "tomorrow" locally.
    let tomorrowStart = localCal.startOfDay(for: localCal.date(byAdding: .day, value: 1, to: nowDate)!)
    let tomorrowComps = localCal.dateComponents([.year, .month, .day], from: tomorrowStart)
    if oadComps == tomorrowComps {
        let tomorrowMidnightUTC = Int(tomorrowStart.timeIntervalSince1970)
        let tomorrowLateNightEnd = Int(tomorrowStart.addingTimeInterval(5 * 3600).timeIntervalSince1970)
        if entry.StartTime >= tomorrowMidnightUTC && entry.StartTime < tomorrowLateNightEnd { return true }
    }
    return false
}

// Checked once before falling through to the 4 replacingOccurrences passes below — most guide
// text (titles, channel names) contains none of these, and each pass is a full string scan +
// allocation regardless of whether it finds anything, so skipping straight to "already safe" for
// the common case avoids paying for 4 no-op scans. Called on the order of a dozen times per grid
// entry across ~1300+ program blocks per rebuild (buildGuideGridHTML, buildTunerShowsHTML,
// buildDevBarHTML, buildSumPhHTML), on @MainActor.
private let htmlEscapeChars = CharacterSet(charactersIn: "&<>\"")

func he(_ s: String) -> String {
    guard s.rangeOfCharacter(from: htmlEscapeChars) != nil else { return s }
    return s.replacingOccurrences(of: "&",  with: "&amp;")
            .replacingOccurrences(of: "<",  with: "&lt;")
            .replacingOccurrences(of: ">",  with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
}

// MARK: - Guide ring/badge (native equivalent of the web guide's .g-st-* status ring)

// Colors match the web guide's --vc-* CSS custom properties (WebServer.swift/guide.css) exactly,
// so the same fact reads the same way on both surfaces. Badge glyphs are the closest SF Symbol
// equivalent of each web glyph (⏱/⏺/⏭/⚠/▶) rather than the literal Unicode character, since SF
// Symbols render more reliably at small native sizes than fallback text glyphs do.
extension GuideRingState {
    var ringColor: Color? {
        switch self {
        case .recording:      return Color(red: 1.0,   green: 0.353, blue: 0.353) // #ff5a5a
        case .willSkip:       return Color(red: 0.541, green: 0.573, blue: 0.639) // #8a92a3
        case .conflict:       return Color(red: 1.0,   green: 0.584, blue: 0.0)   // #ff9500
        case .scheduled:      return Color(red: 0.231, green: 0.576, blue: 1.0)   // #3b93ff
        case .inUseOtherTuner: return Color(red: 0.608, green: 0.349, blue: 0.714) // #9b59b6
        case .none:            return nil
        }
    }
    var badgeSymbol: String? {
        switch self {
        case .recording:       return "record.circle.fill"
        case .willSkip:        return "forward.end.fill"
        case .conflict:        return "exclamationmark.triangle.fill"
        case .scheduled:       return "clock.fill"
        case .inUseOtherTuner: return "play.fill"
        case .none:             return nil
        }
    }
    // Lowercase-led so callers can concatenate naturally as "\(title), \(suffix)" — matches
    // WatchNowRow's existing accessibility-label convention (e.g. "\(title), scheduled").
    var tooltipSuffix: String {
        switch self {
        case .recording:       return "recording now"
        case .willSkip:        return "already recorded, will skip"
        case .conflict:        return "conflict, all tuners busy at this time"
        case .scheduled:       return "scheduled to record"
        case .inUseOtherTuner: return "in use by another tuner, not managed by this app"
        case .none:             return ""
        }
    }
}

private struct GuideRingBadge: ViewModifier {
    let state: GuideRingState
    func body(content: Content) -> some View {
        content.overlay {
            if let color = state.ringColor {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(color, lineWidth: 2)
                    .modifier(PulseIfRecording(active: state == .recording, color: color))
            }
        }
        .overlay(alignment: .topTrailing) {
            if let color = state.ringColor, let symbol = state.badgeSymbol {
                Circle()
                    .fill(color)
                    .frame(width: 18, height: 18)
                    .overlay {
                        Image(systemName: symbol)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .shadow(color: .black.opacity(0.4), radius: 1, y: 1)
                    .padding(3)
                    .modifier(PulseIfRecording(active: state == .recording, color: color))
            }
        }
    }
}

// Matches the web guide's 1.6s ease-in-out ring/badge pulse (guide.css's gRingPulse/gRecPulse
// keyframes) for the recording state only — every other state is static, same as the web version.
private struct PulseIfRecording: ViewModifier {
    let active: Bool
    let color: Color
    @State private var dimmed = false
    func body(content: Content) -> some View {
        content
            .opacity(active && dimmed ? 0.5 : 1)
            .onAppear { syncAnimation() }
            // A row's identity (channel.id) is stable across a state transition, so a show that
            // goes from e.g. scheduled to recording while its row is already on screen only fires
            // .onAppear once, before `active` ever turned true — without this, the ring picks up
            // the correct red color but never starts pulsing until the row leaves and re-enters view.
            .onChange(of: active) { _, _ in syncAnimation() }
    }

    private func syncAnimation() {
        if active {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                dimmed = true
            }
        } else {
            // A one-shot animation here replaces (and thereby cancels) any still-running
            // repeatForever loop from a prior active==true period, rather than leaving it
            // oscillating in the background with no visible effect.
            withAnimation(.easeInOut(duration: 0.2)) {
                dimmed = false
            }
        }
    }
}

extension View {
    /// Draws the native equivalent of the web guide's `.g-st-*` status ring + corner badge —
    /// see `docs/WatchNowView.md`'s Poster thumbnail section and `docs/WebServer.md`'s "Status
    /// ring + badge" for the shared precedence/color/glyph rationale. No-op for `.none`.
    func guideRingBadge(_ state: GuideRingState) -> some View {
        modifier(GuideRingBadge(state: state))
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
    // XMLTV's <category> vocabulary is far richer than guide.php's ~9-tag Filter — these hues match
    // guide.css's --gg-* custom properties (same source, same family of colors as the web guide grid).
    "crime":    Color(hue: 0.000, saturation: 0.62, brightness: 0.58),
    "romance":  Color(hue: 0.925, saturation: 0.62, brightness: 0.58),
    "thriller": Color(hue: 0.661, saturation: 0.62, brightness: 0.58),
    "action":   Color(hue: 0.033, saturation: 0.62, brightness: 0.58),
    "mystery":  Color(hue: 0.708, saturation: 0.62, brightness: 0.58),
    "doc":      Color(hue: 0.561, saturation: 0.62, brightness: 0.58),
    "science":  Color(hue: 0.522, saturation: 0.62, brightness: 0.58),
    "nature":   Color(hue: 0.228, saturation: 0.62, brightness: 0.58),
    "history":  Color(hue: 0.078, saturation: 0.62, brightness: 0.58),
    "music":    Color(hue: 0.797, saturation: 0.62, brightness: 0.58),
    "food":     Color(hue: 0.144, saturation: 0.62, brightness: 0.58),
    "travel":   Color(hue: 0.506, saturation: 0.62, brightness: 0.58),
    "gameshow": Color(hue: 0.161, saturation: 0.62, brightness: 0.58),
    "home":     Color(hue: 0.097, saturation: 0.62, brightness: 0.58),
    "health":   Color(hue: 0.411, saturation: 0.62, brightness: 0.58),
    "faith":    Color(hue: 0.181, saturation: 0.62, brightness: 0.58),
]

// Raw genre tag → color-map key. Mirrors WebServer.swift's server-side `ggAlias` (same reasoning:
// guide.php says "Sports", XMLTV says singular "Sport"; XMLTV's "Documentary"/"Game show" spell out
// what the color map stores tersely as "doc"/"gameshow").
private let _genreAlias: [String: String] = [
    "sport": "sports", "movies": "movie", "sitcom": "comedy", "kids": "children",
    "documentary": "doc", "game show": "gameshow", "animation": "children", "animated": "children",
]

func guideEntryColor(for entry: GuideEntry, onAir: Bool) -> Color {
    let raw  = entry.firstGenre?.lowercased() ?? ""
    let key  = _genreAlias[raw] ?? raw
    let base = _genreColorMap[key] ?? Color(white: 0.22)
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
