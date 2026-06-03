# WebServer.swift — Built-in LAN Web Server

Serves an interactive guide page and JSON API over HTTP so any browser on the local network can browse programming and schedule recordings. Enabled via **Settings → Web Server → Enable Web Server**. Default port: **1980**.

The web server is scoped to **scheduling and management** — playback is not supported. There are no streaming routes or media links.

---

## API surface

```swift
func start(port: Int, appState: AppState, onState: @escaping (String?) -> Void)
func stop()
func updateTXTRecord()   // @MainActor — refreshes mDNS TXT record; called from idleLoop
```

`onState` is called on `DispatchQueue.main`. `nil` = server is ready; non-nil = error string.

`stop()` nils the internal `stateCallback` before cancelling the listener so the `.cancelled` state handler does not surface as an error when stopping intentionally.

---

## Routes

| Method | Path | Response |
|---|---|---|
| GET | `/` or `/index.html` | Full guide HTML page |
| GET | `/api/now.json` | JSON array of on-air entries (see schema below) |
| GET | `/api/shows-html` | HTML fragment for the shows section; polled by the page's JS every 30 s to refresh recording/scheduled/paused tables without a full reload |
| POST | `/api/record` | Schedule a recording |
| POST | `/api/delete` | Remove a managed show and stop any active recording |
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
  "showType":    "single"
}
```

| Field | Required | Values |
|---|---|---|
| `deviceId` | yes | HDHomeRun device ID |
| `guideNumber` | yes | Channel number string (e.g. `"5.1"`) |
| `startTime` | yes | Unix timestamp — locates the exact `GuideEntry` via `guideStore.entries(after: .distantPast)` |
| `endTime` | no | Unused server-side |
| `showType` | no | `"single"` (default) · `"dateTime"` · `"seriesChannel"` · `"seriesAll"` |

`showType` maps to `ShowState`:

| Value | ShowState | Behaviour |
|---|---|---|
| `"single"` | `.single` | Record this airing only |
| `"dateTime"` | `.dateTime` | Record at this time/day every week |
| `"seriesChannel"` | `.seriesChannel` | Record new episodes via SeriesID on this channel |
| `"seriesAll"` | `.seriesAll` | Record new episodes via SeriesID on any channel |

**Success:** `{"ok": true, "title": "Show Title", "tunerFull": false}`  
`tunerFull: true` means all tuners were occupied at schedule time — the show is queued and will record when a tuner is free.  
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

## HTML page — visual layout

Self-contained HTML with all CSS inlined. Auto-refreshes every 60 seconds via `<meta http-equiv="refresh" content="60">`.

**Dark theme:** body `#141414` · channel column `#1a1a1a` · default program block `#2c2c2c / #484848 border`.

Page structure (top to bottom):

1. **Page header** — `h1` title + `≡` status toggle button + tuner badge / device link (single device) or device switcher bar (multiple devices)
2. **Tuner popover** (`#t-pop`) — fixed overlay; shown by clicking a tuner badge
3. **Summary panel** (`#sum`) — always visible; selected show details + actions
4. **Record type modal** (`#rec-modal`) — fixed overlay; appears on Record click
5. **Schedule popover** (`#sched-pop`) — fixed overlay; opened by clicking the `≡` button in the header. Contains: Recording / Up Next / Scheduled sections (`.sp-*` classes).
6. **Guide grid** — scrollable cable-guide grid (width/time-window depends on UA; see below)

**`≡` status button** (`#status-btn`): `background:none` button next to the h1. Clicking calls `openSchedPop(this)` which toggles `#sched-pop` (positioned below the button). Calls `closeSchedPop()` on second click or backdrop click. Button color shifts from `var(--t4)` (muted) to `var(--ac)` (accent) when the popover is open.

**Auto-select on load**: after `setDev('')` initializes the guide, an IIFE finds the first visible `.g-row` and selects the currently-airing `.g-prog` on that row, populating the summary panel immediately without requiring a click.

---

### Device switcher bar / header

**Single device:** `h1` title + `≡` status toggle button + tuner badge + device web UI link (`http://{LocalIP}/`) inline.

**Multiple devices:** `h1` on its own line, then `#dev-bar` with:
- **All Tuners** button (`.d-btn.d-sel` when active) — shows all channels, deduplicates by `GuideNumber` (first-device-wins) via JS
- Per device: **HDHR-XXXXXXXX** filter button (`.d-btn`) + **↗** link to device web UI + tuner badge

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
- **Poster image** (120 px wide, `object-fit: cover`) — hidden if no `ImageURL`
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
| `data-managed="1"` | Italic "★ Already scheduled" note + grey "Remove" button |
| Neither | Red "Record" button (amber "⚠ Record (tuner full)" when device is full and show is live) |

**Actions are applied in-place** — no page reload on record or delete. On record success, the selected block gains `.g-prog-sched` + ★ badge and the action row swaps to Scheduled+Remove. On delete success, the block loses its badge/color and the Record button reappears.

---

### Record type modal (`#rec-modal`)

`position: fixed` overlay (z-index 100). Appears when Record is clicked.

**Contents:**
- Show title + channel/time (copied from summary)
- Four radio options (`recOpts`): Single episode · Weekly repeat · Series — this channel · Series — any channel
- **SeriesID row** (`#rm-sid`) — appears when a series type is selected
- **Tuner-full warning** (`#rm-tuner`) — amber banner shown when device is full and show is currently airing
- Cancel / Schedule buttons

On **Schedule**: `confirmRecord()` POSTs to `/api/record`. On success, the guide block and summary panel are updated in-place (no page reload). If `tunerFull` is true in the response, the note reads "⚠ Queued — all tuners busy".

---

### Guide grid

A cable-TV-style horizontal time grid. Window width depends on the requesting client's User-Agent:

| Client | Window | Default (GuideHours = 24) |
|---|---|---|
| Desktop (Macintosh / Windows / Linux UA) | `GuideHours / 2` hours | 12 h |
| Mobile (iPhone / iPad / Android UA) | `GuideHours / 4` hours | 6 h |

`isDesktopUA(_ ua: String)` (private helper) classifies the UA server-side. Modern iPads in desktop-browsing mode report `"Macintosh"` and receive the wider window. Window always starts at the previous 30-minute boundary (`winStart = (nowTs / 1800) * 1800`).

`div.gi` `min-width` = `max(1200, winSec / 1800 * 100)` px — scales up for wider windows so program blocks never compress below a readable width.

**Layout:**
- `div.gw` — scroll container (`overflow: auto; max-height: 60vh`)
- `div.gi` — inner, `min-width` scales with window (see above)
- Sticky time-header (`top: 0; z-index: 10`)
- Sticky channel column (`left: 0; z-index: 2`) — 130 px wide
- Corner cell `z-index: 11`

**Rows:** one row per (device × channel). Cross-device deduplication is handled client-side by `setDev('')` on page load — it hides duplicate `GuideNumber` rows keeping the first-device occurrence, giving a clean "All" view.

Each `.g-row` carries `data-dev` and `data-ch` for device filtering.

**`setDev()` and DOM caching**: `.g-row` NodeList is cached into `_rows` at page load and reused on every device switch — avoids repeated `querySelectorAll` calls.

**Time header:** 7 ticks at `winSec/6` intervals (e.g. 2 h apart for a 12 h window, 1 h apart for 6 h) + red "now" bar.

**Vertical gridlines:** CSS `repeating-linear-gradient` at every **8.3333%** of the timeline element width. Since the timeline spans `winSec` seconds, each gridline represents `winSec × 0.08333 / 60` minutes — 30 min for the mobile 6 h window, 60 min for the desktop 12 h window.

**Program block color coding:**

| Class | Condition | Background | Border |
|---|---|---|---|
| `.g-prog-rec` | Currently recording | `#3c1818` | `#c03030` (red) |
| `.g-prog-now` | On air, not recording | `#1c3820` | `#3a6a40` (green) |
| `.g-prog-sched` | Managed/scheduled | `#1a1a40` | `#4848c8` (blue) |
| `.gg-drama` | Drama | `hsl(216,50%,26%)` | — |
| `.gg-comedy` | Comedy | `hsl(47,55%,26%)` | — |
| `.gg-news` | News | `hsl(342,50%,24%)` | — |
| `.gg-sports` | Sports | `hsl(119,55%,21%)` | — |
| `.gg-reality` | Reality | `hsl(25,55%,24%)` | — |
| `.gg-movie` | Movie | `hsl(270,45%,26%)` | — |
| `.gg-talk` | Talk | `hsl(173,50%,21%)` | — |
| `.gg-children` | Children | `hsl(202,45%,24%)` | — |
| `.g-prog` (default) | No match | `#2c2c2c` | `#484848` |

State classes (rec / now / sched) take precedence over genre. `.g-prog.g-sel` adds white border + glow.

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

**★ badge logic (managed shows):** three separate sets are pre-computed from `activeMgd` (active, non-paused shows only):
- `mgdSID` — SeriesIDs of `seriesChannel`/`seriesAll` shows only (`isSeries == true`); `dateTime` shows are excluded even if they have a stored `show_seriesid`
- `mgdTitSeries` — titles of series shows without a SeriesID
- `mgdDateTimeCh` — `"title|channel"` pairs for `dateTime` shows; only badges that exact channel, not every airing everywhere

This prevents a `dateTime` show's stored SeriesID from falsely starring unrelated guide entries sharing that ID. Paused shows are excluded from all three sets — the same exclusion applies in `/api/now.json`'s `isScheduled` field so the two badge paths agree.

**● Recording badge:** `isRecCh` is now scoped to the current device (`recChannelsByDevice[device.DeviceID]`). In a multi-device setup, a recording on device A no longer marks the same channel number on device B as Recording.

---

### Schedule popover (`#sched-pop`)

Fixed overlay opened by the `≡` button. Built server-side by `buildSchedPopHTML(state:)` and refreshed via `/api/shows-html` after record/delete actions.

Three sections (`.sp-sec`) separated by `.sp-div` dividers — empty sections are omitted:
- **Recording** — `state.recordingShows`; title in red `●` prefix (`.sp-rec`)
- **Up Next** — first `state.activeShows` entry sorted by `show_next` ascending; shows relative time in accent color
- **Scheduled** — remaining `state.activeShows`

Content is embedded at page build time; `refreshShowsSection()` fetches `/api/shows-html` on record/delete to update `#sched-pop-body` in place.

---

## JavaScript — key functions

| Function | Purpose |
|---|---|
| `showInfo(el)` | `onclick` on program blocks; reads `el.dataset`, populates summary panel, sets globals |
| `closeSummary()` | Hides summary, restores placeholder, clears `.g-sel` |
| `doRecord()` | Opens record modal; shows tuner-full warning if applicable |
| `cancelRecord()` | Hides modal |
| `confirmRecord()` | POSTs `/api/record`; updates block + summary in-place on success |
| `doDelete()` | POSTs `/api/delete`; removes badge/color from block, restores Record button |
| `setDev(id)` | Filters guide rows by `data-dev`; empty string = All (with JS dedup); uses cached `_rows` NodeList |
| `openSchedPop(anchor)` | Opens `#sched-pop` anchored below the button; toggles closed on second click |
| `closeSchedPop()` | Hides `#sched-pop`; resets `#status-btn` color and `aria-expanded` |
| `devFull(devId)` | Returns true if `tuners[devId].a >= tuners[devId].t` |
| `showTunerInfo(devId, anchor)` | Opens tuner popover anchored below the clicked badge |
| `closeTunerPop()` | Hides tuner popover |
| `gc(genre)` | Maps genre → HSL background for summary panel |
| `ft(date)` | Formats Date as `"H:MM AM/PM"` |
| `so(id, val)` | Shows element with textContent, or hides if falsy |
| `hej(s)` | HTML-escapes a string for safe `innerHTML` concatenation (`&`, `<`, `>`) — used in the tuner popover where values come from server-side data |

**Globals:** `_d` (deviceId), `_n` (guideNumber), `_s` (startTime), `_e` (endTime), `_ser` (SeriesID), `curDev` (active device filter) — set by `showInfo`, consumed by `doRecord`/`doDelete`/`confirmRecord`.

**Embedded JS data:**
- `var tuners` — `{deviceId: {t: total, a: active, surl: "http://ip/status.json"}, …}` — tuner counts from fresh `/status.json` fetch
- `var recsByDev` — `{deviceId: [{tuner, title, ch, chname}, …], …}` — active recording detail for popover

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
- After assembly: method + path parsed from request line, body extracted, a `Task` hops to `@MainActor`, response built, `send()` called from network queue.
- `send()` writes a single HTTP/1.1 response `Data` packet; `conn.cancel()` fires in the completion block.
- One full request → one response → cancel. No persistent connections or pipelining.

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
