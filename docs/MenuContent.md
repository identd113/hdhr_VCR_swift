# MenuContent.swift — Menu Bar Dropdown

## Visual Appearance

### Menu bar icon
A small custom TV icon sits in the macOS menu bar. It changes state based on app activity:
- **Starting up** — icon rendered at 30% opacity (dimmed), indicating the app is not yet ready
- **Idle** — full-opacity TV icon, black in light mode / white in dark mode
- **Show starting soon** — replaced with an orange `clock.badge.fill` SF Symbol when any show starts within 30 minutes
- **Recording** — replaced with a red `record.circle.fill` SF Symbol when any show is actively recording

### Dropdown menu
Clicking the icon opens a native macOS cascading menu (NSMenu style). The menu has no custom background — it uses the system's standard menu appearance (dark translucent on macOS). Items are full-width, standard menu item height (~22pt). Interactive items highlight in system accent color on hover.

**Header rows** (non-interactive, at the top):
- One row per detected HDHomeRun device: `"105404BE  1/4"` — DeviceID left-aligned, live-active/total-tuners. Live count comes from polling `status.json` each idle tick (`deviceTunerOccupancy`); falls back to the app's own recording count before the first poll. The "app expects N" count includes both active recordings **and** the VLC player if it is open on that device — recording one show while watching counts as 2. Color: `systemOrange` when the device has lineup/guide warnings; full `labelColor` when recording (no warnings); `secondaryLabelColor` when idle and healthy. If the live count differs from the app's expected count, appends `"  ⚠ app expects N"`. After startup, missing lineup or guide data appends `"  ⚠ no lineup"` or `"  ⚠ no guide"` (or both, comma-separated) to the same line.
- Status message row: `"16 show(s) — 1 tuner(s) ready"` — the tuner count uses `availableDeviceCount`, which excludes any device that has an empty lineup or empty guide data.

Immediately below the header: **Watch Now** button (when devices present), **Add Show…** button, then **Settings…**, then a divider.

**Watching** section (only visible when VLC player is open, appears directly above Recording Now):
- Section header: `"Watching"` (single device) or `"Watching · 105404BE"` (shows which device's tuner is in use)
- One button: `"Ch 5.1  NBC · Show Title"` with a `play.tv.fill` icon in blue; clicking it focuses the VLC player window

**Recording Now** section (only visible when recording):
- Section header: `"Recording Now"` (single tuner) or `"Recording · 105404BE"` (per device, multiple tuners) — macOS section label style, uppercase gray small text with separator
- Each recording: `"🔴 Show Title"` menu item, right-arrow indicates submenu

**Up Next** section (only visible when shows start within 60 min):
- Same section header pattern: `"Up Next"` or `"Up Next · 105404BE"`
- Within the section: shows bucketed by start time, each time slot rendered as a `Section` header (`"8:00 PM"`) with its shows below; show items have `"  ch 5.1"` appended to the title

**Scheduled** section: `"Scheduled"` or `"Scheduled · DeviceID"` header, shows listed with state icon prefix

**Paused** section: `"Paused"` or `"Paused · DeviceID"` header, shows prefixed with `⏸`

A divider separates show sections from the **Quit hdhrVCRplus** destructive button at the bottom.

### Show submenu appearance (recording, scheduled, paused)
Opening a show's submenu reveals a rich detail panel:

1. **Poster image** — 460pt wide, 258pt tall, cornerRadius 6, fills the menu width. If no poster URL: a gray rounded rectangle placeholder fills the same space.
2. **Title** — `.title3` size, `labelColor`
3. **Episode info** — `.callout` size, if present
4. **Synopsis** — up to 160 chars, `.callout` size, `labelColor`

Below the poster block, secondary metadata in `.footnote` / `.caption` size using `labelColor` or `secondaryLabelColor`:
- Type and channel: `"SeriesID(All) · Channel 5.1"`
- Start time and duration: `"8:00 PM · 60 min"` (secondary color)
- Tuner: `"tuner 105404BE"` (secondary color)
- Conflict, failure, or bonus time warnings in secondary color

Action buttons at the bottom of the submenu (standard blue text, destructive items in red).

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
        let title: String
        switch id {
        case "add-show":  title = "Add Show"
        case "edit-show": title = "Edit Show"
        case "settings":  title = "Settings"
        case "watch-now": title = "Watch Now"
        default:          title = id   // cable-guide: not in map, always opens via openWindow
        }
        if let w = NSApp.windows.first(where: { $0.title == title }) {
            w.makeKeyAndOrderFront(nil); return
        }
        openWindow(id: id)
    }
}
```

The `DispatchQueue.main.async` is essential: `.menu`-style `MenuBarExtra` dismisses the menu synchronously on interaction. Calling `openWindow` before the menu is fully dismissed can cause the window to appear behind the menu or fail silently. The deferred dispatch fires after the menu is gone.

Window IDs → titles: `"add-show"` → "Add Show", `"edit-show"` → "Edit Show", `"settings"` → "Settings", `"watch-now"` → "Watch Now", `"cable-guide"` → "Cable Guide"

Note: `"cable-guide"` is opened directly via `openWindow(id: "cable-guide")` from the guide pop-out button, **not** through the `open()` helper. The `open()` helper matches windows by title; `"cable-guide"` (lowercase id) would not match `"Cable Guide"` (the WindowGroup title), so it falls through without deduplication. Since the floating guide is always launched from a single button, the direct call is correct.

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
[Header: one line per device — DeviceID  liveCount/slots  ⚠ no lineup, no guide (inline, orange)]
[Status message — secondary color, uses availableDeviceCount]
[Now Watching — "Ch 5.1  NBC · Show Title", play.tv.fill icon, only when vlcCurrentURL is non-empty]
[Watch Now — Label("Watch Now", systemImage: "play.tv.fill"), when devices present]
[Add Show… — Button, opens wizard window]
Divider
Settings…
Divider
Section "Recording Now"              ← only when shows are recording (single tuner)
Section "Recording · DeviceID"       ← per device when multiple tuners present
  recordingMenu(show) …
Divider
Section "Up Next"                    ← shows starting within the next hour (single tuner)
Section "Up Next · DeviceID"         ← per device when multiple tuners present
  Section "8:00 PM"                  ← time-slot Section groups shows by start minute
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

One `Text` line per device: `"105404BE  1/4"` (DeviceID + `liveCount/totalTuners`). `liveCount` comes from `state.deviceTunerOccupancy[deviceId]` — the decoded `/status.json` array polled each idle tick; falls back to `recordingShows` count before the first poll. Full `labelColor` when recording; `secondaryLabelColor` when idle. If `liveCount != appCount` (and occupancy has been polled at least once), appends `"  ⚠ app expects N"`.

After startup, lineup/guide failures are appended inline to the device row: `"  ⚠ no lineup"`, `"  ⚠ no guide"`, or `"  ⚠ no lineup, no guide"`. The entire row turns `systemOrange` when any warning is present — a single visual pop replaces the earlier pattern of separate orange rows below each device. Both conditions read `@Published` vars directly so SwiftUI reliably re-renders when either changes. Devices with active warnings are excluded from `availableDeviceCount`, so `state.statusMessage` reads e.g. `"16 show(s) — 1 tuner(s) ready"` when one of two devices is unhealthy.

---

## Recording Now — `recordingMenu(_:)`

Menu label: `🔴 [Title]` (or `🔴 [Title] · S02E05` when guide entry is found for the airing)

Submenu contents — uses `showInfoHeader(show, entry:)` for the top block, then:
1. **Type + channel** — `"SeriesID(All) · Channel 5.1"`, full `labelColor`
2. **Start time + duration** — `"8:00 PM · 60 min"`, `secondaryLabelColor`
3. **Bonus Time callout** — `"🏈 Bonus Time (+N min)"` when `show.show_bonus_time == true` and the recording is past the guide end time
4. **Tuner ID** — `"tuner 105404BE"`, `secondaryLabelColor`
5. **Signal** — shown when `state.tunerStatus[show.show_id]` is set: `"Signal: 78% · lock: qam256 · 12.4 Mbps"`, `secondaryLabelColor`
6. Divider
7. **Skip** (destructive) — `state.skipRecording(showId:)`: stops recording, advances schedule to next airing, no fail-count increment
8. **Delete…** (destructive) — `state.confirmAndDeleteShow(show)`: stops recording + shows confirmation alert with poster image, then removes the show entirely
9. **Show Recording in Finder** — shown when `show_recording_path` is non-empty
10. **Watch in VLC** — shown when `state.config.Watch_in_VLC == true` (user toggle in Settings → Advanced); **Watch Now!** — shown when `VLCBridge.shared.isAvailable` (VLC app installed and dylib loaded). These are independent conditions.
11. **Edit…**

---

## `showInfoHeader(_:entry:)` — Shared Poster Panel

Used by `recordingMenu`, `scheduledMenu`, and `pausedMenu`. Renders:

1. **Poster** — `AsyncImage` of `show.show_logo_url` (460×258, cornerRadius 6) with a gray placeholder when absent. Accessibility label: `"\(show.show_title) poster"`.
2. **Title** — `menuInfo(show.show_title, font: .title3, maxWidth: 460)`
3. **Episode info** — `entry.episodeInfoLabel` if the entry is non-nil
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

Shows in `activeShows` whose `show_next` falls within the **next 60 minutes** appear in the **"Up Next"** section above "Scheduled". Shows are bucketed by start time (rounded to the minute); each bucket renders as a nested `Section("8:00 PM")` containing its shows. Each show in Up Next has `showChannel: true` so the channel is visible in the row label. Shows in Up Next are excluded from the Scheduled section.

**Series filter:** series shows without a confirmed `menuScheduledEntry` (no guide entry was matched within the look-ahead window) are excluded from Up Next and remain in Scheduled. These shows are in retry/scan mode — `show_next` falls within the window only because of a prior episode, not because a real upcoming episode has been confirmed — and surfacing them in Up Next would mislead the user into thinking a recording is imminent.

---

## Paused Shows — `pausedMenu(_:)`

Source: `state.pausedShows` — shows where `show_active == true && show_paused == true`.

A show enters this state via: fail threshold, manual stop, skip, disk full, missing output file, no air days configured, or manually via the **Pause** button. Shows auto-resume when their scheduled window expires or their next airing is imminent.

Menu label: `⏸ [Title]`

Submenu — uses `showInfoHeader(show, entry:)`, then: show type + channel, pause reason (if `show_fail_reason` non-empty), next attempt time (if `show_next` is future), then **Resume Now** → `state.resumeShow(show)`, **Edit…**, **Delete…** (destructive — uses `confirmAndDeleteShow`).

---

## Now Watching — `nowWatchingInfo`

A `Button` shown when `state.vlcCurrentURL` is non-empty (i.e. the VLC player window is active). Clicking it calls `VLCPlayerWindowManager.shared.focus()` — brings the player window to the front without switching the stream.

Label format: `"Ch 5.1  NBC · Show Title"` where the channel comes from matching `vlcCurrentURL` against the device lineups (URL prefix comparison, strips query params), and the show title is the currently-airing `GuideEntry` for that channel. The `· Show Title` suffix is omitted when no guide entry is found. Icon: `play.tv.fill` in `watchNowBlue`.

`nowWatchingInfo` is a private computed property that:
1. Returns `nil` when `vlcCurrentURL` is empty
2. Strips query params from the URL, then scans all device lineups for a `LineupEntry` whose `URL` matches exactly (equality check against the stripped base URL)
3. Looks up the current guide entry via `state.guideEntries(deviceId:channelNum:)` and filters to the entry spanning `Date()`
4. Returns `(channel: LineupEntry, entry: GuideEntry?)`

`vlcCurrentURL` is driven by a Combine sink in `AppState.init` that maps `VLCBridge.shared.$currentURL` (the URL actually loaded by libvlc) through `.urlBase` — stripping any `?transcode=…` query param — and assigns it to `$vlcCurrentURL`. It updates automatically whenever VLC starts or stops playing; no manual assignment is needed at call sites. When `VLCBridge.releasePlayer()` is called on window close, `currentURL` becomes `nil`, the Combine chain fires, and `vlcCurrentURL` clears to `""` — so this button disappears without any explicit clearing in `playerWindowDidClose`.

---

## Watch Now — `watchNowMenu`

A `Button` with `Label("Watch Now", systemImage: "play.tv.fill")` in a blue tint (`watchNowBlue = Color(red: 0.2, green: 0.6, blue: 1.0)`). Shown when `state.devices` is non-empty. Opens the `"watch-now"` `WindowGroup` (`WatchNowView`) — a 420×620 poster-card grid of currently-airing shows. If the window is already open, brings it to front instead of opening a duplicate.

---

## Add Show — `Button`

A plain `Button` with `Label("Add Show…", systemImage: "plus")`. Opens the `"add-show"` `WindowGroup` (`AddShowView`) — a 3-step wizard. The old cascading menu (device → channel → guide entries) was removed; that browsing path is now covered by **Watch Now**.

---

## Helper Functions

| Function | Purpose |
|---|---|
| `showInfoHeader(_:entry:)` | Shared poster + title + episode + synopsis block; always shows yellow flag triangle |
| `stateIcon(_:)` | Emoji for show type |
| `relativeLabel(_:)` | "2h 15m", "45m", "30s" from a `TimeInterval` |
| `elapsedLabel(since:)` | `relativeLabel(Date().timeIntervalSince(start))` |
| `remainingLabel(until:)` | `relativeLabel(end.timeIntervalSince(Date()))` |
| `upcomingLabel(channel:date:)` | `"Channel 5.1 · Thu 8:00 PM"` / `"Channel 5.1 · 8:00 PM"` for today |
| `timeRange(_:)` | `"8:00 PM – 9:00 PM"` — inside entry submenus |
| `weekdayName(_:)` | Full weekday name from a `Date` |
| `entry.episodeInfoLabel` | `GuideEntry` extension (Models.swift); joins `EpisodeNumber` + `EpisodeTitle` with ` · `; nil if both empty |
| `truncateSynopsis(_:limit:)` | Clips to 160 chars at a word boundary |
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

- **No "Record Now" shortcut** — there's no direct path to immediately record a show that's currently on air without going through Watch Now or the Add Show wizard.
