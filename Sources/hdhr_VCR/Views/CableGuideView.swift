import SwiftUI
import AppKit

// ── Module-level colour helpers (used by both CableGuideView and AddShowView) ──

private let _guidePalette: [Color] = [
    Color(hue: 0.60, saturation: 0.60, brightness: 0.52),  // blue
    Color(hue: 0.75, saturation: 0.55, brightness: 0.50),  // purple
    Color(hue: 0.07, saturation: 0.65, brightness: 0.52),  // orange
    Color(hue: 0.48, saturation: 0.60, brightness: 0.48),  // teal
    Color(hue: 0.33, saturation: 0.55, brightness: 0.46),  // green
    Color(hue: 0.95, saturation: 0.60, brightness: 0.50),  // crimson
    Color(hue: 0.56, saturation: 0.50, brightness: 0.50),  // steel blue
    Color(hue: 0.13, saturation: 0.55, brightness: 0.50),  // amber
]

private let _genreColorMap: [String: Color] = [
    "drama":    Color(hue: 0.60, saturation: 0.65, brightness: 0.52),
    "comedy":   Color(hue: 0.13, saturation: 0.65, brightness: 0.52),
    "news":     Color(hue: 0.95, saturation: 0.60, brightness: 0.50),
    "sports":   Color(hue: 0.33, saturation: 0.65, brightness: 0.46),
    "reality":  Color(hue: 0.07, saturation: 0.65, brightness: 0.52),
    "movie":    Color(hue: 0.75, saturation: 0.55, brightness: 0.50),
    "talk":     Color(hue: 0.48, saturation: 0.60, brightness: 0.48),
    "children": Color(hue: 0.56, saturation: 0.50, brightness: 0.50),
]

/// Returns the display colour for a guide entry.
/// Uses genre when available, falls back to series/title hash.
/// On-air shows use full opacity; future shows are dimmed to 0.75 so on-air stands out.
func guideEntryColor(for entry: GuideEntry, onAir: Bool) -> Color {
    if let genre = entry.firstGenre?.lowercased(),
       let color = _genreColorMap[genre] {
        return onAir ? color : color.opacity(0.75)
    }
    let key  = entry.SeriesID ?? entry.Title
    let base = _guidePalette[abs(key.hashValue) % _guidePalette.count]
    return onAir ? base : base.opacity(0.75)
}

// ── Cable-style TV guide grid ─────────────────────────────────────────────────
// Rows = channels, columns = 30-min time slots, cells span proportional to show duration.
// Channel labels are pinned left (do not scroll horizontally).
// Time header lives INSIDE the ScrollView as a LazyVStack pinned section header:
// it scrolls horizontally with the content and stays pinned at the top during vertical scroll.

struct CableGuideView: View {
    let allChannels:      [GuideChannel]
    let lineup:           [LineupEntry]      // for HD badge + stream URL
    let guideHours:       Int
    @Binding var selectedEntry:   GuideEntry?
    @Binding var selectedChannel: LineupEntry?
    @Binding var snapToNow:       Bool        // set true externally to snap grid to now
    let managedSeriesIDs:   Set<String>         // shows already scheduled (by SeriesID)
    let managedTitles:      Set<String>         // shows already scheduled (by title fallback)
    let recordingSeriesIDs: Set<String>         // shows currently recording
    let recordingTitles:    Set<String>
    let nextUpSeriesIDs:    Set<String>         // shows recording within 30 min
    let nextUpTitles:       Set<String>
    // Bonus Time: seriesIDs/titles of managed sports shows; used to draw the dotted overtime box
    let bonusSeriesIDs:   Set<String>
    let bonusTitles:      Set<String>
    let bonusMinutes:     Int                 // how many minutes of Bonus Time to visualize
    let genreFilter:      String?             // nil = show all; non-nil = dim non-matching
    var onConfirm: (() -> Void)? = nil        // called on double-click to advance wizard

    // ── Layout constants ───────────────────────────────────────────────────────
    private let channelColW: CGFloat = 100
    private let rowH:        CGFloat = 52
    private let headerH:     CGFloat = 26
    // pxPerMin scales up on wider windows so the grid fills available space
    @State private var availableGridWidth: CGFloat = 0
    private var pxPerMin: CGFloat {
        guard availableGridWidth > 0 else { return 4.2 }
        return max(4.2, availableGridWidth / CGFloat(guideHours * 60))
    }

    // ── State ──────────────────────────────────────────────────────────────────
    @State private var channelScrollOffset: CGFloat = 0

    // Cached hot-path values — rebuilt once on appear/change, not on every render
    @State private var lineupByNumber: [String: LineupEntry] = [:]
    @State private var displayStart:   Date   = Date()
    @State private var timeSlots:      [Date] = []

    // ── Derived layout values (O(1) math from cached state) ───────────────────
    private var displayEnd:   Date   { displayStart.addingTimeInterval(Double(guideHours) * 3600) }
    private var totalMinutes: CGFloat { CGFloat(guideHours * 60) }
    private var totalW:       CGFloat { totalMinutes * pxPerMin }
    private var slotW:        CGFloat { 1800 * pxPerMin / 60 }

    // ── Body ───────────────────────────────────────────────────────────────────
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            channelColumnFixed
            guideScrollView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(GeometryReader { geo in
            Color.clear.onAppear {
                availableGridWidth = geo.size.width - channelColW
            }
            .onChange(of: geo.size.width) { w in
                availableGridWidth = w - channelColW
            }
        })
        .onAppear { rebuildCaches() }
        .onChange(of: lineup.count)       { _ in rebuildCaches() }
        .onChange(of: guideHours)         { _ in rebuildCaches() }
        .onChange(of: availableGridWidth) { _ in rebuildCaches() }
    }

    // ── Cache rebuild ──────────────────────────────────────────────────────────

    private func rebuildCaches() {
        lineupByNumber = Dictionary(uniqueKeysWithValues: lineup.map { ($0.GuideNumber, $0) })
        let secs = Int(Date().timeIntervalSince1970)
        displayStart = Date(timeIntervalSince1970: Double((secs / 1800) * 1800) - 1800)
        let end = displayStart.addingTimeInterval(Double(guideHours) * 3600)
        var slots: [Date] = []
        var t = displayStart
        while t < end { slots.append(t); t = t.addingTimeInterval(1800) }
        timeSlots = slots
    }

    // ── Fixed channel column (does not scroll horizontally) ────────────────────

    private var channelColumnFixed: some View {
        VStack(spacing: 0) {
            // Corner cell — matches scrollingTimeHeader height exactly
            Text("CHANNEL")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
                .frame(width: channelColW, height: headerH, alignment: .center)
                .background(Color.accentColor)

            // Channel labels, offset vertically to track vertical scroll.
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    ForEach(allChannels) { ch in channelLabelCell(ch) }
                }
                .offset(y: -channelScrollOffset)
            }
            .frame(maxHeight: .infinity)
            .clipped()
        }
        .frame(width: channelColW)
        .clipped()
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func channelLabelCell(_ ch: GuideChannel) -> some View {
        let lu = lineupByNumber[ch.GuideNumber]
        return HStack(spacing: 5) {
            ChannelIcon(urlString: ch.ImageURL, size: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(ch.GuideNumber)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.primary)
                Text(ch.GuideName)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if (lu?.HD ?? 0) == 1 {
                    Text("HD")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundColor(Color.accentColor)
                }
            }
        }
        .padding(.horizontal, 5)
        .frame(width: channelColW, height: rowH, alignment: .leading)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(Rectangle()
            .strokeBorder(Color(NSColor.separatorColor).opacity(0.35), lineWidth: 0.5))
    }

    // ── Time header — lives inside the scroll view so it scrolls horizontally ──
    // pinnedViews: [.sectionHeaders] keeps it pinned to the top during vertical scroll.

    private func scrollingTimeHeader(nowX: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            // Invisible anchor used by ScrollViewReader to snap to current time.
            HStack(spacing: 0) {
                Color.clear.frame(width: max(0, nowX - 160), height: 0)
                Color.clear.frame(width: 1, height: 0).id("now-anchor")
                Spacer(minLength: 0)
            }
            .frame(width: totalW, height: 0)

            ForEach(timeSlots, id: \.self) { slot in
                let x = CGFloat(slot.timeIntervalSince(displayStart) / 60) * pxPerMin
                Text(formatSlot(slot))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.leading, 5)
                    .frame(width: slotW, height: headerH, alignment: .leading)
                    .background(Color.accentColor.opacity(0.80))
                    .offset(x: x)
            }

            Rectangle()
                .fill(Color.red)
                .frame(width: 2, height: headerH)
                .offset(x: nowX)
        }
        .frame(width: totalW, height: headerH)
        .background(Color.accentColor.opacity(0.80))
    }

    // ── Scrollable guide rows ──────────────────────────────────────────────────

    private var guideScrollView: some View {
        let nowX = CGFloat(Date().timeIntervalSince(displayStart) / 60) * pxPerMin
        return ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(allChannels) { ch in
                            let entries = visibleEntries(ch)
                            ShowBlocksRow(
                                channel:            ch,
                                entries:            entries,
                                lineupEntry:        lineupByNumber[ch.GuideNumber],
                                displayStart:       displayStart,
                                totalW:             totalW,
                                rowH:               rowH,
                                pxPerMin:           pxPerMin,
                                timeSlots:          timeSlots,
                                selectedEntry:      selectedEntry,
                                selectedChannel:    selectedChannel,
                                managedSeriesIDs:   managedSeriesIDs,
                                managedTitles:      managedTitles,
                                recordingSeriesIDs: recordingSeriesIDs,
                                recordingTitles:    recordingTitles,
                                nextUpSeriesIDs:    nextUpSeriesIDs,
                                nextUpTitles:       nextUpTitles,
                                bonusSeriesIDs:     bonusSeriesIDs,
                                bonusTitles:        bonusTitles,
                                bonusMinutes:       bonusMinutes,
                                genreFilter:        genreFilter,
                                onSelect: { entry, lu in
                                    selectedEntry   = entry
                                    selectedChannel = lu
                                },
                                onConfirm: onConfirm
                            )
                            .equatable()
                        }
                    } header: {
                        scrollingTimeHeader(nowX: nowX)
                    }
                }
                .frame(width: totalW)
                .onScrollOffset(coordinateSpaceName: "guideScroll") { pt in
                    var t = Transaction(); t.disablesAnimations = true
                    withTransaction(t) {
                        channelScrollOffset = pt.y
                    }
                }
            }
            .coordinateSpace(name: "guideScroll")
            .onChange(of: snapToNow) { trigger in
                guard trigger else { return }
                proxy.scrollTo("now-anchor", anchor: .leading)
                snapToNow = false
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    proxy.scrollTo("now-anchor", anchor: .leading)
                }
            }
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private func visibleEntries(_ ch: GuideChannel) -> [GuideEntry] {
        let raw      = ch.Guide ?? []
        let filtered = raw.filter { $0.endDate > displayStart && $0.startDate < displayEnd }
        if ch.GuideNumber == allChannels.first?.GuideNumber {
            NSLog("[CableGuide] ch%@ raw=%d filtered=%d winStart=%d winEnd=%d",
                  ch.GuideNumber, raw.count, filtered.count,
                  Int(displayStart.timeIntervalSince1970),
                  Int(displayEnd.timeIntervalSince1970))
        }
        return filtered.sorted { $0.StartTime < $1.StartTime }
    }

    private func formatSlot(_ d: Date) -> String {
        let f = DateFormatter()
        // "jmm" template: j means preferred hour format for the locale (12h or 24h)
        f.dateFormat = DateFormatter.dateFormat(fromTemplate: "jmm", options: 0, locale: .current)
        return f.string(from: d)
    }
}

// ── Equatable channel row — SwiftUI skips body re-eval during scroll ──────────

private struct ShowBlocksRow: View, Equatable {
    let channel:          GuideChannel
    let entries:          [GuideEntry]
    let lineupEntry:      LineupEntry?
    let displayStart:     Date
    let totalW:           CGFloat
    let rowH:             CGFloat
    let pxPerMin:         CGFloat
    let timeSlots:        [Date]
    let selectedEntry:    GuideEntry?
    let selectedChannel:  LineupEntry?
    let managedSeriesIDs:   Set<String>
    let managedTitles:      Set<String>
    let recordingSeriesIDs: Set<String>
    let recordingTitles:    Set<String>
    let nextUpSeriesIDs:    Set<String>
    let nextUpTitles:       Set<String>
    // Bonus Time: sports shows that get an overtime extension — used to draw the dotted overlay box
    let bonusSeriesIDs:   Set<String>
    let bonusTitles:      Set<String>
    let bonusMinutes:     Int
    let genreFilter:      String?
    var onSelect:  (GuideEntry, LineupEntry?) -> Void
    var onConfirm: (() -> Void)?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.channel.GuideNumber          == rhs.channel.GuideNumber &&
        lhs.entries.count                == rhs.entries.count &&
        lhs.selectedEntry?.StartTime     == rhs.selectedEntry?.StartTime &&
        lhs.selectedChannel?.GuideNumber == rhs.selectedChannel?.GuideNumber &&
        lhs.genreFilter                  == rhs.genreFilter &&
        lhs.displayStart                 == rhs.displayStart &&
        lhs.managedSeriesIDs             == rhs.managedSeriesIDs &&
        lhs.managedTitles                == rhs.managedTitles &&
        lhs.recordingSeriesIDs           == rhs.recordingSeriesIDs &&
        lhs.recordingTitles              == rhs.recordingTitles &&
        lhs.nextUpSeriesIDs              == rhs.nextUpSeriesIDs &&
        lhs.nextUpTitles                 == rhs.nextUpTitles &&
        lhs.bonusSeriesIDs               == rhs.bonusSeriesIDs &&
        lhs.bonusTitles                  == rhs.bonusTitles &&
        lhs.bonusMinutes                 == rhs.bonusMinutes
    }

    var body: some View {
        let now = Date()
        ZStack(alignment: .topLeading) {
            Color(NSColor.underPageBackgroundColor)
                .frame(width: totalW, height: rowH)

            ForEach(timeSlots, id: \.self) { slot in
                let x = CGFloat(slot.timeIntervalSince(displayStart) / 60) * pxPerMin
                Rectangle()
                    .fill(Color(NSColor.separatorColor).opacity(0.18))
                    .frame(width: 0.5, height: rowH)
                    .offset(x: x)
            }

            ForEach(entries) { entry in showBlock(entry: entry, now: now) }

            let nowX = CGFloat(now.timeIntervalSince(displayStart) / 60) * pxPerMin
            if nowX > 0 && nowX < totalW {
                Rectangle()
                    .fill(Color.red.opacity(0.65))
                    .frame(width: 2, height: rowH)
                    .offset(x: nowX)
            }
        }
        .frame(width: totalW, height: rowH)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(NSColor.separatorColor).opacity(0.35))
                .frame(height: 0.5)
        }
        .clipped()
    }

    @ViewBuilder
    private func showBlock(entry: GuideEntry, now: Date) -> some View {
        let startSec   = entry.startDate.timeIntervalSince(displayStart)
        let rawX       = CGFloat(startSec / 60) * pxPerMin
        let cellX      = max(0, rawX)
        let clip       = min(CGFloat(0), rawX)
        let rawW       = CGFloat(entry.durationMinutes) * pxPerMin + clip - 2
        let cellW      = max(22, rawW)
        let onAir      = entry.startDate <= now && entry.endDate > now
        // lineupEntry != nil guard prevents nil==nil false-positive when lineup is absent:
        // both sides would be nil and Swift evaluates nil == nil as true, lighting up every
        // entry at the same startTime across all channels as "selected".
        let isSelected = selectedEntry?.id == entry.id
                          && lineupEntry != nil
                          && selectedChannel?.GuideNumber == lineupEntry?.GuideNumber
        // When SeriesID is present use it exclusively; title is fallback only for entries
        // that have no SeriesID so unrelated shows sharing a name don't get false badges.
        let isManaged   = entry.SeriesID.map { managedSeriesIDs.contains($0) }
                       ?? managedTitles.contains(entry.Title)
        let isRecording = entry.SeriesID.map { recordingSeriesIDs.contains($0) }
                       ?? recordingTitles.contains(entry.Title)
        let isNextUp    = !isRecording && (entry.SeriesID.map { nextUpSeriesIDs.contains($0) }
                       ?? nextUpTitles.contains(entry.Title))
        let isBonusTime = entry.SeriesID.map { bonusSeriesIDs.contains($0) }
                       ?? bonusTitles.contains(entry.Title)
        let matchesFilter: Bool = {
            guard let f = genreFilter else { return true }
            return entry.Filter?.contains(where: { $0.caseInsensitiveCompare(f) == .orderedSame }) ?? false
        }()

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(guideEntryColor(for: entry, onAir: onAir))

            // Item 9: white wash on on-air shows makes them visibly brighter than future shows,
            // which are already dimmed to 0.75 opacity by guideEntryColor
            if onAir && !isSelected {
                RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.12))
            }

            if isSelected {
                RoundedRectangle(cornerRadius: 3).strokeBorder(Color.white, lineWidth: 2.5)
                RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.15))
            } else if isRecording {
                RoundedRectangle(cornerRadius: 3).strokeBorder(Color.red, lineWidth: 1.5)
            } else if isNextUp {
                RoundedRectangle(cornerRadius: 3).strokeBorder(Color.orange, lineWidth: 1.5)
            } else {
                RoundedRectangle(cornerRadius: 3).strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.Title)
                    .font(.system(size: 11, weight: isSelected ? .bold : .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                if cellW > 90, let ep = entry.EpisodeTitle, !ep.isEmpty {
                    Text(ep)
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)
            .frame(width: max(1, cellW - (isSelected ? 20 : 8)), alignment: .topLeading)

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .offset(x: cellW - 18, y: 4)
            } else if isRecording {
                // Red dot — currently recording
                Circle().fill(Color.red).frame(width: 8, height: 8)
                    .offset(x: cellW - 11, y: 4)
            } else if isNextUp {
                // Orange clock — records within 30 min
                Image(systemName: "clock.badge.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.orange)
                    .offset(x: cellW - 14, y: 4)
            }

            if isManaged {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.9))
                    .offset(x: 4, y: rowH - 20)
            }
        }
        .frame(width: cellW, height: rowH - 2)
        .offset(x: cellX, y: 1)
        .opacity(matchesFilter ? 1.0 : 0.2)
        .allowsHitTesting(matchesFilter)
        .onTapGesture {
            onSelect(entry, lineupEntry)
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            onSelect(entry, lineupEntry)
            onConfirm?()
        })

        // Item 6: Bonus Time dotted box — drawn as a sibling view immediately to the right of the
        // show block, showing how far past the guide end the recording will actually run.
        // Only appears for managed sports shows when Bonus Time is configured (bonusMinutes > 0).
        if isBonusTime && bonusMinutes > 0 {
            let bonusW = max(8, CGFloat(bonusMinutes) * pxPerMin - 2)
            ZStack(alignment: .topLeading) {
                // Dotted border matching the show's color to visually link them
                RoundedRectangle(cornerRadius: 3)
                    .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    .foregroundColor(guideEntryColor(for: entry, onAir: onAir).opacity(0.85))
                // Label if the box is wide enough to fit text
                if bonusW > 60 {
                    Text("Bonus Time")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(guideEntryColor(for: entry, onAir: onAir).opacity(0.9))
                        .padding(.horizontal, 4)
                        .padding(.top, 4)
                }
            }
            .frame(width: bonusW, height: rowH - 2)
            .offset(x: cellX + cellW + 2, y: 1)
            .opacity(matchesFilter ? 1.0 : 0.2)
            .allowsHitTesting(false)  // tap goes to the underlying show, not the bonus box
        }
    }
}

extension GuideChannel: Identifiable { public var id: String { GuideNumber } }
