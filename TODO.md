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

## HDHomeRun Record Engine routing for seamless channel switching

The in-app VLC player currently streams directly from the device (port 5004). On channel change, the old TCP connection closes and a new one opens — the tuner must fully release before the next one can start, producing a 1–3 second blank gap.

The HDHomeRun Record Engine (SiliconDust DVR daemon, port 4999) supports `ClientID` (UUID, per-player-instance) and `SessionID` (random hex32, regenerated per channel request). Routing through it instead of port 5004 allows the engine to pre-allocate the new tuner before releasing the old one, eliminating the gap. The stream URL becomes:

```
http://<record-engine-ip>:4999/auto/v<channel>?ClientID=<UUID>&SessionID=<hex32>
```

Same `ClientID` across the session; new `SessionID` on each channel change. Seeking reuses the same `ClientID`+`SessionID` with a `Range:` header.

**Prerequisites**: User must be running the HDHomeRun DVR software (ships with the "HDHomeRun" macOS app). The record engine IP is discoverable via `/discover.json` or mDNS. Should fall back to direct port 5004 if no record engine is found.

**Key files**: `VLCBridge.swift` (`play(url:)`), `VLCPlayerView.swift` (`playChannel(_:)`), `AppState.swift` (device discovery), `AppConfig` (new field for ClientID persistence).

---

## Parse X-HDHomeRun-Error response header from curl recordings

The device returns an `X-HDHomeRun-Error` HTTP response header when a recording stream fails at the device level. Currently, curl exits with a non-zero code and the app logs "curl exited unexpectedly" with no further detail. Parsing this header would give precise `show_fail_reason` values.

**Error codes** (from HDHomeRun HTTP API docs):
- 804 — Tuner In Use
- 805 — All Tuners In Use
- 806 — Tune Failed
- 807 — No Video Data
- 808 — DVR Failure
- 809 — Playback Connection Limit
- 810 — DVR Full
- 811 — Content Protection Required

**Implementation**: Pass `-D -` (dump headers to stdout) or `-i` to curl and parse the `X-HDHomeRun-Error:` line before the body. Or use a separate `curl -I` (HEAD) preflight to check availability before starting the recording stream.

**Key files**: `RecordingManager.swift` (curl invocation), `AppState.swift` (`checkRecordingHealth` / start logic).

---

## Capture X-HDHomeRun-Resource response header to identify allocated tuner

The device returns `X-HDHomeRun-Resource: tunerN` in the HTTP response headers when a stream starts (confirmed on port 5004). The app currently identifies which tuner a recording is using by polling `/status.json` and matching by channel number — fragile when two shows share a channel or the match is ambiguous.

Capturing this header at stream start gives an exact tuner identity with no polling. Pass `-D -` (dump headers to stdout mixed with body) or use a separate `curl -I` HEAD request to read it before the body stream begins. Store as `show_tuner_resource` on `Show` (e.g. `"tuner1"`); use it to target `/tunerN/vstatus` directly instead of searching by channel.

**Key files**: `RecordingManager.swift`, `Models.swift` (`Show` struct), `AppState.swift` (vstatus polling ~line 1634).

---

## Colored guide entry rows in .menu add-show cascade

Color the background of each guide entry row in the `.menu` mode add-show cascade (channel submenu → entry list) with the genre color, matching the cable guide grid.

**Implementation notes**: SwiftUI `Menu {}` maps to native `NSMenuItem`; `.background()` modifiers are ignored at row level. Requires AppKit interop:
1. Create a `ColoredMenuItemView: NSView` subclass that draws genre color at low opacity as background, checks `enclosingMenuItem?.isHighlighted` in `draw(_:)` to show `NSColor.selectedMenuItemColor` on hover.
2. Build entries imperatively and assign `.view = ColoredMenuItemView(...)` on each `NSMenuItem`.
3. `NSMenu` calls `setNeedsDisplay()` on the custom view when highlight state changes — checking `isHighlighted` in `draw` is sufficient, no KVO needed.

**Key file**: `Sources/hdhr_VCR/Views/MenuContent.swift` → `entryMenu()` (~line 250); `entryColor` already computed via `guideEntryColor(for:onAir:)`.
