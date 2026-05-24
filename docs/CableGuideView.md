# CableGuideView.swift — Cable TV Guide Grid

## Intent

`CableGuideView` is a reusable cable-TV-style program guide grid. Rows are channels, columns are 30-minute time slots, and show blocks span proportionally to their duration. Both axes scroll simultaneously. The channel label column stays pinned on the left while the grid scrolls horizontally.

It is used in `AddShowView` step 2. It is a pure display component — selection and confirmation callbacks go back to the parent via bindings and closures.

---

## Layout Architecture

> **CRITICAL:** This layout went through 10+ failed attempts before the current structure was found. See `CableGuideView_pitfalls.md` before changing the outer structure.

```
HStack(alignment: .top, spacing: 0) {
  channelColumnFixed            ← pinned left column, clips to channelScrollOffset
  guideScrollView               ← ScrollView([.horizontal, .vertical])
    LazyVStack(pinnedViews: .sectionHeaders) {
      Section {
        ForEach(allChannels) { ShowBlocksRow(...).equatable() }
      } header: {
        scrollingTimeHeader      ← time header inside ScrollView; scrolls horizontally,
                                    pinned vertically by LazyVStack sectionHeaders
                                    (contains "now-anchor" for ScrollViewReader.scrollTo)
      }
    }
}
```

### Layout Constants

```swift
private let channelColW: CGFloat = 100    // fixed channel label column width
private let rowH:        CGFloat = 52     // row height per channel
private let headerH:     CGFloat = 26     // time header bar height
// pxPerMin is dynamic — scales to fill available width (min 4.2 px/min)
@State private var availableGridWidth: CGFloat = 0
private var pxPerMin: CGFloat {
    guard availableGridWidth > 0 else { return 4.2 }
    return max(4.2, availableGridWidth / CGFloat(guideHours * 60))
}
```

`displayStart` is floored to the nearest 30-minute boundary, one slot before "now", so the current time is always visible just right of center on open.

`availableGridWidth` is captured via a `.background(GeometryReader { ... })` and updated whenever the window is resized — this drives pxPerMin recalculation and a `rebuildCaches()` call.

### Constraints That Must Be Preserved

1. **`GeometryReader` in `AddShowView` must wrap BOTH the summary panel AND `CableGuideView`** — pulling the summary panel outside the `GeometryReader` always causes the guide to fill the window and the summary to disappear.

2. **`CableGuideView` must NOT have a `.frame()` modifier in `AddShowView`** — the `GeometryReader` + `VStack` distributes height naturally.

3. **`LazyVStack(pinnedViews: [.sectionHeaders])` requires macOS 15+** — on macOS 13/14 this causes blank rows in a bidirectional `ScrollView` (lazy row visibility can't be resolved). macOS 15 is the current deployment floor so this is safe. Do not lower the deployment target without reverting to plain `VStack` + external `pinnedTimeHeader`.

4. **`guideScrollView` MUST have `.frame(maxWidth: .infinity, maxHeight: .infinity)`** — without it the scroll view collapses to near-zero width inside the HStack.

5. **Summary height = `proxy.size.height / 3`** (not a fixed pixel value).

6. **Window minimum = 1100×720 for the guide step** (resizable up to full screen), 560×540 for other steps. The grid fills available width dynamically via `pxPerMin` scaling.

---

## Color System

Color logic is in **module-level functions** (not `private` on `CableGuideView`) so `AddShowView` can call `guideEntryColor(for:onAir:)` for the summary panel background.

### Genre color map (`_genreColorMap`)

```swift
"drama":    blue       (hue 0.60)
"comedy":   amber      (hue 0.13)
"news":     crimson    (hue 0.95)
"sports":   green      (hue 0.33)
"reality":  orange     (hue 0.07)
"movie":    purple     (hue 0.75)
"talk":     teal       (hue 0.48)
"children": steel-blue (hue 0.56)
```

### Fallback palette (`_guidePalette`)

8 colors used when `GuideEntry.Filter` is absent or doesn't match a known genre. Color is selected by `abs((SeriesID ?? Title).hashValue) % 8` — deterministic per series/title, consistent across renders.

### `guideEntryColor(for:onAir:)`

```swift
func guideEntryColor(for entry: GuideEntry, onAir: Bool) -> Color {
    let base = _genreColorMap[entry.firstGenre?.lowercased() ?? ""]
             ?? _guidePalette[abs((entry.SeriesID ?? entry.Title).hashValue) % 8]
    return onAir ? base : base.opacity(0.75)  // future shows dimmed 25%
}
```

---

## `ShowBlocksRow`

`ShowBlocksRow` is a separate `private struct` conforming to both `View` and `Equatable`. This lets `.equatable()` skip `body` re-evaluation for unchanged rows during scroll.

### `==` Implementation

Compares: `channel.GuideNumber`, `entries.count`, `selectedEntry?.StartTime`, `selectedChannel?.GuideNumber`, `lineupEntry?.GuideNumber`, `genreFilter`, `displayStart`, `managedSeriesIDs`, `managedTitles`, `recordingSeriesIDs`, `recordingTitles`, `nextUpSeriesIDs`, `nextUpTitles`, `bonusSeriesIDs`, `bonusTitles`, `bonusMinutes`.

The `lineupEntry?.GuideNumber` field is included because a `nil → non-nil` change (lineup arriving after a cached guide load) must force a re-evaluation so that tap handlers get the real `LineupEntry` reference instead of nil. Without this, the first tap after a cold load does nothing — the handler calls `onSelect(entry, nil)` and `AddShowView` can't advance because `selectedChannel == nil`.

### Per-block decorations

| Condition | Visual |
|---|---|
| On-air (unselected) | Full opacity + `Color.white.opacity(0.12)` white wash overlay |
| Selected | White stroke border (2.5pt) + `checkmark.circle.fill` icon + `Color.white.opacity(0.15)` fill |
| Currently recording | Red stroke border (1.5pt) + red circle dot, top-right corner |
| Starts within 30 min | Orange stroke border (1.5pt) + `clock.badge.fill` icon (orange), top-right corner |
| Managed (any) | `bookmark.fill` icon (white, 0.9 opacity), bottom-left corner |
| Filter mismatch | 0.2 opacity, `allowsHitTesting(false)` |
| Bonus Time | Dotted `RoundedRectangle` sibling at `cellX + cellW + 2`; `.zIndex(1)` so it renders above the next block; next show's title is drawn inside the box so it remains readable even when fully covered; tapping the bonus box selects the overlapped next show |

Recording vs. next-up precedence: `isNextUp` is only true when `!isRecording` — the red recording state always takes visual priority. Both use SeriesID-first matching with title as fallback to avoid false positives when unrelated shows share a name.

### Selection logic

Selection compares `entry.id` (= `StartTime`) AND `lineupEntry != nil` AND `selectedChannel?.GuideNumber == lineupEntry?.GuideNumber`. The explicit `lineupEntry != nil` guard is required because Swift evaluates `nil == nil` as `true` — without it, when the lineup is absent every entry at the same `StartTime` across all channels appears selected simultaneously. Tap = single-select. Double-tap (`.simultaneousGesture(TapGesture(count: 2))`) calls `onConfirm?()` to advance the wizard.

---

## Bonus Time Dotted Box

For managed sports shows, a dotted `RoundedRectangle` is drawn as a sibling view at `cellX + cellW + 2` (immediately after the show block). Width = `bonusMinutes * pxPerMin`. "Bonus Time" label shown only when box > 60px wide.

---

## Scroll Synchronization

`channelScrollOffset` (vertical) is driven by `VerticalScrollTracker: NSViewRepresentable` — a zero-size `NSView` embedded in the scroll content `.background()`; it hooks `NSView.boundsDidChangeNotification` on the `NSScrollView.contentView` and fires on every AppKit scroll frame. A 1pt threshold and `disablesAnimations: true` prevent jitter.

**Do not replace `VerticalScrollTracker` with `.onScrollGeometryChange` or `GeometryReader + PreferenceKey`** — AppKit moves scroll content via CALayer translation without triggering SwiftUI view body re-evaluation. Those SwiftUI APIs only fire during a render pass, so they are completely silent on live scroll frames. `VerticalScrollTracker` is the only mechanism that fires per-frame on macOS. See `CableGuideView_pitfalls.md` and `feedback_channel_scroll_sync.md` for the full investigation.

The time header scrolls horizontally automatically (it's inside the `ScrollView`) and stays pinned vertically via `LazyVStack(pinnedViews: [.sectionHeaders])` — no `timeHeaderOffset` synchronization needed.

- `channelScrollOffset` → `.offset(y: -channelScrollOffset)` on the fixed channel column, inside `.clipped()`

---

## Performance Optimizations

- **Cached state** (`lineupByNumber`, `displayStart`, `timeSlots`) rebuilt once via `rebuildCaches()` on appear/lineup/guideHours/width changes — not on scroll.
- **`ShowBlocksRow.equatable()`** — skips body re-eval for unchanged rows during scroll.
- **`visibleEntries(_:)`** — filters each channel's entries to the display window before passing to rows.
- **No `LazyVStack`** — eager rendering of ~106 rows is fast because `.equatable()` skips unchanged rows.

---

## Parameters

| Parameter | Type | Purpose |
|---|---|---|
| `allChannels` | `[GuideChannel]` | All channel rows to display |
| `lineup` | `[LineupEntry]` | For HD badge + stream URL matching |
| `guideHours` | `Int` | How far ahead to show |
| `selectedEntry` | `@Binding GuideEntry?` | Currently selected guide cell |
| `selectedChannel` | `@Binding LineupEntry?` | Channel of the selected cell |
| `snapToNow` | `@Binding Bool` | Set true to scroll grid to current time |
| `managedSeriesIDs` | `Set<String>` | Shows already scheduled — bookmark badge |
| `managedTitles` | `Set<String>` | Title-based fallback for managed badge |
| `recordingSeriesIDs` | `Set<String>` | Shows currently recording — red border + dot |
| `recordingTitles` | `Set<String>` | Title-based fallback for recording badge |
| `nextUpSeriesIDs` | `Set<String>` | Shows recording within 30 min — orange border + clock |
| `nextUpTitles` | `Set<String>` | Title-based fallback for next-up badge |
| `bonusSeriesIDs` | `Set<String>` | Sports shows with Bonus Time — dotted box |
| `bonusTitles` | `Set<String>` | Title-based fallback for bonus box |
| `bonusMinutes` | `Int` | Bonus box width in minutes |
| `genreFilter` | `String?` | nil = all; non-nil = dim non-matching |
| `onConfirm` | `(() -> Void)?` | Called on double-tap — advances wizard; pass `{}` for browse-only views |
