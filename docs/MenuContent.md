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
| Starting up | Dimmed `tv` | `isStartingUp == true` |
| Idle | `tv` | No recordings, no imminent shows |
| Show soon | `clock.badge.fill` (orange) | `nextShowMinutes <= 30` |
| Recording | `record.circle.fill` (red) | `isRecording == true` |

`nextShowMinutes` is an `AppState` computed property: minutes until the nearest active show's `show_next`. The clock badge is driven by this being ≤30.

---

## Top-Level Menu Structure

```
[Header: one line per device — DeviceID  active/slots]
[Status message — secondary color]
Divider
Section "Recording Now"       ← only when shows are recording
  recordingMenu(show) …
Divider
Section "Scheduled"           ← active, non-recording shows sorted by show_next
  scheduledMenu(show) …
Section "Paused"              ← inactive shows
  pausedMenu(show) …
Divider
[Add Show — cascading menu or "Add Show…" button based on mode]
Refresh Guide
Settings…
Divider
Quit hdhr_VCR
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
6. **Channel + type** — `"ch 5.1 · SeriesID(All)"`, `secondaryLabelColor`
7. **Elapsed + remaining** — `"2h 15m elapsed · 45m left"` via `elapsedLabel(since:)` / `remainingLabel(until:)`
8. Divider
9. **Stop Recording** → `state.stopRecording(showId:)` — deactivates show, kills curl PID explicitly, moves to Paused
10. **Watch in VLC** — shown when `config.Watch_in_VLC` and `/Applications/VLC.app` exists
11. **Edit…** — sets `state.editingShowId`, opens `"edit-show"` window

The guide lookup is a **synchronous read from the in-memory cache** (`guideStore.channelEntryIndex`). No network call. If the cache is empty, episode/synopsis items are absent gracefully.

---

## Scheduled Shows — `scheduledMenu(_:)`

Source: `state.activeShows` — sorted by `show_next` ascending.

Menu label: `[stateIcon] [Title]`

State icons: `1️⃣` Single · `📅` DateTime · `📺` SeriesID(Channel) · `🔁` SeriesID(All)

Submenu (in order):
1. **Type + channel** — `"SeriesID(All) · ch 5.1"`, full `labelColor`
2. **Episode info** — guide entry at `show_next` ±5 min:
   ```swift
   let scheduledEntry = guideEntries.first {
       abs($0.startDate.timeIntervalSince(next)) < 5 * 60
   }
   ```
   Shows `episodeInfoLabel(scheduledEntry)` in `labelColor` if found
3. **Timing** — `"In 2h 15m · 60 min"` or `"Started 5m ago · 55m left"`, full `labelColor`
4. **Next SeriesID episode** (SeriesID shows only) — calls `state.nextGuideEpisode(for:)` → `guideStore.nextEpisode(seriesID:channelNum:deviceId:)`. Shows `"ch 5.1 · 8:00 PM"` and episode info, in full `labelColor`
5. **Failure warning** — orange `"⚠️ N failure(s): reason"` if `show_fail_count > 0`
6. Divider
7. **Edit…**, **Deactivate**, **Delete…** (destructive role)

All timing and episode text uses full `labelColor` (not `secondaryLabelColor`) for readability — the dim gray was too low-contrast in the menu.

---

## Paused Shows — `pausedMenu(_:)`

Source: `state.inactiveShows`.

Menu label: `⏸ [Title]`

Submenu: last error reason (if `show_fail_reason` is non-empty), then **Activate**, **Edit…**, **Delete…** (destructive).

---

## Add Show — `addShowMenu` Cascade

Only shown when `addShowMode == .menu` (set in Settings → General → Add Show Method). Otherwise a plain `Button("Add Show…")` opens the wizard.

**Level 1 — Device** (skipped for single-tuner setups):
For a single device, goes straight to channel list. For multiple, wraps each device in an outer `Menu(device.DeviceID)`. In both paths, `state.ensureGuideLoaded(for:)` is called immediately via a `let _ = { ... }()` side-effect — required because SwiftUI `Menu` bodies evaluate eagerly when the menu opens.

**Level 2 — Channels** (`channelMenus(for:)`):
Reads `state.lineups[device.DeviceID]`. Each `LineupEntry` becomes a `Menu("5.1  NBC HD")` with HD badge appended when `lineup.HD == 1`.

**Level 3 — Guide entries** (`channelMenu(device:channel:)`):
Calls `state.guideEntries(deviceId:channelNum:)`. Splits into `onAir` and `upcoming`. On-air listed first with `▶` prefix + Divider + upcoming. If guide is loading: `"Fetching guide…"`. If empty after load: `"No upcoming shows"` + reload button.

**Level 4 — Entry submenu** (`entryMenu(entry:device:channel:isOnAir:)`):
Label: `entryLabel(_:isOnAir:)` → `"▶ 8:00 PM  Jeopardy! (30m)"` or `"8:00 PM  Jeopardy! (30m)"`. Icon: `square.fill` colored by `guideEntryColor(for:onAir:)`.

Submenu:
- Poster `AsyncImage` (120×80) if `entry.ImageURL` is set
- Title `.headline`
- `episodeInfoLabel(entry)` — `"S02E05 · Episode Title"`
- Time range — `"8:00 PM – 9:00 PM"`
- Synopsis up to 3 lines `.caption`
- Divider
- **Record once (Single)** → `addShowFromGuide(entry:type:.single:device:channel:)`
- **Record as series…** submenu:
  - **DateTime** — same weekday + time on this channel
  - **SeriesID — this channel** — any episode of this SeriesID on this channel
  - **SeriesID — all channels** — any episode of this SeriesID anywhere
- **Watch in VLC** (conditional — `config.Watch_in_VLC && isOnAir`)

`addShowFromGuide` on `AppState` stores `show_genre = entry.firstGenre ?? ""` so Bonus Time detection works at recording time without a guide lookup.

---

## Helper Functions

| Function | Purpose |
|---|---|
| `stateIcon(_:)` | Emoji for show type |
| `relativeLabel(_:)` | "2h 15m", "45m", "30s" from a `TimeInterval` |
| `elapsedLabel(since:)` | `relativeLabel(Date().timeIntervalSince(start))` |
| `remainingLabel(until:)` | `relativeLabel(end.timeIntervalSince(Date()))` |
| `entryLabel(_:isOnAir:)` | `"▶ 8:00 PM  Show (30m)"` — parent menu item label |
| `timeRange(_:)` | `"8:00 PM – 9:00 PM"` — inside entry submenu |
| `weekdayName(_:)` | Full weekday name from a `Date` |
| `episodeInfoLabel(_:)` | Joins `EpisodeNumber` + `EpisodeTitle` with ` · `; nil if both empty |
| `editShow(_:)` | Sets `state.editingShowId`, calls `open("edit-show")` |

---

## Dark Mode / Color

All informational text explicitly uses `Color(NSColor.labelColor)` or `Color(NSColor.secondaryLabelColor)` — not SwiftUI's `.primary` / `.secondary`. In `.menu`-style `MenuBarExtra`, SwiftUI's semantic colors are overridden by NSMenu's disabled-item dimming, making text unreadably faint. Explicit NSColor refs are immune to this.

---

## What Still Needs Doing

- **Elapsed timer doesn't tick** — elapsed/remaining times are static (computed when menu opens). NSMenu doesn't refresh automatically; a real-time display would require a window-based popover for recording detail.

- **Stop without confirmation** — "Stop Recording" immediately deactivates the show with no undo. An `NSAlert` ("Stop recording and deactivate [Title]?") would prevent accidental permanent deactivation.

- **Bonus Time indicator in recording menu** — when a sports show is recording past the guide end in Bonus Time, there's no callout like "🏈 Bonus Time" in the menu. The remaining-time counter shows the padded end time, but the user has no visible explanation.

- **Paused shows have no detail** — the paused submenu shows only the last fail reason. Adding the show type, channel, and when it last recorded would help the user decide whether to reactivate or delete.

- **Delete without confirmation in scheduled/paused** — both `scheduledMenu` and `pausedMenu` have Delete buttons with no NSAlert. The `.destructive` role adds a red tint but no confirmation.

- **No "Record Now" shortcut** — there's no direct path to immediately record a show that's currently on air without going through the full Add Show cascade.
