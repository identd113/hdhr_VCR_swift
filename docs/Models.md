# Models.swift — Data Types

All data types used across the app: `Show`, `HDHRDevice`, `GuideEntry`, `AppConfig`, `EpochDate`, and supporting structs.

---

## The 4-State Show Model

Shows have exactly one of four states, determined by boolean flags evaluated in priority order:

```
if !show_is_series       → .single
if show_use_seriesid_all → .seriesAll
if show_use_seriesid     → .seriesChannel
else                     → .dateTime
```

| State | Recording logic |
|---|---|
| **Single** | Records once at the scheduled slot, then deactivates |
| **DateTime** | Repeats on specific days/time on one channel; advances via `nextDateTime` after each recording |
| **SeriesID(Channel)** | Any episode of a series on one channel; matched by SeriesID then title; advances via guide scan |
| **SeriesID(All)** | Any episode of a series on any channel or device; same guide-scan logic, but `hdhr_record` may change per airing |

Note: `.seriesAll` is triggered solely by `show_use_seriesid_all == true` (regardless of `show_use_seriesid`). In practice both flags are set together, but the code does not require it.

`Show.state` is computed at runtime from the flags — it is not stored in config.

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

## Bonus Time Default

`show_bonus_time` defaults to `false` for all new shows. **One exception:** the `init(from:)` decoder uses `show_genre.lowercased().contains("sports")` as the fallback when the field is absent from JSON — so shows loaded from a pre-bonus-time config auto-enable it if their genre is Sports. New shows created through the UI or `addShowFromGuide` always receive an explicit value (never the genre-based fallback), so genre alone does not auto-enable bonus time for newly added shows.

---

## Recording Folder Fallback (`show_dir` / `show_temp_dir` / `posixRecordDir`)

`Show.localFallbackDir` (`NSHomeDirectory() + "/Movies/hdhr_videos"`) is the single shared constant for "the folder that always exists, purely local, no volume to go offline" — used by `posixRecordDir`'s own fallback tier, `AppState.defaultSaveDir`, `addShowFromGuide`, and the Add/Edit Show dialogs' folder handling, rather than each duplicating the literal path.

`posixRecordDir` treats `show_dir` as primary and `show_temp_dir` as the fallback: if `show_dir`'s parent directory doesn't exist (the volume is unmounted), it redirects to `show_temp_dir`. For this to do anything, `show_temp_dir` has to actually be a *different* folder from `show_dir` — a prior bug in the native Add/Edit Show dialogs set them to the identical value (the user's chosen folder) on every save, silently discarding whatever real fallback a show had (including one set correctly by the web guide's `addShowFromGuide`, which always uses `Show.localFallbackDir` for `show_temp_dir` regardless of what `show_dir` is). Both dialogs now set `show_temp_dir` to `Show.localFallbackDir` instead of copying `show_dir`.

**Self-healing for shows already saved with the bug:** `Show.init(from:)` repairs it on every load — a non-empty `show_temp_dir` identical to a non-default `show_dir` (i.e. `show_temp_dir == show_dir && show_dir != Show.localFallbackDir`) is treated as unambiguous evidence of the bug (a genuinely intentional matching value would be pointless to ever set) and is reset to `Show.localFallbackDir` in memory immediately, before anything reads `posixRecordDir`. This doesn't require re-saving through the now-fixed dialogs, and doesn't force an immediate config-file rewrite either — it just reapplies on every load, so the running app's fallback behavior is correct from the moment the config loads regardless of what's actually persisted on disk.

---

## Decode Resilience (`Show.init(from:)` / `ConfigFile.init(from:)`)

Every field in `Show.init(from:)` decodes via `try?` with a fallback default — including `show_id` (falls back to a fresh generated UUID, same format as `Show.blank()`). This matters because `ConfigFile.init(from:)`'s `shows` array decode is all-or-nothing: `(try? c.decode([Show].self, forKey: .shows)) ?? (try? … forKey: .the_shows) ?? []` — if decoding a single element in the array throws, the *entire* array decode throws and falls through to the next `try?`/eventually `[]`. Before `show_id` had a fallback, one show with a missing/corrupt `show_id` anywhere in the saved JSON would silently wipe every saved show on next launch. With every field now optional-with-fallback, a well-formed JSON array of show objects can no longer throw during decode.

If the `shows`/`the_shows` key *is* present in the config but the array still fails to decode entirely (a genuinely malformed structure, not just a missing field — e.g. the value isn't an array of objects at all), `ConfigFile.init` logs `[Config] shows array present but failed to decode — starting with an empty list; check config file for corruption` at `.error` before falling back to `[]`, so that failure mode is no longer silent.

---

## Show Output Path

`Show.outputPath(date:)` builds the recording file path. The `DateFormatter` used for the timestamp suffix (`outputDateFormatter`) is a `private static let` — allocated once per app session, not on every recording start.

**Extension is always `.ts`** regardless of transcode profile. The recorder writes the device's HTTP response verbatim (`curl -o`, no remux), and that response is always an MPEG-2 transport stream — transcoding only swaps the video codec inside the TS (MPEG-2 → H.264), not the container (see `docs/HDHRFindings.md`). `Show.recordingExtensions = {ts, m2ts, mkv}` and `Show.isRecordingFile(_:)` are the single source of truth for "is this a file we produced": `.ts` is current output, `.m2ts`/`.mkv` are legacy (pre-2026-07) and stay recognized so old recordings still count for `recordedEpisodeTags` (skip-already-recorded) and `organizeSeriesRecordings`. `.mp4` is deliberately excluded — the app never wrote it.

---

## Date Fields in Show

All five date fields (`show_next`, `show_end`, `show_last`, `notify_upnext_time`, `notify_recording_time`) are `Date?`. `nil` means "not set." The config encoder uses ISO8601; the decoder accepts ISO8601 or legacy string/numeric epoch (for migrating v1 configs). The old `EpochDate` wrapper type is gone.

---

## Transient Recording Fields

`discord_start_msg_id: String` (default `""`) — stores the Discord message ID returned by the `?wait=true` webhook response when the first Discord embed for this recording is sent (may be a failure card if the show fails before the start embed fires). Used by `AppState.discordRecordingCard` to edit that embed in-place for all subsequent lifecycle events (failure retry → start → progress → complete/paused), keeping the entire recording lifecycle in a single Discord message. Persisted in config JSON so that a restart during a recording can still edit the original message. Cleared to `""` **only** at terminal events (recording completes, or the show is paused/stopped) — **not** on non-terminal failures, so the next retry edits the same card. On startup, `reattachRecordings()` sends a recovery embed and clears this field for any show that has an ID but was not reattached as actively recording.

`show_tuner_resource: String` (default `""`) — exact tuner identity from the `X-HDHomeRun-Resource` HTTP response header (e.g. `"tuner0"`). Captured 1.5 s after recording starts via `AppState.captureResourceHeaders()` reading the curl `--dump-header` file. Used by `fetchDeviceStatus` to target `/tunerN/vstatus` directly instead of searching by channel number. Cleared to `""` when recording stops (naturally, manually, or on unexpected exit); also cleared on reattach at startup so it can be re-captured.

---

## Show Failure Helpers

Two mutating methods on `Show` consolidate the repeated failure-state field group:

- `recordFailure(reason: String)` — increments `show_fail_count` and sets `show_fail_reason`. Does NOT set `show_paused` — the caller (`startRecording`) checks the count against `Fail_count_setting` and pauses only after the threshold is exceeded, allowing one retry per idle loop tick.
- `clearFailures()` — zeros `show_fail_count` and clears `show_fail_reason`. Callers that also un-pause a show set `show_paused = false` separately (intentional — paused state is independent of the failure counters in some flows such as `resetAllFailCounts`).

---

## GuideEntry Notable Fields

- `Filter: [String]?` — genre tags (e.g. `["Drama", "Series"]`). Absent from some devices; decodes as `nil` when key is missing. In XMLTV mode (`Guide_use_xml = true`), may also contain `"Shop"` or `"Shopping"` for paid-programming entries (explicit category; JSON uses SeriesID blocklist instead).
- `firstGenre: String?` — computed property on `Filter`; returns `"Movie"` when `Filter` contains `"Movie"` or `"Movies"` (regardless of position), otherwise returns the first element that is not `"series"` (case-insensitive). Used for guide cell coloring and genre filter picker.
- `episodeInfoLabel: String?` — computed property; joins `EpisodeNumber` and `EpisodeTitle` with `" · "`, returning `nil` when both are absent or empty. Used in WatchNowView, AddShowView, and FloatingGuideView summary panels.
- `deviceId: String` (default `""`) — **not in JSON; excluded from `CodingKeys`**. Stamped by `GuideStore.buildIndex` from the owning device's `DeviceID` so the device identity travels with the entry.
- `channelNum: String` (default `""`) — **not in JSON; excluded from `CodingKeys`**. Stamped by `GuideStore.buildIndex` alongside `deviceId` so managed-show slot keys can be built from the entry alone.

---

## GuideChannel Notable Fields

- `Affiliate: String?` — network name (e.g. `"NBC"`). Populated in XMLTV mode from the last `<display-name>` element. In JSON mode (`guide.php`) this field is present in the server response and decoded directly.

---

## ManagedGuideMatcher

`struct ManagedGuideMatcher: Equatable` in `Models.swift` is the **single source of truth** for managed-show identification *and* ownership. Used by WebServer to flag managed shows in the guide HTML and to embed the owning show's config for the edit modal. Callers pass `activeManagedShows` once at construction; then call `owner(for:)` per block (`isManaged(entry:)` is a thin `owner(for:) != nil` wrapper kept for call sites that only need the boolean).

```swift
struct ManagedGuideMatcher: Equatable {
    let seriesAllIDs:    [String: Show]   // bare SeriesID → owner — seriesAll shows (record on any device)
    let seriesAllTitles: [String: Show]   // bare title → owner — seriesAll shows without a SeriesID
    let seriesChKeys:    [String: Show]   // "device:SeriesID" → owner — seriesChannel shows (device-scoped)
    let seriesChTitles:  [String: Show]   // "device:title" → owner — seriesChannel shows without a SeriesID
    let singleSlotKeys:  [String: Show]   // "device:channel:epoch" → owner — single shows, exact slot
    let datetimeSlotKeys: [String: Show]  // "device:channel:Weekday:HH:MM" → owner — dateTime shows, per allowed day

    init(activeManagedShows: [Show])

    // Reads entry.deviceId and entry.channelNum directly — no caller-supplied args.
    func owner(for entry: GuideEntry) -> Show?
    func isManaged(entry: GuideEntry) -> Bool
}
```

Values are the owning `Show`, not just presence — this is what lets `WebServer.swift` embed a managed block's `data-show-*` edit attributes directly from `owner(for:)` instead of maintaining a second, independently-derived owner lookup (a prior `findManagedShow` helper there did exactly that, and being built differently — no title fallback for series shows — could disagree with the flag about whether a block had a resolvable owner; see `docs/WebServer.md`'s "Managed show data attributes" section).

Matching tiers (in order — `owner(for:)` returns the first match, `isManaged` is `owner(for:) != nil`):
1. `entry.SeriesID` in `seriesAllIDs` (any device) OR `"device:SeriesID"` in `seriesChKeys` → managed
2. `entry.Title` in `seriesAllTitles` OR `"device:title"` in `seriesChTitles` → managed
3. `"device:channel:Weekday:HH:MM"` local-time key in `datetimeSlotKeys` → managed (dateTime shows: only on allowed weekdays)
4. `"device:channel:epoch"` key in `singleSlotKeys` → managed (single shows: exact scheduled slot only)

Tiers 3–4 (the `Calendar.current.dateComponents` call and everything after) are skipped entirely via an early return when both `datetimeSlotKeys` and `singleSlotKeys` are empty — the common case for a guide with only SeriesID-managed shows, and otherwise this ran for every non-managed entry in the grid (the majority of entries) on every rebuild.

All six dictionaries keep the *first* match on a key collision (e.g. two shows sharing a SeriesID, or two shows landing on the identical slot key) rather than trapping or silently overwriting — matching the tolerant dedup a plain `Set` gave before switching from presence-only keys to key→owner maps. `seriesAllIDs`/`seriesAllTitles`/`seriesChKeys`/`seriesChTitles` get this via `Dictionary(_:uniquingKeysWith: { a, _ in a })`; `singleSlotKeys`/`datetimeSlotKeys` are built with a manual loop (`if dict[key] == nil { dict[key] = s }`) since they're populated incrementally per allowed air-day rather than from a single flat mapping, but the collision behavior is the same first-wins semantics.

`dateTime` shows emit one key per entry in `show_air_date` (e.g. a Wednesday-only show at 4:30 PM local emits only `"device:4.3:Wednesday:16:30"`). A Friday airing of that show at 4:30 PM looks for `"device:4.3:Friday:16:30"` and finds nothing — no yellow diamond. If `show_air_date` is empty, keys are emitted for all 7 days. `single` shows use the epoch so only the specific airing is flagged.

Paused shows are excluded from `activeManagedShows` by all callers — the yellow/red flag only appears for active scheduled shows.

---

## HDHRDevice Computed Properties

- `lineupURL` — always `"http://{LocalIP}/lineup.json"`. The `LineupURL` field from discover.json is not stored (may contain `hdhomerun.local` which fails on unreliable networks).
- `statusURL` — `"http://{LocalIP}/status.json"` — live tuner status endpoint.

## HDHRDevice Availability Tracking

```swift
var missedProbes: Int = 0      // runtime-only; not persisted; resets to 0 on every launch
var isAvailable: Bool { missedProbes < 3 }
```

`missedProbes` is incremented by `AppState.probeForNewDevices()` each probe cycle when the device is not seen in the discovery response (or when discovery throws entirely). Reset to 0 when the device is seen again. Not in `CodingKeys` — never serialised to config.

A device is considered **unavailable** (`isAvailable == false`) after 3 consecutive missed probes. After the first miss, `probeForNewDevices` schedules a 60-second follow-up probe so the unavailability threshold can be reached in ~2 minutes rather than 15.

---

## DeviceTunerInfo

Decodable struct for one entry in the `/status.json` array:

```swift
struct DeviceTunerInfo: Decodable {
    let Resource: String              // e.g. "tuner0"
    let VctNumber: String?            // non-nil when tuner is in use
    let TargetIP: String?             // client receiving the stream
    let SignalQualityPercent: Int?    // snq 0–100; used for passive signal collection
}
```

A tuner is occupied when `VctNumber != nil`. `SignalQualityPercent` is read by `AppState.teardownRecordingState` when reconstructing a tuner's occupancy entry.

---

## Signal Quality Types

Defined in `Models.swift`, used by `ChannelSignalStore` and the guide views.

```swift
struct ChannelSignalSample: Codable {
    var ts:  Date
    var snq: Int   // 0–100, signal quality percent
}

enum SignalBucket: String, Codable, Equatable {
    case noData, poor, fair, good
    init(_ v: Double)  // v < 0.33 → poor, < 0.66 → fair, else good
}
```

`SignalBucket` is the display-facing classification. `ChannelSignalSample` is the raw timestamped reading persisted by `ChannelSignalStore`.

---

## Logging (`glog`)

Global free function in `Models.swift`:

```swift
func glog(_ msg: String, level: LogLevel = .info)
// LogLevel: .info ("INFO"), .warning ("WARN"), .error ("ERROR")
```

Writes to **both** OSLog (subsystem `com.hdhr.vcrplus`, category `app`) and the app log file.

Log file: `~/Library/Logs/hdhrVCRplus.log`  
Format: `[2026-05-25T04:01:24Z] [INFO] message`

`logFilePath` is a module-level `let` constant. Writes are dispatched onto a serial `logQueue` (`DispatchQueue`, `.utility` QoS). A single `FileHandle` is opened on first write and kept open for the app's lifetime — no open/close overhead per call. Safe to call from any actor or thread. All source files use `glog`; no `print()` calls anywhere.
