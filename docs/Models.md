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

## GuideEntry Notable Fields

- `Filter: [String]?` — genre tags (e.g. `["Drama", "Series"]`). Absent from some devices; decodes as `nil` when key is missing.
- `firstGenre: String?` — computed shorthand for `Filter?.first`; used for guide cell coloring and genre filter picker.

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
