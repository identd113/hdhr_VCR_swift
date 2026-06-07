# AppState.swift — App Logic & Data Flow

`@MainActor ObservableObject`. All app state lives here. `hdhr_VCRApp` injects it as an `@EnvironmentObject`.

---

## Startup (`AppState.startup`)

1. Sparkle `SPUStandardUpdaterController` initialized (`startingUpdater: true`) — begins background update checks immediately. Deferred to `startup()` (not a stored property) so tests that set `skipStartup = true` never trigger updater UI.
2. `loadConfig()` — reads JSON, resets all `show_recording = false`; sets `guideStore.verbose`. Auto-removes inactive Single shows (already recorded; no further scheduling needed).
3. `reattachRecordings()` — scans `ps -Axo pid,args` for lines containing `show_id:` + `/usr/bin/curl` + `hdhrVCRplus`. If the matching show's `show_end` is still future, sets `show_recording = true`, clears `show_tuner_resource` (will be re-captured by `captureResourceHeaders`), and calls `recordingManager.reattach(showId:pid:title:endDate:)` — recording continues uninterrupted and the sleep assertion is re-armed for the remaining duration. **Read pipe data before `waitUntilExit()`** to avoid deadlock when ps output exceeds the ~64 KB pipe buffer. After the PID scan, any show that has a non-empty `discord_start_msg_id` but was **not** reattached (i.e. its recording ended while the app was down) gets a recovery Discord embed: "✅ Recording Complete" if the output file has non-zero size, or "⚠️ Recording Interrupted" otherwise. The `discord_start_msg_id` is cleared to `""` in config **before** the network send — a crash during the PATCH won't re-trigger the recovery on the next launch.
4. `setupWebServer()` — binds the NWListener on `config.Web_server_port` immediately after config load, before device discovery. Port is available within ~1 s of launch; responses that require guide data are delayed by main-actor availability, not by the startup sequence itself.
5. Notification permission (background `Task` — non-blocking).
6. `discoverDevices(knownHosts:attempts:10)` — up to 10 retries with 1 s pauses; idle loop retries on each tick if devices remain empty.
7. `fetchAllGuides()` — parallel guide load for all devices; mirrors result into `guideByDevice`.
8. `startTimer()` — fires `idleLoop()` every `config.Idle_timer_interval` seconds (default 10, min 5).
9. Sets `isStartingUp = false` (menu bar icon switches from dimmed to normal/red-dot).

---

## Idle Loop (`AppState.idleLoop`)

Runs every `config.Idle_timer_interval` seconds on MainActor:

- If `devices` is empty → retries discovery immediately.
- If guide channels missing for any device → calls `ensureGuideLoaded(for:)`.
- Refreshes lineup + guide every `max(3600, GuideHours × 1800)` seconds (non-blocking `Task`).
- **Device probe** — calls `probeForNewDevices()` every 5 minutes to detect new and departing tuners. When any device misses a probe (not seen in discovery response), a 60-second follow-up probe is scheduled (`nextQuickProbe`) so the 3-miss unavailability threshold is reached in ~2–7 minutes rather than 15. The normal 5-minute cycle is unaffected by quick probes.
- Per active show:
  - Fires "Up Next" notification once at `Notify_upnext` minutes before; stamps `notify_upnext_time`.
  - Fires "Recording Soon" notification once at `Notify_recording` minutes before; stamps `notify_recording_time`.
  - Starts recording if `show_next <= now + 10s` AND `show_end > now`.
  - Stops recording naturally if `show_end <= now`.
  - Detects unexpected curl exit → reads `X-HDHomeRun-Error` from the curl header dump via `RecordingManager.readAndClearHDHRError` (precise device error code, e.g. "Tuner In Use (804)"), falls back to `"curl exited unexpectedly"` if no header was written; clears `show_tuner_resource`; increments fail count, sends notification.
  - Fires Discord progress update (PATCH) once per 5-minute boundary for active recordings when `Discord_on_progress` is enabled and `discord_start_msg_id` is set.
- Conflict notifications: when a show can't start because all tuners are full, fires once per show+episode window (`conflictNotifiedEpochs: [String: TimeInterval]` — keyed by `show_id`, value is `show_next` epoch; clears on reschedule via `removeValue(forKey:)`).
- Calls `captureResourceHeaders()` then `fetchDeviceStatus(for:)` once per device (via `refreshTunerOccupancy`). `captureResourceHeaders` reads `X-HDHomeRun-Resource` from the curl header dump for any recording show whose `show_tuner_resource` is still empty — stores e.g. `"tuner0"` directly on the show. `fetchDeviceStatus` uses this value first when targeting `/tunerN/vstatus`; falls back to VctNumber channel match, then any locked tuner. Logs a warning if no locked tuner is found at all.
- **Tuner audit**: after storing `deviceTunerOccupancy`, `fetchDeviceStatus` logs `[TunerAudit] DEVID: N/M active  rec=N vlc=N` every tick — `active` is the raw count of locked tuners from `status.json`, `rec` is `recordingShows.filter { hdhr_record == device.DeviceID }.count`, and `vlc` is 1 when `VLCPlayerWindowManager.shared.currentDeviceID` matches this device. Unexpected tuner usage (e.g. a leak after a delete) is immediately visible in the log.

---

## Device Discovery (`HDHRManager.discoverDevices`)

Three paths run **concurrently**; results merged by DeviceID:

1. **Known hosts** — extracts IPs from `show_url` fields of saved shows → probes `/discover.json`. Sub-second on stable networks.
2. **mDNS** — `http://hdhomerun.local/discover.json`. Handles single-object or array response.
3. **UDP broadcast** — SiliconDust packet to `255.255.255.255:65001`, waits 2 s; each reply followed up with `fetchDeviceInfo(ip:)`.

Falls back to **SiliconDust cloud API** (`http://discover.hdhomerun.com/discover.json`) if all three yield nothing. After merging, devices missing `DeviceAuth` are supplemented from the cloud response (needed for EXTEND devices). Session timeouts: 2 s request / 6 s resource.

### EXTEND device (HDTC-2US)
- Has no local `/guide.json` — uses cloud guide API instead.
- `GuideStore.guideURL(for:hours:)` routes to `https://api.hdhomerun.com/api/guide.php?DeviceAuth=...&Duration=N` (hours) when `DeviceAuth != nil`; otherwise `http://{LocalIP}/guide.json?Duration=N`.
- mDNS response omits `LocalIP`; extracted from `BaseURL` host in `HDHRDevice.init(from:)`.
- Local `/discover.json` may omit `DeviceAuth` on some firmware; startup retry + mDNS/cloud discovery recovers.

---

## Computed Properties

| Property | Description |
|---|---|
| `isRecording` | Any show has `show_recording == true` |
| `recordingShows` | Recording and `show_end > now` |
| `activeShows` | `show_active && !show_recording && !show_paused`, sorted by `show_next` |
| `pausedShows` | `show_active && show_paused` |
| `inactiveShows` | `!show_active` (completed singles; auto-removed at startup) |
| `unavailableDeviceIDs` | `Set<String>` of DeviceIDs whose `isAvailable == false` (missedProbes ≥ 3) |
| `unavailableDeviceShows` | Active shows (recording or scheduled) whose `hdhr_record` is in `unavailableDeviceIDs` |
| `nextShowMinutes` | Minutes until nearest active show; drives orange `clock.badge` icon when ≤ 30 |
| `availableDeviceCount` | Excludes devices with missing lineup or guide; used in status message |
| `onAirNow(for:at:)` | Returns one `(channel: LineupEntry, entry: GuideEntry)` per unique on-air channel for a device at `date` (default `Date()`), sorted favorites-first then by channel number. Used by `WatchNowView` and `WebServer.buildNowJSON`. |
| `tunersFull(for: deviceId)` | Returns `true` when every tuner on the device is occupied. Counts **both** active recordings (`recordingShows`) and the in-app VLC stream (`VLCPlayerWindowManager.shared.currentDeviceID`). Use this — never count recordings alone — because watching and recording occupy tuners equally. Used by `startRecording` and `WatchNowView`. |

---

## Web Server

`webServer: WebServer` — `NWListener`-backed LAN HTTP server (see [WebServer.md](WebServer.md)).

| Property / Method | Description |
|---|---|
| `@Published webServerRunning: Bool` | `true` once NWListener reaches `.ready` state |
| `@Published webServerError: String?` | Non-nil when the listener fails (port in use, OS error, etc.) |
| `setupWebServer()` | Starts, restarts, or stops the server based on `config.Web_server_enabled` and `config.Web_server_port`. Called at step 4 of `startup()` and again whenever Settings saves a changed web server config. |
| `ensureWebServerRunning()` | Increments `internalWebServerUseCount`; starts the server if not already running. Called from `FloatingGuideView.onAppear` and `AddShowView` guide step. |
| `releaseInternalWebServer()` | Decrements `internalWebServerUseCount`; stops the server when count reaches 0 **and** `config.Web_server_enabled == false`. Called from `.onDisappear` of the guide WKWebView. Safe to call from multiple concurrent windows — the count prevents stopping the server while another guide window is open. |
| `discordWebDelete(_ show: Show)` | `@MainActor`. Called by `WebServer.handleDelete` before clearing state. Edits the existing "Recording Started" Discord embed in-place (if `discord_start_msg_id` is non-empty) using `Discord_on_start` as the gate — the embed was created under that flag, so the update follows the same preference. No-op when `show_recording == false` or `discord_start_msg_id` is empty. |

The web server is stopped explicitly in all three `quit()` exit branches before `NSApplication.terminate(nil)`.

---

## Guide Helpers

| Method | Description |
|---|---|
| `fetchAllGuides()` | Startup parallel load; sets `lastGuideRefresh` only when ≥1 channel loaded |
| `refreshGuides()` | Private; invalidates then reloads all; called periodically from idle loop. After reload, calls `rescheduleAllSeries()` so series shows stranded past the guide window get rescheduled as soon as a matching episode appears. |
| `ensureGuideLoaded(for deviceId:)` | Loads a device if channels absent and not already loading; safe to call repeatedly |
| `ensureLineupLoaded(for device:)` | Re-fetches lineup if nil/empty; called at guide-step open in AddShowView + FloatingGuideView |
| `guideEntries(deviceId:channelNum:)` | Delegates to `guideStore.entries()` |
| `handleGuideLoadFailure(deviceId:)` | Private. Records backoff failure + sends notify/Discord embed on first failure per streak; subsequent retries are silent. Called from `refreshGuides` and `ensureGuideLoaded`. |
| `nextGuideEpisode(for show:)` | Delegates to `guideStore.nextEpisode()`; respects channel/device filters |
| `upcomingGuideEpisodes(seriesID:after:limit:)` | Up to `limit` upcoming `(channel, entry)` tuples across all devices |
| `nextDateTimeOccurrences(for:after:count:)` | Returns up to `count` DateTime occurrences after `after`. Pass `after: Date()` to include today's airing (menu display); pass `after: startOfTomorrow` to skip today (rescheduling after a completed recording). Uses modulo arithmetic over air-day indices. |
| `nextDateTime(for:)` | One-liner wrapper — calls `nextDateTimeOccurrences(for:after:startOfTomorrow, count:1).first`. Always skips today so a completed recording never re-schedules to the same day. |

---

## Show Actions

| Method | Description |
|---|---|
| `startRecording(index:)` | Guards: returns early (with a warning log) if the assigned device is not in `devices` at all, or if it is present but `!isAvailable`. This prevents burning the show's fail count against a dead tuner. Computes `endDate` (show_end ?? show_length fallback, then +bonus padding if active). Always writes `shows[index].show_end = endDate` before launching so the idle-loop natural-stop and notifications both use the final value. Notification and Discord "Ends" field use `endDate`, not the pre-padding `show.show_end`. When `Discord_on_start` is enabled, inserts the show ID into `pendingDiscordStart` — the embed is deferred until the first idle-loop tick confirms curl is alive (see Discord Embed Flow). |
| `updateShow(_ show: Show)` | Replaces the matching show in `shows[]` and saves config. For any active, non-paused, non-recording show whose `state != .single`, fires `scheduleNextAir` immediately via an async Task so type changes (e.g. seriesChannel → seriesAll) and day/time edits take effect without waiting for the idle loop. |
| `pauseShow(_:)` | Sets `show_paused = true`, `show_fail_reason = "Manually paused"`, saves config |
| `resumeShow(_:)` | Clears `show_paused`, resets fail count + reason, saves config |
| `watchInVLC(url:)` | Opens stream in `/Applications/VLC.app` via `NSWorkspace`; no-op if VLC absent or `Watch_in_VLC` false |
| `watchInApp(url:title:deviceId:transcode:guideNumber:)` | Opens VLC in-app player; checks `/status.json` first, alerts if all tuners occupied. If `guideNumber` is supplied, looks up the current guide entry and fires a `"vlc"` sleep assertion via `recordingManager.preventSleep(id:reason:duration:)` sized to the entry's end time + 5-min buffer. |
| `refreshTunerOccupancy()` | Fires a Task that sleeps 1.5 s, then calls `captureResourceHeaders()` + `fetchDeviceStatus` for every device, then `releaseAssertionsIfIdle()`. Called after recording start/stop, VLC open/close, and channel switch so the menu header count stays current. |
| `releaseAssertionsIfIdle()` | Private. After all devices are checked: if every known tuner reports zero active streams **and** `recordingShows` is empty **and** no VLC session is open, calls `recordingManager.releaseAllAssertions()`. Guards against false-positives during the gap between recording start and tuner lock-in. |
| `captureResourceHeaders()` | Private. For each recording show with empty `show_tuner_resource`, calls `RecordingManager.readHDHRResource` to read `X-HDHomeRun-Resource` from the curl header dump file. Stores result (e.g. `"tuner0"`) on the show for use by `fetchDeviceStatus`. |
| `confirmAndDeleteShow(_:then:)` | Fetches poster async → NSAlert with image → stops recording + removes show |
| `addShowFromGuide(entry:type:device:channel:airDays:transcode:)` | Schedules a show from a guide entry. `airDays: [String]?` — when supplied (web record modal), overrides the default day-of-week for `dateTime` shows. `transcode: String?` — when supplied (web record modal), overrides `config.Default_transcode`; `nil` uses the config default. Called by both the Mac guide wizard and `WebServer.handleRecord`. |
| `rescheduleAllSeries()` | Re-runs `scheduleNextAir` for every active, non-paused, **non-recording** SeriesID show using the current guide cache. Called from `refreshGuides()` and the Settings Rescan Series maintenance action. |
| `testDiscordEvent(_:webhookURL:)` | Sends test embed using real show data; always passes `enabled: true` |
| `formatFileSize(_:)` | Private static; formats bytes as `"X.XX GB"` / `"X.X MB"` / `"X KB"` |

---

## Discord Embed Flow

Recording lifecycle embeds edit the original "Recording Started" message in-place rather than posting new messages:

1. **Recording starts** — `startRecording` inserts the show ID into `pendingDiscordStart: Set<String>`. The embed is **not sent immediately** — it is deferred to prevent a ping for recordings that fail in the first few seconds.
2. **First idle-loop confirmation** — on the first tick where `show_recording == true` and `recordingManager.isRunning()` confirms curl is alive, the show ID is removed from `pendingDiscordStart` and `sendDiscordEmbedCapturing` (async `Task`) fires the "🔴 Recording Started" embed. Discord echoes the created message (`?wait=true`); the message ID is stored in `show.discord_start_msg_id`. If curl has already exited before this tick, the start embed is suppressed and only the failure embed is sent.
3. **Progress update** — the idle loop checks once per 5-minute boundary: if `show_recording && !discord_start_msg_id.isEmpty && Discord_on_progress`, it calls `editDiscordEmbed` with an "⏺ Recording In Progress" embed containing `"Xm elapsed · Ym remaining"`.
4. **Recording ends** — `stopRecording` / file-verify path passes `editMessageId: show.discord_start_msg_id` to `discordShow`, which calls `editDiscordEmbed` (PATCH) instead of `sendDiscordEmbed` (POST). `discord_start_msg_id` is cleared to `""` after.

5. **App restart recovery** — `reattachRecordings()` (step 2 of startup) scans for shows with a non-empty `discord_start_msg_id` that were not reattached as actively recording. For each, it sends a recovery embed: "✅ Recording Complete" if `show_recording_path` file has non-zero size, or "⚠️ Recording Interrupted" otherwise. The ID is cleared before the send so a crash during the PATCH doesn't re-trigger on the next launch.

**Helper split**: `buildDiscordShowEmbed(event:show:color:extra:)` builds the `[String: Any]` embed dict (author, title, description, fields, thumbnail, footer). `discordShow` wraps it with guard checks and routes to either `sendDiscordEmbed` or `editDiscordEmbed` based on `editMessageId`. `sendDiscordEmbedCapturing` and `editDiscordEmbed` are free functions in `DiscordNotifier.swift`.

---

## @Published Safety Rule

In a SwiftUI `.menu`-style `MenuBarExtra`, the menu body re-evaluates on every `@Published` change.

**Never assign `guideByDevice = ...` unconditionally after a failed/empty response.** A failed load that assigns `guideByDevice` triggers `didSet → rebuildMenuEntries → @Published changes → re-eval → ...` at ~35ms/loop, freezing the menu. Guards: `ensureGuideLoaded` only assigns when `guideStore.channels(deviceId:)` is non-empty; `guideApiBackoff: [String: APIBackoff]` enforces exponential backoff (1 → 5 → 15 → 30 → 60 min) on failed devices.

`rebuildMenuEntries()` is called from `guideByDevice.didSet` (after every guide load) and from the idle loop (guarded by `menuIsOpen`). It rebuilds: `managedShowBySeriesID`/`managedShowByTitle` (O(1) show lookups for WatchNow + menus), `channelImageURLs` (logo URL map for WatchNow), `menuScheduledEntry`/`menuUpcomingSlots` (pre-computed guide matches for scheduled/paused menus), and `conflictingShowIDs` (one O(N²) conflict pass instead of one per open).

`fetchDeviceStatus(for:)` applies the same guard: writes to `@Published` properties `deviceTunerOccupancy` and `tunerStatus` are skipped entirely while `menuIsOpen`. Signal alerting (Discord notifications, `signalDropoutTicks`, `ChannelSignalStore` recording) still runs unconditionally because it is not display-only. The next idle tick applies the deferred `@Published` updates. The `/tunerN/vstatus` fetch is also skipped while `menuIsOpen` since its only purpose is to update `tunerStatus`.

**Conflict detection** uses `candidateShows = shows.filter { show_active && !show_paused }` — this includes currently-recording shows (`show_recording == true`), unlike `activeShows` which excludes them. A scheduled show that overlaps an already-recording show is therefore correctly flagged. `conflictNotifiedEpochs: [String: TimeInterval]` (keyed by `show_id`, value = `show_next` epoch) is cleared per show on each `scheduleNextAir`, fail-threshold pause, and manual stop — so stale entries don't accumulate across airings.

---

## Show Delete / Skip (`deleteShow`, `skipRecording`)

Both functions call `recordingManager.stop(showId:)` first (sends SIGTERM to curl and releases the show's sleep assertion), then `VLCPlayerWindowManager.shared.closeIfPlayingURL(show.show_url)` — if the in-app VLC player is currently streaming the deleted/skipped show's URL the player window is closed, freeing the tuner.

`deleteShow` removes the show from `shows` and saves config. `skipRecording` additionally marks `show_paused = true`, sets `show_fail_reason = "Skipped"`, and calls `scheduleNextAir` to advance to the next airing.

---

## Quit (`quit()`)

All three exit branches call `VLCBridge.shared.stop()` before terminating so the in-app player releases its HDHR tuner immediately:

- **No recordings** — `VLCBridge.stop()` → `recordingManager.stopAll()` → `NSApplication.terminate(nil)`
- **Keep Recording & Quit** — `VLCBridge.stop()` → `NSApplication.terminate(nil)` (curl orphaned to launchd; reattach on relaunch via `reattachRecordings()`)
- **Stop Recordings & Quit** — `VLCBridge.stop()` → `recordingManager.stopAll()` → `NSApplication.terminate(nil)`
