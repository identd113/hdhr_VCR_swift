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
