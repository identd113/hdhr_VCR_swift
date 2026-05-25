# MenuContent.swift — Menu Bar Dropdown

## Intent

`MenuContent` is the entire visible UI of the app while the menu is closed. It is the `body` of the `MenuBarExtra` scene declared with `.menu` style in `hdhr_VCRApp.swift`. Every interaction the user has with the app — starting, stopping, scheduling, editing, and adding shows — flows through here or through a window it opens.

Because this is a menu bar app (`LSUIElement = true`, no Dock icon, no main window), `MenuContent` IS the app's primary interface.

---

## Window Opening

Windows are opened with a dedicated `open(_:)` helper rather than calling `openWindow` directly:

```swift
private func open(_ id: String) {
    DispatchQueue.main.async {
        NSApp.activate(ignoringOtherApps: true)
        // Bring existing window to front instead of opening a duplicate
        if let w = NSApp.windows.first(where: { $0.title == title }) {
            w.makeKeyAndOrderFront(nil); return
        }
        openWindow(id: id)
    }
}
```

The `DispatchQueue.main.async` is essential: `.menu`-style `MenuBarExtra` dismisses the menu synchronously on interaction. Calling `openWindow` before the menu is fully dismissed can cause the window to appear behind the menu or fail silently. The deferred dispatch fires after the menu is gone.

Window IDs → titles: `"add-show"` → "Add Show", `"edit-show"` → "Edit Show", `"settings"` → "Settings"

---

## Menu Bar Icon States

| State | Icon | Condition |
|---|---|---|
| Starting up | Dimmed (30% opacity) custom icon | `isReady == false` |
| Idle | Custom icon | No recordings, no imminent shows |
| Show soon | `clock.badge.fill` (orange) | `nextShowMinutes <= 30` |
| Recording | `record.circle.fill` (red) | `isRecording == true` |

`nextShowMinutes` is an `AppState` computed property: minutes until the nearest active show's `show_next`. The clock badge is driven by this being ≤30.

`isReady` is a computed property on `AppState` that returns `true` once at least one device is found, a lineup is populated, and guide data is loaded. The icon stays at 30% opacity until all three conditions are met — a visual signal that the app isn't yet usable.

---

## Top-Level Menu Structure

```
[Header: one line per device — DeviceID  active/slots]
[Status message — secondary color]
Divider
Section "Recording Now"       ← only when shows are recording
  recordingMenu(show) …
Divider
Section "Next Up"             ← shows within 5 min of the nearest upcoming airing
  [start time] · [duration]  ← small caption above each row
  scheduledMenu(show) …
Section "Scheduled"           ← remaining active, non-recording shows sorted by show_next
  scheduledMenu(show) …
Section "Paused"              ← show_active && show_paused shows
  pausedMenu(show) …
Divider
[Add Show — cascading menu or "Add Show…" button based on mode]
Refresh Guide
Settings…
Divider
Quit hdhrVCRplus
```

### Header

One `Text` line per device: `"105404BE  1/4"` (DeviceID + `active/totalTuners`). Active count is filtered by `hdhr_record == device.DeviceID` across `recordingShows`. Full `labelColor` when that device has active recordings; `secondaryLabelColor` when idle. Below device lines: `state.statusMessage` in secondary color.

---

## Recording Now — `recordingMenu(_:)`

Menu label: `🔴 [Title]`

Submenu contents (in order):
1. **Poster image** — `AsyncImage` of `show.show_logo_url` (120×80, cornerRadius 4) if non-empty
2. **Title** — `.headline`, `labelColor`
3. **Episode info** — synchronous lookup from `state.guideEntries(deviceId: show.hdhr_record, channelNum: show.show_channel)`, finding the entry where `startDate <= now && endDate > now`. Shows `episodeInfoLabel(entry)` (`"S02E05 · The One Where…"`) in `labelColor`
4. **Synopsis** — up to 3 lines from `currentEntry?.Synopsis`, in `labelColor`
5. Divider
6. **Channel + type** — `"Channel 5.1 · SeriesID(All)"`, `secondaryLabelColor`
7. **Elapsed + remaining** — `"2h 15m elapsed · 45m left"` via `elapsedLabel(since:)` / `remainingLabel(until:)`
8. **Tuner signal** — shown when `state.tunerStatus[show.show_id]` is set (polled each idle tick via `fetchTunerStatus`): `"Signal: 78% · lock: qam256 · 12.4 Mbps"`, `secondaryLabelColor`
9. Divider
10. **Stop Recording** → confirms via `NSAlert` ("Stop & Pause" / "Keep Recording"), then `state.stopRecording(showId:)` — pauses show (`show_paused = true`), kills curl PID, moves to Paused section
11. **Skip This Airing** → `state.skipRecording(showId:)` — stops recording, advances schedule to next airing without incrementing fail count
12. **Watch in VLC** — shown when `config.Watch_in_VLC` and `/Applications/VLC.app` exists; button label text uses VLC orange (`Color(red: 1.0, green: 0.482, blue: 0.0)`)
13. **Edit…** — sets `state.editingShowId`, opens `"edit-show"` window

The guide lookup is a **synchronous read from the in-memory cache** (`guideStore.channelEntryIndex`). No network call. If the cache is empty, episode/synopsis items are absent gracefully.

---

## Scheduled Shows — `scheduledMenu(_:)`

Source: `state.activeShows` — sorted by `show_next` ascending.

Menu label: `[stateIcon] [Title]` — prefixed with `⚠️` when a tuner conflict is detected for the show's next airing.

State icons: `1️⃣` Single · `📅` DateTime · `🔂` SeriesID(Channel) · `🔁` SeriesID(All)

Submenu (in order):
1. **Poster image** — `AsyncImage` of `show.show_logo_url` (120×80, cornerRadius 4) if non-empty
2. **Title** — `.headline`, `labelColor`
3. **Type + channel** — `"SeriesID(All) · Channel 5.1"`, full `labelColor`
4. **Synopsis** — from the guide entry at `show_next` ±5 min, `.footnote`, `secondaryLabelColor`
5. Divider
6. **Episode info** — guide entry at `show_next` ±5 min:
   ```swift
   let scheduledEntry = guideEntries.first {
       abs($0.startDate.timeIntervalSince(next)) < 5 * 60
   }
   ```
   Shows `episodeInfoLabel(scheduledEntry)` in `labelColor` if found
7. **Timing** — `"In 2h 15m · 60 min"` or `"Started 5m ago · 55m left"`, full `labelColor`
8. **Next SeriesID episode** (SeriesID shows only) — calls `state.nextGuideEpisode(for:)` → `guideStore.nextEpisode(seriesID:channelNum:deviceId:)`. Shows `"Channel 5.1 · 8:00 PM"` and episode info, in full `labelColor`
9. **Conflict warning** — orange `"⚠️ Conflict: all N tuners busy at this time"` if `state.hasConflict(for: show)` returns true
10. **Failure warning** — orange `"⚠️ N failure(s): reason"` if `show_fail_count > 0`
11. Divider
12. **Edit…**, **Pause** → `state.pauseShow(show)` (sets `show_paused = true`, reason "Manually paused"), **Delete…** (destructive, `NSAlert` confirmation)

All timing and episode text uses full `labelColor` (not `secondaryLabelColor`) for readability — the dim gray was too low-contrast in the menu.

### Next Up section

Shows in `activeShows` whose `show_next` is within 5 minutes of the nearest upcoming airing are promoted to a **"Next Up"** section above "Scheduled". Each row is preceded by a small caption line: `"10:30 PM · 60 min"` (static clock time + recording duration). This avoids a countdown string that would force a redraw every minute. The remaining shows appear in the standard "Scheduled" section below.

---

## Paused Shows — `pausedMenu(_:)`

Source: `state.pausedShows` — shows where `show_active == true && show_paused == true`.

A show enters this state via: fail threshold, manual stop, skip, disk full, missing output file, no air days configured, or manually via the **Pause** button. Shows auto-resume when their scheduled window expires or their next airing is imminent.

Menu label: `⏸ [Title]`

Submenu: show type + channel, pause reason (if `show_fail_reason` is non-empty), next attempt time (if `show_next` is in the future), then **Resume Now** → `state.resumeShow(show)`, **Edit…**, **Delete…** (destructive).

---

## Add Show — `addShowMenu` Cascade

Only shown when `addShowMode == .menu` (set in Settings → General → Add Show Method). Otherwise a plain `Button("Add Show…")` opens the wizard.

The cascade is intentionally **two levels deep only** — device and channel. SwiftUI's `Menu {}` evaluates all nested content eagerly when the parent opens, so adding a third level (guide entries) for ~100 channels caused the entire entry tree to be built on every menu open. The cascade stops at channel level; clicking a channel opens the wizard.

**Level 1 — Device** (skipped for single-tuner setups):
For a single device, goes straight to channel list. For multiple, wraps each device in an outer `Menu(device.DeviceID)`. In both paths, `state.ensureGuideLoaded(for:)` is called immediately via a `let _ = { ... }()` side-effect — required because SwiftUI `Menu` bodies evaluate eagerly when the menu opens.

**Level 2 — Channels** (`channelMenus(for:)` → `channelMenu(device:channel:)`):
Reads `state.lineups[device.DeviceID]`. Only channels with guide data (`menuGuideEntries` non-empty) are shown. Each channel is a flat `Button` (not a submenu) showing:
- Channel logo (16×16) from `channelIconImages` — O(1) dict lookup; falls back to `tv` SF Symbol
- `"5.1  NBC HD"` label with HD badge when `lineup.HD == 1`

Clicking a channel sets `state.pendingAddChannel = (device, channel)`, bumps `pendingAddChannelGeneration`, and opens `"add-show"`. The wizard opens at the guide step with that device and channel pre-selected.

**Channel logo loading**: logos are pre-fetched into `AppState.channelIconImages: [String: NSImage]` during guide load via `prefetchChannelIcons(_:)`. The URL→image dict is populated with a single actor hop after all downloads complete, so menu access is always synchronous. `channelImageURLs: [String: String]` maps `"deviceId:channelNum"` → image URL; both dicts are rebuilt in `rebuildMenuEntries()` after each guide load.

---

## Helper Functions

| Function | Purpose |
|---|---|
| `stateIcon(_:)` | Emoji for show type |
| `relativeLabel(_:)` | "2h 15m", "45m", "30s" from a `TimeInterval` |
| `elapsedLabel(since:)` | `relativeLabel(Date().timeIntervalSince(start))` |
| `remainingLabel(until:)` | `relativeLabel(end.timeIntervalSince(Date()))` |
| `timeRange(_:)` | `"8:00 PM – 9:00 PM"` — inside show submenus |
| `weekdayName(_:)` | Full weekday name from a `Date` |
| `episodeInfoLabel(_:)` | Joins `EpisodeNumber` + `EpisodeTitle` with ` · `; nil if both empty |
| `editShow(_:)` | Sets `state.editingShowId`, calls `open("edit-show")` |

---

## Dark Mode / Color

All informational text explicitly uses `Color(NSColor.labelColor)` or `Color(NSColor.secondaryLabelColor)` — not SwiftUI's `.primary` / `.secondary`. In `.menu`-style `MenuBarExtra`, SwiftUI's semantic colors are overridden by NSMenu's disabled-item dimming, making text unreadably faint. Explicit NSColor refs are immune to this.

---

## What Still Needs Doing

- **Elapsed timer doesn't tick** — elapsed/remaining times are static (computed when menu opens). NSMenu doesn't refresh automatically; a real-time display would require a window-based popover for recording detail.

- **Bonus Time indicator in recording menu** — when a sports show is recording past the guide end in Bonus Time, there's no callout like "🏈 Bonus Time" in the menu. The remaining-time counter shows the padded end time, but the user has no visible explanation.

- **No "Record Now" shortcut** — there's no direct path to immediately record a show that's currently on air without going through the full Add Show cascade.
