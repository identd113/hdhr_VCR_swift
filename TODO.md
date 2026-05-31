# TODO

Deferred features and improvements. Add items here when a task is punted. Remove when complete and note the resolving commit in `ISSUES.md` if the work was non-trivial.

---

## Native Markdown renderer in Settings → About

Settings → About uses a custom `renderChangelog()` `@ViewBuilder` in `SettingsView.swift` that manually parses `## `, `- `, and `**bold**` from CHANGELOG.md. Headers render as `.caption.bold()` rather than real heading font sizes.

**Proposed fix**: Replace with `NSAttributedString(markdown:options:)` (macOS 12+, unconditionally available since floor is 15) wrapped in an `NSViewRepresentable` `NSTextView`. Gives full block-level rendering: proper heading sizes, real bullet lists, inline code, dividers.

**Implementation notes**: `NSTextView` doesn't self-size in SwiftUI — need to compute content height after layout and inject as `.frame(height:)` (override `intrinsicContentSize` on a subclass, or use a `@Binding var height: CGFloat` updated after `sizeToFit()`).

---

## FloatingGuideView: summaryPanel isManaged uses O(n) search instead of Set lookup

`summaryPanel` is a separate `@ViewBuilder private var` and can't access the `managedSeriesIDs`/`managedTitles`/`managedDTSingleSlotKeys` Sets built in `body`. Lines 185-200 re-derive them via `contains(where:)` on `state.shows` on every render. Fix: promote the three sets to `private var` computed properties on `FloatingGuideView` so both `body` and `summaryPanel` use O(1) Set lookups from the same source.

**Key file**: `Sources/hdhr_VCR/Views/FloatingGuideView.swift` lines 42-49 (body) and 185-200 (summaryPanel).

---

## Colored guide entry rows in .menu add-show cascade

Color the background of each guide entry row in the `.menu` mode add-show cascade (channel submenu → entry list) with the genre color, matching the cable guide grid.

**Implementation notes**: SwiftUI `Menu {}` maps to native `NSMenuItem`; `.background()` modifiers are ignored at row level. Requires AppKit interop:
1. Create a `ColoredMenuItemView: NSView` subclass that draws genre color at low opacity as background, checks `enclosingMenuItem?.isHighlighted` in `draw(_:)` to show `NSColor.selectedMenuItemColor` on hover.
2. Build entries imperatively and assign `.view = ColoredMenuItemView(...)` on each `NSMenuItem`.
3. `NSMenu` calls `setNeedsDisplay()` on the custom view when highlight state changes — checking `isHighlighted` in `draw` is sufficient, no KVO needed.

**Key file**: `Sources/hdhr_VCR/Views/MenuContent.swift` → `entryMenu()` (~line 250); `entryColor` already computed via `guideEntryColor(for:onAir:)`.
