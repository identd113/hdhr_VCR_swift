# CableGuideView.swift — Cable TV Guide Grid

## Intent

`CableGuideView` is a reusable cable-TV-style program guide grid. Rows are channels, columns are 30-minute time slots, and show blocks span proportionally to their duration. Both axes scroll simultaneously. The channel label column stays pinned on the left while the grid scrolls horizontally.

It is used in `AddShowView` step 2. It is a pure display component — selection and confirmation callbacks go back to the parent via bindings and closures.

---

## Layout Architecture

> **CRITICAL:** This layout went through 10+ failed attempts before the current structure was found. Do not change the outer structure without reading `cableView.md`.

```
HStack(alignment: .top, spacing: 0) {
  channelColumnFixed            ← pinned left column, clips to channelScrollOffset
  VStack(maxWidth: .infinity, maxHeight: .infinity) {
    pinnedTimeHeader             ← time slots header, tracks timeHeaderOffset
    guideScrollView              ← ScrollView([.horizontal, .vertical])
      VStack {
        zero-height now-anchor   ← for ScrollViewReader.scrollTo("now")
        VStack {                 ← plain VStack (NOT LazyVStack — see Constraints)
          ForEach(allChannels) { ShowBlocksRow(...).equatable() }
        }
      }
  }
}
```

### Layout Constants

```swift
private let channelColW: CGFloat = 100    // fixed channel label column width
private let rowH:        CGFloat = 52     // row height per channel
private let headerH:     CGFloat = 26     // time header bar height
private let pxPerMin:    CGFloat = 4.2    // pixels per minute in the time axis
```

`displayStart` is floored to the nearest 30-minute boundary, one slot before "now", so the current time is always visible just right of center on open.

### Constraints That Must Be Preserved

1. **`GeometryReader` in `AddShowView` must wrap BOTH the summary panel AND `CableGuideView`** — pulling the summary panel outside the `GeometryReader` always causes the guide to fill the window and the summary to disappear.

2. **`CableGuideView` must NOT have a `.frame()` modifier in `AddShowView`** — the `GeometryReader` + `VStack` distributes height naturally.

3. **Plain `VStack`, NOT `LazyVStack`** — `LazyVStack(pinnedViews: .sectionHeaders)` inside a bidirectional `ScrollView` cannot compute lazy row visibility, causing all content to render blank. With 106 channels at 52px each (~5500px total), eager rendering is acceptable and performs well due to `.equatable()`.

4. **Inner `VStack` (pinnedTimeHeader + guideScrollView) MUST have `.frame(maxWidth: .infinity, maxHeight: .infinity)`** — without it the VStack collapses to near-zero width inside the HStack.

5. **Summary height = `proxy.size.height / 3`** (not a fixed pixel value).

6. **Window size = 980×700 for the guide step**, 560×540 for others. These sizes were tuned for the layout; changing them may require re-validating the grid proportions.

---

## Color System

Color logic is in **module-level functions** (not `private` on `CableGuideView`) so `AddShowView` can call `guideEntryColor(for:onAir:)` for the summary panel background.

### Genre color map (`_genreColorMap`)

```swift
"drama":    blue   (hue 0.60)
"comedy":   amber  (hue 0.13)
"news":     crimson (hue 0.95)
"sports":   green  (hue 0.33)
"reality":  orange (hue 0.07)
"movie":    purple (hue 0.75)
"talk":     teal   (hue 0.48)
"children": steel-blue (hue 0.56)
```

### Fallback palette (`_guidePalette`)

8 colors used when `GuideEntry.Filter` is absent or doesn't match a known genre. Color is selected by `abs((SeriesID ?? Title).hashValue) % 8` — deterministic per series/title, consistent across renders.

### `guideEntryColor(for:onAir:)`

```swift
func guideEntryColor(for entry: GuideEntry, onAir: Bool) -> Color {
    // Genre match first; palette hash as fallback
    let base = _genreColorMap[entry.firstGenre?.lowercased() ?? ""]
             ?? _guidePalette[abs((entry.SeriesID ?? entry.Title).hashValue) % 8]
    return onAir ? base : base.opacity(0.75)  // future shows dimmed 25%
}
```

On-air shows also get an additional `Color.white.opacity(0.12)` overlay rendered inside `showBlock()` to make them visibly brighter than the already-full-opacity color.

---

## `ShowBlocksRow`

`ShowBlocksRow` is a separate `private struct` conforming to both `View` and `Equatable`. This lets `.equatable()` skip `body` re-evaluation for unchanged rows during scroll — critical for smooth scrolling with 100+ channels.

### `==` Implementation

Compares:
- `channel.GuideNumber`
- `entries.count`
- `selectedEntry?.StartTime`
- `selectedChannel?.GuideNumber`
- `genreFilter`
- `displayStart`
- `managedSeriesIDs`, `managedTitles`
- `bonusSeriesIDs`, `bonusTitles`, `bonusMinutes`

A row only re-renders if any of these change. During scrolling, most rows are unchanged — only rows near the selection change.

### Per-block decorations

| Condition | Visual |
|---|---|
| On-air | Full opacity + `Color.white.opacity(0.12)` overlay |
| Selected | White stroke border (2.5pt) + checkmark icon + `Color.white.opacity(0.15)` fill |
| Not selected | Light black border (0.5pt) |
| On-air + managed | Red dot badge 5×5px, top-right corner |
| Managed (any) | `bookmark.fill` icon, bottom-left corner, white 0.9 opacity |
| Filter mismatch | 0.2 opacity, `allowsHitTesting(false)` |
| Bonus Time | Dotted box sibling view extending past the show's right edge |

### Episode title in block

Shown only when `cellW > 90` and `entry.EpisodeTitle` is non-empty. Font size 9, white 0.85 opacity. Prevents truncation artifact on narrow cells.

### Selection logic

Selection compares BOTH `entry.id` (= `StartTime`) AND `selectedChannel?.GuideNumber == lineupEntry?.GuideNumber`. This avoids false matches when two different channels have a show starting at the same epoch second.

Tap = single-select. Double-tap (using `.simultaneousGesture(TapGesture(count: 2))`) also calls `onConfirm?()` which advances the wizard to step 3.

---

## Bonus Time Dotted Box

For managed sports shows (`bonusSeriesIDs` / `bonusTitles` match), a dotted `RoundedRectangle` is drawn as a **sibling view** in the parent `ZStack`, positioned at `cellX + cellW + 2` (immediately after the show block).

```swift
if isBonusTime && bonusMinutes > 0 {
    let bonusW = max(8, CGFloat(bonusMinutes) * pxPerMin - 2)
    ZStack(alignment: .topLeading) {
        RoundedRectangle(cornerRadius: 3)
            .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            .foregroundColor(guideEntryColor(for: entry, onAir: onAir).opacity(0.85))
        if bonusW > 60 {
            Text("Bonus Time")
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(guideEntryColor(for: entry, onAir: onAir).opacity(0.9))
                .padding(.horizontal, 4).padding(.top, 4)
        }
    }
    .frame(width: bonusW, height: rowH - 2)
    .offset(x: cellX + cellW + 2, y: 1)
    .allowsHitTesting(false)  // taps fall through to the underlying show block
}
```

Width = `bonusMinutes * pxPerMin` pixels. The box uses the same genre color as the show block at 0.85 opacity. "Bonus Time" label shown only when box is wider than 60px. The box intentionally overlaps whatever show follows — this is the visual metaphor that Bonus Time is "stealing" screen space from the next program.

---

## Scroll Synchronization

The channel column does not scroll horizontally but must scroll vertically in sync with the guide grid. The time header does not scroll vertically but must track horizontal scroll.

Both are driven by `onScrollGeometryChange(for: CGPoint.self)` monitoring `contentOffset` of the guide `ScrollView`:

```swift
.onScrollGeometryChange(for: CGPoint.self, of: { $0.contentOffset }) { _, pt in
    var t = Transaction(); t.disablesAnimations = true
    withTransaction(t) {
        if abs(pt.y - channelScrollOffset) > 1 { channelScrollOffset = pt.y }
        if abs(pt.x - timeHeaderOffset)    > 1 { timeHeaderOffset    = pt.x }
    }
}
```

- `channelScrollOffset` → applied as `.offset(y: -channelScrollOffset)` on the channel column, inside a `.clipped()` container
- `timeHeaderOffset` → applied as `.offset(x: -timeHeaderOffset)` on the pinned time header

The 1pt threshold prevents jitter on sub-pixel scroll increments. `disablesAnimations: true` prevents spring animation artifacts on small increments (which would cause visible lag).

`onScrollGeometryChange` requires macOS 15+. This is why `Package.swift` sets the minimum OS to `"15.0"`.

---

## Performance Optimizations

- **`lineupByNumber`, `displayStart`, `timeSlots`** cached as `@State`, rebuilt once via `rebuildCaches()` on `.onAppear`/`onChange(of: lineup.count)`/`onChange(of: guideHours)` — NOT on every scroll-triggered body re-evaluation.
- **`ShowBlocksRow.equatable()`** — SwiftUI skips body re-eval for unchanged rows. Only rows where selection, entries, or managed state changed re-render.
- **`visibleEntries(_:)`** — filters each channel's guide entries to the display window (`displayStart...displayEnd`) before passing to `ShowBlocksRow`, so entries outside the visible time range don't render blocks.
- **No `LazyVStack`** — eager rendering of ~106 rows × 52px = ~5500px total is fast because each row's body is skipped by `.equatable()` during scroll.

---

## Parameters

| Parameter | Type | Purpose |
|---|---|---|
| `allChannels` | `[GuideChannel]` | All channel rows to display |
| `lineup` | `[LineupEntry]` | For HD badge + stream URL matching |
| `guideHours` | `Int` | How far ahead to show |
| `selectedEntry` | `@Binding GuideEntry?` | Currently selected guide cell |
| `selectedChannel` | `@Binding LineupEntry?` | Channel of the selected cell |
| `snapToNow` | `@Binding Bool` | Set true externally to scroll grid to current time |
| `managedSeriesIDs` | `Set<String>` | Shows already scheduled — shows bookmark badge |
| `managedTitles` | `Set<String>` | Title-based fallback for managed badge |
| `bonusSeriesIDs` | `Set<String>` | Sports shows with Bonus Time — shows dotted box |
| `bonusTitles` | `Set<String>` | Title-based fallback for bonus box |
| `bonusMinutes` | `Int` | How many minutes the bonus box extends (= `config.Sports_padding_minutes`) |
| `genreFilter` | `String?` | nil = all; non-nil = dim non-matching |
| `onConfirm` | `(() -> Void)?` | Called on double-tap — advances wizard to step 3 |

---

## What Still Needs Doing

- **Horizontal scroll position persistence** — when the genre filter changes and the view re-renders, the horizontal scroll position resets to the start (or to "Now"). The "Now" button mitigates this but it can be disorienting.

- **Channel icon loading** — `ChannelIcon` uses `ChannelIconCache` (disk-backed async cache). Icons load progressively. There's no shimmer/placeholder; rows show a blank square until the icon loads.

- **Landscape/wide-screen layout** — the guide grid at 980×700 works well on 1440p but can feel cramped on smaller monitors. `channelColW` (100px) and `rowH` (52px) are hardcoded constants — these could be user-adjustable.

- **Time slot columns** — currently 30-minute slots (1800 seconds = `slotW`). A 15-minute slot option would be useful for shows with non-standard durations but would double the rendered content width.

- **Bonus Time box overlapping** — the dotted box draws over whatever show follows the sports show. This is intentional (Bonus Time "steals" from the next show) but can look confusing if the next show block is narrow. A translucent fill inside the dotted box would make the overlay nature clearer.

- **Multi-device guide in one view** — currently shows one device at a time. For households with multiple tuners showing different channel lineups, a device switcher or merged view would be useful.

- **Filter by "already managed"** — no way to filter/highlight all shows already being recorded. The bookmark badge exists but scanning 100+ channels visually is slow.
