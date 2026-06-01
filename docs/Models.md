# Models.swift — Data Types

All data types used across the app: `Show`, `HDHRDevice`, `GuideEntry`, `AppConfig`, `EpochDate`, and supporting structs.

---

## The 4-State Show Model

Shows have exactly one of four states, determined by boolean flags:

| State | `show_is_series` | `show_use_seriesid` | `show_use_seriesid_all` | Recording logic |
|---|---|---|---|---|
| **Single** | false | false | false | Records once, then deactivates |
| **DateTime** | true | false | false | Repeats on specific days/time on one channel |
| **SeriesID(Channel)** | true | true | false | Any episode of a series on one channel |
| **SeriesID(All)** | true | true | true | Any episode of a series on any channel |

`Show.state` computed property derives the enum from these flags.

---

## Show State Flags

Two booleans control schedulability beyond the 4-state type:

- **`show_active`** — `false` only for completed Singles. Never set `false` for series or error conditions.
- **`show_paused`** — `true` for any recoverable pause: fail threshold, manual stop, skip, disk full, missing output, no air days, or user action. Paused shows appear in the "Paused" menu section with **Resume Now**.

Menu section routing:
- `show_recording == true` → Recording Now
- `show_active && !show_paused && !show_recording` → Scheduled / Next Up
- `show_active && show_paused` → Paused
- `!show_active` → auto-removed at startup (never shown)

---

## Next-Air Scheduling (`AppState.scheduleNextAir`)

Called after each recording completes and file verification passes:

- **Single**: sets `show_active = false`.
- **DateTime**: calculates next matching weekday/time in **local time** via `nextDateTime(for:)`. `show_time` = local decimal hours; `show_air_date` = local day names. If `show_air_date` is empty or invalid → pauses with `"No air days configured"`.
- **SeriesID**: reloads guide if stale, checks `currentEpisode` first (handles marathons), then `nextEpisode`. Uses `match.deviceId` to update `show.hdhr_record` — SeriesID(All) may resolve to a different device. If no episode found → `show_next = now + Series_scan_retry_hours`.

---

## Show Output Path

`Show.outputPath(for:date:)` builds the recording file path. The `DateFormatter` used for the timestamp suffix (`outputDateFormatter`) is a `private static let` — allocated once per app session, not on every recording start.

---

## Date Fields in Show

All five date fields (`show_next`, `show_end`, `show_last`, `notify_upnext_time`, `notify_recording_time`) are `Date?`. `nil` means "not set." The config encoder uses ISO8601; the decoder accepts ISO8601 or legacy string/numeric epoch (for migrating v1 configs). The old `EpochDate` wrapper type is gone.

---

## Transient Recording Fields

`discord_start_msg_id: String` (default `""`) — stores the Discord message ID returned by the `?wait=true` webhook response when a "Recording Started" embed is sent. Used by `AppState` to edit that embed in-place at completion, failure, or on progress updates. Persisted in config JSON so that a restart during a recording can still edit the original start message. Cleared to `""` after the recording ends (success or failure). On startup, `reattachRecordings()` sends a recovery embed and clears this field for any show that has an ID but was not reattached as actively recording.

`show_tuner_resource: String` (default `""`) — exact tuner identity from the `X-HDHomeRun-Resource` HTTP response header (e.g. `"tuner0"`). Captured 1.5 s after recording starts via `AppState.captureResourceHeaders()` reading the curl `--dump-header` file. Used by `fetchDeviceStatus` to target `/tunerN/vstatus` directly instead of searching by channel number. Cleared to `""` when recording stops (naturally, manually, or on unexpected exit); also cleared on reattach at startup so it can be re-captured.

---

## Show Failure Helpers

Two mutating methods on `Show` consolidate the repeated failure-state field group:

- `recordFailure(reason: String)` — increments `show_fail_count`, sets `show_fail_reason`, sets `show_paused = true`. Used at every recording-start failure path.
- `clearFailures()` — zeros `show_fail_count` and clears `show_fail_reason`. Callers that also un-pause a show set `show_paused = false` separately (intentional — paused state is independent of the failure counters in some flows such as `resetAllFailCounts`).

---

## GuideEntry Notable Fields

- `Filter: [String]?` — genre tags (e.g. `["Drama", "Series"]`). Absent from some devices; decodes as `nil` when key is missing.
- `firstGenre: String?` — computed shorthand for `Filter?.first`; used for guide cell coloring and genre filter picker.
- `episodeInfoLabel: String?` — computed property; joins `EpisodeNumber` and `EpisodeTitle` with `" · "`, returning `nil` when both are absent or empty. Used in WatchNowView, AddShowView, and FloatingGuideView summary panels.

---

## HDHRDevice Computed Properties

- `lineupURL` — always `"http://{LocalIP}/lineup.json"`. **Never** uses `LineupURL` from discover.json (may contain `hdhomerun.local` which fails on unreliable networks).
- `statusURL` — `"http://{LocalIP}/status.json"` — live tuner status endpoint.

---

## DeviceTunerInfo

Decodable struct for one entry in the `/status.json` array:

```swift
struct DeviceTunerInfo: Decodable {
    let Resource: String       // e.g. "tuner0"
    let VctNumber: String?     // non-nil when tuner is in use
    let TargetIP: String?      // client receiving the stream
}
```

A tuner is occupied when `VctNumber != nil`.

---

## Logging (`glog`)

Global free function in `Models.swift`:

```swift
func glog(_ msg: String, level: LogLevel = .info)
// LogLevel: .info ("INFO"), .warning ("WARN"), .error ("ERROR")
```

Log file: `~/Library/Logs/hdhrVCRplus.log`  
Format: `[2026-05-25T04:01:24Z] [INFO] message`

File descriptor opened with `O_APPEND` on every call — atomic across actors/threads. All source files use `glog`; no `print()` calls anywhere.
