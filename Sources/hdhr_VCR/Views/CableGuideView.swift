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
// Channel labels are pinned (do not scroll horizontally).
// Time header is pinned above the scroll view (not inside it) so contentOffset.y == 0
// at rest, keeping channel-column sync exact.

struct CableGuideView: View {
    let allChannels:      [GuideChannel]
    let lineup:           [LineupEntry]      // for HD badge + stream URL
    let guideHours:       Int
    @Binding var selectedEntry:   GuideEntry?
    @Binding var selectedChannel: LineupEntry?
    @Binding var snapToNow:       Bool        // set true externally to snap grid to now
    let managedSeriesIDs: Set<String>         // shows already scheduled (by SeriesID)
    let managedTitles:    Set<String>         // shows already scheduled (by title fallback)
    let genreFilter:      String?             // nil = show all; non-nil = dim non-matching
    var onConfirm: (() -> Void)? = nil        // called on double-click to advance wizard

    // ── Layout constants ───────────────────────────────────────────────────────
    private let channelColW: CGFloat = 100
    private let rowH:        CGFloat = 52
    private let headerH:     CGFloat = 26
    private let pxPerMin:    CGFloat = 4.2

    // ── State ──────────────────────────────────────────────────────────────────
    @State private var channelScrollOffset: CGFloat = 0   // tracks vertical scroll
    @State private var timeHeaderOffset:    CGFloat = 0   // tracks horizontal scroll

    // Pre-built O(1) lookup — avoids lineup.first(where:) O(N) scan per channel per render
    private var lineupByNumber: [String: LineupEntry] {
        Dictionary(uniqueKeysWithValues: lineup.map { ($0.GuideNumber, $0) })
    }

    // ── Derived layout values ──────────────────────────────────────────────────
    private var displayStart: Date {
        let secs = Int(Date().timeIntervalSince1970)
        return Date(timeIntervalSince1970: Double((secs / 1800) * 1800) - 1800)
    }
    private var displayEnd:   Date   { displayStart.addingTimeInterval(Double(guideHours) * 3600) }
    private var totalMinutes: CGFloat { CGFloat(guideHours * 60) }
    private var totalW:       CGFloat { totalMinutes * pxPerMin }
    private var slotW:        CGFloat { 1800 * pxPerMin / 60 }

    private var timeSlots: [Date] {
        var slots: [Date] = []
        var t = displayStart
        while t < displayEnd { slots.append(t); t = t.addingTimeInterval(1800) }
        return slots
    }

    // ── Body ───────────────────────────────────────────────────────────────────
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            channelColumnFixed
            VStack(spacing: 0) {
                pinnedTimeHeader   // sits above the scroll view; synced via timeHeaderOffset
                guideScrollView    // rows only — no pinned section header inside
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // ── Fixed channel column (does not scroll horizontally) ────────────────────

    private var channelColumnFixed: some View {
        VStack(spacing: 0) {
            // Corner cell — matches pinnedTimeHeader height exactly
            Text("CHANNEL")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
                .frame(width: channelColW, height: headerH, alignment: .center)
                .background(Color.accentColor)

            // Channel labels, offset vertically to track vertical scroll.
            // frame(maxHeight:) MUST come before .clipped() so the clip rect is the
            // available height (not the ZStack's 5000px+ natural height).
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    ForEach(allChannels) { ch in channelLabelCell(ch) }
                }
                .offset(y: -channelScrollOffset)
            }
            .frame(maxHeight: .infinity)   // ← constrains layout bounds first
            .clipped()                      // ← then clips to those bounds
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

    // ── Pinned time header (outside the scroll view; shifts left with timeHeaderOffset) ──

    private var pinnedTimeHeader: some View {
        ZStack(alignment: .leading) {
            ForEach(timeSlots, id: \.self) { slot in
                let x = CGFloat(slot.timeIntervalSince(displayStart) / 60) * pxPerMin - timeHeaderOffset
                Text(formatSlot(slot))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.leading, 5)
                    .frame(width: slotW, height: headerH, alignment: .leading)
                    .background(Color.accentColor.opacity(0.80))
                    .offset(x: x)
            }

            // "Now" indicator line on the time header
            let nowX = CGFloat(Date().timeIntervalSince(displayStart) / 60) * pxPerMin - timeHeaderOffset
            Rectangle()
                .fill(Color.red)
                .frame(width: 2, height: headerH)
                .offset(x: nowX)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: headerH)
        .clipped()
        .background(Color.accentColor.opacity(0.80))
    }

    // ── Scrollable guide rows (channel rows only — no pinned section header) ───

    private var guideScrollView: some View {
        // nowX computed once for the anchor layout position
        let nowX = CGFloat(Date().timeIntervalSince(displayStart) / 60) * pxPerMin
        return ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                VStack(spacing: 0) {
                    // Zero-height anchor at layout x=(nowX-160) so proxy.scrollTo works correctly.
                    // Must use real layout width (not .offset) because scrollTo uses layout bounds.
                    HStack(spacing: 0) {
                        Color.clear.frame(width: max(0, nowX - 160), height: 0)
                        Color.clear.frame(width: 1, height: 0).id("now-anchor")
                        Spacer(minLength: 0)
                    }
                    .frame(width: totalW, height: 0)

                    VStack(spacing: 0) {
                        ForEach(allChannels) { ch in showBlocksRow(ch) }
                    }
                    .frame(width: totalW)
                }
            }
            // Track both axes: y → channel column sync, x → time header sync
            .onScrollGeometryChange(for: CGPoint.self, of: { $0.contentOffset }) { _, pt in
                channelScrollOffset = pt.y
                timeHeaderOffset    = pt.x
            }
            .onChange(of: snapToNow) { _, trigger in
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

    // ── Show blocks row (no channel label — that lives in channelColumnFixed) ──

    private func showBlocksRow(_ ch: GuideChannel) -> some View {
        let lu      = lineupByNumber[ch.GuideNumber]
        let entries = visibleEntries(ch)
        let now     = Date()

        return ZStack(alignment: .topLeading) {
            Color(NSColor.underPageBackgroundColor)
                .frame(width: totalW, height: rowH)

            // Vertical grid lines at 30-min boundaries
            ForEach(timeSlots, id: \.self) { slot in
                let x = CGFloat(slot.timeIntervalSince(displayStart) / 60) * pxPerMin
                Rectangle()
                    .fill(Color(NSColor.separatorColor).opacity(0.18))
                    .frame(width: 0.5, height: rowH)
                    .offset(x: x)
            }

            ForEach(entries) { entry in showBlock(entry: entry, lu: lu, now: now) }

            // "Now" line
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

    // ── Individual show block ──────────────────────────────────────────────────

    @ViewBuilder
    private func showBlock(entry: GuideEntry, lu: LineupEntry?, now: Date) -> some View {
        let startSec   = entry.startDate.timeIntervalSince(displayStart)
        let rawX       = CGFloat(startSec / 60) * pxPerMin
        let cellX      = max(0, rawX)
        let clip       = min(CGFloat(0), rawX)
        let rawW       = CGFloat(entry.durationMinutes) * pxPerMin + clip - 2
        let cellW      = max(22, rawW)
        let onAir      = entry.startDate <= now && entry.endDate > now
        let isSelected = selectedEntry?.id == entry.id
                          && selectedChannel?.GuideNumber == lu?.GuideNumber
        let isManaged  = (entry.SeriesID.map { managedSeriesIDs.contains($0) } ?? false)
                       || managedTitles.contains(entry.Title)
        let matchesFilter: Bool = {
            guard let f = genreFilter else { return true }
            return entry.Filter?.contains(where: { $0.caseInsensitiveCompare(f) == .orderedSame }) ?? false
        }()

        ZStack(alignment: .topLeading) {
            // Background fill
            RoundedRectangle(cornerRadius: 3)
                .fill(guideEntryColor(for: entry, onAir: onAir))

            // Selection border + glow
            if isSelected {
                RoundedRectangle(cornerRadius: 3).strokeBorder(Color.white, lineWidth: 2.5)
                RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.15))
            } else {
                RoundedRectangle(cornerRadius: 3).strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5)
            }

            // Title + episode title
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

            // Top-right: checkmark (selected) or on-air dot
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .offset(x: cellW - 18, y: 4)
            } else if onAir {
                Circle().fill(Color.red).frame(width: 5, height: 5)
                    .offset(x: cellW - 9, y: 5)
            }

            // Bottom-left: bookmark badge when show is already managed
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
        // Single-tap fires immediately; double-tap runs concurrently (no ~400ms delay)
        .onTapGesture {
            selectedEntry   = entry
            selectedChannel = lu
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            selectedEntry   = entry
            selectedChannel = lu
            onConfirm?()
        })
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
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f.string(from: d)
    }
}

extension GuideChannel: Identifiable { public var id: String { GuideNumber } }
