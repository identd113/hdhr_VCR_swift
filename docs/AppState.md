# AppState.swift — App Logic & Data Flow

`@MainActor ObservableObject`. All app state lives here. `hdhr_VCRApp` injects it as an `@EnvironmentObject`.

---

## Startup (`AppState.startup`)

1. `loadConfig()` — reads JSON, resets all `show_recording = false`; sets `guideStore.verbose`. Auto-removes inactive Single shows (already recorded; no further scheduling needed).
2. `reattachRecordings()` — scans `ps -Axo pid,args` for `caffeinate` lines with `show_id:` + `hdhrVCRplus`. If the show's `show_end` is still future, sets `show_recording = true` and registers the PID — recording continues uninterrupted. **Read pipe data before `waitUntilExit()`** to avoid deadlock when ps output exceeds the ~64 KB pipe buffer.
3. Notification permission (background `Task` — non-blocking).
4. `discoverDevices(knownHosts:attempts:10)` — up to 10 retries with 1 s pauses; idle loop retries on each tick if devices remain empty.
5. `fetchAllGuides()` — parallel guide load for all devices; mirrors result into `guideByDevice`.
6. `startTimer()` — fires `idleLoop()` every `config.Idle_timer_interval` seconds (default 10, min 5).
7. Sets `isStartingUp = false` (menu bar icon switches from dimmed to normal/red-dot).

---

## Idle Loop (`AppState.idleLoop`)

Runs every `config.Idle_timer_interval` seconds on MainActor:

- If `devices` is empty → retries discovery immediately.
- If guide channels missing for any device → calls `ensureGuideLoaded(for:)`.
- Refreshes lineup + guide every `max(3600, GuideHours × 1800)` seconds (non-blocking `Task`).
- Per active show:
  - Fires "Up Next" notification once at `Notify_upnext` minutes before; stamps `notify_upnext_time`.
  - Fires "Recording Soon" notification once at `Notify_recording` minutes before; stamps `notify_recording_time`.
  - Starts recording if `show_next <= now + 10s` AND `show_end > now`.
  - Stops recording naturally if `show_end <= now`.
  - Detects unexpected caffeinate exit → increments fail count, sends notification.
- Conflict notifications: when a show can't start because all tuners are full, fires once per show+episode window (`conflictNotifiedKeys` set keyed by `"showID-show_next_epoch"`).

---

## Device Discovery (`HDHRManager.discoverDevices`)

Three paths run **concurrently**; results merged by DeviceID:

1. **Known hosts** — extracts IPs from `show_url` fields of saved shows → probes `/discover.json`. Sub-second on stable networks.
2. **mDNS** — `http://hdhomerun.local/discover.json`. Handles single-object or array response.
3. **UDP broadcast** — SiliconDust packet to `255.255.255.255:65001`, waits 2 s; each reply followed up with `fetchDeviceInfo(ip:)`.

Falls back to **SiliconDust cloud API** (`http://discover.hdhomerun.com/discover.json`) if all three yield nothing. After merging, devices missing `DeviceAuth` are supplemented from the cloud response (needed for EXTEND devices). Session timeouts: 2 s request / 6 s resource.

### EXTEND device (HDTC-2US)
- Has no local `/guide.json` — uses cloud guide API instead.
- `GuideStore.guideURL(for:hours:)` routes to `https://api.hdhomerun.com/api/guide.php?DeviceAuth=...&Duration=N` (hours) when `DeviceAuth != nil`; otherwise `http://{LocalIP}/guide.json?Duration=N`.
- mDNS response omits `LocalIP`; extracted from `BaseURL` host in `HDHRDevice.init(from:)`.
- Local `/discover.json` may omit `DeviceAuth` on some firmware; startup retry + mDNS/cloud discovery recovers.

---

## Computed Properties

| Property | Description |
|---|---|
| `isRecording` | Any show has `show_recording == true` |
| `recordingShows` | Recording and `show_end > now` |
| `activeShows` | `show_active && !show_recording && !show_paused`, sorted by `show_next` |
| `pausedShows` | `show_active && show_paused` |
| `inactiveShows` | `!show_active` (completed singles; auto-removed at startup) |
| `nextShowMinutes` | Minutes until nearest active show; drives orange `clock.badge` icon when ≤ 30 |
| `availableDeviceCount` | Excludes devices with missing lineup or guide; used in status message |

---

## Guide Helpers

| Method | Description |
|---|---|
| `fetchAllGuides()` | Startup parallel load; sets `lastGuideRefresh` only when ≥1 channel loaded |
| `refreshGuides()` | Private; invalidates then reloads all; called periodically from idle loop |
| `ensureGuideLoaded(for deviceId:)` | Loads a device if channels absent and not already loading; safe to call repeatedly |
| `ensureLineupLoaded(for device:)` | Re-fetches lineup if nil/empty; called at guide-step open in AddShowView + FloatingGuideView |
| `guideEntries(deviceId:channelNum:)` | Delegates to `guideStore.entries()` |
| `nextGuideEpisode(for show:)` | Delegates to `guideStore.nextEpisode()`; respects channel/device filters |
| `upcomingGuideEpisodes(seriesID:after:limit:)` | Up to `limit` upcoming `(channel, entry)` tuples across all devices |

---

## Show Actions

| Method | Description |
|---|---|
| `pauseShow(_:)` | Sets `show_paused = true`, `show_fail_reason = "Manually paused"`, saves config |
| `resumeShow(_:)` | Clears `show_paused`, resets fail count + reason, saves config |
| `watchInVLC(url:)` | Opens stream in `/Applications/VLC.app` via `NSWorkspace`; no-op if VLC absent or `Watch_in_VLC` false |
| `watchInApp(url:title:deviceId:transcode:)` | Opens VLC in-app player; checks `/status.json` first, alerts if all tuners occupied; sets `vlcCurrentURL` |
| `confirmAndDeleteShow(_:then:)` | Fetches poster async → NSAlert with image → stops recording + removes show |
| `testDiscordEvent(_:webhookURL:)` | Sends test embed using real show data; always passes `enabled: true` |
| `formatFileSize(_:)` | Private static; formats bytes as `"X.XX GB"` / `"X.X MB"` / `"X KB"` |

---

## @Published Safety Rule

In a SwiftUI `.menu`-style `MenuBarExtra`, the menu body re-evaluates on every `@Published` change.

**Never assign `guideByDevice = ...` unconditionally after a failed/empty response.** A failed load that assigns `guideByDevice` triggers `didSet → rebuildMenuEntries → @Published changes → re-eval → ...` at ~35ms/loop, freezing the menu. Guards: `ensureGuideLoaded` only assigns when `guideStore.channels(deviceId:)` is non-empty; `guideApiBackoff: [String: APIBackoff]` enforces exponential backoff (1 → 5 → 15 → 30 → 60 min) on failed devices.

`rebuildMenuEntries()` is called from `guideByDevice.didSet` (after every guide load) and from the idle loop (guarded by `menuIsOpen`). It rebuilds: `managedShowBySeriesID`/`managedShowByTitle` (O(1) show lookups for WatchNow + menus), `channelImageURLs` (logo URL map for WatchNow), `menuScheduledEntry`/`menuUpcomingSlots` (pre-computed guide matches for scheduled/paused menus), and `conflictingShowIDs` (one O(N²) conflict pass instead of one per open).
