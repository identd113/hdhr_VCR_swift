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
- **`show_paused`** — `true` when the fail threshold is reached, or for: manual stop, skip, disk full, missing output, no air days, or user action. Paused shows appear in the "Paused" menu section with **Resume Now**. A recording failure alone does NOT pause the show — `startRecording` retries up to `Fail_count_setting` times (once per idle loop tick) before setting this flag.

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
- **SeriesID**: reloads guide if stale, checks `currentEpisode` first (handles marathons), then `nextEpisode`. Uses `match.deviceId` to update `show.hdhr_record` — SeriesID(All) may resolve to a different device. If no episode found: bumps `show_next` to `now + Series_scan_retry_hours` only if `show_next` is nil or already past — a future `show_next` (e.g. from a prior guide match) is left unchanged so `rescheduleAllSeries` can override it when a real episode appears.

---

## Show Output Path

`Show.outputPath(date:)` builds the recording file path. The `DateFormatter` used for the timestamp suffix (`outputDateFormatter`) is a `private static let` — allocated once per app session, not on every recording start.

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

- `recordFailure(reason: String)` — increments `show_fail_count` and sets `show_fail_reason`. Does NOT set `show_paused` — the caller (`startRecording`) checks the count against `Fail_count_setting` and pauses only after the threshold is exceeded, allowing one retry per idle loop tick.
- `clearFailures()` — zeros `show_fail_count` and clears `show_fail_reason`. Callers that also un-pause a show set `show_paused = false` separately (intentional — paused state is independent of the failure counters in some flows such as `resetAllFailCounts`).

---

## GuideEntry Notable Fields

- `Filter: [String]?` — genre tags (e.g. `["Drama", "Series"]`). Absent from some devices; decodes as `nil` when key is missing.
- `firstGenre: String?` — computed shorthand for `Filter?.first`; used for guide cell coloring and genre filter picker.
- `episodeInfoLabel: String?` — computed property; joins `EpisodeNumber` and `EpisodeTitle` with `" · "`, returning `nil` when both are absent or empty. Used in WatchNowView, AddShowView, and FloatingGuideView summary panels.
- `deviceId: String` (default `""`) — **not in JSON; excluded from `CodingKeys`**. Stamped by `GuideStore.buildIndex` from the owning device's `DeviceID` so the device identity travels with the entry.
- `channelNum: String` (default `""`) — **not in JSON; excluded from `CodingKeys`**. Stamped by `GuideStore.buildIndex` alongside `deviceId` so managed-show slot keys can be built from the entry alone.

---

## ManagedGuideMatcher

`struct ManagedGuideMatcher: Equatable` in `Models.swift` is the **single source of truth** for managed-show identification across all four call sites (CableGuideView, AddShowView, FloatingGuideView, WebServer). Callers pass `activeManagedShows` once at construction; then call `isManaged(entry:)` per block.

```swift
struct ManagedGuideMatcher: Equatable {
    let seriesIDs:        Set<String>   // SeriesID(Channel/All) shows
    let titles:           Set<String>   // title fallback for series shows without a SeriesID
    let singleSlotKeys:   Set<String>   // "device:channel:epoch" — single shows, exact slot
    let datetimeSlotKeys: Set<String>   // "device:channel:HH:MM" — dateTime shows, all matching slots

    init(activeManagedShows: [Show])

    // Reads entry.deviceId and entry.channelNum directly — no caller-supplied args.
    func isManaged(entry: GuideEntry) -> Bool
}
```

Matching tiers (in order):
1. `entry.SeriesID` present and in `seriesIDs` → managed
2. `entry.Title` in `titles` → managed (series shows whose guide entry has no SeriesID)
3. `"device:channel:HH:MM"` local-time key in `datetimeSlotKeys` → managed (datetime shows: every weekly slot)
4. `"device:channel:epoch"` key in `singleSlotKeys` → managed (single shows: exact scheduled slot only)

`dateTime` shows use local-time `HH:MM` so a M-F 7PM show flags every 7PM slot on that channel+device in the guide window, not just the one stored in `show_next`. `single` shows use the epoch so only the specific airing is flagged.

Paused shows are excluded from `activeManagedShows` by all callers — the yellow/red flag only appears for active scheduled shows.

---

## ShowMatcher

`struct ShowMatcher: Equatable` — lightweight version of `ManagedGuideMatcher` used for recording / next-up / bonus classification where only SeriesID + title matching is needed (no slot-key logic).

```swift
struct ShowMatcher: Equatable {
    let seriesIDs: Set<String>
    let titles:    Set<String>

    init(_ shows: [Show])

    func matches(_ entry: GuideEntry) -> Bool
    // Returns true when entry.SeriesID ∈ seriesIDs, or entry.Title ∈ titles as fallback.
}
```

Used by `CableGuideView.ShowBlocksRow`, `AddShowView`, `FloatingGuideView`, and `AppState.bonusOverlapWarning`. Replaces the previous pattern of building two raw `Set<String>` values and testing them inline.

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
