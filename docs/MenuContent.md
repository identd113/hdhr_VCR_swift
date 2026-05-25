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
[Add Show — cascading menu or "Add Show…" button based on mode]
Divider
Settings…
Divider
Section "Recording Now"              ← only when shows are recording (single tuner)
Section "Recording · DeviceID"       ← per device when multiple tuners present
  recordingMenu(show) …
Divider
Section "Up Next"                    ← shows starting within the next hour (single tuner)
Section "Up Next · DeviceID"         ← per device when multiple tuners present
  [secondary text: "8:00 PM"]        ← time label — no divider, groups shows by slot
  scheduledMenu(show, showChannel:true) …   ← "ch 5.1" appended to label
Divider
Section "Scheduled"                  ← remaining active shows (single tuner)
Section "Scheduled · DeviceID"       ← per device when multiple tuners
  scheduledMenu(show) …
Section "Paused"                     ← show_active && show_paused (single tuner)
Section "Paused · DeviceID"          ← per device when multiple tuners
  pausedMenu(show) …
Divider
Quit hdhrVCRplus
```

**Multi-tuner section separation**: all four show sections (Recording, Up Next, Scheduled, Paused) split into per-device sub-sections when `state.devices.count > 1`. Each sub-section is labeled `"SectionName · DeviceID"`. When only one tuner is present the device suffix is omitted.

### Header

One `Text` line per device: `"105404BE  1/4"` (DeviceID + `active/totalTuners`). Active count is filtered by `hdhr_record == device.DeviceID` across `recordingShows`. Full `labelColor` when that device has active recordings; `secondaryLabelColor` when idle. Below device lines: `state.statusMessage` in secondary color.

---

## Recording Now — `recordingMenu(_:)`

Menu label: `🔴 [Title]` (or `🔴 [Title] · S02E05` when guide entry is found for the airing)

Submenu contents — uses `showInfoHeader(show, entry:)` for the top block, then:
1. **Type + channel** — `"SeriesID(All) · Channel 5.1"`, full `labelColor`
2. **Start time + duration** — `"8:00 PM · 60 min"`, `secondaryLabelColor`
3. **Bonus Time callout** — `"🏈 Bonus Time (+N min)"` when a sports show records past guide end
4. **Tuner ID** — `"tuner 105404BE"`, `secondaryLabelColor`
5. **Signal** — shown when `state.tunerStatus[show.show_id]` is set: `"Signal: 78% · lock: qam256 · 12.4 Mbps"`, `secondaryLabelColor`
6. Divider
7. **Skip** (destructive) — `state.skipRecording(showId:)`: stops recording, advances schedule to next airing, no fail-count increment
8. **Delete…** (destructive) — `state.confirmAndDeleteShow(show)`: stops recording + shows confirmation alert with poster image, then removes the show entirely
9. **Show Recording in Finder** — shown when `show_recording_path` is non-empty
10. **Watch in VLC** / **Watch Now!** — conditional on VLC availability (same as scheduled)
11. **Edit…**

---

## `showInfoHeader(_:entry:)` — Shared Poster Panel

Used by `recordingMenu`, `scheduledMenu`, and `pausedMenu`. Renders:

1. **Poster** — `AsyncImage` of `show.show_logo_url` (460×258, cornerRadius 6) with a gray placeholder when absent. Always carries a yellow 24pt right-angle triangle overlay in the top-right corner (`Path`, `.fill(.yellow)`) — all shows in these sections are already managed, so the flag is always visible. Accessibility label: `"\(show.show_title) poster"` on the image; `"Already scheduled"` on the triangle.
2. **Title** — `menuInfo(show.show_title, font: .title3, maxWidth: 460)`
3. **Episode info** — `episodeInfoLabel(entry)` if the entry is non-nil
4. **Synopsis** — `entry.Synopsis` truncated to 160 chars

---

## Scheduled Shows — `scheduledMenu(_:showChannel:)`

Source: `state.activeShows` — sorted by `show_next` ascending.

`showChannel: Bool = false` — when `true` (used in Up Next), `"  ch 5.1"` is appended to the menu label so the channel is visible without opening the submenu.

Menu label: `[stateIcon] [Title]` (+ optional `  ch 5.1`) — prefixed with `⚠️` when a tuner conflict is detected.

State icons: `1️⃣` Single · `📅` DateTime · `🔂` SeriesID(Channel) · `🔁` SeriesID(All)

Submenu — uses `showInfoHeader(show, entry:)` for the top block, then:
1. **Type + channel** — `"SeriesID(All) · Channel 5.1"`, full `labelColor`
2. **Conflict warning** — `"⚠️ Conflict — all tuners busy at this time"`, `secondaryLabelColor`
3. **Start time + duration** — `"8:00 PM · 60 min"` (absolute start time · recording length), `secondaryLabelColor`
4. **Upcoming slots** — for DateTime: next 3 weekday occurrences; for SeriesID: from `state.menuUpcomingSlots[show.show_id]`. Each slot: `"Channel 5.1 · Thu 8:00 PM"` or `"Channel 5.1 · 8:00 PM"` (omits weekday when today). Preceded by "Upcoming" header when count > 1.
5. **Failure warning** — `"⚠️ N failure(s): reason"` when `show_fail_count > 0`
6. Divider
7. **Edit…**, **Pause**, **Delete…** (destructive — uses `confirmAndDeleteShow`)

### Up Next section

Shows in `activeShows` whose `show_next` falls within the **next 60 minutes** appear in the **"Up Next"** section above "Scheduled". Shows are bucketed by start time (rounded to the minute) and grouped under a secondary `menuInfo` time label (e.g. `"8:00 PM"`) — plain text, no divider, so it sits flush under the section header. Each show in Up Next has `showChannel: true` so the channel is visible in the row label. Shows in Up Next are excluded from the Scheduled section.

**Why `menuInfo` not `Section` for time groups**: `Section` adds its own separator divider above its label. Using a nested `Section` for each time slot caused a double-divider gap between `"Up Next"` and the first time label. `menuInfo` renders as a plain non-interactive label item with no preceding divider.

---

## Paused Shows — `pausedMenu(_:)`

Source: `state.pausedShows` — shows where `show_active == true && show_paused == true`.

A show enters this state via: fail threshold, manual stop, skip, disk full, missing output file, no air days configured, or manually via the **Pause** button. Shows auto-resume when their scheduled window expires or their next airing is imminent.

Menu label: `⏸ [Title]`

Submenu — uses `showInfoHeader(show, entry:)`, then: show type + channel, pause reason (if `show_fail_reason` non-empty), next attempt time (if `show_next` is future), then **Resume Now** → `state.resumeShow(show)`, **Edit…**, **Delete…** (destructive — uses `confirmAndDeleteShow`).

---

## Add Show — `addShowMenu` Cascade

Only shown when `addShowMode == .menu` (set in Settings → General → Add Show Method). Otherwise a plain `Button("Add Show…")` opens the wizard.

The cascade is intentionally **two levels deep only** — device and channel. SwiftUI's `Menu {}` evaluates all nested content eagerly when the parent opens, so adding a third level (guide entries) for ~100 channels caused the entire entry tree to be built on every menu open. The cascade stops at channel level; clicking a channel opens the wizard.

**Level 1 — Device** (skipped for single-tuner setups):
For a single device, goes straight to channel list. For multiple, wraps each device in an outer `Menu(device.DeviceID)`. In both paths, `state.ensureGuideLoaded(for:)` is called immediately via a `let _ = { ... }()` side-effect — required because SwiftUI `Menu` bodies evaluate eagerly when the menu opens.

**Level 2 — Channels** (`channelMenus(for:)` → `channelMenu(device:channel:)`):
Reads `state.lineups[device.DeviceID]`. Channels are sorted favorites-first (`isFavorite` desc), then by numeric channel number (`channelSortKey`). Only channels with guide data (`menuGuideEntries` non-empty) are shown. Favorites appear under a `"★  FAVORITES"` italic text header; others follow after a `Divider`. Each channel is a `Menu` (submenu) showing:
- Channel logo (16×16) from `channelIconImages` — O(1) dict lookup; falls back to `tv` SF Symbol; `.accessibilityHidden(true)`
- `"5.1  NBC HD ★"` label — HD badge when `lineup.HD == 1`, star suffix when `isFavorite`

**Guide entries within a channel** (`entryMenu(entry:device:channel:isOnAir:)`):
Each entry is a `Menu` with a color accent bar (genre color). When the entry matches a managed show (`managedShow(for:)` lookup by SeriesID then title), the menu label uses a `Label` with `Self.managedFlagImage` (14×14 yellow AppKit triangle) as the icon, and the submenu shows **Skip** / **Edit…** / **Delete…** instead of **Record…**. Unmanaged entries show a **Record…** button that opens the wizard pre-filled.

**`managedFlagImage`** is a `static let NSImage` drawn via `NSBezierPath` + `NSColor.systemYellow` — right-angle at top-left, vertex at bottom-left. `Path`/`Canvas` do not render in NSMenu item labels; only `NSImage` and SF Symbols work reliably.

**Channel logo loading**: logos are pre-fetched into `AppState.channelIconImages: [String: NSImage]` during guide load via `prefetchChannelIcons(_:)`. The URL→image dict is populated with a single actor hop after all downloads complete, so menu access is always synchronous. `channelImageURLs: [String: String]` maps `"deviceId:channelNum"` → image URL; both dicts are rebuilt in `rebuildMenuEntries()` after each guide load.

---

## Helper Functions

| Function | Purpose |
|---|---|
| `showInfoHeader(_:entry:)` | Shared poster + title + episode + synopsis block; always shows yellow flag triangle |
| `managedShow(for:)` | Looks up an existing `Show` for a guide entry by SeriesID then title |
| `stateIcon(_:)` | Emoji for show type |
| `relativeLabel(_:)` | "2h 15m", "45m", "30s" from a `TimeInterval` |
| `elapsedLabel(since:)` | `relativeLabel(Date().timeIntervalSince(start))` |
| `remainingLabel(until:)` | `relativeLabel(end.timeIntervalSince(Date()))` |
| `upcomingLabel(channel:date:)` | `"Channel 5.1 · Thu 8:00 PM"` / `"Channel 5.1 · 8:00 PM"` for today |
| `nextDateTimeOccurrences(for:count:)` | Next N weekday+time slots for a DateTime show (local calendar) |
| `timeRange(_:)` | `"8:00 PM – 9:00 PM"` — inside entry submenus |
| `weekdayName(_:)` | Full weekday name from a `Date` |
| `episodeInfoLabel(_:)` | Joins `EpisodeNumber` + `EpisodeTitle` with ` · `; nil if both empty |
| `truncateSynopsis(_:limit:)` | Clips to 160 chars at a word boundary |
| `entryLabel(_:isOnAir:)` | `"▶ 8:00 PM  Title"` (on air) or `"8:00 PM  Title"` |
| `editShow(_:)` | Sets `state.editingShowId`, calls `open("edit-show")` |

## `confirmAndDeleteShow` (AppState)

All delete actions in menus and `EditShowView` call `AppState.confirmAndDeleteShow(_ show:, then completion:)`. It:
1. Looks up the show's poster URL from the guide cache (`nextGuideEpisode` for series, title match for singles)
2. Fetches the image async via `URLSession`
3. Shows an `NSAlert` with `alert.icon = image`, "Delete / Cancel" buttons
4. Calls `deleteShow(show)` (which also calls `recordingManager.stop`) + `completion()` on confirm

`EditShowView` passes `{ dismiss() }` as the completion so the window closes after deletion. Menu callers pass `{}` (default).

---

## Dark Mode / Color

All informational text explicitly uses `Color(NSColor.labelColor)` or `Color(NSColor.secondaryLabelColor)` — not SwiftUI's `.primary` / `.secondary`. In `.menu`-style `MenuBarExtra`, SwiftUI's semantic colors are overridden by NSMenu's disabled-item dimming, making text unreadably faint. Explicit NSColor refs are immune to this.

---

## What Still Needs Doing

- **Elapsed timer doesn't tick** — elapsed/remaining times are static (computed when menu opens). NSMenu doesn't refresh automatically; a real-time display would require a window-based popover for recording detail.

- **Bonus Time indicator in recording menu** — when a sports show is recording past the guide end in Bonus Time, there's no callout like "🏈 Bonus Time" in the menu. The remaining-time counter shows the padded end time, but the user has no visible explanation.

- **No "Record Now" shortcut** — there's no direct path to immediately record a show that's currently on air without going through the full Add Show cascade.
