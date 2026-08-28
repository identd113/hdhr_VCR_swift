import Foundation

// Pure grid/scheduling logic pulled out of main.swift's global-state-driven functions
// specifically to make it unit-testable (see StringLayout.swift's header for why the split was
// necessary at all). Each function here takes explicit parameters instead of reading main.swift's
// globals (`payload`, `selRow`, `colStart`, etc.) — main.swift's own same-named wrappers just
// forward those globals in.

// Mirrors Show.genreImpliesBonusTime (Models.swift) — "sport" not "sports" matches both guide.php's
// plural "Sports" and XMLTV's singular "Sport" tag. Duplicated rather than imported (hdhr_VCR is an
// executable, not a library) — without this, a sports show scheduled from the TUI silently never
// gets Bonus Time, unlike the native wizard and the web Record modal's own checkbox.
public func genreImpliesBonusTime(_ genre: String?) -> Bool {
    genre?.lowercased().contains("sport") == true
}

// max(1, ...) alone would force at least 1 grid column even when there isn't room for the fixed
// channel gutter plus a single slot beside it — every row line would then emit more characters
// than the terminal has, the overflow-and-wrap bug class this whole module exists to catch before
// it ships. render() (main.swift) guards that specific case separately (a terminal narrower than
// channelColWidth + slotWidth shows a "too narrow" message instead of attempting the grid at all)
// — this function's own floor of 1 is only ever reached when that guard has already confirmed
// there's room for at least one slot.
public func computeVisibleCols(cols: Int, channelColWidth: Int, slotWidth: Int, maxSlot: Int) -> Int {
    max(1, min((cols - channelColWidth) / slotWidth, maxSlot))
}

// Index of whichever entry in `entries` was airing at `anchorTime`, or — if there's a gap in the
// schedule right at that time — whichever entry starts closest to it. Empty `entries` falls back
// to 0 (out-of-range index the caller must itself guard, matching entryIndex's original contract).
//
// This is moveRow(_:)'s (main.swift) anchor-time channel-switch logic: switching the selected
// channel re-selects "whatever's airing at the same time you were already looking at" on the new
// row, rather than always landing on that row's own entry 0 — which is what used to make switching
// channels reset the horizontal (time) scroll position back to the start of the guide window even
// when scrolled hours into it. See docs/TUIGuide.md's Keybindings table.
public func entryIndex(nearestTo anchorTime: Int, in entries: [GuideEntryDTO]) -> Int {
    guard !entries.isEmpty else { return 0 }
    if let idx = entries.firstIndex(where: { $0.startTime <= anchorTime && $0.endTime > anchorTime }) {
        return idx
    }
    return entries.indices.min(by: {
        abs(entries[$0].startTime - anchorTime) < abs(entries[$1].startTime - anchorTime)
    }) ?? 0
}

// One row's left-to-right block layout: a real program (`entryOffset` = its index into `entries`)
// or a blank guide gap (`entryOffset == nil`), clipped to the visible `[colStart, colStart + vc)`
// slot window. `span` is in slot units (main.swift's `slotWidth` chars each), not characters.
public struct RowBlock: Equatable {
    public let span: Int
    public let entryOffset: Int?

    public init(span: Int, entryOffset: Int?) {
        self.span = span
        self.entryOffset = entryOffset
    }
}

// Builds one channel row's blocks for the grid. `entries` is assumed already time-ordered (as the
// server returns it) but NOT assumed non-overlapping — real-world guide data occasionally carries
// overlapping/duplicate entries for one channel (confirmed live: two back-to-back
// identically-titled listings whose slot ranges actually overlapped by one slot). Each entry's
// start is clamped to `colStart + cursorCol` (wherever the previous block's own end already put
// the cursor), not just `colStart` — without that clamp, an overlapping entry could render
// starting *before* the previous block had finished, pushing the row's total span past `vc` slots
// and wrapping the line past the terminal's width regardless of how correct the rest of the
// character-count math was. See docs/TUIGuide.md's Layout section.
public func layoutRowBlocks(entries: [GuideEntryDTO], winStart: Int, colStart: Int, vc: Int, secondsPerSlot: Int) -> [RowBlock] {
    var blocks: [RowBlock] = []
    var cursorCol = 0
    for (idx, e) in entries.enumerated() {
        let startSlot = (e.startTime - winStart) / secondsPerSlot
        let endSlot = max(startSlot + 1, (e.endTime - winStart + secondsPerSlot - 1) / secondsPerSlot)
        let visStart = max(startSlot, colStart, colStart + cursorCol)
        let visEnd = min(endSlot, colStart + vc)
        guard visEnd > visStart else { continue }
        let gapCols = max(0, (visStart - colStart) - cursorCol)
        if gapCols > 0 { blocks.append(RowBlock(span: gapCols, entryOffset: nil)); cursorCol += gapCols }
        let spanCols = visEnd - visStart
        blocks.append(RowBlock(span: spanCols, entryOffset: idx))
        cursorCol += spanCols
    }
    return blocks
}

// ── Search / channel-jump (a limited, offline counterpart to the web guide's own type-ahead show
// search — see docs/TUIGuide.md's "Deferred ideas" entry this fulfills, and its "Search / channel
// jump" section for the full design rationale) ──

// First channel (in `channels`' own already-sorted display order) whose guideNumber starts with
// `prefix` — the live jump target for "#5.1"-style channel-number entry in main.swift's `.search`
// mode. Live per keystroke (unlike searchShows below): typing "#5" jumps as soon as it's
// unambiguous, "#5.1" narrows further, with no Enter needed to confirm — a channel number is a
// single unambiguous target, not a list to choose from.
public func firstChannelIndex(matchingNumberPrefix prefix: String, in channels: [GuideChannelDTO]) -> Int? {
    guard !prefix.isEmpty else { return nil }
    return channels.firstIndex { $0.guideNumber.hasPrefix(prefix) }
}

// One search-result row: a show (grouped by seriesId, or by lowercased title when seriesId is
// nil — the same "no ID -> fall back to title" shape Show.seriesTitle(from:) uses in the main
// app, duplicated rather than imported since hdhr_guide_core can't depend on the hdhr_VCR
// executable target, the same accepted tradeoff genreImpliesBonusTime above already makes) and
// the (channelIndex, entryIndex) of its single jump target.
public struct SearchResult: Equatable {
    public let title: String
    public let channelIndex: Int
    public let entryIndex: Int
    public let airingCount: Int

    public init(title: String, channelIndex: Int, entryIndex: Int, airingCount: Int) {
        self.title = title
        self.channelIndex = channelIndex
        self.entryIndex = entryIndex
        self.airingCount = airingCount
    }
}

// Case-insensitive substring match against every already-loaded channel's entries — no network
// call, unlike the web guide's `/api/guide-search`: everything this needs is already sitting in
// `payload` (the same full guide window already displayed, "No client-side time cap" per
// docs/TUIGuide.md), so there's nothing to debounce or request-id-guard against a stale in-flight
// fetch the way the web version has to.
//
// Grouped by show (see SearchResult's own doc comment) rather than one row per raw entry, so a
// show with many reruns collapses into one line instead of crowding the small, `limit`-capped
// list — the same reason the web guide's own /api/guide-search groups by SeriesID. Each group's
// jump target is its chronologically EARLIEST airing in the loaded window, mirroring the web
// guide's `airings sorted by start` / `jumpToSearchAiring` landing on `airings[0]`. Deliberately
// narrower than the web version: no per-result episode cycling (←/→ between a show's other
// airings) — picking a result jumps to that one airing; from there the grid's own ←/→ already
// covers moving between a channel's other programs. Sorted by title, capped at `limit`.
public func searchShows(query: String, in channels: [GuideChannelDTO], limit: Int) -> [SearchResult] {
    let q = query.lowercased()
    guard !q.isEmpty else { return [] }

    struct Group { var title: String; var channelIndex: Int; var entryIndex: Int; var startTime: Int; var count: Int }
    var groups: [String: Group] = [:]
    for (ci, ch) in channels.enumerated() {
        for (ei, e) in ch.entries.enumerated() where e.title.lowercased().contains(q) {
            let key = e.seriesId ?? e.title.lowercased()
            if var g = groups[key] {
                g.count += 1
                if e.startTime < g.startTime { g.channelIndex = ci; g.entryIndex = ei; g.startTime = e.startTime }
                groups[key] = g
            } else {
                groups[key] = Group(title: e.title, channelIndex: ci, entryIndex: ei, startTime: e.startTime, count: 1)
            }
        }
    }
    return groups.values
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        .prefix(limit)
        .map { SearchResult(title: $0.title, channelIndex: $0.channelIndex, entryIndex: $0.entryIndex, airingCount: $0.count) }
}
