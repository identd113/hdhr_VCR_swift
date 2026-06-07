# WebServer.swift — Built-in LAN Web Server

Serves an interactive guide page and JSON API over HTTP so any browser on the local network can browse programming and schedule recordings. Enabled via **Settings → Web Server → Enable Web Server**. Default port: **1980**.

The web server is scoped to **scheduling and management** — playback is not supported. There are no streaming routes or media links.

---

## API surface

```swift
func start(port: Int, appState: AppState, onState: @escaping (String?) -> Void)
func stop()
func updateTXTRecord()    // @MainActor — refreshes mDNS TXT record; called from idleLoop
func broadcastEvent(_:)   // pushes a JSON event to all open SSE clients
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
| GET | `/api/shows-html` | HTML fragment for the schedule popover body |
| GET | `/api/tuners.json` | JSON object `{deviceId: {t, a, surl}}` — per-device total/active tuner counts; polled by `refreshTuners()` every 30 s |
| GET | `/api/signal` | JSON object `{guideName: "good"|"fair"|"poor"|"noData"}` — snapshot of `ChannelSignalStore.shared.buckets` keyed by `guideName.lowercased()` |
| POST | `/api/record` | Schedule a recording |
| POST | `/api/signal-scan` | Trigger a signal strength scan. Optional body `{"force":true}` rescans all channels regardless of freshness. Returns `{"status":"started","force":bool}`. |
| POST | `/api/delete` | Remove a managed show and stop any active recording |
| POST | `/api/edit` | Update a managed show's config fields |
| POST | `/api/toggle-favorite` | Toggle the favorite flag for a channel |
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
- **Schedule popover rows** — each `.sp-row` has an `onclick="openEditShow(this)"` handler; `data-*` attrs are embedded by `buildSchedPopHTML`
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
| `recording_started` | `AppState.startRecording` | `channel`, `device` |
| `recording_stopped` | `AppState.stopRecording` | `channel`, `device` |
| `show_added` | `AppState.addShowFromGuide` | `channel`, `device` |
| `show_deleted` | `WebServer.handleDelete` | `channel`, `device` |
| `show_updated` | `WebServer.handleEdit` | `channel`, `device` |
| `favorite_toggled` | `WebServer.handleToggleFavorite` | `device`, `guideNumber` |
| `deviceOffline` | `AppState.probeForNewDevices` (miss #3) | `deviceId` |
| `deviceOnline` | `AppState.probeForNewDevices` (seen after unavailable, or new device) | `deviceId` |
| `signal_update` | `AppState.startSignalScan` | `gname` (guideName.lowercased()), `bucket` (raw string: `"good"` / `"fair"` / `"poor"` / `"noData"`) |

**Client handling:**
```javascript
(function(){
  if(!window.EventSource)return;
  var es=new EventSource('/api/events');
  es.onmessage=function(e){
    try{
      var d=JSON.parse(e.data);
      if(!d||!d.type)return;
      if(d.type==='signal_update'&&d.gname&&d.bucket){
        // inline DOM update — no full refresh needed
        document.querySelectorAll('.g-row[data-gname="'+d.gname+'"]').forEach(function(row){
          // update SVG bars in channel column
        });
      } else {
        refreshGuide();
      }
    }catch(x){}
  };
})();
```
`signal_update` events update the SVG bars on matching `.g-row[data-gname]` elements in-place without triggering a full `refreshGuide()`. All other events trigger `refreshGuide()` — the scroll-preserving partial DOM swap. `EventSource` auto-reconnects after 3 s on drop. `stop()` cancels all SSE connections and clears the registry.

---

## HTML page — visual layout

Self-contained HTML with all CSS inlined. Updates arrive via SSE push events (see below) and targeted DOM swaps after user actions. The page hard-reloads automatically if the server version changes (redeploy detected via 60-second `/api/ping` poll) or if the baked-in 2-hour expiry elapses. Tuner occupancy is fetched server-side on every page load (before HTML is served) via `refreshTunerOccupancy()`.

`refreshGuide()` is called client-side after user actions (record, delete, edit) and on receipt of an SSE event. It updates the guide grid without a page reload:

- **`refreshGuide(selOverride?)`** — saves `.gw` scroll position and the currently-selected `.g-prog` element (`data-start` + `data-num` + `data-device`); `GET /` → DOMParser → swaps `.gi` (guide grid), `#sum-ph` (summary placeholder), `#sched-pop-body` (schedule popover); restores scroll position; re-selects the previously-highlighted entry via `showInfo()`. If `selOverride` is passed (a JS object), its key-value pairs are merged into the re-selected block's `dataset` before `showInfo()` runs — used after a Record action to inject `{recording:'1', managed:'1'}` so the summary panel shows the correct state without requiring a manual re-select.

**Dark theme:** body `#141414` · channel column `#1a1a1a` · default program block `#2c2c2c / #484848 border`.

Page structure (top to bottom):

1. **Page header** — `h1` title + `≡` status toggle button + tuner badge / device link (single device) or device switcher bar (multiple devices)
2. **Tuner popover** (`#t-pop`) — fixed overlay; shown by clicking a tuner badge
3. **Summary panel** (`#sum`) — always visible; selected show details + actions
4. **Record type modal** (`#rec-modal`) — fixed overlay; appears on Record click
5. **Edit modal** (`#edit-modal`) — fixed overlay (z-index 201); appears on Edit click or schedule-popover row click
6. **Schedule popover** (`#sched-pop`) — fixed overlay; opened by clicking the `≡` button in the header. Contains: Recording / Up Next / Scheduled sections (`.sp-*` classes).
7. **Guide grid** — scrollable cable-guide grid (width/time-window depends on UA; see below)

**`≡` status button** (`#status-btn`): `background:none` button placed **to the left of the `<h1>` title** in the upper-left header area. Clicking calls `openSchedPop(this)` which toggles `#sched-pop` (positioned below the button). Calls `closeSchedPop()` on second click or backdrop click. Button color shifts from `var(--t4)` (muted) to `var(--ac)` (accent) when the popover is open.

**Auto-select on load**: after `setDev('')` initializes the guide, an IIFE finds the first visible `.g-row` and selects the currently-airing `.g-prog` on that row, populating the summary panel immediately without requiring a click.

---

### Device switcher bar / header

**Single device:** `≡` button + column containing `h1` title on the first line, then tuner badge + device web UI link (`http://{LocalIP}/`) on a second line below the title.

**Multiple devices:** `h1` on its own line, then `#dev-bar` with one column group per device:
- **Row 1** of each group: **HDHR-XXXXXXXX** filter button (`.d-btn`) + **↗** link to device web UI
- **Row 2** of each group: tuner badge (`.t-info`) below the device name

Each device group uses `display:inline-flex; flex-direction:column` so name and badge stack vertically. `#dev-bar` uses `align-items:flex-start` so groups of different heights don't stretch.

Clicking a device button calls `setDev(devId)` which filters guide rows to that device via `data-dev` attributes.

**Tuner badges** (`.t-info` / `.t-info-full`): show `active/total` slots. Red styling when full. Clicking opens the tuner popover.

---

### Tuner popover (`#t-pop`)

Fixed overlay (z-index 200). Positioned below the clicked tuner badge. Shows:
- **Header** — `active/total tuners` (+ `— FULL` when all occupied)
- **Per-active-tuner rows** — tuner slot name · channel number + channel name · show title
- **`status.json ↗`** link — opens `http://{LocalIP}/status.json` in a new tab

Active tuner detection: `DeviceTunerInfo` entries where `VctNumber != nil`. Idle slots (returned by the device with only `"Resource"` present) are not counted. The occupancy is refreshed from `/status.json` on every `GET /` request (cache-bypassed with `cachePolicy: .reloadIgnoringLocalCacheData`).

---

### Summary panel (`#sum`)

Always rendered above the guide grid. Two states:

**Placeholder** (`#sum-ph`): "Select a show from the guide" — on load and after close.

**Selected** (`#sum-c`): appears when the user clicks a program block. Layout (left to right):
- **Poster image** — hidden if no `ImageURL`. Default: 72 px wide, `object-fit: contain`. Tablet (≤ 960 px): 56 px. Desktop (≥ 961 px): 260 px, `align-self: center`. On load failure, falls back to the channel logo; if that also fails, hides entirely. The `onerror` handler is set in JS each time `showInfo()` populates the panel (not as an inline HTML attribute) so the fallback chain re-arms on every selection.
- **Info column** (flex: 1):
  - Title (bold, 0.92 rem, ellipsis)
  - Genre badge (uppercase pill) — hidden if absent or `"Series"`
  - Episode info — hidden if absent
  - Original airdate — hidden if absent
  - Synopsis (2-line `-webkit-line-clamp`) — hidden if absent
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
- Schedule popover body is refreshed via `/api/shows-html`.

---

### Guide grid

A cable-TV-style horizontal time grid. Window width depends on the requesting client's User-Agent:

| Client | Window | Default (GuideHours = 24) |
|---|---|---|
| Desktop (Macintosh / Windows / Linux UA) | `GuideHours` hours | 24 h |
| Mobile (iPhone / iPad / Android UA) | `GuideHours / 2` hours | 12 h |

`isDesktopUA(_ ua: String)` (private helper) classifies the UA server-side. Modern iPads in desktop-browsing mode report `"Macintosh"` and receive the wider window.

**Window start:** `winStart = (nowTs / 1800) * 1800 - 1800` — floors to the nearest 30-minute boundary then subtracts one slot, giving a 30–60 minute lookback. `GuideStore.entries()` is called with `after: Date(winStart)` (not the default `after: Date()`) so shows that already ended but fall within the lookback are included. Gap periods with no guide data render as `.g-gap` divs (fully opaque `var(--bg)`) so the striped `.g-tl` background never shows through. On page load, a JS IIFE scrolls the guide so the now-line sits ~25% from the left of the visible viewport.

**Live now-line:** `_winStart` and `_winSec` are baked into the page JS at render time. `nowPct()` recomputes the now-line position as `(Date.now()/1000 - _winStart) / _winSec * 100`, clamped to [0, 100]. `updateNowLine()` updates the `left` style on all `.g-now-bar` and `.g-now-tick` elements every **5 minutes** via `setInterval`. It also auto-scrolls the guide if the now-line has drifted past **75%** of the viewport width, nudging it back to the 25% position — without disturbing users who have manually scrolled ahead (their now-line is near the left edge, well below the threshold).

**Page staleness:** two guards run every 60 seconds via `checkFreshness()`: (1) if `Date.now()` exceeds the baked-in `_exp` timestamp (render time + 2 hours), the page hard-reloads; (2) `/api/ping` is fetched and its `version` field compared to the baked-in `_ver` — mismatch means a redeploy has occurred, triggering `location.reload()`. The version check catches redeployments within 60 seconds; the `_exp` expiry handles long-open stale tabs.

`div.gi` `min-width` = `max(1200, winSec / 1800 * 100)` px — scales up for wider windows so program blocks never compress below a readable width.

**Layout:**
- `div.gw` — scroll container (`overflow: auto; max-height: 60vh`)
- `div.gi` — inner, `min-width` scales with window (see above)
- Sticky time-header (`top: 0; z-index: 10`)
- Sticky channel column (`left: 0; z-index: 2`) — both data rows (`.g-ch`) and the header cell (`.g-hdr-ch`) are **105 px** wide. They must match so the `nowPct%` left offset maps to the same pixel position in both the time header and program rows.
- Corner cell `z-index: 11`

**Rows:** one row per (device × channel). Cross-device deduplication is handled client-side by `setDev('')` on page load — it hides duplicate `GuideNumber` rows keeping the first-device occurrence, giving a clean "All" view.

Each `.g-row` carries `data-dev`, `data-ch`, `data-gname` (`GuideName.lowercased()`), and `data-fav` (`"1"` for favorite channels, absent otherwise). `data-gname` is the key used by `signal_update` SSE events; `data-fav` is used by `setDev` to show/hide `.g-fav-sep` headers.

**Favorites section:** favorite channels are sorted to the top of each device's channel list server-side. A `.g-fav-sep` separator row (amber `★ FAVORITES` label, `display:flex`) is inserted above the first favorite row per device and hidden via `setDev` when no visible favorite rows remain (e.g. genre filter active). Favorite channel rows get a golden background tint via `color-mix(in srgb, var(--fav) 16%, var(--s1))` on `.g-ch` and a repeating gradient tint on `.g-tl`. A `☆`/`★` toggle button (`.g-fav-btn`) in each channel cell calls `toggleFav(evt, btn)` to POST `/api/toggle-favorite`.

**Signal bars in channel column:** when `state.config.Signal_quality_enabled` and signal data exists for a channel, a 3-bar SVG (`class="g-sig"`, `viewBox="0 0 11 10"`, `width/height=10`) is baked into the `.g-ch` cell at page build time. Buckets map to fill levels: `good` → all 3 bars, `fair` → 2 bars, `poor` → 1 bar, `noData` → no SVG emitted. The `title` attribute carries `"Signal: {bucket}"` for hover. Bars are updated in-place on `signal_update` SSE events without a page reload.

**`setDev()` and DOM caching**: `.g-row` NodeList is cached into `_rows` at page load and reused on every device switch — avoids repeated `querySelectorAll` calls. When `setDev(id)` is called with a **different** device ID than `curDev`, `_genreFilter` is reset to `''` and the `<select id="genre-sel">` is reset to the blank option — a stale genre filter from the previous device would otherwise leave the guide empty if the new device has no matching genre.

**Time header:** one tick per clock hour, aligned to hour boundaries via `stride(from: firstHour, through: winEnd, by: 3600)` where `firstHour = ((winStart + 3599) / 3600) * 3600`. Label uses `DateFormatter` template `"j"` (locale-preferred hour, e.g. `"8 PM"` or `"20"`). + red "now" bar.

**Vertical gridlines:** CSS `repeating-linear-gradient` at every **8.3333%** of the timeline element width. Since the timeline spans `winSec` seconds, each gridline represents `winSec × 0.08333 / 60` minutes — 60 min for the mobile 12 h window, 120 min for the desktop 24 h window.

**Program block color coding:**

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

State classes (rec / now / sched) take precedence over genre. `.g-prog-now.gg-*` two-class selectors override the grey fallback with genre-tinted now-playing colors (e.g. `.g-prog-now.gg-drama` → `hsl(216,52%,44%)`). `.g-prog-sched.gg-*` selectors apply the same genre hue families to scheduled-show blocks — slightly darker/more saturated in dark mode, lighter tints in light mode — so a scheduled Drama block is clearly distinct from both the default blue `.g-prog-sched` and an unscheduled current-program block. `.g-prog.g-sel` adds white border + glow.

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

`findManagedShow` matches by SeriesID first, then series title, then exact title+channel.

---

### Schedule popover (`#sched-pop`)

Fixed overlay opened by the `≡` button. Built server-side by `buildSchedPopHTML(state:)` and refreshed via `/api/shows-html` after record/delete actions.

Four sections (`.sp-sec`) separated by `.sp-div` dividers — empty sections are omitted. Shows on unavailable devices are excluded from the first three sections and appear only in the fourth:
- **Recording** — `state.recordingShows` on available devices; title in red `●` prefix (`.sp-rec`); channel cell appends **"· Ends 10:00 PM"** (`state.shortTime(show.show_end)`) so the expected stop time is visible at a glance.
- **Up Next** — first `state.activeShows` entry (available devices only) sorted by `show_next` ascending; shows relative time in accent color
- **Scheduled** — remaining `state.activeShows` (available devices only)
- **Unavailable Tuner** — all active shows whose assigned device is currently unavailable (`state.unavailableDeviceShows`); header in red; `⚠` prefix on each row

Content is embedded at page build time; `refreshShowsSection()` fetches `/api/shows-html` on record/delete to update `#sched-pop-body` in place.

---

## JavaScript — key functions

| Function | Purpose |
|---|---|
| `showInfo(el)` | `onclick` on program blocks; reads `el.dataset`, populates summary panel, sets globals |
| `closeSummary()` | Hides summary, restores placeholder, clears `.g-sel` |
| `refreshGuide(selOverride?)` | Partial DOM refresh: saves `.gw` scroll + selected entry; `GET /`; swaps `.gi`, `#sum-ph`, `#sched-pop-body`; restores scroll; re-selects prior entry. Optional `selOverride` object patches `dataset` attrs on the re-selected block before `showInfo()` — used after Record to inject `{recording:'1',managed:'1'}` without a manual re-click. |
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
| `setDev(id)` | Filters guide rows by `data-dev`; empty string = All (with JS dedup); uses cached `_rows` NodeList; shows/hides `.g-fav-sep` separators based on whether any visible favorite rows remain for each device |
| `toggleFav(evt, btn)` | `onclick` on `.g-fav-btn` star buttons; reads `data-dev` / `data-ch` from parent `.g-row`; POSTs `/api/toggle-favorite`; calls `refreshGuide()` on success |
| `openSchedPop(anchor)` | Opens `#sched-pop` anchored below the button; toggles closed on second click |
| `closeSchedPop()` | Hides `#sched-pop`; resets `#status-btn` color and `aria-expanded` |
| `devFull(devId)` | Returns true if `tuners[devId].a >= tuners[devId].t` |
| `showTunerInfo(devId, anchor)` | Opens tuner popover anchored below the clicked badge |
| `closeTunerPop()` | Hides tuner popover |
| `gc(genre)` | Maps genre → HSL background for summary panel |
| `ft(date)` | Formats Date as `"H:MM AM/PM"` |
| `so(id, val)` | Shows element with textContent, or hides if falsy |
| `hej(s)` | HTML-escapes a string for safe `innerHTML` concatenation (`&`, `<`, `>`) — used in the tuner popover where values come from server-side data |

**Globals:** `_d` (deviceId), `_n` (guideNumber), `_s` (startTime), `_e` (endTime), `_ser` (SeriesID), `_genre` (first genre string), `curDev` (active device filter) — set by `showInfo`, consumed by `doRecord`/`doDelete`/`confirmRecord`. `_genre` is used by `doRecord()` to pre-check Bonus Time for sports entries.

**Embedded JS data:**
- `var tuners` — `{deviceId: {t: total, a: active, surl: "http://ip/status.json"}, …}` — tuner counts from fresh `/status.json` fetch
- `var recsByDev` — `{deviceId: [{tuner, title, ch, chname}, …], …}` — active recording detail for popover

Both variables are serialised via `JSONSerialization` (not string interpolation) and passed through `jsEscapeForScript()` before embedding in the `<script>` block. This replaces `<`, `>`, and `&` with `\uXXXX` escapes so a show title or device ID containing `</script>` cannot terminate the script element. Device filter buttons use `onclick="setDev(this.dataset.dev)"` / `onclick="showTunerInfo(this.dataset.dev,this)"` — the DeviceID is read from the already-HTML-escaped `data-dev` attribute rather than interpolated into a JS string literal.

---

## JSON schema — `/api/tuners.json`

Object keyed by device ID. Used by `refreshTuners()` to update tuner badges without a page reload.

```json
{
  "105404BE": { "t": 2, "a": 1, "surl": "http://192.168.1.x/status.json" }
}
```

| Key | Type | Meaning |
|---|---|---|
| `t` | Int | Total tuner count (`TunerCount` from device) |
| `a` | Int | Active (in-use) tuners — slots where `VctNumber != nil` in `deviceTunerOccupancy` |
| `surl` | String | `http://{LocalIP}/status.json` for the device detail link in the tuner popover |

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
- `send()` writes a single HTTP/1.1 response `Data` packet; `conn.cancel()` fires in the completion block.
- Normal requests: one full request → one response → cancel. SSE connections: open until client disconnects or `stop()` is called.

**`WebResponse` cases:**

| Case | HTTP status | Use |
|---|---|---|
| `.ok(contentType:body:)` | 200 OK | Successful GET or POST |
| `.notFound(String)` | 404 Not Found | Unknown path |
| `.badRequest(String)` | 400 Bad Request | POST with missing required fields |
| `.payloadTooLarge(String)` | 413 Content Too Large | Request body exceeds 128 KB |

---

## Tuner occupancy

Before building the HTML page, `refreshTunerOccupancy()` fetches `/status.json` from each device concurrently using `URLRequest(cachePolicy: .reloadIgnoringLocalCacheData)` + `Cache-Control: no-cache`. Results are stored in `state.deviceTunerOccupancy`.

Active tuner count = entries where `VctNumber != nil`. The device always returns all tuner slots in the JSON array; idle slots have only `"Resource"` with no other fields.

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

`broadcastEvent` is called from `AppState` (`startRecording`, `stopRecording`, `addShowFromGuide`) and from `WebServer` handlers (`handleDelete`, `handleEdit`) after state changes. Connected SSE clients receive the event and call `refreshGuide()` in place.

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

Key log prefixes: `[WebServer] Listening`, `[WebServer] mDNS registered`, `[WebServer] refreshTunerOccupancy`, `[WebServer] buildHTML tuners`, `[WebServer] Rejected non-LAN`.
