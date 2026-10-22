import CoreGraphics

/// Pure layout planner for the player window's responsive toolbar (docs/VLCPlayerView.md, "Responsive toolbar").
///
/// The toolbar is one row of controls. When the window is narrower than the row, controls are degraded one
/// step at a time, lowest `rank` first, until the row fits: a step is either "full → compact" (a narrower form
/// of the same control: icon-only label, shorter slider) or "→ folded" (the control leaves the bar and is
/// offered as an item at the top of the "…" menu). When there is extra room the steps are undone in the
/// opposite order (highest rank first), but only when the result fits with `hysteresis` points to spare, so a
/// window resting on a threshold does not flap between two layouts.
///
/// No SwiftUI, no measuring of views: widths are conservative constants supplied by the caller, and the only
/// measured number is the toolbar's available width.
struct ToolbarOverflowPlanner {

    enum Level: Int, Comparable, Sendable {
        case full = 0, compact = 1, folded = 2
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    struct ItemSpec: Equatable, Sendable {
        let id: String
        /// Width on the bar at full size, including any divider that leads it (not the gap before it).
        let fullWidth: CGFloat
        /// Width in the narrower form; nil = this control has no compact form.
        let compactWidth: CGFloat?
        /// Whether the control may leave the bar for the overflow menu. The channel picker and the "…" menu itself cannot.
        let foldable: Bool
        /// Rank of the full → compact step (ignored without a `compactWidth`). Lower degrades first.
        let compactRank: Int
        /// Rank of the → folded step (ignored when not `foldable`). Lower folds first.
        let foldRank: Int

        init(id: String, fullWidth: CGFloat, compactWidth: CGFloat? = nil, foldable: Bool = true,
             compactRank: Int = 0, foldRank: Int = 0) {
            self.id = id
            self.fullWidth = fullWidth
            self.compactWidth = compactWidth
            self.foldable = foldable
            self.compactRank = compactRank
            self.foldRank = foldRank
        }

        func width(at level: Level) -> CGFloat {
            switch level {
            case .full: return fullWidth
            case .compact: return compactWidth ?? fullWidth
            case .folded: return 0
            }
        }
    }

    struct Plan: Equatable, Sendable {
        /// Level per item id. An id the planner was not given is `.full` (see `level(of:)`).
        let levels: [String: Level]
        /// Ids that left the bar, most recently folded (highest `foldRank`) first — the order they appear in the menu.
        let foldedIDs: [String]
        /// False when even the most degraded layout is wider than the space (the row will clip; nothing more can fold).
        let fits: Bool

        func level(of id: String) -> Level { levels[id] ?? .full }
        func isFolded(_ id: String) -> Bool { level(of: id) == .folded }
        func isCompact(_ id: String) -> Bool { level(of: id) == .compact }
    }

    /// Gap between neighbouring items (the toolbar `HStack` spacing).
    static let spacing: CGFloat = 10
    /// Leading + trailing padding of the row.
    static let horizontalPadding: CGFloat = 24
    /// Default slack for hysteresis: promotion needs this much spare room.
    static let defaultHysteresis: CGFloat = 16
    /// Room kept free beyond the estimated widths (estimates are constants, not measurements).
    static let slack: CGFloat = 6

    /// Width of the row for `levels` (missing = full): item widths, the gaps between visible items, the padding and the slack.
    static func requiredWidth(_ items: [ItemSpec], levels: [String: Level],
                              spacing: CGFloat = spacing, padding: CGFloat = horizontalPadding,
                              slack: CGFloat = slack) -> CGFloat {
        var total: CGFloat = 0
        var visible = 0
        for item in items {
            let lv = levels[item.id] ?? .full
            if lv == .folded { continue }
            total += item.width(at: lv)
            visible += 1
        }
        return total + CGFloat(max(0, visible - 1)) * spacing + padding + slack
    }

    /// Plans the row. `previous` (the plan in force) enables hysteresis; without it the result depends on `available` alone.
    static func plan(items: [ItemSpec], available: CGFloat, previous: Plan? = nil,
                     hysteresis: CGFloat = defaultHysteresis,
                     spacing: CGFloat = spacing, padding: CGFloat = horizontalPadding,
                     slack: CGFloat = slack) -> Plan {
        func need(_ l: [String: Level]) -> CGFloat {
            requiredWidth(items, levels: l, spacing: spacing, padding: padding, slack: slack)
        }

        // Start from the plan in force (for items still present) or everything at full size.
        var levels: [String: Level] = [:]
        for item in items { levels[item.id] = previous?.levels[item.id] ?? .full }
        // A previous plan can hold a state the item can no longer take (e.g. it lost its compact form): clamp it.
        for item in items {
            guard let lv = levels[item.id] else { continue }
            if lv == .folded && !item.foldable { levels[item.id] = item.compactWidth == nil ? .full : .compact }
            if lv == .compact && item.compactWidth == nil { levels[item.id] = .full }
        }

        // 1. Degrade, lowest rank first, until it fits (ties: earliest in `items`).
        while need(levels) > available, let step = nextDegrade(items, levels) {
            levels[step.id] = step.to
        }

        // 2. Promote, highest rank first, only while the result fits with `hysteresis` to spare.
        while let step = nextPromote(items, levels) {
            var trial = levels
            trial[step.id] = step.to
            guard need(trial) <= available - hysteresis else { break }
            levels = trial
        }

        let folded = items.filter { levels[$0.id] == .folded }
            .sorted { $0.foldRank > $1.foldRank }
            .map(\.id)
        return Plan(levels: levels, foldedIDs: folded, fits: need(levels) <= available)
    }

    // MARK: Steps

    private struct Step { let id: String; let to: Level; let rank: Int }

    /// The cheapest-to-lose next degradation: lowest rank, earliest item on ties.
    private static func nextDegrade(_ items: [ItemSpec], _ levels: [String: Level]) -> Step? {
        var best: Step?
        for item in items {
            let lv = levels[item.id] ?? .full
            var cand: Step?
            switch lv {
            case .full:
                if item.compactWidth != nil { cand = Step(id: item.id, to: .compact, rank: item.compactRank) }
                else if item.foldable { cand = Step(id: item.id, to: .folded, rank: item.foldRank) }
            case .compact:
                if item.foldable { cand = Step(id: item.id, to: .folded, rank: item.foldRank) }
            case .folded:
                break
            }
            if let cand, best == nil || cand.rank < best!.rank { best = cand }
        }
        return best
    }

    /// The step that undoes the most recent-looking degradation: highest rank, earliest item on ties.
    private static func nextPromote(_ items: [ItemSpec], _ levels: [String: Level]) -> Step? {
        var best: Step?
        for item in items {
            let lv = levels[item.id] ?? .full
            var cand: Step?
            switch lv {
            case .folded:
                if item.compactWidth != nil { cand = Step(id: item.id, to: .compact, rank: item.foldRank) }
                else { cand = Step(id: item.id, to: .full, rank: item.foldRank) }
            case .compact:
                cand = Step(id: item.id, to: .full, rank: item.compactRank)
            case .full:
                break
            }
            if let cand, best == nil || cand.rank > best!.rank { best = cand }
        }
        return best
    }
}

/// The player toolbar's items: ids, estimated widths and priorities. Kept next to the planner so the numbers
/// and the docs table stay in one place. Widths include the divider that leads an item (1 pt + the 10 pt gap).
enum PlayerToolbarItem {
    static let picker = "channelPicker"
    static let record = "quickRecord"
    static let buffer = "bufferPill"
    static let catchUp = "catchUp"
    static let h264 = "h264Toggle"
    static let info = "statusBarToggle"
    static let clock = "clock"
    static let volume = "volume"
    static let more = "moreOptions"

    /// Fold ranks (lower folds first). Spaced so a step can be inserted between two without renumbering.
    enum Rank {
        static let clock = 10
        static let buffer = 20
        static let h264 = 30
        static let record = 40
        static let catchUpCompact = 50
        static let pickerCompact = 60
        static let volumeCompact = 65
        static let catchUpFold = 70
        static let volumeFold = 75
        static let infoFold = 80
    }

    static let pickerFull: CGFloat = 220
    static let pickerCompact: CGFloat = 120
    static let volumeSliderFull: CGFloat = 100
    static let volumeSliderCompact: CGFloat = 60
    static let clockTextWidth: CGFloat = 70
    /// Fixed label widths, so the row's width does not move with the text (the label is `.frame(width:)` and `.lineLimit(1)`).
    static let catchUpLabelWidth: CGFloat = 96          // icon + "Catch Up"
    static let catchUpRecordingLabelWidth: CGFloat = 150 // icon + "Live Edge · 1m 23s"

    /// The items for the current state, in bar order. `bufferEnabled`: the buffer pill is shown (the catch-up button is then
    /// icon-only, with or without the pill around it). `recordingRelay`: the catch-up label is the longer "Live Edge · Ns".
    static func specs(hasRecord: Bool, bufferEnabled: Bool, recordingRelay: Bool, hasH264: Bool) -> [ToolbarOverflowPlanner.ItemSpec] {
        typealias S = ToolbarOverflowPlanner.ItemSpec
        var out: [S] = [S(id: picker, fullWidth: pickerFull, compactWidth: pickerCompact, foldable: false, compactRank: Rank.pickerCompact)]
        if hasRecord { out.append(S(id: record, fullWidth: 86, foldRank: Rank.record)) }
        if bufferEnabled { out.append(S(id: buffer, fullWidth: 84, foldRank: Rank.buffer)) }
        if bufferEnabled {
            out.append(S(id: catchUp, fullWidth: 24, foldRank: Rank.catchUpFold))
        } else {
            out.append(S(id: catchUp, fullWidth: recordingRelay ? catchUpRecordingLabelWidth : catchUpLabelWidth,
                         compactWidth: 24, compactRank: Rank.catchUpCompact, foldRank: Rank.catchUpFold))
        }
        if hasH264 { out.append(S(id: h264, fullWidth: 83, foldRank: Rank.h264)) }
        out.append(S(id: info, fullWidth: 22, foldRank: Rank.infoFold))
        out.append(S(id: clock, fullWidth: 11 + clockTextWidth, foldRank: Rank.clock))
        out.append(S(id: volume, fullWidth: 11 + 16 + 10 + volumeSliderFull, compactWidth: 11 + 16 + 10 + volumeSliderCompact,
                     compactRank: Rank.volumeCompact, foldRank: Rank.volumeFold))
        out.append(S(id: more, fullWidth: 11 + 28, foldable: false))
        return out
    }

    /// Smallest window content width at which the toolbar still has its never-folding controls: the channel picker
    /// (compact), the "…" menu, padding and slack. The window's minimum is a round number above this.
    static var essentialWidth: CGFloat {
        ToolbarOverflowPlanner.requiredWidth(
            specs(hasRecord: false, bufferEnabled: false, recordingRelay: false, hasH264: false),
            levels: [catchUp: .folded, info: .folded, clock: .folded, volume: .folded, picker: .compact])
    }
}
