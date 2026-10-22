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

## Bonus Time padded-end marker (`show_bonus_padded_end`)

`Show.show_bonus_padded_end: Date?` (persisted; absent in older configs → `nil`) records the *padded* `show_end` that Bonus Time last produced for an airing. `startRecording` adds `Sports_padding_minutes` to `show_end` and saves the result; if `show_bonus_padded_end == endDate` it logs `Bonus Time already applied to this airing's end — not adding it again` instead, so a retry within the airing (launch failure, curl died, the backoff) — **or a relaunch mid-airing**, which used to lose the old in-memory `ShowRuntimeState.bonusPaddedEnd` while the padded `show_end` stayed on disk — can't pad twice. Compared by value, so a new airing (different `show_end`) unmatches it with no explicit clearing.

## Bonus Time Default

`show_bonus_time` defaults to `false` for all new shows. **One exception:** the `init(from:)` decoder uses `Show.genreImpliesBonusTime(show_genre)` (`show_genre.lowercased().contains("sport")` — singular on purpose, matches both guide.php's "Sports" and XMLTV's "Sport") as the fallback when the field is absent from JSON — so shows loaded from a pre-bonus-time config auto-enable it if their genre contains "sport". New shows created through the UI or `addShowFromGuide` always receive an explicit value (never the genre-based fallback), so genre alone does not auto-enable bonus time for newly added shows.

---

## Recording Folder Fallback (`show_dir` / `show_temp_dir` / `posixRecordDir`)

`Show.localFallbackDir` (`NSHomeDirectory() + "/Movies/hdhr_videos"`) is the single shared constant for "the folder that always exists, purely local, no volume to go offline" — used by `posixRecordDir`'s own fallback tier, `AppState.defaultSaveDir`, `addShowFromGuide`, and the Add/Edit Show dialogs' folder handling, rather than each duplicating the literal path.

`Show.posixPrimaryDir` is the configured folder as POSIX (a legacy HFS string like `"Raid6:DVR Tests:"` — shows migrated from the original AppleScript app — converted by `toPosix`, never swapped for the fallback), and `Show.isRecordingToFallback` is `!show_dir.isEmpty && posixRecordDir != posixPrimaryDir` — what drives `startRecording`'s "Primary folder unavailable — recording to fallback" warning. It compares the two *POSIX* forms: comparing `posixRecordDir` against the raw `show_dir` string (the pre-2026-10-09 check) always differed for an HFS-style `show_dir`, so such a show logged a false "unavailable" warning on every airing even though the mounted primary folder was in use. `posixRecordDir` treats `show_dir` as primary and `show_temp_dir` as the fallback: if `show_dir`'s parent directory doesn't exist (the volume is unmounted), it redirects to `show_temp_dir`. For this to do anything, `show_temp_dir` has to actually be a *different* folder from `show_dir` — a prior bug in the native Add/Edit Show dialogs set them to the identical value (the user's chosen folder) on every save, silently discarding whatever real fallback a show had (including one set correctly by the web guide's `addShowFromGuide`, which always uses `Show.localFallbackDir` for `show_temp_dir` regardless of what `show_dir` is). Both dialogs now set `show_temp_dir` to `Show.localFallbackDir` instead of copying `show_dir`.

**Self-healing for shows already saved with the bug:** `Show.init(from:)` repairs it on every load — a non-empty `show_temp_dir` identical to a non-default `show_dir` (i.e. `show_temp_dir == show_dir && show_dir != Show.localFallbackDir`) is treated as unambiguous evidence of the bug (a genuinely intentional matching value would be pointless to ever set) and is reset to `Show.localFallbackDir` in memory immediately, before anything reads `posixRecordDir`. This doesn't require re-saving through the now-fixed dialogs, and doesn't force an immediate config-file rewrite either — it just reapplies on every load, so the running app's fallback behavior is correct from the moment the config loads regardless of what's actually persisted on disk.

---

## Persisted Show Schema (JSON keys in `shows[]`)

Encoded by the synthesized `Encodable` (key = Swift property name; `Optional` fields that are `nil` are **omitted**, not written as `null`). Decoded by `Show.init(from:)`: every key is optional on read, the default below is what a missing/mistyped key becomes. Dates are ISO-8601 UTC strings with no fractional seconds (`"2026-05-30T21:00:00Z"`); the decoder also accepts a legacy numeric or numeric-string epoch (> 0), anything else decodes as `nil`.

| Key | JSON type | Default on missing | Meaning / units |
|---|---|---|---|
| `show_id` | String | fresh UUID, **32 lowercase hex chars, no dashes** | Identity. Never an integer. Also the value after `show_id:` in the curl `-H` header. |
| `show_title` | String | `""` | Raw title (series shows have the ` SxxExx…` suffix stripped by `Show.seriesTitle(from:)` at creation). |
| `show_is_series` | Bool | false | Together with the next two flags selects the 4-state type (see top). |
| `show_use_seriesid` | Bool | false | SeriesID(Channel). |
| `show_use_seriesid_all` | Bool | false | SeriesID(All); wins over `show_use_seriesid`. |
| `show_air_date` | [String] | `[]` | **Full English weekday names**, `"Sunday"`…`"Saturday"` (matched case-insensitively, unknown names ignored). Used by `.dateTime` for the schedule; informational for `.single`. |
| `show_channel` | String | `""` | Guide number as text (`"4.1"`, `"1002"`). |
| `show_time` | Number (Double) | **20.0** | **Local decimal hours 0-24** (`20.5` = 8:30 PM local). Minutes = `round(frac*60)`. DateTime only. |
| `show_length` | Int | **60** | **Minutes.** Fallback end = `show_next + show_length`. |
| `show_next` | ISO date, optional | omitted (nil) | Next air start (absolute instant). |
| `show_end` | ISO date, optional | omitted | End of the current/next airing, **including** Bonus Time padding once `startRecording` has applied it. |
| `show_active` | Bool | **true** | false only for a finished `.single`. |
| `show_paused` | Bool | false | See Show State Flags. |
| `hdhr_record` | String | `""` | Device ID (8 hex, uppercase, e.g. `"105404BE"`). |
| `show_url` | String | `""` | Tuner stream URL from the lineup (`http://ip:5004/auto/v4.1`); re-resolved when empty. |
| `show_seriesid` | String | `""` | Guide SeriesID. |
| `show_fail_count` / `show_fail_reason` | Int / String | 0 / `""` | Consecutive failures; last reason text (`"Tuner not detected"` is a reserved marker). |
| `show_logo_url` | String | `""` | Channel/show image URL. |
| `show_transcode` | String | `"none"` | `none|heavy|mobile|internet720|internet540|internet480|internet360|internet240`. |
| `show_recording` | Bool | false | Reset to false on every launch, then re-derived by `reattachRecordings()`. |
| `show_last` | ISO date, optional | omitted | Last completed recording. |
| `notify_upnext_time` / `notify_recording_time` | ISO date, optional | omitted | De-dupe markers for the two reminder notifications. |
| `show_dir` | String | `""` | Destination folder, POSIX (a legacy HFS `"Vol:Folder:"` string is converted at read time, see `toPosix`). Empty = `~/Movies/hdhr_videos`. |
| `show_temp_dir` | String | `""` | Local fallback folder when `show_dir`'s volume is offline; self-healed if equal to `show_dir`. |
| `show_recording_path` | String | `""` | Absolute path of the active/last recording file. |
| `show_genre` | String | `""` | First guide genre tag. |
| `show_bonus_time` | Bool | `Show.genreImpliesBonusTime(show_genre)` | Extend past `show_end` by `Sports_padding_minutes`. |
| `show_bonus_padded_end` | ISO date, optional | omitted | The padded `show_end` already applied (prevents double padding on relaunch). |
| `discord_start_msg_id` | String | `""` | Discord message id of the lifecycle embed. |
| `show_tuner_resource` | String | `""` | `"tuner0"` from `X-HDHomeRun-Resource`. |
| `show_ignore_duplicate_once` | Bool | false | Per-show override of skip-already-recorded. |
| `show_new_only` | Bool | false | Skip airings the guide does not flag as new. |

`Show.blank()` uses the same defaults (fresh `show_id`, `show_time 20.0`, `show_length 60`, `show_active true`, `show_transcode "none"`, everything else empty/false/nil). `Show.state` and `isSeries` are computed, never stored.

---

## Decode Resilience (`Show.init(from:)` / `ConfigFile.init(from:)`)

Every field in `Show.init(from:)` decodes via `try?` with a fallback default — including `show_id` (falls back to a fresh generated UUID, same format as `Show.blank()`). This matters because `ConfigFile.init(from:)`'s `shows` array decode is all-or-nothing: `(try? c.decode([Show].self, forKey: .shows)) ?? (try? … forKey: .the_shows) ?? []` — if decoding a single element in the array throws, the *entire* array decode throws and falls through to the next `try?`/eventually `[]`. Before `show_id` had a fallback, one show with a missing/corrupt `show_id` anywhere in the saved JSON would silently wipe every saved show on next launch. With every field now optional-with-fallback, a well-formed JSON array of show objects can no longer throw during decode.

If the `shows`/`the_shows` key *is* present in the config but the array still fails to decode entirely (a genuinely malformed structure, not just a missing field — e.g. the value isn't an array of objects at all), `ConfigFile.init` logs `[Config] shows array present but failed to decode — starting with an empty list; check config file for corruption` at `.error` before falling back to `[]`, so that failure mode is no longer silent.

---

## Show Output Path

`Show.outputPath(date:)` builds the recording file path. The `DateFormatter` used for the timestamp suffix (`outputDateFormatter`) is a `private static let` — allocated once per app session, not on every recording start.

**Extension is always `.ts`** regardless of transcode profile. The recorder writes the device's HTTP response verbatim (`curl -o`, no remux), and that response is always an MPEG-2 transport stream — transcoding only swaps the video codec inside the TS (MPEG-2 → H.264), not the container (see `docs/HDHRFindings.md`). `Show.recordingExtensions = {ts, m2ts, mkv}` and `Show.isRecordingFile(_:)` are the single source of truth for "is this a file we produced": `.ts` is current output, `.m2ts`/`.mkv` are legacy (pre-2026-07) and stay recognized so old recordings still count for `recordedEpisodeTags` (skip-already-recorded) and `organizeSeriesRecordings`. `.mp4` is deliberately excluded — the app never wrote it.


### File name scheme

`Show.outputPath(date:subfolder:episodeTag:)` returns `<posixRecordDir>[/<subfolder>]/<title><_EPISODETAG>_<channel>_<yyyyMMdd_HHmm>.ts`:

- `<title>` = `show_title` with `/` replaced by `-`, leading `.` characters stripped (no hidden/`.`/`..` names); empty becomes `Recording`. Trimmed (whole characters) so the whole file name stays <= 255 UTF-8 bytes.
- `<_EPISODETAG>` = `"_" + episodeTag` (the guide's `EpisodeNumber`, e.g. `S03E18`, or a bare season `S03`) and is **omitted entirely** when there is no tag. The tag is only passed for series shows when `Series_subfolder_enabled` is on, so the tag sits between title and channel, each part joined by `_`.
- `<channel>` = `show_channel` verbatim (`4.1`). Date part = `show_next` (else now), formatter `yyyyMMdd_HHmm`, `en_US_POSIX`, **local time zone**.
- Example: `Jeopardy_S41E112_4.1_20261022_1900.ts`; no tag: `Local News_4.1_20261022_1800.ts`.
- `subfolder` (series + `Series_subfolder_enabled`): `<title>/Season NN` (`NN` = zero-padded `%02d` season from the tag; `<title>` has `/` -> `-`), or just `<title>` when no parseable season.
- `AppState.uniqueRecordingPath` then avoids overwriting a non-empty file from an earlier attempt of the same airing by inserting `_part2`..`_part99` before `.ts`.

### Parsing the tag back out (`HDR_EPISODE`, skip-already-recorded)

Three readers, deliberately different:

| Reader | Regex (case-insensitive) | Notes |
|---|---|---|
| `AppState.episodeTag(inFilename:)` (organize + `recordedEpisodeTags`) | `[_ ](S\d+(?:E\d+)?)` | Leading `_` or space required, **no trailing delimiter required**; accepts legacy `Title SxxExx guests_…` names. Returned as found; callers uppercase it. |
| Post-recording script env `HDHR_EPISODE` (`runPostRecordingScript`) | `_(S\d+(?:E\d+)?)_` | **Requires both a leading and a trailing underscore** (which `outputPath` always produces: `_S03E18_4.1_…`); the underscores are trimmed. Empty string when the file has no tag. |
| Duplicate gate (`duplicateEpisodeTag`, startRecording) | `^S\d+E\d+$` on the *guide's* tag | Needs a full season+episode tag; a bare `S03` never counts as a duplicate. |

### Size floors (what counts as "already recorded")

`recordedEpisodeTags(forTitle:baseDir:expectedMinutes:...)` scans `<baseDir>/<title>` and its `Season *` children for recording files (`.ts/.m2ts/.mkv`) and ignores a file smaller than `minBytes = max(durationFloor, 0.8 x largest sibling file with a tag)`:

- `durationFloor = max(1_000_000, Int(expectedMinutes x 1_500_000/8 x 60 x 0.8))` -> i.e. 1.5 Mbps = 11,250,000 bytes/min, x0.8; `expectedMinutes` = the show's `show_length` (0 = flat 1,000,000-byte floor).
- Smaller files are skipped (never counted); with `renameTruncatedTag` a truncated file for that tag is renamed to `.partial`. Files modified within 120 s before this airing's start (`ownAirStart - 120 s`) are this airing's own earlier attempts: excluded, and deleted if 0 bytes.

### `Show.seriesTitle(from:)`

Strips the first match of `\s+S\d+E\d+.*$` (case-insensitive) and everything after it: `"South Park S24E116 Trey Parker; Matt Stone"` -> `"South Park"`. Needs whitespace before `S`, digits, `E`, digits - so a bare `S03` or a title with no episode tag is returned unchanged. Applied to SeriesID shows only (Single/DateTime keep the raw title). The result is trimmed only by the regex's own whitespace consumption (no extra trim). `GuideEntry.seriesTitle` caches the same value for title matching.

### `Show.toPosix` (legacy HFS paths)

Applied to `show_dir`/`show_temp_dir` at read time (`posixPrimaryDir`/`posixRecordDir`), never written back: if the string already starts with `/` **or contains no `:`** it is returned unchanged; otherwise one trailing `:` is dropped, the rest is split on `:` (empty components kept) and rejoined with `/` under a `/Volumes/` prefix. `"Raid6:DVR Tests:"` -> `/Volumes/Raid6/DVR Tests`. So the first component is always treated as a volume name (the boot volume `Macintosh HD:Users:x` becomes `/Volumes/Macintosh HD/Users/x`, which is a symlink to `/` and resolves).

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
- `episodeInfoLabel: String?` — computed property; joins `EpisodeNumber` and `EpisodeTitle` with `" · "`, returning `nil` when both are absent or empty. Used in WatchNowView and AddShowView summary panels.
- `deviceId: String` (default `""`) — **not in JSON; excluded from `CodingKeys`**. Stamped by `GuideStore.prepareIndex` from the owning device's `DeviceID` so the device identity travels with the entry.
- `channelNum: String` (default `""`) — **not in JSON; excluded from `CodingKeys`**. Stamped by `GuideStore.prepareIndex` alongside `deviceId` so managed-show slot keys can be built from the entry alone.

---

## GuideChannel Notable Fields

- `Affiliate: String?` — network name (e.g. `"NBC"`). Populated in XMLTV mode from the last `<display-name>` element. In JSON mode (`guide.php`) this field is present in the server response and decoded directly.

---

## ManagedGuideMatcher

`struct ManagedGuideMatcher: Equatable` in `Models.swift` is the **single source of truth** for managed-show identification *and* ownership. Used by WebServer to flag managed shows in the guide HTML and to embed the owning show's config for the edit modal. Callers pass `activeManagedShows` once at construction; then call `owner(for:)` per block (`isManaged(entry:)` is a thin `owner(for:) != nil` wrapper kept for call sites that only need the boolean).

```swift
struct ManagedGuideMatcher: Equatable {
    let seriesKeys:      [String: Show]   // "device:channel:SeriesID" (seriesChannel) or "device:SeriesID" (seriesAll) → owner
    let seriesTitles:    [String: Show]   // same scope split, title-keyed fallback (no SeriesID) → owner
    let singleSlotKeys:  [String: Show]   // "device:channel:epoch" → owner — single shows, exact slot
    let datetimeSlotKeys: [String: Show]  // "device:channel:Weekday:HH:MM" → owner — dateTime shows, per allowed day

    init(activeManagedShows: [Show])

    // Reads entry.deviceId and entry.channelNum directly — no caller-supplied args.
    func owner(for entry: GuideEntry) -> Show?
    func isManaged(entry: GuideEntry) -> Bool
}
```

Values are the owning `Show`, not just presence — this is what lets `WebServer.swift` embed a managed block's `data-show-*` edit attributes directly from `owner(for:)` instead of maintaining a second, independently-derived owner lookup (a prior `findManagedShow` helper there did exactly that, and being built differently — no title fallback for series shows — could disagree with the flag about whether a block had a resolvable owner; see `docs/WebServer.md`'s "Managed show data attributes" section).

`seriesAll` and `seriesChannel` shows are both confined to their assigned tuner (`hdhr_record`), so a series show can never match/mark on more than one tuner at once — but as of 2026-08-15 they key differently within `seriesKeys`/`seriesTitles`, not just scheduling differently: `seriesAll` is keyed device-only (`"device:SeriesID"`/`"device:title"`) and matches any channel on that tuner, since it's meant to follow the series across channels (reruns/affiliates often shift channels). `seriesChannel` is keyed device-*and-channel* (`"device:channel:SeriesID"`/`"device:channel:title"`) and matches only the one channel it was added from — a same-series rerun on a different channel on the same tuner does not badge as managed. Both key shapes share the same two dictionaries rather than needing separate ones: a 3-segment key and a 2-segment key can never collide as strings (device/channel/SeriesID never themselves contain `:`), so `owner(for:)` just tries the channel-scoped shape first, then the device-only shape — each dictionary naturally only holds entries whose keys look that way, with no need to track which type produced which entry. This mirrors *scheduling* channel scope exactly (which channel(s) `AppState.resolveSeriesAir`/`nextGuideEpisode`/`scheduleNextAir` search for the next episode) — see CLAUDE.md's "Web guide managed markers are tuner-scoped, and channel-scoped for `seriesChannel`" invariant. (Before this, both types shared the same device-only keys, so a `seriesChannel` show's badge could appear on a channel it would never actually record from — see `issues_resolved.md`. Before that, `seriesAll` used bare, device-agnostic keys and could match/mark on every tuner — also `issues_resolved.md`.)

Matching tiers (in order — `owner(for:)` returns the first match, `isManaged` is `owner(for:) != nil`):
1. `"device:channel:SeriesID"` in `seriesKeys` → managed (seriesChannel: own channel only)
2. `"device:SeriesID"` in `seriesKeys` → managed (seriesAll: any channel on the device)
3. `"device:channel:title"` in `seriesTitles` → managed (seriesChannel, no SeriesID)
4. `"device:title"` in `seriesTitles` → managed (seriesAll, no SeriesID)
5. `"device:channel:Weekday:HH:MM"` local-time key in `datetimeSlotKeys` → managed (dateTime shows: only on allowed weekdays)
6. `"device:channel:epoch"` key in `singleSlotKeys` → managed (single shows: exact scheduled slot only)

Tiers 5–6 (the `Calendar.current.dateComponents` call and everything after) are skipped entirely via an early return when both `datetimeSlotKeys` and `singleSlotKeys` are empty — the common case for a guide with only SeriesID-managed shows, and otherwise this ran for every non-managed entry in the grid (the majority of entries) on every rebuild.

All four dictionaries keep the *first* match on a key collision (e.g. two shows sharing a SeriesID on the same device, or two shows landing on the identical slot key) rather than trapping or silently overwriting — matching the tolerant dedup a plain `Set` gave before switching from presence-only keys to key→owner maps. `seriesKeys`/`seriesTitles` get this via `Dictionary(_:uniquingKeysWith: { a, _ in a })`; `singleSlotKeys`/`datetimeSlotKeys` are built with a manual loop (`if dict[key] == nil { dict[key] = s }`) since they're populated incrementally per allowed air-day rather than from a single flat mapping, but the collision behavior is the same first-wins semantics.

`dateTime` shows emit one key per entry in `show_air_date` (e.g. a Wednesday-only show at 4:30 PM local emits only `"device:4.3:Wednesday:16:30"`). A Friday airing of that show at 4:30 PM looks for `"device:4.3:Friday:16:30"` and finds nothing — no yellow diamond. If `show_air_date` is empty, keys are emitted for all 7 days. `single` shows use the epoch so only the specific airing is flagged.

Paused shows are excluded from `activeManagedShows` by all callers — the yellow/red flag only appears for active scheduled shows.

---

## HDHRDevice Computed Properties

- `lineupURL` — always `"http://{LocalIP}/lineup.json"`. The `LineupURL` field from discover.json is not stored (may contain `hdhomerun.local` which fails on unreliable networks).
- `statusURL` — `"http://{LocalIP}/status.json"` — live tuner status endpoint.
- `supportsTranscode` (added 2026-08-28) — `(ModelNumber ?? "").hasPrefix("HDTC")`. The real per-device
  `Transcode` capability field only exists on a CGNAT-unsafe cloud endpoint (`docs/HDHRFindings.md`'s
  "Transcode capability" section) — never called. `ModelNumber`'s `"HDTC"` prefix (EXTEND/PLUS-tier
  devices) is the safe local proxy `AppState.startRecording` gates on before ever attempting a
  non-`"none"` transcode profile. Nil `ModelNumber` (e.g. a UDP-only-discovered device — the UDP
  discovery reply has no `ModelNumber` TLV, so `HDHRManager.swift`'s manual `HDHRDevice(...)`
  construction there leaves it at its default `nil`) is treated as unsupported — the conservative
  default, since a recording that never attempts an unverified profile beats one that fails and
  retries.

`ModelNumber: String?` (e.g. `"HDTC-2US"`) is decoded like every other optional field here (`try?`
in `HDHRDevice`'s custom `init(from:)`) from all three JSON-decoding discovery paths in
`HDHRManager.swift` (`fetchDeviceInfo`, `mDNSDiscover`, `cloudDiscover`) — only the manual UDP-reply
construction doesn't populate it, per above.

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

## Show titles from untrusted sources (`String.sanitizedShowTitle`)

A show title that arrives over the web API is cleaned by `sanitizedShowTitle` (`Models.swift`): control characters removed, trimmed, capped at 120 characters (a file name is title + date + tag inside a 255-byte limit) and leading dots stripped so `.`/`..` can't act as a path component. It is applied in `/api/record` and `/api/edit` and to the series folder name used when organizing recordings into `Title/Season NN`; it may return `""` (the record path then falls back to the guide entry's own title).

## Logging (`glog`)

Global free function in `Models.swift`:

```swift
func glog(_ msg: String, level: LogLevel = .info)
// LogLevel: .info ("INFO"), .warning ("WARN"), .error ("ERROR")
```

Writes to **both** OSLog (subsystem `com.hdhr.vcrplus`, category `app`) and the app log file.

**Secrets are masked before they're written** (`redactingSecrets`, applied inside `glog` and `discordLog`): any `DeviceAuth=<value>` (a live SiliconDust cloud bearer token) and, since 2026-10-09, the token in a Discord webhook URL (`…/webhooks/<id>/<token>` → `…/REDACTED`, `redactingWebhookTokens`) — a failed send's `URLError` embeds the full URL, and these logs are the ones users are asked to share. Older lines already on disk are not rewritten.

Log file: `~/Library/Logs/hdhrVCRplus.log`  
Format: `[2026-05-25T04:01:24Z] [INFO] message`

`logFilePath` is a module-level `let` constant. Writes are dispatched onto a serial `logQueue` (`DispatchQueue`, `.utility` QoS) onto a shared `RotatingLogFile` instance, which keeps a single `FileHandle` open across calls — no open/close overhead per write. Safe to call from any actor or thread. All source files use `glog`; no `print()` calls anywhere.

**Rotation**: `RotatingLogFile` (also in `Models.swift`) caps `logFilePath` at 20 MB — sized off the file's measured real-world rate (~1.2 MB/day, ~11,700 `glog()` lines/day), giving roughly 2.5 weeks live plus 2.5 weeks in a kept prior generation. On hitting the cap it closes the handle, moves the current file to `hdhrVCRplus.log.1` (overwriting any existing one), and reopens fresh at `logFilePath`. `bytesWritten` only advances when `handle` is non-nil — i.e. only for bytes that actually made it to disk — so a transient `open()` failure (full disk, brief permissions issue) can't trigger a phantom rotation against a file that never grew. `discordLog()` (`DiscordNotifier.swift`) uses the same class against `hdhrVCRplus-discord.log` with its own smaller 5 MB cap (that file runs at ~1% of the main log's volume).

`RecordingManager`'s verbose-curl-logging feature targets its own separate file, `curlVerboseLogFilePath` (`hdhrVCRplus-curl.log`, 5 MB cap), via a raw `posix_spawn` file descriptor for curl's own `-v` stderr — independent of `glog()`'s queue and of `RotatingLogFile` entirely, since curl's direct-fd writes are invisible to that class's byte counter. Capped instead by `rotateCurlVerboseLogIfNeeded()` (also in `Models.swift`), which stats the file and renames it (not truncates) once per verbose recording start rather than per line — see `docs/RecordingManager.md`'s "Verbose curl Logging" section for the full mechanism and why this file used to (incorrectly) share `logFilePath`.
