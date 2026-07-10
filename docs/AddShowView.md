# AddShowView.swift — Add Show Wizard

## Visual Appearance

### Overall window
Fixed **560×540** for steps 1 and 3; expands to resizable **min 1100×720** for the guide step. The window animates between sizes with a 0.2s ease-in-out. Escape closes the window from any step.

**Top of window (all steps)**: 2 small 8pt circles in a row, left-padded under the top edge — progress indicator. Filled accent-color circle = current step; hollow gray circle = other step. `guide` and `details` steps only — `ForEach([Step.guide, .details])` always produces exactly 2 dots. Below the circles: a `Divider`.

### Step 1 — Device selection (usually auto-skipped)
White background. Title `"Select Tuner"` in `.title2` left-padded, with a `"Refresh"` labeled button (↺ icon) at the right.

If no devices: centered `ContentUnavailableView` — `wifi.slash` SF Symbol, `"No tuners found"` title, description text.

If devices present: macOS `List` with rows, each row:
- `antenna.radiowaves.left.and.right` SF Symbol icon (decorative, hidden from VoiceOver)
- **DeviceID** in bold on the left
- `"Recording N"` in red bold caption on the right (if recording)
- Below: `"192.168.1.x · 4 tuners · 106 channels · fw 20240101"` in caption secondary color
- Selected row highlighted in system accent color

Nav bar (bottom): **Next** button (`.borderedProminent`) enabled when a device is selected.

### Step 2 — Guide (web guide)
A `WKWebView` (`AddShowWebView`) loading `http://localhost:{port}/`. The web guide is the same interface served to LAN browsers. Clicking **Record** in the web guide's summary panel posts a `WKScriptMessage` (`"record"` handler) with entry data, which advances the wizard to step 3. The nav bar is hidden on this step; navigation happens via the Record button in the web guide.

If the web server is not yet running, a `ProgressView("Starting guide…")` is shown until it becomes ready.

### Step 3 — Details
Fixed 560×540 window. White/system background. `ScrollView` containing a `VStack` with 16pt spacing.

- Orange warning banner if `show.show_url` is empty — lineup may not have loaded yet.
- Form fields using `ShowFormSection` (shared with `EditShowView`)
- **Other Upcoming Airings** panel (below the form, only when `seriesType.isSeries` — i.e. SeriesID(Channel) or SeriesID(All) — and results are non-empty): other future airings of the same `show_seriesid`, excluding the airing just selected in Step 2. Each row is one compact line: time (`upcomingFormatter`) · channel name · episode info (`GuideEntry.episodeInfoLabel`, e.g. "S01E13 · Episode Name") if the guide has it — no show title (redundant, the whole panel is about one series). Backed by `AppState.upcomingGuideEpisodes(seriesID:)` — bounded by the guide's ~29h-per-device window and a 4-row cap, so it's a best-effort preview, not an exhaustive schedule. Hidden entirely (no placeholder) for Single/DateTime shows, when `show_seriesid` is empty, or when no other airings are found. Mirrored on the web guide's Record modal via `GET /api/airings/{seriesId}` — see `docs/WebServer.md`'s "Record type modal" section — keep the two in sync.
- Bottom-right: orange `StarburstBadge` (115pt size) floats via `.overlay(alignment: .bottomTrailing)`, springs in on appear if `show_bonus_time == true` and `Sports_padding_enabled`. Sports entries have Bonus Time pre-checked; any show type can enable it.

**Nav bar** (bottom): **Back** on left, **Record** (`.borderedProminent`, tinted `recordRed` — same red as the web guide's Record button, `#c0392b`, see `GuideViewHelpers.swift`) on right. A `Divider` above.

## Intent

`AddShowView` is a 3-step wizard window for adding a new recording schedule. Steps: tuner selection → web guide browsing → recording details.

Window size: **560×540** for steps 1 and 3; **resizable** (min 1100×720, ideal 1280×820) for step 2. The guide step window can be expanded — the web guide fills the available width.

---

## Steps

```
enum Step { case device, guide, details }
```

A progress indicator (2 dots, filled vs hollow) tracks position across the `guide` and `details` steps. The guide step hides the nav bar entirely; navigation is via the Record button in the web guide summary panel. **Escape key** dismisses the window from any step (`.onExitCommand { dismiss() }`).

### Step 1 — Device

Shows a `List` of `state.devices` with expanded device info:
- **DeviceID** + active recording count (red when > 0)
- **IP · N tuners · M channels · fw YYYYMMDD** (firmware shown if non-nil)

Tapping a row sets `selectedDevice`. **Double-tapping** sets `selectedDevice` and immediately advances to step 2. The "Next" button also advances when `selectedDevice != nil`.

**Single-device skip**: `.onAppear` auto-selects the only device and jumps to step 2 immediately, so single-tuner setups never see the device list.

A **Refresh** button runs `state.discoverDevices()` in a `Task`.

### Step 2 — Guide

`AddShowWebView: NSViewRepresentable` wraps a `WKWebView` loaded with `http://localhost:{port}/`. A `WKScriptMessageHandler` named `"record"` is registered; when the user clicks Record in the web summary panel, JS posts the entry data to this handler. The coordinator calls `onRecord([String: Any])` on the main queue.

`onRecord` in `guideStep` calls `applyWebGuideEntry(...)`, which populates all `show` fields and sets `selectedDevice`, then sets `step = .details`.

**Web server lifecycle**: managed at the wizard root, not the guide step. `ensureWebServerRunning()` is called in the root `.onAppear` (only when the guide step will be shown — skipped for the `pendingAddEntry` path that goes directly to details). `releaseInternalWebServer()` is called in root `.onDisappear`. This means stepping from guide → details → Back does not stop and restart the server, and the user never sees a "Starting guide…" flash on Back navigation.

**Lineup pre-load**: the `guideStep` Group has a `.task` that calls `state.ensureLineupLoaded(for:)` when it appears. This ensures `state.lineups[deviceId]` is populated before the user can click Record — so `applyWebGuideEntry`'s lineup lookup always finds a URL rather than returning `""`.

**Re-open while open**: `.onChange(of: state.pendingAddEntryGeneration)` and `.onChange(of: state.pendingAddChannelGeneration)` on the root body handle the case where the user opens the Add Show wizard from WatchNow or the menu while the wizard is already on the guide step. The new pending entry is applied immediately without requiring the wizard to close and reopen.

External navigation is blocked — the `WKNavigationDelegate` only allows `localhost` URLs.

Dark/light theme is synced via JS in `webView(_:didFinish:)`.

`dismantleNSView` removes the `"record"` message handler to prevent a retain cycle.

### Step 3 — Details

`ScrollView` containing the form fields, with a `StarburstBadge` floating at the bottom-right via `.overlay(alignment: .bottomTrailing)` on the outer `Group { switch step }` — outside and above the `ScrollView`.

Form fields:
- **Title** — `TextField` pre-populated from the web guide entry
- **Type** — segmented `Picker` for `ShowState.allCases`
- **Days** — weekday toggle buttons (shown for `.single` and `.dateTime`). Single enforces single-day selection; dateTime allows any combination
- **Transcode** — `Picker`: None / Heavy / Mobile / Internet 720
- **Folder** — display + Choose… button; writes to `UserDefaults["defaultSaveDirectory"]`

**Bonus Time starburst**: when `show.show_bonus_time == true && state.config.Sports_padding_enabled`, a `StarburstBadge` floats at the bottom-right corner showing "+N min". Sports entries auto-enable Bonus Time.

`canAdvance` for details step: `!show.show_title.isEmpty && recordFolder != nil && !show.show_url.isEmpty`.

---

## `applyWebGuideEntry()`

Called when the web guide posts a `"record"` message. Populates `show` from the message payload:

```swift
show.show_title      = title
show.show_channel    = guideNumber
show.show_length     = (endTime - startTime) / 60
show.show_next       = startDate
show.show_end        = endDate
show.show_seriesid   = seriesId
show.show_logo_url   = imageURL
show.show_genre      = genre
show.show_bonus_time = genre.lowercased().contains("sports") && state.config.Sports_padding_enabled
show.hdhr_record     = deviceId
// stream URL resolved from lineup:
show.show_url = state.lineups[deviceId]?.first(where: { $0.GuideNumber == guideNumber })?.URL ?? ""
```

`selectedDevice` is set to the matching device (so `save()` can call `resolveSeriesAir` with the correct device). Air day is pre-populated from the guide entry's local weekday. Series type always resets to `.single`.

---

## `applyPendingEntry()`

Called from `.onAppear` when `state.pendingAddEntry` is set, **or** from the root `.onChange(of: state.pendingAddEntryGeneration)` when it fires while the wizard is already open. Inlines field population from the pending tuple, bypassing the web guide step entirely and jumping directly to step 3:

```swift
show.show_title    = entry.Title
show.show_channel  = channel.GuideNumber
show.show_length   = entry.durationMinutes
// ... (same fields as applyWebGuideEntry)
show.show_url      = channel.URL ?? ""
step = .details
state.pendingAddEntry = nil
```

---

## `save()`

Applies the selected series type flags and folder to the `show` struct, then calls `state.addShow(show)`:

```swift
show.show_is_series        = seriesType != .single
show.show_use_seriesid     = seriesType.isSeries
show.show_use_seriesid_all = seriesType == .seriesAll
show.show_air_date         = seriesType.isSeries
    ? ["Monday","Tuesday","Wednesday","Thursday","Friday","Saturday","Sunday"]
    : Array(airDays)
```

For SeriesID shows (`show_use_seriesid == true`), channel is looked up from the lineup by `show.show_channel`, and `resolveSeriesAir(show:device:isAll:channel:)` is called **before** `state.addShow(show)` — it checks for a currently-airing episode first, then falls back to the next future episode, so recording starts immediately if the show is on now.

`state.addShow` deduplicates by `show_id` (UUID), then saves the config to disk.

---

## Key Functions

| Function | Purpose |
|---|---|
| `applyWebGuideEntry(...)` | Populates `show` from web guide record message; sets `selectedDevice`; looks up stream URL from lineups |
| `applyPendingEntry(_:)` | Populates `show` from `state.pendingAddEntry`; jumps to details step |
| `applyPendingChannel(_:)` | Sets `selectedDevice` from `state.pendingAddChannel`; goes to guide step |
| `save()` | Applies series flags + folder; optionally calls `resolveSeriesAir`; calls `state.addShow` |
| `chooseFolder()` | `NSOpenPanel` folder picker; writes to `UserDefaults["defaultSaveDirectory"]` |
| `goForward()` / `goBack()` | Step navigation: `.device → .guide`, `.guide → break` (nav bar hidden; web guide advances via its own Record button), `.details → save()` |

---

## What Still Needs Doing

- **Time picker for DateTime shows** — air time is always taken from the guide entry's start time. If the user wants to schedule 5 minutes early, there's no control for that.

- **Single device step skip + slow discovery** — if discovery is still running when the wizard opens, it might auto-select a device that isn't the preferred one.

- **No edit integration** — there's no way to change a show's scheduled episode by browsing the guide in the Edit view.
