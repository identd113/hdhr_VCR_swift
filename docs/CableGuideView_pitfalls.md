# CableGuideView Layout — Pitfalls and Failed Attempts

> **Read this before changing the outer layout structure of `CableGuideView` or `AddShowView`'s guide step.**
> The current layout went through 10+ failed attempts before landing on the working solution.

---

## The Problem

Add Show wizard step 2 should show:
1. Toolbar at top (Tuner picker, Genre filter, Now, Refresh)
2. Summary panel below toolbar (shows selected show details)
3. Cable guide grid filling the remaining space (scrollable both axes)

**Recurring symptom**: Once guide data loads (106 channels × 52px ≈ 5800px), the toolbar and summary panel disappear. The guide grid fills the entire window. Visible channels start partway down the list (e.g. ch 15.7, not 2.1), indicating content is shown from the middle.

**Root cause**: The `guideStep` VStack grows to its natural content height (~5800px). The outer `.frame(height: ...)` clips it, but SwiftUI centers the oversized child by default. The visible window shows the MIDDLE of the 5800px stack — cutting off the toolbar/summary at the top and lower channels at the bottom.

---

## Failed Attempts

### 1. LazyVStack → VStack (no effect)
Changed `LazyVStack(pinnedViews: .sectionHeaders)` to plain `VStack` inside `scrollableGrid`. No change. Reverted. (The centering bug is in `AddShowView`, not inside the scroll view.)

### 2. Removed GeometryReader from AddShowView (partial fix, blank grid)
The original code wrapped `guideStep` content in a `GeometryReader` that starved `CableGuideView` of height → grid was completely blank. Removing the `GeometryReader` made the grid visible but introduced the toolbar-disappearing centering problem. Not a complete solution.

### 3. `.frame(maxWidth: .infinity, maxHeight: .infinity)` on CableGuideView body
Added this to `CableGuideView.body` to claim all available space. Made things worse — the view claimed all space before the VStack could allocate any to toolbar/summary. Removed.

### 4. Inner VStack wrapper with max frame
Wrapped summary + `CableGuideView` in a nested `VStack` with `.frame(maxWidth: .infinity, maxHeight: .infinity)`. Same result — guide fills window.

### 5. `.fixedSize(horizontal: false, vertical: true)` on header VStack
Grouped toolbar + summary into an inner VStack with `.fixedSize(vertical: true)` to force natural height. Same result.

### 6. Restored first-push structure exactly
Checked out the first working commit (ddb95f0) structure verbatim:
- Two toolbar HStack rows (tuner + genre)
- `summaryPanel.frame(height: 130)` fixed
- `CableGuideView` with no frame modifier
- Window 860×620
- `LazyVStack(pinnedViews: .sectionHeaders)` in scrollableGrid

This structure failed to produce a working guide. Confirmed the centering bug exists regardless of toolbar structure.

### 7. GeometryReader wrapping ONLY CableGuideView

```swift
summaryPanel.frame(height: 130)
Divider()
GeometryReader { geo in
    CableGuideView(...).frame(width: geo.size.width, height: geo.size.height)
}
```

Summary panel disappeared and shows were not visible. Same failure: `GeometryReader` without a constrained parent collapses to zero.

### 8. summaryPanel OUTSIDE GeometryReader

```swift
summaryPanel.frame(height: 130)   // fixed height, outside GeometryReader
Divider()
GeometryReader { geo in
    CableGuideView(...).frame(width: geo.size.width, height: geo.size.height)
}
```

No summary area visible, shows no longer visible in grid. This is identical to attempt #7. The constraint is non-negotiable: **GeometryReader must wrap both summary and CableGuideView together.**

### 9. LazyVStack with pinnedViews in guideScrollView (blank rows)

The committed solution (353c7bf) used the correct AddShowView structure but kept:
```swift
LazyVStack(spacing: 0, pinnedViews: .sectionHeaders)
```
inside a `ScrollView([.horizontal, .vertical])`. Result: channel column appeared, guide blocks were blank. `LazyVStack` with `pinnedViews` in a bidirectional ScrollView cannot compute lazy row visibility — it renders nothing. Replacing with plain `VStack` fixed the blank-row bug. 106 rows is small enough to render eagerly (all rows are lightweight; `.equatable()` prevents re-evaluation during scroll).

### 10. Restructuring scroll architecture combined with #8

An attempt to move the time header outside the ScrollView (as a pinned external view synced via `timeHeaderOffset`) was deployed at the same time as attempt #8. Could not be isolated for testing. The combined deploy broke all visible content. Key side effects:
- `.clipped()` / `.frame(maxHeight:)` order swapped in `channelColumnFixed`
- `HStack(alignment: .top, spacing: 0)` added (safe by itself, but masked other issues)

---

## The Working Solution

The same AddShowView structure as 353c7bf — `GeometryReader` wrapping both summary and guide — but with corrected `CableGuideView` internals:

**AddShowView (`guideStep`):**
```swift
VStack(spacing: 0) {
    compactToolbar
    Divider()
    GeometryReader { proxy in   // MUST wrap both summary AND CableGuideView
        VStack(spacing: 0) {
            summaryPanel
                .frame(height: proxy.size.height / 3)
            Divider()
            CableGuideView(...)  // NO .frame() here
        }
    }
}
```

**CableGuideView body:**
```swift
HStack(alignment: .top, spacing: 0) {
    channelColumnFixed
    VStack(spacing: 0) {
        pinnedTimeHeader          // time header OUTSIDE the ScrollView
        guideScrollView           // ScrollView([.horizontal, .vertical])
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)  // REQUIRED — without this the VStack collapses to zero width
}
```

**guideScrollView:**
```swift
ScrollView([.horizontal, .vertical]) {
    VStack(spacing: 0) {
        HStack { ... }.frame(width: totalW, height: 0)   // zero-height "now" anchor
        VStack(spacing: 0) {                             // plain VStack, NOT LazyVStack
            ForEach(allChannels) { ShowBlocksRow(...).equatable() }
        }
    }
}
.onScrollGeometryChange(for: CGPoint.self, of: { $0.contentOffset }) { _, pt in
    channelScrollOffset = pt.y   // drives fixed channel column offset
    timeHeaderOffset    = pt.x   // drives pinned time header offset
}
```

---

## Constraints That Must Be Preserved

| # | Constraint | Consequence of violation |
|---|---|---|
| 1 | `GeometryReader` MUST wrap both summaryPanel AND `CableGuideView` | Guide fills window, toolbar/summary disappear |
| 2 | `CableGuideView` MUST NOT have a `.frame()` in `AddShowView` | Height distribution breaks |
| 3 | Summary height = `proxy.size.height / 3` (not fixed px) | Fixed height breaks proportions at different window sizes |
| 4 | Inner VStack (pinnedTimeHeader + guideScrollView) MUST have `.frame(maxWidth: .infinity, maxHeight: .infinity)` | VStack gets zero width inside HStack |
| 5 | Plain `VStack`, NOT `LazyVStack` | All guide rows render blank |
| 6 | Window minimum 1100×720 for guide step | Guide compressed below usable proportions |
