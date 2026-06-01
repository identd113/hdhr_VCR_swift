# TODO

Deferred features and improvements. Add items here when a task is punted. Remove when complete and note the resolving commit in `ISSUES.md` if the work was non-trivial.

---

## Watch Now plays live recording file instead of opening a new tuner

When the VLC player is opened for a show that is currently being recorded on the same device, it opens a fresh HTTP stream to the tuner — consuming a second tuner slot unnecessarily. Instead, VLC should play the partial `.ts` file being written by curl, which is valid as a growing file.

This applies everywhere "Watch Now" / "Watch in App" is offered: `WatchNowView`, `MenuContent` (`entryMenu`, `recordingMenu`), and `FloatingGuideView` / `CableGuideView` summary panels.

**Gating**: New `AppConfig` boolean `Watch_live_file: Bool = true` (Settings → Recording or Playback section). When enabled, opening a show that is actively recording uses the output file path instead of the stream URL. When disabled, always opens a new tuner stream.

**Detection**: Check `state.shows.first(where: { $0.show_recording && $0.show_url == channel.url })` (or match by device + channel number) before calling `VLCBridge.play()`. If matched, substitute `show.show_output_path` (or equivalent) as the URL.

**Edge cases**: File may not exist yet if curl just started (guard with `FileManager.default.fileExists`; fall back to stream URL). Seeking works normally in VLC against a growing file. Stopping the recording while VLC is playing the file will leave VLC at end-of-stream — acceptable.

**Key files**: `AppState.swift` (`watchInApp`, tuner check logic), `WatchNowView.swift`, `MenuContent.swift`, `AppConfig` (new field), `SettingsView.swift` (new toggle).

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
