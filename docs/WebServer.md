# WebServer.swift — Built-in LAN Web Server

Serves an interactive guide page and JSON API over HTTP. The page is consumed by two clients: **external browsers** on the local network, and the **in-app WKWebView** windows (`FloatingGuideView` browse window and `AddShowView` step 2). Both connect to the same SSE stream and see the same HTML. Enabled via **Settings → Web Server → Enable Web Server**. Default port: **1980**.

The web server is scoped to **scheduling and management** — playback is not supported. There are no streaming routes or media links.

---

## API surface

```swift
func start(port: Int, appState: AppState, onState: @escaping (String?) -> Void)
func stop()
func updateTXTRecord()    // @MainActor — refreshes mDNS TXT record; called from idleLoop
func broadcastEvent(_:)   // pushes a JSON event to all open SSE clients
func broadcastRecordingEvent(type:channel:device:state:)  // @MainActor — builds sumPh + the device's tdrop fragment and calls broadcastEvent
func prebuildPageHTML(state: AppState)   // @MainActor — pre-renders and caches desktop + mobile HTML; called after fetchAllGuides / refreshGuides
func invalidateHTMLCache()               // clears cachedHTML so the next GET / rebuilds
```

`onState` is called on `DispatchQueue.main`. `nil` = server is ready; non-nil = error string.

`stop()` nils the internal `stateCallback` before cancelling the listener so the `.cancelled` state handler does not surface as an error when stopping intentionally.

---

## Routes

| Method | Path | Response |
|---|---|---|
| GET | `/` or `/index.html` | Full guide HTML page |
| GET | `/api/ping` | `{"ok":true,"version":"260606-1155"}` — health check + build version; used as self-ping after bind and by the page staleness checker |
| GET | `/api/events` | SSE stream — kept open; server pushes JSON events on state changes |
| GET | `/api/now.json` | JSON array of on-air entries (see schema below) |
| GET | `/api/signal` | JSON object `{guideName: "good"|"fair"|"poor"|"noData"}` — snapshot of `ChannelSignalStore.shared.buckets` keyed by `guideName.lowercased()` |
| POST | `/api/record` | Schedule a recording |
| POST | `/api/signal-scan` | Trigger a signal strength scan. Optional body `{"force":true}` rescans all channels regardless of freshness. Returns `{"status":"started","force":bool}`. |
| POST | `/api/delete` | Remove a managed show and stop any active recording |
| POST | `/api/edit` | Update a managed show's config fields |
| POST | `/api/toggle-favorite` | Toggle the favorite flag for a channel |
| GET | `/api/now-airing/{devId}/{ch}` | JSON `{title, epTitle, poster, endTime}` for the currently-airing guide entry on the given device+channel; used by the tuner popover to enrich external stream rows asynchronously |
| GET | `/api/guide-detail/{devId}/{ch}/{winStart}/{winSec}` | JSON `{entries: [{start, syn, poster, ep, date}]}` — heavy fields (Synopsis/poster/episode/air date) for every entry currently in that channel's guide window, keyed by `start` epoch. `winStart`/`winSec` are the client's own `_winStart`/`_winSec` (the window its DOM was actually rendered against), so the response matches what the client has rather than silently drifting with server "now" time; falls back to the server's current window if those segments are missing/malformed. Lazily fetched by the client's per-row `IntersectionObserver` once a row scrolls into view; these fields are omitted from the initial grid HTML (see "Lazy heavy-data loading" below) |
| GET | `/api/signal-stats/{guideName}` | JSON `{bucket, last, avg, min, max, checked, n, total}` — full signal stats for one channel from `ChannelSignalStore.stats()`; `checked` is the last-sampled epoch (client renders relative). Empty `{}` when no samples. Used by the tuner popover to show inline recordability per active tuner |
| GET | `/api/icon` | Serves the app icon as a 72×72 PNG (for the splash overlay) |
| anything else | | 404 plain text |

---

## POST /api/record

Schedules a recording by calling `state.addShowFromGuide(entry:type:device:channel:)` — the same function the Mac guide wizard uses, so web-scheduled recordings are identical to app-scheduled ones (same notifications, conflict detection, config fields).

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
| `airDays` | no | Day names for `dateTime` shows (e.g. `["Monday","Friday"]`). When absent or empty, defaults to the day-of-week of `startTime`. |
| `transcode` | no | Transcode profile: `"none"` (default) · `"heavy"` · `"mobile"` · `"internet720"`. When absent, the show inherits `config.Default_transcode`. |

`showType` maps to `ShowState`:

| Value | ShowState | Behaviour |
|---|---|---|
| `"single"` | `.single` | Record this airing only |
| `"dateTime"` | `.dateTime` | Record at this time/day every week |
| `"seriesChannel"` | `.seriesChannel` | Record new episodes via SeriesID on this channel |
| `"seriesAll"` | `.seriesAll` | Record new episodes via SeriesID on any channel |

**`tunerFull`** is determined by `AppState.tunersFull(for: deviceId)` — this counts both active recordings **and** the in-app VLC stream. Do not use raw `deviceTunerOccupancy` counts for this check, as VLC occupies a tuner that does not appear in `status.json`.

**Success:** `{"ok": true, "title": "Show Title", "tunerFull": false, "recStarted": false, "tunerActive": 1, "tunerTotal": 2}`

| Response field | Meaning |
|---|---|
| `tunerFull` | All tuners occupied at schedule time — show is queued |
| `recStarted` | `true` when the show is currently on air and recording started immediately |
| `tunerActive` | Current active-tuner count for this device after scheduling |
| `tunerTotal` | Total tuner capacity of this device |

The client uses `recStarted` to immediately color the guide block red (`.g-prog-rec`) vs. yellow (`.g-prog-sched`) without a page reload. `tunerActive`/`tunerTotal` are used to update the `tun-{devId}` badge text in place.

**Failure:** `{"ok": false, "error": "reason"}` (HTTP 200) or `400 Bad Request` plain text for missing fields.

---

## POST /api/delete

Removes a managed show from the schedule and stops any active recording. Flow: `state.discordWebDelete(show)` (edits the existing "Recording Started" Discord embed in-place if one was created) → `recordingManager.stop()` → clear `show_url` and `show_recording` → `state.deleteShow()` → save config.

The stream URL is explicitly cleared on the live show record *before* `deleteShow` is called so the idle loop cannot race in and restart the recording in the gap.

**Request body (JSON):**

```json
{
  "deviceId":    "XXXXXXXX",
  "guideNumber": "5.1",
  "startTime":   1748822400,
  "title":       "Show Title"
}
```

Match priority: recording show on exact device+channel first, then active show matching title (handles series shows on any channel).

**Success:** `{"ok": true, "title": "Show Title"}`  
**Failure:** `{"ok": false, "error": "Show not found"}`

---

## POST /api/toggle-favorite

Toggles the favorite status of a channel by calling `AppState.toggleFavorite(device:channel:)`. Optimistically mutates `lineups[deviceId][idx].Favorite` in-place, fires an async HDHR API call (`HDHRManager.setFavorite()` → `POST http://{ip}/lineup.post?favorite=+/-GuideNumber`), and reverts on failure. Broadcasts a `favorite_toggled` SSE event so all open guide pages refresh.

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
  "resetFailures": true
}
```

| Field | Type | Effect |
|---|---|---|
| `showId` | String | **Required.** Identifies the show to update |
| `showType` | String | `"single"` / `"dateTime"` / `"seriesChannel"` / `"seriesAll"` — updates series flags |
| `paused` | Bool | Pause or unpause; unpausing calls `clearFailures()` |
| `title` | String | Show title |
| `channel` | String | Guide channel number |
| `length` | Int | Recording length in minutes |
| `bonusTime` | Bool | Bonus time flag |
| `transcode` | String | Transcode profile |
| `airDays` | [String] | Air day list (used for `dateTime` shows) |
| `resetFailures` | Bool | Clears `show_fail_count`/`show_fail_reason` and sets `show_active = true` |

Promoting a show to a `seriesId` type (`seriesChannel`/`seriesAll`) when it previously was not triggers `rescheduleAllSeries()` immediately so `show_next` is populated before the next idle loop tick.

**Success:** `{"ok": true, "title": "Updated Title"}`  
**Failure:** `400 Bad Request` — `"Missing required field: showId"` or show not found.

---

## Edit modal (`#edit-modal`)

`position: fixed` overlay (z-index 201). Opened from two paths:
- **Per-tuner dropdown rows** — each `.sp-row` has an `onclick="openEditShow(this)"` handler; `data-*` attrs are embedded by `buildTunerShowsHTML`
- **Guide grid** — Edit button in the summary panel calls `doEditFromGuide()`, which re-packages `data-show-*` attrs from the selected `.g-prog` block into the same shape `openEditShow()` expects

**Contents:**
- Show title + channel (read-only display)
- Type selector (single / weekly / series channel / series any)
- **Air Days row** — visible **only for `dateTime`** (weekly repeat) type; 7 Su–Sa toggle buttons. Hidden for all other types. At least one day must remain selected.
- **SeriesID row** — visible for series types
- Length field (minutes)
- Bonus Time toggle
- Transcode selector
- Paused toggle
- **Reset Failures link** — shown when `failcount > 0`; sets `resetFailures: true` in payload
- Cancel / Save buttons

Save Directory is **not** editable from the web UI — directory path changes require local app access.

On **Save**: `confirmEdit()` POSTs `/api/edit` and closes modal on success. An SSE event (`show_updated`) is pushed to all connected clients immediately after the server-side update, triggering `refreshGuide()` in place.

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
| `recording_started` | `AppState.startRecording` | `channel`, `device`, `sumPh` (HTML), `tdrop` (HTML), `tdropDev` |
| `recording_stopped` | `AppState.teardownRecordingState` | `channel`, `device`, `sumPh` (HTML), `tdrop` (HTML), `tdropDev` |
| `guide_refreshed` | `AppState.refreshGuides` (on success) | *(none beyond type)* |
| `show_added` | `AppState.addShowFromGuide` | `channel`, `device` |
| `show_deleted` | `WebServer.handleDelete` | `channel`, `device` |
| `show_updated` | `WebServer.handleEdit` | `channel`, `device` |
| `favorite_toggled` | `WebServer.handleToggleFavorite` | `device`, `guideNumber` |
| `deviceOffline` | `AppState.probeForNewDevices` (miss #3) | `deviceId` |
| `deviceOnline` | `AppState.probeForNewDevices` (seen after unavailable, or new device) | `deviceId` |
| `signal_update` | `AppState.startSignalScan` | `gname` (guideName.lowercased()), `bucket` (raw string: `"good"` / `"fair"` / `"poor"` / `"noData"`) |
| `tuner_update` | `WebServer.pushFreshTunerCounts` (on SSE connect) | `counts`: `{deviceId: {a: active, t: total}, …}` — live occupancy from `recordingShows` |

`recording_started` and `recording_stopped` carry pre-rendered `sumPh` and `tdrop` HTML fragments built by `broadcastRecordingEvent` → `buildSumPhHTML` + `buildTunerShowsHTML(state, device)`. The client applies `sumPh` to `#sum-ph` and `tdrop` to `#tdrop-{tdropDev}` inline without a second HTTP request.

**Client handling (four cases):**

1. `tuner_update` — updates `tuners[dev].a` in-place and refreshes all `#tun-{dev}` badge elements. Fired on every new SSE connection so the badge is accurate immediately, not just after a recording event.
2. `signal_update` — updates SVG signal bars in-place on matching `.g-row[data-gname]` rows. No `refreshGuide()`.
3. Events with `sumPh`/`tdrop` — applies `#sum-ph` and the affected tuner's `#tdrop-{tdropDev}` directly. For recording events also toggles `.g-prog-rec` / `.g-prog-now` classes and the `.g-flag-rec` child on the currently-airing guide entry for the affected channel+device. No `refreshGuide()`.
4. All other events — `refreshGuide()` (scroll-preserving partial DOM swap).

`guide_refreshed` falls into case 4 — `refreshGuide()` fetches the full page and swaps the grid, bringing schedule flags and channel data up to date after a guide cycle. It is broadcast roughly **once per clock-hour boundary** (the `lastRefreshHour` gate in `AppState.idleLoop` → `refreshGuides()`), so an idle guide window does a background refresh about hourly even with no user activity.

`EventSource` auto-reconnects after 3 s on drop. `stop()` cancels all SSE connections and clears the registry.

---

## HTML page — visual layout

Self-contained HTML with all CSS inlined. Updates arrive via SSE push events (see below) and targeted DOM swaps after user actions. The page hard-reloads automatically if the server version changes (redeploy detected via 60-second `/api/ping` poll) or if the baked-in 2-hour expiry elapses. Tuner occupancy is sourced from the `AppState.deviceTunerOccupancy` cache, which the idle loop refreshes every 10 seconds via `fetchDeviceStatus()`.

**HTML cache:** `prebuildPageHTML(state:)` pre-renders the page HTML after every guide load (`fetchAllGuides`, `refreshGuides`) and stores it in `cachedHTML` — one shared copy for all UAs, since desktop and mobile now render the same guide window (see below). It also gzips that HTML once at the same time and stores the result in `cachedHTMLGzip`; `GET /` returns `.okPrecompressed(...)`, which picks whichever of the two `send()` already has on hand based on the request's `Accept-Encoding` instead of re-running DEFLATE on every request (the page is ~1.5 MB raw — compressing it costs ~30–60 ms, dwarfing everything else in a LAN page load, so paying that cost once per guide refresh instead of once per `GET /` was a meaningful win). Both caches are `nil` only before the first guide load, in which case the page falls back to a live synchronous build (via the generic `.ok(...)` case, gzipped on the fly by `send()` same as any other response). This eliminates the 2–4 second `@MainActor` blocking time on first load for remote clients.

**Splash overlay:** a fixed `#splash` div (z-index 9999) covers the page on load, showing the app icon (from `/api/icon`), name, and build version. A 300 ms CSS animation delay means the splash is never visible on fast local loads (the page's `requestAnimationFrame` fires and removes it before the animation starts). On slow remote loads it fades in after 300 ms and is removed once the first `rAF` fires. `/api/icon` serves the `AppIcon.icns` scaled to 72×72 as PNG via `NSImage` + `NSBitmapImageRep`.

`refreshGuide()` is called client-side after user actions (record, delete, edit) and on receipt of an SSE event. It updates the guide grid without a page reload:

- **`refreshGuide(selOverride?)`** — saves `.gw` scroll position and the currently-selected `.g-prog` element (`data-start` + `data-num` + `data-device`); `GET /` → DOMParser → swaps `.gi` (guide grid), `#sum-ph` (summary placeholder), and each `.tdrop` body (`#tdrop-{devId}`); re-reads `data-winstart`/`data-winsec` from the new `.g-hdr` into `_winStart`/`_winSec` (keeps the live now-line aligned to the refreshed grid); restores scroll position; re-selects the previously-highlighted entry via `showInfo()`. If `selOverride` is passed (a JS object), its key-value pairs are merged into the re-selected block's `dataset` before `showInfo()` runs — used after a Record action to inject `{recording:'1', managed:'1'}` so the summary panel shows the correct state without requiring a manual re-select.

**Theme variables:** CSS custom properties defined on `:root` (dark default) and overridden on `html.lm` (light). Dark: body `--bg:#141414` · surfaces `--s1–s4` `#1a–#22` · borders `--b0–b5` `#25–#48` · text `--t0–t6` `#f0–#66`. Light: body `--bg:#e4e6ea` · surfaces `#ec–#ff` · borders `#78–#c4` (visible against light backgrounds) · text `--t0–t6` `#11–#7d` (all pass WCAG AA contrast on light surfaces). Theme is toggled by adding/removing the `lm` class on `<html>`; preference is stored in `localStorage('theme')` with `'auto'` following `prefers-color-scheme`.

Page structure (top to bottom):

1. **Top toolbar** (`#toolbar`) — a single horizontal, wrapping row holding (left→right): `h1` title, the per-tuner box list (`#dev-bar`, one `tunerBox` per discovered + offline device), the genre filter (`#genre-bar`, shown when applicable), and — pushed to the far right via `margin-left:auto` — the theme switcher (`#theme-sw`, dark/auto/light). Guide navigation (⊙ Now / ↺ Refresh) lives in the guide corner cell, not the toolbar. There is no global schedule popover — each tuner box has its own ▾ dropdown.
2. **Tuner popover** (`#t-pop`) — fixed overlay; shown by clicking a tuner badge
3. **Summary panel** (`#sum`) — always visible; selected show details + actions
4. **Record type modal** (`#rec-modal`) — fixed overlay; appears on Record click
5. **Edit modal** (`#edit-modal`) — fixed overlay (z-index 201); appears on Edit click or schedule-popover row click
6. **Per-tuner dropdowns** (`.tdrop`, one `#tdrop-{devId}` per tuner) — absolute-positioned panels under each tuner box, toggled by the box's ▾ (`toggleTunerDrop`). Each lists that tuner's own Recording / Up Next / Scheduled / Paused (`.sp-*` classes) from `buildTunerShowsHTML(state:, deviceId:)`.
7. **Guide grid** — scrollable cable-guide grid (width/time-window depends on UA; see below)

**Per-tuner ▾ dropdown** (`.tdrop-btn` → `toggleTunerDrop(devId)`): each tuner box has a ▾ button that toggles its `#tdrop-{devId}` panel (absolute, below the box). Opening one closes any other; a document-level click handler closes open dropdowns when the click is outside any `.tuner-box`.

**Auto-select on load**: deferred into a `requestAnimationFrame` callback so the guide grid paints first (LCP element). On the first animation frame, an IIFE finds the first visible `.g-row` and selects the currently-airing `.g-prog`, populating the summary panel. `scrollToNow()` runs in the same callback. Deferring both prevents the externally-fetched CDN poster image from becoming the LCP element.

---

### Tuner boxes (`#dev-bar` in the toolbar)

`#dev-bar` is a wrapping flex row with one `tunerBox` per discovered device **plus** one per
offline/absent device (any `show.hdhr_record` not in `state.devices`). Rendered for every
configuration including a single device. Each box (`.tuner-box`) has a `.tuner-row`:
**HDHR-XXXXXXXX** name + **↗** device web-UI link + live count badge (`.t-info` → `showTunerInfo`)
+ **▾** (`.tdrop-btn` → `toggleTunerDrop`), followed by a hidden `#tdrop-{devId}` panel.

**Active vs inactive.** A tuner is *active* when it's in `state.usableDeviceIDs` (discovered AND
reachable). Active: name is a `.d-btn` `setDev` filter, badge shows live `n/m`. Inactive
(unreachable or absent): the whole box gets `.tuner-off` (dimmed), the name is a non-clickable
`.d-btn-off` label, and the badge reads **offline** (`.t-info-off`). The ▾ dropdown works either
way and lists that tuner's assigned shows.

Clicking an active name calls `setDev(devId)`, filtering guide rows to that device via `data-dev`.

**Default tuner (no combined view).** With more than one tuner there is no "All" view — the grid
opens on a single tuner. `buildHTML` computes `defaultDev` = the first device with both a
non-empty lineup and loaded guide data (fallback: first with a lineup, else `""`), and the
bootstrap call is `setDev('<defaultDev>')`. Single-device keeps `setDev('')`. Users switch
tuners via the active device names.

**Tuner badges** (`.t-info` / `.t-info-full`): show `active/total` slots. Red styling when full. Clicking opens the tuner popover.

---

### Tuner popover (`#t-pop`)

Fixed overlay (z-index 200). Positioned below the clicked tuner badge. Shows:
- **Header** — `active/total tuners` (+ `— FULL` when all occupied)
- **Per-active-tuner rows** — see below
- **`status.json ↗`** link — opens `http://{LocalIP}/status.json` in a new tab

**Per-tuner row content:**

| Tuner state | Display |
|---|---|
| Idle (no channel locked) | Tuner label + "Idle" in dim text |
| Our recording | Tuner label · channel · show title (clickable) · red ● dot · "Ends H:MM AM/PM" |
| External live stream | Tuner label · channel · guide title (clickable) · episode name · "Ends H:MM" · client IP |

**Recording match** (`recsByDevJS` builder): prefers `show_tuner_resource` (case-insensitive); falls back to `show_channel == VctNumber` when the resource header hasn't been captured yet (first ~1.5 s of a new recording).

**Clickable titles — jump to guide:** all non-idle tuner rows have a clickable title (underline dotted, pointer cursor) that calls `goToShow(ch)` — closes the popup, finds the currently-airing `.g-prog` for that channel, scrolls it into view, and calls `showInfo()`. Our own recording rows get this treatment via a synchronous post-render loop. External stream rows (`"Live stream ch X"` title) additionally fire `fetch('/api/now-airing/{devId}/{ch}')` to patch the DOM with the real guide title, episode name, poster thumbnail, and end time.

**Red recording dot** appears on external streams when `recsByDev` contains a matching `rec=1` entry for the same channel on any device.

**Inline signal quality:** every non-idle tuner row with a `chname` fires `fetch('/api/signal-stats/{chname}')` and appends a small line — colored dot + bucket label (`Poor`/`Fair`/`Good`) + `{avg}% avg · {last}% last · checked {relTime}`. Colors match the guide-row SVG bars and `bColors` SSE palette. Skipped when the channel has no samples (server returns `{}`). `relTime()` renders the `checked` epoch as `just now` / `Xm ago` / `Xh ago` / `Xd ago` so stale readings are obvious.

**Generation token (`tPopGen`):** bumped on every `showTunerInfo` open and `closeTunerPop`. Each enrichment fetch (signal-stats and now-airing) captures `gen` at start and bails if `gen !== tPopGen` when its response arrives — prevents stale fetches from a closed/rebuilt popover appending duplicate or outdated DOM.

Active tuner detection: `DeviceTunerInfo` entries where `VctNumber != nil`. Idle slots (returned by the device with only `"Resource"` present) are not counted. Occupancy data comes from `AppState.deviceTunerOccupancy`, kept warm by the idle loop (see Tuner occupancy section).

**`GET /api/now-airing/{devId}/{ch}`** — returns `{title, epTitle, poster, endTime}` for the currently-airing guide entry on that device/channel. `endTime` is a Unix timestamp string.

---

### Summary panel (`#sum`)

Always rendered above the guide grid. Two states:

**Placeholder** (`#sum-ph`): "Select a show from the guide" — on load and after close.

**Selected** (`#sum-c`): appears when the user clicks a program block. Layout (left to right):
- **Poster image** — hidden if no `ImageURL`. Default: 72 px wide, `object-fit: contain`. Tablet (≤ 960 px): 56 px. Desktop (≥ 961 px): 260 px, `align-self: center`. **Progressive loading:** `showInfo()` sets the `<img src>` to the CDN poster URL directly. If the poster fails to load, an `onerror` handler (set in JS each time `showInfo()` runs, not inline) falls back to the channel logo URL; if that also fails, the image is hidden. A `data-pgen` generation counter prevents a slow CDN fetch for an earlier selection from overwriting a later selection's image.
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

**Watch buttons** (`#sum-watch-app`, `#sum-watch-vlc`) — shown **below** the record/managed/stop block when the selected show is currently on air (`_wLive`) **and** the page is loaded inside a `WKWebView` (`_wInApp` flag, set by checking `window.webkit?.messageHandlers?.watch` on page load). These buttons post to `window.webkit.messageHandlers.watch` and are never visible in a regular browser (the flag stays false). `doWatchInApp()` posts `{type:'app', ...}`; `doWatchInVLC()` posts `{type:'vlc', ...}`.

**Actions are applied in-place** — no page reload on record or delete. On record success, the selected block gains `.g-prog-sched` + yellow triangle flag and the action row swaps to Scheduled+Remove. On delete success, the block loses its flag/color and the Record button reappears.

---

### Record type modal (`#rec-modal`)

Styled to match `#edit-modal`: same 400 px width, `max-height: calc(100vh - 40px)`, scrollable, themed via `var(--s2)` / `var(--b2)` CSS variables. `position: fixed` overlay (z-index 100). Appears when Record is clicked.

**Contents (top to bottom):**
- **"Record Show"** header with border-bottom separator
- **Show row** — `em-lbl` "Show" label + show title + channel/time below (read-only)
- **Type row** — `em-lbl` "Type" label + four radio options (`recOpts`): Single episode · Weekly repeat · Series — this channel · Series — any channel
- **SeriesID row** (`#rm-sid`, `em-row` style) — visible when a series type is selected; value in `em-sid` monospace style
- **Days row** (`#rm-days-row`, `em-row` style) — visible when "Weekly repeat" (`dateTime`) is selected; 7 Su–Sa toggle buttons pre-checked to the guide entry's day of week. At least one day must remain selected (last-day deselect is blocked).
- **Transcode row** — `em-lbl` "Transcode" label + `<select id="rm-transcode">` with the same 4 options as the edit modal. Resets to "None (copy stream)" each time the modal opens.
- **Tuner-full warning** (`#rm-tuner`) — amber banner shown when device is full and show is currently airing
- **Footer** with border-top separator — Cancel / Schedule buttons

On **Schedule**: `confirmRecord()` collects selected air days from `#rm-days .day-btn.sel` and the transcode value from `#rm-transcode`, then POSTs both to `/api/record`. The transcode value is applied to the new show (overriding the config default). On success:
- Guide block gains `.g-prog-rec` + red triangle flag if `recStarted` is true (show currently airing); otherwise `.g-prog-sched` + yellow triangle flag.
- Summary note shows "● Recording now", "⚠ Queued — all tuners busy", or "★ Scheduled — next idle loop pick-up".
- The summary delete button becomes **"Stop & Delete"** (+ `danger` class) when `recStarted`; stays **"Remove"** otherwise.
- `refreshGuide({recording:'1',managed:'1'})` or `refreshGuide({managed:'1'})` is called so the re-selected block's `dataset` reflects the new recording/managed state before `showInfo()` runs — the summary panel updates without requiring a manual re-click.
- Tuner badge `#tun-{devId}` is updated in place with the new active/total count from `tunerActive`/`tunerTotal`.
- Per-tuner dropdown bodies are refreshed in place by `refreshGuide()` (and recording events).

---

### Guide grid

A cable-TV-style horizontal time grid. Desktop and mobile clients both get the full `GuideHours` window (default 24 h) — `winSec = GuideHours * 3600` regardless of UA. `isDesktopUA(_ ua: String)` (private helper) still classifies the UA server-side for `/api/guide-refresh`'s grid rebuild, but no longer affects window size or which cached page HTML is served (see "HTML cache" above — one shared `cachedHTML` now covers all UAs).

**Window start:** `winStart = (nowTs / 1800) * 1800 - 1800` — floors to the nearest 30-minute boundary then subtracts one slot, giving a 30–60 minute lookback. `GuideStore.entries()` is called with `after: Date(winStart)` (not the default `after: Date()`) so shows that already ended but fall within the lookback are included. Gap periods with no guide data render as `.g-gap` divs (fully opaque `var(--bg)`) so the striped `.g-tl` background never shows through. On page load, `scrollToNow()` is called inside the `requestAnimationFrame` callback (alongside the auto-select IIFE) so the now-line sits ~25% from the left of the visible viewport after the first paint.

**Live now-line:** `_winStart` and `_winSec` are baked into the page JS at render time. `nowPct()` recomputes the now-line position as `(Date.now()/1000 - _winStart) / _winSec * 100`, clamped to [0, 100]. `updateNowLine()` updates the `left` style on all `.g-now-bar` and `.g-now-tick` elements every **1 minute** via `setInterval`.

**`refreshGuide()` must resync the window origin.** The grid header (`.g-hdr`, inside `.gi`) carries `data-winstart` / `data-winsec`. Because `refreshGuide()` swaps in a grid that the server rendered against a *fresh* `winStart` (it advances at each hour boundary), `refreshGuide()` re-reads those attributes from the newly-swapped `.g-hdr` and updates `_winStart`/`_winSec`. Without this, `nowPct()` would keep plotting against the stale page-load origin on the new grid and the now-line would drift ahead over time (visible after the guide sits open through an hourly `guide_refreshed`). It also auto-scrolls the guide if the now-line has drifted past **75%** of the viewport width, nudging it back to the 25% position — without disturbing users who have manually scrolled ahead (their now-line is near the left edge, well below the threshold).

**Page staleness:** two guards run every 60 seconds via `checkFreshness()`: (1) if `Date.now()` exceeds the baked-in `_exp` timestamp (render time + 2 hours), the page hard-reloads; (2) `/api/ping` is fetched and its `version` field compared to the baked-in `_ver` — mismatch means a redeploy has occurred, triggering `location.reload()`. The version check catches redeployments within 60 seconds; the `_exp` expiry handles long-open stale tabs.

`div.gi` `min-width` = `max(1200, winSec / 1800 * 100)` px — scales up for wider windows so program blocks never compress below a readable width.

**Layout:**
- `div.gw-outer` — flex child of body (`flex: 1; min-height: 0; display: flex; flex-direction: column`); grows to fill all remaining viewport height below the toolbar and summary card; `overflow: clip` clips the rounded border
- `div.gw` — scroll container (`overflow: auto; flex: 1`); fills `.gw-outer` vertically so the guide always extends to the bottom of the window with no dead space
- `div.gi` — inner, `min-width` scales with window (see above)
- Sticky time-header (`top: 0; z-index: 10`)
- Sticky channel column (`left: 0; z-index: 2`) — both data rows (`.g-ch`) and the header cell (`.g-hdr-ch`) are **125 px** wide. They must match so the `nowPct%` left offset maps to the same pixel position in both the time header and program rows.
- Corner cell (`z-index: 11`) — flex row: "Ch" label (`.g-hdr-ch-lbl`) left, two icon buttons (`.g-hdr-btn`) right: **⊙** calls `scrollToNow()` (now-line to ~25% of viewport), **↺** calls `refreshGuide()` (scroll-preserving DOM swap — not a page reload). Sticky top+left, so the controls stay visible while scrolling the grid in any direction.

**Lazy row rendering:** each `.g-row` carries `content-visibility: auto; contain-intrinsic-size: auto 55px`. The browser skips style/layout/paint for rows scrolled out of view and renders them on demand as they approach the viewport, so the initial paint costs only the ~12 on-screen rows instead of all ~100 — the dominant cost on a full guide (1300+ program blocks, per-row repeating-gradient backgrounds). `contain-intrinsic-size` reserves each skipped row's height so scrollbar geometry is correct before render; the `auto` keyword caches the real measured size after a row renders once. This applies to data rows only, not `.g-fav-sep` separators, and survives `refreshGuide()` DOM swaps since it is pure CSS. Requires a `content-visibility`-capable engine (Safari 18+/WKWebView on macOS 15+, Chrome 85+); older browsers degrade to rendering all rows up front (prior behavior).

**Lazy heavy-data loading:** `.g-prog` blocks ship only light attrs (`data-title`, `data-start`/`data-end`, `data-device`/`data-num`/`data-chname`, `data-genre`, `data-filters`, `data-logo`, `data-series`, `data-managed`, `data-recording`) in the initial grid HTML. Heavy fields (Synopsis, poster `ImageURL`, episode title/number, original air date — `data-syn`/`data-poster`/`data-ep`/`data-date`) are fetched on demand via `/api/guide-detail/{devId}/{ch}/{winStart}/{winSec}`, one batched request per channel row. A page-level `IntersectionObserver` (`initRowObserver()`, root = `.gw`, `rootMargin: 400px`) watches every `.g-row`; when a row nears the viewport it fetches that channel's heavy data once, patches every matching `.g-prog`'s `dataset` in place, and `unobserve`s the row (heavy data for a given row never changes except across a `refreshGuide()` swap). Results are cached client-side in `_heavyCache`, keyed by `"device:channel:start"` — cache hits on a `refreshGuide()`-swapped row apply synchronously with no network round-trip. `fetchRowHeavy()` de-dupes concurrent requests for the same row via `_heavyRowsInFlight` (a `Map` of `"device:channel"` → the in-flight promise, not just a presence flag) so a second caller racing the first (e.g. the observer firing while a click's JIT fetch is also pending) chains onto the real fetch's result instead of resolving early with blank data. `showInfo()`'s poster/episode/date/synopsis rendering goes through `renderHeavyFields(el)` → `paintHeavyFields(el)`, which paints from cache/dataset immediately and falls back to a just-in-time single-row fetch (guarded by a per-element generation token, mirroring the existing `pi.dataset.pgen` idiom) for the case where a block is clicked before its row's observer has fired — e.g. a fast scroll-and-click, or the initial auto-selected "now" block, which runs inside `requestAnimationFrame` and may execute before `initRowObserver()`'s callback. `showInfo()` marks `.g-sel` on the clicked element *before* calling `renderHeavyFields()` so `paintHeavyFields()`'s selection check is accurate on the very first (synchronous) paint. `initRowObserver()` is re-run after every `refreshGuide()` DOM swap (new `.g-row` elements need fresh observation).

**Rows:** one row per (device × channel). Cross-device deduplication is handled client-side by `setDev('')` on page load — it hides duplicate `GuideNumber` rows keeping the first-device occurrence, giving a clean "All" view.

Each `.g-row` carries `data-dev`, `data-ch`, `data-gname` (`GuideName.lowercased()`), and `data-fav` (`"1"` for favorite channels, absent otherwise). `data-gname` is the key used by `signal_update` SSE events; `data-fav` is used by `setDev` to show/hide `.g-fav-sep` headers. Individual `.g-prog` blocks carry `data-inf="1"` when their guide entry's `SeriesID` matches a confirmed paid-programming ID — see Infomercial dimming below.

**Favorites section:** favorite channels are sorted to the top of each device's channel list server-side. A `.g-fav-sep` separator row (amber `★ FAVORITES` label, `display:flex`) is inserted above the first favorite row per device and hidden via `setDev` when no visible favorite rows remain (e.g. another device selected). Favorite channel rows get a golden background tint via `color-mix(in srgb, var(--fav) 16%, var(--s1))` on `.g-ch` and a repeating gradient tint on `.g-tl`. A `☆`/`★` toggle button (`.g-fav-btn`) in each channel cell calls `toggleFav(evt, btn)` to POST `/api/toggle-favorite`.

**Signal bars in channel column:** when `state.config.Signal_quality_enabled` and signal data exists for a channel, a 3-bar SVG (`class="g-sig"`, `viewBox="0 0 11 10"`, `width/height=10`) is baked into the `.g-ch` cell at page build time. Buckets map to fill levels: `good` → all 3 bars, `fair` → 2 bars, `poor` → 1 bar, `noData` → no SVG emitted. The `title` attribute carries `"Signal: {bucket}"` for hover. Bars are updated in-place on `signal_update` SSE events without a page reload.

**`setDev()` and DOM caching**: `.g-row` NodeList is cached into `_rows` at page load and reused on every device switch — avoids repeated `querySelectorAll` calls. When `setDev(id)` is called with a **different** device ID than `curDev`, `_genreFilter` is reset to `''` and the `<select id="genre-sel">` is reset to the blank option, so each device starts with an unfiltered view.

**Genre filter:** a `<select id="genre-sel">` (in `#genre-bar`, hidden unless the guide contains ≥2 distinct genres, new-episode programs, or infomercial programs) is populated at page load from unique `data-genre` values, with a **New** option (value `__new`) appended if any `data-new="1"` programs exist, and an **Infomercials** option (value `__inf`) appended if any `data-inf="1"` programs exist. `filterGenre(g)` sets `_genreFilter` and calls `applyGenreDim()`, which adds `.g-prog-dim` (35% opacity, `pointer-events: none` — dimmed and unselectable) to every program that doesn't match. In new-episode mode (`__new`), non-new programs dim. In infomercial mode (`__inf`), non-inf programs dim. In normal mode, non-genre-matching programs dim and infomercials are always dimmed. Rows are never hidden — only individual programs are dimmed. `setDev()` calls `applyGenreDim()` after row visibility changes so the dim state survives device switches and `refreshGuide()` DOM swaps.

**Infomercial dimming:** individual `.g-prog` blocks whose guide entry `SeriesID` matches a confirmed paid-programming ID (`C11809220ENAPZK`, `C459763EN3L6D`) get `data-inf="1"` on the program element itself — not the row. A channel that airs one overnight infomercial slot is unaffected on its other blocks. By default these programs are dimmed and unclickable. Selecting **Infomercials** in the genre filter (`_genreFilter === '__inf'`) inverts this: inf programs become selectable and recordable, all non-inf programs dim instead.

**Time header:** one tick per clock hour, aligned to hour boundaries via `stride(from: firstHour, through: winEnd, by: 3600)` where `firstHour = ((winStart + 3599) / 3600) * 3600`. Label uses `DateFormatter` template `"j"` (locale-preferred hour, e.g. `"8 PM"` or `"20"`). + red "now" bar.

**Vertical gridlines:** CSS `repeating-linear-gradient` at every **8.3333%** of the timeline element width. Since the timeline spans `winSec` seconds, each gridline represents `winSec × 0.08333 / 60` minutes — 120 min for the default 24 h window (desktop and mobile alike).

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

**Corner triangle flags:** a right-triangle CSS flag (`position:absolute; top:0; right:0`) is rendered as a `<div>` child of the program block using the CSS border trick (`border-width: 0 18px 18px 0`):
- `.g-flag` (yellow `#ffd700`) — managed/scheduled show
- `.g-flag-rec` (red `#ff6060`) — currently recording

Recording takes precedence; yellow shows only when managed but not recording. There are no star or red-circle badges.

**Managed show matching:** `buildHTML` constructs a `ManagedGuideMatcher(activeManagedShows: activeMgd)` — the same struct used by the SwiftUI cable guide — to decide which blocks get a flag and the `data-managed="1"` attribute. `activeMgd` is active, non-paused shows only; the same exclusion applies in `/api/now.json`'s `isScheduled` field so the two flag paths agree.

The four matching tiers (seriesID → title fallback → datetime `device:channel:HH:MM` → single `device:channel:epoch`) are documented in [Models.md — ManagedGuideMatcher](Models.md). `dateTime` shows are matched by local-time slot so every upcoming weekly airing is flagged, not just the one stored in `show_next`.

**Recording flag scoping:** `isRecCh` is scoped to the current device (`recChannelsByDevice[device.DeviceID]`). A recording on device A does not flag the same channel number on device B.

`pendingRecChannelsByDevice` supplements `recChannelsByDevice` with shows that have passed `show_next` but whose idle-loop recording start hasn't fired yet (condition: `show_active && !show_paused && !show_recording && show_next <= now && show_end > now`). This means a guide cell turns red (`.g-prog-rec`) immediately after a web Record tap on a live show — before the next idle loop tick marks `show_recording = true`. Scoped to device the same way as `recChannelsByDevice`.

**Managed show data attributes:** when `isMgd` is true, `findManagedShow(e, ch)` is called to locate the `Show` record and embed its config on the block for use by the edit modal:

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

`findManagedShow` lookup strategy:
- **Series shows** (`isSeries`): SeriesID only — `activeMgdBySeries[entry.SeriesID]`. No title fallback; avoids returning the wrong device's show when the same title is scheduled on multiple devices.
- **dateTime shows**: `"device:channel:Weekday:HH:MM"` slot key — same format as `ManagedGuideMatcher.datetimeSlotKeys`, built from `show_next` time and `show_air_date` entries.
- **Single shows**: `"device:channel:epoch"` slot key — exact scheduled-slot match.

If no match is found (e.g. a series show whose guide entry has no SeriesID), the block still gets `data-managed="1"` and the triangle flag but no `data-show-*` edit attrs — the Edit button will not be pre-filled from the guide for that block.

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

Update paths: `refreshGuide()` swaps each `.tdrop` body in place from a fresh `GET /` (covers
add/remove/edit, which arrive as `show_*` SSE → `refreshGuide`); a recording start/stop pushes
`tdrop`/`tdropDev` in its SSE event and the client swaps just `#tdrop-{tdropDev}`.

---

## JavaScript — key functions

| Function | Purpose |
|---|---|
| `showInfo(el)` | `onclick` on program blocks; reads `el.dataset`, populates summary panel, sets globals |
| `closeSummary()` | Hides summary, restores placeholder, clears `.g-sel` |
| `refreshGuide(selOverride?)` | Partial DOM refresh: saves `.gw` scroll + selected entry; `GET /`; swaps `.gi`, `#sum-ph`, and each `.tdrop` body (`#tdrop-{devId}`); resyncs `_winStart`/`_winSec` from the new `.g-hdr` (so the now-line doesn't drift); restores scroll; re-selects prior entry. Optional `selOverride` object patches `dataset` attrs on the re-selected block before `showInfo()` — used after Record to inject `{recording:'1',managed:'1'}` without a manual re-click. |
| `doRecord()` | Opens record modal; pre-checks day-of-week button matching guide entry; pre-checks Bonus Time for sports entries; resets transcode to `"none"`; shows tuner-full warning if applicable |
| `cancelRecord()` | Hides modal |
| `confirmRecord()` | Collects `airDays` from `#rm-days` and `transcode` from `#rm-transcode`; POSTs `/api/record`; on success: red flag + `.g-prog-rec` if `recStarted`, yellow flag + `.g-prog-sched` otherwise. Delete button becomes **"Stop & Delete"** (+ `danger` class) when `recStarted`, stays **"Remove"** otherwise. Calls `refreshGuide({recording:'1',managed:'1'})` or `refreshGuide({managed:'1'})` so the summary panel reflects the new state immediately. Updates tuner badge `#tun-{devId}` in place. |
| `updateDaysVisibility()` | Shows `#em-days-row` when `_editType === 'dateTime'`; hides for all other types |
| `toggleDay(btn)` | Toggles a day-button selection in the edit modal; prevents deselecting the last selected day |
| `doDelete()` | POSTs `/api/delete`; removes triangle flag/color from block, restores Record button |
| `doEditFromGuide()` | Reads `data-show-*` attrs from selected `.g-prog` block; calls `openEditShow()` |
| `openEditShow(el)` | Populates and opens `#edit-modal` from `el.dataset`; handles both guide blocks and schedule popover rows |
| `closeEditShow()` | Hides `#edit-modal` |
| `confirmEdit()` | POSTs `/api/edit`; closes modal on success |
| `setDev(id)` | Filters guide rows by `data-dev`; empty string = deduped single-device fallback (multi-tuner bootstraps to a real `defaultDev`, not `''`); uses cached `_rows` NodeList; calls `applyGenreDim()` then shows/hides `.g-fav-sep` separators |
| `filterGenre(g)` | Sets `_genreFilter` and calls `applyGenreDim()` |
| `applyGenreDim()` | Clears all `.g-prog-dim`. In new-episode mode (`__new`): dims non-new programs. In infomercial mode (`__inf`): dims all non-inf programs. In normal mode: dims programs that fail the genre filter OR have `data-inf="1"`. Rows always remain visible. |
| `scrollToNow()` | Scrolls `.gw` so the now-line sits ~25% from the left of the viewport; corner-cell ⊙ button and page load both call it |
| `toggleFav(evt, btn)` | `onclick` on `.g-fav-btn` star buttons; reads `data-dev` / `data-ch` from parent `.g-row`; POSTs `/api/toggle-favorite`; calls `refreshGuide()` on success |
| `toggleTunerDrop(devId)` | Toggles that tuner's `#tdrop-{devId}` dropdown; closes any other open `.tdrop` first. A document-level click handler closes open dropdowns on any click outside a `.tuner-box`. |
| `devFull(devId)` | Returns true if `tuners[devId].a >= tuners[devId].t` |
| `showTunerInfo(devId, anchor)` | Opens tuner popover anchored below the clicked badge; renders per-tuner rows immediately from `recsByDev`, then fires async `/api/now-airing` fetches to enrich external stream rows with guide title, episode, poster, and end time |
| `closeTunerPop()` | Hides tuner popover |
| `goToShow(ch)` | Closes tuner popover, finds the currently-airing `.g-prog` block for `ch`, scrolls it into view, and calls `showInfo()` to select it |
| `gc(genre)` | Maps genre → HSL background for summary panel |
| `ft(date)` | Formats Date as `"H:MM AM/PM"` |
| `so(id, val)` | Shows element with textContent, or hides if falsy |
| `hej(s)` | HTML-escapes a string for safe `innerHTML` concatenation (`&`, `<`, `>`) — used in the tuner popover where values come from server-side data |

**Globals:** `_d` (deviceId), `_n` (guideNumber), `_s` (startTime), `_e` (endTime), `_ser` (SeriesID), `_genre` (first genre string), `curDev` (active device filter), `_genreFilter` (active genre filter, `''` = none) — set by `showInfo` (except `_genreFilter`, set by `filterGenre`), consumed by `doRecord`/`doDelete`/`confirmRecord`/`applyGenreDim`. `_genre` is used by `doRecord()` to pre-check Bonus Time for sports entries.

**Embedded JS data:**
- `var tuners` — `{deviceId: {t: total, a: active, surl: "http://ip/status.json"}, …}` — tuner counts from fresh `/status.json` fetch
- `var recsByDev` — `{deviceId: [{tuner, title, ch, chname, ip, idle, rec, endTime}, …], …}` — per-tuner occupancy detail for popover. `ip`: client IP for external streams not matched to our recordings; `idle`: `"1"` when tuner has no channel locked; `rec`: `"1"` when tuner is running one of our recordings; `endTime`: Unix timestamp of recording end (from `show_end`) when `rec==="1"`

Both variables are serialised via `JSONSerialization` (not string interpolation) and passed through `jsEscapeForScript()` before embedding in the `<script>` block. This replaces `<`, `>`, and `&` with `\uXXXX` escapes so a show title or device ID containing `</script>` cannot terminate the script element. Device filter buttons use `onclick="setDev(this.dataset.dev)"` / `onclick="showTunerInfo(this.dataset.dev,this)"` — the DeviceID is read from the already-HTML-escaped `data-dev` attribute rather than interpolated into a JS string literal.

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

## mDNS / Bonjour

When the listener reaches `.ready`, it advertises via `NWListener.Service`:

| Field | Value |
|---|---|
| Service type | `_http._tcp` |
| Service name | `"hdhrVCR+"` |
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

**HTML/JS injection prevention:**
- All user-derived strings in HTML attributes pass through `he()` (`& < > "` escaped).
- JSON blobs embedded in `<script>` blocks (`var tuners`, `var recsByDev`) pass through `jsEscapeForScript()`, which replaces `<`, `>`, and `&` with `\uXXXX` Unicode escapes to prevent `</script>` tag injection.
- Device filter `onclick` handlers use `this.dataset.dev` (already HTML-escaped) instead of interpolating `DeviceID` into a JS string literal.
- The tuner popover builds its rows via `innerHTML` concatenation using the client-side `hej()` helper to HTML-escape show titles, channel numbers, and tuner names.

**No authentication** — LAN-only tool. Settings warns: *"Local network access only. No authentication. Do not expose this port to the internet."*

---

## HTML escaping

All user-derived strings pass through `he(_ s: String)` (defined in `GuideViewHelpers.swift`) before HTML interpolation. Escapes `& < > "`. JS reads via `el.dataset.*` which auto-decodes, so no double-decoding needed.

JSON blobs embedded inside `<script>…</script>` additionally pass through `jsEscapeForScript()` (defined in `WebServer.swift`), which replaces `<`, `>`, and `&` with their `\uXXXX` JS Unicode escapes (`<`, `>`, `&`). `JSONSerialization` does not escape these characters by default, and browsers treat `</script>` as an end-tag even inside a JS string literal.

Client-side `innerHTML` concatenation (tuner popover rows) uses the page-local `hej(s)` JS helper for the same escaping in the browser.

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
- `send()` writes a single HTTP/1.1 response `Data` packet with `isComplete: true` — this signals NWConnection to send a TCP FIN with the last byte, closing the write side immediately. **Without `isComplete: true`, NWConnection leaves the TCP connection half-open after the data is sent; browsers stall on "Content Download" waiting for a FIN that never arrives.** `conn.cancel()` fires in the send completion block to clean up the read side.
- Normal requests: one full request → one response → cancel. SSE connections: open until client disconnects or `stop()` is called.
- **TCP_NODELAY:** the NWListener is created with `NWProtocolTCP.Options().noDelay = true` to disable Nagle's algorithm, ensuring response bytes are flushed immediately rather than held for coalescing.

**gzip compression:** `accumulate()` parses `Accept-Encoding`; when the client supports gzip and an `.ok` body is ≥ 1400 bytes, `send()` compresses it (`Content-Encoding: gzip` + `Vary: Accept-Encoding`). The guide page shrinks ~1.1 MB → ~160 KB — the dominant cost for LAN Wi-Fi clients. Implementation: libcompression `COMPRESSION_ZLIB` (raw DEFLATE) wrapped in a gzip container (10-byte header + CRC-32/ISIZE trailer, table-based CRC in `WebServer.crc32`). Falls back to uncompressed if compression fails or wouldn't shrink the payload. Already-compressed image responses (channel icons, app icon PNG) are never gzipped. `GET /`'s response is the one exception to "compressed on every request" — see `.okPrecompressed` below.

**`WebResponse` cases:**

| Case | HTTP status | Use |
|---|---|---|
| `.ok(contentType:body:)` | 200 OK | Successful GET or POST; gzip-compressed by `send()` when client supports it and body ≥ 1400 bytes |
| `.okPrecompressed(contentType:raw:gzip:)` | 200 OK | `GET /` only — both the raw and already-gzipped bodies were computed once in `prebuildPageHTML(state:)` (`cachedHTML`/`cachedHTMLGzip`); `send()` just picks one based on `Accept-Encoding` instead of re-running DEFLATE per request |
| `.notFound(String)` | 404 Not Found | Unknown path |
| `.badRequest(String)` | 400 Bad Request | POST with missing required fields |
| `.payloadTooLarge(String)` | 413 Content Too Large | Request body exceeds 128 KB |

---

## Tuner occupancy

`buildHTML()` bakes tuner counts from `state.recordingShows` (active recording count per device) and `device.TunerCount` (total slots). These are always current at render time.

On SSE connect, `pushFreshTunerCounts()` fires immediately: it reads `state.recordingShows` on `@MainActor` and broadcasts a `tuner_update` event. This corrects the baked-in counts for any client that loads the page before a recording starts — the badge updates within milliseconds of SSE connection rather than waiting for the next recording event or idle tick.

`deviceTunerOccupancy` (populated by `fetchDeviceStatus` in the idle loop) is used for the tuner popover detail rows — per-tuner channel and title — not for the badge count.

---

## AppState integration

```swift
let webServer        = WebServer()
@Published var webServerRunning: Bool    = false
@Published var webServerError:   String? = nil

func setupWebServer()   // starts/stops based on config.Web_server_enabled; called at startup and on Settings save
func quit()             // calls webServer.stop()
```

`onAirNow(for:at:)` is shared between `WatchNowView` and `WebServer.buildHTML`.

`addShowFromGuide` and `deleteShow` called by the web handlers are the same functions used throughout the app — no web-specific recording logic.

`broadcastEvent` is called from `AppState` (`addShowFromGuide`) and from `WebServer` handlers (`handleDelete`, `handleEdit`) after state changes.

`broadcastRecordingEvent` is called from `AppState` for `recording_started` and `recording_stopped`. It builds a fresh `#sum-ph` fragment (`buildSumPhHTML`) and the affected device's `#tdrop-{device}` dropdown body (`buildTunerShowsHTML`), embedding them as `sumPh` + `tdrop`/`tdropDev` so clients update those elements without a second HTTP request.

`guide_refreshed` is broadcast from `AppState.refreshGuides()` when at least one device returned guide data; connected clients call `refreshGuide()` to swap the full grid.

---

## Settings (SettingsView — Web Server category)

- **Toggle** — `Web_server_enabled` (default `false`)
- **Port field** — `Web_server_port` (default `1980`; validated 1025–65534; invalid values block Save)
- **Access row** — shown when `state.webServerRunning == true`; LAN IP + port as selectable monospaced text with `Open` link; uses `availableNetworkInterfaces()`, skipping `utun` interfaces. Link uses IP directly (`http://x.x.x.x:port`) to avoid browser HTTPS upgrade of `.local` hostnames.
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

**Expected success:**
```json
{"ok": true, "title": "Local News at 11", "tunerFull": false}
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

---

### Testing a recording without live TV

From CLAUDE.md: set `show_next` to `now + 30 s` and `show_end` to `now + 2 min` in the saved config JSON, then restart the app. The idle loop will pick it up and attempt to start `curl`. Check `show_fail_reason` in the config if it fails; enable verbose curl (Settings → Advanced) to see the raw HTTP exchange with the device.

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
