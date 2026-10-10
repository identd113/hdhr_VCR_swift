# GuideStore.swift — Guide Cache

Single source of truth for all guide data. `AppState` holds `let guideStore = GuideStore()` and mirrors channel data into `@Published var guideByDevice` after each load.

All methods run on `@MainActor`, with one deliberate exception: `prepareIndex(deviceId:channels:)` (see "Fetch → Index Pipeline" below) is `nonisolated static` and runs off the actor, specifically so a large guide decode/sort doesn't block the actor that also serves WebServer requests. Network calls yield the actor during I/O; state is only written after the response arrives.

---

## URL Building

`guideURL(for:hours:)` — `Duration` parameter is in **hours** (not seconds):
- **EXTEND / cloud** (DeviceAuth present): `https://api.hdhomerun.com/api/guide.php?DeviceAuth=...&Start={epoch}&Duration=N`
- **Local device**: `http://{LocalIP}/guide.json?Start={epoch}&Duration=N`

`Start` is set to `now - 3600` so the current hour's programs are included even when called mid-hour. `N` is `hours + 1`, not the raw `hours` value — one hour of padding to preserve the configured future window despite the earlier start.

Returns `nil` if neither DeviceAuth nor LocalIP is available (logs a diagnostic).

`load()` makes a single call per device, so it is structurally capped at the cloud API's ~29h per-call window regardless of `Duration` (see `docs/HDHRFindings.md`'s "Per-call window cap" — pagination would be required to genuinely exceed it, not currently implemented). `AppConfig`'s `GuideHours` setting is clamped to `1...28` (Settings UI range, and `min(28, …)` on decode of an old saved value) to keep the requested window inside that cap — previously the UI allowed up to 48, silently exceeding it with no truncation signal.

`xmltvURL(for:)` — XMLTV cloud endpoint, no Start/Duration parameters (server controls the window). Returns `nil` if the device has no `DeviceAuth` (XMLTV is cloud-only; local devices use JSON regardless of the format flag).

---

## Internal Indexes

| Index | Key | Value |
|---|---|---|
| `channelsByDevice` | `deviceId` | `[GuideChannel]` — mirrored into `AppState.guideByDevice`; Guide arrays are pre-sorted by `StartTime` by `prepareIndex` (see "Fetch → Index Pipeline" below); each entry has `deviceId` and `channelNum` stamped on it |
| `channelEntryIndex` | `"deviceId:channelNum"` | `[GuideEntry]` sorted by `StartTime` |
| `seriesIndex` | `seriesID` | `[SeriesMatch]` sorted by `StartTime` (lazily — sorted on first query per series, not at build time); each carries `deviceId`, `channelNum`, `entry` |
| `unsortedSeries` | — | `Set<String>` of series IDs needing sort on next `nextEpisode`/`nextEpisodes`/`currentEpisode` call |

---

## Key Methods

```swift
func load(for device: HDHRDevice, hours: Int, useXML: Bool = false, maxCacheAge: TimeInterval? = nil)    // a second caller for a device whose load is in flight JOINS it and gets its real result (no more "false" = spurious failure; `inFlightLoads`); fetch + index one device; useXML routes to XMLTV endpoint if DeviceAuth present; maxCacheAge (nil = always network) lets a recent on-disk copy stand in — see "On-disk guide cache"
func loadAll(devices: [HDHRDevice], hours: Int, useXML: Bool = false, maxCacheAge: TimeInterval? = nil)  // parallel load for all devices
func channels(deviceId: String) -> [GuideChannel]
func entries(deviceId: String, channelNum: String, after: Date) -> [GuideEntry]
func nextEpisode(seriesID: String, channelNum: String?, deviceId: String?, after: Date, preferUnrecorded: ((GuideEntry) -> Bool)?, preferFavorite: ((String, String) -> Bool)?) -> SeriesMatch?
func currentEpisode(seriesID: String, channelNum: String?, deviceId: String?, at: Date, preferUnrecorded: ((GuideEntry) -> Bool)?, preferFavorite: ((String, String) -> Bool)?) -> SeriesMatch?
func nextEpisodes(seriesID: String, channelNum: String? = nil, deviceId: String? = nil, after: Date, limit: Int) -> [SeriesMatch]
func currentEntryByTitle(_ title: String, channelNum: String? = nil, deviceId: String? = nil, at: Date = Date(), preferUnrecorded: ((GuideEntry) -> Bool)? = nil, preferFavorite: ((String, String) -> Bool)? = nil) -> SeriesMatch?  // SeriesID-missing fallback, matches by title instead
func nextEntryByTitle(_ title: String, channelNum: String? = nil, deviceId: String? = nil, after: Date = Date(), preferUnrecorded: ((GuideEntry) -> Bool)? = nil, preferFavorite: ((String, String) -> Bool)? = nil) -> SeriesMatch?  // same fallback, for the next airing
func isFresh(deviceId: String, within interval: TimeInterval) -> Bool  // default 1 hour
func isLoading(deviceId: String) -> Bool
func invalidateAll()
func needsRecovery(deviceId: String) -> Bool   // no guide in memory, OR the last fetch failed (what is showing may be a saved copy)
var lastFailure: [String: LoadFailure]         // why each device's last fetch failed; cleared by a successful network fetch
static func classify(_ error: Error) -> LoadFailure   // NSURLError TLS/certificate codes → .certificate(reason); else .network
```

`load()` logs: URL fetched, HTTP status + byte count + ms, channel count + total entry count, and a warning if all channels have zero entries. On parse failure the full raw response (up to 2000 chars) is logged at `.error`. No verbose/debug mode — there is no `verbose` flag.

## Fetch → Index Pipeline

`fetchAndIndex(id:url:parse:)` (the shared scaffolding behind `load()`/`loadXMLTV()`) splits the actual indexing work into two functions, added 2026-09-20 specifically to keep a large guide decode/sort off the main actor:

- **`prepareIndex(deviceId:channels:)`** — `nonisolated static`, pure. Sorts each channel's `Guide` array by `StartTime`, stamps `deviceId`/`channelNum` on every entry (see "Entry Stamping" below), and builds this device's own slice of `channelEntryIndex`/`seriesIndex` entries into a plain `PreparedIndex` value. Touches no `GuideStore` instance state, so it's safe to run inside `Task.detached` — which is exactly what `fetchAndIndex` does, after the JSON/XMLTV `parse` closure runs, so the CPU-heavy decode+sort for a payload that can be ~1.4MB/~2500 entries never blocks the actor that also serves nearly every `WebServer` request.
- **`applyIndex(_:)`** — instance method, `@MainActor`. Takes the `PreparedIndex` from the background task and does the actual merge: prunes this device's stale entries from `channelEntryIndex`/`seriesIndex`, then writes in the fresh ones and assigns `channelsByDevice[deviceId]`. Cheap (dictionary inserts over one device's own entries) compared to the sort/decode that already happened, so it's fine to run on the actor.

**`buildIndex(deviceId:channels:)` still exists but is off the live fetch path** — it's now just `applyIndex(Self.prepareIndex(deviceId: deviceId, channels: channels))`, kept as a synchronous, single-call convenience specifically for tests that want to seed guide data directly (see its own doc comment — `SnapshotTests.swift`'s `watchNowOnAir` case is the reason it's `internal`, not `private`). Production loads (`fetchAndIndex`, and therefore every `load()`/`loadXMLTV()`/`loadAll()` call) go through `prepareIndex`/`applyIndex` directly, not through `buildIndex`. Any reference elsewhere in the docs to "`buildIndex` stamps/sorts/atomically replaces…" describing the *live* guide-refresh path should be read as `prepareIndex`+`applyIndex` together — `buildIndex` the symbol is only still exercised by tests.

---

`currentEntryByTitle`/`nextEntryByTitle` compare `Show.seriesTitle(from: $0.Title) == title`, not raw equality — `title` is the stored `show_title`, which for a series show has already had any episode-specific suffix stripped by `Show.seriesTitle(from:)` (see `docs/AddShowView.md`'s `save()` entry), but an individual guide entry missing SeriesID can still carry that suffix on its raw `Title`. Stripping `entry.Title` the same way before comparing keeps both sides in series-name-only form — an exact `$0.Title == title` would otherwise never match once the stored title is stripped.

`channelNum`/`deviceId` are applied *independently*, like `currentEpisode`/`nextEpisode` — each defaults `nil` to mean "any," and only a genuinely non-nil pair takes the fast per-channel `"deviceId:channelNum"` bucket lookup (`channelEntryIndex[...]`); any other combination (both `nil`, or just one set) falls through to a scan of `titleFallbackScanKeys(deviceId:)` (private) — that device's channels in lineup order, or every known device (sorted by ID, each in its own lineup order) when `deviceId` is also `nil` — filtering on each matching `GuideEntry`'s own stamped `deviceId`/`channelNum` fields only for whichever side was actually supplied. This matters for SeriesID(All) shows, which pass a fixed `deviceId` (their one assigned tuner) but `channelNum: nil` (any channel on it) — an earlier version only applied either filter when *both* were non-nil, which would have silently ignored `deviceId` entirely for that combination and scanned every device instead of just the assigned one. `titleFallbackScanKeys` exists specifically for determinism: an earlier version scanned `channelEntryIndex.values.flatMap` directly — dictionary iteration order, which can reorder across guide rebuilds — so a multi-channel simulcast tie (e.g. "Local News" airing on two channels of one tuner) could silently pick a different channel on different guide reloads; `currentEntryByTitle` also gained a `preferUnrecorded`/`preferFavorite` tie-break (checked across every candidate for `currentEntryByTitle`, since all are inherently concurrent; narrowed to the StartTime-tied prefix first for `nextEntryByTitle`) mirroring `currentEpisode`/`nextEpisode`'s own — see `issues_resolved.md`'s "`GuideStore.currentEntryByTitle`/`nextEntryByTitle` picked a non-deterministic channel" entry.

`nextEpisodes` gained the same `channelNum`/`deviceId` filter pair 2026-08-20 (both default `nil`, unfiltered — the original signature's behavior). `AppState.rebuildMenuEntries()`'s `menuUpcomingSlots` computation passes the show's own `channelNum`/`hdhr_record` so the menu bar's "Upcoming" preview can't surface a same-SeriesID airing that belongs to a *different* device — before this, a SeriesID shared across two HDHomeRuns could leak an unrelated device's slot into a show's own preview, unlabeled. `AppState.upcomingGuideEpisodes(seriesID:)` (→ `/api/airings/{seriesId}`, `AddShowView`'s "Other Upcoming Airings") deliberately keeps calling it unfiltered — that preview is meant to span every device, and labels each result with `device` in its output. The `(channelNum, StartTime)` dedup below only matters for that unfiltered case; a device-scoped call can't have more than one match per `(channelNum, StartTime)` to begin with.

---

## Lazy Series Sort

`applyIndex(_:)` appends entries into `seriesIndex` but does **not** sort them — it marks affected series in `unsortedSeries` instead. `sortIfNeeded(_:)` is called at the top of `nextEpisode`, `nextEpisodes`, and `currentEpisode`; it sorts only the queried series on first access, then removes it from `unsortedSeries`. This defers the O(series × entries log entries) sort cost from guide-load time (main-actor, synchronous) to first-query time (typically spread across the first idle-loop `rebuildMenuEntries` call after load).

`invalidateAll()` clears `unsortedSeries` entirely. (A prior `invalidate(deviceId:)` did the equivalent per-device prune, but was removed as dead code — it had no production call sites, only `invalidateAll()` is used.)

---

## Multi-Channel Tie-Break: Unrecorded, then Favorite

A SeriesID(All) show can have candidates airing on multiple channels of one device at the identical time — either the *same* episode (simulcast, or a rerun scheduled to overlap) or, on a multi-tuner device, genuinely *different* episodes of the same series airing concurrently on two channels. `seriesIndex[seriesID]` is sorted by `StartTime` only (stable sort) — with neither tie-break closure supplied, `.first` on a tie resolves to whichever channel happened to be inserted first while `prepareIndex` walked that device's guide-fetch response, which is incidental, not a deliberate preference.

`nextEpisode`/`currentEpisode` accept two optional tie-break closures, checked in this order — but the two functions now diverge on the "all candidates are already recorded" case (2026-08-19, closing a tight reschedule loop — see `issues_resolved.md`):

1. **`preferUnrecorded: (GuideEntry) -> Bool`** — returns `true` for a candidate that is *not* already on disk. Among the tied candidates, if exactly one (or more, for `currentEpisode`) satisfies this, that/those win outright, before favorite status is even considered: a duplicate on a favorited channel still loses to a fresh episode elsewhere.
   - **`nextEpisode`**: if the closure doesn't distinguish the tied set at all (every candidate recorded, or every candidate unrecorded — no information either way), falls through to step 2 including `first`. This is deliberate — a *future* candidate's duplicate status can still change before it actually airs, so `nextEpisode` always returns something and lets the real check happen at record time.
   - **`currentEpisode`**: if **every** currently-airing candidate is already recorded, returns `nil` instead of falling through — this is a stable, already-known-now fact (unlike a future candidate), and returning `first` here would have callers (`scheduleNextAir`) re-select the exact same on-air duplicate on every reschedule, spinning a tight retry loop for the rest of its broadcast window. With 2+ unrecorded candidates among 3+ airing at once, step 2 below only searches the unrecorded subset, not all candidates — a duplicate can never win a tie purely by sorting first with nothing favorited.
2. **`preferFavorite: (deviceId, channelNum) -> Bool`** — same as before: `nextEpisode` narrows to the candidates sharing the earliest StartTime as `first` (`prefix(while:)`) and returns the first one the closure marks favorite, falling back to `first` if none are; `currentEpisode` searches all currently-airing candidates the same way (no StartTime narrowing needed — the "currently airing" filter already scopes them to the tie), or just the unrecorded subset per the bullet above when step 1 found 2+ unrecorded candidates.

`AppState.resolveSeriesAir` and `AppState.scheduleNextAir` — the two places that actually decide which channel a SeriesID show records — pass `AppState.preferUnrecordedEpisode(for:)` (wraps the same on-disk check `duplicateEpisodeTag(title:episodeTag:baseDir:)` uses at record time, so this can never disagree with whether the episode would actually be skipped as a duplicate; returns `nil` — no preference — when `show_ignore_duplicate_once` is set) and `AppState.isFavoriteChannel(deviceId:channelNum:)` (looks up `LineupEntry.isFavorite` in `lineups`) as these two closures. Other `nextEpisode` callers (`nextGuideEpisode(for:)`, the menu's scheduled-entry lookup) are display-only and don't pass either — they don't decide what records, so an incidental tie there doesn't change behavior.

---

## Entry Stamping

`prepareIndex` stamps two non-Codable fields on every `GuideEntry` after sorting:

- `entry.deviceId` — set to the owning device's `DeviceID`
- `entry.channelNum` — set to the channel's `GuideNumber`

These fields are excluded from JSON (`CodingKeys` omits them) and are purely in-memory. They allow `ManagedGuideMatcher.isManaged(entry:)` to build device+channel+slot keys from the entry alone, without callers threading device and channel strings through every call site.

---

## Freshness

`isFresh(deviceId:within:)` compares `loadTimestamps[deviceId]` against `Date()`. The idle loop calls this before scheduling a series episode; if stale, it reloads before searching for the next airing.

The only invalidation in use is `invalidateAll()` — a per-device `invalidate(deviceId:)` used to exist but was removed as dead code (no production call sites; nothing currently forces a single device's cache stale independently). `invalidateAll()` is called from `SettingsView` when guide-affecting settings change (e.g. `GuideHours`, format) or the user triggers a manual rescan — an explicit, user-initiated action where an immediate wipe-then-reload is expected. `AppState.refreshGuides()` (the silent automatic periodic refresh — cadence is `AppState.effectiveGuideRefreshIntervalSeconds`-derived, not hourly, see `docs/AppState.md`'s idle-loop entry) deliberately does **not** call it — see `docs/AppState.md`'s `refreshGuides()` entry for why (a prior version did, and it raced with anything reading the guide store during the refresh's own network fetch). `AddShowView` doesn't call into `GuideStore` directly — its guide step is a `WKWebView` wrapper embedding the LAN web guide (`localhost:{port}`), which reads guide state server-side via `WebServer.swift`, not through `GuideStore` calls from the view itself.

## On-disk guide cache (2026-10-04)

**Failure handling (2026-10-08/09).** A fetch that fails — network/TLS error, non-200, empty body, undecodable body — records *why* in `lastFailure[deviceId]` (`LoadFailure`: `.certificate(reason)`, `.network(description)`, `.http(status)`, `.badResponse`; AppState turns it into the user-facing alert, see `docs/AppState.md`'s `handleGuideLoadFailure`). A response that decodes to **zero channels** (an expired/rotated `DeviceAuth`, a cloud hiccup) is a failure too: it used to replace the device's guide with nothing and stamp it fresh, so nothing retried. `invalidateAll()` also clears `inFlightLoads` and bumps the epoch, and `load()`/`fetchAndIndex` release only *their own* `inFlightLoads`/`loadingDevices` entry (task identity / matching epoch) — otherwise a stale in-flight load shadowed the reload that followed a Settings change, reporting failure (and a false "Guide Load Failed") while the guide stayed empty. **Stale on-disk fallback:** when a fetch fails *and the device has no guide in memory* (a relaunch or deploy during an outage — 2026-10-09 SiliconDust's `*.hdhomerun.com` certificate expired and every `guide.php` call failed its TLS handshake), `applyDiskCache` loads the newest saved copy that still covers the present, up to `staleFallbackMaxAge` (36 h) old, however old it is otherwise, with a `guide refresh failed — using the on-disk copy from N min ago` warning; the failure is still reported (the call returns `false`, so the retry cadence continues) and `loadTimestamps` keeps the file's own age so `isFresh` stays false. A guide already in memory is never replaced by an older disk copy. `needsRecovery` stays true until a network fetch succeeds, which is what keeps AppState retrying on its backoff (see `ensureGuideLoaded`).

To keep the public guide API light, `GuideStore(diskCacheDir:)` (production: `<Application Support>/hdhrVCRplus/guide_cache/`, derived from `ConfigManager.supportDir` so tests' temp config dirs never touch the live cache) stores each successful fetch's raw response body as `<deviceId>-<json|xml>-<hours>h.guide` — written only after the body parsed and indexed. A load that passes `maxCacheAge` (only `AppState.performFetchAllGuides`, i.e. startup / the "no guide yet" retry / the first-run wizard, passes `GuideStore.startupCacheMaxAge` = 1 h) first tries that file: if its mtime is younger than the limit, it parses, **and** some entry still ends after now, it is indexed exactly like a network result (`loadTimestamps` = the file's mtime, log line `guide loaded from disk cache … no network call`); otherwise it falls through to the normal fetch. The periodic `refreshGuides()`, per-device retries, new-device probes and scheduling-time reloads pass no `maxCacheAge` and always hit the network. The file name carries kind + `GuideHours`, so changing the window or the XMLTV setting never reuses a differently-shaped response. The cache holds no `DeviceAuth`. A relaunch or deploy within the hour therefore costs zero `guide.php` calls.
