# AddShowView.swift — Add Show Wizard

## Visual Appearance

### Overall window
Fixed **560×540** for the details step; expands to resizable **min 1100×720** for the guide step. The guide-step size is **remembered across reopens and app restarts** — persisted in `UserDefaults` via `@AppStorage("addShowGuideWidth"/"addShowGuideHeight")` (defaults 1450×820), fed as the guide-step ideal width/height on open. A background `GeometryReader` (pure SwiftUI, no AppKit) reads the window-content size and writes it back on resize via `onChange`; sizes narrower than 1000 (the details step) are ignored so they never overwrite the saved guide size. The window animates between sizes with a 0.2s ease-in-out. Escape closes the window from any step.

**Top of window (all steps)**: 2 small 8pt circles in a row, left-padded under the top edge — progress indicator. Filled accent-color circle = current step; hollow gray circle = other step. `guide` and `details` steps only — `ForEach([Step.guide, .details])` always produces exactly 2 dots. Below the circles: a `Divider`.

> The native device-selection step was removed (the tuner is chosen inside the web guide). `Step` is now `{ case guide, details }`; there is no `deviceStep` view any more.

### Step 1 — Guide (web guide)
A `WKWebView` (`AddShowWebView`) loading `http://localhost:{port}/`. The web guide is the same interface served to LAN browsers. Clicking **Record** in the web guide's summary panel posts a `WKScriptMessage` (`"record"` handler) with entry data, which advances the wizard to step 2 (Details). The nav bar is hidden on this step; navigation happens via the Record button in the web guide.

If the web server is not yet running, a `ProgressView("Starting guide…")` is shown until it becomes ready.

### Step 2 — Details
Fixed 560×540 window. White/system background. `ScrollView` containing a `VStack` with 16pt spacing.

- Orange warning banner if `show.show_url` is empty — lineup may not have loaded yet.
- Form fields using `ShowFormSection` (shared with `EditShowView`) — this now includes a **Signal** row (bars for the selected channel + a weak-signal warning banner when the channel's signal is poor), gated on `Signal_quality_enabled`. See `docs/ShowFormSection.md`.
- **Other Upcoming Airings** panel (below the form, only when `seriesType.isSeries` — i.e. SeriesID(Channel) or SeriesID(All) — and results are non-empty): other future airings of the same `show_seriesid`, excluding the airing just selected in Step 2 (matched by channel + start time + `deviceId` together — channel + start time alone would also wrongly exclude a second tuner's identical airing of the same channel number, which is exactly what a shared-antenna multi-tuner setup reports). Each `OtherAiringRow` is a compact row — a leading 3pt accent bar tinted by `guideEntryColor(for:onAir:)` (same genre-color mapping as the guide grid and Watch Now), an 18×18 channel logo (from `state.channelImageURLs`/`channelIconImages`, falling back to a `tv` SF Symbol when uncached), and a text column: bold day+time (`upcomingFormatter`), secondary `Ch N · Channel Name`, and episode info (`GuideEntry.episodeInfoLabel`, e.g. "S01E13 · Episode Name") when the guide has it — no show title (redundant, the whole panel is about one series). Rows are separated by a `Divider()`, not individual card backgrounds; a light hover tint plus a `.help()` tooltip signal the row is double-clickable. Backed by `AppState.upcomingGuideEpisodes(seriesID:)` — bounded by the guide's ~29h-per-device window and a 4-row cap, so it's a best-effort preview, not an exhaustive schedule; a weekly series will often show only 1 entry (or none) simply because that's all the cloud guide window contains, not a bug. The result is cached in `@State private var otherAiringsCache` and only recomputed via `.task(id:)` (keyed on `show_seriesid`/`seriesType`/`show_channel`/`show_next`, plus `AppState.guideGeneration` — a counter `AppState` bumps every time `guideByDevice` is reassigned, so the ~hourly background guide refresh forces a recompute even if none of this show's own fields changed, instead of leaving a stale list showing if the wizard is left open across that refresh) rather than as a plain computed property read directly from `body`, since none of those fields change on a Title keystroke but a bare computed property would still re-run the lookup on every re-render regardless. Hidden entirely (no placeholder) for Single/DateTime shows, when `show_seriesid` is empty, or when no other airings are found. Mirrored on the web guide's Record modal via `GET /api/airings/{seriesId}` — see `docs/WebServer.md`'s "Record type modal" section — keep the two in sync.
- **Double-click a row to switch the Details step to that airing** (`AddShowView.switchToAiring(channel:entry:)`): re-anchors `show.show_title`/`show_channel`/`show_length`/`show_next`/`show_end`/`show_logo_url`/`show_genre`/`hdhr_record`/`show_url`/`show_time` (and `selectedDevice`, if the airing is on a different device) to the clicked entry — the same field set the initial guide selection populates, minus `seriesType`/`show_bonus_time`, which are left as already set on this step. `airDays` **is** updated (recomputed from the clicked entry's weekday) — it was left alone in an earlier version on the theory that only `seriesType`/`airDays`/`show_bonus_time` were user-set-and-preserved, but nothing stops the user from switching Type to `.dateTime` after using this panel, and a stale `airDays` from whatever the initial guide selection's weekday was would then silently mismatch the newly-chosen airing's actual day. Since the panel recomputes from `show.show_channel`/`show.show_next` on every render, the just-switched-from airing reappears in the list — a swap, not an append.
- Bottom-right: orange `StarburstBadge` (65pt size) floats via `.overlay(alignment: .bottomTrailing)`, springs in on appear if `show_bonus_time == true` and `Sports_padding_enabled`. Sports entries have Bonus Time pre-checked; any show type can enable it. Sized down from an earlier 115pt so it no longer covers the Folder row / Other Upcoming Airings panel underneath — see `docs/StarburstBadge.md`.

**Nav bar** (bottom): **Back** and **Record** grouped together and right-aligned (`HStack { Spacer(); HStack { Back; Record } }`) — Record is `.borderedProminent`, tinted `recordRed` (same red as the web guide's Record button, `#c0392b`, see `GuideViewHelpers.swift`). A `Divider` above.

## Intent

`AddShowView` is a 2-step wizard window for adding a new recording schedule: web guide browsing → recording details (see the note under "Overall window" above for why there's no separate device-selection step).

Window size: **560×540** for the details step; **resizable** (min 1100×720) for the guide step, which remembers its size across reopens/restarts (mechanism in "Overall window" above) and can otherwise be resized freely — the web guide fills the available width.

---

## Steps

```
enum Step { case guide, details }
```

A progress indicator (2 dots, filled vs hollow) tracks position across the `guide` and `details` steps. The guide step hides the nav bar entirely; navigation is via the Record button in the web guide summary panel. **Escape key** dismisses the window from any step (`.onExitCommand { dismiss() }`).

### Step 1 — Guide

`AddShowWebView: NSViewRepresentable` wraps a `WKWebView` loaded with `http://localhost:{port}/`. A `WKScriptMessageHandler` named `"record"` is registered; when the user clicks Record in the web summary panel, JS posts the entry data to this handler. The coordinator calls `onRecord([String: Any])` on the main queue.

`onRecord` in `guideStep` calls `applyWebGuideEntry(...)`, which populates all `show` fields and sets `selectedDevice`, then sets `step = .details`.

**Web server lifecycle**: managed at the wizard root, not the guide step. `ensureWebServerRunning()` is called in the root `.onAppear` (only when the guide step will be shown — skipped for the `pendingAddEntry` path that goes directly to details). `releaseInternalWebServer()` is called in root `.onDisappear`. This means stepping from guide → details → Back does not stop and restart the server, and the user never sees a "Starting guide…" flash on Back navigation.

**Lineup pre-load**: the `guideStep` Group has a `.task(id: state.devices.isEmpty)` that calls `state.ensureLineupLoaded(for:)`. This ensures `state.lineups[deviceId]` is populated before the user can click Record — so `applyWebGuideEntry`'s lineup lookup always finds a URL rather than returning `""`. Keyed by `state.devices.isEmpty` rather than a bare `.task` — a bare `.task` only fires once for the view's lifetime, so if the wizard opens during a cold launch before device discovery has finished, `state.devices` is empty, the guard inside returns immediately, and it would otherwise never retry once discovery completes. The `isEmpty` id flips `false` the moment devices populate, re-running the task at that point.

**Re-open while open**: `.onChange(of: state.pendingAddEntryGeneration)` and `.onChange(of: state.pendingAddChannelGeneration)` on the root body handle the case where the user opens the Add Show wizard from WatchNow or the menu while the wizard is already on the guide step. The new pending entry is applied immediately without requiring the wizard to close and reopen.

External navigation is blocked — the `WKNavigationDelegate` only allows `localhost` URLs.

Dark/light theme is synced via JS in `webView(_:didFinish:)`.

`dismantleNSView` removes the `"record"` message handler to prevent a retain cycle.

### Step 2 — Details

`ScrollView` containing the form fields, with a `StarburstBadge` floating at the bottom-right via `.overlay(alignment: .bottomTrailing)` on the outer `Group { switch step }` — outside and above the `ScrollView`.

Form fields, in fixed source order (`ShowFormSection.swift`) — only presence toggles per `Type`, the order itself never changes. Fields common to every `Type` come first; the one field unique to the selected `Type` (Day(s) for Single/DateTime, Duplicate Episodes for the series types) is pushed to the bottom, immediately before Folder:
- **Title** — `TextField` pre-populated from the web guide entry
- **Signal** — bars for the selected channel + a weak-signal warning when its signal is poor (only when `Signal_quality_enabled` and the channel has signal history); shared via `ShowFormSection`
- **Type** — segmented `Picker` for `ShowState.allCases`
- **Transcode** — `Picker`: None / Heavy / Mobile / Internet 720
- **Bonus Time** — toggle, shown when `Sports_padding_enabled`; see "Bonus Time starburst" below
- **Days** — weekday toggle buttons (shown for `.single` and `.dateTime` only, mutually exclusive with Duplicate Episodes). Single enforces single-day selection and labels the row "Day " (with a trailing space, padded to match "Days" width so the weekday buttons stay aligned between the two Types); dateTime allows any combination and labels it "Days"
- **Duplicate Episodes** — shown only when Series subfolders + Skip already-recorded episodes are both on and the show is a series (`.seriesChannel`/`.seriesAll`), mutually exclusive with Days; an orange "already on disk — will be skipped" warning plus a "Record even if already on disk" toggle (`show_ignore_duplicate_once`); shared via `ShowFormSection`
- **Folder** — always last; display + Choose… button; writes to `UserDefaults["defaultSaveDirectory"]`

**Bonus Time starburst**: when `show.show_bonus_time == true && state.config.Sports_padding_enabled`, a `StarburstBadge` floats at the bottom-right corner showing "+N min". Sports entries auto-enable Bonus Time.

`canAdvance` for details step: `!show.show_title.isEmpty && recordFolder != nil && !show.show_url.isEmpty`, **and**, when `seriesType == .dateTime`, `!airDays.isEmpty` — a recurring DateTime show with every weekday deselected can't advance/save, since it would save and then never fire (single/seriesChannel/seriesAll shows don't gate on `airDays` this way; series types override `show_air_date` to all 7 days at save regardless of UI state). A `false` result just disables the Record button (SwiftUI `.disabled`) with no other feedback — see "Silent-failure logging" below for what's logged at the points that can cause this with zero visible cause.

**Silent-failure logging** (added 2026-08-12, after a report of "clicked Record in the wizard, nothing happened, no confirmation" that left no trace to diagnose): every point along the guide-click → Details-step path that can silently produce nothing now logs to `hdhrVCRplus.log`. (1) The `"record"` `WKScriptMessage` handler's field-decoding `guard` (previously a bare `else { return }`) now logs `[AddShow] guide record message missing/malformed required field(s) — got keys: [...]` at `.warning` if the JS payload is missing `deviceId`/`guideNumber`/`startTime`/`endTime`, and a plain `[AddShow] guide record → 'Title' ch=X device=Y` on success, so a future report can distinguish "the click never reached native code" from "it arrived but something downstream failed." (2) `applyWebGuideEntry`/`applyPendingEntry` log `[AddShow] 'Title' ch=X device=Y — stream URL not found: ...` at `.warning` whenever the lineup lookup that fills `show.show_url` comes back empty — the exact condition that leaves Record silently disabled — with a reason (lineup not loaded yet for that device, vs. loaded but no matching `GuideNumber`) rather than just the pre-existing orange Details-step banner, which had no log counterpart. (3) `save()`'s `recordFolder == nil` early-out (shouldn't be reachable given `canAdvance`'s own gate, but defensive) logs `[AddShow] save() aborted — recordFolder was nil for 'Title'` at `.warning` instead of a bare no-op.

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

Called from `.onAppear` when `state.pendingAddEntry` is set, **or** from the root `.onChange(of: state.pendingAddEntryGeneration)` when it fires while the wizard is already open. Inlines field population from the pending tuple, bypassing the web guide step entirely and jumping directly to step 2 (Details):

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
    ? ["Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"]
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
| `save()` | Applies series flags; sets `show_dir` to the chosen `recordFolder` and `show_temp_dir` to `Show.localFallbackDir` (a genuinely distinct local fallback, not a copy of `recordFolder` — see `Show.localFallbackDir`'s doc comment and `docs/EditShowView.md`'s `saveWithoutDismiss()` entry for the bug this fixed); for a SeriesID type, strips any episode-specific suffix (e.g. " S24E116 Trey Parker; Matt Stone; Alison Brie") from `show_title` via `Show.seriesTitle(from:)` — `applyPendingEntry`/`applyWebGuideEntry`/`switchToAiring` all set `show_title` straight from the raw guide entry with no stripping, so this is the one gate that actually applies it, no matter which of those last touched the title; optionally calls `resolveSeriesAir`; calls `state.addShow` |
| `chooseFolder()` | `NSOpenPanel` folder picker; writes to `UserDefaults["defaultSaveDirectory"]` |
| `goBack()` | Step navigation: `.details → .guide` (the guide step advances via the web guide's own Record button, so there is no `goForward()`) |

---

## What Still Needs Doing

- **Time picker for DateTime shows** — air time is always taken from the guide entry's start time. If the user wants to schedule 5 minutes early, there's no control for that.

- **No edit integration** — there's no way to change a show's scheduled episode by browsing the guide in the Edit view.
