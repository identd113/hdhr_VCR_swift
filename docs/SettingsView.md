# SettingsView.swift — Settings Window

## Visual Appearance

### Overall window
Fixed **560×520**. Standard macOS window chrome. Title: `"Settings"`.

### Layout
`VStack` with no spacing: `NavigationSplitView` fills the top portion, a `Divider`, then a persistent save bar at the bottom (~42pt tall).

**Sidebar** (left column, 150–200pt wide):
macOS `List` with items using `Label(name, systemImage: icon)`. Icons and category names:
- `gear` General
- `record.circle` Recording
- `tv` Guide
- `bell.badge` Notifications
- `terminal` Advanced
- `globe` Web Server
- `wrench.and.screwdriver` Maintenance
- `info.circle` About

Selected row highlighted in accent color. Each row carries `accessibilityIdentifier("settings-tab-\(cat.id...)")` (lowercased, spaces→hyphens) — a stable non-visual handle for UI automation/accessibility tooling (see `Tests/hdhr_VCRTests/Views/WindowNavigationTests.swift`), since the window's title tracks the selected tab's own `.navigationTitle` rather than staying a fixed "Settings".

**Detail area** (right): `Form` with `.grouped` style (rounded-rect sections on macOS). Each category shows its own `Form` with `Section` headers. Navigation title appears at the top of the detail area.

**Save bar** (bottom, always visible):
- `"Unsaved changes"` secondary small text + `"Discard"` secondary-color button when dirty
- `"Test the webhook before saving"` orange warning + Discard when webhook untested
- Right side: `"Save"` button (disabled when clean or webhook untested, ⌘S shortcut) + **"Save & Close"** prominent button (orange tint when dirty, blue/accent when clean, Return shortcut)
- Accessibility identifiers: `settings-discard`, `settings-save`, `settings-save-close`

### Category: General
Two `Section`s:
- **System**: `Toggle("Launch at Login")`, `Toggle("Blink menu bar icon")`
- **Guide**: `Toggle("Use XMLTV guide format")` — bound to `draft.Guide_use_xml` (default `false`). Moved here from the Guide tab's former Format section (2026-08-10) so the JSON/XMLTV switch is visible without digging into a dedicated tab. No inline warning; toggling and saving triggers an immediate guide refresh via the XMLTV endpoint.

### Category: Recording
Two `Section`s:

**Recording** section:
- Default folder: `LabeledContent` with secondary path text + `"Choose…"` + optional `"Reset"` buttons
- Default transcode: inline `Picker` — None / Heavy / Mobile / Internet 720
- Min free disk: `Stepper` showing `"Min free disk: N GB"`, range 1–100
- Pause after N failures: `Stepper`, range 1–10
- Watch in VLC: `Toggle` (only visible when VLC is installed)
- Bonus Time: `Toggle`; when on, reveals a `Stepper` for bonus minutes (10–60, step 5)

**Post-Processing** section:
- Series subfolders: `Toggle`; when on, SeriesID recordings are organized into `Title/Season XX/` subfolders; episode tag (e.g. `S02E04`) is embedded in the filename
- Skip already-recorded episodes: `Toggle` (only visible when Series subfolders is on) — skips a managed episode whose `SxxExx` is already on disk
- Post-recording script: path field + `"Choose…"` button — runs after a recording finishes

### Category: Guide
One `Section`:

**Fetch** section:
- Guide hours: `Stepper` `"Show next N hours"`, range 1–28
- Series scan retry: `Stepper` `"Series scan retry: N hr"`, range 1–24
- `"Update Guides Now"` `.borderedProminent` button

The JSON/XMLTV format toggle (formerly a "Format" section here) moved to General → Guide, 2026-08-10 — see that section above.

### Category: Notifications
**Notifications** section: Up Next minutes `Stepper` (5–120, step 5); Recording alert minutes `Stepper` (1–60). Orange `Label` warning when recording alert fires at or after Up Next.

**Discord** section: `Toggle("Enable Discord notifications")`. When enabled: `HStack` with monospaced `TextField` for webhook URL + `"Test"` `.bordered` button (or `ProgressView` while testing). Status labels:
- Passed: green `checkmark.circle.fill` + `"Verified"`
- Failed: red `xmark.circle.fill` + error text
- Untested: orange text `"Test the webhook before saving."`

**Notify when…** section (visible only when enabled + URL set): 4 grouped toggles (Lifecycle events, Reminders, Problems, Other) instead of 12 flat per-event rows.

### Category: Advanced
Four sections:
- **Network**: `Picker` for discovery/recording interface (`"Auto"` default + available NICs with display names). Caption explaining VPN usage. (The idle-check-interval stepper that used to live here was removed 2026-07-23 — see below.)
- **Logging**: `"Show App Log in Console"` button (opens Console.app for OSLog output) + selectable filter hint label (`subsystem == "com.hdhr.vcrplus"`). `Toggle("Verbose curl logging")`; when on: caption with curl log path (text-selectable) + `"Show curl log in Finder"` button. Config path (text-selectable) + `"Show config in Finder"` button — merged here from the former standalone Config File section.
- **Updates**: single `Toggle("Check for updates automatically")` bound to `draft.Check_for_updates` (default on). Gates only the automatic once-a-day background check (`AppState.updateCheckLoop()`); the manual "Check for Updates" button on the About tab always runs regardless. See `UpdateChecker.swift`.
- **Signal Quality**: two `Toggle`s (show bars, send dropout alerts) + conditional **Scan Channels** section with per-device scan buttons (visible only when Show signal bars is on)

The donation-nag unlock target is no longer Settings-editable — it's a hardcoded (hashed) constant
in `DonationNagView.swift` now, not per-install config. See [DonationNagView.md](DonationNagView.md).

### Category: Maintenance
Sections: Shows, Guide & Devices, Tools (if Homebrew found).

Each action row: title in medium weight + a small `ⓘ` `InfoButton` (tapping shows the description in a popover) + `"Run"` `.bordered` button on the right (or `ProgressView(.small)` while running).

When a task finishes: green `checkmark.circle.fill` + result message in a separate `Section`.

**Tools section** (Homebrew): brew install rows for VLC and HDHomeRun CLI; result label in green/red.

**Developer section** — removed (2026-07-23): it only offered a "Simulate macOS version" picker, which had been dead since `CableGuideView` (its one consumer) was removed.

### Category: About
See the About section description below — app image with signal-pulse tap effect, version, native markdown changelog, GitHub link.

## InfoButton pattern

All controls use a label-closure `Form` syntax that embeds a small `ⓘ` **InfoButton** next to the control label. Tapping the button shows a popover (arrow edge `.bottom`, max width 280 pt) with the description string. There are no always-visible caption lines — descriptions are hidden until requested. Applies to all sections including `maintenanceRow` and `brewInstallRow` helpers.

```swift
private struct InfoButton: View {
    let text: String
    @State private var isPresented = false
    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "info.circle").font(.callout).foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            Text(text).font(.callout).padding(12).frame(maxWidth: 280)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
```

## Intent

`SettingsView` is a `NavigationSplitView` settings window (sidebar + detail, like Finder column view). All app configuration lives here. Changes are held in a `draft: AppConfig` until the user explicitly presses **Save** (⌘S) — nothing writes to disk mid-edit.

---

## Draft / Save Pattern

```swift
@State private var draft: AppConfig = AppConfig()
private var isDirty: Bool { draft != state.config }
```

- `.onAppear` seeds `draft = state.config`
- All controls bind to `$draft.*` — not to `state.config` directly
- **Save** → `applyAndSave()` sets `state.config = draft`, calls `state.saveConfig()`, and applies side effects: if `Network_interface` changed, invalidates the guide cache and triggers `state.rediscoverDevices()` + `state.refreshGuide()` in a background Task so the new NIC is active immediately
- **Save & Close** → if `canSave` (`isDirty && !webhookNeedsTest && !webPortInvalid`), calls `applyAndSave()`, then always closes the window regardless. **Disabled** (not always enabled) when the Discord webhook needs testing or the web port is out of range — closing without saving in that state is still possible via the window's own close button, just not this one. Rightmost button, `.borderedProminent`, triggered by Return (`.defaultAction`). Turns orange when `canSave` is true.
- **Discard** → `draft = state.config`
- **Close with unsaved changes** → `WindowCloseInterceptor` intercepts and shows an NSAlert: Save / Discard / Cancel

The Save button turns **orange** when `canSave` is true (`.tint(canSave ? .orange : .accentColor)`). `canSave = isDirty && !webhookNeedsTest && !webPortInvalid` — dirty changes alone don't enable Save if the webhook hasn't been tested or the port is invalid.

---

## Settings Categories

Sidebar entries (with SF Symbol icons):

| Category | Icon | Contents |
|---|---|---|
| General | `gear` | Launch at Login, Blink menu bar icon, JSON/XMLTV format toggle |
| Recording | `record.circle` | Folder, transcode, disk, failures, VLC, Bonus Time, Series subfolders, Post-recording script |
| Guide | `tv` | Guide hours, series scan retry |
| Notifications | `bell.badge` | Up Next timing, Recording alert timing |
| Advanced | `terminal` | Network interface, logging + verbose curl + config file path, check for updates, signal quality |
| Web Server | `globe` | Enable/disable LAN web server, port, access URL |
| Maintenance | `wrench.and.screwdriver` | Show maintenance, guide/device ops, brew tool installs |
| About | `info.circle` | App logo, version, history, GitHub link |

---

### General

- **Launch at Login** — uses `SMAppService.mainApp` (`register()`/`unregister()`), Apple's Login Item API — not a hand-written LaunchAgents plist. `launchAtLoginRegistered` reads `SMAppService.mainApp.status == .enabled`; the toggle only calls register/unregister on Save if the draft value differs from that live status. Toggle reverts to the actual registered state on a thrown error; the error's `localizedDescription` is shown in red below the toggle.
- **Blink menu bar icon** — `Toggle` bound to `draft.Status_light_blink_enabled` (off by default). When on, the menu bar icon's built-in status light blinks on a 6s cycle (5s lit, 1s off) instead of staying lit continuously while a recording is in progress or a show is starting within 30 minutes. Takes effect live — no restart or window reopen needed. Driven by `AppState.statusLightTimer`/`tickStatusLight()`, a dedicated 1Hz timer independent of the idle loop; see [MenuContent.md](MenuContent.md#menu-bar-icon-states).

---

### Recording

- **Default folder** — label (last path component) + Choose… + Reset. Stored in `@AppStorage("defaultSaveDirectory")` (not `AppConfig`). Priority order for resolution: UserDefaults → `config.Hdhr_setup_folder` → `~/Movies/hdhr_videos`.
- **Default transcode** — `Picker`: None / Heavy / Mobile / Internet 720. Stored in `draft.Default_transcode`.
- **Min free disk** — `Stepper` (1–100 GB). Recording is refused when free space is below this threshold (`AppState.diskOK(for:)`).
- **Pause after N failures** — `Stepper` (1–10). After `Fail_count_setting` consecutive failures, `show_active = false` and the show moves to Paused. Each successful recording start decrements `show_fail_count` by 1.
- **Watch in VLC** — `Toggle`, only shown when `/Applications/VLC.app` exists. Enables "Watch in VLC" buttons throughout the app. Stored in `draft.Watch_in_VLC`. **Auto-initialized**: on first launch (when `Watch_in_VLC_initialized == false`), the setting is auto-enabled if VLC is installed, then `Watch_in_VLC_initialized` is set to true so subsequent user toggles are never overridden.
- **Min buffer rate** — no longer exposed in Settings (removed 2026-07-23; low-utility tuning knob). `Player_buffer_min_rate` still exists in `AppConfig` and still sets the fill-phase floor for the in-app player's 8-second live buffer — it's just fixed at its default (93%) instead of user-adjustable.
- **Bonus Time** — `Toggle` (on by default). Extends any show's recording past guide end. Sports entries default to enabled via `applyWebGuideEntry()`; any show can override via the per-show toggle. Stored in `draft.Sports_padding_enabled`.
- **Bonus Time duration** — `Stepper` (10–60 min, step 5, default 30). Only visible when Bonus Time toggle is on. Stored in `draft.Sports_padding_minutes`.
- **Series subfolders** — `Toggle` (off by default). When enabled, SeriesID recordings (`seriesChannel`/`seriesAll`) are saved into `Title/Season XX/` subfolders inside the recording folder, and the episode tag (e.g. `S02E04`) is embedded in the filename before the channel. Falls back to `Title/` when no season is parseable from the guide's `EpisodeNumber`. Flat path used when disabled or for non-SeriesID shows. Stored in `draft.Series_subfolder_enabled`.
- **Skip already-recorded episodes** — `Toggle` (off by default), `.disabled(!draft.Series_subfolder_enabled)` so it greys out unless Series subfolders is on. When enabled, `startRecording` checks whether a file with the upcoming episode's season+episode (`SxxExx`) already exists in the show's folder tree (via `AppState.recordedEpisodeTags(forTitle:baseDir:)`); if so it logs `SKIP`, optionally posts a Discord card (`Discord_on_duplicate`), and advances to the next airing **without** recording or incrementing `show_fail_count`. Only fires when the upcoming guide entry has a full `S\d+E\d+` tag (season-only/blank tags record as normal). Also drives the web guide's slate "already recorded" status ring+badge (`.g-st-skip`, `docs/WebServer.md`). Stored in `draft.Skip_recorded_episodes`.
- **Post-recording script** — `LabeledContent` with Choose / Clear buttons (Choose opens an `NSOpenPanel` for files). When set, the selected shell script is run via `/bin/sh scriptPath filePath` after each successful recording (non-zero file size confirmed). The script receives the recording's POSIX file path as `$1` and the following env vars: `HDHR_PATH` (same as `$1`), `HDHR_TITLE`, `HDHR_CHANNEL`, `HDHR_TRANSCODE` (`"none"` if not set), `HDHR_EPISODE` (e.g. `"S02E04"` or `"S03"`; empty if not embedded), `HDHR_DEVICE`, `HDHR_SERIES` (`"1"` for SeriesID shows, `"0"` for dateTime), `HDHR_FILESIZE` (bytes). Homebrew paths (`/opt/homebrew/bin:/usr/local/bin`) are prepended to `PATH` so tools like `comskip` can be referenced by name. Script exits are logged; non-zero exit is logged as a warning. Stored in `draft.Post_recording_script`.

---

### Guide

**Fetch section:**
- **Show next N hours** — `Stepper` (1–28, capped below the old 1–48 range). Controls how far ahead the guide fetches and how long until the guide auto-refreshes (`max(3600, GuideHours × 1800)` seconds). Capped at 28 because `GuideStore.load()` makes a single API call and the cloud `guide.php` endpoint silently truncates any single request past ~29h (`docs/HDHRFindings.md`) — a higher setting would look accepted but never actually fetch further out. `AppConfig.init(from:)` also clamps a decoded value from an older config that saved something above 28.
- **Series scan retry** — `Stepper` (1–24 hr). How long to wait before re-scanning the guide for a SeriesID show's next episode when no match was found.
- **Update Guides Now** — `Button` (always visible). Calls `state.refreshAll()` immediately, invalidating and reloading guide data for all devices. Useful any time fresh data is needed without restarting the app.

**Format section:**
- **Use XMLTV guide format** — `Toggle` bound to `draft.Guide_use_xml` (default `false` = JSON). When enabled, guide data is fetched from the XMLTV cloud endpoint (`api/xmltv`) instead of `guide.php`. Flipping and saving triggers an immediate `invalidateAll()` + `refreshGuide()`. Devices without `DeviceAuth` fall back to JSON regardless. The `GuideHours` setting is ignored in XMLTV mode (server controls the window, ~2 days on free tier).

---

### Notifications

- **Up Next** — `Stepper` (5–120 min, step 5). Minutes before air to send the "Up Next" notification. Stored as `Double` (`Notify_upnext`) but displayed as `Int`.
- **Recording alert** — `Stepper` (1–60 min). Minutes before recording starts to send the "Recording Soon" notification. Stored as `Double` (`Notify_recording`).
- **Timing overlap warning** — orange `Label` shown when `Notify_recording >= Notify_upnext`; the Up Next notification won't fire before the Recording Soon one at those settings.

#### Discord Webhook

- **Webhook URL** — `TextField` bound to `draft.Discord_webhook_url`. Monospaced font. Shown only when `draft.Discord_enabled` is true. Leave blank (or disable the master toggle) to suppress all Discord notifications. `sendDiscordEmbed()` in `DiscordNotifier.swift` silently no-ops for blank or non-discord.com URLs.
- **Test button** — a single `.bordered` `"Test"` button next to the URL field; replaced by `ProgressView(.small)` while testing. Calls `state.checkWebhookURL(draft.Discord_webhook_url)` (sends a real ping to Discord). Disabled when the URL is blank.
- **`Section("Notify when…")`** — shown only when `draft.Discord_enabled && !draft.Discord_webhook_url.isEmpty`. Condensed (2026-07-23) from 12 flat per-event toggles into 4 grouped ones via a `groupToggle(_:_:fields:)` helper — each Toggle's `isOn` reflects whether *every* field in its group is on, and flipping it sets every field in the group to that new value together. The underlying `Discord_on_*` fields are unchanged and still checked independently by `fireDiscordCard`/`discordShow` call sites — this only reduces how many controls Settings shows, not the granularity of what's stored. Groups:
  - **Lifecycle events** — `Discord_on_start`, `Discord_on_complete`, `Discord_on_failed`, `Discord_on_paused`
  - **Reminders** — `Discord_on_upnext`, `Discord_on_soon`
  - **Problems** — `Discord_on_skipped` (disk full), `Discord_on_duplicate` (already recorded), `Discord_on_conflict`, `Discord_on_guide_error`
  - **Other** — `Discord_on_show_added`, `Discord_on_progress` (edits the start embed in-place every 5 min with elapsed/remaining time while recording)

#### Discord embed structure

Each embed includes:
- `author`: `"CH {number} · {name}"` with `icon_url` from `GuideChannel.ImageURL`
- `title`: event string (e.g. `"🔴 Recording Started"`)
- `description`: bold show title, episode number · title (if known), synopsis (truncated to 200 chars)
- `color`: event-specific decimal (green=started, blue=complete, red=failed, orange=paused/skipped, yellow=conflict, teal=added, purple=upnext/soon, grey=error)
- `fields`: Channel (inline), Type (inline), Time range (inline), plus event-specific extras (Reason, Next Airing, File Size, Format, etc.)
- `tags` field: filter tags formatted as `` `Drama` `` `` `Series` `` code-style
- `thumbnail`: `show_logo_url` (poster image)
- `footer`: `"hdhrVCRplus  ·  {deviceID}"`

Recording Complete embeds additionally include **Format** (file extension, e.g. `TS`) and **File Size** (e.g. `2.34 GB`) inline fields, derived from `FileManager.attributesOfItem` at stop time.

---

### Advanced

- **Idle check interval** — no longer exposed in Settings (removed 2026-07-23; low-utility tuning knob). `Idle_timer_interval` still exists in `AppConfig` and still controls how often the idle loop fires (`AppState.startTimer()`, minimum enforced at 5s) — it's just fixed at its default (10s) instead of user-adjustable, applied once at launch.
- **Discovery & recording interface** — `Picker`: "Auto" (empty string) plus all IPv4-bearing interfaces, each shown as `name  ip` (e.g. `en0  192.168.1.5`, `utun0  10.8.0.2`). Populated by `availableNetworkInterfaces()` via `getifaddrs`; uses `IFF_POINTOPOINT` to detect all VPN/tunnel types (utun*, tun*, cscotun*, gpd*, zt*, ppp*, ipsec*, etc.) regardless of vendor naming. Stored in `draft.Network_interface`. On Settings open, if the saved value names an interface that is no longer available (VPN disconnected), `draft.Network_interface` is silently reset to `""` so a Save can't persist a broken value. On Save, a changed interface triggers the guide-cache invalidate + rediscover/refresh side effect described under Draft/Save Pattern above, so the new NIC is active immediately. When non-empty:
  - UDP discovery (`HDHRManager.udpDiscoverSync`) binds via `IP_BOUND_IF`+`if_nametoindex`; **automatically skipped for tunnel/point-to-point interfaces** (`isPointToPointInterface()` check) since tunnels don't support broadcast — known-hosts (saved device IPs) handles remote device lookup
  - curl recordings get `--interface <name>` appended to args
  - URLSession HTTP requests rely on OS routing — correct for VPN since the VPN routes the remote subnet through the tunnel automatically
  - Leave on Auto for single-NIC setups.
- **Dock icon** — `Picker`: Auto (default) / Always / Never, bound to `draft.Dock_icon_mode`. "Auto" starts the app with a Dock icon (`.regular` activation policy) until `AppState.confirmLocalNetworkAccessIfNeeded()` sees a real lineup fetch succeed, then hides it (`.accessory`) — a mitigation for a macOS bug where a background-only (`LSUIElement`) process may never receive the system's Local Network permission prompt at all (see `TODO.md`'s "Show Stoppers" entry). "Always"/"Never" apply immediately on Save (`SettingsView.applyAndSave()`), not just next launch. `AppConfig.Local_network_confirmed` (the flag driving "auto") is internal/not user-facing.
- **App log** — `"Show App Log in Console"` button. Opens Console.app; logs go to OSLog (subsystem `com.hdhr.vcrplus`) **and** `~/Library/Logs/hdhrVCRplus.log`. A selectable filter hint label appears below the button for copy-paste into Console or Terminal (`log stream --level debug --predicate 'subsystem == "com.hdhr.vcrplus"'`).
- **Verbose curl logging** — `Toggle`. Adds `-v` to curl args and pipes curl stderr to its own dedicated file, `~/Library/Logs/hdhrVCRplus-curl.log` (separate from the app log). When enabled, shows the curl log path (selectable text) and a "Show curl log in Finder" button. Log path is `RecordingManager.curlLogPath` (static let, → `curlVerboseLogFilePath`). Rotated at 5 MB (rename to `.1`, not truncate) by `rotateCurlVerboseLogIfNeeded()`, checked once before each new recording session starts.
- **Config file path** — read-only display (`state.configManager.configPath`) + "Show config in Finder" button using `NSWorkspace.shared.selectFile(_:inFileViewerRootedAtPath:)`. Merged into the Logging section (was a standalone Config File section).

**Updates section** (always visible in Advanced):
- **Check for updates automatically** — `Toggle` bound to `draft.Check_for_updates` (default `true`). When on, `AppState.updateCheckLoop()` (started once at app startup, runs for the app's lifetime) calls `checkForUpdateOnce()` immediately and then every 24h. Read-only network check — never downloads or installs anything, just compares versions and surfaces a link. See `UpdateChecker.swift` and the About tab's Update check bullet above.

**Signal Quality section** (always visible in Advanced):
- **Show signal bars in guide** — `Toggle` bound to `draft.Signal_quality_enabled`. When on, `SignalBarsView` appears in cable guide and Watch Now rows. Signal data is **always collected passively** during recordings regardless of this toggle — it only controls display.
- **Send alerts on signal dropout** — `Toggle` bound to `draft.Signal_quality_alert_notify`. When on, sends a system notification and a Discord embed when a recording's SNQ drops below 30% for ~20 seconds and when it recovers. Logging via `glog` is always active.

**Signal Strength Scan section** (only visible when Signal Quality toggle is on):
- Brief description: *"Briefly tunes each channel to measure signal quality. Results are stored and shown as bars in the guide."*
- While scanning: progress label (`"Scanning {GuideName} (N/total)…"`) + `Label` with `antenna.radiowaves.left.and.right` icon + red **Cancel Scan** button.
- At rest: one **Measure Signal: {DeviceID}** button per discovered device. Calls `state.startSignalScan(force: true)` — `force:true` bypasses the `needsSample()` freshness gate so a manual tap always remeasures all channels. Takes 3 SNQ readings at 500 ms intervals (~1.5 s per channel). `flush()` is called after each channel so progress survives a quit. Completed samples are immediately pushed to the web guide via SSE `signal_update`.

---

### Web Server

- **Enable Web Server** — `Toggle` bound to `draft.Web_server_enabled`. Off by default. Warning label: *"Local network access only. No authentication. Do not expose this port to the internet."*
- **Port** — `TextField` (value binding, `.number.grouping(.never)` format to suppress the thousands comma), shown when enabled. Validated 1025–65534. Invalid values show an orange warning and block the Save button and `WindowCloseInterceptor`. Saving restarts the `NWListener` and re-registers mDNS at the new port immediately — no app restart needed.
- **Access row** — shown only when `state.config.Web_server_enabled && state.webServerRunning`. Displays `http://{ip}:{port}` as selectable monospaced text with an **Open** `Link`. IP is resolved by `availableNetworkInterfaces()` filtering out `utun*` VPN interfaces; falls back to `"localhost"`. The link uses the device's IP directly (not an mDNS `.local` hostname) to prevent browser HTTPS upgrades.
- **Error banner** — shown when `state.webServerError` is non-nil (port in use, OS cancellation, etc.).

Saving with changed `Web_server_enabled` or `Web_server_port` calls `state.setupWebServer()` immediately to start, restart, or stop the listener.

See [WebServer.md](WebServer.md) for full route and feature documentation.

---

### Maintenance

One-tap operations for recovering from stuck states. Each uses `maintenanceRow(_:_:action:)` — a helper that takes a title string, a description string, and an async closure that returns a result string. The result is shown in a green `Label` at the bottom of the section after completion.

**Shows section:**
- **Reactivate Paused Shows** — calls `state.reactivatePausedShows()`, setting `show_active = true` on all inactive shows and resetting their fail counts. Result: count of shows reactivated.
- **Rescan Series** — calls `state.rescheduleAllSeries()`, which iterates all active, non-paused, non-recording SeriesID shows, reloads each device's guide if stale, and resets `show_next` to the next matching episode. The count shown in the result excludes currently-recording shows. Result: `"N series show(s) rescheduled"`.
- **Reset Fail Counts** — calls `state.resetAllFailCounts()`, zeroing `show_fail_count` and clearing `show_fail_reason` on every show without touching `show_active`. Useful when shows get stuck in Paused after transient network failures.
- **Organize Series Recordings** — calls `state.organizeSeriesRecordings()`. Scans the flat root of each SeriesID show's recording directory for matching files and moves them into `Title/Season XX/` subfolders (or `Title/` when no season is parseable). Skips files currently being recorded. Updates `show_recording_path` on any show whose file was moved and saves config. Result: `"Moved N file(s) into subfolders"` or `"No files to organize"`.

**Guide & Devices section:**
- **Rediscover Devices** — calls `state.rediscoverDevices()` (same 3-path mDNS+UDP+known-hosts scan as startup). Reports device count.
- **Refresh Guide** — calls `state.refreshGuide()` (invalidate + reload all devices). Reports channel count on completion.
- **Clear Guide Cache** — calls `state.guideStore.invalidateAll()` and clears `state.guideByDevice`. The next time the guide step or floating guide opens, it fetches fresh data.

**Tools section** (only shown when `/usr/local/bin/brew` or `/opt/homebrew/bin/brew` exists):
- **VLC** — `brew install --cask vlc`. Shown as installed (checkmark) via `VLCBridge.locateApp()` (Launch Services bundle-ID lookup, not a hardcoded path — works for Homebrew cask, `~/Applications`, etc). On successful install, `brewStatus` appends "— restart the app to enable Watch Now": `VLCBridge.shared.isAvailable` (which gates the Watch Now buttons) is captured once via `dlopen` at first access, so a VLC install mid-session doesn't retroactively enable them.
- **HDHomeRun CLI** — `brew install libhdhomerun`. Shown as installed when `hdhomerun_config` is on PATH. Not called anywhere else in the app — offered purely as a convenience for the user's own terminal use. Brew output is streamed to a `brewStatus` string shown at the bottom of the section.

**Developer section** — removed (2026-07-23). It offered a "Simulate macOS version" picker (`draftSimulatedOS`/`@AppStorage("simulatedMacOSVersion")`) that had been dead since `CableGuideView`, its one consumer, was removed — the picker changed nothing.

---

### About

- **App logo** — `ZStack`: three `SignalRing` views stacked behind the logo image (or `antenna.radiowaves.left.and.right` fallback). Tapping the logo increments `logoTapCount`; each `SignalRing` reacts via `.task(id: logoTapCount)` — three concentric circles expand and fade, staggered 150 ms apart, producing a broadcast-signal pulse. `SignalRing` is a private `View` struct at file scope; it sets `opacity = 0.6` instantly on trigger, then animates `scale 0.5 → 1.75` and `opacity → 0` with `.easeOut(duration: 0.8)`.
- **App name** — `.largeTitle` bold `"hdhrVCRplus"`
- **Version** — `Text("Version \(appVersion) — Swift/SwiftUI rewrite")`. `appVersion` is a global `let` in `Sources/hdhr_VCR/Version.swift`, generated by `deploy.sh` before each build in the format `YYMMDD-HHMM` (e.g. `260521-2011`).
- **Update check** — below the version line: when `state.updateCheckResult` is non-nil, a bold `Link("Update available: vX.Y.Z", …)` opening the GitHub release page; otherwise, once a check has run this launch, a secondary-colored `"Up to date (checked … ago)"` line. A `"Check for Updates"` button always triggers an immediate check regardless of the Advanced → Updates toggle (see below), which only gates the automatic once-a-day background loop. See `UpdateChecker.swift` — compares `CFBundleShortVersionString` (stamped by `deploy_release.sh` to the real semver; unchanged by ordinary `deploy.sh` dev builds) against GitHub's `releases/latest` API tag, component-wise. Same result also drives an "Update Available" row in the menu bar dropdown (`docs/MenuContent.md`).
- **Registration status** — when `state.config.Donation_unlocked`, a green checkmark ("Registered supporter") plus a selectable `"Code: {Donation_unlock_code}"` line (only shown if a code was actually stored — an install unlocked before this field existed shows just the checkmark); otherwise a secondary-colored "Not yet a registered supporter" line. See [DonationNagView.md](DonationNagView.md).
- **History text** — multi-paragraph description of the app's origin (AppleScript 2016 → Swift rewrite)
- **Changelog** — rendered by `MarkdownView: NSViewRepresentable` (private struct at file scope). Parses via `AttributedString(markdown:options: .init(interpretedSyntax: .full))`, then `MarkdownView.render(_:)` walks each run's `PresentationIntent` (`intent.components`, which runs `[paragraph, listItem(ordinal), unorderedList|orderedList, ...ancestors]` — verified directly against Foundation, not documented by Apple) to reproduce block structure the naive `NSAttributedString(AttributedString)` bridge drops on the floor: `## ` headers get bold/enlarged text on their own line, `- ` list items get a hanging-indent "•\t" bullet (`1. ` ordered items get a real "N.\t" number instead — the immediately-enclosing list's orderedness is read off the list-kind component right after `.listItem` in that chain; nested lists indent further per enclosing list level), consecutive list items get tight single-line spacing while every other block transition gets a blank line, and any run left with no `.foregroundColor` (i.e. everything except markdown links) is filled in with `NSColor.labelColor` so it tracks light/dark mode. Inline styling (bold/italic/inline code/links) still comes through automatically via the per-run `NSAttributedString(AttributedString)` bridge. Displayed in a non-scrollable `NSTextView` (selectable, no background). Height is self-measured via `layoutManager.usedRect(for: textContainer)` after each layout pass and injected as `.frame(height: max(100, changelogHeight))` — the view self-sizes to content. Only sections at or below the running build version are shown; a blue "Update available" banner appears when the fetched changelog has a newer version.
- **GitHub link** — `Link("View on GitHub", destination: URL(...))`

---

## Version Stamping

`Version.swift` is generated by `deploy.sh` with:
```bash
printf 'let appVersion = "%s"\n' "$(date +%y%m%d-%H%M)" > Sources/hdhr_VCR/Version.swift
```

This file should NOT be edited manually. It can be `.gitignore`d, but is currently committed so `swift build` (without running deploy) works. If you need to do a `swift build` without deploying, run `deploy.sh` once or write a placeholder manually: `let appVersion = "000000-0000"`.

---

## `WindowCloseInterceptor`

An `NSViewRepresentable` that attaches an `NSWindowDelegate` to the settings window on `.onAppear`. The coordinator holds mutable `isDirty` and `onSave` values that are updated via `updateNSView` so they stay current across re-renders without recreating the delegate.

```swift
func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard isDirty else { return true }
    let alert = NSAlert()
    if canSave {
        // Normal dirty state: offer Save / Discard / Cancel
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:  onSave(); return true
        case .alertSecondButtonReturn: return true
        default:                       return false
        }
    } else {
        // Validation error blocks saving (untested webhook or invalid port)
        alert.informativeText = "Settings can't be saved yet — fix the validation error first. Discard changes?"
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
```

`canSave` is `!webhookNeedsTest && !webPortInvalid` — false when the Discord webhook is untested **or** the web server port is out of range. The alert message is generic so it applies to either validation failure.

---

## AppConfig Codable Safety

`AppConfig` uses a **custom `init(from:)` decoder** (not synthesized) that uses `try?` with fallback defaults for every field:

```swift
extension AppConfig: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        Notify_recording = (try? c.decode(Double.self, forKey: .Notify_recording)) ?? 15.5
        // ... all fields with try? + default
    }
}
```

This means:
- Old config files missing any field decode cleanly (missing key → default value)
- New fields can be added to `AppConfig` without breaking existing user configs
- `Min_disk_free_gb` handles both `Double` and `Int` JSON types for compatibility with the AppleScript app's JSONHelper format

**Critical**: every time a new field is added to `AppConfig`, it MUST be added to this custom decoder with a default. The synthesized decoder (`Codable` without `init(from:)`) would throw `keyNotFound` on any config file that predates the new field, returning `nil` from `ConfigManager.load()` and silently overwriting the user's config with defaults.

---

## Config File Location

`~/Library/Application Support/hdhrVCRplus/hdhr_VCR-{hostname}.json` where hostname is `ProcessInfo.processInfo.hostName` (e.g. `woodflix.local`).

On first launch after updating from an older build, `ConfigManager` automatically migrates the file from its old location at `~/Documents/hdhr_VCR-{hostname}.json`. The old file is preserved so the original AppleScript app can still read it. This move was necessary because macOS TCC resets `~/Documents` access on every ad-hoc re-sign (`codesign --force --sign -`), causing the app to lose all scheduled shows after each development build.

**Important**: `ProcessInfo.processInfo.hostName` is used — NOT `Host.current().localizedName`. On macOS 26, `localizedName` returns the display name (`"Mac mini"`) instead of nil, causing the config filename to change and all user data to appear lost. Using `processInfo.hostName` avoids this regression.

A `.json.bak` backup is written before each save. The config format is shared with the original AppleScript app (`hdhr_VCR-AS`).

---

## What Still Needs Doing

- **No per-show overrides** — all recording settings (transcode, Bonus Time, fail threshold) apply globally. A useful future feature would be per-show overrides: "this show always transcodes to Mobile" or "this show gets 60 minutes of Bonus Time."

- **Bonus Time label clarity** — the stepper says "Bonus Time: 30 min" with no inline context. The `.help()` tooltip explains it, but a visible note like "(past guide end)" in the label itself would clarify without requiring hover.

- **No export/import of config** — power users who manage multiple machines have no UI for this. The config JSON is in `~/Documents/` and can be copied manually, but "Export config…" / "Import config…" buttons in Advanced would be user-friendly.

- **No per-show Discord overrides** — Discord toggles apply globally. A per-show "notify on complete" checkbox would require adding fields to `Show`.

- **Version stamp only on deploy** — running `swift build` directly won't update `Version.swift`. A Xcode pre-build phase or Swift Package Manager build plugin would make the version always current.

- **Settings window size is fixed** — `560×520` is hardcoded. On smaller displays this can crowd the form content.
