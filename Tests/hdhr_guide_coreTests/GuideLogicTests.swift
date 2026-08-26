import Testing
@testable import hdhr_guide_core

@Suite("genreImpliesBonusTime")
struct GenreImpliesBonusTimeTests {
    @Test func matchesPluralSports() { #expect(genreImpliesBonusTime("Sports") == true) }
    @Test func matchesSingularSportXMLTVTag() { #expect(genreImpliesBonusTime("Sport") == true) }
    @Test func isCaseInsensitive() { #expect(genreImpliesBonusTime("SPORTS") == true) }
    @Test func nonSportsGenreDoesNotMatch() { #expect(genreImpliesBonusTime("Drama") == false) }
    @Test func nilGenreDoesNotMatch() { #expect(genreImpliesBonusTime(nil) == false) }
}

@Suite("computeVisibleCols")
struct ComputeVisibleColsTests {
    @Test func normalWidthComputesSlotsFromRemainingSpace() {
        // 100 cols - 20 gutter = 80 / 14 slotWidth = 5 (integer division)
        #expect(computeVisibleCols(cols: 100, channelColWidth: 20, slotWidth: 14, maxSlot: 56) == 5)
    }

    @Test func cappedByMaxSlotOnAVeryWideTerminal() {
        // A terminal wide enough for far more slots than the server actually has data for
        // shouldn't report more columns than exist.
        #expect(computeVisibleCols(cols: 1000, channelColWidth: 20, slotWidth: 14, maxSlot: 5) == 5)
    }

    @Test func floorsAtOneEvenWhenNarrowerThanOneSlot() {
        // The floor itself — main.swift's render() is responsible for refusing to attempt the grid
        // at all below channelColWidth + slotWidth (see docs/TUIGuide.md's "Robustness fixes");
        // this function's own floor of 1 is what it falls back to once that guard has already
        // confirmed there's room, so it must never return less than 1 regardless of input.
        #expect(computeVisibleCols(cols: 10, channelColWidth: 20, slotWidth: 14, maxSlot: 56) == 1)
    }
}

@Suite("entryIndex(nearestTo:in:) — anchor-time channel switching")
struct EntryIndexTests {
    private func entry(_ title: String, _ start: Int, _ end: Int) -> GuideEntryDTO {
        GuideEntryDTO(title: title, startTime: start, endTime: end)
    }

    @Test func emptyEntriesReturnsZero() {
        #expect(entryIndex(nearestTo: 1000, in: []) == 0)
    }

    @Test func anchorInsideAnEntrysSpanSelectsThatEntry() {
        let entries = [entry("A", 0, 1800), entry("B", 1800, 3600), entry("C", 3600, 5400)]
        #expect(entryIndex(nearestTo: 2000, in: entries) == 1)   // inside B's span
    }

    @Test func anchorExactlyAtAnEntrysStartSelectsThatEntry() {
        let entries = [entry("A", 0, 1800), entry("B", 1800, 3600)]
        #expect(entryIndex(nearestTo: 1800, in: entries) == 1)
    }

    // The actual regression this function exists to fix: switching channels used to always land
    // on the new row's entry 0, resetting the horizontal (time) scroll position back to the start
    // of the guide window even when the user had scrolled hours into it. This is the "gap in the
    // schedule" case that mechanism relies on — a channel whose own schedule doesn't have anything
    // starting exactly at the anchor time still lands on the *closest* available entry, not entry 0.
    @Test func gapInScheduleFallsBackToNearestEntry() {
        // No entry covers 5000 (there's a gap between B ending at 3600 and C starting at 9000) —
        // nearest by |start - anchor| is C (9000, distance 4000) vs A (0, distance 5000) vs B
        // (1800, distance 3200) -> B is nearest.
        let entries = [entry("A", 0, 1800), entry("B", 1800, 3600), entry("C", 9000, 10800)]
        #expect(entryIndex(nearestTo: 5000, in: entries) == 1)
    }

    @Test func anchorBeforeEverythingSelectsNearestByStart() {
        let entries = [entry("A", 5000, 6800), entry("B", 9000, 10800)]
        #expect(entryIndex(nearestTo: 0, in: entries) == 0)
    }
}

@Suite("layoutRowBlocks — overlapping guide entries don't overflow the row")
struct LayoutRowBlocksTests {
    private func entry(_ title: String, _ start: Int, _ end: Int) -> GuideEntryDTO {
        GuideEntryDTO(title: title, startTime: start, endTime: end)
    }

    @Test func nonOverlappingEntriesFillTheirOwnSlots() {
        // winStart=0, secondsPerSlot=1800: A occupies slot 0, B occupies slot 1.
        let entries = [entry("A", 0, 1800), entry("B", 1800, 3600)]
        let blocks = layoutRowBlocks(entries: entries, winStart: 0, colStart: 0, vc: 5, secondsPerSlot: 1800)
        #expect(blocks == [RowBlock(span: 1, entryOffset: 0), RowBlock(span: 1, entryOffset: 1)])
    }

    @Test func gapBetweenEntriesBecomesABlankBlock() {
        let entries = [entry("A", 0, 1800), entry("B", 5400, 7200)]   // gap: slots 1-2 empty
        let blocks = layoutRowBlocks(entries: entries, winStart: 0, colStart: 0, vc: 5, secondsPerSlot: 1800)
        #expect(blocks == [
            RowBlock(span: 1, entryOffset: 0),
            RowBlock(span: 2, entryOffset: nil),
            RowBlock(span: 1, entryOffset: 1),
        ])
    }

    // The actual regression: real-world guide data occasionally carries overlapping/duplicate
    // entries for one channel (confirmed live: two back-to-back identically-titled listings whose
    // slot ranges actually overlapped by one slot). Without the clamp, B here would render starting
    // at its own natural slot 1 — inside A's still-active span — rather than being pushed to start
    // where A actually ends, and total span would exceed `vc`, overflowing the row past the
    // terminal's width.
    @Test func overlappingEntryIsClampedToStartWherePreviousBlockEnded() {
        // A: slots 0-1 (secs 0-3600). B: naturally starts at slot 1 (secs 1800), overlapping A's
        // still-active second slot, and runs to slot 3 (secs 7200) — a real guide-feed overlap
        // quirk, not something this app can fix upstream.
        let entries = [entry("A", 0, 3600), entry("B", 1800, 7200)]
        let blocks = layoutRowBlocks(entries: entries, winStart: 0, colStart: 0, vc: 5, secondsPerSlot: 1800)
        // Total span across all blocks must never exceed vc (5) — that's the actual bug this
        // guards: total content wider than the visible window.
        let totalSpan = blocks.reduce(0) { $0 + $1.span }
        #expect(totalSpan <= 5, "overlapping entries must not push total row span past vc")
        // A gets its full 2 slots (0-1); B is clamped to start at slot 2 (where A ended, not its
        // own natural slot 1) and keeps its own remaining span (slots 2-3) within the window.
        #expect(blocks == [RowBlock(span: 2, entryOffset: 0), RowBlock(span: 2, entryOffset: 1)])
    }

    // The narrower case: an overlapping entry whose own span is *fully* consumed by the clamp (its
    // natural end time is no later than where the clamp pushes its start to) drops out entirely —
    // still safe (no overflow), just nothing left to show for a fully-duplicate listing.
    @Test func fullyOverlappingDuplicateEntryIsDroppedNotStretched() {
        let entries = [entry("A", 0, 3600), entry("B", 0, 3600)]   // exact duplicate of A
        let blocks = layoutRowBlocks(entries: entries, winStart: 0, colStart: 0, vc: 5, secondsPerSlot: 1800)
        #expect(blocks == [RowBlock(span: 2, entryOffset: 0)])
    }

    @Test func entryFullyBeforeVisibleWindowIsExcluded() {
        let entries = [entry("A", 0, 1800), entry("B", 3600, 5400)]
        // colStart=2 means the visible window starts at slot 2 (secs 3600+) — A (slot 0) is
        // entirely before it and should be dropped, not rendered as a negative-offset block.
        let blocks = layoutRowBlocks(entries: entries, winStart: 0, colStart: 2, vc: 3, secondsPerSlot: 1800)
        #expect(blocks == [RowBlock(span: 1, entryOffset: 1)])
    }

    @Test func entryFullyAfterVisibleWindowIsExcluded() {
        let entries = [entry("A", 0, 1800), entry("B", 9000, 10800)]
        let blocks = layoutRowBlocks(entries: entries, winStart: 0, colStart: 0, vc: 2, secondsPerSlot: 1800)
        #expect(blocks == [RowBlock(span: 1, entryOffset: 0)])   // B (slot 5) is past vc=2, excluded
    }

    @Test func emptyEntriesProducesNoBlocks() {
        #expect(layoutRowBlocks(entries: [], winStart: 0, colStart: 0, vc: 5, secondsPerSlot: 1800) == [])
    }
}
