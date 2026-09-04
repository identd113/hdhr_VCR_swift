# WebServer.swift — Built-in LAN Web Server

Serves an interactive guide page and JSON API over HTTP. The page is consumed by two clients: **external browsers** on the local network, and the **in-app WKWebView** in `AddShowView` step 2. Both connect to the same SSE stream and see the same HTML. Enabled via **Settings → Sharing → Enable Sharing** (the Settings section's user-facing label — the underlying `Web_server_enabled` config key and `WebServer.swift` itself are unchanged). Default port: **1980**.

The web server is primarily scoped to **scheduling and management**, with one narrow exception: `/api/watch-recording` relays a *currently-recording* show's on-disk file as an open-ended HTTP stream, powering the in-app "Watch Now!" relay (see below). It is not a general media server — finished recordings are not reachable through it.

---

## API surface

```swift
func start(port: Int, appState: AppState, onState: @escaping (String?) -> Void)
func stop(completion: (() -> Void)? = nil)  // completion, when given, fires once the listener's teardown is actually confirmed (its `.cancelled` state, bounded by a 2s fallback) rather than the instant this call returns — added for AppState.relaunchForVLC() (docs/AppState.md), which needs the OS to have genuinely released the port before launching a fresh instance of the app. Every other call site omits it and keeps the original synchronous, fire-and-forget behavior.
func updateTXTRecord()    // @MainActor — refreshes mDNS TXT record if it actually changed since the last call; called from idleLoop
func broadcastEvent(_:)   // pushes a JSON event to all open SSE clients
func broadcastRecordingEvent(type:channel:device:state:prebuiltGrid:refreshPageCache:)  // @MainActor — builds sumPh + the device's tdrop fragment and calls broadcastEvent, then (unless refreshPageCache is false) rebuilds and re-caches the full page HTML (prebuildPageHTML) so a fresh page load right after a recording starts/stops shows the correct .g-prog-rec/.g-st-rec marker instead of the pre-event snapshot. `prebuiltGrid` lets a caller that already built the grid (see broadcastRecordingStopped) reuse it instead of paying for buildGuideGridHTML again
func broadcastRecordingStopped(channel:device:state:alsoRebuildGrid:)  // @MainActor — pairs broadcastRecordingEvent("recording_stopped") with the paired broadcastGuideChangeEvent("recording_stopped") teardownRecordingState needs (see "Recording section" below), building the grid once and sharing it between both instead of each paying for its own buildGuideGridHTML pass. `alsoRebuildGrid: false` (deleteShow's use, when the show is about to be removed and re-broadcast anyway) skips the guide-change broadcast and its cache refresh entirely
func broadcastGuideChangeEvent(type:extra:state:prebuiltGrid:)  // @MainActor — builds grid + sumph + all tdrop fragments once (buildGuideRefreshPayload) and calls broadcastEvent, so connected clients apply the pushed HTML instead of each independently re-fetching /api/guide-refresh; also re-caches the full page HTML (prebuildPageHTML) with the same grid, so the next fresh page load reflects this change too. `prebuiltGrid` lets a caller that already built the grid (see refreshPageAndBroadcastGuideChange) reuse it
func broadcastDeviceBarEvent(type:deviceId:state:)  // @MainActor — builds #dev-bar's inner HTML (buildDevBarHTML) and calls broadcastEvent; used for deviceOnline/deviceOffline so the tuner-box row updates live instead of only on next page reload
func prebuildPageHTML(state:prebuiltGrid:)   // @MainActor — pre-renders and caches desktop + mobile HTML; called after fetchAllGuides / refreshGuides, and now also from broadcastRecordingEvent/broadcastGuideChangeEvent on every recording start/stop and guide-changing action, not just on a guide reload
func refreshPageAndBroadcastGuideChange(type:state:)  // @MainActor — thin wrapper around broadcastGuideChangeEvent (which now does its own grid build + cachedHTML rebuild); kept as a distinctly-named entry point for refreshGuides()'s hourly "guide_refreshed" call site
```

`onState` is called on `DispatchQueue.main`. `nil` = server is ready; non-nil = error string.

`stop()` nils the internal `stateCallback` before cancelling the listener so the `.cancelled` state handler does not surface as an error when stopping intentionally.

---

## Routes

| Method | Path | Response |
|---|---|---|
| GET | `/` or `/index.html` | Full guide HTML page |
| GET | `/favicon.ico` | Serves the bundled `favicon.ico` resource (`image/x-icon`) — a separate asset from `/api/icon`'s PNG, referenced by the page's `<link rel="shortcut icon">` so browser tabs get an icon |
| GET | `/api/ping` | `{"ok":true,"version":"260606-1155","release":"2.0.3","buildNumber":"20003"}` — health check + three separate version identifiers. `version` (the build stamp, `Version.swift`'s `appVersion`, regenerated on *every* deploy) is load-bearing — the page staleness checker (see "Page staleness" below) and the self-ping after bind both key off it. `release`/`buildNumber` are read from `Info.plist`'s `CFBundleShortVersionString`/`CFBundleVersion` — additive, informational only, nothing keys off them. Both are only ever set by `deploy_release.sh <version>`; a `deploy.sh` dev build leaves them at whatever the last release left behind, so they answer "which release is this based on," not "is this the exact build running right now" (that's what `version` is for). |
| GET | `/api/events` | SSE stream — kept open; server pushes JSON events on state changes |
| GET | `/api/guide-refresh` | JSON `{grid, sumph, tdrop}`, always plain (uncompressed) — full rebuilt guide grid + summary panel + per-device tuner-dropdown fragments, the same `buildGuideRefreshPayload` an SSE guide-change event's `grid`/`gridZ` also comes from. A normal `.ok` HTTP response, so it's still transparently gzip'd/decompressed at the transport level by `fetch()` when the client's `Accept-Encoding` allows it — unlike the SSE push, which has no such layer and gzip+base64's these fields itself instead (see "Payload size and shared-queue contention" below). Used by the client's manual **↺** refresh button and as the SSE `onmessage` fallback for an unrecognized event shape |
| GET | `/api/now.json` | JSON array of on-air entries (see schema below) |
| GET | `/api/guide.json` (or `/api/guide.json/{deviceId}`) | JSON `{deviceId, winStart, winSec, devices, channels, sportsPaddingEnabled, terminalGuideEnabled}` — structured (non-HTML) guide data for one tuner's full window, every entry not just on-air (see schema below). No deviceId segment picks the first usable device, mirroring the web guide's own `defaultDev` choice. `sportsPaddingEnabled` mirrors `Sports_padding_enabled` (`state.config`) — the same value guide.js's HTML-baked `SPORTS_PADDING_ENABLED` template token carries, exposed here so a non-HTML JSON client (`hdhr_guide`, `Sources/hdhr_guide/`) can gate its own sports-genre auto-Bonus-Time detection on it too, matching every other client's `genreImpliesBonusTime && Sports_padding_enabled` pattern instead of always assuming the setting is on. `terminalGuideEnabled` mirrors `Terminal_guide_enabled` (state.config, Settings → Sharing → Terminal Guide's own sub-toggle) — `hdhr_guide` checks it right after its first fetch and exits if false; a courtesy gate only, since this same JSON is unaffected by the flag and already reachable to any LAN caller once `Web_server_enabled` is on |
| GET | `/api/signal` | JSON object `{guideName: "good"|"fair"|"poor"|"noData"}` — snapshot of `ChannelSignalStore.shared.buckets` keyed by `guideName.lowercased()` |
| POST | `/api/record` | Schedule a recording |
| POST | `/api/signal-scan` | Trigger a signal strength scan. Optional body `{"force":true}` rescans all channels regardless of freshness. Returns `{"status":"started","force":bool}`. |
| POST | `/api/delete` | Remove a managed show and stop any active recording |
| POST | `/api/edit` | Update a managed show's config fields |
| POST | `/api/toggle-favorite` | Toggle the favorite flag for a channel |
| GET | `/api/now-airing/{devId}/{ch}` | JSON `{title, epTitle, poster, endTime}` for the currently-airing guide entry on the given device+channel; used by the tuner popover to enrich external stream rows asynchronously |
| GET | `/api/guide-detail/{devId}/{ch}/{winStart}/{winSec}` | JSON `{entries: [{start, syn, poster, ep, date}]}` — heavy fields (Synopsis/poster/episode/air date) for every entry currently in that channel's guide window, keyed by `start` epoch. `winStart`/`winSec` are the client's own `_winStart`/`_winSec` (the window its DOM was actually rendered against), so the response matches what the client has rather than silently drifting with server "now" time; falls back to the server's current window if those segments are missing/malformed **or out of range** (`winStart` clamped to ±10 years of now, `winSec` to `1...(28*3600)` — a well-formed-but-absurd value like `Int.max` used to overflow the `winStart + winSec` addition and trap the whole process; see `issues_resolved.md`). Lazily fetched by the client's per-row `IntersectionObserver` once a row scrolls into view; these fields are omitted from the initial grid HTML (see "Lazy heavy-data loading" below) |
| GET | `/api/signal-stats/{guideName}` | JSON `{bucket, last, avg, min, max, checked, n, total}` — full signal stats for one channel from `ChannelSignalStore.stats()`; `checked` is the last-sampled epoch (client renders relative). Empty `{}` when no samples. Used by the tuner popover to show inline recordability per active tuner |
| GET | `/api/airings/{seriesId}` | JSON `{airings: [{start, end, ch, chName, ep, device, genre, chLogo, title}]}` — up to 4 upcoming episodes of the given SeriesID, via `state.upcomingGuideEpisodes(seriesID:)` — always unfiltered (every channel), unlike native's `AddShowView` which passes a `channelNum` filter server-side for SeriesID(Channel); the web Record modal instead filters client-side in `renderAirings()` (below) so toggling Channel/All doesn't need a second fetch. `genre` is `GuideEntry.firstGenre` (drives the row's genre-color accent bar via `gc()`); `chLogo` is the channel logo URL from `state.channelImageURLs`, `""` when not cached. `end`/`title` exist so `switchAiring()` can fully re-anchor the modal to a row (see below) without a second fetch. Powers the Record modal's "Other Upcoming Airings" preview. Unknown/absent series → `{"airings":[]}` |
| GET | `/api/guide-search/{deviceId}/{query}` | JSON `{shows: [{title, seriesId, poster, airings: [{start, end, device, ch, chName, ep, genre}]}]}` — shows on that one device's guide (search is current-tuner-only) whose title case-insensitively contains `query`, grouped by SeriesID (falling back to a `Show.seriesTitle(from:)`-normalized title when absent — same key shape `GuideStore.currentEntryByTitle`/`ManagedGuideMatcher.owner(for:)` use) so a rerun without a SeriesID still collapses into one show. `poster` is the first non-nil `GuideEntry.ImageURL` seen in the group. Each group's `airings` is sorted by `start`; groups are sorted by `title` and capped at 25. `query` shorter than 2 chars (after trimming) → `{"shows":[]}`. Powers the guide toolbar's search box (below) |
| GET | `/api/icon` | Serves the app icon as a 72×72 PNG (for the splash overlay) |
| GET | `/api/watch-recording?show={id}` | Relays a currently-recording show's on-disk file as an open-ended HTTP stream (see below) |
| anything else | | 404 plain text |

---

## POST /api/record

Schedules a recording by calling `state.addShowFromGuide(entry:type:device:channel:airDays:transcode:bonusTime:titleOverride:)` — the same function the menu's quick-add uses (not the in-app wizard, which goes through `save()` → `addShow`) — so web-scheduled recordings get the same notifications, conflict detection, and config fields as menu quick-add ones.

**Request body (JSON):**

```json
{
  "deviceId":    "XXXXXXXX",
  "guideNumber": "5.1",
  "startTime":   1748822400,
  "endTime":     1748826000,
  "showType":    "single",
  "airDays":     ["Monday","Wednesday","Friday"]
}
```

| Field | Required | Values |
|---|---|---|
| `deviceId` | yes | HDHomeRun device ID |
| `guideNumber` | yes | Channel number string (e.g. `"5.1"`) |
| `startTime` | yes | Unix timestamp — locates the exact `GuideEntry` via `guideStore.entries(after: .distantPast)` |
| `endTime` | no | Unused server-side |
| `showType` | no | `"single"` (default) · `"dateTime"` · `"seriesChannel"` · `"seriesAll"` |
| `airDays` | no | Day names (e.g. `["Monday","Friday"]`). For `dateTime`, absent/empty defaults to the day-of-week of `startTime`. For `single`, stored as informational metadata only (`show_air_date`) — it does not affect `show_next`/what actually records; the web Record modal sends the entry's own weekday here. |
| `transcode` | no | Transcode profile: `"none"` (default) · `"heavy"` · `"mobile"` · `"internet720"`. When absent, the show inherits `config.Default_transcode`. |
| `title` | no | Overrides the show title. Sent by the web Record modal only when the user edits the prefilled title — omitted otherwise so the server-side SeriesID episode-suffix stripping (`addShowFromGuide`) still applies to the raw guide title. |
| `bonusTime` | no | `Bool`, default `false`. Passed through to `addShowFromGuide(...bonusTime:...)`; sent by the web Record modal's bonus-time checkbox. |

`showType` maps to `ShowState`:

| Value | ShowState | Behaviour |
|---|---|---|
| `"single"` | `.single` | Record this airing only |
| `"dateTime"` | `.dateTime` | Record at this time/day every week |
| `"seriesChannel"` | `.seriesChannel` | Record new episodes via SeriesID on this channel |
| `"seriesAll"` | `.seriesAll` | Record new episodes via SeriesID on any channel on this same assigned HDHomeRun device (not any device) |

**`tunerFull`** is determined by `AppState.tunersFull(for: deviceId)`, which delegates to `activeTunerCount(for:)` — `max(hardware-polled deviceTunerOccupancy count, this instance's recordingShows + in-app VLC stream)`. Neither signal alone is sufficient: raw `deviceTunerOccupancy` misses the in-app VLC stream (it doesn't appear in `status.json`), while local `recordingShows` alone misses tuners locked by another machine running this app against the same physical device.

**Success:** `{"ok": true, "title": "Show Title", "tunerFull": false, "recStarted": false, "tunerActive": 1, "tunerTotal": 2}`

| Response field | Meaning |
|---|---|
| `tunerFull` | All tuners occupied at schedule time — show is queued |
| `recStarted` | `true` when the show is currently on air and recording started immediately |
| `tunerActive` | Current active-tuner count for this device after scheduling |
| `tunerTotal` | Total tuner capacity of this device |

The client uses `recStarted` to immediately switch the guide block's background class to `.g-prog-rec` vs. `.g-prog-sched`, and its status ring/badge class to `.g-st-rec` vs. `.g-st-sched` (⏺ vs. ⏱, see "Status ring + badge" below), without a page reload. `tunerActive`/`tunerTotal` are used to update the `tun-{devId}` badge text in place.

**Failure:** `{"ok": false, "error": "reason"}` (HTTP 200) or `400 Bad Request` plain text for missing fields.

---

## POST /api/delete

Removes a managed show from the schedule and stops any active recording. Flow: `state.discordWebDelete(show)` (edits the existing "Recording Started" Discord embed in-place if one was created) → `recordingManager.stop()` → clear `show_url` and `show_recording` → `state.deleteShow()` → save config.

The stream URL is explicitly cleared on the live show record *before* `deleteShow` is called so the idle loop cannot race in and restart the recording in the gap.

**Request body (JSON):**

```json
{
  "showId":      "XXXXXXXX-XXXX",
  "deviceId":    "XXXXXXXX",
  "guideNumber": "5.1",
  "startTime":   1748822400,
  "title":       "Show Title"
}
```

Requires `showId` OR (`deviceId` + `guideNumber`); missing both is a `400` (`"Missing required field: showId or (deviceId + guideNumber)"`).

Match priority: **`showId`** first (sent by the edit modal, matches `state.shows` directly) — falls back, when `showId` is absent, to a recording show on exact device+channel, then to an active show matching **device+channel+title** (handles series shows on any channel; the deviceId check on this fallback is required — a multi-tuner setup can have two devices scheduled to record an identically-titled show on the same channel number, and a title-only match would delete/stop the wrong tuner's show).

**Success:** `{"ok": true, "title": "Show Title"}`  
**Failure:** `{"ok": false, "error": "Show not found"}`

---

## POST /api/toggle-favorite

Toggles the favorite status of a channel by calling `AppState.toggleFavorite(device:channel:)`. Optimistically mutates `lineups[deviceId][idx].Favorite` in-place, fires an async HDHR API call (`HDHRManager.setFavorite()` → `POST http://{ip}/lineup.post?favorite=+/-GuideNumber`), and reverts on failure. Broadcasts a `favorite_toggled` SSE event (via `broadcastGuideChangeEvent` — carries the rebuilt grid/sumph/tdrop, see SSE section) so all open guide pages update in place.

**Request body (JSON):**

```json
{
  "deviceId":    "XXXXXXXX",
  "guideNumber": "5.1"
}
```

**Success:** `{"ok": true, "isFavorite": true}`  
**Failure:** `{"ok": false, "error": "Device or channel not found"}` or `400 Bad Request` for missing fields.

---

## POST /api/edit

Updates config fields on an existing managed show. All fields except `showId` are optional — only supplied fields are applied. Cannot be called on a show that is currently recording (the web UI hides the Edit button for recording shows; the server-side handler does not enforce this restriction).

**Request body (JSON):**

```json
{
  "showId":        "abc123",
  "showType":      "seriesAll",
  "paused":        false,
  "title":         "Jeopardy!",
  "channel":       "5.1",
  "length":        30,
  "bonusTime":     true,
  "transcode":     "none",
  "airDays":       ["Monday","Wednesday","Friday"],
  "resetFailures": true,
  "ignoreDuplicateOnce": false,
  "newOnly": false
}
```

| Field | Type | Effect |
|---|---|---|
| `showId` | String | **Required.** Identifies the show to update |
| `showType` | String | `"single"` / `"dateTime"` / `"seriesChannel"` / `"seriesAll"` — updates series flags |
| `paused` | Bool | Pause or unpause; unpausing calls `clearFailures()`, clears `showRuntime[showId]?.retryAfter`, and clears `notify_upnext_time`/`notify_recording_time` (re-arms the "Up Next"/"Recording Soon" pre-notifications — same reasoning as `AppState.applyResume`, since this branch doesn't route through it; see `issues_resolved.md`'s "Two more resume paths missed by the `notify_upnext_time`/`notify_recording_time` re-arm fix" entry) |
| `title` | String | Show title |
| `channel` | String | Guide channel number |
| `length` | Int | Recording length in minutes |
| `bonusTime` | Bool | Bonus time flag |
| `transcode` | String | Transcode profile |
| `airDays` | [String] | Air day list (used for `dateTime` shows) |
| `resetFailures` | Bool | Clears `show_fail_count`/`show_fail_reason` and sets `show_active = true` |
| `ignoreDuplicateOnce` | Bool | `show_ignore_duplicate_once` — the "Duplicate Episodes" override (see "Duplicate-episode override" above) |
| `newOnly` | Bool | `show_new_only` — the "New Only" / "Skip reruns" toggle (`docs/ShowFormSection.md`); checked at record time regardless of type, but only meaningful (and only shown in the UI) for non-`single` types |

**Recording directory is not web-settable:** this endpoint has no auth beyond LAN-subnet matching, so it deliberately does **not** accept a `saveDir` (or any output-path) field — allowing a LAN host to redirect where recordings land is a security risk. Any `saveDir` in the request body is ignored; `show_dir`/`show_temp_dir` can only be changed with local app access.

Promoting a show to a `seriesId` type (`seriesChannel`/`seriesAll`) when it previously was not triggers `rescheduleAllSeries()` immediately so `show_next` is populated before the next idle loop tick.

**Success:** `{"ok": true, "title": "Updated Title"}`  
**Failure:** `400 Bad Request` — `"Missing required field: showId"`, show not found, a `channel` not in the device lineup, or a `length` over the 24 h (1440 min) cap.

---

## Edit modal (`#edit-modal`)

`position: fixed` overlay (z-index 201). Opened from two paths:
- **Per-tuner dropdown rows** — each `.sp-row` has an `onclick="openEditShow(this)"` handler; `data-*` attrs are embedded by `buildTunerShowsHTML`
- **Guide grid** — Edit button in the summary panel calls `doEditFromGuide()`, which re-packages `data-show-*` attrs from the selected `.g-prog` block into the same shape `openEditShow()` expects

**Contents (top to bottom)** — ordered to match the native Edit Show field order (`ShowFormSection.swift` fields first, then `EditShowView`'s own Channel/Length/SeriesID fields, which sit near the bottom of the native form too):
- Title (editable input, `#em-title-in`)
- **Signal row** (`#em-sig-row`) — bars (`#em-sig`) + weak-signal warning banner (`#em-sig-warn`), mirroring the Record modal's `#rm-sig`/`#rm-sig-warn`. Hidden by default and only shown once `renderEmSignal()`'s fetch resolves a non-`noData` bucket — unlike the Record modal (where the bars sit inside the Title row's content column with nothing to hide), Edit's Signal is its own row, so it stays hidden entirely rather than showing an empty "Signal" label when the feature is off or there's no data yet. Keyed by `_editChname`, a dedicated var (not the shared `_chname` the Record modal/grid selection use) since Edit can be opened from the tuner dropdown, which never touches `_chname`. `_editChname` is populated from `data-chname` — added to the tuner-dropdown row's data attributes (`buildTunerShowsHTML`, resolved from `state.lineups[hdhr_record]`'s matching `GuideNumber`) and already present on the grid block's own `data-chname` for the `doEditFromGuide()` path.
- **Type selector** — same compact button row + description line as the Record modal (`#em-type-opts`/`#em-type-desc`, built by the shared `renderTypeRow()` helper — collapsed to Single/DateTime/SeriesID as of 2026-08-23, see the Record modal's Type row entry above for the full mechanism). Selecting a button resolves to a concrete type (defaulting `'seriesID'` clicks to `'seriesChannel'`, or preserving the current scope) and updates the module-level `_editType` var directly (read by `confirmEdit()`), not a `:checked` DOM query.
- **Scope row** (`#em-scope-row`/`#em-scope`) — 2-segment Channel/All, same shape and mechanism as the Record modal's Scope row above; visible only when `_editType` is a series type, built/rebuilt by `updateScopeUI()` (called both on modal open and from the Type selector's click callback, since — unlike Days/Dup/New Only, whose `update*Visibility()` helpers only toggle visibility — this one also has to *render* the two buttons). Selecting Channel/All writes `_editType` directly and calls `updateChannelRowVisibility()` (below).
- **Transcode selector** (`#em-transcode`) — with its own **no-transcode warning** (`#em-no-transcode`, same style/copy as the Record modal's `#rm-no-transcode` below), shown by `updateEmNoTranscodeWarn()` whenever `#em-transcode`'s picked value isn't `"none"` and `noTranscode(_editDev)` is truthy. The one real difference from the Record modal's version: keyed off `_editDev` (the show's already-assigned tuner, set from `data-dev`/`d.dev` when the modal opens) rather than the guide's currently-selected device — editing an existing show never changes which tuner it's on, so there's no `switchAiring()`-equivalent re-evaluation needed. Re-run on `#em-transcode`'s own `onchange` and once at modal-open time.
- **Bonus Time toggle** (`#em-bonus-row`) — hidden entirely when `config.Sports_padding_enabled` is `false` (parity with the Record modal), and always hidden while the show is recording
- **Air Days row** — visible for **`single` and `dateTime`** types (parity with the Record modal); 7 Su–Sa toggle buttons, label reads "Day" for `single` / "Days" for `dateTime`. Hidden for series types. At least one day must remain selected.
- **New Only toggle** (`#em-new-row`/`#em-new`) — "Skip reruns", mirrors the native dialog's `show_new_only` toggle (`docs/ShowFormSection.md`). Visible for every type except `single`; re-evaluated on every type-picker change via `updateNewOnlyVisibility()`. Unlike Duplicate Episodes below, not gated by any server-side config flag.
- Channel + Length fields (minutes) — web-only editable fields (native `EditShowView` shows these too, in the same relative position after the shared `ShowFormSection` block). **Channel row** (`#em-ch-row`) is hidden when Scope is All (`updateChannelRowVisibility()`, called from `updateScopeUI()` and the Scope row's own click handler) — mirrors `EditShowView.swift`'s identical hide rule (`docs/EditShowView.md`), since an All-scoped show floats across every channel the tuner receives rather than being locked to one.
- **Reset Failures link** — shown when `failcount > 0`; sets `resetFailures: true` in payload
- **SeriesID row** — visible for series types; web-only display (native shows it even further down, after Stream URL)
- **Duplicate Episodes toggle** (`#em-dup-row`/`#em-dup`) — "Record even if already on disk", mirrors the native dialog's toggle (`ShowFormSection.swift`). Visible only when `SKIP_DUP_ENABLED` (`Series_subfolder_enabled && Skip_recorded_episodes`) and the type is a series type; re-evaluated on every type-picker change via `updateDupVisibility()`. See "Duplicate-episode override" above.
- **Tuner-not-detected banner** (`#em-dev-warn`, amber) — shown when the show's `hdhr_record` device isn't a key in the client-side `tuners` JS var (from `tunerJS`, built from `state.devices` — i.e. genuinely undiscovered, not just offline-but-known). Reads "Tuner HDHR-XXXX is no longer detected — delete this show, or leave it as is in case the tuner returns."
- **Recording-in-progress banner** (`#em-rec-warn`, red) — shown while the show is actively recording; warns that Delete will stop the active recording
- Cancel / Delete / Pause / Save buttons — **Pause is hidden** (not just disabled, so the row reflows via flexbox rather than leaving a dead gap) while the show is recording *or* while its tuner isn't detected — in both cases pausing has no meaningful effect (already mid-capture, or no future occurrence on a phantom tuner to pause)

Save Directory is **not** editable from the web UI — directory path changes require local app access.

On **Save**: `confirmEdit()` POSTs `/api/edit` and closes modal on success. A `show_updated` SSE event carrying the rebuilt grid/sumph/tdrop (via `broadcastGuideChangeEvent`) is pushed to all connected clients immediately after the server-side update, so every open tab applies the update in place without its own fetch.

---

## Delete confirmation modal (`#del-confirm-modal`)

`position: fixed` overlay (z-index 202 — above `#edit-modal`'s 201, since it can be opened from within it). Shared by both delete entry points — the Summary panel's Delete/Stop & Delete button (`doDelete()`) and the Edit modal's Delete/Stop & Delete button (`doEditDelete()`) — neither posts to `/api/delete` directly anymore; both call `showDeleteConfirm(title, poster, typeStr, isRec, onConfirm)` first, which populates and shows this modal and stashes `onConfirm` (`performSummaryDelete`/`performEditDelete` respectively — the functions that actually do the POST, previously the entire body of `doDelete()`/`doEditDelete()`) in the module-level `_delConfirmAction` var. Native precedent: `AppState.confirmAndDeleteShow(_:then:)` (see `docs/AppState.md`) already does the equivalent poster-fetch-then-`NSAlert` confirmation for the menu bar UI — this brings the web guide to parity, plus the recording-type line the native alert doesn't show.

**Contents:**
- Poster image (`#dc-poster`) — `poster` argument (Summary panel: `_poster||_logo`; Edit modal: `_editPoster`, itself `d.poster||d.logo||''` captured by `openEditShow()`); hidden entirely if empty or on load error, never left as a broken-image icon
- `Delete "<title>"?` (falls back to `"this show"` if title is somehow empty)
- `Type: <label>` — `typeLabel(typeStr)` looks `typeStr` (a `ShowState` raw value) up in the same `recOpts` table the Record/Edit modals' own Type row renders from, so this can never disagree with what those modals call each type
- A warning line — `"This will stop the active recording. This cannot be undone."` when `isRec`, else just `"This cannot be undone."`
- Cancel / Delete buttons — the confirm button is relabeled **"Stop & Delete"** when `isRec`, matching the triggering button's own label

`cancelDeleteConfirm()` hides the modal and clears `_delConfirmAction` (also wired to a backdrop click, matching the other modals). `confirmDeleteConfirm()` (the confirm button) invokes and clears `_delConfirmAction` — the actual delete (POST + UI update) only ever runs from there, never from the triggering button's own click handler.

---

## Recording playback relay — `/api/watch-recording?show={id}&start={byteOffset}`

Lets `AppState.watchRecordingInApp(_:)` (`MenuContent`'s "Watch Now!" on an actively-recording show) play the in-progress recording without opening a second tuner. VLC's plain `file://` access module snapshots a file's length at open time and won't read past it even though curl keeps appending — so a direct `file://` URL onto a growing recording stalls/ends once playback catches up. This endpoint reframes the file as an open-ended HTTP response instead: no `Content-Length`, connection held open, bytes drip-fed as they land on disk — the same shape as the real HDHomeRun tuner stream, which VLC already handles.

**Server infrastructure (`WebServer.swift`):**
- `handleWatchRecording(showId:startOffset:conn:)` — looks up the show and reads `show_recording_path` on `@MainActor` (both in-memory, no I/O), then dispatches to a dedicated `fileIOQueue` (not `queue`, which every other connection's request/response I/O and SSE keepalives also run on) for the `fileExists` check and everything in `streamGrowingFile` — isolates this route's disk I/O so a slow or momentarily-stalled recording drive can only stall the one Watch Now session touching it, not every other device's guide loads/edits/live updates on the shared server queue
- `streamGrowingFile(path:showId:startOffset:conn:)` — sends `200 OK` with `Content-Type: video/mp2t`, `Connection: keep-alive`, no `Content-Length`; if `startOffset > 0`, seeks the `FileHandle` there first (clamped to the file's current size, so a stale offset can't seek past EOF), then hands off to the pump loop
- `pumpGrowingFile(...)` — checks `conn.state` first on every recursive call (`.cancelled`/`.failed` closes the file handle and stops recursing immediately) — otherwise a connection cancelled while the loop sits in its 0.5 s wait-for-more-data poll (the common state once caught up to the live edge) wouldn't be noticed until a `conn.send()` was actually attempted, which only happens once new bytes arrive. Then reads 200 TS-packet chunks (~37 KB) and sends them via `sendWithTimeout`; on an empty read, polls every 0.5 s while `show.show_recording == true`, then drains and closes once the show stops recording; on a send failure (real error or timeout — see below), closes the file handle, cancels the connection, and stops recursing. That empty-read branch is the one part of the pump loop that needs a `Task { @MainActor in ... }` hop (to read `show.show_recording`) before it can schedule the next poll — see `docs/VLCBridge.md`'s "Channel Switching (play)" for why that specific dependency mattered: it was one half of a real mutual deadlock with VLC's own blocking stop call, fixed 2026-08-15 on the VLCBridge side without needing to change anything here
- **`sendWithTimeout(_:on:timeout:completion:)`, added 2026-09-04** — wraps every `conn.send(...)` in this pump (both the initial header in `streamGrowingFile` and each chunk in the loop above) with a `growingFileSendTimeout` (15s) fallback. `Network.framework`'s own send has no built-in timeout: a peer that stops draining its TCP receive window (rather than cleanly closing) leaves `.contentProcessed`'s completion pending forever, with `conn.state` never transitioning to `.cancelled`/`.failed` either — so the existing per-recursion state check above can't catch it. Caught live via the virtual-tuner relay (this same pump, `handleVirtualTunerStream` → `streamGrowingFile`): a remote viewer's stream froze for ~5 minutes with zero log signal on this Mac's side, while a sibling connection to the same peer stayed perfectly healthy the whole time (ruling out a Mac-wide bottleneck — see `docs/VirtualTunerService.md`), until the client itself gave up and reconnected from byte 0. `sendWithTimeout` races the real `.contentProcessed` completion against a `queue.asyncAfter` timer (both always run on `queue`, so no lock is needed to guard against double-firing); whichever fires first wins, reporting `nil` on success or a failure-reason string (the real error's description, or a synthetic `"timed out after Ns..."`) on either a genuine send error or a timeout. Either failure path now explicitly calls `conn.cancel()` — a real send error usually means the OS already knows the connection is dead, but the timeout case does not, so without this a stalled connection would stay open indefinitely from this side even after giving up on it (`cancel()` is idempotent, safe to call either way).
- Intercepted in `accumulate()` before the normal `route()` path, same as `/api/events` — never falls through to the keep-alive/Content-Length response path
- Logs to `~/Library/Logs/hdhrVCRplus.log`: stream open/close (including `startOffset`), each time it catches up to the live edge and resumes (with wait duration), and a running total every 5 MB sent — enough to tell from the log alone whether a session stalled waiting for data or was cut short
- `start` is an app-level byte offset computed by `AppState.seekRecording(_:)`, not an RFC 7233 `Range` header — there's no `Accept-Ranges`/`206 Partial Content` handling, since only this app's own player ever requests this endpoint

**AppState side:** `watchRecordingInApp(_:)` builds `http://127.0.0.1:{Web_server_port}/api/watch-recording?show={show_id}&start={offset}` — `offset` defaults to ~30s behind the live edge (not byte 0), so Watch Now! starts near "now" rather than at the beginning of the recording — and calls `ensureWebServerRunning()` (the same refcounted internal-use path `AddShowView`'s guide step uses, so this works even with the LAN web UI disabled in Settings) guarded by a `recordingRelayActive` flag; `VLCPlayerWindowManager.playerWindowDidClose()` calls `AppState.releaseRecordingRelayIfNeeded()` to balance it. The external-VLC path (`watchRecordingInVLC(_:)`, `Watch_in_VLC` setting) still uses a plain `file://` URL — there's no reliable close hook for an app launched via `NSWorkspace`, so it can't safely balance the relay's refcount, and is subject to the same-open-time-snapshot caveat this endpoint exists to avoid.

**Scrubbing:** `AppState.seekRecording(showId:toSeconds:)` (called from `VLCPlayerView`'s recording scrub bar — see `docs/VLCPlayerView.md`) estimates a byte offset as `(file size so far / seconds recorded so far) × targetSeconds`, rounded down to a 188-byte TS packet boundary, then reconnects via `VLCBridge.play(url:)` with `&start={offset}` appended. This is an approximate, non-frame-accurate seek (the raw file has no index) implemented as a full reconnect rather than a true in-place seek — simpler and more reliable than relying on libvlc's own time-seek machinery against a `Content-Length`-less resource, at the cost of a brief rebuffer on every scrub commit. `VLCBridge.recordingPlaybackSeconds` (seek-base seconds + wall-clock time since the last reconnect) drives the scrub bar's displayed position between commits, refreshed by `beginRecordingSeek(showId:recordingStart:seekBaseSeconds:)`; `VLCBridge.play(url:)` also refreshes the reconnect timestamp on *any* reconnect to a relay URL (including the toolbar's "catch up" button replaying the same URL) so the displayed position can't drift ahead of what's actually playing.

---

## Server-Sent Events — `/api/events`

A persistent SSE endpoint. Browsers connect once on page load via `EventSource('/api/events')`; the connection stays open indefinitely.

**Server infrastructure (`WebServer.swift`):**
- `sseConns: [NWConnection]` — registry of all open SSE connections (protected by `NSLock`)
- `broadcastEvent(_ event: [String: Any])` — serialises the dict to JSON and writes `data: {…}\n\n` to every registered connection; removes dead connections on send failure
- `registerSSE(_ conn:)` — sends SSE response headers (`Content-Type: text/event-stream`, `Cache-Control: no-cache`, `Connection: keep-alive`), adds connection to registry, starts keepalive loop
- `sseKeepalive(_ conn:)` — sends `": ping\n\n"` SSE comments every 25 s to keep the connection alive through proxies; recursively reschedules itself; stops when the connection is removed from the registry
- SSE connections are intercepted in `accumulate()` before the normal `route()` path — they never call `send()` and are never cancelled after the response headers

**Events pushed:**

| Event `type` | Triggered by | Payload fields |
|---|---|---|
| `recording_started` | `AppState.startRecording` | `channel`, `device`, `sumPh` (HTML), `tdrop` (HTML string), `tdropDev` |
| `recording_stopped` | `AppState.teardownRecordingState` | `channel`, `device`, `sumPh` (HTML), `tdrop` (HTML string), `tdropDev` — **plus** a second, separate `recording_stopped` SSE message with the full `broadcastGuideChangeEvent` shape (`grid`/`sumph`/`tdrop`, see below) fired right after, added 2026-08-21 so the channel's row physically reorders out of the Recording section (see "Recording section" above) |
| `guide_refreshed` | `AppState.refreshGuides` (on success) | `grid` (HTML), `sumph` (HTML), `tdrop` (`{deviceId: HTML}`) |
| `show_added` | `AppState.addShow` (self-broadcasts — covers `addShowFromGuide` via the web guide **and** the native Add Show wizard) | `channel`, `device`, `grid`, `sumph`, `tdrop` |
| `show_deleted` | `AppState.deleteShow` | `channel`, `device`, `grid`, `sumph`, `tdrop` |
| `show_updated` | `AppState.updateShow` (self-broadcasts — covers `WebServer.handleEdit` **and** the native Edit Show window), `skipRecording`/`pauseShow`/`resumeShow` | `channel`, `device`, `grid`, `sumph`, `tdrop` |
| `favorite_toggled` | `WebServer.handleToggleFavorite` | `device`, `guideNumber`, `grid`, `sumph`, `tdrop` |
| `tuner_occupancy_changed` | `AppState.fetchDeviceStatusUncached` (hardware active-tuner count change) | `device`, `grid`, `sumph`, `tdrop` — same `broadcastGuideChangeEvent` payload shape as the rows above; keeps the tuner popover (`recsByDevJS`) and `.g-st-inuse` ring in sync with a hardware-only occupancy change (e.g. another machine's tuner starting/stopping) that none of the other triggers would catch. Throttled per-device (`lastGuideOccupancyBroadcast`, independent of the menu-open write cooldown) so a rapidly flapping external count can't re-trigger a full grid rebuild every idle-loop tick. |
| `deviceOffline` | `AppState.probeForNewDevices` (miss #3), via `broadcastDeviceBarEvent` | `deviceId`, `devbar` (HTML) |
| `deviceOnline` | `AppState.probeForNewDevices` (seen after unavailable, or new device), via `broadcastDeviceBarEvent` | `deviceId`, `devbar` (HTML) |
| `signal_update` | `AppState.startSignalScan` | `gname` (guideName.lowercased()), `bucket` (raw string: `"good"` / `"fair"` / `"poor"` / `"noData"`) |
| `tuner_update` | `WebServer.pushFreshTunerCounts` (on SSE connect) | `counts`: `{deviceId: {a: active, t: total}, …}` — live occupancy from `recordingShows` |

`recording_started` and `recording_stopped` carry pre-rendered `sumPh` and `tdrop` HTML fragments built by `broadcastRecordingEvent` → `buildSumPhHTML` + `buildTunerShowsHTML(state, device)` (one device only — `tdrop` here is a single HTML string, applied to `#tdrop-{tdropDev}`). The client applies `sumPh` to `#sum-ph` inline without a second HTTP request.

`guide_refreshed`/`show_added`/`show_deleted`/`show_updated`/`favorite_toggled` carry the full `grid`/`sumph`/`tdrop` payload built by `broadcastGuideChangeEvent` → `buildGuideRefreshPayload` (same shape `GET /api/guide-refresh` returns — `tdrop` here is an *object* keyed by device ID, not a single string). This is computed **once per event**, server-side, and pushed to every connected client, instead of each client independently calling `/api/guide-refresh` and rebuilding the grid itself — see "Guide-change fragment push" below.

`deviceOnline`/`deviceOffline` carry a `devbar` HTML fragment built by `broadcastDeviceBarEvent` → `buildDevBarHTML` — the inner content of `#dev-bar` (one tuner box per usable-or-has-a-show discovered device, plus any offline/absent device with a show — see the `#dev-bar` section further down), factored out of `buildHTML` so it can be pushed standalone. Previously these two events carried no HTML payload at all; the client had no branch for them and fell through to the fetch-based `refreshGuide()` fallback (case 6 below), whose payload never includes `#dev-bar`'s HTML — so a device going online/offline mid-session silently never updated its tuner-box row (online/offline dimming) until the next full page reload.

**Client handling (seven cases, checked in order):**

1. `tuner_update` — updates `tuners[dev].a` in-place and refreshes all `#tun-{dev}` badge elements. Fired on every new SSE connection so the badge is accurate immediately, not just after a recording event.
2. `signal_update` — updates SVG signal bars in-place on matching `.g-row[data-gname]` rows. No `refreshGuide()`.
3. Events with `gridZ`/`sumphZ`/`tdropZ` — the gzip+base64'd form of case 4's payload (see "Payload size and shared-queue contention" below). `decodeGzipB64(_:)` (browser-native `DecompressionStream('gzip')`) decodes whichever `*Z` keys are present, async, falling back to the plain `d.grid`/`d.sumph` string for a field whose `*Z` sibling is absent (the server can send a mix — see `gzipBase64`'s own comment), then hands the reassembled plain `{grid, sumph, tdrop}` object to the same `applyGuidePayload(d)` case 4 uses. Falls back to a full `refreshGuide()` fetch if this browser lacks `DecompressionStream`, rather than silently doing nothing until the next reload. **Must be checked before case 4** for the same reason case 4 must precede case 5 below.
4. Events with `grid` — applies the pushed `{grid, sumph, tdrop}` payload via `applyGuidePayload(d)` (swaps `.gi`, `#sum-ph`, every `#tdrop-body-{dev}`, re-syncs `_winStart`/`_winSec`, restores scroll + selection). **Must be checked before case 5** — this payload's `tdrop` is a `{device: html}` object, which would otherwise satisfy case 5's `d.tdrop` truthiness check and get assigned directly into `innerHTML`, rendering the literal string `[object Object]`.
5. Events with `sumPh`/`tdrop` (recording events only, now that cases 3–4 intercept the guide-change events) — applies `#sum-ph` and the affected tuner's `#tdrop-{tdropDev}` directly, and toggles `.g-prog-rec`/`.g-prog-now` classes plus the `.g-st-rec` status-ring/badge class on the currently-airing guide entry for the affected channel+device. No `refreshGuide()`.
6. Events with `devbar` (`deviceOnline`/`deviceOffline`) — swaps `#dev-bar`'s `innerHTML` in place. No `refreshGuide()`. `buildDevBarHTML` always renders every `.tdrop` closed (it has no notion of client UI state), so the handler first records which single `.tdrop` (if any — `toggleTunerDrop` only ever leaves one open at a time) currently has `style.display==='block'`, then re-applies that after the swap, so a device coming online/offline elsewhere doesn't silently close a dropdown the user has open.
7. All other events (or a `grid`/`gridZ`-carrying event missed for some reason) — `refreshGuide()` (fetch-based fallback, same `applyGuidePayload` under the hood).

`guide_refreshed` now falls into case 3 instead of the old fetch-based fallback — the grid the idle loop already rebuilt via `prebuildPageHTML` at guide-refresh time is reused by pushing the identical fragments computed by `broadcastGuideChangeEvent`, so no additional rebuild happens per connected tab. It's broadcast roughly **once per clock-hour boundary** (the `lastRefreshHour` gate in `AppState.idleLoop` → `refreshGuides()`), so an idle guide window does a background refresh about hourly even with no user activity.

### Guide-change fragment push (avoiding a rebuild per open tab)

Before `broadcastGuideChangeEvent` existed, every one of the events in case 3 above (`guide_refreshed`, `show_added`, `show_deleted`, `show_updated`, `favorite_toggled`) was broadcast bare (`{"type": ...}` only), so every connected tab fell into the fetch-based fallback (case 6) and independently called `/api/guide-refresh` — a full, uncached rebuild of the grid across every device/channel/entry. For N open tabs that meant N redundant rebuilds per state change. `broadcastGuideChangeEvent` computes the rebuild exactly once, server-side, and embeds the result in the SSE push — cost is now one rebuild per state change regardless of how many tabs are watching. `WebServer.handleDelete` relies on `AppState.deleteShow`'s own broadcast rather than also broadcasting itself, to avoid double-rebuilding on delete; `WebServer.handleEdit` relies on `AppState.updateShow`'s own broadcast the same way (both `addShow` and `updateShow` now self-broadcast `show_added`/`show_updated`, so every caller — the web handlers, the native Add/Edit Show windows — pushes to the web UI unconditionally instead of depending on each caller remembering to).

**Payload size and shared-queue contention (confirmed 2026-08-24, payload size fixed 2026-08-31 — see `ISSUES.md`'s "web guide feels laggy" entry)**: the win above is real (one rebuild instead of N), but the SSE push itself isn't free — `broadcastEvent` sends the `grid`/`sumph`/`tdrop` payload via `conn.send()`, on **`queue`** — the same shared serial `DispatchQueue` every `NWConnection` uses for its own request/response I/O and SSE keepalives (see `handleWatchRecording`'s entry above, which documents this exact shared-queue risk for the Watch Now relay's disk reads, but the same risk applies here too). With several tabs open, a burst of guide-changing actions can back this queue up badly enough that a *brand-new, unrelated* connection has to wait behind it before the app ever reads its first byte — measured live at 650-950ms added latency with 8 open SSE connections, at the payload size below. **Fixed 2026-08-31**: `broadcastGuideChangeEvent` now gzip+base64's the grid/sumph/tdrop fragments (`gzipBase64(_:)`) before embedding them, under new `gridZ`/`sumphZ`/`tdropZ` keys — falling back per-field to the plain key when compression declines to shrink a field (see that function's own comment). Cut a real broadcast from 2,252,437 bytes to 211,466 bytes (10.65x) — measured directly, before/after, with 4 held-open SSE connections. This is a payload-size fix only, not a queue-architecture fix: it doesn't touch `queue` itself, so `TODO.md`'s other two candidate approaches (stop embedding the full grid entirely in favor of a lightweight notify-and-pull, or give new-connection accept its own queue) remain live options if contention is ever measured again at the now-smaller payload size.

`EventSource` auto-reconnects after 3 s on drop. `stop()` cancels all SSE connections and clears the registry.

---

## HTML page — visual layout

Self-contained HTML with all CSS inlined — the *served* response is still one self-contained document, but the *source* is split across real files (see "Template files" below), not one Swift string literal. Updates arrive via SSE push events (see below) and targeted DOM swaps after user actions. The page hard-reloads automatically if the server version changes (redeploy detected via 60-second `/api/ping` poll) or if the baked-in 2-hour expiry elapses. Tuner occupancy is sourced from the `AppState.deviceTunerOccupancy` cache, which the idle loop refreshes every 10 seconds via `fetchDeviceStatus()`.

### Template files

The CSS, JS, and static body/toolbar/modal skeleton live in real files under repo-root `Resources/` — `guide.css`, `guide.js`, `guide-shell.html`, `guide-vertical.css` — not Swift string literals. `WebServer.swift` loads each once per process lifetime via lazy vars (`cachedGuideCSS`/`cachedGuideJS`/`cachedGuideShellHTML`/`cachedGuideVerticalCSS`), resolved through `templateURL(_:_:)`: first `Bundle.main.url(forResource:withExtension:)` (works once `deploy.sh`/`deploy_release.sh` have copied the four files into `Contents/Resources/`, exactly like `favicon.ico`/`AppIcon.icns`/`app*.jpg` already do — **not** SPM's `resources:`/`Bundle.module` mechanism, which is broken for this app's deploy pipeline, see `ISSUES.md`), falling back in `#if DEBUG` builds to a source-relative path under the repo's `Resources/` dir (via `#filePath`) so a plain `swift build` + direct binary run still renders a working guide page without a full `deploy.sh` cycle.

`buildHTML(state:prebuiltGrid:includeVerticalCSS:)` stitches the four templates together with thin Swift-literal glue for the outer `<!DOCTYPE>`/`<head>`/`<style>`/`<script>` wrapper tags, substituting each template's `{{TOKEN}}` placeholders via `fillTemplate(_:_:)` — a small `[(String,String)].reduce` over `replacingOccurrences`. Tokens cover the 21 values that used to be native Swift `\(...)` interpolation: `guide.css` has 1 (`GUIDE_MIN_WIDTH`), `guide-vertical.css` has 1 (`GUIDE_MIN_HEIGHT`), `guide-shell.html` has 6 (`APP_VERSION`, `HEADER_HTML`, `DEVICE_BAR_HTML`, `SUM_PH_HTML`, `SPORTS_PADDING_MINUTES`, `GRID_INNER`), `guide.js` has 13 more (`TUNER_JS`, `RECS_BY_DEV_JS`, `SPORTS_PADDING_MINUTES`, `SPORTS_PADDING_ENABLED`, `SIGNAL_QUALITY_ENABLED`, `SKIP_DUP_ENABLED`, `DEFAULT_TRANSCODE`, `DEFAULT_DEV`, `WIN_START`, `WIN_SEC`, `APP_VERSION`, `VER_EXP_TS`, `VT_ELIGIBLE`). The `includeVerticalCSS` parameter — not a token, a plain Swift `Bool` — controls two things at once: whether `guide-vertical.css`'s `<style>` block is embedded at all, and what `VT_ELIGIBLE` bakes into `guide.js` as (`true`/`false`, and only `true` when `cachedGuideVerticalCSS` actually loaded); see "Vertical time-axis mode" below for why both need to move together. If a template fails to load, `buildHTML` falls back to a minimal inline error string per template and logs a warning via `glog` rather than crashing.

This is a pure extraction — `prebuildPageHTML`/`cachedHTML`/`cachedHTMLGzip`'s caching model (below) is unchanged; `buildHTML` is still called from the same 4 sites, only what counts as "static text" inside it moved from Swift literal to loaded file. The pre-existing `ggAlias`/`ggKnown`/`--gg-*` genre-table duplication between Swift (`buildGuideGridHTML`), `guide.js`, and `guide.css` carries over unchanged — none of that text was ever Swift-interpolated, so it wasn't touched by this split.

**`body{height:100vh;height:100dvh}`** — the `100dvh` line (after the `100vh` fallback, so older engines that don't understand `dvh` keep the `vh` behavior) tracks the browser's actual *visible* viewport rather than the taller one that includes mobile Safari's address-bar chrome. Without it, a landscape phone sizes the page to a height greater than what's on screen, and `body`'s `overflow:hidden` (needed so the grid's own internal scroll region — `.gw{overflow:auto}` — is the only scrollable area) leaves the bottom of the guide unreachable, since there's no page-level scroll to get to it. Desktop/portrait is unaffected — `100vh` and `100dvh` agree there.

**HTML cache:** `prebuildPageHTML(state:)` pre-renders the page HTML and stores it in `cachedHTML` — one shared copy for all UAs, since desktop and mobile now render the same guide window (see below). It also gzips that HTML once at the same time and stores the result in `cachedHTMLGzip`; `GET /` returns `.okPrecompressed(...)`, which picks whichever of the two `send()` already has on hand based on the request's `Accept-Encoding` instead of re-running DEFLATE on every request (the page is ~1.5 MB raw — compressing it costs ~30–60 ms, dwarfing everything else in a LAN page load, so paying that cost once per rebuild instead of once per `GET /` was a meaningful win). Both caches are `nil` only before the first guide load, in which case the page falls back to a live synchronous build (via the generic `.ok(...)` case, gzipped on the fly by `send()` same as any other response). This eliminates the 2–4 second `@MainActor` blocking time on first load for remote clients.

`prebuildPageHTML` is called after every guide load (`fetchAllGuides`, `refreshGuides`), and also from `broadcastRecordingEvent` (every recording start/stop) and `broadcastGuideChangeEvent` (every add/delete/pause/resume/edit/favorite-toggle, plus the hourly guide refresh) — so `cachedHTML` stays current with every state change that affects the grid, not just the hourly guide reload. Without this, a fresh page load (a new tab, a hard refresh, or reopening the native Guide window's `WKWebView`, which does a fresh `GET /` each time it's created) could show a show as not-yet-recording for up to an hour after it actually started — connected tabs don't hit this because they get a live SSE class-toggle/grid-swap patch instead of re-fetching the page.

**Splash overlay:** a fixed `#splash` div (z-index 9999) covers the page on load, showing the app icon (from `/api/icon`), name, and build version. A 300 ms CSS animation delay means the splash is never visible on fast local loads (the page's `requestAnimationFrame` fires and removes it before the animation starts). On slow remote loads it fades in after 300 ms and is removed once the first `rAF` fires. `/api/icon` serves the `AppIcon.icns` scaled to 72×72 as PNG via `NSImage` + `NSBitmapImageRep`.

`refreshGuide()` is only called client-side for the manual **↺** refresh button and as the SSE `onmessage` handler's fallback for an event shape it doesn't otherwise recognize (see the SSE events list above). User actions (record, delete, edit, pause, favorite-toggle) do **not** call it — each of those already gets its change pushed via the SSE-broadcast `show_updated`/`show_deleted`/`favorite_toggled` guide-change event (the server calls `broadcastGuideChangeEvent` once per action, delivered to every connected tab including the one that triggered it), which `applyGuidePayload` applies the same way `refreshGuide()` would. Calling both used to mean every one of these actions rebuilt the grid server-side twice — once for the broadcast, once for the initiating tab's own redundant fetch — for no benefit, since the broadcast already covers it.

- **`refreshGuide(selOverride?)`** — saves `.gw` scroll position and the currently-selected `.g-prog` element (`data-start` + `data-num` + `data-device`); fetches `/api/guide-refresh` (same JSON shape an SSE guide-change event carries) → `applyGuidePayload()` swaps `.gi` (guide grid), `#sum-ph` (summary placeholder), and each `.tdrop` body (`#tdrop-{devId}`); re-reads `data-winstart`/`data-winsec` from the new `.g-hdr` into `_winStart`/`_winSec` (keeps the live now-line aligned to the refreshed grid); restores scroll position; re-selects the previously-highlighted entry via `showInfo()`. `selOverride`, if passed (a JS object), is merged into the re-selected block's `dataset` before `showInfo()` runs — no current caller passes one (the last one, `confirmRecord()`'s post-Record injection of `{recording:'1', managed:'1'}`, was removed along with that call once the SSE broadcast was confirmed to already carry the correct values), but the parameter stays since `applyGuidePayload()` (shared with the SSE handler) still accepts it.

**Theme variables:** CSS custom properties defined on `:root` (dark default) and overridden on `html.lm` (light). Dark: body `--bg:#141414` · surfaces `--s1–s4` `#1a–#22` · borders `--b0–b5` `#25–#48` · text `--t0–t6` `#f0–#66`. Light: body `--bg:#e4e6ea` · surfaces `#ec–#ff` · borders `#78–#c4` (visible against light backgrounds) · text `--t0–t6` `#11–#7d` (all pass WCAG AA contrast on light surfaces). Theme is toggled by adding/removing the `lm` class on `<html>`; preference is stored in `localStorage('theme')` with `'auto'` following `prefers-color-scheme`.

**Two entry points into the switching logic, not one** (`guide.js`): `applyNativeTheme(m)` does the actual work (write `localStorage`, toggle `.lm`, refresh the summary panel's theme-dependent chip colors) and is the only one the `#theme-sw` buttons' own `onclick` never calls directly. `setTheme(m)` — what those buttons actually call — does everything `applyNativeTheme` does, plus a best-effort `window.webkit.messageHandlers.appearanceChanged.postMessage(m)`. That bridge object only exists inside `AddShowView`'s embedded `WKWebView` (`docs/AddShowView.md`'s "Appearance sync" section) — a real browser connecting over the LAN has no `window.webkit` at all, so the call throws and is silently swallowed by `setTheme`'s own `catch`, leaving a remote session's theme choice exactly as independent as it's always been. The split exists so the native app can push its own `Appearance_mode` setting into that one embedded instance (`applyNativeTheme`, called from Swift) without that push ever looping back through the bridge and getting mistaken for a fresh user click.

Page structure (top to bottom):

1. **Top toolbar** (`#toolbar`) — a single horizontal, wrapping row holding (left→right): `h1` title, the per-tuner box list (`#dev-bar`, one `tunerBox` per discovered + offline device), the genre filter (`#genre-bar`, shown when applicable), the show search box (`#search-bar`, collapsed to just its `⌕` icon by default — see "Show search" below), and — pushed to the far right via `margin-left:auto` — the theme switcher (`#theme-sw`, dark/auto/light). Guide navigation (⊙ Now / ↺ Refresh) lives in the guide corner cell, not the toolbar. There is no global schedule popover — each tuner box has its own ▾ dropdown.
2. **Tuner popover** (`#t-pop`) — fixed overlay; shown by clicking an already-selected tuner's name button a second time (see "Tuner boxes" below)
3. **Summary panel** (`#sum`) — always visible; selected show details + actions
4. **Record type modal** (`#rec-modal`) — fixed overlay; appears on Record click
5. **Edit modal** (`#edit-modal`) — fixed overlay (z-index 201); appears on Edit click or schedule-popover row click
6. **Per-tuner dropdowns** (`.tdrop`, one `#tdrop-{devId}` per tuner) — absolute-positioned panels under each tuner box, toggled by the box's ▾ (`toggleTunerDrop`). Each lists that tuner's own Recording / Up Next / Scheduled / Paused (`.sp-*` classes) from `buildTunerShowsHTML(state:, deviceId:)`.
7. **Guide grid** — scrollable cable-guide grid (width/time-window depends on UA; see below)

**Per-tuner ▾ dropdown** (`.tdrop-btn` → `toggleTunerDrop(devId)`): each tuner box has a ▾ button that toggles its `#tdrop-{devId}` panel (absolute, below the box). Opening one closes any other; a document-level click handler closes open dropdowns when the click is outside any `.tuner-box`.

**Auto-select on load**: deferred into a `requestAnimationFrame` callback so the guide grid paints first (LCP element). On the first animation frame, an IIFE finds the first visible `.g-row` and selects the currently-airing `.g-prog`, populating the summary panel. `scrollToNow()` runs in the same callback. Deferring both prevents the externally-fetched CDN poster image from becoming the LCP element.

**Pull-to-refresh** (added 2026-08-25, touch only): dragging down on `.gw` while `scrollTop === 0` translates `.gw` down via an inline `transform`, revealing `#pull-refresh`'s spinner behind it (an absolutely-positioned sibling, see `.gw-outer`'s layout above). Past a 32px pull, releasing calls `refreshGuide()` — deliberately the *existing* in-place AJAX path (same one the SSE `onmessage` fallback already uses), not a page reload. This matters: `applyGuidePayload()` preserves scroll position and re-selects whichever program was already selected, so pulling to refresh leaves you looking at the same part of the grid — a native page reload would instead re-run the auto-select-on-load + `scrollToNow()` logic just above and jump to "now," which is exactly the jarring behavior this was built to avoid. Can never collide with a browser's own page-level pull-to-reload gesture, since `body` itself is `overflow: hidden` (never scrolls) — `.gw` is the only scrollable element on the page. A mostly-horizontal drag (channel-row/time-axis panning) or scrolling away from the top mid-gesture aborts the pull rather than triggering a refresh. `refreshGuide()` returns its fetch promise (previously discarded) specifically so this can wait for real completion — paired with `Promise.all([...., minDelay])` so the spinner stays visible at least 400ms even on a fast LAN, instead of flashing.

---

### Tuner boxes (`#dev-bar` in the toolbar)

`#dev-bar` is a wrapping flex row with one `tunerBox` per discovered device that's either usable
or still has at least one show referencing it, **plus** one per offline/absent device (any
`show.hdhr_record` not in `state.devices` — always shown, regardless of shows, per the invariant
below). A discovered device that's gone unavailable and has zero shows pointing at it (`hdhr_record`
match) is omitted entirely as of 2026-08-15 — nothing depends on it, so a permanently-dimmed empty
box would just be clutter; see `CLAUDE.md`'s "Web guide is per-tuner" invariant. Otherwise rendered
for every configuration including a single device. Each box (`.tuner-box`) has a `.tuner-row`:
**HDHR-XXXXXXXX** name (with the live `active/total` occupancy count folded into its own label,
e.g. "HDHR-105404BE 2/2 — FULL") + **▾** (`.tdrop-btn` → `toggleTunerDrop`), followed by a hidden
`#tdrop-{devId}` panel containing just the **↗** device web-UI link and that tuner's own
Recording/Up Next/Scheduled/Paused list.

**Active vs inactive.** A tuner is *active* when it's in `state.usableDeviceIDs` (discovered AND
reachable). Active: name is a single `.d-btn` button handling both guide-switching and tuner-detail
lookup (see "One button, two clicks" below); its inline count span (`#tun-{devId}`, class
`.t-info-inline`, red `.t-info-full` when all slots are occupied) is not itself clickable — there is
only one interactive target per tuner box, not two. Inactive (unreachable or absent): the box gets
`.tuner-off`, the name is a non-clickable `.d-btn-off` label, and `tdrop-hdr` shows a plain
**offline** span (`#tun-{devId}.t-info-off`) since there's no live occupancy data to show. The ▾
dropdown works either way and lists that tuner's assigned shows.

**Dimming must target `.tuner-row`, not `.tuner-box`.** `.tuner-off` sets `opacity` on `.tuner-row`
(the name+▾ row) only, *not* on the outer `.tuner-box` that also contains `.tdrop`. `opacity < 1`
creates a new CSS stacking context for whatever element it's on — if it were on `.tuner-box`, that
context would trap `.tdrop`'s `z-index: 150` inside it, so `.tdrop`'s stacking would only be
compared against its sibling `.tuner-row`, not against later page siblings like `#sum`. The result:
an offline tuner's dropdown would paint *underneath* the summary panel instead of over it, while an
active tuner's identical-looking dropdown (no opacity ancestor) rendered fine — a bug that only
reproduces on an offline/undetected tuner specifically. Keep the opacity scoped to `.tuner-row`.

**One button, two clicks (`handleDevClick(id, btn)`, guide.js).** An active tuner name's `onclick`
calls `handleDevClick`, not `setDev` directly: if the clicked tuner is not already the selected one,
it behaves exactly as before — `setDev(id)` filters the guide grid to that device. If it's already
selected — the common case for a second click on the same button — it instead opens the tuner
popover (`showTunerInfo(id, btn)`), the hardware-occupancy detail view described below. This
replaced an earlier layout where that popover's trigger was a separate "`active/total`[ — FULL]"
badge nested inside the ▾ dropdown's header — real-world mobile use showed that badge was too easy
to miss (buried a tap deeper than expected), so its function moved onto the always-visible name
button and its old standalone location was removed.

"Already selected" is `id === curDev` **or** (fixed 2026-08-21 — see `issues_resolved.md`)
`curDev === '' && ` this is the sole online tuner button. The second arm exists because a
single-online-tuner setup bootstraps with `setDev('')` (see "Default tuner" below) — `curDev` starts
out `''`, but the button's own `id` is always its real device ID, never `''`, so the bare `id ===
curDev` check alone could never match on that tuner's very first click even though it already reads
as selected (`.d-sel`, applied by this same "sole online tuner" rule inside `setDev`, below). Before
the fix, that first click silently no-op'd (a same-device `setDev(id)` reselect) and only a *second*
click — after `curDev` had been set to the real ID by that first one — actually opened the popover.
Multi-tuner setups were never affected, since their bootstrap `defaultDev` is always a real device ID.

**Default tuner (no combined view).** With more than one tuner there is no "All" view — the grid
opens on a single tuner. `buildHTML` computes `defaultDev` = the first device with both a
non-empty lineup and loaded guide data (fallback: first with a lineup, else `""`), and the
bootstrap call is `setDev('<defaultDev>')`. Single-device keeps `setDev('')`. Because the default
tuner starts out already selected, a user's very first click on a single-tuner setup's name button
opens the popover directly rather than a no-op reselect (see the two-arm check above) — consistent
with the "second click while already selected" rule, not a true special case anymore. `setDev('')`'s
`.d-sel` highlight (see the table below) is applied to that sole online tuner box too, so it visibly
reads as selected on load exactly like a multi-tuner default does — not just functionally selected
with no visual cue.

**Live updates:** the whole `#dev-bar` fragment (built by `buildDevBarHTML(state:)`, the same content `buildHTML` embeds on initial page load) is re-pushed via the `devbar` SSE payload on `deviceOnline`/`deviceOffline` — see SSE section — so a device recovering, going offline, or being newly discovered updates this row live in every open tab.

Both `buildDevBarHTML` and `buildHTML` (which separately needs per-device active/total counts to build the client-side `tuners` JS var) get their tuner-occupancy numbers from one shared `Self.computeDevTuners(state:logDiagnostics:)`, not two independent computations — they briefly diverged when `buildDevBarHTML` was first factored out (only `buildHTML`'s copy carried a diagnostic `glog()` line), which is exactly the kind of drift risk a single shared function closes for good. `computeDevTuners`'s active count is `state.activeTunerCount(for:)` (= `max(hardware occupancy, recordingShows + in-app VLC stream)`), the *same* source the SSE `tuner_update`/`broadcastRecordingEvent` pushes use — so a `deviceOnline`/`deviceOffline` dev-bar swap can't clobber a VLC-or-just-started-recording count back down to the hardware-only number. (The per-active-tuner *rows* still enumerate `DeviceTunerInfo` entries with `VctNumber != nil`; that's row display, independent of the badge count.)

---

### Tuner popover (`#t-pop`)

Fixed overlay (z-index 200). Positioned below the clicked tuner name button (`handleDevClick`'s
second-click branch, or directly via `showTunerInfo` from other call sites like the post-record
tuner-count refresh). Shows:
- **Header** — `active/total tuners` (+ `— FULL` when all occupied)
- **Per-active-tuner rows** — see below
- **`status.json ↗`** link — opens `http://{LocalIP}/status.json` in a new tab

**Per-tuner row content:**

| Tuner state | Display |
|---|---|
| Idle (no channel locked) | Tuner label + "Idle" in dim text |
| Our recording | Tuner label · channel · show title (clickable) · red ● dot · "Ends H:MM AM/PM" |
| Tuned, but not ours (another machine running this app against the same device, or someone watching live via the HDHomeRun's own app/web UI — see CLAUDE.md's "Tuner occupancy" invariant) | Tuner label · channel · "· another tuner" suffix · real currently-airing guide title (clickable) · purple ● dot (`#9b59b6`, matching the guide grid's `.g-st-inuse` ring color) · episode name · "Ends H:MM" · client IP |

**Recording match** (`recsByDevJS` builder): prefers `show_tuner_resource` (case-insensitive); falls back to `show_channel == VctNumber` when the resource header hasn't been captured yet (first ~1.5 s of a new recording). When a tuned channel doesn't match one of our own shows, the title is resolved server-side via `state.guideEntries(deviceId:channelNum:)` (the same currently-airing lookup `WatchNowView`/`buildGuideGridHTML` use) — a real show title, not a generic placeholder; falls back to `"Ch {num} (unmanaged)"` only when there's no guide data at all for that channel. An `external: "1"` flag (distinct from `idle`, which means no channel is locked at all) marks this case explicitly so the client can label it, rather than a user having to infer "not ours" purely from the absence of a red dot.

**Clickable titles — jump to guide:** all non-idle tuner rows have a clickable title (underline dotted, pointer cursor) that calls `goToShow(ch)` — closes the popup, finds the currently-airing `.g-prog` for that channel, scrolls it into view, and calls `showInfo()`. Our own recording rows get this treatment via a synchronous post-render loop. Rows with `external === "1"` additionally fire `fetch('/api/now-airing/{devId}/{ch}')` to patch the DOM with episode name, poster thumbnail, and end time on top of the title already resolved server-side (keyed off the `external` flag, not string-matching the title text, so this doesn't silently stop firing if the server-side fallback wording ever changes).

**Red recording dot** appears on our own rows (`rec === "1"`). **Purple dot** (`#9b59b6`) appears on tuned-but-not-ours rows (`external === "1"`) — same color as the guide grid's `.g-st-inuse` ring, so the two surfaces read as one consistent "not managed by this app" signal.

**Inline signal quality:** every non-idle tuner row with a `chname` fires `fetch('/api/signal-stats/{chname}')` and appends a small line — colored dot + bucket label (`Poor`/`Fair`/`Good`) + `{avg}% avg · {last}% last · checked {relTime}`. Colors match the guide-row SVG bars and `bColors` SSE palette. Skipped when the channel has no samples (server returns `{}`). `relTime()` renders the `checked` epoch as `just now` / `Xm ago` / `Xh ago` / `Xd ago` so stale readings are obvious.

**Generation token (`tPopGen`):** bumped on every `showTunerInfo` open and `closeTunerPop`. Each enrichment fetch (signal-stats and now-airing) captures `gen` at start and bails if `gen !== tPopGen` when its response arrives — prevents stale fetches from a closed/rebuilt popover appending duplicate or outdated DOM.

Active tuner detection: `DeviceTunerInfo` entries where `VctNumber != nil`. Idle slots (returned by the device with only `"Resource"` present) are not counted. Occupancy data comes from `AppState.deviceTunerOccupancy`, kept warm by the idle loop and optimistically updated on recording stop (see Tuner occupancy section).

**`GET /api/now-airing/{devId}/{ch}`** — returns `{title, epTitle, poster, endTime}` for the currently-airing guide entry on that device/channel. `endTime` is a Unix timestamp string.

---

### Summary panel (`#sum`)

Always rendered above the guide grid. Two states:

**Placeholder** (`#sum-ph`): "Select a show from the guide" — on load and after close.

**Selected** (`#sum-c`): appears when the user clicks a program block. Layout (left to right):
- **Poster image** — hidden if no `ImageURL`. Default: 72 px wide, `object-fit: contain`. Tablet (≤ 960 px): 56 px. Desktop (≥ 961 px): 260 px, `align-self: center`. **Progressive loading:** `showInfo()` sets the `<img src>` to the CDN poster URL directly. If the poster fails to load, an `onerror` handler (set in JS each time `showInfo()` runs, not inline) falls back to the channel logo URL; if that also fails, the image is hidden. A `data-pgen` generation counter prevents a slow CDN fetch for an earlier selection from overwriting a later selection's image.

**Short-viewport compaction (`@media(max-height:480px)`)** — a *height*, not width, breakpoint, so it catches landscape phones the width-based tiers above don't (a landscape phone is often wide enough to land in the "tablet" or even "desktop" poster-width tier while still being very short). `#sum` is pinned above the scrollable grid by design (a plain flex item before `.gw-outer`'s `flex:1` region, never inside `.gw`'s own scroll) — on a short screen its *own* height is what starves the grid of room, so below 480px viewport height the poster, genre badge, air-date, and synopsis are all hidden and padding/margin are trimmed, leaving just title/episode + the action buttons. The same bucket also shrinks the toolbar row (`#toolbar` gap/margin, `h1`, per-tuner `.d-btn`/`.tdrop-btn`/`.t-info`/`.t-info-inline`, `.genre-sel`, `#search-in`, `#theme-sw` buttons) — a landscape phone is exactly the case where `#toolbar`'s `flex-wrap` is most likely to overflow, since the row has to fit `h1` + every tuner box + the genre filter + the search box + the theme switcher.

**Single-row summary reflow (same `max-height:480px` bucket):** with the poster/genre/date/synopsis hidden, `#sum-grad` (`flex:1`) still stretched to the card's full width — on a landscape phone that's the whole grid width — leaving a vertical stack of just title/episode/actions/channel-row mostly empty on the right while still costing four lines of scarce height. `#sum-grad` switches to `flex-direction:row` instead: `#sum-title` and `#sum-ep` (`min-width:0`, ellipsis, `#sum-ep` gets a CSS `::before` "·" separator since they're no longer on separate lines) share the left side and truncate under pressure; `#sum-ch-row` (the logo+`#sum-ct` channel/time line — carries that id specifically so this rule can target it) follows inline; `#sum-actions` gets `margin-left:auto` to push Record/Edit/Delete/Watch to the row's right edge. The close `✕` button is a sibling of `#sum-grad` inside `#sum-c`, not a child of it, so it's already pinned at the card's true right edge regardless of this reflow — no separate rule needed for it. `order` values (`#sum-title`:1, `#sum-ep`:2, `#sum-ch-row`:3, `#sum-actions`:4) fix the visual order independent of DOM order (the channel-row `<div>` comes after `#sum-actions` in the markup).

**Toolbar wrap grouping:** `#genre-bar`, `#search-bar`, and `#theme-sw` live inside a shared `#toolbar-right` flex wrapper (`margin-left:auto`, its own `flex-wrap:wrap`) rather than each being a bare top-level child of `#toolbar`. `margin-left:auto` on an individual flex item only pushes it to the right edge of *whatever line it lands on* — if `#theme-sw` were still a standalone item and didn't fit after the filter controls, it would wrap onto its own line and that auto-margin would strand it alone on the far right with a mostly-empty row above it. Grouping them means the browser's wrap decision applies to the group as one unit: all three stay adjacent whether they fit on the tuner-box row or wrap down together.

**Phone compaction (`@media(max-width:600px)`)** — a general narrow-viewport pass, distinct from the height-based one above (both can apply at once — a narrow *and* short phone gets both). Shrinks `body` padding, `h1`, the toolbar controls (`.d-btn`/`.tdrop-btn`/`.t-info`/`.t-info-inline`/`#theme-sw`/`.genre-sel`/`#search-in`), the guide grid (`--ch-w` to 100px, header/tick/logo/channel-name font sizes, `.g-hdr-tl` height, row `min-height` to 44px with `.g-row`'s `contain-intrinsic-size` kept in lockstep, program title/subtitle font sizes, the status-ring badge size), and the record/edit modals (`.mac-sheet` padding, `.em-row`/`.em-lbl`/`.em-input`/`.mac-btn`). Overrides targeting elements with inline base styles in `guide-shell.html` (`.mac-sheet`) need `!important`; class-only targets don't.
- **Info column** (flex: 1):
  - Title (bold, 0.92 rem, ellipsis)
  - Genre badge (uppercase pill) — hidden if absent or `"Series"`
  - Episode info — hidden if absent
  - Original airdate — hidden if absent
  - Synopsis (1-line `-webkit-line-clamp`) — hidden if absent
  - **Actions row** (`#sum-actions`) — directly below synopsis (see below)
  - Channel logo · `"Ch N · Name · HH:MM – HH:MM"`
- **Close button** (✕) — top-right

**Actions row** — three mutually-exclusive states:

| Condition | Elements shown |
|---|---|
| `data-recording="1"` | Red italic "● Recording now" note + dark-red "Stop & Delete" button |
| `data-managed="1"` | Italic "Already scheduled" note + **Edit** button + grey "Remove" button |
| Neither | Red "Record" button (amber "⚠ Record (tuner full)" when device is full and show is live) |

The **Edit** button (`#sum-edit`) is only shown for managed shows that are **not** currently recording — it is intentionally hidden when `data-recording="1"` to prevent changing show config mid-recording. Clicking Edit calls `doEditFromGuide()`, which reads show config from `data-show-*` attrs on the selected `.g-prog` block and opens the edit modal.

**Actions are applied in-place** — no page reload on record or delete. On record success, the selected block gains `.g-prog-sched` (background) + `.g-st-sched` (status ring/badge) and the action row swaps to Scheduled+Remove. On delete success, the block loses its status classes/color and the Record button reappears.

**Status ring + badge** — a program block's disposition (scheduled / recording / will-skip / conflict / in-use-by-other-tuner) is shown as a colored outer ring (`box-shadow`, so genre background stays untouched) plus a small badge glyph in the top-right corner, drawn from Unicode VCR transport-control characters rather than color alone: `.g-st-sched` blue `#3b93ff` ⏱, `.g-st-rec` red `#ff5a5a` ⏺ (ring + badge both pulse), `.g-st-skip` slate `#8a92a3` ⏭, `.g-st-conflict` orange `#ff9500` ⚠, `.g-st-inuse` purple `#9b59b6` ▶. Deliberately not gold/red/green — those stoplight hues imply stop–caution–go, which doesn't match this state set (green for "will skip" reads as "go ahead," backwards). There is no on-page legend; the glyph is meant to be self-explanatory, with the block's `title` tooltip (`stateLabel`, see below) as the fallback for anyone unsure. Precedence (mutually exclusive, one class per block): recording > will-skip > conflict > scheduled > in-use-by-other-tuner.

**In-use-by-other-tuner marker (`.g-st-inuse`)** — a hardware tuner on the device is locked to this channel right now (`AppState.deviceTunerOccupancy`, `VctNumber` non-nil) but for a reason this app doesn't track: not one of this instance's own recordings, and the channel isn't otherwise scheduled/skipping/conflicting. Typical cause: the menu bar's "X/Y tuners in use — app expects Z" mismatch (see CLAUDE.md's "Tuner occupancy" invariant) — another machine running this app against the same physical device, or someone watching live via the HDHomeRun's own app/web UI. Computed via `hwOtherChannelsByDevice` (per device: hardware-locked channels minus this instance's own recording channels), lowest precedence of the five states so it never overrides a more specific/actionable one. `stateLabel` suffix: `— In use on this device (not by this app)`. Same rebuild cadence as skip/conflict/scheduled — recomputed on every full grid rebuild, not the lightweight in-place recording-event patch (which only ever toggles `.g-st-rec`), so on a shared device it can lag up to the next rebuild trigger (add/edit/delete/favorite-toggle/recording start-stop/hourly refresh) behind the other tuner actually starting or stopping.

**Skip-already-recorded marker (`.g-st-skip`)** — when **Series subfolders** *and* **Skip already-recorded episodes** are both on (config `Series_subfolder_enabled` + `Skip_recorded_episodes`), a managed program block whose season/episode (`SxxExx`) is already on disk gets the slate `.g-st-skip` ring/badge **instead of** the blue `.g-st-sched` "will record" one — unless the owning show has `show_ignore_duplicate_once` set (the "Record even if already on disk" toggle in the Add/Edit dialog, see `docs/ShowFormSection.md`), in which case it keeps `.g-st-sched` since the recording will actually happen. The block keeps its `.g-prog-sched` background class either way; only the status ring/badge class changes. Because the ring/badge is decorative (no separate `pointer-events:none` element needed — it's a `::after` on `.g-prog` itself), the state is also spelled out in the block's native `title` tooltip: the program `title · episode (time range)` gets a state suffix — `— Recording now` / `— Scheduled to record` / `— Already recorded · will skip` / `— Conflict: all tuners busy at this time` (or, when `AppState.showRuntime[showId]?.conflictBeatenByFavorite` is true for the owning show, `— Conflict: a favorited channel has priority for this tuner`) — computed by `stateLabel`, same precedence as the ring/badge classes. The recorded `SxxExx` tags per managed series are gathered once per grid build via `AppState.recordedEpisodeTags(forTitle:baseDir:expectedMinutes:renameTruncatedTag:)` (one directory scan per managed series, off the per-block path), then each block compares its `EpisodeNumber` against them. Like the other three states, it is re-emitted on every full grid rebuild (refresh + guide-change SSE), so it survives refreshes; the in-place recording-event patch (which doesn't rebuild the grid) only toggles `.g-st-rec` — it does not recompute skip/conflict/scheduled.

**Conflict marker (`.g-st-conflict`)** — a scheduled-but-not-recording, not-skipped block whose owning show has `AppState.showRuntime[showId]?.isConflicting == true` (rebuilt in `rebuildMenuEntries()`, shared with the native menu's ⚠️ marker). This is a per-device greedy tuner-slot simulation, not a live per-block scan: shows are walked in `(show_next, favorite-first tiebreak)` order and assigned the first free tuner slot; only the show(s) that don't get a slot are flagged — not every member of an over-capacity cluster. A loss to a favorited competitor specifically is tracked separately via that same entry's `conflictBeatenByFavorite` field and changes the tooltip wording (see above).

---

### Record type modal (`#rec-modal`)

Styled to match `#edit-modal`: same 480 px width (widened from 400px so the Type button row fits on one line without wrapping — see the Type row entry below), `max-height: calc(100vh - 40px)`, scrollable, themed via `var(--s2)` / `var(--b2)` CSS variables. `position: fixed` overlay (z-index 100). Appears when Record is clicked.

Mirrors the native Add Show wizard's Details step (`ShowFormSection`) minus the Folder field (the server keeps the config default directory) — kept in sync deliberately.

**Contents (top to bottom)** — ordered to match the native Add/Edit Show field order (`ShowFormSection.swift`): fields common to every recording Type come first, then the fields unique to whichever Type is selected, pushed to the bottom:
- **"Record Show"** header with border-bottom separator
- **Title row** — `em-lbl` "Title" label + editable `<input id="rm-title-in">` prefilled with the guide title + channel/time below (read-only, `#rm-ch` — stays visible regardless of Scope, unlike the Edit modal's editable Channel field below: it names the specific airing being added from, not a lock, so there's nothing misleading about showing it even for an All-scoped show), and a **signal bars** holder (`#rm-sig`) under that. `renderRmSignal()` (called from `doRecord()` and `switchAiring()`) fetches `/api/signal-stats/{_chname}` and renders a 3-bar SVG (same `poor #e53935 / fair #fbc02d / good #43a047` palette as the guide-row bars) when `_sigEnabled` and the channel has data; blank on disabled/no-data/error. Guarded against a `switchAiring` race (ignores a response whose `_chname` no longer matches).
- **Type row** — `em-lbl` "Type" label + a joined segmented-bar control (`.rm-type-row`: single 1px border, rounded corners, `overflow:hidden`; `.rm-type-btn` segments have no own border/radius, just a `border-right` divider between them, none on the last), one segment per `topOpts` entry — **Single · DateTime · SeriesID** (as of 2026-08-23; collapsed from the 4-way `recOpts` table, mirroring native's Type/Scope split — see `docs/ShowFormSection.md`'s "Type/Scope split") — matching native's `.pickerStyle(.segmented)` Type picker instead of separate pill buttons with gaps between them. A single description line (`#rm-type-desc`) below the row shows the selected option's longer explanation, updating on click. Built and wired up by the shared `renderTypeRow(containerId, descId, selected, onSelect)` helper (also used by the Edit modal) — plain buttons with a `.sel` class for the active one, not radio inputs; `selected` is the real type string (`'single'`/`'dateTime'`/`'seriesChannel'`/`'seriesAll'`) but `renderTypeRow` collapses it via `topOptFor()` for highlighting purposes, and `onSelect` is called with the *clicked top-level value* (`'single'`/`'dateTime'`/`'seriesID'`), not the real type — the caller resolves `'seriesID'` to a concrete type (defaulting to `'seriesChannel'`, or preserving the current scope if already a series type) and stores it in `_rmType` (read by `confirmRecord()` and the Day-button click handler) rather than a `:checked` DOM query. `recOpts` (the original 4-way table) is kept around unchanged — `typeLabel()` (the delete-confirm dialog's "Type: SeriesID(Channel)" text) still needs the precise granular label.
- **Scope row** (`#rm-scope-row`, `em-row` style) — a 2-segment `.rm-type-row` (`#rm-scope`, built by `renderScopeRow(containerId, selected, onSelect)`) — Channel · All — visible only when the Type row's collapsed SeriesID segment is selected (i.e. `_rmType` is `'seriesChannel'`/`'seriesAll'`), re-evaluated on every Type-row click. Selecting a segment sets `_rmType` directly to `'seriesChannel'`/`'seriesAll'` and re-renders the Other Upcoming Airings list (`renderAirings(_airCache[_ser]||[])`, see below) so it re-filters to the new scope immediately. Mirrors native's Scope Picker (`docs/ShowFormSection.md`).
- **Transcode row** — `em-lbl` "Transcode" label + `<select id="rm-transcode">` with the same 4 options as the edit modal. Defaults to `config.Default_transcode` (allowlist-sanitized server-side) each time the modal opens, not a hardcoded `"none"`.
- **Bonus Time row** (`#rm-bonus-row`, `em-row` style) — hidden entirely when `config.Sports_padding_enabled` is `false`; `em-lbl` "Bonus Time" label + `.mac-check` checkbox (native's default Toggle style outside a List/Form is a checkbox, not a switch) with adjacent text `+{Sports_padding_minutes} min past guide end`. Auto-checked for Sports-genre entries only when bonus is enabled.
- **Days row** (`#rm-days-row`, `em-row` style) — visible for `single` (label "Day") and `dateTime` (label "Days"); hidden for series types. Pre-checked to the guide entry's day of week. For `single`, clicking a day moves the selection to it (clicking the already-selected day clears it — matches the native wizard's single-day Toggle semantics exactly, including allowing zero selected). For `dateTime`, days multi-toggle with at least one required (last-day deselect is blocked). Switching Type back to `single` collapses the selection back to the guide entry's weekday.
- **New Only row** (`#rm-new-row`, `em-row` style) — a "Skip reruns" `.mac-check` checkbox (`#rm-new`), mirroring the native dialog's `show_new_only` toggle (`docs/ShowFormSection.md`). Visible for every Type except `single`, re-evaluated on every type-picker click; unlike Duplicate Episodes below, not gated by any server-side config flag. Unchecked by default each time the modal opens.
- **SeriesID row** (`#rm-sid`, `em-row` style) — visible when a series type is selected; value in `em-sid` monospace style. Web-only (no native equivalent in Add Show), placed after the fields common to every Type.
- **Other Upcoming Airings row** (`#rm-airings`, `em-row` style) — visible when a series type is selected *and* the (possibly channel-filtered, see below) airings list has at least one entry after excluding the one just selected. Each `.rm-air-row` (mirrors the tuner dropdown's `.sp-row` list styling) has: a genre-color accent bar (`gc(a.genre)`, same mapping as the guide grid), the channel logo (`.rm-air-logo`, 18px, hidden via `onerror` if it fails to load), and a two/three-line info column — bold day+time, secondary `Ch N · Name`, and episode info when the guide has it. Rows are separated by a bottom border (`.rm-air-row`), not full card backgrounds — same list language as `.sp-row`; hover tints the row and the cursor becomes a pointer as a click affordance. Fetched once per series per modal-open and cached client-side (`_airCache`); a generation counter (`_airGen`) discards a response that arrives after the modal was reopened for a different program. Web-only (native `AddShowView` shows the equivalent panel below the whole form, not inline; neither Edit view has one at all). **Channel-scoped as of 2026-08-23:** `renderAirings()` filters the cached (always-unfiltered) list to `_n` (the current channel) whenever `_rmType==='seriesChannel'` — seriesChannel only ever records from that one channel, so the preview would otherwise list airings this show could never actually catch; seriesAll stays unfiltered. The Scope row's click handler (below) re-calls `renderAirings(_airCache[_ser]||[])` on every Channel/All toggle so the list updates live without a re-fetch — mirrors native's `AddShowView`, whose `channelNum` filter is applied server-side instead (`docs/AppState.md`'s `upcomingGuideEpisodes`).
- **Double-click a row to switch the modal to that airing** (`switchAiring(idx)`) — re-anchors `_d`/`_n`/`_s`/`_e`/`_genre`/`_title` to the clicked airing (looked up from `_airCurrent`, the last-rendered filtered array), updates the title input and the `Ch N · Name · time` line, re-checks the tuner-full warning for the (possibly different) device, and re-renders the airings list from the same `_airCache` entry — which now excludes the newly-selected airing and re-includes whichever one was previously selected. Selected Type/Transcode/Bonus are left untouched. Native parity: `AddShowView.switchToAiring(channel:entry:)`.
- **Tuner-full warning** (`#rm-tuner`) — amber banner shown when device is full and show is currently airing
- **Weak-signal warning** (`#rm-sig-warn`) — amber banner (same style as `#rm-tuner`) shown by `renderRmSignal()` when the channel's signal bucket is `poor`; hidden otherwise
- **No-transcode warning** (`#rm-no-transcode`, added 2026-08-28) — amber banner (same style as `#rm-tuner`/`#rm-sig-warn`) shown by `updateNoTranscodeWarn()` whenever `#rm-transcode`'s picked value isn't `"none"` and `noTranscode(_d)` (`tuners[_d].nt`, truthy) — "This tuner doesn't support transcoding — the Transcode setting above will be ignored and recorded as None." Purely informational, mirroring `ShowFormSection`'s native banner (`docs/ShowFormSection.md`) — the real enforcement is `AppState.startRecording`'s unconditional `device.supportsTranscode` override (CLAUDE.md's "Transcode capability gate" invariant), which applies whether or not this banner was ever shown. Re-evaluated on the transcode `<select>`'s own `onchange`, at the end of `doRecord()` (after seeding `_defaultTranscode`), and at the end of `switchAiring()` (since `_d` can change to a different device). The `nt` field itself is baked into the `tuners` JS object server-side (`WebServer.swift`'s `tunerJS` builder) as `d.supportsTranscode ? 0 : 1` — `HDHRDevice.supportsTranscode` is the same `ModelNumber`-`"HDTC"`-prefix check the native app uses, so a device's capability can never disagree between the two UIs.
- **Footer** with border-top separator — Cancel / Schedule buttons

**Config staleness:** `_defaultTranscode`, `_bonusEnabled`, and the bonus row's minutes label are baked into the served HTML at page-generation time (same as `_bonusMins`) — a config change in Settings takes effect on the next guide load (page refresh or the hourly `guide_refreshed` reload), not immediately.

On **Schedule**: `confirmRecord()` collects selected air days from `#rm-days .day-btn.sel`, the transcode value from `#rm-transcode`, the trimmed title from `#rm-title-in` (included in the POST only if it differs from the original guide title — see `title` field above), and `#rm-new`'s checked state as `newOnly`, then POSTs to `/api/record`. The transcode value is applied to the new show (overriding the config default). On success:
- Guide block gains `.g-prog-rec` + `.g-st-rec` (red ring, pulsing ⏺ badge) if `recStarted` is true (show currently airing); otherwise `.g-prog-sched` + `.g-st-sched` (blue ring, ⏱ badge).
- Summary note shows "● Recording now", "⚠ Queued — all tuners busy", or "★ Scheduled — next idle loop pick-up".
- The summary delete button becomes **"Stop & Delete"** (+ `danger` class) when `recStarted`; stays **"Remove"** otherwise.
- Tuner badge `#tun-{devId}` is updated in place with the new active/total count from `tunerActive`/`tunerTotal`.
- No explicit `refreshGuide()` call — `/api/record`'s `addShow`/`updateShow` already broadcasts a `show_updated` guide-change event over SSE, which this same tab applies via `applyGuidePayload()` (including re-selecting the block and refreshing per-tuner dropdown bodies) just as `refreshGuide()` would have; calling both meant every Record rebuilt the grid server-side twice.

---

### Guide grid

A cable-TV-style horizontal time grid. Desktop and mobile clients both get the full `GuideHours` window (default 24 h) — `winSec = GuideHours * 3600` regardless of UA. There is no UA-based branching left anywhere in the request path — `isDesktopUA`, the `isDesktop` parameter threaded through `buildGuideGridHTML`/`buildHTML`, and the `userAgent` parameter threaded through `route`/`routeOnMain` were all removed as dead code once UA no longer affected window size or which cached page HTML is served (see "HTML cache" above — one shared `cachedHTML` now covers all UAs); the server no longer parses `User-Agent` from request headers at all.

**Window start:** `winStart = (nowTs / 1800) * 1800 - 3600` — floors to the nearest 30-minute boundary then subtracts one hour, giving a 60–90 minute lookback. `GuideStore.entries()` is called with `after: Date(winStart)` (not the default `after: Date()`) so shows that already ended but fall within the lookback are included. Gap periods with no guide data render as `.g-gap` divs (fully opaque `var(--bg)`) so the striped `.g-tl` background never shows through. On page load, `scrollToNow()` is called inside the `requestAnimationFrame` callback (alongside the auto-select IIFE) so the now-line sits ~25% from the left of the visible viewport after the first paint.

**Live now-line:** `_winStart` and `_winSec` are baked into the page JS at render time. `nowPct()` recomputes the now-line position as `(Date.now()/1000 - _winStart) / _winSec * 100`, clamped to [0, 100]. `updateNowLine()` updates the `left` style (or `top`, under vertical time-axis mode — see below) on all `.g-now-bar` and `.g-now-tick` elements every **1 minute** via `setInterval` — and is also called once **immediately** at page-load time (right before the `setInterval` call). That immediate call matters: `GET /` serves `cachedHTML`, pre-rendered by `prebuildPageHTML()` at the last guide refresh, add/delete/pause/resume/edit/favorite-toggle, or recording start/stop (see "HTML cache" above — rebuilds are frequent in an active session, but nothing guarantees one happened recently if the guide has been quiet), so the now-line position baked into the HTML reflects whenever that prebuild last ran, not the moment this particular browser actually loaded the page — `setInterval`'s own first tick doesn't fire for a full 60s, so without the immediate call the line could sit stale for up to a minute after every fresh load. `refreshGuide()`'s DOM swap mostly avoids this problem — `/api/guide-refresh` reuses `cachedGridHTML` (the grid built by the most recent guide-changing broadcast) rather than calling `buildGuideGridHTML` live, but since `winStart` only ever changes at an hour boundary (see "Window start" above) and the hourly `refreshGuides()` rebuild keeps that cache aligned to the current hour, the two are equivalent except for the same narrow post-hour-boundary staleness window `GET /`'s `cachedHTML` already has (bounded to one idle-loop tick).

**`refreshGuide()` must resync the window origin.** The grid header (`.g-hdr`, inside `.gi`) carries `data-winstart` / `data-winsec`. Because `refreshGuide()` swaps in a grid that the server rendered against a *fresh* `winStart` (it advances at each hour boundary), `refreshGuide()` re-reads those attributes from the newly-swapped `.g-hdr` and updates `_winStart`/`_winSec`. Without this, `nowPct()` would keep plotting against the stale page-load origin on the new grid and the now-line would drift ahead over time (visible after the guide sits open through an hourly `guide_refreshed`). It also auto-scrolls the guide if the now-line has drifted past **75%** of the viewport width, nudging it back to the 25% position — without disturbing users who have manually scrolled ahead (their now-line is near the left edge, well below the threshold).

**Page staleness:** two guards run every 60 seconds via `checkFreshness()`: (1) if `Date.now()` exceeds the baked-in `_exp` timestamp (render time + 2 hours), the page hard-reloads; (2) `/api/ping` is fetched and its `version` field compared to the baked-in `_ver` — mismatch means a redeploy has occurred, triggering `location.reload()`. The version check catches redeployments within 60 seconds; the `_exp` expiry handles long-open stale tabs.

`div.gi` `min-width` = `max(1200, winSec / 1800 * 100)` px — scales up for wider windows so program blocks never compress below a readable width.

**Layout:**
- `div.gw-outer` — flex child of body (`flex: 1; min-height: 0; display: flex; flex-direction: column`); grows to fill all remaining viewport height below the toolbar and summary card; `overflow: clip` clips the rounded border
- `div.gw` — scroll container (`overflow: auto; flex: 1`); fills `.gw-outer` vertically so the guide always extends to the bottom of the window with no dead space
- `div.gi` — inner, `min-width` scales with window (see above)
- `div#pull-refresh` — `position: absolute; top: 0` sibling of `.gw` inside `.gw-outer`, holding a spinner (`.pull-spin`). Sits behind `.gw` (which has an opaque background), revealed as `.gw` is translated down. See "Pull-to-refresh" below.
- Sticky time-header (`top: 0; z-index: 10`)
- Sticky channel column (`left: 0; z-index: 2`) — both data rows (`.g-ch`) and the header cell (`.g-hdr-ch`) share width via the `--ch-w` CSS custom property (**125 px** default, **100 px** under the `max-width:600px` phone breakpoint — bumped up from an original 86px, alongside a `.g-cn`/`.g-cname` font-size reduction and an `overflow:hidden;text-overflow:ellipsis` backstop, after 86px let channel number/name text overflow into the favorite star and timeline on narrow phones; `#g-hscroll`'s `left` offset also reads it). They must match so the `nowPct%` left offset maps to the same pixel position in both the time header and program rows. `guide.js` never hardcodes this value — `chW()` reads `--ch-w` live via `getComputedStyle` so `nowPx` (used by `updateNowLine()`, `scrollToNow()`, and the now-button visibility check) stays correct at any breakpoint.
- Program-block positioning itself (`.g-tick`/`.g-now-tick`/`.g-now-bar`/`.g-gap`/`.g-prog`) is emitted by `buildGuideGridHTML()`'s `pct()` helper as CSS custom properties — `style="--gs:{start%};--gw:{width%}"` — rather than literal `left:`/`width:`. The base CSS rules for those classes then read `left:var(--gs)`/`width:var(--gw)`, which renders identically to the old direct-inline approach in the default orientation but lets **vertical time-axis mode** (below) reinterpret the same numbers as `top`/`height` instead, without any second server-side rendering path.
- Corner cell (`z-index: 11`) — flex row: "Ch" label (`.g-hdr-ch-lbl`) left, two icon buttons (`.g-hdr-btn`) right: **⊙** calls `scrollToNow()` (now-line to ~25% of viewport), **↺** calls `refreshGuide()` (scroll-preserving DOM swap — not a page reload). Sticky top+left, so the controls stay visible while scrolling the grid in any direction.

**Lazy row rendering:** each `.g-row` carries `content-visibility: auto; contain-intrinsic-size: auto 55px`. The browser skips style/layout/paint for rows scrolled out of view and renders them on demand as they approach the viewport, so the initial paint costs only the ~12 on-screen rows instead of all ~100 — the dominant cost on a full guide (1300+ program blocks, per-row repeating-gradient backgrounds). `contain-intrinsic-size` reserves each skipped row's height so scrollbar geometry is correct before render; the `auto` keyword caches the real measured size after a row renders once. This applies to data rows only, not `.g-fav-sep`/`.g-rec-sep` separators, and survives `refreshGuide()` DOM swaps since it is pure CSS. Requires a `content-visibility`-capable engine (Safari 18+/WKWebView on macOS 15+, Chrome 85+); older browsers degrade to rendering all rows up front (prior behavior).

**Lazy heavy-data loading:** `.g-prog` blocks ship only light attrs (`data-title`, `data-start`/`data-end`, `data-device`/`data-num`/`data-chname`, `data-genre`, `data-filters`, `data-logo`, `data-series`, `data-managed`, `data-recording`) in the initial grid HTML. Heavy fields (Synopsis, poster `ImageURL`, episode title/number, original air date — `data-syn`/`data-poster`/`data-ep`/`data-date`) are fetched on demand via `/api/guide-detail/{devId}/{ch}/{winStart}/{winSec}`, one batched request per channel row. A page-level `IntersectionObserver` (`initRowObserver()`, root = `.gw`, `rootMargin: 400px`) watches every `.g-row`; when a row nears the viewport it fetches that channel's heavy data once, patches every matching `.g-prog`'s `dataset` in place, and `unobserve`s the row (heavy data for a given row never changes except across a `refreshGuide()` swap). Results are cached client-side in `_heavyCache`, keyed by `"device:channel:start"` — cache hits on a `refreshGuide()`-swapped row apply synchronously with no network round-trip. `fetchRowHeavy()` de-dupes concurrent requests for the same row via `_heavyRowsInFlight` (a `Map` of `"device:channel"` → the in-flight promise, not just a presence flag) so a second caller racing the first (e.g. the observer firing while a click's JIT fetch is also pending) chains onto the real fetch's result instead of resolving early with blank data. `showInfo()`'s poster/episode/date/synopsis rendering goes through `renderHeavyFields(el)` → `paintHeavyFields(el)`, which paints from cache/dataset immediately and falls back to a just-in-time single-row fetch (guarded by a per-element generation token, mirroring the existing `pi.dataset.pgen` idiom) for the case where a block is clicked before its row's observer has fired — e.g. a fast scroll-and-click, or the initial auto-selected "now" block, which runs inside `requestAnimationFrame` and may execute before `initRowObserver()`'s callback. `showInfo()` marks `.g-sel` on the clicked element *before* calling `renderHeavyFields()` so `paintHeavyFields()`'s selection check is accurate on the very first (synchronous) paint. `initRowObserver()` is re-run after every `refreshGuide()` DOM swap (new `.g-row` elements need fresh observation).

**Hover prefetch (added 2026-08-21):** a delegated `mouseover` listener on `document` also warms a
tile's row via the same `applyHeavyFromCache`/`fetchRowHeavy` path the scroll observer uses, so a
tile the pointer dwells on before a click is usually already cached by click time. Gated behind a
~150ms dwell timer (`_hoverPrefetchTimer`/`_hoverPrefetchEl`) keyed to the specific `.g-prog` last
hovered — a fetch only actually fires if the pointer stays on that one tile past the timer, not on
every tile the cursor merely passes over. Without the debounce this fired on every element boundary
`mouseover` crosses (not just intentional hovers): a synthetic sweep of a real ~2600-tile guide fired
100+ concurrent fetches instantly, backing up the MainActor-serialized server behind unrelated
click-driven requests — see `issues_resolved.md`. With the debounce, the same sweep fires zero
immediate fetches; a genuine hover-and-pause still fires exactly one.

**Rows:** one row per (device × channel). Cross-device deduplication is handled client-side by `setDev('')` on page load — it hides duplicate `GuideNumber` rows keeping the first-device occurrence, giving a clean "All" view.

Each `.g-row` carries `data-dev`, `data-ch`, `data-gname` (`GuideName.lowercased()`), `data-fav` (`"1"` for favorite channels, absent otherwise), and `data-rec` (`"1"` for a channel with an active or pending-window recording, absent otherwise). `data-gname` is the key used by `signal_update` SSE events; `data-fav`/`data-rec` are used by `setDev` to show/hide the `.g-fav-sep`/`.g-rec-sep` headers. Individual `.g-prog` blocks carry `data-inf="1"` when their guide entry's `SeriesID` matches a confirmed paid-programming ID — see Infomercial dimming below.

**Recording section:** channels with an active or pending-window recording (same `recChannelsByDevice`/`pendingRecChannelsByDevice` sets `buildGuideGridHTML` uses for the `.g-st-rec` ring) sort to the very top of each device's channel list, *above* Favorites — a channel already recording is a stronger claim on attention than a merely-favorited one, and a channel that's both only appears once, in this section. A `.g-rec-sep` separator row (`--vc-rec` red `● RECORDING` label, same shape as `.g-fav-sep`) is inserted above the first such row per device and hidden via `setDev` the same way `.g-fav-sep` is. Recording channel rows get the same `color-mix(...)` background/gradient tint treatment as favorite rows, just keyed off `--vc-rec` instead of `--fav` — plus (2026-08-29, fixed live against a real recording) the channel number/name text itself (`.g-cn`/`.g-cname`) is colored solid `--vc-rec`, not just background-tinted: the 16% background mix alone read as a muddy olive/brown against some channel logos, carrying none of the visual weight the row's own `.g-st-rec` ring + pulsing badge already has. This section-level marker is server-rendered only — the row's actual DOM position only changes on a full grid rebuild-and-swap (`applyGuidePayload`), not on the lightweight ring/class patch `recording_started`/`recording_stopped` (see below) apply in place. **On stop** (fixed 2026-08-21 — see `issues_resolved.md`), `teardownRecordingState` calls `WebServer.broadcastRecordingStopped`, which fires both `broadcastRecordingEvent` and `broadcastGuideChangeEvent` (same two-message SSE shape as before) but builds the grid **once** and shares it between them, rather than each independently paying for `buildGuideGridHTML` — so the channel drops back out of this section immediately, at the cost of one grid rebuild per stop rather than two. `deleteShow`'s use of this path (`alsoRebuildGrid: false`) skips the guide-change broadcast/rebuild entirely, since its own subsequent `pushShowUpdate` after removing the show rebuilds the grid again anyway. **On start**, this gap still exists — a channel doesn't jump into the Recording section immediately, only gets the ring color while staying in its prior position until the next full rebuild (page load, hourly `guide_refreshed`, or any add/edit/delete/favorite-toggle). Scoped narrowly to what was reported; symmetric fix on start not yet done.

**Favorites section:** favorite channels (excluding any already in the Recording section above) are sorted next in each device's channel list server-side. A `.g-fav-sep` separator row (amber `★ FAVORITES` label, `display:flex`) is inserted above the first favorite row per device and hidden via `setDev` when no visible favorite rows remain (e.g. another device selected). Favorite channel rows get a golden background tint via `color-mix(in srgb, var(--fav) 16%, var(--s1))` on `.g-ch` and a repeating gradient tint on `.g-tl`. A `☆`/`★` toggle button (`.g-fav-btn`) in each channel cell calls `toggleFav(evt, btn)` to POST `/api/toggle-favorite`.

**Signal bars in channel column:** when `state.config.Signal_quality_enabled` and signal data exists for a channel, a 3-bar SVG (`class="g-sig"`, `viewBox="0 0 11 10"`, `width/height=10`) is baked into the `.g-ch` cell at page build time. Buckets map to fill levels: `good` → all 3 bars, `fair` → 2 bars, `poor` → 1 bar, `noData` → no SVG emitted. The `title` attribute carries `"Signal: {bucket}"` for hover. Bars are updated in-place on `signal_update` SSE events without a page reload.

**`setDev()` and DOM caching**: `.g-row` NodeList is cached into `_rows` at page load and reused on every device switch — avoids repeated `querySelectorAll` calls. When `setDev(id)` is called with a **different** device ID than `curDev`, `_genreFilter` is reset to `''`, the `<select id="genre-sel">` is reset to the blank option, any active show-search filter is cleared (`clearSearchFilter()` — see "Show search" below), and `rebuildGenreFilter()` (below) re-runs so the dropdown reflects that device's own genres rather than whichever device was previously selected. Both filters are scoped to "the tuner you're viewing," so a device switch invalidates either.

**Genre filter — rebuilt live, not just at page load (2026-08-10):** a `<select id="genre-sel">` (in `#genre-bar`, hidden unless the *currently viewed device* has ≥2 distinct genres, new-episode programs, or infomercial programs) is populated by `rebuildGenreFilter()` from unique `data-genre` values, scoped to `.g-prog[data-device="curDev"]` (or all devices when `curDev` is falsy) — so switching tuners shows that tuner's own genres, not a stale union from whichever device was selected at page load. A **New** option (value `__new`) is appended if any in-scope `data-new="1"` programs exist, and an **Infomercials** option (value `__inf`) if any in-scope `data-inf="1"` programs exist. `rebuildGenreFilter()` runs at initial page load, inside `setDev()` whenever the device actually changes, and at the end of `applyGuidePayload()` (i.e. after every guide-data pull — the hourly `guide_refreshed` SSE refresh and any `show_added`/`show_updated`/`show_deleted`/`favorite_toggled` grid-changed push) so a genre that only exists in freshly-pulled data becomes selectable without a manual page reload. `filterGenre(g)` sets `_genreFilter`, clears any active show-search filter (mutual exclusivity — see below), and calls `applyFilterDim()`, which adds `.g-prog-dim` (35% opacity, `pointer-events: none` — dimmed and unselectable) to every program that doesn't match. In new-episode mode (`__new`), non-new programs dim. In infomercial mode (`__inf`), non-inf programs dim. In normal mode, non-genre-matching programs dim and infomercials are always dimmed. Rows are never hidden — only individual programs are dimmed. `setDev()` calls `applyFilterDim()` after row visibility changes so the dim state survives device switches and `refreshGuide()` DOM swaps.

**Show search (`#search-bar`, added 2026-08-28):** a text input next to the genre filter that finds a show by name and jumps the guide to it. Current-tuner-only, mirroring the genre filter's own per-device scope, and mutually exclusive with it — selecting one clears the other, so at most one dim reason is ever active.

**Channel jump (`#5.1`-style query, added 2026-08-31):** typing `#` followed by digits into the same box scrolls straight to the first *currently visible* row (`.g-row[style.display!=='none']`, same per-device scope `setDev` already enforces) whose channel number starts with what's typed, live on every keystroke via `jumpToChannelPrefix()` — no Enter, no dropdown, no server round-trip (it's a plain scan of the already-rendered `.g-row` elements' own `data-ch`). Mirrors `hdhr_guide`'s own `#5.1` channel-jump (`docs/TUIGuide.md`'s "Search / channel-jump") exactly, including the "first prefix match wins" rule rather than a stricter "only when unambiguous" one — typing `#5` jumps immediately to whichever visible channel numbered `5*` sorts first, `#5.1` narrows further if that wasn't the intended one. `onSearchInput()` branches on this before the length-3 show-search gate, so a `#`-prefixed query never reaches `runSearch()`/the dropdown at all. No-op (stays put) when nothing currently visible matches yet, same as the TUI. Purely a scroll — doesn't touch `_genreFilter`/`_searchShow` or `applyFilterDim()`, unlike selecting a show search result.

**Collapsed by default (added 2026-08-28, second pass):** `#search-in` normally sits collapsed to width 0/opacity 0 behind a small always-visible `⌕` icon button (`#search-icon-btn`), and expands via plain CSS `:hover`/`:focus-within` on `#search-bar` (`guide.css`) — no JS tracks hover/focus state; moving the mouse over the bar or tabbing/clicking into it is enough. The one state CSS alone can't cover is an active filter chip: `selectSearchShow`/`clearSearchFilter` add/remove a `.has-filter` class on `#search-bar` so the box stays expanded showing the chip even after the click that picked a result blurs the input (see "Show search" below on why that blur happens). The expand transition (width/padding/margin, plus a small one-shot scale-pop on the icon itself, `@keyframes searchIconPop`) rides the same `cubic-bezier(.22,1,.36,1)` overshoot curve `.sb-anim`'s `@keyframes sbPop` already uses elsewhere in this file, so it reads as the same "flourish" language rather than a plain linear resize. `syncSearchIconAria()` mirrors the live `:hover`/`:focus-within`/`.has-filter` condition onto `#search-icon-btn`'s own `aria-expanded` (distinct from `#search-in`'s `aria-expanded`, which already means "the results dropdown is open" per the combobox ARIA pattern below) via `mouseenter`/`mouseleave`/`focusin`/`focusout` listeners plus explicit calls from `selectSearchShow`/`clearSearchFilter` (a class toggle fires none of those four events on its own). `#search-icon-btn` also carries `aria-controls="search-in"`, the standard disclosure-button pairing for `aria-expanded` and the same pattern `#search-in` itself already uses for `#search-drop` (`aria-controls="search-drop"`) below. Collapsing via CSS rather than `display:none`/`visibility:hidden` is deliberate: `#search-in`/`#search-info-btn` stay in the normal Tab order at all times, and focusing either one (Tab, not just a click) satisfies `:focus-within` and reveals it in the same paint — there's no keyboard trap where a control is reachable but invisible.

**Type-to-search:** typing a plain, unmodified, single printable character anywhere in the guide — nothing already focused/editable, no Record/Edit/Delete-confirm modal open (`anyGuideModalOpen()`), no filter chip already active — pops `#search-bar` open via a document-level `keydown` listener that focuses `#search-in`, seeds its value with the pressed key, and calls `onSearchInput()`, exactly as if the user had clicked in and typed it themselves (`e.preventDefault()` on the same keystroke also stops Firefox's own "quick find" from opening on `/` or `'`). **`/` is special-cased** to just open/focus the box without being typed into it — the same dedicated "enter search" key `hdhr_guide`'s own `Mode.search` uses (`docs/TUIGuide.md`'s "Search / channel-jump"), for consistency across clients — and resets any leftover uncommitted text first, so `/` always hands back a fresh, empty, focused box rather than resuming an abandoned query. Since `AddShowView`'s Guide step embeds this exact same page in a `WKWebView`, `/` works identically there — no separate native implementation needed. **Space is deliberately excluded** despite being a printable character: every `.g-prog` block is `role="button" tabindex="0"` with its own `onkeydown` activating on Space (`buildGuideGridHTML` in `WebServer.swift`), and native `<button>`s activate on Space's `keyup` gated on this `keydown`'s default not being prevented — hijacking Space here would both mis-fire a spurious search *and*, via this listener's own `preventDefault()`, silently break Space as a keyboard-activation key everywhere else in the guide. The listener's checks are ordered cheapest-first (plain property reads before `anyGuideModalOpen()`'s DOM lookups) so the common case — arrow keys, Tab, Escape, modified shortcuts, all of which reject before reaching that point — costs no DOM work. **Errant-keystroke guard:** `armSearchStrayTimer()`, called from every `onSearchInput()`, arms a 5s timer whenever the box holds exactly one character; if nothing else happens in that window (no more typing, no filter picked), the timer clears the box and blurs it — collapsing it back to the bare icon via the same CSS the mouse-leave path uses — on the theory that a single stray key with no follow-up was aimed at the guide underneath, not the search box. Re-armed (or canceled, if the length no longer qualifies) on every keystroke, and canceled outright the moment a show is actually selected (`selectSearchShow`).

Typing 3+ characters debounces (~200ms) a fetch to `GET /api/guide-search/{deviceId}/{query}` (deviceId resolved by `searchDeviceId()` — `curDev`, or the lone online tuner button's id for a single-tuner setup where `curDev` stays `''`, same fallback `handleDevClick` uses); results render into `#search-drop` (poster thumbnail, title, airing count/channel) and are navigable with `ArrowUp`/`ArrowDown` (`_searchHi` tracks the highlighted row) and `Enter`/click to select — scoped to `#search-in`'s own `onkeydown`. Selecting a show (`selectSearchShow`) builds `_searchShow = {title, seriesId, airings, airingKeys, idx}` — `airingKeys` is a `Set` of exact `"device:ch:start"` triples from the endpoint's response, checked directly against each `.g-prog`'s own `dataset` in `applyFilterDim()` (no client-side title/SeriesID re-matching, so it can't drift from what the server already decided belongs to the show) — clears `_genreFilter`, switches `#search-in` to `readOnly` (styled as a filled pill, `#search-in[readonly]`) showing the title, with a `"(i/N)"` airing counter appended only when the show has more than one airing (`updateSearchCounter()`) — a single-airing show shows the bare title — shows the `#search-clear` ✕ button, and jumps to `airings[0]` via the same `.g-prog[data-device][data-num][data-start]` exact-match lookup `jumpToGuide` uses, then `scrollIntoView` + `showInfo`. Once a show is selected, `ArrowLeft`/`ArrowRight` episode-cycling (`cycleSearchEpisode(±1)`, clamped at both ends of `airings` — no wraparound) is handled by a **global** `document`-level `keydown` listener, not `#search-in`'s own `onkeydown` — selecting a dropdown result by mouse click blurs the input (`mousedown` on the non-focusable `.search-row` moves focus to `<body>`), so scoping the arrow keys to input focus would silently stop working right after the most common way to select a show. The global listener (`anyGuideModalOpen()` guard + an "is this an actually-editable non-search text field" `document.activeElement` check) skips when a Record/Edit/Delete-confirm modal is open or focus is genuinely inside an editable text input, so it can't steal caret-movement keys from those; `#search-in` itself is exempted from that check since it's `readOnly` in chip mode. `Escape`/`Backspace`/`Delete` (still input-scoped, via `onSearchKeydown`) call `clearSearchFilter()`.

**Search help popover (`#search-info-btn`/`#search-help`, added 2026-08-28):** a `ⓘ` button next to `#search-in` — the web guide's equivalent of the native app's `InfoButton` (`Sources/hdhr_VCR/Views/InfoButton.swift`, an `info.circle` icon that pops explanatory text in Settings), reimplemented in plain HTML/CSS/JS since the web guide has no SwiftUI to share it with. `toggleSearchHelp(event)` toggles `#search-help` (a static explainer: search threshold, ↑/↓/Enter for the dropdown, ←/→ for episode cycling, Esc/✕ to clear) and closes the results dropdown first (`closeSearchDrop()` — the two panels share the same anchor point and are mutually exclusive); `event.stopPropagation()` keeps that same click from immediately re-closing it via the outside-click handler below. Closed by: the outside-click handler (extended to call `closeSearchHelp()` whenever a click lands outside `#search-bar`), `onSearchInput()` (typing again implies the explainer's been read), and `Escape` (`onSearchKeydown`'s Escape branch now closes both the dropdown and the help panel, whichever is open).

`applyFilterDim` — the single dim function shared with the genre filter (renamed from `applyGenreDim`, 2026-08-28) — checks `_searchShow` first, before the genre/new/infomercial branches, so every existing `applyFilterDim()` call site (`setDev`, and `applyGuidePayload`'s `setDev(curDev)` after every refresh) reapplies whichever filter is active with no new wiring.

**Infomercial dimming:** individual `.g-prog` blocks get `data-inf="1"` on the program element itself (not the row) from `e.isInfomercial` (`GuideEntry` in `Models.swift` — single source of truth, added 2026-08-21), computed in `buildGuideGridHTML()`. That property checks three signals: (1) guide entry `SeriesID` matches a confirmed paid-programming ID (`C11809220ENAPZK`, `C459763EN3L6D`), (2) `Title == "Paid Programming"`, or (3) — XMLTV-sourced entries only, added 2026-08-10 — `Filter` contains `"Shop"`/`"Shopping"` (case-insensitive), SiliconDust's own explicit paid-programming category tag; `guide.php`-sourced entries have no such tag and rely on (1)/(2) only. A channel that airs one overnight infomercial slot is unaffected on its other blocks. By default these programs are dimmed and unclickable. Selecting **Infomercials** in the genre filter (`_genreFilter === '__inf'`) inverts this: inf programs become selectable and recordable, all non-inf programs dim instead. The same `isInfomercial` property also gates `quickRecordMenu` (`GuideViewHelpers.swift`) on the two native surfaces that share it — Watch Now's Record button and the VLC player's toolbar quick-record button — which withhold Record unconditionally for paid programming (no filter/opt-in UI exists there to invert it, unlike the web guide).

**Time header:** one tick per clock hour, aligned to hour boundaries via `stride(from: firstHour, through: winEnd, by: 3600)` where `firstHour = ((winStart + 3599) / 3600) * 3600`. Label uses `DateFormatter` template `"j"` (locale-preferred hour, e.g. `"8 PM"` or `"20"`). + red "now" bar. `.g-hdr-tl`'s height (32px default) shrinks to 28px under the `max-width:600px` phone breakpoint and to 24px under `max-height:480px` (landscape) — `.g-hdr-btn`/`.g-tick` font-size shrink alongside it in both, `.g-hdr-ch`'s padding shrinks under the `max-height:480px` bucket while the `max-width:600px` bucket instead shrinks `.g-hdr-ch-lbl`'s font-size, so the corner cell and tick labels stay visually balanced with the thinner strip either way; every pixel trimmed here is handed back to `.gw`'s scrollable grid area.

**Vertical gridlines:** CSS `repeating-linear-gradient` at every **8.3333%** of the timeline element width. Since the timeline spans `winSec` seconds, each gridline represents `winSec × 0.08333 / 60` minutes — 120 min for the default 24 h window (desktop and mobile alike).

**Vertical time-axis mode (`@media (orientation:portrait)`) is per-route, not global.** `GET /` always renders the standard horizontal grid, in any orientation, on any device — it's a fixed, "pinned" experience for anyone who bookmarks the plain root URL. `GET /vertical` is the orientation-responsive one: portrait transposes the whole grid (channels become side-by-side columns with sticky-**top** headers, time becomes the shared vertical axis with a sticky-**left** ruler, the same relationship as a calendar day/week view), landscape on that same route looks identical to `/`. There is no manual toggle and nothing is persisted to `localStorage` — which route you're on plus the device's actual orientation are the only two inputs. An earlier version of this feature had a manual `#axis-sw` toolbar toggle and made `/vertical` a bare alias for `/` (same page either way, orientation deciding globally); both were replaced once it became clear `/` needs to be immune to vertical mode regardless of how the phone is held, while `/vertical` should still respond to orientation live.

**How the two routes actually differ:** `buildHTML(state:prebuiltGrid:includeVerticalCSS:)` takes a `Bool` that controls two things together — whether `guide-vertical.css`'s `<style>` block is embedded in the page at all, and whether `guide.js`'s `{{VT_ELIGIBLE}}` token bakes in as `true` or `false`. `GET /` builds with `includeVerticalCSS: false`: no vertical stylesheet ships, so there is literally no CSS for a portrait media query to match, no matter the device's orientation. `GET /vertical` builds with `includeVerticalCSS: true` — but `VT_ELIGIBLE` only actually bakes as `true` when `cachedGuideVerticalCSS` also loaded successfully (`includeVerticalCSS && cachedGuideVerticalCSS != nil`); a missing/failed-to-load template falls back to an empty style block with no `@media(orientation:portrait)` rules, so `VT_ELIGIBLE` must stay `false` too or `isVT()` would claim vertical mode is active against CSS that was never actually transposed. `guide.js`'s `isVT()` is `_vtEligible && _orientMq.matches` — the `_vtEligible` half matters because without it, `isVT()` on `/` would still say `true` in portrait (orientation alone) even though the CSS never transposed anything, desyncing the scroll/now-line math from what's actually on screen.

**Two independent page caches exist because of this split** — `cachedHTML`/`cachedHTMLGzip` (for `/`, `includeVerticalCSS: false`) and `cachedVerticalHTML`/`cachedVerticalHTMLGzip` (for `/vertical`, `includeVerticalCSS: true`), both built from a single shared `buildGuideGridHTML()` call — the grid itself (1300+ program blocks) is identical between the two variants and is the expensive part, so it's computed once and reused for both `buildHTML` calls rather than twice.

**The vertical cache is built lazily, not on every rebuild.** `prebuildPageHTML(state:prebuiltGrid:)` only builds/gzips the `/vertical` variant once `verticalRouteEverRequested` is true — a sticky-for-process-lifetime flag the `/vertical` route handler itself sets on its first hit (it also builds+gzips+caches the page live for that request, so there's no cold-start penalty beyond the one request that flips the flag). Installs where `/vertical` is never requested (no phone browser in portrait mode, ever) skip that build and its gzip pass entirely on every guide-changing rebuild — `cachedVerticalHTML`/`cachedVerticalHTMLGzip` just stay `nil`, and `GET /vertical` would build live per-request if it were ever hit. Once the flag flips, both variants are (re)built together on every subsequent rebuild, same as before. `cachedHTML`/`cachedHTMLGzip` (for `/`) are unaffected — always built on every rebuild regardless.

**The two gzip passes, when both run, run concurrently** — `Self.gzip` only touches plain `Data` with no `@MainActor` affinity, unlike the two `buildHTML` calls (which read MainActor-isolated `AppState` and must stay sequential), so `prebuildPageHTML` compresses both payloads via `DispatchQueue.concurrentPerform` instead of back-to-back, halving the wall-clock cost of the compression step on `@MainActor` when the vertical variant is in play.

**All of the vertical-mode CSS rules live in `Resources/guide-vertical.css`, a separate file from `guide.css`** (see "HTML cache" above for the token-substitution details). This is a deliberate file-level boundary: every selector in `guide-vertical.css` is wrapped in one `@media (orientation:portrait){...}` block and additionally carries a redundant `html` element qualifier (`html .g-ch`, not bare `.g-ch`) purely for a specificity margin over `guide.css`'s base rules — being a later `<style>` block already wins ties by source order, but the extra qualifier keeps that true even if `guide.css` later grows an equal-or-higher-specificity rule for the same selector. Editing horizontal-mode rules in `guide.css` can't accidentally touch vertical mode this way, and vice versa. `deploy.sh`/`deploy_release.sh` copy it alongside the other three guide templates (see CLAUDE.md's guide-template invariant).

- **Why this shape, not a per-row flip:** channels stay columns (not "keep channels as a vertical list and rotate each row's own timeline in place") because that would nest a small vertical scroll inside a big vertical scroll. With channels as columns, each is only as wide as one channel's label (~90–140px, reusing `--ch-w` — the existing phone breakpoint's `--ch-w:100px` override automatically fits more columns on a narrow screen too; vertical mode's own portrait breakpoint bumps this further to 108px, see below), so 2–4 channels fit on a portrait phone with a natural swipe-down through time.
- **No parallel HTML generation path:** the `--gs`/`--gw` custom properties `buildGuideGridHTML()` emits (see "Sticky channel column" above) express "how far into the time window," not a screen direction — the *same* server-rendered numbers serve both orientations. `guide-vertical.css` is a purely additive CSS file (does not modify any default-mode selector) that redirects those properties from `left`/`width` to `top`/`height`.
- **The pinned corner is a mix of native sticky and a JS fallback, not two matching stickies.** `.g-hdr-ch` — nested inside `.g-hdr` — sticks on `top` via `position:sticky` same as everywhere else in this grid (stays put while time scrolls vertically). `.g-hdr` itself is **not** `position:sticky` despite conceptually needing the mirror-image `left`-only stick — that was tried first and observed failing on-device (the ruler scrolled away with the channel columns instead of staying pinned), a known weak spot in WebKit where sticky along the inline/left axis inside a flex row is far less reliable than the top/bottom axis used everywhere else in this grid. `.g-hdr` uses `guide.js`'s `syncHdrPin()` instead — a scroll listener on `.gw` that sets `transform:translateX(gw.scrollLeft)`, re-synced on load, on orientation change, and after every `refreshGuide()` DOM swap (which replaces `.g-hdr` with a fresh element that starts with no transform).
- **`.g-hdr` is also pulled out of `.gi`'s flex flow entirely** (`position:absolute;top:0;bottom:0;left:0`, not a normal flex item) rather than left in-flow and merely transformed — a transform repaints an element at a new visual position but doesn't remove its original space from layout, so an in-flow `.g-hdr` with just a translate would visually overlap whichever channel column had scrolled underneath it (observed on-device: garbled/overlapping text where the ruler sat on top of real content) instead of content cleanly starting after it. `.gi{padding-left:var(--ch-w)}` reserves the exact space `.g-hdr` used to occupy as a flex item, so the real columns — now the actual first flex children — still start in the right place; the padding scrolls away with the rest of `.gi`'s content while the absolutely-positioned-then-transformed `.g-hdr` stays fixed at the viewport edge, exactly filling the gap the scrolled-away padding leaves behind. (`top:0;bottom:0` rather than `height:100%` for the same reason as the `.g-ch` width fix elsewhere in this section — a percentage against `.gi`'s auto/intrinsic height would compute to nothing.)
- **`--ch-h`** (default `52px`) is `--ch-w`'s vertical-mode counterpart — the sticky channel-header row's height (`.g-ch`, `.g-hdr-ch`). `chH()` in `guide.js` reads it the same way `chW()` reads `--ch-w`.
- **Small-phone `--ch-w` override, scoped to vertical mode only:** `guide-vertical.css`'s own `@media (orientation:portrait) and (max-width:600px)` block bumps `--ch-w` to **108px** (`html:root{--ch-w:108px}`) and shrinks `.g-cn`/`.g-cname` to `.6rem` with an `overflow:hidden;text-overflow:ellipsis` backstop. Vertical mode shows several channel columns side by side rather than horizontal mode's single sticky column, so the same 100px `guide.css` uses at this breakpoint (fine for one column) is too tight here — channel number/name text could overflow into the neighboring column. Scoped to `max-width:600px` specifically (not just `orientation:portrait`) so portrait tablets, which never hit `guide.css`'s 100px shrink and are already comfortable at the base 125px, are left alone.
- **`GUIDE_MIN_HEIGHT`** (`Sources/hdhr_VCR/WebServer.swift`, `max(1600, winSec / 1800 * 70)`) is `GUIDE_MIN_WIDTH`'s counterpart, setting `.g-tl`'s `min-height` in portrait — same shape, a smaller px/30min constant since a column only needs to be tall enough for legible stacked blocks, not wide enough for side-by-side ones.
- **30-min gridlines** flip from `repeating-linear-gradient(90deg,...)` to `180deg` — same `8.3333%` stops, now horizontal divider lines instead of vertical.
- **The two-genre split-color gradient** (`extraStyle` in `buildGuideGridHTML()`, `background:linear-gradient(...)`) reads its direction from a `--gg-dir` custom property (default `to right`, inherited; the portrait media query overrides it to `to bottom`) instead of a baked-in keyword.
- **`.g-fav-sep`** becomes a narrow (`12px`) separator column instead of a horizontal bar. It shows no icon or text in portrait (`.g-fav-sep-star`/`.g-fav-sep-txt` both `display:none`) — a `writing-mode:vertical-rl` rotated "★ FAVORITES" label was tried first but needed a head-tilt to read and felt cramped at any reasonable column width, and even a lone star alone still read as stray clutter; the amber tint (the same `background` the base, horizontal-mode rule already applies to `.g-fav-sep .g-ch`) is enough to mark the section on its own. The cell's own `position:sticky` is also turned off (`position:static`) since it has nothing left to stick. `.g-rec-sep` gets the identical treatment (narrow column, icon/text hidden, tint-only) in `--vc-rec` red instead of amber.
- **`content-visibility` moves from `.g-row` to `.g-row > .g-tl`** in portrait — `.g-row{content-visibility:visible}` cancels the base (horizontal-mode) rule, and `.g-row>.g-tl{content-visibility:auto;contain-intrinsic-size:auto 130px auto {{GUIDE_MIN_HEIGHT}}px}` reapplies it scoped to just the timeline. This was a real bug, not a preemptive choice: with `content-visibility:auto` on `.g-row` itself, `.g-ch`'s `position:sticky` (a direct child) hit a known WebKit/Chromium rendering bug category — a channel column's header (logo/name/star) could fail to paint at all on first load until a real scroll forced a recompute; two nudge attempts (a scrollTop poke, a forced synchronous reflow) didn't fix it, only moving the containment boundary did. `.g-ch` was never the expensive part anyway (one small cell vs. ~50+ program blocks per column), so scoping the optimization to `.g-tl` loses nothing. The two `[auto]? <length>` groups in `contain-intrinsic-size` (width, then height) are required because a lone trailing `auto` with no length (`130px auto`) is invalid and browsers resolve it to the *same* value on both axes instead of "width only" — an off-screen column's placeholder would otherwise collapse to 130px tall and visibly snap to its real height as it scrolls into view.
- **`#g-hscroll`** (the custom horizontal scrollbar) is hidden in portrait (`display:none` in both CSS and a `syncThumb()` early-return in `guide.js`) — the horizontal axis in vertical mode is channels, not time, and the browser's native vertical scrollbar covers time-axis navigation.
- **`initRowObserver()`'s `rootMargin`** (the lazy heavy-data loader, see below) swaps from `'400px 0px 400px 0px'` to `'0px 400px 0px 400px'` under `isVT()`, since columns now enter/leave the viewport via horizontal scroll instead of vertical.
- **`updateNowLine()`/`scrollToNow()`/the now-button-visibility check** each branch on `isVT()`, swapping `scrollLeft`/`clientWidth`/`scrollWidth`/`style.left` for `scrollTop`/`clientHeight`/`scrollHeight`/`style.top` (and `chW()` for `chH()`) — kept as small paired branches rather than a shared abstraction, matching this file's existing terse style.
- **Rotating the device mid-session** is handled by a `window.matchMedia('(orientation: portrait)').addEventListener('change', ...)` listener in `guide.js` that re-runs `updateNowLine()` (clears the now-line's stale inline `left`/`top` from the old axis — inline styles beat the media-query CSS otherwise) and `initRowObserver()` (re-derives `rootMargin` for the new axis). Without it, both would silently keep using the pre-rotation axis until `updateNowLine`'s next 60s tick or the next `refreshGuide()` DOM swap.
- **Click/selection logic is untouched:** `showInfo()`, `goToShow()`, `jumpToGuide()`, `setDev()`, and `toggleFav()` are all purely `dataset`-driven and never read element position, so none of them needed changes for this mode.

**Program block color coding:**

Dark mode values (default). Light mode overrides follow below.

| Class | Condition | Background | Border |
|---|---|---|---|
| `.g-prog-rec` | Currently recording | `#3c1818` | `#c03030` (red) |
| `.g-prog-now` | On air (no genre) | `#424242` | `#787878` (grey) |
| `.g-prog-sched` | Managed/scheduled | `#1a1a40` | `#4848c8` (blue) |
| `.gg-drama` | Drama | `hsl(216,48%,36%)` | — |
| `.gg-comedy` | Comedy | `hsl(47,48%,36%)` | — |
| `.gg-news` | News | `hsl(342,43%,36%)` | — |
| `.gg-sports` | Sports | `hsl(119,48%,33%)` | — |
| `.gg-reality` | Reality | `hsl(25,48%,36%)` | — |
| `.gg-movie` | Movie | `hsl(270,58%,38%)` | — |
| `.gg-talk` | Talk | `hsl(173,43%,34%)` | — |
| `.gg-children` | Children / Kids | `hsl(315,43%,35%)` | — |
| `.g-prog` (default) | No genre | `#2c2c2c` | `#484848` |

**Light mode overrides (`html.lm`):**

| Class | Background | Border |
|---|---|---|
| `.g-prog-rec` | `#f8c0c0` | `#c02828` (red) |
| `.g-prog-now` | `#bec2cc` | `#6870a0` (blue-grey) |
| `.g-prog-sched` | `#c0c0f0` | `#4040c8` (blue) |
| `.gg-*` genre | `hsl(hue, sat, 68–72%)` | `hsl(hue, sat, 46–50%)` |
| `.g-prog-now.gg-*` / `.g-prog-sched.gg-*` | `hsl(hue, sat, 76–80%)` | `hsl(hue, sat, 46–50%)` |
| `.g-prog` (default) | `#cbd0dc` | `#8590a8` |

`.g-prog-dim` (genre filter active, non-matching program) overlays any of the above: `opacity: .35; pointer-events: none` — the block keeps its color but is dimmed and unselectable.

State classes (rec / now / sched) take precedence over genre. `.g-prog-now.gg-*` two-class selectors override the grey fallback with genre-tinted now-playing colors (e.g. dark mode `.g-prog-now.gg-drama` → `hsl(216,52%,44%)`; light mode → `hsl(216,57%,78%)`). `.g-prog-sched.gg-*` selectors apply the same genre hue families to scheduled-show blocks with matching lightness. `.g-prog.g-sel` adds white border + glow.

This table covers only the block's *background* — an entirely separate, independent layer (a colored `box-shadow` ring + corner badge, `.g-st-sched`/`.g-st-rec`/`.g-st-skip`/`.g-st-conflict`) sits on top without touching it; see "Status ring + badge" above. `will-skip` and `conflict` blocks have no dedicated background color of their own — they keep whichever of the three background classes above already applies (almost always `.g-prog-sched`) and are distinguished only by the ring/badge.

**Data attributes on every program block:**

| Attribute | Content |
|---|---|
| `data-title` | Show title |
| `data-syn` | Synopsis, capped 220 chars |
| `data-poster` | `entry.ImageURL` or `""` |
| `data-ep` | `entry.episodeInfoLabel` or `""` |
| `data-date` | Formatted `OriginalAirdate` or `""` |
| `data-genre` | `entry.firstGenre` or `""` |
| `data-start` | `entry.StartTime` (Unix int) |
| `data-end` | `entry.EndTime` (Unix int) |
| `data-device` | `device.DeviceID` |
| `data-num` | `ch.GuideNumber` |
| `data-chname` | `ch.GuideName` |
| `data-logo` | Channel logo URL or `""` |
| `data-series` | `entry.SeriesID` or `""` |
| `data-managed` | `1` if managed, else `0` |
| `data-recording` | `1` if currently recording, else `0` |
| `data-new` | `1` when `isNewEpisode()` is true (first-run today or late-night after midnight), else absent |

**NEW pill:** when `isNewEpisode(entry)` is true (OriginalAirdate, decoded as UTC year/month/day, matches today's local calendar date — or tomorrow's local date for 00:00–05:00 start times), a green `NEW` badge (`.g-new-tag`, `background:#27ae60`) appears inline with the title inside a `.g-ti-row` flex row. The title (`flex: 0 1 auto`) shrinks to fit; the pill (`flex-shrink: 0`) stays compact immediately after the title text. `data-new="1"` is also set on the block for the genre filter.

**Status ring + badge classes:** no `<div>` child element — the marker is a `box-shadow` ring plus a `::after` badge glyph applied directly to the `.g-prog` element via one of five mutually-exclusive classes:
- `.g-st-sched` (blue `#3b93ff`, ⏱) — managed/scheduled show
- `.g-st-rec` (red `#ff5a5a`, ⏺, pulsing) — currently recording
- `.g-st-skip` (slate `#8a92a3`, ⏭) — already recorded, will skip (see below)
- `.g-st-conflict` (orange `#ff9500`, ⚠) — scheduled but can't get a tuner (see below)
- `.g-st-inuse` (purple `#9b59b6`, ▶) — a hardware tuner is on this channel but not for any reason this app tracks (see below)

Precedence: recording > will-skip > conflict > scheduled > in-use-by-other-tuner — see "Status ring + badge" above for the full rationale (why VCR glyphs instead of color alone, why not stoplight gold/red/green).

**Managed show matching:** `buildHTML` constructs a `ManagedGuideMatcher(activeManagedShows: activeMgd)` to decide which blocks get `.g-st-sched` and the `data-managed="1"` attribute. `activeMgd` is active, non-paused shows only; the same exclusion applies in `/api/now.json`'s `isScheduled` field so the two paths agree.

The matching tiers (seriesChannel's own-channel seriesID/title → seriesAll's any-channel seriesID/title → datetime `device:channel:HH:MM` → single `device:channel:epoch`) are documented in [Models.md — ManagedGuideMatcher](Models.md) — note that `seriesChannel` and `seriesAll` use different key shapes as of 2026-08-15 (channel-scoped vs. device-only), so a `seriesChannel` show's badge no longer appears on a rerun airing on a different channel. `dateTime` shows are matched by local-time slot so every upcoming weekly airing is flagged, not just the one stored in `show_next`.

**Recording flag scoping:** `isRecCh` is scoped to the current device (`recChannelsByDevice[device.DeviceID]`). A recording on device A does not flag the same channel number on device B.

`pendingRecChannelsByDevice` supplements `recChannelsByDevice` with shows that have passed `show_next` but whose idle-loop recording start hasn't fired yet. This means a guide cell turns red (`.g-prog-rec`) immediately after a web Record tap on a live show — before the next idle loop tick marks `show_recording = true`. As of 2026-08-15 this is no longer computed inline here — both this and `WatchNowView` now share one definition, `AppState.pendingRecordingChannels(for:)` (`show_active && !show_paused && !show_recording && show_next <= now && show_end > now && (showRuntime[show_id]?.retryAfter is nil or already expired)`) — the retry-cooldown clause excludes a show currently sitting out a missed-start retry backoff, so a show that actually failed to start no longer falsely reads as "recording" here (see `issues_resolved.md`). Scoped to device the same way as `recChannelsByDevice`.

**Managed show data attributes:** `owner = guideMatcher.owner(for: e)` (see [Models.md — ManagedGuideMatcher](Models.md)) locates the owning `Show` record and embeds its config on the block for use by the edit modal; `isMgd` is just `owner != nil`:

| Attribute | Content |
|---|---|
| `data-show-id` | `show.show_id` |
| `data-show-type` | `"single"` / `"dateTime"` / `"seriesChannel"` / `"seriesAll"` |
| `data-show-paused` | `1` / `0` |
| `data-show-length` | `show.show_length` (minutes) |
| `data-show-bonus` | `1` / `0` |
| `data-show-transcode` | `show.show_transcode` |
| `data-show-seriesid` | `show.show_seriesid` |
| `data-show-airdays` | Comma-joined `show.show_air_date` |
| `data-show-failcount` | `show.show_fail_count` |
| `data-show-failreason` | `show.show_fail_reason` |
| `data-show-recording` | `1` if recording, `0` otherwise |
| `data-show-ignoredup` | `1` / `0` — `show.show_ignore_duplicate_once`, the web guide's "Duplicate Episodes" toggle (see "Duplicate-episode override" below) |
| `data-show-newonly` | `1` / `0` — `show.show_new_only`, the web guide's "New Only" toggle |

`owner(for:)` uses the exact same tiered lookup the flag itself is derived from (SeriesID → title fallback → dateTime slot → single slot — see Models.md), so the flag and the embedded edit attributes can never disagree about which show a block belongs to. This replaced an earlier, separately-maintained `findManagedShow(e, ch)` lookup that only checked SeriesID for series shows (no title fallback) — meaning a series entry whose guide data happened to lack a SeriesID could get flagged managed (via the title-fallback tier the boolean flag already used) but resolve to no owner at all, leaving the Edit button unable to pre-fill from the guide for that block. `owner(for:)` closes that gap: since it shares the identical tiers, a title-fallback match now always populates the same `data-show-*` attributes.

If no match is found at all (e.g. a series show whose guide entry has no SeriesID *and* no title match), the block still gets `data-managed="1"` and the `.g-st-sched` ring/badge but no `data-show-*` edit attrs — the Edit button will not be pre-filled from the guide for that block.

**Duplicate-episode override:** `willSkip` (above) renders the green `.g-flag-skip` corner flag + "Already recorded · will skip" tooltip for a managed block the grid knows will be skipped as a duplicate, but that alone was previously a dead end in the browser — `show_ignore_duplicate_once` (the per-show one-shot override, `docs/ShowFormSection.md`) was only settable from the native Add/Edit dialogs. The edit modal's "Duplicate Episodes" row (`em-dup-row`/`em-dup` in `guide-shell.html`) closes that gap: shown whenever `SKIP_DUP_ENABLED` (a JS token baked from `state.config.Series_subfolder_enabled && state.config.Skip_recorded_episodes`) is true and the show's type is `seriesChannel`/`seriesAll` (`updateDupVisibility()` in `guide.js`, re-checked on every type-picker change), it round-trips `data-show-ignoredup` → the checkbox → `POST /api/edit`'s `ignoreDuplicateOnce` field → `handleEdit` → `show.show_ignore_duplicate_once`. Not wired into the Record modal (`#rec-modal`) — see `docs/ShowFormSection.md`'s note on why a brand-new Record can't know this yet.

**New Only:** unlike Duplicate Episodes, `show_new_only` needs no on-disk state to evaluate — it only reads the guide entry already in hand — so it's wired into **both** modals: the Record modal's `#rm-new-row`/`#rm-new` (visible for every type except `single`, unchecked by default) round-trips through `POST /api/record`'s `newOnly` field → `AppState.addShowFromGuide(newOnly:)`; the Edit modal's `#em-new-row`/`#em-new` round-trips `data-show-newonly` → the checkbox → `POST /api/edit`'s `newOnly` field → `handleEdit` → `show.show_new_only`, the same shape as Duplicate Episodes above.

---

### Per-tuner dropdown (`#tdrop-{devId}`)

Each tuner box's ▾ toggles an absolute-positioned panel listing **that tuner's own** shows,
built by `buildTunerShowsHTML(state:, deviceId:)` (filters every section to
`show.hdhr_record == deviceId`). Sections (`.sp-sec`) separated by `.sp-div` dividers — empty
sections are omitted:
- **Recording** — that tuner's `recordingShows`; red `●` prefix (`.sp-rec`); channel cell appends **"· Ends 10:00 PM"** (`state.shortTime(show.show_end)`).
- **Up Next** — that tuner's first `activeShows` entry by `show_next` ascending; relative time in accent color.
- **Scheduled** — that tuner's remaining `activeShows`.
- **Paused** — that tuner's `pausedShows`; `⏸` prefix.

Empty → `<div class="sp-empty">No shows on this tuner.</div>`. Each `.sp-row` carries `data-dev`
+ the show's `data-*` and an `onclick="openEditShow(this)"`. Offline/absent tuners use the same
builder, so their assigned shows still appear in their dropdown even though they can't record.

Update paths: add/remove/edit/favorite-toggle arrive as `show_*`/`favorite_toggled`/`guide_refreshed`
SSE events carrying the rebuilt `tdrop` object (all devices) via `applyGuidePayload`, which swaps
each `#tdrop-body-{dev}` in place (see "Guide-change fragment push" above); a recording start/stop
instead pushes a single-device `tdrop`/`tdropDev` in its SSE event and the client swaps just
`#tdrop-{tdropDev}`.

---

## JavaScript — key functions

| Function | Purpose |
|---|---|
| `showInfo(el)` | `onclick` on program blocks; reads `el.dataset`, populates summary panel, sets globals |
| `recordFromDblClick(el)` | `ondblclick` on program blocks; calls `showInfo(el)` then routes to `doEditFromGuide()` for any managed block (`data-managed="1"`, recording or not — re-adding an already-scheduled/already-recording show via the Record modal never made sense) or `doRecord()` otherwise. For a recording block specifically this is a double-click-only shortcut with no visible-button equivalent (`showInfo()`'s Summary panel shows only "Stop & Delete" there, not an Edit button, keeping an accidental double-click away from that destructive action) — safe because the Edit modal (`openEditShow()`) already fully supports a recording show: hides Pause (nothing to pause), relabels Delete to "Stop & Delete". |
| `closeSummary()` | Hides summary, restores placeholder, clears `.g-sel` |
| `postJSON(url,payload)` | Shared POST helper — `fetch(url,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)})`. Used by all 7 mutating actions (`confirmRecord`, `doDelete`, `doEditPause`, `doEditReset`, `confirmEdit`, `doEditDelete`, `toggleFav`); each still handles its own response/error path since those differ enough per action (e.g. `confirmRecord`'s `r.text()` fallback on a non-JSON error body) that only the fetch-construction boilerplate is shared. |
| `refreshGuide(selOverride?)` | Partial DOM refresh: saves `.gw` scroll + selected entry; fetches `/api/guide-refresh`; swaps `.gi`, `#sum-ph`, and each `.tdrop` body (`#tdrop-{devId}`) via `applyGuidePayload()`; resyncs `_winStart`/`_winSec` from the new `.g-hdr` (so the now-line doesn't drift); restores scroll; re-selects prior entry. Only called by the manual **↺** refresh button and the SSE handler's fallback for an unrecognized event shape — no user action calls it directly anymore (see line ~300 above and the "Guide-change events" SSE section for why). Optional `selOverride` object would patch `dataset` attrs on the re-selected block before `showInfo()` runs, but no current caller passes one. |
| `doRecord()` | Opens record modal; prefills the title input; pre-checks day-of-week button matching guide entry (Day row shown for `single`/`dateTime`); pre-checks Bonus Time for sports entries when `_bonusEnabled`; sets transcode to `_defaultTranscode`; shows tuner-full warning if applicable; resets the airings cache/generation counter |
| `cancelRecord()` | Hides modal |
| `loadAirings(seriesId, gen)` | Fetches `/api/airings/{seriesId}` (cached per series in `_airCache`); discards the response if `gen` no longer matches `_airGen` (modal was reopened for a different program); renders via `renderAirings()` |
| `renderAirings(list)` | First filters to `_n` (current channel) when `_rmType==='seriesChannel'` (unfiltered for `'seriesAll'`), then filters out the currently-selected airing (matching `ch`+`start`), stores the filtered array in `_airCurrent` (index-addressed by each row's `ondblclick`), hides `#rm-airings` and clears `#rm-airings-list` if nothing remains, else renders up to 4 `Day time · Ch N Name · episode info` rows |
| `switchAiring(idx)` | Looks up `_airCurrent[idx]`, re-anchors `_d`/`_n`/`_s`/`_e`/`_genre`/`_title`/`_entryDow` to it, updates the title input + `Ch N · Name · time` line + tuner-full warning, then calls `renderAirings(_airCache[_ser])` again so the list swaps to reflect the new selection |
| `confirmRecord()` | Collects `airDays` from `#rm-days`, `transcode` from `#rm-transcode`, and the trimmed title from `#rm-title-in` (included only if edited); POSTs `/api/record`; on success: `.g-prog-rec` + `.g-st-rec` (red, pulsing) if `recStarted`, `.g-prog-sched` + `.g-st-sched` (blue) otherwise. Delete button becomes **"Stop & Delete"** (+ `danger` class) when `recStarted`, stays **"Remove"** otherwise. Updates tuner badge `#tun-{devId}` in place. No explicit `refreshGuide()` — `/api/record`'s broadcast SSE event covers the summary panel/dataset update. |
| `updateDaysVisibility()` | Shows `#em-days-row` for `single` and `dateTime` types (label "Day"/"Days"); hides for series types |
| `toggleDay(btn)` | Toggles a day-button selection in the edit modal; prevents deselecting the last selected day |
| `doDelete()` | Gathers title/poster/type from the selected `.g-prog` block and calls `showDeleteConfirm(...)` with `performSummaryDelete` as the confirm action — does not POST directly. |
| `performSummaryDelete()` | The actual delete: POSTs `/api/delete`; removes status/color classes from block, restores Record button; no explicit `refreshGuide()` — `deleteShow()` already broadcasts `show_deleted` over SSE |
| `doEditDelete()` | Gathers title/`_editPoster`/`_editType` and calls `showDeleteConfirm(...)` with `performEditDelete` as the confirm action — does not POST directly. |
| `performEditDelete()` | The actual delete: POSTs `/api/delete` with `showId:_editId`; closes the edit modal on success |
| `showDeleteConfirm(title,poster,typeStr,isRec,onConfirm)` | Populates and opens `#del-confirm-modal` (poster image, `Delete "<title>"?`, `Type: <label>` via `typeLabel()`, and — when `isRec` — a "will stop the active recording" warning with the confirm button relabeled "Stop & Delete"); stores `onConfirm` in `_delConfirmAction` for `confirmDeleteConfirm()` to invoke. Shared by both `doDelete()` (Summary panel) and `doEditDelete()` (Edit modal), so the two delete entry points can never drift out of sync on what the confirmation shows. |
| `cancelDeleteConfirm()` / `confirmDeleteConfirm()` | Hide `#del-confirm-modal`; the latter invokes and clears `_delConfirmAction` |
| `typeLabel(t)` | Looks up a `ShowState` raw value in the same `recOpts` table the Record/Edit modals' Type row renders from, returning its short label (`t`, e.g. `"SeriesID(Channel)"`) — reuses that table specifically so the confirm dialog can never disagree with what those modals call each type. |
| `doEditFromGuide()` | Reads `data-show-*` attrs (including `poster`/`logo`) from selected `.g-prog` block; calls `openEditShow()` |
| `openEditShow(el)` | Populates and opens `#edit-modal` from `el.dataset`, including `_editPoster=d.poster||d.logo||''` (used by `doEditDelete()`'s confirm dialog); handles both guide blocks and schedule popover rows |
| `closeEditShow()` | Hides `#edit-modal` |
| `confirmEdit()` | POSTs `/api/edit`; closes modal on success; no explicit `refreshGuide()` — `handleEdit`'s `updateShow` already broadcasts `show_updated` over SSE |
| `setDev(id)` | Filters guide rows by `data-dev`; empty string = deduped single-device fallback (multi-tuner bootstraps to a real `defaultDev`, not `''`); uses cached `_rows` NodeList; calls `applyFilterDim()` then shows/hides `.g-fav-sep`/`.g-rec-sep` separators. Also applies `.d-sel` (blue "selected" highlight) to the matching `.d-btn` — for empty `id`, that's the sole online tuner box (only ever one at that point, since a real `defaultDev` is used whenever there's more than one) rather than none, so single-device setups don't read as nothing-selected |
| `filterGenre(g)` | Sets `_genreFilter`, clears `_searchShow` if set (mutual exclusivity), calls `applyFilterDim()` |
| `applyFilterDim()` | Clears all `.g-prog-dim`. Single dim pass shared by the genre filter and show search (renamed from `applyGenreDim`, 2026-08-28) — at most one is ever active. If `_searchShow` is set: dims every `.g-prog` whose `(device,num,start)` isn't in `_searchShow.airingKeys`. Else in new-episode mode (`__new`): dims non-new programs. Else in infomercial mode (`__inf`): dims all non-inf programs. Else (normal genre mode): dims programs that fail the genre filter OR have `data-inf="1"`. Rows always remain visible. |
| `searchDeviceId()` | Resolves the device id to search against: `curDev`, or — for a single-online-tuner setup where `curDev` stays `''` — the lone `.d-btn[data-dev]` button's id, same fallback `handleDevClick` uses |
| `expandSearch()` | `#search-icon-btn`'s `onclick` — just `focus()`es `#search-in`; `:focus-within` (`guide.css`) does the actual expand, same as a mouse hover would |
| `armSearchStrayTimer()` | Called from every `onSearchInput()`. Arms a 5s timeout when `#search-in` holds exactly one character (cancels any pending one first); on fire, re-checks the length/`_searchShow` state (a lot can happen in 5s) and, if still a lone stray character, clears the box, re-runs `onSearchInput()`, and `blur()`s it so `:focus-within` releases and the box collapses back to the icon |
| *(global `keydown` listener)* — type-to-search | Skips when `_searchShow` is set, a modifier key is held, the key isn't a single printable character, the key is Space (reserved for `.g-prog`/native-`<button>` activation — see "Type-to-search" above), a guide modal is open, or focus is already on `#search-in` or another genuinely editable field (`SELECT` included, for its own native type-to-jump). Otherwise: `preventDefault()`s (also blocks Firefox's own quick-find); for `/` specifically, clears `#search-in` and focuses it (dedicated "enter search" key, nothing typed into the box); for any other qualifying character, seeds `#search-in`'s value with the pressed key, focuses it, places the caret after it, and calls `onSearchInput()` |
| `syncSearchIconAria()` | Mirrors `#search-bar`'s live `:hover`/`:focus-within`/`.has-filter` condition onto `#search-icon-btn`'s `aria-expanded`, via `mouseenter`/`mouseleave`/`focusin`/`focusout` listeners on `#search-bar` plus explicit calls from `selectSearchShow`/`clearSearchFilter` (a class toggle alone fires none of those four events) |
| `onSearchInput()` / `runSearch(q)` | Debounces (~200ms) a fetch to `/api/guide-search/{searchDeviceId()}/{q}` once the trimmed value reaches 3 chars; `_searchReqId` invalidates a stale in-flight fetch (a fast backspace or a newer query) so it can't repaint the dropdown after the fact |
| `renderSearchDrop()` / `highlightSearchRow(idx)` | Renders `_searchResults` into `#search-drop` (poster/title/airing-count rows); `highlightSearchRow` toggles `.search-hi` + `aria-selected` for arrow-key nav |
| `toggleSearchHelp(event)` / `closeSearchHelp()` | Toggle/close the `ⓘ` explainer popover (`#search-help`) — mutually exclusive with `#search-drop` (opening one closes the other) |
| `onSearchKeydown(event)` | `#search-in`'s own `onkeydown`. No show selected: `ArrowUp`/`ArrowDown` move `_searchHi` through the open dropdown, `Enter` selects (highlighted row, or row 0), `Escape` closes. A show selected: `Escape`/`Backspace`/`Delete` call `clearSearchFilter()` (`ArrowLeft`/`ArrowRight` cycling is handled globally — see below, not by this handler, since selecting a result by click blurs the input) |
| *(global `keydown` listener)* / `anyGuideModalOpen()` | While `_searchShow` is set: `ArrowLeft`/`ArrowRight` call `cycleSearchEpisode(∓1/±1)` regardless of what's focused, unless a Record/Edit/Delete-confirm modal is open (`anyGuideModalOpen()`) or focus is genuinely inside an editable non-search text input — so it works right after clicking a dropdown result (which blurs `#search-in`) without stealing arrow keys from a modal's title field |
| `selectSearchShow(show)` / `clearSearchFilter()` | Select: builds `_searchShow`, clears `_genreFilter`, sets `#search-in` `readOnly` (chip styling), shows `#search-clear`, adds `#search-bar`'s `.has-filter` class (keeps it expanded after the selecting click blurs the input), `applyFilterDim()`, jumps to `airings[0]`. Clear: resets all of that back to an editable empty box and removes `.has-filter`. |
| `cycleSearchEpisode(delta)` / `jumpToSearchAiring()` | Clamps `_searchShow.idx` into `[0, airings.length)` (no wraparound), then locates `.g-prog[data-device][data-num][data-start]` for the target airing (exact-match, same pattern as `jumpToGuide`) and `scrollIntoView` + `showInfo` |
| `scrollToNow()` | Scrolls `.gw` so the now-line sits ~25% from the left of the viewport; corner-cell ⊙ button and page load both call it |
| `toggleFav(evt, btn)` | `onclick` on `.g-fav-btn` star buttons; reads `data-dev` / `data-ch` from parent `.g-row`; POSTs `/api/toggle-favorite` — no explicit `refreshGuide()` call, `handleToggleFavorite` already broadcasts `favorite_toggled` over SSE |
| `toggleTunerDrop(devId)` | Toggles that tuner's `#tdrop-{devId}` dropdown; closes any other open `.tdrop` first. A document-level click handler closes open dropdowns on any click outside a `.tuner-box`. |
| `devFull(devId)` | Returns true if `tuners[devId].a >= tuners[devId].t` |
| `noTranscode(devId)` / `updateNoTranscodeWarn()` | `noTranscode` returns true if `tuners[devId].nt` is truthy (device doesn't support transcoding). `updateNoTranscodeWarn` toggles `#rm-no-transcode` based on that plus `#rm-transcode`'s current value — see "No-transcode warning" above |
| `updateEmNoTranscodeWarn()` | Edit modal's counterpart to `updateNoTranscodeWarn()` above — toggles `#em-no-transcode` based on `noTranscode(_editDev)` (the show's own assigned tuner, not the guide's currently-selected device) plus `#em-transcode`'s current value. See the Edit modal's own Transcode selector entry above |
| `handleDevClick(id, btn)` | `.d-btn` name button's onclick — `setDev(id)` when switching to a not-yet-selected tuner; `showTunerInfo(id, btn)` when the tuner is already selected (a second click, or the first click on a single-online-tuner setup's already-selected default — see "One button, two clicks" above) |
| `showTunerInfo(devId, anchor)` | Opens tuner popover anchored below the clicked name button; renders per-tuner rows immediately from `recsByDev` (title for a tuned-but-not-ours channel is already resolved server-side, not a placeholder), then fires async `/api/now-airing` fetches for rows with `external==="1"` to add episode, poster, and end time on top of that title |
| `closeTunerPop()` | Hides tuner popover |
| `goToShow(ch)` | Closes tuner popover, finds the currently-airing `.g-prog` block for `ch`, scrolls it into view, and calls `showInfo()` to select it |
| `gc(genre)` | Maps genre → HSL background for summary panel |
| `ft(date)` | Formats Date as `"H:MM AM/PM"` |
| `so(id, val)` | Shows element with textContent, or hides if falsy |
| `hej(s)` | HTML-escapes a string for safe `innerHTML` concatenation (`&`, `<`, `>`) — used in the tuner popover where values come from server-side data |

**Globals:** `_d` (deviceId), `_n` (guideNumber), `_s` (startTime), `_e` (endTime), `_ser` (SeriesID), `_genre` (first genre string), `_title` (guide title), `curDev` (active device filter), `_genreFilter` (active genre filter, `''` = none) — set by `showInfo` (except `_genreFilter`, set by `filterGenre`), consumed by `doRecord`/`doDelete`/`confirmRecord`/`applyFilterDim`. `_genre` is used by `doRecord()` to pre-check Bonus Time for sports entries; `_title` prefills `#rm-title-in` and is the baseline `confirmRecord()` diffs the edited value against. Note `_d`/`_n`/`_s`/`_e`/`_genre`/`_title` are also reassigned by `switchAiring()` while the modal is open — they represent "whichever airing the modal is currently scoped to," not necessarily the guide block that was clicked to open it. `_bonusEnabled`/`_defaultTranscode` (config-derived, baked into the page like `_bonusMins`), `_entryDow` (day-of-week of the modal's current anchor airing, used for the Day row's Single-type preselection), and `_airCache`/`_airGen`/`_airCurrent` (Other Upcoming Airings cache, staleness guard, and last-rendered filtered array) are also page-level globals used by the record modal. Show-search globals: `_searchShow` (`null`, or `{title, seriesId, airings, airingKeys, idx}` once a dropdown result is picked — consumed by `applyFilterDim`/`cycleSearchEpisode`/`jumpToSearchAiring`), `_searchResults` (last fetched dropdown list), `_searchHi` (arrow-key-highlighted dropdown row index, `-1` = none), `_searchReqId` (monotonic guard against a stale in-flight fetch repainting the dropdown), `_searchStrayTimer` (pending 5s errant-keystroke auto-clear, or `null` — see `armSearchStrayTimer()`).

**Embedded JS data:**
- `var tuners` — `{deviceId: {t: total, a: active, surl: "http://ip/status.json"}, …}` — tuner counts from fresh `/status.json` fetch
- `var recsByDev` — `{deviceId: [{tuner, title, ch, chname, ip, idle, rec, external, endTime}, …], …}` — per-tuner occupancy detail for popover. `ip`: client IP for external streams not matched to our recordings; `idle`: `"1"` when tuner has no channel locked at all; `rec`: `"1"` when tuner is running one of our recordings; `external`: `"1"` when a channel *is* locked but doesn't match one of our own shows (distinct from `idle` — a channel is actively tuned, just not by us); `endTime`: Unix timestamp of recording end (from `show_end`) when `rec==="1"`

Both variables are serialised via `JSONSerialization` (not string interpolation) and passed through `jsEscapeForScript()` before embedding in the `<script>` block. This replaces `<`, `>`, and `&` with `\uXXXX` escapes so a show title or device ID containing `</script>` cannot terminate the script element. Device filter buttons use `onclick="handleDevClick(this.dataset.dev,this)"` (dispatches to `setDev`/`showTunerInfo` — see "One button, two clicks" above) — the DeviceID is read from the already-HTML-escaped `data-dev` attribute rather than interpolated into a JS string literal.

---

## JSON schema — `/api/now.json`

```swift
struct NowEntry: Encodable {
    var deviceId, guideNumber, guideName, title: String
    var hd: Bool
    var episodeTitle: String?
    var startTime, endTime: Int      // Unix timestamps
    var imageURL, channelLogoURL: String?
    var isRecording, isScheduled: Bool
}
```

Encoded with `JSONEncoder` `.prettyPrinted`.

---

## JSON schema — `/api/guide.json`

```swift
struct GuidePayload: Encodable {
    var deviceId: String
    var winStart, winSec: Int          // same window buildGuideGridHTML uses (guideWindow(state:))
    var devices: [DeviceSummary]       // every discovered device, PLUS any device referenced by a
                                        // show's hdhr_record but never discovered at all (offline,
                                        // active 0/total 0) — CLAUDE.md's "Web guide offline
                                        // devices" invariant, mirroring buildDevBarHTML's own union
    var channels: [GuideChannel]       // this device's lineup, Recording → Favorite → channelSortKey
    var sportsPaddingEnabled: Bool     // mirrors Sports_padding_enabled (state.config) — lets a
                                        // non-HTML client gate sports-genre auto-Bonus-Time
                                        // detection on it, see docs/TUIGuide.md
    var terminalGuideEnabled: Bool     // mirrors Terminal_guide_enabled (state.config) — courtesy
                                        // gate hdhr_guide checks at startup, see docs/TUIGuide.md
}
struct DeviceSummary: Encodable { var deviceId: String; var active, total: Int }
struct GuideChannel: Encodable {
    var guideNumber, guideName: String
    var hd, favorite: Bool
    var entries: [GuideEntryJSON]      // every entry in [winStart, winStart+winSec), not just on-air
}
struct GuideEntryJSON: Encodable {
    var title: String
    var episodeTitle, episodeNumber, synopsis, seriesId, genre: String?
    var tags: [String]?                // raw GuideEntry.Filter genre tags, e.g. ["Kids","Series"] —
                                        // `genre` above is the single derived firstGenre used for
                                        // color; `tags` is the unreduced list, for display
    var startTime, endTime: Int        // Unix timestamps
    var isRecording, isScheduled: Bool
    var scheduledShowId: String?       // ManagedGuideMatcher.owner(for:)'s Show.show_id when
                                        // isScheduled — lets a client delete/stop this recording
                                        // via POST /api/delete (`{"showId": ...}`) without a
                                        // second lookup
    var isSkipped: Bool                // mirrors buildGuideGridHTML's willSkip / the web guide's
                                        // slate .g-st-skip ring+⏭ badge — true when this managed
                                        // airing will be silently skipped at record time as an
                                        // on-disk duplicate. Always false unless isScheduled; never
                                        // true together with isRecording. See docs/TUIGuide.md.
    var isNew: Bool                    // mirrors buildGuideGridHTML's isNew / the web guide's green
                                        // .g-new-tag title pill — OriginalAirdate falls on local
                                        // "today" (or the early-morning "tomorrow" slot for a
                                        // late-night show). See docs/TUIGuide.md.
}
```

Encoded compact (no `.prettyPrinted`) — unlike `/api/now.json`, this carries every entry across the whole guide window for one device, not just on-air ones, so the payload is meaningfully larger per request. `isScheduled` comes from the same `ManagedGuideMatcher` `/api/now.json` and `buildGuideGridHTML` already share (see that struct's own comments) — never reintroduce a parallel lookup here. `isSkipped` and `isNew` both call the same shared functions `buildGuideGridHTML`'s own `willSkip`/`isNew` use (`computeRecordedTagsByShow`/`newEpisodeTest`, see those functions' own comments) rather than recomputing this independently — `computeRecordedTagsByShow`'s per-series disk scan is additionally cached across requests (`cachedRecordedTagsByShow`, refreshed on the same guide-changing events as the HTML grid); `newEpisodeTest`'s calendar-anchor computation is cheap enough to just call fresh per request.

**Channel order is Recording → Favorite → `channelSortKey`**, the same three-tier precedence `buildGuideGridHTML`'s "Recording section"/"Favorites section" use — a single `.sorted(by:)` over the whole lineup, not three concatenated filtered lists, so a channel that's both recording and favorited sorts under Recording only; there's no way for the same channel to appear twice.

---

## mDNS / Bonjour

When the listener reaches `.ready`, it advertises via `NWListener.Service`:

| Field | Value |
|---|---|
| Service type | `_http._tcp` |
| Service name | `"hdhrVCRplus"` |
| TXT record | see below |

**TXT record keys:**

| Key | Value | Example |
|---|---|---|
| `path` | `/` | `/` |
| `port` | Web server port | `1980` |
| `rec`, `rec2`, … | `"Title · Channel · DeviceID [· tunerN]"` for each active recording | `"Jeopardy! · 5.1 · 105404BE · tuner0"` |
| `next` | `"Title · Channel · DeviceID · in Xh Ym"` for the nearest upcoming show | `"60 Minutes · 8.1 · 105404BE · in 2h 15m"` |

**DeviceID** is the 8-character hex tuner ID (e.g. `"105404BE"`) stored on each show as `hdhr_record`. For active recordings, `show_tuner_resource` (e.g. `"tuner0"`) is appended when available — populated ~1.5 s after recording starts from the `X-HDHomeRun-Resource` response header.

All values are truncated to 120 characters. The TXT record is refreshed on `.ready` and on every idle loop tick. `listener?.service` reassignment updates Bonjour in-place without restarting the listener. Advertisement is withdrawn when `stop()` calls `listener?.cancel()`.

---

## Security

**Subnet guard:** `NWListener` binds to all interfaces. Every incoming connection is checked in `isLocalAddress()` before any data is read. Non-LAN IPs get `conn.cancel()` with zero bytes returned.

`isLocalAddress()` handles both IPv4 and IPv6:
- **IPv4:** walks `getifaddrs()` AF_INET interfaces, applies netmask comparison
- **IPv6:** strips zone ID suffix (`%en0`), walks AF_INET6 interfaces, applies 16-byte prefix mask comparison
- **Loopback:** `127.0.0.1` and `::1` unconditionally allowed; IPv4-mapped loopback `::ffff:127.0.0.1` is normalised to `127.0.0.1` before the check

**Request size cap:** `accumulate()` rejects any request whose accumulated bytes exceed 128 KB (`maxRequestBytes`) — both on an oversized `Content-Length` header and on total buffer growth — returning `413 Content Too Large`. This prevents memory exhaustion from slow or malicious LAN clients.

**HTML/JS injection prevention:** see [HTML escaping](#html-escaping) below for the two escaping paths (`he()` for HTML attributes, `jsEscapeForScript()` for JSON blobs in `<script>` tags) and the client-side `hej()` helper.

**No authentication** — LAN-only tool. Settings warns: *"Local network access only. No authentication. Do not expose this port to the internet."*

---

## HTML escaping

All user-derived strings pass through `he(_ s: String)` (defined in `GuideViewHelpers.swift`) before HTML interpolation. Escapes `& < > "`. JS reads via `el.dataset.*` which auto-decodes, so no double-decoding needed. Device filter `onclick` handlers use `this.dataset.dev` (already HTML-escaped) instead of interpolating `DeviceID` into a JS string literal.

JSON blobs embedded inside `<script>…</script>` (`var tuners`, `var recsByDev`) additionally pass through `jsEscapeForScript()` (defined in `WebServer.swift`), which replaces `<`, `>`, and `&` with their `\uXXXX` JS Unicode escapes. `JSONSerialization` does not escape these characters by default, and browsers treat `</script>` as an end-tag even inside a JS string literal.

Client-side `innerHTML` concatenation (tuner popover rows) uses the page-local `hej(s)` JS helper — same escaping, in the browser. Show titles, channel numbers, and tuner names all go through it there.

---

## Connection model

- `NWListener` runs on a private `DispatchQueue` (`hdhrVCRplus.webserver`, `.utility`).
- Each connection uses an **accumulating reader** (`accumulate(conn:buffer:)`) that loops `conn.receive` calls until:
  1. `\r\n\r\n` is found (headers complete)
  2. `Content-Length` header is parsed
  3. That many body bytes have arrived
  
  This correctly handles POST requests where the browser delivers headers and body in separate TCP segments.

- **128 KB cap:** any request whose total buffered bytes exceed `maxRequestBytes` (128 KB), or whose `Content-Length` exceeds that limit, is rejected immediately with `413 Content Too Large`. The buffer is grown via `Data.append()` (in-place when only one reference exists) rather than `+` to avoid O(n²) copying.
- The `\r\n\r\n` separator is a `private static let httpSep` constant so no allocation occurs per receive callback.
- After assembly: method + path parsed from request line. If path is `/api/events`, `registerSSE(conn)` is called and the connection is kept alive indefinitely (see SSE section). Otherwise a `Task` hops to `@MainActor`, response built, `send()` called from network queue.
- `send()` writes a single HTTP/1.1 response `Data` packet with `isComplete: true` — this marks the end of *this response's* content on the NWConnection; it does **not** by itself send a TCP FIN or force the connection closed (verified empirically — `curl --next` and raw sequential-request sockets both reuse the connection across responses sent this way). Whether the connection actually closes is controlled entirely by the `Connection` header logic below and the explicit `conn.cancel()` calls in `send()`'s completion handler.
- **TCP_NODELAY:** the NWListener is created with `NWProtocolTCP.Options().noDelay = true` to disable Nagle's algorithm, ensuring response bytes are flushed immediately rather than held for coalescing.

**HTTP/1.1 keep-alive:** the connection is reused across requests **only** when the request is one we can fully frame and safely follow with another response — all of: HTTP/1.1, method `GET` or `POST` (not `HEAD`/others, whose response-body expectations would desync a reused socket), a valid non-negative `Content-Length`, no leftover/pipelined bytes past the body, and the client didn't send `Connection: close`. When all hold, the response carries `Connection: keep-alive` + `Keep-Alive: timeout=30` and `send()`'s completion handler loops back into `accumulate()` on the *same* `NWConnection` (starting from an empty buffer — the reuse gate requires no leftover bytes). Anything else (HTTP/1.0, HEAD, a mis-framed/chunked/oversized body, pipelined writes, or an error response) falls back to `Connection: close` — the pre-keep-alive default — which is what keeps those cases from hanging or corrupting the socket rather than trying to serve them on a reused connection. Error responses (`.notFound`/`.badRequest`/`.payloadTooLarge`) always close regardless of the caller, because a framing failure may leave unread bytes that would misparse the next request.

**Idle close:** `accumulate()` arms a fresh idle-close `DispatchWorkItem` (`idleCloseSeconds` = 30s) before *every* `conn.receive`, cancelled the instant real bytes arrive; the next `accumulate()` call arms a new one. This bounds every state where the server waits on the client — initial connect, a partially-sent request, and the gap between kept-alive requests — so a slow, silent, or abandoned client can't pin a socket open. SSE (`/api/events`) requests flow through `accumulate()` to be read like any other, but once dispatched to `registerSSE()` they leave the request-reuse loop and manage their own indefinite-lifetime connection (kept warm by `sseKeepalive`, not the idle timer).

**stop() closes everything:** every accepted connection is tracked in `liveConns` (registered in `handleConnection`, deregistered via each connection's `stateUpdateHandler` on `.cancelled`/`.failed`). `stop()` cancels all of them alongside the listener and SSE connections — without this, a warm kept-alive connection would keep being served (including state-mutating POSTs) after the web server is disabled or its port changed.

This all exists because every request without keep-alive pays a full TCP handshake before any HTTP bytes can move — on `localhost` that's sub-millisecond and invisible, but on a real LAN Wi-Fi client it's the dominant cost for a page that fires ~20 lazy `/api/guide-detail` requests on load (see "Lazy heavy-data loading" above). Verified via Chrome DevTools Protocol (`Network.responseReceived`'s `connectionReused`/`connectionId`): 20 requests for a full guide load collapse to 6 underlying TCP connections (Chrome's per-host cap), 14 of them explicitly marked reused — versus 19-20 separate connections before this existed.

**gzip compression:** `accumulate()` parses `Accept-Encoding`; when the client supports gzip and an `.ok` body is ≥ 1400 bytes, `send()` compresses it (`Content-Encoding: gzip` + `Vary: Accept-Encoding`). The guide page shrinks ~1.1 MB → ~160 KB — the dominant cost for LAN Wi-Fi clients. Implementation: libcompression `COMPRESSION_ZLIB` (raw DEFLATE) wrapped in a gzip container (10-byte header + CRC-32/ISIZE trailer, table-based CRC in `WebServer.crc32`). Falls back to uncompressed if compression fails or wouldn't shrink the payload. Already-compressed image responses (channel icons, app icon PNG) are never gzipped. `GET /` and `GET /vertical`'s responses are the exception to "compressed on every request" — see `.okPrecompressed` below.

**`WebResponse` cases:**

| Case | HTTP status | Use |
|---|---|---|
| `.ok(contentType:body:)` | 200 OK | Successful GET or POST; gzip-compressed by `send()` when client supports it and body ≥ 1400 bytes |
| `.okPrecompressed(contentType:raw:gzip:)` | 200 OK | `GET /` and `GET /vertical` — both routes' raw and already-gzipped bodies were computed once in `prebuildPageHTML(state:)` (`cachedHTML`/`cachedHTMLGzip` and `cachedVerticalHTML`/`cachedVerticalHTMLGzip` respectively); `send()` just picks one based on `Accept-Encoding` instead of re-running DEFLATE per request |
| `.notFound(String)` | 404 Not Found | Unknown path |
| `.badRequest(String)` | 400 Bad Request | POST with missing required fields |
| `.payloadTooLarge(String)` | 413 Content Too Large | Request body exceeds 128 KB |

---

## Tuner occupancy

`buildHTML()` bakes tuner counts from `state.activeTunerCount(for:)` (= `max(hardware-polled deviceTunerOccupancy count, recordingShows + in-app VLC stream)`, via the shared `computeDevTuners`) and `device.TunerCount` (total slots) — not `recordingShows` alone, which would miss a tuner locked by another machine running this app against the same physical device, or the in-app VLC stream. These are always current at render time.

On SSE connect, `pushFreshTunerCounts()` fires immediately: it reads `state.activeTunerCount(for:)` per device on `@MainActor` and broadcasts a `tuner_update` event. This corrects the baked-in counts for any client that loads the page before a recording starts — the badge updates within milliseconds of SSE connection rather than waiting for the next recording event or idle tick.

`deviceTunerOccupancy` (populated by `fetchDeviceStatus` in the idle loop) is used for the tuner popover detail rows — per-tuner channel and title — not for the badge count. `teardownRecordingState` also writes into it directly on a recording stop, clearing the just-released tuner's `VctNumber` to `nil` immediately rather than waiting for the next idle-loop poll — otherwise `activeTunerCount`'s `max(hardwarePolledCount, recordingShows+vlc)` could transiently over-report that tuner as still occupied for the ~1.5s until the poll catches up.

---

## AppState integration

```swift
let webServer        = WebServer()
@Published var webServerRunning: Bool    = false
@Published var webServerError:   String? = nil

func setupWebServer()   // updates the Web_server_enabled share of desired state; called at startup and on Settings save — see AppState.md's reconcileWebServerState() for the actual start/stop arbiter
func quit()             // calls webServer.stop()
```

`onAirNow(for:at:)` is shared between `WatchNowView` and `WebServer.buildHTML`.

`addShowFromGuide`/`addShow` and `deleteShow` called by the web handlers are the same functions used throughout the app — no web-specific recording logic.

`broadcastEvent` is called directly for `signal_update`/`tuner_update` — events that don't carry guide HTML.

`broadcastRecordingEvent` is called from `AppState` for `recording_started` and `recording_stopped` — see the SSE "Events pushed" table above for what it builds and embeds (`sumPh`/`tdrop`/`tdropDev`).

`broadcastGuideChangeEvent` is called from `AppState` (`refreshGuides`, `addShow`, `skipRecording`, `pauseShow`, `resumeShow`, `deleteShow`, `updateShow`, `fetchDeviceStatusUncached` on a throttled hardware tuner-occupancy count change — `tuner_occupancy_changed`) and from `WebServer` handlers (`handleToggleFavorite`) after state changes that affect the grid — see "Guide-change fragment push" above for what it builds. `handleDelete`/`handleEdit` do not broadcast themselves; they rely on `deleteShow`'s/`updateShow`'s own broadcast so a web-initiated delete or edit doesn't fire the event twice. `addShow` and `updateShow` broadcasting internally (rather than leaving it to each caller) is what makes this unconditional for every add/edit path, not just the web ones — see the `show_added`/`show_updated` notes above.

`broadcastDeviceBarEvent` is called from `AppState.probeForNewDevices` for `deviceOnline`/`deviceOffline` (a device recovering after being missed, or a newly-discovered device) — see the SSE events table above for the `devbar` payload it builds and why.

`guide_refreshed` is broadcast from `AppState.refreshGuides()` when at least one device returned guide data; connected clients apply the pushed grid/sumph/tdrop payload directly (no fetch needed).

---

## Settings (SettingsView — Sharing category)

- **Toggle** — `Web_server_enabled` (default `false`)
- **Port field** — `Web_server_port` (default `1980`; validated 1025–65534; invalid values block Save)
- **Access row** — shown when `state.config.Web_server_enabled && state.webServerRunning`; LAN IP + port as selectable monospaced text with `Open` link; uses `availableNetworkInterfaces()`, skipping `utun` interfaces. Link uses IP directly (`http://x.x.x.x:port`) to avoid browser HTTPS upgrade of `.local` hostnames.
- **Error banner** — shown when `state.webServerError` is non-nil

---

## AppConfig fields

```swift
var Web_server_enabled: Bool = false
var Web_server_port:    Int  = 1980
```

---

## Testing and mocking API calls

The web server runs on `localhost:1980` (or whatever port is configured). All routes are plain HTTP, so `curl` covers every endpoint without a browser.

### Step 1 — get real values to use

The easiest source is `/api/now.json`, which shows live on-air entries with the exact field values the record endpoint expects:

```bash
curl -s http://localhost:1980/api/now.json | python3 -m json.tool | head -40
```

Sample output:
```json
[
  {
    "deviceId": "105404BE",
    "guideNumber": "5.1",
    "guideName": "KNBC",
    "title": "Local News at 11",
    "hd": true,
    "startTime": 1748822400,
    "endTime": 1748826000,
    "isRecording": false,
    "isScheduled": false
  }
]
```

Use `deviceId`, `guideNumber`, and `startTime` directly in the POST bodies below.

For entries that are **not currently airing** (future guide slots), open the guide page in a browser, right-click a program block → **Inspect Element** and read the `data-device`, `data-num`, and `data-start` attributes directly off the element.

---

### POST /api/record — schedule a recording

```bash
# Single episode
curl -s -X POST http://localhost:1980/api/record \
  -H "Content-Type: application/json" \
  -d '{"deviceId":"105404BE","guideNumber":"5.1","startTime":1748822400,"showType":"single"}' \
  | python3 -m json.tool
```

```bash
# Series — any channel
curl -s -X POST http://localhost:1980/api/record \
  -H "Content-Type: application/json" \
  -d '{"deviceId":"105404BE","guideNumber":"5.1","startTime":1748822400,"showType":"seriesAll"}' \
  | python3 -m json.tool
```

```bash
# Title override — omit "title" entirely to keep the server's own SeriesID suffix stripping
curl -s -X POST http://localhost:1980/api/record \
  -H "Content-Type: application/json" \
  -d '{"deviceId":"105404BE","guideNumber":"5.1","startTime":1748822400,"showType":"single","title":"My Custom Title"}' \
  | python3 -m json.tool
```

**Expected success:**
```json
{"ok": true, "title": "Local News at 11", "tunerFull": false, "recStarted": false, "tunerActive": 1, "tunerTotal": 2}
```

**Expected failure (wrong startTime):**
```json
{"ok": false, "error": "Guide entry not found"}
```

**Expected 400 (missing field):**
```
Missing required fields: deviceId, guideNumber, startTime
```

---

### GET /api/airings/{seriesId} — other upcoming episodes

```bash
curl -s http://localhost:1980/api/airings/EP000000012345 | python3 -m json.tool
```

**Expected success:**
```json
{"airings":[{"start":1752182400,"end":1752186000,"ch":"4.1","chName":"KOMO","ep":"S01E13 · Episode Name","device":"105404BE","genre":"Kids","chLogo":"https://img.hdhomerun.com/channels/US31262.png","title":"Local News at 11"}]}
```

**Unknown/absent series:**
```json
{"airings":[]}
```

---

### POST /api/delete — remove a show

`title` is used as a fallback match for series shows; `deviceId` + `guideNumber` identify recording shows precisely.

```bash
curl -s -X POST http://localhost:1980/api/delete \
  -H "Content-Type: application/json" \
  -d '{"deviceId":"105404BE","guideNumber":"5.1","startTime":1748822400,"title":"Local News at 11"}' \
  | python3 -m json.tool
```

**Expected success:**
```json
{"ok": true, "title": "Local News at 11"}
```

**Expected failure (show not in schedule):**
```json
{"ok": false, "error": "Show not found"}
```

---

### GET /api/now.json — on-air listing

```bash
curl -s http://localhost:1980/api/now.json | python3 -m json.tool
```

Returns an empty array `[]` when no guide data is loaded (device not yet discovered or guide fetch failed).

---

### GET / — full guide page

```bash
# Fetch and inspect raw HTML size
curl -s http://localhost:1980/ | wc -c

# Check HTTP headers only
curl -sI http://localhost:1980/
```

---

### Device-level mocking with mock_hdhr.py

`tools/mock_hdhr.py` adds a second fake HDHomeRun device (ID `FFFF0001`) at `127.0.0.2`. It proxies all requests to the real device so guide data, lineups, and recordings are real — only the device identity is spoofed. This lets you test multi-device logic (device switcher, per-device tuner counts, channel dedup) without a second physical tuner.

```bash
# Normal: second device mirrors the real one
sudo python3 tools/mock_hdhr.py

# Simulate broken lineup (no channel list)
sudo python3 tools/mock_hdhr.py --bad-lineup

# Simulate broken guide data
sudo python3 tools/mock_hdhr.py --bad-guide

# Both: no lineup AND no guide (tuner fully non-functional)
sudo python3 tools/mock_hdhr.py --bad-tuner
```

Stop with **Ctrl+C** — the loopback alias (`127.0.0.2`) is removed automatically.

With the mock running, the web server will show two devices in the switcher bar and a combined channel list in the guide grid.

**Gotcha — `FFFF0001` collision with a leftover config test device.** This mock's hardcoded device ID (`FFFF0001`) is the same ID a fake EXTEND device sometimes left sitting in a dev config points at (kept intentionally to exercise the "tuner no longer detected" edit-modal path above — see `tools/mock_scenario.py` below, and the "Web guide offline devices" invariant in `CLAUDE.md`). If a show in `state.shows` references `hdhr_record: "FFFF0001"` and you start `mock_hdhr.py`, that device suddenly becomes *detected* (real mDNS + UDP responses), so the show stops showing the not-detected edit-modal banner for as long as the mock runs. Expected, not a bug — just worth knowing before you go looking for why that banner disappeared.

---

### Scenario mocking with mock_scenario.py

`tools/mock_scenario.py` plants mock states in the **running app** over its own live web/guide API — no root, no fake device, no second tuner. It reads the real guide and either schedules `[MOCK] `-prefixed shows or plants a fake "already recorded" stub file, then can clean up after itself. Verified working end-to-end (2026-08-01): `record-test` schedules a real now-airing entry and confirms the recorder actually writes growing bytes before cleaning up; `conflict` schedules N+1 overlapping shows on an N-tuner device and confirms the conflict; `clean` removes only its own `[MOCK]`-titled shows and `19700101_0000`-signed files.

```bash
tools/mock_scenario.py list                    # upcoming managed airings mockable via `duplicate`
tools/mock_scenario.py duplicate [--series X]   # plant a fake "already recorded" file → green skip flag
tools/mock_scenario.py conflict [--device X]    # schedule overlapping shows on one tuner → conflict
tools/mock_scenario.py record-test [--series X] # schedule a now-airing entry, verify it records, self-clean
tools/mock_scenario.py clean                    # remove everything the tool created
```

Needs the app running with the web server on; `duplicate` also needs Series-subfolders + Skip-already-recorded on. Not wired into `swift test` or `deploy.sh` — it's a manual/on-demand check, and `record-test` in particular is the best available regression check for the RecordingManager pipeline (spawn/write/stop), which has no automated unit-test coverage since it drives a real `curl` process.

---

### Testing a recording without live TV

From CLAUDE.md: set `show_next` to `now + 30 s` and `show_end` to `now + 2 min` in the saved config JSON, then restart the app. The idle loop will pick it up and attempt to start `curl`. Check `show_fail_reason` in the config if it fails; enable verbose curl (Settings → Advanced) to see the raw HTTP exchange with the device.

**Simpler alternative:** `tools/mock_scenario.py record-test` (see above) does this same schedule-and-verify against a real currently-airing guide entry, without hand-editing the config JSON, and self-cleans afterward.

---

### Checking web server logs

```bash
# Stream live (requires app to be running)
log stream --level info --predicate 'subsystem == "com.hdhr.vcrplus"' | grep WebServer

# Show last 10 minutes
/usr/bin/log show --last 10m --info \
  --predicate 'subsystem == "com.hdhr.vcrplus"' | grep -i webserver
```

Key log prefixes: `[WebServer] Listening`, `[WebServer] mDNS registered`, `[WebServer] buildHTML tuners`, `[WebServer] Rejected non-LAN`.
