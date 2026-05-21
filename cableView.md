# CableGuideView Layout — Investigation Log

## The Problem
Add Show wizard step 2 (guide grid) should show:
1. **Toolbar** at top — Tuner picker, Genre filter, Now button, Refresh button
2. **Summary panel** below toolbar — shows selected show details (dynamic height)
3. **Cable guide grid** filling the remaining space — scrollable both axes

**Symptom (original)**: Once guide data loads (106 channels), the toolbar and
summary panel disappear. The guide grid fills the entire window. The visible
channels start partway down the list (e.g. ch 15.7, not 2.1), indicating the
content is being shown from the middle, not the top.

## Root Cause Theory (confirmed by channel offset)
The guideStep `VStack` grows to its natural content height (~5800px: toolbar +
summary + 106 channels × 52px). The outer `.frame(height: 620)` clips it, but
SwiftUI centers the oversized child by default. The visible 620px window shows the
MIDDLE of the 5800px stack — cutting off the toolbar/summary at the top and the
bottom channels at the bottom.

---

## What We Tried

### 1. LazyVStack → VStack (FAILED)
Changed `LazyVStack(pinnedViews: .sectionHeaders)` to plain `VStack` inside
`scrollableGrid`. No change. Reverted.

### 2. Removed GeometryReader from AddShowView (PARTIAL — blank grid)
Original code wrapped guideStep content in a `GeometryReader` that starved
`CableGuideView` of height → grid was completely blank. Removing it made the
grid visible, but introduced the toolbar-disappearing problem.

### 3. `.frame(maxWidth: .infinity, maxHeight: .infinity)` on CableGuideView body (FAILED)
Made `CableGuideView.body` explicitly fill max space. Made things worse —
the view claimed all space before the VStack could allocate to toolbar/summary.
Removed.

### 4. Inner VStack wrapper with `.frame(maxWidth: .infinity, maxHeight: .infinity)` (FAILED)
Wrapped summary + CableGuideView in a nested VStack with the max frame. Same
result — guide fills window.

### 5. `.fixedSize(horizontal: false, vertical: true)` on header VStack (FAILED)
Grouped toolbar + summary into an inner VStack with `.fixedSize(vertical: true)`
to force natural height. Same result.

### 6. Restored first-push structure exactly (FAILED — same problem)
Checked out the first working commit (ddb95f0) structure:
- Two toolbar HStack rows (tuner row + genre row)
- `summaryPanel.frame(height: 130)` with no wrapper
- `CableGuideView` with NO frame modifier
- Window 860×620
- `LazyVStack(pinnedViews: .sectionHeaders)` in scrollableGrid

### 7. GeometryReader wrapping ONLY CableGuideView (FAILED)
```swift
summaryPanel.frame(height: 130)
Divider()
GeometryReader { geo in
    CableGuideView(...).frame(width: geo.size.width, height: geo.size.height)
}
```
Broke the layout. Summary panel disappeared, shows were not visible.
This was re-attempted in a later session (see Attempt 9 below) with same result.

---

## ⚠️ COMMITTED SOLUTION (commit 353c7bf) — HAS BLANK GRID BUG

Single `GeometryReader` wraps **both** summaryPanel and CableGuideView together.
Summary height = 1/3 of available height. CableGuideView gets the rest with
**no frame modifier**. The AddShowView side of this is CORRECT and must not change.

However the committed CableGuideView internals use:
```swift
LazyVStack(spacing: 0, pinnedViews: .sectionHeaders)
```
This causes **blank rows** — LazyVStack with `pinnedViews` in a bidirectional
`ScrollView([.horizontal, .vertical])` cannot compute lazy visibility correctly.
Channel column showed, guide blocks were blank.

---

## ✅ WORKING SOLUTION (session 3)

Same AddShowView structure as 353c7bf (GeometryReader wrapping both). CableGuideView
internals rebuilt:

**Key changes vs committed:**
1. Time header moved OUTSIDE the scroll view (`pinnedTimeHeader`) — synced via
   `timeHeaderOffset` state updated by `onScrollGeometryChange(for: CGPoint.self)`
2. `LazyVStack` → plain `VStack` — LazyVStack in bidirectional ScrollView fails to
   render rows. VStack renders all 106 rows immediately (acceptable for this count).
3. Inner VStack (pinnedTimeHeader + guideScrollView) needs
   `.frame(maxWidth: .infinity, maxHeight: .infinity)` — without it the VStack
   gets zero width in the HStack even though channelColumnFixed only takes 100px.

**CableGuideView.body:**
```swift
HStack(alignment: .top, spacing: 0) {
    channelColumnFixed
    VStack(spacing: 0) {
        pinnedTimeHeader
        guideScrollView
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)  // ← REQUIRED
}
```

**guideScrollView:**
```swift
ScrollView([.horizontal, .vertical]) {
    VStack(spacing: 0) {          // ← plain VStack, NOT LazyVStack
        HStack { ... }.frame(width: totalW, height: 0)  // zero-height now-anchor
        VStack(spacing: 0) {
            ForEach(allChannels) { ch in showBlocksRow(ch) }
        }
        .frame(width: totalW)
    }
}
.onScrollGeometryChange(for: CGPoint.self, of: { $0.contentOffset }) { _, pt in
    channelScrollOffset = pt.y
    timeHeaderOffset    = pt.x
}
```

Window size: **860 × 620** for guide step, 560 × 540 for others.

---

## Session 2 Failures (attempted "small changes")

### 8. Moved summaryPanel OUTSIDE GeometryReader (FAILED — same as #7)
Tried:
```swift
summaryPanel.frame(height: 130)   // fixed height, outside GeometryReader
Divider()
GeometryReader { geo in
    CableGuideView(...).frame(width: geo.size.width, height: geo.size.height)
}
```
Result: no summary area visible, shows no longer visible in grid.
This is the SAME failure mode as attempt #7. The constraint is clear:
**GeometryReader must wrap both summary and CableGuideView together.**

### 9. Restructured CableGuideView scroll architecture (FAILED)
Tried moving the time header OUTSIDE the scroll view (as a pinned external
view, synced via `timeHeaderOffset: CGFloat`), replacing the Section-pinned
approach. Combined with attempt #8 so hard to isolate, but was deployed
together and broke the view.

Changes made that need reverting:
- `channelColW`: 88 → 100
- `scrollableGrid` replaced with `pinnedTimeHeader` + `guideScrollView`
- Added `timeHeaderOffset` state, tracked both axes via `onScrollGeometryChange`
- `.clipped()` / `.frame(maxHeight:)` order swapped in `channelColumnFixed`
- `HStack(alignment: .top, spacing: 0)` in body (may be safe)
- Bottom separator overlay on guide rows (may be safe)

### 10. Moved Tuner picker to right side of toolbar (minor change, part of #8/#9 deploy)
Moved Tuner picker from LEFT of toolbar to RIGHT (after Now/Refresh).
Combined with #8 so could not evaluate independently.

---

## Constraints Confirmed

1. **GeometryReader must wrap both summaryPanel AND CableGuideView** — pulling
   summary outside always breaks the layout.
2. **CableGuideView must NOT have a `.frame()` modifier in AddShowView** —
   the GeometryReader+VStack pattern distributes height naturally.
3. **Summary height = `proxy.size.height / 3`** — not a fixed pixel value.
4. **Window size for guide step = 860 × 620** — larger sizes untested/may break.
5. **LazyVStack CANNOT be used in a bidirectional ScrollView** — rows go blank.
   Use plain `VStack`. 106 channels is small enough to render eagerly.
6. **Inner VStack (pinnedTimeHeader + guideScrollView) MUST have
   `.frame(maxWidth: .infinity, maxHeight: .infinity)`** — without it the VStack
   gets zero width even though the HStack has room. Root cause unclear; may be
   SwiftUI HStack not distributing remaining space to the flexible child when the
   child's ideal width (from ScrollView content) is much larger than available.

## Files
- `Sources/hdhr_VCR/Views/AddShowView.swift` — wizard, guideStep computed var
- `Sources/hdhr_VCR/Views/CableGuideView.swift` — cable guide grid component
