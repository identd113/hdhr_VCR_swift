# GuideStore.swift — Guide Cache

Single source of truth for all guide data. `AppState` holds `let guideStore = GuideStore()` and mirrors channel data into `@Published var guideByDevice` after each load.

All methods run on `@MainActor`. Network calls yield the actor during I/O; state is only written after the response arrives.

---

## URL Building

`guideURL(for:hours:)` — `Duration` parameter is in **hours** (not seconds):
- **EXTEND / cloud** (DeviceAuth present): `https://api.hdhomerun.com/api/guide.php?DeviceAuth=...&Start={epoch}&Duration=N`
- **Local device**: `http://{LocalIP}/guide.json?Start={epoch}&Duration=N`

`Start` is set to `now - 3600` so the current hour's programs are included even when called mid-hour.

Returns `nil` if neither DeviceAuth nor LocalIP is available (logs a diagnostic).

`load()` makes a single call per device, so it is structurally capped at the cloud API's ~29h per-call window regardless of `Duration` (see `docs/HDHRFindings.md`'s "Per-call window cap" — pagination would be required to genuinely exceed it, not currently implemented). `AppConfig`'s `GuideHours` setting is clamped to `1...28` (Settings UI range, and `min(28, …)` on decode of an old saved value) to keep the requested window inside that cap — previously the UI allowed up to 48, silently exceeding it with no truncation signal.

`xmltvURL(for:)` — XMLTV cloud endpoint, no Start/Duration parameters (server controls the window). Returns `nil` if the device has no `DeviceAuth` (XMLTV is cloud-only; local devices use JSON regardless of the format flag).

---

## Internal Indexes

| Index | Key | Value |
|---|---|---|
| `channelsByDevice` | `deviceId` | `[GuideChannel]` — mirrored into `AppState.guideByDevice`; Guide arrays are pre-sorted by `StartTime` by `buildIndex`; each entry has `deviceId` and `channelNum` stamped on it |
| `channelEntryIndex` | `"deviceId:channelNum"` | `[GuideEntry]` sorted by `StartTime` |
| `seriesIndex` | `seriesID` | `[SeriesMatch]` sorted by `StartTime` (lazily — sorted on first query per series, not at build time); each carries `deviceId`, `channelNum`, `entry` |
| `unsortedSeries` | — | `Set<String>` of series IDs needing sort on next `nextEpisode`/`nextEpisodes`/`currentEpisode` call |

---

## Key Methods

```swift
func load(for device: HDHRDevice, hours: Int, useXML: Bool = false)    // fetch + index one device; useXML routes to XMLTV endpoint if DeviceAuth present
func loadAll(devices: [HDHRDevice], hours: Int, useXML: Bool = false)  // parallel load for all devices
func channels(deviceId: String) -> [GuideChannel]
func entries(deviceId: String, channelNum: String, after: Date) -> [GuideEntry]
func nextEpisode(seriesID: String, channelNum: String?, deviceId: String?, after: Date, preferFavorite: ((String, String) -> Bool)?) -> SeriesMatch?
func currentEpisode(seriesID: String, channelNum: String?, deviceId: String?, at: Date, preferFavorite: ((String, String) -> Bool)?) -> SeriesMatch?
func nextEpisodes(seriesID: String, after: Date, limit: Int) -> [SeriesMatch]
func currentEntryByTitle(_ title: String, channelNum: String, deviceId: String, at: Date = Date()) -> SeriesMatch?  // SeriesID-missing fallback, matches by title instead
func nextEntryByTitle(_ title: String, channelNum: String, deviceId: String, after: Date = Date()) -> SeriesMatch?  // same fallback, for the next airing
func isFresh(deviceId: String, within interval: TimeInterval) -> Bool  // default 1 hour
func isLoading(deviceId: String) -> Bool
func invalidateAll()
```

`load()` logs: URL fetched, HTTP status + byte count + ms, channel count + total entry count, and a warning if all channels have zero entries. On parse failure the full raw response (up to 2000 chars) is logged at `.error`. No verbose/debug mode — there is no `verbose` flag.

---

## Lazy Series Sort

`buildIndex` appends entries into `seriesIndex` but does **not** sort them — it marks affected series in `unsortedSeries` instead. `sortIfNeeded(_:)` is called at the top of `nextEpisode`, `nextEpisodes`, and `currentEpisode`; it sorts only the queried series on first access, then removes it from `unsortedSeries`. This defers the O(series × entries log entries) sort cost from guide-load time (main-actor, synchronous) to first-query time (typically spread across the first idle-loop `rebuildMenuEntries` call after load).

`invalidateAll()` clears `unsortedSeries` entirely. (A prior `invalidate(deviceId:)` did the equivalent per-device prune, but was removed as dead code — it had no production call sites, only `invalidateAll()` is used.)

---

## Favorite-Channel Tie-Break

A SeriesID(All) show can have the *same* episode airing on multiple channels of one device at the identical time (simulcast, or a rerun scheduled to overlap). `seriesIndex[seriesID]` is sorted by `StartTime` only (stable sort) — with no `preferFavorite` closure, `.first` on a tie resolves to whichever channel happened to be inserted first while `buildIndex` walked that device's guide-fetch response, which is incidental, not a deliberate preference.

`nextEpisode`/`currentEpisode` accept an optional `preferFavorite: (deviceId, channelNum) -> Bool` closure. When supplied: `nextEpisode` narrows to the candidates sharing the earliest StartTime as `first` (`prefix(while:)`) and returns the first one the closure marks favorite, falling back to `first` if none are; `currentEpisode` searches all currently-airing candidates the same way (no StartTime narrowing needed — the "currently airing" filter already scopes them to the tie). `AppState.resolveSeriesAir` and `AppState.scheduleNextAir` — the two places that actually decide which channel a SeriesID show records — pass `AppState.isFavoriteChannel(deviceId:channelNum:)` (looks up `LineupEntry.isFavorite` in `lineups`) as this closure. Other `nextEpisode` callers (`nextGuideEpisode(for:)`, the menu's scheduled-entry lookup) are display-only and don't pass it — they don't decide what records, so an incidental tie there doesn't change behavior.

---

## Entry Stamping

`buildIndex` stamps two non-Codable fields on every `GuideEntry` after sorting:

- `entry.deviceId` — set to the owning device's `DeviceID`
- `entry.channelNum` — set to the channel's `GuideNumber`

These fields are excluded from JSON (`CodingKeys` omits them) and are purely in-memory. They allow `ManagedGuideMatcher.isManaged(entry:)` to build device+channel+slot keys from the entry alone, without callers threading device and channel strings through every call site.

---

## Freshness

`isFresh(deviceId:within:)` compares `loadTimestamps[deviceId]` against `Date()`. The idle loop calls this before scheduling a series episode; if stale, it reloads before searching for the next airing.

The only invalidation in use is `invalidateAll()` — a per-device `invalidate(deviceId:)` used to exist but was removed as dead code (no production call sites; nothing currently forces a single device's cache stale independently). `invalidateAll()` is called from `SettingsView` when guide-affecting settings change (e.g. `GuideHours`, format) or the user triggers a manual rescan — an explicit, user-initiated action where an immediate wipe-then-reload is expected. `AppState.refreshGuides()` (the silent automatic hourly refresh) deliberately does **not** call it — see `docs/AppState.md`'s `refreshGuides()` entry for why (a prior version did, and it raced with anything reading the guide store during the refresh's own network fetch). Neither `AddShowView` nor `FloatingGuideView` calls into `GuideStore` directly — `AddShowView`'s guide step and `FloatingGuideView` are both `WKWebView` wrappers embedding the LAN web guide (`localhost:{port}`), which reads guide state server-side via `WebServer.swift`, not through `GuideStore` calls from these views.
