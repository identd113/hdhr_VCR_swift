# Failed Approaches

Not an issue tracker — this is a record of things that were tried repeatedly, failed, and eventually either abandoned or solved a different way. Kept separate from `ISSUES.md`/`issues_resolved.md` (which track specific bugs against current code) because these entries are about *technique*, often against code that no longer exists — the lesson is the point, not the bug.

---

## Pinning a scroll-synced header/column over a bidirectional SwiftUI ScrollView (macOS, pre-15)

**Context**: `CableGuideView.swift`, the native cable-guide grid (now fully removed — replaced by the WKWebView-embedded web guide). The grid needed a time-axis header and a channel-label column that both stayed fixed while the grid itself scrolled horizontally and vertically.

**What was tried, in order, and why each failed:**

1. **Time header inside the ScrollView with `LazyVStack(pinnedViews: [.sectionHeaders])`** — works for vertical-only scroll, but the header scrolls away horizontally along with the grid content, since pinning only holds a section header in place along the scroll axis it's pinned for.
2. **Nested ScrollViews with offsets synced via `PreferenceKey` + `GeometryReader`** — the offset `PreferenceKey` doesn't fire during AppKit-driven scroll *momentum*. It updates fine for a slow manual drag, then visibly lags or snaps on momentum release, because SwiftUI's preference propagation only runs on SwiftUI layout passes, not on every AppKit scroll frame.
3. **10 further documented layout permutations** (combinations of the above, plus various offset-clamping and animation-suppression attempts) — all inherited variants of the same root problem: nothing in pure SwiftUI observes AppKit's own scroll-frame cadence.

**What actually worked**: Don't try to keep the header/column inside the scrolling content at all.
- Channel label column: pinned **outside** the `ScrollView` entirely as a fixed left column (`HStack { channelColumnFixed | ScrollView }`).
- Time header: also external, shifted via `.offset(x: -timeHeaderOffset)` to track horizontal scroll position.
- Scroll position itself: captured via `NSViewRepresentable` wrapping the scroll view's `NSClipView`, observing `NSView.boundsDidChangeNotification` directly — this fires on every AppKit scroll frame, including momentum, unlike the SwiftUI `PreferenceKey` path.
- A 1-pt change threshold plus `Transaction.disablesAnimations` around the offset write killed residual jitter.
- Noted at the time: `LazyVStack(pinnedViews:)` inside a bidirectional `ScrollView` only behaves correctly on macOS 15+ — a real deployment-target constraint discovered in the course of this, independent of which approach was used.

**The generalizable lesson** (this is the part worth remembering even though `CableGuideView` itself is gone): if you need to react to AppKit scroll state — position, momentum, velocity — on macOS, go straight to `NSViewRepresentable` + `NSView.boundsDidChangeNotification` (or the equivalent `NSScrollView` notification) rather than trying to make SwiftUI's own layout/preference system track it. SwiftUI's tools only fire on SwiftUI's own layout cadence, which does not include AppKit-driven momentum scrolling. macOS 15's native `onScrollGeometryChange` closes this gap when the deployment target allows it.
