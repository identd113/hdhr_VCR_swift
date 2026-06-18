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
func nextEpisode(seriesID: String, channelNum: String?, deviceId: String?, after: Date) -> SeriesMatch?
func nextEpisodes(seriesID: String, after: Date, limit: Int) -> [SeriesMatch]
func isFresh(deviceId: String, within interval: TimeInterval) -> Bool  // default 1 hour
func invalidate(deviceId: String)
func invalidateAll()
```

---

## Lazy Series Sort

`buildIndex` appends entries into `seriesIndex` but does **not** sort them — it marks affected series in `unsortedSeries` instead. `sortIfNeeded(_:)` is called at the top of `nextEpisode`, `nextEpisodes`, and `currentEpisode`; it sorts only the queried series on first access, then removes it from `unsortedSeries`. This defers the O(series × entries log entries) sort cost from guide-load time (main-actor, synchronous) to first-query time (typically spread across the first idle-loop `rebuildMenuEntries` call after load).

`invalidate(deviceId:)` prunes `unsortedSeries` to only entries still in `seriesIndex`. `invalidateAll()` clears it entirely.

---

## Entry Stamping

`buildIndex` stamps two non-Codable fields on every `GuideEntry` after sorting:

- `entry.deviceId` — set to the owning device's `DeviceID`
- `entry.channelNum` — set to the channel's `GuideNumber`

These fields are excluded from JSON (`CodingKeys` omits them) and are purely in-memory. They allow `ManagedGuideMatcher.isManaged(entry:)` to build device+channel+slot keys from the entry alone, without callers threading device and channel strings through every call site.

---

## Freshness

`isFresh(deviceId:within:)` compares `loadTimestamps[deviceId]` against `Date()`. The idle loop calls this before scheduling a series episode; if stale, it reloads before searching for the next airing. `AddShowView` and `FloatingGuideView` call `invalidate` on Refresh button tap to force a reload regardless of freshness.
