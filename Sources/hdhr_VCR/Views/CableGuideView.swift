import SwiftUI
import AppKit

// Cable-style TV guide grid.
// Rows = channels, columns = 30-min time slots, cells span proportional to show duration.

struct CableGuideView: View {
    let allChannels:   [GuideChannel]
    let lineup:        [LineupEntry]      // for HD badge + stream URL
    let guideHours:    Int
    @Binding var selectedEntry:   GuideEntry?
    @Binding var selectedChannel: LineupEntry?
    var onConfirm: (() -> Void)? = nil   // called on double-click to advance the wizard

    // ── Layout ─────────────────────────────────────────────────────────────
    private let channelColW: CGFloat = 88
    private let rowH:        CGFloat = 52
    private let headerH:     CGFloat = 26
    private let pxPerMin:    CGFloat = 4.2   // 30 min ≈ 126 px

    // Display window: start at previous 30-min boundary (so current shows appear)
    private var displayStart: Date {
        let secs = Int(Date().timeIntervalSince1970)
        return Date(timeIntervalSince1970: Double((secs / 1800) * 1800) - 1800)
    }
    private var displayEnd:   Date   { displayStart.addingTimeInterval(Double(guideHours) * 3600) }
    private var totalMinutes: CGFloat { CGFloat(guideHours * 60) }
    private var totalW:       CGFloat { totalMinutes * pxPerMin }

    // All 30-min slot boundaries in the window
    private var timeSlots: [Date] {
        var slots: [Date] = []
        var t = displayStart
        while t < displayEnd { slots.append(t); t = t.addingTimeInterval(1800) }
        return slots
    }

    // Colour palette — cable-guide style muted hues
    private let palette: [Color] = [
        Color(hue: 0.60, saturation: 0.60, brightness: 0.52),  // blue
        Color(hue: 0.75, saturation: 0.55, brightness: 0.50),  // purple
        Color(hue: 0.07, saturation: 0.65, brightness: 0.52),  // orange
        Color(hue: 0.48, saturation: 0.60, brightness: 0.48),  // teal
        Color(hue: 0.33, saturation: 0.55, brightness: 0.46),  // green
        Color(hue: 0.95, saturation: 0.60, brightness: 0.50),  // crimson
        Color(hue: 0.56, saturation: 0.50, brightness: 0.50),  // steel blue
        Color(hue: 0.13, saturation: 0.55, brightness: 0.50),  // amber
    ]

    private func cellColor(_ entry: GuideEntry, onAir: Bool) -> Color {
        let key  = entry.SeriesID ?? entry.Title
        let base = palette[abs(key.hashValue) % palette.count]
        return onAir ? base : base.opacity(0.70)
    }

    // ── Body ────────────────────────────────────────────────────────────────
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                    Section(header: timeHeader) {
                        ForEach(allChannels, id: \.GuideNumber) { ch in
                            channelRow(ch)
                        }
                    }
                }
                .frame(width: channelColW + totalW)
            }
            .onAppear {
                // Scroll to ~15 min before now so the "now" line is visible
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    proxy.scrollTo("now-anchor", anchor: .leading)
                }
            }
        }
    }

    // ── Time header (pinned) ────────────────────────────────────────────────
    private var timeHeader: some View {
        HStack(spacing: 0) {
            // Corner
            Text("CHANNEL")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
                .frame(width: channelColW, height: headerH, alignment: .center)
                .background(Color.accentColor)

            // One label per 30-min slot
            ZStack(alignment: .leading) {
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

                // "Now" marker in header + scroll anchor
                let nowX = CGFloat(Date().timeIntervalSince(displayStart) / 60) * pxPerMin
                Color.clear.frame(width: 1, height: 1)
                    .offset(x: max(0, nowX - 160))   // put anchor a bit left of now
                    .id("now-anchor")

                Rectangle()
                    .fill(Color.red)
                    .frame(width: 2, height: headerH)
                    .offset(x: nowX)
            }
            .frame(width: totalW, height: headerH)
            .clipped()
        }
        .frame(height: headerH)
        .background(Color.accentColor.opacity(0.80))
    }

    private var slotW: CGFloat { 1800 * pxPerMin / 60 }   // 30 min in px

    // ── Channel row ─────────────────────────────────────────────────────────
    private func channelRow(_ ch: GuideChannel) -> some View {
        let lu      = lineup.first(where: { $0.GuideNumber == ch.GuideNumber })
        let entries = visibleEntries(ch)

        return HStack(spacing: 0) {
            // Channel name cell (fixed left)
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
            .padding(.horizontal, 7)
            .frame(width: channelColW, height: rowH, alignment: .leading)
            .background(Color(NSColor.windowBackgroundColor))
            .overlay(Rectangle()
                .strokeBorder(Color(NSColor.separatorColor).opacity(0.35), lineWidth: 0.5))

            // Show blocks
            ZStack(alignment: .topLeading) {
                Color(NSColor.underPageBackgroundColor)
                    .frame(width: totalW, height: rowH)

                // Vertical grid lines at each 30-min boundary
                ForEach(timeSlots, id: \.self) { slot in
                    let x = CGFloat(slot.timeIntervalSince(displayStart) / 60) * pxPerMin
                    Rectangle()
                        .fill(Color(NSColor.separatorColor).opacity(0.18))
                        .frame(width: 0.5, height: rowH)
                        .offset(x: x)
                }

                // Show cells
                ForEach(entries) { entry in
                    showBlock(entry: entry, lu: lu)
                }

                // "Now" line
                let nowX = CGFloat(Date().timeIntervalSince(displayStart) / 60) * pxPerMin
                if nowX > 0 && nowX < totalW {
                    Rectangle()
                        .fill(Color.red.opacity(0.65))
                        .frame(width: 2, height: rowH)
                        .offset(x: nowX)
                }
            }
            .frame(width: totalW, height: rowH)
            .clipped()
        }
        .frame(height: rowH)
    }

    // ── Show block ──────────────────────────────────────────────────────────
    @ViewBuilder
    private func showBlock(entry: GuideEntry, lu: LineupEntry?) -> some View {
        let now       = Date()
        let startSec  = entry.startDate.timeIntervalSince(displayStart)
        let rawX      = CGFloat(startSec / 60) * pxPerMin
        let cellX     = max(0, rawX)
        let clip      = min(CGFloat(0), rawX)          // negative when show starts before window
        let rawW      = CGFloat(entry.durationMinutes) * pxPerMin + clip - 2
        let cellW     = max(22, rawW)
        let onAir     = entry.startDate <= now && entry.endDate > now
        let isSelected = selectedEntry?.id == entry.id
                          && selectedChannel?.GuideNumber == lu?.GuideNumber

        ZStack(alignment: .topLeading) {
            // Fill: brighten when selected
            RoundedRectangle(cornerRadius: 3)
                .fill(isSelected
                    ? cellColor(entry, onAir: onAir).opacity(1.0)
                    : cellColor(entry, onAir: onAir))

            // Selection: thick white border + white inner glow overlay
            if isSelected {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.white, lineWidth: 2.5)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.15))
            } else {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5)
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

            // Checkmark when selected (top-right corner)
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .offset(x: cellW - 18, y: 4)
            } else if onAir {
                // On-air dot when not selected
                Circle()
                    .fill(Color.red)
                    .frame(width: 5, height: 5)
                    .offset(x: cellW - 9, y: 5)
            }
        }
        .frame(width: cellW, height: rowH - 2)
        .offset(x: cellX, y: 1)
        // Single click → select
        .onTapGesture(count: 1) {
            selectedEntry   = entry
            selectedChannel = lu
        }
        // Double-click → select + advance wizard
        .onTapGesture(count: 2) {
            selectedEntry   = entry
            selectedChannel = lu
            onConfirm?()
        }
    }

    // ── Helpers ─────────────────────────────────────────────────────────────

    private func visibleEntries(_ ch: GuideChannel) -> [GuideEntry] {
        (ch.Guide ?? [])
            .filter { $0.endDate > displayStart && $0.startDate < displayEnd }
            .sorted { $0.StartTime < $1.StartTime }
    }

    private func formatSlot(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f.string(from: d)
    }
}

extension GuideChannel: Identifiable { public var id: String { GuideNumber } }
