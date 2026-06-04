# CableGuideView.swift — Cable TV Guide Grid

## Visual Appearance

The guide fills the entire available area below its parent's toolbar and to the right of the pinned channel column. It looks and behaves like a cable TV interactive program guide.

### Channel label column (left, 116pt wide, pinned)
- **Top-left corner cell**: accent-color background (macOS default blue), white bold `"CHANNEL"` label in 10pt font, 26pt tall — aligns exactly with the time header.
- **Favorites separator row** (20pt tall, when favorites exist): `windowBackgroundColor` fill, bottom 0.5pt separator line, yellow-tinted bold `"★  FAVORITES"` label in 9pt, left-padded 6pt.
- **Channel rows** (52pt tall each): `windowBackgroundColor` background, 0.5pt separator border on all sides at 35% opacity.
  - Left: 28×28 `ChannelIcon` (channel logo image, rounded, or blank if no URL)
  - Center: channel number in 11pt bold, channel name in 10pt secondary color below, `"HD"` badge in 8pt heavy accent color if `HD == 1`
  - Right: star button — `"★"` in yellow (16pt) if favorited, `"☆"` in tertiary label color if not; 22×22 tap target, plain button style
- **All Channels separator** (20pt, when both groups present): same style as Favorites separator, text `"ALL CHANNELS"` in secondary label color.
- Column background: `windowBackgroundColor`; clipped so rows scrolling off top/bottom are invisible.

### Time header (26pt tall, pinned vertically, scrolls horizontally)
- Background: accent color at 80% opacity (blue-ish strip spanning full guide width)
- 30-minute slot labels: white 10pt medium-weight text left-padded 5pt, each spanning `slotW` pixels
- **Red "now" line**: 2pt wide red `Rectangle` positioned at the current time's X offset — the only red element in the header, making the current moment immediately obvious.

### Guide grid cells (show blocks)
Each show occupies a rectangular block spanning `duration × pxPerMin` pixels wide and `rowH - 2` (50pt) tall. Inside the block:
- **Background**: genre color (see below) at full opacity for on-air shows; 75% opacity for future shows
- **Show title**: white, 11pt bold, padded 4pt top and 8pt left, up to 4 lines, `lineLimit` set to available height
- **Time label**: `"8:00 PM"` in white at 80% opacity, 9pt, at the top-left

**Block background colors by genre:**
| Genre | Color |
|---|---|
| Drama | Blue (hue 0.60, sat 0.65, bri 0.52) |
| Comedy | Amber (hue 0.13, sat 0.65, bri 0.52) |
| News | Crimson (hue 0.95, sat 0.60, bri 0.50) |
| Sports | Green (hue 0.33, sat 0.65, bri 0.46) |
| Reality | Orange (hue 0.07, sat 0.65, bri 0.52) |
| Movie | Purple (hue 0.75, sat 0.55, bri 0.50) |
| Talk | Teal (hue 0.48, sat 0.60, bri 0.48) |
| Children | Steel blue (hue 0.56, sat 0.50, bri 0.50) |
| No genre | Hash of SeriesID/Title → one of 8 palette colors |

**Block decorations (Z-ordered bottom to top):**
1. **Filter-dimmed** — non-matching genre blocks at 20% opacity, `allowsHitTesting(false)`
2. **On-air wash** — `Color.white.opacity(0.12)` overlay on currently-airing blocks
3. **Yellow managed triangle** — 22pt right-angle triangle, `Path.fill(.yellow)`, upper-right corner. Vertices: `(cellW-22, 0) → (cellW, 0) → (cellW, 22)`. Always rendered on top of the block background, below status icons.
4. **Selected border** — 2.5pt white stroke + `Color.white.opacity(0.15)` fill overlay when selected
5. **Status icons** (rendered after triangle so they appear on top of it; both are `.accessibilityHidden(true)` — their status is folded into the cell's composite accessibility label instead):
   - Recording: 8pt red `Circle` at `(cellW-12, 3)` — centred inside the yellow triangle
   - Next-up: `clock.badge.fill` (10pt orange) at `(cellW-14, 4)`

**Show title text frame**: `max(1, cellW - 8)` wide (constant 8pt right margin, regardless of selection state).

**Row background**: `underPageBackgroundColor` (very dark gray/black in dark mode) spans the full grid width per row. Vertical slot dividers: 0.5pt `separatorColor` at 18% opacity at every 30-minute boundary.

### Bonus Time dotted box
For managed sports shows, a dotted `RoundedRectangle` (cornerRadius 4, stroke 1.5pt, `secondaryLabelColor`) appears immediately to the right of the show block. Width = `bonusMinutes × pxPerMin`. When the box is wider than 60pt, a `"Bonus Time"` label appears inside in secondary color. The box has `.zIndex(1)` so it renders above the next channel's blocks.

### Section separators (favorites / all channels)
Between the favorites group and the general channel list, a 20pt-tall `Color(NSColor.controlBackgroundColor)` row spans the full grid width — matching the channel column's separator label row height exactly so both columns stay visually aligned across the divider.

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
private let channelColW: CGFloat = 116    // fixed channel label column width
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

Compares: `channel.GuideNumber`, `entries.count` (via `zip`+`allSatisfy` on `StartTime` — no array alloc), `selectedEntry?.StartTime`, `selectedChannel?.GuideNumber`, `lineupEntry?.GuideNumber`, `genreFilter`, `displayStart`, `timeSlots`, `managedMatcher`, `recordingMatcher`, `nextUpMatcher`, `bonusMatcher`, `bonusMinutes`.

The `lineupEntry?.GuideNumber` field is included because a `nil → non-nil` change (lineup arriving after a cached guide load) must force a re-evaluation so that tap handlers get the real `LineupEntry` reference instead of nil. Without this, the first tap after a cold load does nothing — the handler calls `onSelect(entry, nil)` and `AddShowView` can't advance because `selectedChannel == nil`.

### Per-block decorations

| Condition | Visual |
|---|---|
| On-air (unselected) | Full opacity + `Color.white.opacity(0.12)` white wash overlay |
| Selected | White stroke border (2.5pt) + `checkmark.circle.fill` icon + `Color.white.opacity(0.15)` fill |
| Currently recording | Red stroke border (1.5pt) + **red 22pt right-angle triangle** (`#ff6060`) top-right corner via `ManagedFlagView(recording: true)` |
| Starts within 30 min | Orange stroke border (1.5pt) + `clock.badge.fill` icon (orange), top-right area |
| Managed but not recording | Yellow 22pt right-angle triangle (`ManagedFlagView(recording: false)`) top-right corner |
| Filter mismatch | 0.2 opacity, `allowsHitTesting(false)` |
| Bonus Time | Dotted `RoundedRectangle` sibling at `cellX + cellW + 2`; `.zIndex(1)` so it renders above the next block; next show's title is drawn inside the box so it remains readable even when fully covered; tapping the bonus box selects the overlapped next show |

Recording takes visual priority: the red triangle is shown when `isRecording`; yellow only when `isManaged && !isRecording`. The red circle dot decoration was removed — the triangle alone communicates both states.

**Managed triangle sizing rationale**: the triangle is 22pt so the 8pt red recording dot (offset `x: cellW-12, y: 3`) sits fully inside the triangle without overflowing. Triangle vertices: `(cellW-22, 0) → (cellW, 0) → (cellW, 22)` — right angle at top-right corner.

Recording vs. next-up precedence: `isNextUp` is only true when `!isRecording` — the red recording state always takes visual priority. Both use SeriesID-first matching with title as fallback to avoid false positives when unrelated shows share a name.

### Selection logic

Selection compares `entry.id` (= `StartTime`) AND `lineupEntry != nil` AND `selectedChannel?.GuideNumber == lineupEntry?.GuideNumber`. The explicit `lineupEntry != nil` guard is required because Swift evaluates `nil == nil` as `true` — without it, when the lineup is absent every entry at the same `StartTime` across all channels appears selected simultaneously. Tap = single-select. Double-tap (`.simultaneousGesture(TapGesture(count: 2))`) calls `onConfirm?()` to advance the wizard.

### Accessibility

Each show block is a single collapsed accessibility element (`.accessibilityElement(children: .ignore)` + `.accessibilityAddTraits(.isButton)`). Its label is built at render time: `"Title[, EpisodeTitle], HH:MM – HH:MM[, Recording now | Recording soon | Scheduled]"`. Two actions are registered:
- **Default** (VO+Space): calls `onSelect(entry, lineupEntry)` — selects the cell and populates the summary panel.
- **"Record"** (VO+Cmd+Space action chooser): calls `onSelect` then `onConfirm?()` — selects and immediately advances (no-op in FloatingGuideView which passes `onConfirm: {}`).

The favorite star button has `.accessibilityLabel("Add to favorites")` / `"Remove from favorites"` matching its `.help()` text.

The bonus time dotted box is also a collapsed accessible button: label `"Bonus Time overlap — [next show title]"`, default action selects the next show.

---

## Bonus Time Dotted Box

For managed sports shows, a dotted `RoundedRectangle` is drawn as a sibling view at `cellX + cellW + 2` (immediately after the show block). Width = `bonusMinutes * pxPerMin`. "Bonus Time" label shown only when box > 60px wide.

---

## Scroll Synchronization

`channelScrollOffset` (vertical) is driven by `VerticalScrollTracker: NSViewRepresentable` — a zero-size `NSView` embedded in the scroll content `.background()`; it hooks `NSView.boundsDidChangeNotification` on the `NSScrollView.contentView` and fires on every AppKit scroll frame. A 1pt threshold and `disablesAnimations: true` prevent jitter.

**Do not replace `VerticalScrollTracker` with `.onScrollGeometryChange` or `GeometryReader + PreferenceKey`** — AppKit moves scroll content via CALayer translation without triggering SwiftUI view body re-evaluation. Those SwiftUI APIs only fire during a render pass, so they are completely silent on live scroll frames. `VerticalScrollTracker` is the only mechanism that fires per-frame on macOS. See `CableGuideView_pitfalls.md` and `feedback_channel_scroll_sync.md` for the full investigation.

The time header scrolls horizontally automatically (it's inside the `ScrollView`) and stays pinned vertically via `LazyVStack(pinnedViews: [.sectionHeaders])` — no `timeHeaderOffset` synchronization needed.

- `channelScrollOffset` → `.offset(y: -channelScrollOffset)` on the fixed channel column, inside `.clipped()`

### Channel column scroll forwarding

`channelColumnFixed` has `.background(ChannelScrollForwarder())` — an `NSViewRepresentable` that installs a local `NSEvent` monitor for `.scrollWheel` events. When a scroll event lands in the channel column, it is forwarded to the `NSScrollView` via `sv.scrollWheel(with: event)`. **X is saved before and restored after** to prevent the forwarded event from shifting the time axis:

```swift
let savedX = sv.contentView.bounds.origin.x
sv.scrollWheel(with: event)
var pt = sv.contentView.bounds.origin
if pt.x != savedX { pt.x = savedX; sv.contentView.scroll(to: pt); sv.reflectScrolledClipView(sv.contentView) }
return nil   // consume — don't forward to default handler
```

The monitor returns `nil` (consuming the event) so the channel column itself doesn't scroll horizontally. `VerticalScrollTracker` picks up the resulting `NSScrollView` movement and drives `channelScrollOffset` as normal.

---

## Performance Optimizations

- **`lbn`/`favs`/`others` computed once per body evaluation** — `lineupByNumber` (a `Dictionary` build over `lineup`) and the favorites/others split are computed once in `body` and passed to both `channelColumnFixed` and `guideScrollView`. Avoids rebuilding the dictionary twice per render.
- **Cached state** (`displayStart`, `timeSlots`) rebuilt once via `rebuildCaches()` on appear/guideHours/width changes — not on scroll.
- **`ShowBlocksRow.equatable()`** — skips body re-eval for unchanged rows during scroll.
- **`visibleEntries(_:)`** — filters only; no sort. `GuideStore.buildIndex` pre-sorts each channel's `Guide` array when indexing, so `ch.Guide` is already in `StartTime` order by the time the view reads it.
- **`LazyVStack(pinnedViews: [.sectionHeaders])`** wraps the row `ForEach` so only visible rows instantiate; `.equatable()` additionally skips body re-evaluation for unchanged visible rows during scroll.

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
| `deviceId` | `String` | DeviceID of the device whose guide is shown |
| `managedMatcher` | `ManagedGuideMatcher` | All managed-show matching tiers (seriesID, title, dateTime slot, single slot) — yellow/red triangle flag |
| `recordingMatcher` | `ShowMatcher` | Shows currently recording — red triangle flag + red border |
| `nextUpMatcher` | `ShowMatcher` | Shows starting within 30 min — orange border + clock icon |
| `bonusMatcher` | `ShowMatcher` | Sports shows with Bonus Time — dotted bonus-time box |
| `bonusMinutes` | `Int` | Bonus box width in minutes |
| `genreFilter` | `String?` | nil = all; non-nil = dim non-matching |
| `onConfirm` | `(() -> Void)?` | Called on double-tap — advances wizard; pass `{}` for browse-only views |

The `managedMatcher`, `recordingMatcher`, `nextUpMatcher`, and `bonusMatcher` parameters replace the previous ten separate `Set<String>` parameters (`managedSeriesIDs`, `managedTitles`, `managedDTSingleSlotKeys`, `recordingSeriesIDs`, `recordingTitles`, `nextUpSeriesIDs`, `nextUpTitles`, `bonusSeriesIDs`, `bonusTitles`). See `ManagedGuideMatcher` and `ShowMatcher` in [Models.md](Models.md).
