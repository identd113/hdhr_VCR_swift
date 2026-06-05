# TODO

Deferred features and improvements. Add items here when a task is punted. Remove when complete and note the resolving commit in `ISSUES.md` if the work was non-trivial.

---

## Player / Watch Now

### Watch Now plays live recording file instead of opening a new tuner

When the VLC player is opened for a show that is currently being recorded on the same device, it opens a fresh HTTP stream to the tuner — consuming a second tuner slot unnecessarily. Instead, VLC should play the partial `.ts` file being written by curl, which is valid as a growing file.

This applies everywhere "Watch Now" / "Watch in App" is offered: `WatchNowView`, `MenuContent` (`entryMenu`, `recordingMenu`), and `FloatingGuideView` / `CableGuideView` summary panels.

**Gating**: New `AppConfig` boolean `Watch_live_file: Bool = true` (Settings → Recording or Playback section). When enabled, opening a show that is actively recording uses the output file path instead of the stream URL. When disabled, always opens a new tuner stream.

**Detection**: Check `state.shows.first(where: { $0.show_recording && $0.show_url == channel.url })` (or match by device + channel number) before calling `VLCBridge.play()`. If matched, substitute `show.show_output_path` (or equivalent) as the URL.

**Edge cases**: File may not exist yet if curl just started (guard with `FileManager.default.fileExists`; fall back to stream URL). Seeking works normally in VLC against a growing file. Stopping the recording while VLC is playing the file will leave VLC at end-of-stream — acceptable.

**Key files**: `AppState.swift` (`watchInApp`, tuner check logic), `WatchNowView.swift`, `MenuContent.swift`, `AppConfig` (new field), `SettingsView.swift` (new toggle).

---

### Elapsed/remaining timer in recording menu doesn't tick

Times shown in `recordingMenu` / `scheduledMenu` are computed when the menu opens and stay static for the duration it's open. NSMenu doesn't auto-refresh its view hierarchy. A real-time display would require redesigning recording detail as a window-based popover.

---

### No "Record Now" shortcut

No direct path to immediately record an in-progress show without going through Watch Now or the Add Show wizard. A quick-action from `MenuContent` or `WatchNowView` would skip the wizard for shows currently on air.

---

## Recording

### No retry backoff for failed shows

Failed shows go straight to Paused after N consecutive failures with no grace period. A short wait (e.g. 5 minutes) before retrying the next eligible airing would handle transient network blips without deactivating the show.

**Key files**: `AppState.swift` (idle loop / failure handling), `AppConfig` (optional backoff duration field).

---

### DeviceAuth via UDP tag 0x2B

`HDHRManager.udpDiscoverSync()` reads only tag `0x02` (DeviceID) from the UDP discovery reply. The EXTEND device also includes DeviceAuth in tag `0x2B`. Parsing it would populate `HDHRDevice.DeviceAuth` from UDP so the guide API works when the device's HTTP server is sleeping or unreachable.

Confirmed DeviceAuth from live UDP packet on device `105404BE`; guide URL with that token returns 106 channels.

**Key file**: `HDHRManager.swift` → `udpDiscoverSync()`.

---

## Add Show / Edit Show

### No time offset picker for DateTime shows

Air time is locked to the guide entry's start time. Users who want to record a few minutes early have no control in the wizard.

---

### `show_genre` not exposed in Edit Show

The genre field (used for Bonus Time detection) is set from the guide on add but can't be corrected in Edit. Shows added before Bonus Time can't get a genre retroactively without delete + re-add.

---

### SeriesID is read-only in Edit Show

Can't update `show_seriesid` if SiliconDust changes a series' ID (which happens occasionally). Only fix today is delete + re-add.

---

## Settings

### No per-show fail threshold or bonus duration

`Fail_count_setting` and `Sports_padding_minutes` are global-only. Per-show overrides would be useful for shows that regularly run long or need different failure tolerance.

---

### No export / import config

Power users managing multiple machines must copy the JSON manually. Export / Import buttons in the Advanced settings section would simplify this.

---

## UI / Guide

### Replace native cable guide with WKWebView

Embed the existing web guide (`http://localhost:1980/`) in a `WKWebView` instead of maintaining the native SwiftUI cable grid. See full analysis in [`docs/WKWebView_guide_analysis.md`](docs/WKWebView_guide_analysis.md).

**Summary**: Removes ~1,600 lines of fragile AppKit/SwiftUI scroll-sync code. Memory impact is slightly negative (WKWebView WebContent process overhead). Recommended in two phases — FloatingGuideView first (low risk), AddShowView guide step second (needs `WKScriptMessageHandler` bridge).

---

### Colored guide entry rows in .menu add-show cascade

Color the background of each guide entry row in the `.menu` mode add-show cascade (channel submenu → entry list) with the genre color, matching the cable guide grid.

**Implementation notes**: SwiftUI `Menu {}` maps to native `NSMenuItem`; `.background()` modifiers are ignored at row level. Requires AppKit interop:
1. Create a `ColoredMenuItemView: NSView` subclass that draws genre color at low opacity; check `enclosingMenuItem?.isHighlighted` in `draw(_:)` to show `NSColor.selectedMenuItemColor` on hover.
2. Build entries imperatively and assign `.view = ColoredMenuItemView(...)` on each `NSMenuItem`.
3. `NSMenu` calls `setNeedsDisplay()` on highlight state changes — checking `isHighlighted` in `draw` is sufficient, no KVO needed.

**Key file**: `MenuContent.swift` → `entryMenu()` (~line 250); `entryColor` already computed via `guideEntryColor(for:onAir:)`.

---

## Code Quality

### Remove unused `_release` symbol from VLCBridge

`_release` (`libvlc_release`) is loaded via `dlsym` in `VLCBridge.init()` but never called. The VLC instance lives for the app's entire lifetime so releasing it is never needed. Remove the stored property, typedef, and `sym()` lookup.

**Key file**: `VLCBridge.swift`.
