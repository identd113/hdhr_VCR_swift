# WKWebView Guide — Feasibility Analysis (historical)

**Historical planning doc — superseded.** Written 2026-06-05 as a pre-implementation feasibility analysis; the very next day (`89610a2`, 2026-06-06) the native SwiftUI guide (`CableGuideView.swift`) was removed entirely, `FloatingGuideView.swift` was collapsed to a thin `WKWebView` wrapper (~100 lines), and `AddShowView`'s guide step was also converted to a `WKWebView` (`GuideWebView` in `AddShowView.swift`) — completing what this doc called the "higher risk, optional" Phase 2. `CableGuideView.swift`/`docs/CableGuideView.md`/`docs/CableGuideView_pitfalls.md` no longer exist. Kept for historical context only — see `docs/FloatingGuideView.md` for the current architecture.

---

## Background

The app has two parallel guide implementations:

1. **Native SwiftUI** — CableGuideView + FloatingGuideView + AddShowView guide step (~1,606 lines). Uses AppKit scroll hacks (NSView.boundsDidChangeNotification, NSEvent monitor), GeometryReader nesting constraints, and has 10+ documented failed layout attempts (see `docs/CableGuideView_pitfalls.md`).

2. **Web guide** — WebServer.swift `buildHTML()` at `http://localhost:1980/` (~1,031 lines of inline HTML/CSS/JS). Full feature parity: genre colors, managed flags (yellow/red triangles), bonus time starburst, summary panel with poster/episode/synopsis, Record modal, Edit modal, device switcher, favorites, SSE real-time updates.

The question: replace the native guide with a `WKWebView` embedding the web guide.

---

## Feasibility

**Yes.** `WKWebView` is displayable on macOS via `NSViewRepresentable`. All prerequisites are already met:

- macOS 15.0 deployment target ✓
- `NSAllowsArbitraryLoads = true` in Info.plist ✓
- `NSLocalNetworkUsageDescription` present ✓
- WebKit framework available ✓
- `NSViewRepresentable` pattern already used 6× in codebase ✓

---

## Native Guide Code Being Replaced

| File | Lines | Key Complexity |
|---|---|---|
| CableGuideView.swift | 669 | GeometryReader nesting, NSEvent monitor, NSView boundsDidChange hook, ShowBlocksRow 18-field equatable |
| FloatingGuideView.swift | 368 | Duplicates guide logic, scroll sync, AppKit hooks |
| AddShowView.swift (guide step) | ~500 | Drives CableGuideView with wizard state + scroll sync |
| GuideViewHelpers.swift (guide portions) | ~69 | Shared scroll helpers |
| **Total removable** | **~1,606 lines** | |

---

## Advantages

1. **~1,600 lines of fragile AppKit/SwiftUI hybrid code removed**
2. **Scroll sync hacks eliminated** — VerticalScrollTracker and ChannelScrollForwarder gone
3. **GeometryReader constraints gone** — all 10 documented layout failures cease to exist
4. **Single source of truth** — guide logic in one place (WebServer.swift buildHTML); fixes apply everywhere simultaneously
5. **Web guide already fully tested and shipping** — every feature works today
6. **Record modal already complete** — type/days/transcode/bonus controls exist; no re-implementation needed
7. **FloatingGuideView is the simplest replacement** — browse-only, no wizard integration needed

---

## Disadvantages

1. **Memory is WORSE, not better** — WKWebView spawns a separate WebContent process. Estimated overhead: 80–200 MB. Native lazy SwiftUI rows are cheaper. Memory savings are a false premise.

2. **Web server must auto-start** — `Web_server_enabled` currently defaults to `false`. WKWebView in-app requires the server running at all times (or auto-start on demand). Needs a separate internal-start flag distinct from the user-facing setting.

3. **AddShowView wizard bridge is complex** — The wizard must intercept the Record button to advance to the Details step instead of posting to `/api/record`. Requires `WKScriptMessageHandler`, JS modification (`window.webkit.messageHandlers.record.postMessage(showData)`), and state transfer from JS → Swift.

4. **Folder picker stays native** — macOS sandbox: file system access requires `NSOpenPanel`. AddShowView Details step (step 3) must remain native SwiftUI regardless.

5. **Dark mode mismatch** — Web guide uses a localStorage toggle, not `NSApp.effectiveAppearance`. Needs JS injection on load to sync system appearance.

6. **Loading flash** — WKWebView shows blank before HTML renders. Native views appear instantly.

7. **No offline fallback** — If web server fails to start (port conflict, permissions), guide shows nothing.

8. **Keyboard navigation regression** — WKWebView captures keyboard events differently than native SwiftUI.

---

## Memory Reality

| Scenario | Estimate |
|---|---|
| Native guide open (LazyVStack, lazy rows) | ~20–50 MB additional |
| WKWebView + WebContent process | ~80–200 MB baseline + DOM heap |
| **Net delta** | **+50 to +150 MB worse** |

---

## Recommended Approach: Tiered

### Phase 1 — FloatingGuideView (low risk)
Replace FloatingGuideView with WKWebView loading `http://localhost:1980/`. No wizard integration. Validates the pattern. Risk: LOW — standalone, easy rollback.

**Files**: `FloatingGuideView.swift` (~368 → ~40 lines), `AppState.swift`/`WebServer.swift` (auto-start logic), `docs/FloatingGuideView.md`.

### Phase 2 — AddShowView guide step (higher risk, optional)
Replace step 2 with WKWebView + `WKScriptMessageHandler` bridge. Details step (folder picker) remains native.

**Files**: `AddShowView.swift`, `WebServer.swift` (Record button JS path), `docs/AddShowView.md`.

### Phase 3 — Cleanup (after Phase 2 confirmed stable)
Delete `CableGuideView.swift` (669 lines) and guide portions of `GuideViewHelpers.swift`.

---

## JS→Swift Bridge Sketch (Phase 2)

```swift
let config = WKWebViewConfiguration()
config.userContentController.add(self, name: "record")

// WKScriptMessageHandler
func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    if message.name == "record", let body = message.body as? [String: Any] {
        // parse show data, populate AddShowView @State, advance to step 3
    }
}
```

Web guide JS modification (only when loaded in-app context):
```js
// detect in-app context
if (window.webkit?.messageHandlers?.record) {
    window.webkit.messageHandlers.record.postMessage(showData);
} else {
    fetch('/api/record', { method: 'POST', body: JSON.stringify(showData) });
}
```

---

## Dark Mode Sync

```swift
let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
webView.evaluateJavaScript("localStorage.setItem('theme', '\(isDark ? "dark" : "light")'); applyTheme();")
```

---

## Verification Steps

1. `swift build` — no errors
2. `./deploy.sh`
3. Open FloatingGuideView — guide loads, channels/programs visible, dark mode synced
4. Open guide while web server off — auto-start fires correctly
5. Record modal opens and submits
6. (Phase 2) Add show via wizard — Record click advances to Details, folder picker works
7. `Activity Monitor` → hdhrVCRplus — measure memory before/after
