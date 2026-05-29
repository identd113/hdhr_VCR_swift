# Issue Log

Historical record of bugs and back-and-forth problems encountered during development. Used as a "don't repeat this" reference during code reviews. Unrelated bugs found during work should be added here rather than fixed inline.

**Format**: each issue has a status (`RESOLVED` / `OPEN`), a brief description, what was tried, what worked, and the resolving commit if known.

---

## RESOLVED — Cable guide layout: pinned time header + channel column scroll sync

**Symptom**: Time header and channel label column needed to stay fixed while the guide grid scrolled both horizontally and vertically. Multiple layout attempts (10 documented in `docs/CableGuideView_pitfalls.md`) failed with various combinations of nested ScrollViews, sticky headers via `LazyVStack(pinnedViews:)`, and GeometryReader overlays.

**What failed**: Putting the time header inside the ScrollView with `LazyVStack(pinnedViews: [.sectionHeaders])` — works for vertical-only scroll but the header scrolls away horizontally. Nested ScrollViews with synced offsets via `PreferenceKey + GeometryReader` — offset notifications don't fire during AppKit-driven scroll momentum, causing the header to lag or jump.

**Resolution**: Channel label column is pinned outside the ScrollView entirely (fixed left column, `HStack { channelColumnFixed | ScrollView }`). Time header is also external, shifted via `.offset(x: -timeHeaderOffset)` to track horizontal scroll position. Scroll offset captured using `NSViewRepresentable + boundsDidChangeNotification` (AppKit scroll notification fires reliably; SwiftUI PreferenceKey does not during AppKit-driven scroll). A 1-pt threshold + `Transaction.disablesAnimations` prevent jitter. `LazyVStack(pinnedViews:)` inside a bidirectional ScrollView works correctly only on macOS 15+ — do not lower the deployment target.

**Resolving commit**: `a2189f6` (approximate; layout stabilized across several commits)

---

## RESOLVED — Menu glitch feedback loop on guide load failure

**Symptom**: When a device's guide API returned 403 (e.g., the FFFF0001 test EXTEND device), the menu became completely unresponsive, firing HTTP requests at ~35ms intervals and locking the UI.

**Root cause**: `ensureGuideLoaded` was called inline in the SwiftUI menu `@ViewBuilder`. A failed load that assigned `guideByDevice = []` (even empty) triggered `didSet → rebuildMenuEntries → 3 @Published changes → SwiftUI re-eval → ensureGuideLoaded → HTTP request → failure → assign → didSet → ...` in a tight loop.

**What failed**: Guarding on `menuIsOpen` in `didSet` — guide loads are infrequent and must always populate `menuGuideEntries` even if the menu is open, so this guard was too broad. Adding `NSMenuDelegate` + lazy `menuNeedsUpdate` — rejected as too architecturally complex for the problem.

**Resolution**: `ensureGuideLoaded` only assigns `guideByDevice` when `guideStore.channels(deviceId:)` is non-empty after the load (empty result = no assignment = no re-eval trigger). Added `guideLoadFailTimes: [String: Date]` for 5-minute backoff on failed devices so repeated failures don't hammer the API. The `guideByDevice.didSet` is intentionally not guarded by `menuIsOpen`.

**Resolving commit**: `52c5107` (approximate)

---

## RESOLVED — AVPlayer does not support MPEG-2 transport streams

**Symptom**: The in-app player (using AVKit/AVPlayer) silently failed to play HDHomeRun streams. No error was shown; the player just displayed a black frame.

**Root cause**: AVPlayer on macOS does not support MPEG-2 transport streams, which is the native format from HDHomeRun tuners without transcoding. Forcing `transcode=heavy` as a workaround degraded quality and still failed for some streams.

**What failed**: Forcing transcoding on all streams — quality loss, still unreliable. Custom `AVAssetResourceLoaderDelegate` to pre-buffer — too complex, same underlying codec limitation.

**Resolution**: Replaced AVKit player entirely with VLC via `VLCBridge` (dlopen runtime loader for `libvlc.dylib`). VLC handles MPEG-2 natively so no forced transcoding is needed. The old `PlayerView.swift` is superseded by `VLCPlayerView.swift`. See `docs/VLCBridge.md` and `docs/VLCPlayerView.md`.

**Resolving commit**: in-app player VLC adoption (see git log for VLCBridge introduction)

---

## RESOLVED — TCC permission reset on app re-signing during deploy

**Symptom**: After running `deploy.sh`, the app lost Notification Center permission and folder-access entitlements. Users had to re-grant permissions after every deploy.

**Root cause**: Ad-hoc code signing (`codesign --force`) changes the code signature, which macOS treats as a new app identity — TCC (Transparency, Consent, and Control) ties permissions to the signature.

**Resolution**: Moved the config file from `~/Documents/hdhr_VCR-{hostname}.json` to `~/Library/Application Support/hdhrVCRplus/hdhr_VCR-{hostname}.json`. `ConfigManager` auto-migrates on first launch. This scopes the app's folder access to its own support directory (always granted without a prompt) instead of `~/Documents`. The old file is left in place so the AppleScript app can still read it. Added `setbuf(stdout, nil)` for reliable log flushing after the process model changed.

**Resolving commit**: config migration commit (see git log for `ConfigManager` path change)

---

## RESOLVED — Scroll sync offset not firing during momentum scroll

**Symptom**: The pinned time header in `CableGuideView` lagged or snapped during fast/momentum horizontal scrolling — the SwiftUI offset tracking fell behind AppKit's scroll physics.

**Root cause**: `PreferenceKey + GeometryReader` inside a SwiftUI ScrollView reports geometry changes only during SwiftUI layout passes, not during AppKit-driven scroll momentum frames. The offset appeared to update correctly for slow drags but jumped on momentum release.

**Resolution**: Replaced with `NSViewRepresentable` wrapping the scroll view's `NSClipView`, observing `NSView.boundsDidChangeNotification`. This fires on every AppKit scroll frame including momentum. The CompatibilityHelpers extension uses `onScrollGeometryChange` natively on macOS 15+ and falls back to this AppKit approach on macOS 14.

**Resolving commit**: cable guide scroll sync stabilization (see git log)

---

*Add new issues below this line.*
