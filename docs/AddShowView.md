# AddShowView.swift — Add Show Wizard

## Visual Appearance

### Overall window
The window is always the guide: resizable, **min 1100×720**. The details step is a **sheet** (560×540) that slides down from the title bar over it (2026-10-19, explicit request — resizing the window between steps looked bad). The guide-step size is **remembered across reopens and app restarts** — persisted in `UserDefaults` via `@AppStorage("addShowGuideWidth"/"addShowGuideHeight")` (defaults 1450×820), fed as the guide-step ideal width/height on open. A background `GeometryReader` (pure SwiftUI, no AppKit) reads the window-content size and writes it back on resize via `onChange`; sizes narrower than 1000 (the details step) are ignored so they never overwrite the saved guide size. The window never resizes between steps (the sheet floats over the guide). **Escape** closes the window (`dismissWindow(id: "add-show")`) when the guide is showing; on the Details sheet it cancels the sheet (the Cancel button's `.cancelAction` shortcut) and returns to the guide.

**Top of window (all steps)**: nothing — the step content starts directly under the title bar. The 2-dot progress indicator and the `Divider` below it were removed 2026-10-19 (explicit request: they only added dead space above the guide).

> The native device-selection step was removed (the tuner is chosen inside the web guide). `Step` is now `{ case guide, details }`; there is no `deviceStep` view any more.

### Step 1 — Guide (web guide)
A `WKWebView` (`AddShowWebView`) loading `http://localhost:{port}/`. The web guide is the same interface served to LAN browsers. Clicking **Record** in the web guide's summary panel posts a `WKScriptMessage` (`"record"` handler) with entry data, which advances the wizard to step 2 (Details). The nav bar is hidden on this step; navigation happens via the Record button in the web guide.

If the web server is not yet running (or the page cache is cold), a `ProgressView("Starting guide…")` is shown until it becomes ready. If that takes more than **15 s** the spinner is replaced by a `CaveatBanner` "The guide server isn't responding." with a **Retry** button (re-claims the web server and re-warms the page cache; the 15 s timer re-arms). If the embedded page itself fails to load (`didFailProvisionalNavigation` / `didFail` on `AddShowWebView.Coordinator`; a cancelled load is ignored), a material card overlay shows a `CaveatBanner` "The guide didn't load (reason)." with a **Reload** button, which bumps a reload token that makes `updateNSView` reload the page; a later successful load (`didFinish`) clears it.

### Step 2 — Details
Fixed 560×540 **sheet** over the guide window. White/system background. `ScrollView` containing a `VStack` with 16pt spacing.

- A `CaveatBanner` (shared soft-tinted warning component, `Views/CaveatBanner.swift` — see `docs/ShowFormSection.md`'s own note on it) if `show.show_url` is empty — "Stream URL not found — lineup may not be loaded yet. Cancel and pick the channel again."
- **Validation captions**: when Record is disabled for a fixable reason, a one-line red caption (`FormErrorCaption`, caption size) appears under the offending field — "Title is required." under Title, "Pick at least one day." under Day(s) (Single and DateTime; both need a day selected).
- Form fields using `ShowFormSection` (shared with `EditShowView`) — this now includes a **Signal** row (bars for the selected channel + a weak-signal `CaveatBanner` when the channel's signal is poor), gated on `Signal_quality_enabled`. See `docs/ShowFormSection.md`.
- **Other Upcoming Airings** panel (below the form, only when `seriesType.isSeries` — i.e. SeriesID(Channel) or SeriesID(All) — and results are non-empty): other future airings of the same `show_seriesid`, excluding the airing just selected in Step 2 (matched by channel + start time + `deviceId` together — channel + start time alone would also wrongly exclude a second tuner's identical airing of the same channel number, which is exactly what a shared-antenna multi-tuner setup reports). Each `OtherAiringRow` is a compact row — a leading 3pt accent bar tinted by `guideEntryColor(for:onAir:)` (same genre-color mapping as the guide grid and Watch Now), an 18×18 channel logo (from `state.channelImageURLs`/`channelIconImages`, falling back to a `tv` SF Symbol when uncached), and a text column: bold day+time (`upcomingFormatter`), secondary `Ch N · Channel Name`, and episode info (`GuideEntry.episodeInfoLabel`, e.g. "S01E13 · Episode Name") when the guide has it — no show title (redundant, the whole panel is about one series). Rows are separated by a `Divider()`, not individual card backgrounds; a light hover tint plus a `.help()` tooltip signal the row is double-clickable. Backed by `AppState.upcomingGuideEpisodes(seriesID:channelNum:)` — bounded by the guide's ~29h-per-device window and a 4-row cap, so it's a best-effort preview, not an exhaustive schedule; a weekly series will often show only 1 entry (or none) simply because that's all the cloud guide window contains, not a bug. As of 2026-08-23, `channelNum` is `show.show_channel` when `seriesType == .seriesChannel` (that scope only ever records from the one channel it's locked to, so the preview would otherwise list airings this show could never actually catch) and `nil` (every channel) for `.seriesAll` — device is deliberately never filtered either way, since a cross-device airing is still shown so double-clicking it can re-anchor the show to that other tuner (see `switchToAiring(channel:entry:)` below). The result is cached in `@State private var otherAiringsCache` and only recomputed via `.task(id:)` (keyed on `show_seriesid`/`seriesType`/**whether `seriesType == .seriesChannel`** (so toggling the Scope picker — `docs/ShowFormSection.md`'s "Type/Scope split" — recomputes the list immediately, not just a channel/type change)/`show_channel`/`show_next`, plus `AppState.guideGeneration` — a counter `AppState` bumps every time `guideByDevice` is reassigned, so the periodic background guide refresh (cadence is `AppState.effectiveGuideRefreshIntervalSeconds`-derived, not hourly — see `docs/AppState.md`'s idle-loop entry) forces a recompute even if none of this show's own fields changed, instead of leaving a stale list showing if the wizard is left open across that refresh) rather than as a plain computed property read directly from `body`, since none of those fields change on a Title keystroke but a bare computed property would still re-run the lookup on every re-render regardless. Hidden entirely (no placeholder) for Single/DateTime shows, when `show_seriesid` is empty, or when no other airings are found. Mirrored on the web guide's Record modal via `GET /api/airings/{seriesId}` — see `docs/WebServer.md`'s "Record type modal" section — keep the two in sync. Neither `EditShowView` nor the web Edit modal has an equivalent panel at all.
- **Double-click a row to switch the Details step to that airing** (`AddShowView.switchToAiring(channel:entry:)`): re-anchors `show.show_title`/`show_channel`/`show_length`/`show_next`/`show_end`/`show_logo_url`/`show_genre`/`hdhr_record`/`show_url`/`show_time` (and `selectedDevice`, if the airing is on a different device) to the clicked entry — the same field set the initial guide selection populates, minus `seriesType`, which is left as already set on this step. `airDays` **is** updated (recomputed from the clicked entry's weekday) — it was left alone in an earlier version on the theory that only `seriesType`/`airDays`/`show_bonus_time` were user-set-and-preserved, but nothing stops the user from switching Type to `.dateTime` after using this panel, and a stale `airDays` from whatever the initial guide selection's weekday was would then silently mismatch the newly-chosen airing's actual day. `show_bonus_time` **is** also recomputed now (`Show.genreImpliesBonusTime(show.show_genre) && state.config.Sports_padding_enabled`, same formula as `applyWebGuideEntry`/`applyPendingEntry`) — an earlier version left it alone too, so switching to a differently-genred airing (e.g. non-sports → a sports simulcast of the same series) could leave the Bonus Time toggle silently stuck at whatever the first-selected airing implied; see `issues_resolved.md`'s "`AddShowView.switchToAiring` didn't recompute `show_bonus_time`" entry. Since the panel recomputes from `show.show_channel`/`show.show_next` on every render, the just-switched-from airing reappears in the list — a swap, not an append.
- Bonus Time badge: now inline beside the Bonus Time toggle (`ShowFormSection`, 60pt), scrolls with the form — no longer a floating overlay. Sports entries have Bonus Time pre-checked; any show type can enable it — see `docs/StarburstBadge.md`.

**Nav bar** (bottom): **Cancel** (Esc, `.cancelAction`) and **Record** (Return, `.defaultAction`) grouped together and right-aligned (`HStack { Spacer(); HStack { Cancel; Record } }`) — Record is `.borderedProminent`, tinted `recordRed` (same red as the web guide's Record button, `#c0392b`, see `GuideViewHelpers.swift`). A `Divider` above.

## Intent

`AddShowView` is a 2-step wizard window for adding a new recording schedule: web guide browsing → recording details (see the note under "Overall window" above for why there's no separate device-selection step).

Window size: always the guide's (**resizable**, min 1100×720; the details step is a 560×540 sheet), which remembers its size across reopens/restarts (mechanism in "Overall window" above) and can otherwise be resized freely — the web guide fills the available width.

---

## Steps

```
enum Step { case guide, details }
```

The `guide` and `details` steps have no progress indicator (removed 2026-10-19). The guide step hides the nav bar entirely; navigation is via the Record button in the web guide summary panel. **Escape key**: the root `.onExitCommand` calls `dismissWindow(id: "add-show")` (closes the window) when the guide is showing; while the Details sheet is up, Esc is the sheet's Cancel button (`.cancelAction`), which sets `step = .guide` and drops the sheet. There is no `goBack()` or Back button — the `Step` model is just guide ↔ sheet. `WatchNowView`, by contrast, is a single standard window with no step model and no `onExitCommand` of its own.

### Step 1 — Guide

`AddShowWebView: NSViewRepresentable` wraps a `WKWebView` loaded with `http://localhost:{port}/`. Two `WKScriptMessageHandler`s are registered (a third, `"scanMultiplex"`, for an OTA "Refresh this multiplex's guide" button, was removed 2026-10-28): `"record"` (user clicks Record in the web summary panel — JS posts the entry data, the coordinator calls `onRecord([String: Any])` on the main queue) and `"appearanceChanged"` (see "Appearance sync" below).

`onRecord` in `guideStep` calls `applyWebGuideEntry(...)`, which populates all `show` fields and sets `selectedDevice`, then sets `step = .details`.

**Web server lifecycle**: managed at the wizard root, not the guide step. `ensureWebServerRunning()` is called unconditionally in the root `.onAppear` — on *every* entry path, including `pendingAddEntry`/`pendingAddChannel`, which land straight on `.details`. It's still needed there because the matching `releaseInternalWebServer()` in root `.onDisappear` is itself unconditional (a path that skipped the acquire would underflow `internalWebServerUseCount`), and because even a pending-entry launch can Cancel from `.details` back to `.guide`, whose `WKWebView` loads `localhost:1980`. This means stepping from guide → details → Cancel does not stop and restart the server, and the user never sees a "Starting guide…" flash after Cancel.

**Lineup pre-load**: the `guideStep` Group has a `.task(id: state.availableDevices.isEmpty)` that calls `state.ensureLineupLoaded(for:)` for `selectedDevice ?? availableDevices.first`. This ensures `state.lineups[deviceId]` is populated before the user can click Record — so `applyWebGuideEntry`'s lineup lookup always finds a URL rather than returning `""`. Keyed by `state.availableDevices.isEmpty` (reachable, non-relay tuners — what the body actually loads from; keyed on `recordableDevices`, a tuner that was present but unreachable at open never re-ran the task when it came back, 2.6.5 review) rather than a bare `.task` — a bare `.task` only fires once for the view's lifetime, so if the wizard opens during a cold launch before device discovery has finished, the guard inside returns immediately, and it would otherwise never retry once discovery completes. `recordableDevices`, not raw `state.devices` — a discovered virtual-relay device (FEED) has no real lineup of its own and can't be recorded from, so its presence alone shouldn't count as "devices are here now, stop waiting" (a `devices.isEmpty` id could flip `false` from a virtual-relay-only discovery and then never retry again once a real tuner is later found). The id flips `false` the moment a real, reachable device populates, re-running the task at that point.

**Guide-page cache warmth**: the `guideStep` Group also gates on `state.guidePageCacheWarm`, not just `state.webServerRunning` — see `docs/WebServer.md`'s "HTML cache" section. `AppState.startup()` warms `WebServer`'s page cache immediately after starting the server (independent of device discovery/guide fetch), so in practice this flag is already `true` well before a user could open Add Show; the gate here is a defensive backstop for the rare case it isn't yet, preventing the embedded `WKWebView` from ever hitting `GET /` while the cache is still cold (which used to fall back to a synchronous, multi-second main-thread-blocking guide build).

**Re-open while open**: `.onChange(of: state.pendingAddEntryGeneration)` and `.onChange(of: state.pendingAddChannelGeneration)` on the root body handle the case where the user opens the Add Show wizard from WatchNow or the menu while the wizard is already on the guide step. The new pending entry is applied immediately without requiring the wizard to close and reopen.

External navigation is blocked — the `WKNavigationDelegate` only allows `localhost` URLs.

**Native chrome (2026-10-10)**: `AddShowWebView` injects a `WKUserScript` (document start) that adds class `native` to `<html>`; `guide.css`'s `html.native` rules drop the rounded frame around the grid, run the grid flush to the window's edges (`margin:0 -16px -16px` cancels the body padding) and remove the `::-webkit-scrollbar:horizontal` override, so macOS's own overlay scrollbars apply (the custom `#g-hscroll` is hidden). LAN browsers never get the class and are unchanged. `:root{color-scheme:dark}` / `html.lm{color-scheme:light}` make native scrollbars follow the guide theme.

**Appearance sync** (Settings → General → Appearance, `AppConfig.Appearance_mode`): two-way, but only for this embedded instance — a browser hitting the same guide over the LAN keeps its own independent theme (see `docs/WebServer.md`'s "Dark mode" section for why that isolation is automatic rather than something this code has to enforce). Native → web: `pushAppearance(to:)` resolves `"auto"` against `NSApp.effectiveAppearance` (`"dark"`/`"light"` apply directly) and calls `guide.js`'s `applyNativeTheme(theme)` — from `webView(_:didFinish:)` on every load, and from `updateNSView` whenever `appearanceMode` changes while this window is already open on the guide step (so a Settings change takes effect immediately, not just on next reload). Web → native: the guide's own theme-switcher buttons call `guide.js`'s `setTheme(m)`, which (unlike `applyNativeTheme`) also does `window.webkit.messageHandlers.appearanceChanged.postMessage(m)` — the `"appearanceChanged"` handler's `onAppearanceChanged(String)` callback sets `state.config.Appearance_mode` and saves. `applyNativeTheme`/`setTheme` are deliberately two separate JS entry points, not one — a native-pushed theme must never round-trip back through the message handler and get treated as a fresh user choice (a resolved `"auto"` silently overwriting itself as a concrete `"dark"` in Settings, just because a page loaded, would be a real bug).

`dismantleNSView` removes both message handlers to prevent a retain cycle.

### Step 2 — Details

`ScrollView` containing the form fields (the `StarburstBadge` is inline in the Bonus Time row, not an overlay). The details sheet stays a fixed 560×540 — a sheet is not user-resizable; the guide window itself is the resizable part.

Form fields, in fixed source order (`ShowFormSection.swift`) — only presence toggles per `Type`, the order itself never changes. Fields common to every `Type` come first; the type-conditional fields (Day(s) for Single/DateTime, New Only for every non-Single type, Duplicate Episodes for the series types) are pushed toward the bottom, immediately before Folder:
- **Title** — `TextField` pre-populated from the web guide entry
- **Signal** — bars for the selected channel + a weak-signal `CaveatBanner` when its signal is poor (only when `Signal_quality_enabled` and the channel has signal history); shared via `ShowFormSection`
- **Type** — segmented `Picker` over 3 collapsed choices, Single/DateTime/SeriesID (`.seriesChannel`/`.seriesAll` render as one "SeriesID" segment) — see `docs/ShowFormSection.md`'s "Type/Scope split"
- **Scope** — shown only when the series type is selected; a 2-segment Channel/All `Picker` that sets `show_use_seriesid_all`. See `docs/ShowFormSection.md`.
- **Transcode** — `Picker`: None / Heavy / Mobile / Internet 720. When the selected profile isn't None and the device doesn't support transcoding (`HDHRDevice.supportsTranscode`), a `CaveatBanner` appears below it saying the setting will be ignored and recorded as None — see `docs/ShowFormSection.md`.
- **Bonus Time** — toggle, shown when `Sports_padding_enabled`; see "Bonus Time starburst" below
- **Days** — weekday toggle buttons (shown for `.single` and `.dateTime` only). Single enforces single-day selection and labels the row "Day " (with a trailing space, padded to match "Days" width so the weekday buttons stay aligned between the two Types); dateTime allows any combination and labels it "Days". Not mutually exclusive with New Only below — `.dateTime` shows both Days and New Only together, since New Only's own gate is "every `Type` except `.single`". Only Days/Duplicate Episodes never coexist (Days is Single/DateTime-only, Duplicate Episodes is series-only).
- **New Only** — shown for every `Type` except `.single` (`.dateTime`/`.seriesChannel`/`.seriesAll`); a "Skip reruns" toggle (`show_new_only`) — at record time, skips an airing the guide doesn't mark as new and advances to the next scheduled one. No live preview banner (unlike Duplicate Episodes) since "is this airing new" can only be checked against the guide entry actually resolved at record time. Renders alongside Duplicate Episodes below for the series types (`.seriesChannel`/`.seriesAll`), when Duplicate Episodes' own gate is also satisfied. See `docs/ShowFormSection.md`.
- **Duplicate Episodes** — shown only when Series subfolders + Skip already-recorded episodes are both on and the show is a series (`.seriesChannel`/`.seriesAll`); a `CaveatBanner` reading "already on disk — will be skipped" plus a "Record even if already on disk" toggle (`show_ignore_duplicate_once`); shared via `ShowFormSection`
- **Folder** — always last; display + Choose… button; writes to `UserDefaults["defaultSaveDirectory"]`. `resetShowForNewEntry()` (every guide pick) re-reads `state.defaultSaveDir` into `recordFolder` — the `@State` initializer only runs once per window lifetime, so a default changed in Settings since the window first opened used to be ignored

**Bonus Time starburst**: when `show.show_bonus_time == true && state.config.Sports_padding_enabled`, a `StarburstBadge` shows inline beside the toggle ("+N min"). Sports entries auto-enable Bonus Time.

`canAdvance` for details step: `!show.show_title.isEmpty && recordFolder != nil && !show.show_url.isEmpty`, **and**, when `seriesType == .dateTime || .single`, `!airDays.isEmpty` — a show with every weekday deselected can't advance/save, since it would save and then never fire (seriesChannel/seriesAll shows don't gate on `airDays`; series types override `show_air_date` to all 7 days at save regardless of UI state). A `false` result disables the Record button (SwiftUI `.disabled`); the empty-title and no-day reasons also show the red captions described above (the missing-URL reason shows the banner) — see "Silent-failure logging" below for what's logged at the points that can cause this with zero visible cause.

**Silent-failure logging** (added 2026-08-12, after a report of "clicked Record in the wizard, nothing happened, no confirmation" that left no trace to diagnose): every point along the guide-click → Details-step path that can silently produce nothing now logs to `hdhrVCRplus.log`. (1) The `"record"` `WKScriptMessage` handler's field-decoding `guard` (previously a bare `else { return }`) now logs `[AddShow] guide record message missing/malformed required field(s) — got keys: [...]` at `.warning` if the JS payload is missing `deviceId`/`guideNumber`/`startTime`/`endTime`, and a plain `[AddShow] guide record → 'Title' ch=X device=Y` on success, so a future report can distinguish "the click never reached native code" from "it arrived but something downstream failed." (2) `applyWebGuideEntry`/`applyPendingEntry` log `[AddShow] 'Title' ch=X device=Y — stream URL not found: ...` at `.warning` whenever the lineup lookup that fills `show.show_url` comes back empty — the exact condition that leaves Record silently disabled — rather than just the pre-existing Details-step `CaveatBanner`, which had no log counterpart. Only `applyWebGuideEntry` breaks this down into an actual reason (lineup not loaded yet for that device, vs. loaded but no matching `GuideNumber`); `applyPendingEntry` logs a fixed `"— stream URL not found on the passed-in channel"` with no such breakdown. (3) `save()`'s `recordFolder == nil` early-out (shouldn't be reachable given `canAdvance`'s own gate, but defensive) logs `[AddShow] save() aborted — recordFolder was nil for 'Title'` at `.warning` instead of a bare no-op.

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
show.show_bonus_time = Show.genreImpliesBonusTime(genre) && state.config.Sports_padding_enabled
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
| `chooseFolder()` | `NSOpenPanel` folder picker, nested as a sheet on the Details sheet's own window (`Dialogs.choose(_, on: sheetWindow())`; the refusal alert in `showAddRefusal` likewise); writes to `UserDefaults["defaultSaveDirectory"]` |
| `resetShowForNewEntry()` | Starts each guide pick from a fresh `Show.blank()` with the config's default transcode, and re-reads the current default save folder into `recordFolder` |
| `go(_:)` | Sets `step`; `.details` presents the sheet, `.guide` dismisses it (the guide advances via the web guide's own Record button, so there is no `goForward()`) |

---

## What Still Needs Doing

- **Time picker for DateTime shows** — air time is always taken from the guide entry's start time. If the user wants to schedule 5 minutes early, there's no control for that.

- **No edit integration** — there's no way to change a show's scheduled episode by browsing the guide in the Edit view.

**Other-airings channel icon (2026-10-04):** the 18×18 icon beside each row now shows `stationLogoPlaceholder` (the app icon) instead of the `tv` SF Symbol whenever the station's real logo isn't cached (no `ImageURL`, still downloading, or failed); the real logo replaces it once `ChannelIconCache` has it.

**Details sheet (2026-10-19):** `.sheet(isPresented:)` bound to `step == .details`; Cancel (or Esc) sets `step = .guide`, Record saves and closes the window (`dismissWindow(id: "add-show")` — `dismiss` inside a sheet only closes the sheet). The guide web view stays mounted underneath, so nothing reloads and the window never resizes. An entry that arrives pre-filled (`pendingAddEntry`) opens the window with the sheet already showing. The earlier slide/resize attempts were removed.
