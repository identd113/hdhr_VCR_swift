# AppState.swift — App Logic & Data Flow

`@MainActor ObservableObject`. All app state lives here. `hdhr_VCRApp` injects it as an `@EnvironmentObject`.

---

## Startup (`AppState.startup`)

1. Sparkle `SPUStandardUpdaterController` initialized (`startingUpdater: true`) — begins background update checks immediately. Deferred to `startup()` (not a stored property) so tests that set `skipStartup = true` never trigger updater UI.
2. `loadConfig()` — reads JSON, resets all `show_recording = false`. Auto-removes inactive Single shows (already recorded; no further scheduling needed).
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
- Refreshes lineup + guide at each clock-hour boundary (`lastRefreshHour` vs current hour; non-blocking `Task`) — aligned with the web UI's 30-minute window slide. On total API failure the next attempt is the next hour boundary; intra-hour retries are handled per-device by `ensureGuideLoaded` backoff.
- **Device probe** — calls `probeForNewDevices()` every 5 minutes to detect new and departing tuners. When any device misses a probe (not seen in discovery response), a 60-second follow-up probe is scheduled (`nextQuickProbe`) so the 3-miss unavailability threshold is reached in ~2–7 minutes rather than 15. The condition `missedProbes <= 3` (inclusive) ensures a follow-up is also scheduled on the tick that crosses the unavailability threshold, keeping recovery detection at 60 s cadence immediately after a device goes offline. The normal 5-minute cycle is unaffected by quick probes.
- Per active show:
  - Fires "Up Next" notification once at `Notify_upnext` minutes before; stamps `notify_upnext_time`.
  - Fires "Recording Soon" notification once at `Notify_recording` minutes before; stamps `notify_recording_time`.
  - Starts recording if `show_next <= now + 10s` AND `show_end > now` AND the show isn't in its post-failure retry cooldown (`showRetryAfter[show_id]`, see below).
  - Stops recording naturally if `show_end <= now`.
  - **Stranded show advance**: if `!show_recording && show_end <= now && show_next < now`, calls `scheduleNextAir` immediately. Handles the case where the app restarted after curl exited normally but before the idle loop fired the natural-stop handler (which requires `show_recording == true`). Logs `"stranded show_next in past — advancing"`.
  - Detects unexpected curl exit → reads `X-HDHomeRun-Error` from the curl header dump via `RecordingManager.readAndClearHDHRError` (precise device error code, e.g. "Tuner In Use (804)"), falls back to `"curl exited unexpectedly"` if no header was written; clears `show_tuner_resource`; calls `recordShowFailure(index:reason:)`, sends notification.
  - Fires Discord progress update (PATCH) once per 5-minute boundary for active recordings when `Discord_on_progress` is enabled and `discord_start_msg_id` is set.
- Conflict notifications: when a show can't start because all tuners are full, fires once per show+episode window (`conflictNotifiedEpochs: [String: TimeInterval]` — keyed by `show_id`, value is `show_next` epoch; clears on reschedule via `removeValue(forKey:)`).
- Calls `captureResourceHeaders()` then `fetchDeviceStatus(for:)` once per device (via `refreshTunerOccupancy`). `captureResourceHeaders` reads `X-HDHomeRun-Resource` from the curl header dump for any recording show whose `show_tuner_resource` is still empty — stores e.g. `"tuner0"` directly on the show. `fetchDeviceStatus` uses this value first when targeting `/tunerN/vstatus`; falls back to VctNumber channel match, then any locked tuner. Logs a warning if no locked tuner is found at all.
- **Tuner audit**: after storing `deviceTunerOccupancy`, `fetchDeviceStatus` logs `[TunerAudit] DEVID: N/M active  rec=N vlc=N` every tick — `active` is the raw count of locked tuners from `status.json`, `rec` is `recordingShows.filter { hdhr_record == device.DeviceID }.count`, and `vlc` is 1 when `VLCPlayerWindowManager.shared.currentDeviceID` matches this device. Unexpected tuner usage (e.g. a leak after a delete) is immediately visible in the log.
- **NowAiring log**: at the end of each idle tick, iterates all guide entries that are currently on-air (`StartTime <= now < EndTime`). For entries with no genre tag (`firstGenre == nil`) and a SeriesID not in the known paid-programming set (`C11809220ENAPZK`, `C459763EN3L6D`), logs `[NowAiring] {ch} {guideName} — {title} SeriesID={sid}`, once per (channelNum, StartTime) slot (tracked in `loggedNowAiring: Set<String>`). Used to discover new infomercial SeriesIDs for the web guide's hidden-by-default filter.

### Recording Failure Retry Backoff

Every `recordFailure` call site (curl exit, no stream URL, disk full, launch error, empty output file) is routed through the private `recordShowFailure(index:reason:)` helper instead of calling `Show.recordFailure(reason:)` directly. It increments `show_fail_count` as before, then starts a cooldown in `showRetryAfter: [String: Date]` (keyed by `show_id`, not persisted) so the idle loop's `readyIndices` filter skips the show until the cooldown expires — without this, a show would retry every `Idle_timer_interval` tick (default 10s) and burn through `Fail_count_setting` in well under a minute.

The cooldown length escalates with consecutive failures, expressed in idle-loop ticks rather than wall-clock time (`static let retryBackoffLoops: [Int] = [2, 3]`, indexed by `show_fail_count - 1`, clamped to the last entry): the 1st failure waits 2 ticks, the 2nd and any further consecutive failure waits 3 (capped) until `show_fail_count` reaches `Fail_count_setting` and `startRecording` pauses the show. Mirrors the shape of `APIBackoff` above, but tick-based rather than an exponential wall-clock delay.

`showRetryAfter` entries are cleared alongside `clearFailures()` at every call site (idle-loop auto-resume, `resumeShow`, `resetAllFailCounts`, `reactivatePausedShows`) and in `deleteShow`, so a manually-cleared or deleted show never carries a stale cooldown.

---

## Device Discovery (`HDHRManager.discoverDevices`)

Three paths run **concurrently**; results merged by DeviceID:

1. **Known hosts** — extracts IPs from `show_url` fields of saved shows → probes `/discover.json`. Sub-second on stable networks.
2. **mDNS** — `http://hdhomerun.local/discover.json`. Handles single-object or array response.
3. **UDP broadcast** — SiliconDust packet sent to each active network interface's subnet-directed broadcast address (e.g. `10.0.3.255:65001`, computed via `subnetBroadcastAddresses(interface:)`), plus the global `255.255.255.255:65001` as a best-effort fallback; waits 2 s, each reply followed up with `fetchDeviceInfo(ip:)`. Global broadcast alone can silently miss devices on setups with a second default route (Thunderbolt Bridge, Internet Sharing) — the kernel routes it into the dead route (`errno 65`/`EHOSTUNREACH`) even though the device's subnet is reachable; only directed-broadcast `sendto` failures are logged as warnings, since the global-broadcast fallback failing in that scenario is expected.

Falls back to **SiliconDust cloud API** (`http://discover.hdhomerun.com/discover.json`) if all three yield nothing. After merging, devices missing `DeviceAuth` are supplemented from the cloud response (needed for EXTEND devices). Session timeouts: 2 s request / 6 s resource.

### EXTEND device (HDTC-2US)
- Has no local `/guide.json` — uses cloud guide API instead.
- `GuideStore.guideURL(for:hours:)` routes to `https://api.hdhomerun.com/api/guide.php?DeviceAuth=...&Duration=N` (hours) when `DeviceAuth != nil`; otherwise `http://{LocalIP}/guide.json?Duration=N`.
- When `Guide_use_xml = true`, `GuideStore.load(for:useXML:)` routes to `GuideStore.xmltvURL(for:)` → `https://api.hdhomerun.com/api/xmltv?DeviceAuth=...` instead. Local-only devices (no `DeviceAuth`) always use JSON even when the flag is on.
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
| `usableDeviceIDs` | `Set<String>` of DeviceIDs that are discovered AND reachable (`isAvailable == true`). Used by the web guide to determine active vs. inactive tuner boxes. Inactive tuners are dimmed and non-selectable but still listed with their assigned shows. |
| `nextShowMinutes` | Minutes until nearest active show; drives orange `clock.badge` icon when ≤ 30 |
| `availableDeviceCount` | Excludes devices with missing lineup or guide; used in status message |
| `onAirNow(for:at:)` | Returns one `(channel: LineupEntry, entry: GuideEntry)` per unique on-air channel for a device at `date` (default `Date()`), sorted favorites-first then by channel number. Used by `WatchNowView` and `WebServer.buildNowJSON`. |
| `tunersFull(for: deviceId)` | Returns `true` when every tuner on the device is occupied. Delegates to `activeTunerCount(for:)` — `max(status.json hw count, recordings + VLC)` — so it also honors tuners locked by another machine running this app against the same physical device, not just this instance's own recordings. Never count recordings alone — watching and recording occupy tuners equally, *except* watching a recording via the relay. Used by `startRecording`, `WatchNowView`, and `WebServer.handleRecord`. |
| `activeTunerCount(for: deviceId)` | Returns the current active-tuner count for a device as `max(status.json hw count, recordings + VLC)` (same `vlcOccupiesTuner(for:)` helper). Used by `broadcastRecordingEvent` and `pushFreshTunerCounts` to push accurate badge counts to the web guide via SSE. |
| `vlcOccupiesTuner(for: deviceId)` (private) | `true` only when the in-app VLC window is open on this device **and** it isn't playing the recording relay (`VLCBridge.shared.recordingShowId == nil`). Without this distinction, `tunersFull`/`activeTunerCount` would count watching your own in-progress recording via Watch Now! as consuming a tuner it never touches — undermining the entire point of the relay (see `watchRecordingInApp(_:)` and `docs/WebServer.md`). |

---

## Web Server

`webServer: WebServer` — `NWListener`-backed LAN HTTP server (see [WebServer.md](WebServer.md)).

| Property / Method | Description |
|---|---|
| `@Published webServerRunning: Bool` | `true` once NWListener reaches `.ready` state |
| `@Published webServerError: String?` | Non-nil when the listener fails (port in use, OS error, etc.) |
| `setupWebServer()` | Starts, restarts, or stops the server based on `config.Web_server_enabled` and `config.Web_server_port`. Called at step 4 of `startup()` and again whenever Settings saves a changed web server config. |
| `ensureWebServerRunning()` | Increments `internalWebServerUseCount`; starts the server if not already running. Called from `FloatingGuideView.onAppear` and `AddShowView` guide step. |
| `applyWebServerState(_ errorMsg:)` | Private. Shared completion handler used by both `setupWebServer` and `ensureWebServerRunning`. Sets `webServerRunning`/`webServerError` and calls `updateTXTRecord` on success. |
| `releaseInternalWebServer()` | Decrements `internalWebServerUseCount`; stops the server when count reaches 0 **and** `config.Web_server_enabled == false`. Called from `.onDisappear` of the guide WKWebView. Safe to call from multiple concurrent windows — the count prevents stopping the server while another guide window is open. |
| `discordWebDelete(_ show: Show)` | `@MainActor`. Called by `WebServer.handleDelete` before clearing state. Edits the existing "Recording Started" Discord embed in-place (if `discord_start_msg_id` is non-empty) using `Discord_on_start` as the gate — the embed was created under that flag, so the update follows the same preference. No-op when `show_recording == false` or `discord_start_msg_id` is empty. |

The web server is stopped explicitly in all three `quit()` exit branches before `NSApplication.terminate(nil)`.

---

## Guide Helpers

| Method | Description |
|---|---|
| `fetchAllGuides()` | Startup parallel load; stamps `lastRefreshHour` + bumps `guideRevision` only when ≥1 channel loaded (prevents the first idle tick from re-fetching what startup just loaded) |
| `refreshGuides()` | Private; invalidates then reloads all; called from the idle loop at each hour boundary. After reload, calls `rescheduleAllSeries()` so series shows stranded past the guide window get rescheduled as soon as a matching episode appears. |
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
| `startRecording(index:)` | Guards: returns early (with a warning log) if the assigned device is not in `devices` at all, or if it is present but `!isAvailable`. Calls `tunersFull(for:)` to check if all tuner slots are occupied (recordings + VLC); fires a conflict notification once per show+episode window when blocked. Computes `endDate` (show_end ?? show_length fallback, then +bonus padding if active). Always writes `shows[index].show_end = endDate` before launching so the idle-loop natural-stop and notifications both use the final value. When `config.Series_subfolder_enabled` is on and the show is a SeriesID type, looks up the guide entry via `guideEntryForShow(_:)`, parses season from `EpisodeNumber` via `seasonNumber(from:)`, and passes `subfolder: "Title/Season XX"` + `episodeTag: "S02E04"` to `outputPath()`; falls back to `Title/` if no season is parseable. The destination directory (including any new subfolder) is created with `FileManager.createDirectory(withIntermediateDirectories: true)` before curl is launched. Notification and Discord "Ends" field use `endDate`, not the pre-padding `show.show_end`. When `Discord_on_start` is enabled, inserts the show ID into `pendingDiscordStart` — the embed is deferred until the first idle-loop tick confirms curl is alive (see Discord Embed Flow). |
| `updateShow(_ show: Show)` | Replaces the matching show in `shows[]` and saves config. For any active, non-paused, non-recording show whose `state != .single`, fires `scheduleNextAir` immediately via an async Task so type changes (e.g. seriesChannel → seriesAll) and day/time edits take effect without waiting for the idle loop. |
| `pauseShow(_:)` | Sets `show_paused = true`, `show_fail_reason = "Manually paused"`, saves config |
| `resumeShow(_:)` | Clears `show_paused`, resets fail count + reason, saves config |
| `watchInVLC(url:)` | Opens stream in `/Applications/VLC.app` via `NSWorkspace`; no-op if VLC absent or `Watch_in_VLC` false |
| `watchInApp(url:title:deviceId:transcode:guideNumber:)` | Opens VLC in-app player; checks `/status.json` first, alerts if all tuners occupied. If `guideNumber` is supplied, looks up the current guide entry and fires a `"vlc"` sleep assertion via `recordingManager.preventSleep(id:reason:duration:)` sized to the entry's end time + 5-min buffer. |
| `watchRecordingInApp(_ show:)` | Used by `recordingMenu`'s "Watch Now!" instead of `watchInApp` for shows that are **currently recording** — no tuner check, since it doesn't open a device connection. Points VLC at `http://127.0.0.1:{Web_server_port}/api/watch-recording?show={id}&start={offset}` (`WebServer.swift`'s recording-playback relay — see `docs/WebServer.md`), not a plain `file://` URL: VLC's file access module snapshots the file's length at open time and won't read past it as curl keeps appending, so a direct file URL onto a growing recording stalls once playback catches up. Starts ~`recordingLiveEdgeBackoffSeconds` (30s) behind the live edge rather than at byte 0, so Watch Now! lands near "now" like tuning into live TV — the scrub bar can still reach back to the start. Calls `ensureWebServerRunning()` guarded by `recordingRelayActive` so the internal web server stays up for the relay even with the LAN web UI disabled; balanced by `releaseRecordingRelayIfNeeded()` (called from `VLCPlayerWindowManager.playerWindowDidClose()`). Falls back to `watchInApp` (live stream, new tuner) only if the recording file is missing. Exists because port 5004 allocates one tuner per TCP connection with no client-multiplexing, so re-requesting the channel while it's already recording would needlessly cost a second tuner (`docs/HDHRFindings.md`). Sets the scrub-bar anchor (`VLCBridge.beginRecordingSeek`) via `DispatchQueue.main.async` — `VLCPlayerWindowManager.open()` creates the player window and SwiftUI renders its toolbar synchronously inside that same call, before this method's next line would otherwise run; setting the anchor in the same transaction never produced a visible re-render (confirmed live: the state was set correctly, but the toolbar's conditional scrub bar never appeared), so it's posted as a separate main-queue turn instead. Its `alreadyPlaying` dedup check (skip reopening, just `mgr.focus()`) compares `VLCBridge.shared.recordingShowId == show.show_id`, not the relay URL — the URL's `&start=` offset is recomputed from live elapsed time on every call, so comparing full URLs would almost never match even when this exact show is already open. |
| `watchRecordingInVLC(_ show:)` | Same "currently recording" case for the external-VLC path (`Watch_in_VLC` setting). Still uses a plain `file://` URL to `show.show_recording_path` — an app launched via `NSWorkspace` has no reliable close hook to balance the relay's refcount, so it keeps the earlier (file-snapshot-limited) approach rather than risk leaking the internal web server running forever. Falls back to `watchInVLC` if the recording file is missing. |
| `seekRecording(showId:toSeconds:)` | Scrubs the in-app recording-relay player (`VLCPlayerView`'s scrub bar — see `docs/VLCPlayerView.md`). Estimates a byte offset from `(recording file size so far / seconds recorded so far) × targetSeconds`, aligned to a 188-byte TS packet boundary, and reconnects via `VLCBridge.play(url:)` with `&start={offset}` appended to the relay URL — an approximate, non-frame-accurate seek (the raw file has no index) implemented as a full reconnect, not a true in-place seek. Calls `VLCBridge.beginRecordingSeek(showId:recordingStart:seekBaseSeconds:)` afterward so the scrub bar's displayed position tracks the new offset. |
| `seekRecordingToLiveEdge(showId:)` | Backs the toolbar's "catch up" button for a recording-relay session (`VLCPlayerView`'s `catchUpButton`). `VLCBridge.catchUpToLive()` alone just replays the current URL verbatim — for the relay that means reconnecting at the same stale `&start=` byte offset, doing nothing toward "live" despite the button's tooltip. This computes a fresh `elapsed - recordingLiveEdgeBackoffSeconds` target and calls `seekRecording(showId:toSeconds:)`, the same math `watchRecordingInApp` uses on first open. |
| `refreshTunerOccupancy()` | Fires a Task that sleeps 1.5 s, then calls `captureResourceHeaders()` + `fetchDeviceStatus` for every device, then `releaseAssertionsIfIdle()`. Called after recording start/stop, VLC open/close, and channel switch so the menu header count stays current. |
| `releaseAssertionsIfIdle()` | Private. After all devices are checked: if every known tuner reports zero active streams **and** `recordingShows` is empty **and** no VLC session is open, calls `recordingManager.releaseAllAssertions()`. Guards against false-positives during the gap between recording start and tuner lock-in. |
| `captureResourceHeaders()` | Private. For each recording show with empty `show_tuner_resource`, calls `RecordingManager.readHDHRResource` to read `X-HDHomeRun-Resource` from the curl header dump file. Stores result (e.g. `"tuner0"`) on the show for use by `fetchDeviceStatus`. |
| `confirmAndDeleteShow(_:then:)` | Fetches poster async → NSAlert with image → stops recording + removes show |
| `addShowFromGuide(entry:type:device:channel:airDays:transcode:bonusTime:titleOverride:)` | Schedules a show from a guide entry — called by the menu's quick-add and `WebServer.handleRecord` (not the in-app wizard, which goes through `save()` → `addShow`). `airDays: [String]?` — for `dateTime`, overrides the default day-of-week; for `single`, stored as informational metadata only (`show_air_date`), doesn't affect `show_next`. `transcode: String?` — overrides `config.Default_transcode`; `nil` uses the config default. `bonusTime: Bool` — sets `show_bonus_time`. `titleOverride: String?` — applied after the SeriesID episode-suffix-stripping step, so an explicit override always wins verbatim. For `seriesChannel`/`seriesAll`, calls `resolveSeriesAir` to pick the actual channel/air time (see below). |
| `resolveSeriesAir(show:device:isAll:channel:)` | Picks the channel/air time for a new SeriesID(Channel/All) show: currently-airing episode first (so a partially-aired episode records from now), else next upcoming, with a title-match fallback at each step for guide entries missing `SeriesID`. Delegates the actual pick to `guideStore.currentEpisode`/`nextEpisode`, passing `isFavoriteChannel` to break a same-time multi-channel tie toward a favorited channel (see `docs/GuideStore.md`'s "Favorite-Channel Tie-Break"). |
| `isFavoriteChannel(deviceId:channelNum:)` | Looks up `LineupEntry.isFavorite` for a device+channel in `lineups`. Passed as the `preferFavorite` closure to `resolveSeriesAir` and `scheduleNextAir`'s `GuideStore` calls. |
| `rescheduleAllSeries()` | Re-runs `scheduleNextAir` for every active, non-paused, **non-recording** SeriesID show using the current guide cache. Called from `refreshGuides()` and the Settings Rescan Series maintenance action. `scheduleNextAir` applies the same favorite tie-break as `resolveSeriesAir` when re-picking a channel between airings. |
| `testDiscordEvent(_:webhookURL:)` | Sends test embed using real show data; always passes `enabled: true` |
| `runPostRecordingScript(path:show:fileSize:)` | Private. Called from `stopRecording` after file size > 0 is confirmed. Launches `config.Post_recording_script` via `/bin/sh scriptPath filePath` (detached, no-op if path is empty or file missing). Sets `HDHR_PATH`, `HDHR_TITLE`, `HDHR_CHANNEL`, `HDHR_TRANSCODE`, `HDHR_EPISODE` (extracted from filename with `_(S\d+(?:E\d+)?)_` regex), `HDHR_DEVICE`, `HDHR_SERIES`, `HDHR_FILESIZE` env vars. Prepends Homebrew paths to `PATH`. Script exit is logged; non-zero logged as warning. `terminationHandler` runs on an arbitrary thread; `glog()` is safe because it serializes onto a private `DispatchQueue`. |
| `seasonNumber(from:)` | Private. Parses season number from an HDHR `EpisodeNumber` string (`"S02E04"`, `"s01e05"`, `"S03"`) using a single case-insensitive regex `^S(\d+)(?:E\d+)?$`. Returns `nil` for any non-matching string. |
| `organizeSeriesRecordings()` | Public maintenance action. Scans the flat root of each series show's recording directory for `.m2ts`/`.mkv` files and moves them into `Title/Season XX/` subfolders. Skips files currently being recorded (`activePaths`). Returns a human-readable summary string. Does not move files that are already inside a subfolder (flat-root scan only). |
| `formatFileSize(_:)` | Private static; formats bytes as `"X.XX GB"` / `"X.X MB"` / `"X KB"` |

---

## Discord Embed Flow

All recording lifecycle events (failure, start, progress, end) edit the **same Discord message** rather than posting new ones. The shared message ID (`show.discord_start_msg_id`) is the key:

1. **Recording starts** — `startRecording` inserts the show ID into `pendingDiscordStart: Set<String>`. The embed is **not sent immediately** — it is deferred to prevent a ping for recordings that fail in the first few seconds.
2. **First idle-loop confirmation** — on the first tick where `show_recording == true` and `recordingManager.isRunning()` confirms curl is alive, the show ID is removed from `pendingDiscordStart` and `discordRecordingCard` fires "🔴 Recording Started". If a failure card was posted earlier (e.g. a failed prior attempt for the same show), it edits that card; otherwise it creates a new one via `sendDiscordEmbedCapturing` (`?wait=true`), capturing the message ID into `show.discord_start_msg_id`. If curl has already exited before this tick, the start embed is suppressed and only the failure embed is sent.
3. **Failure** (curl exits unexpectedly, no stream URL, disk full, launch error, or empty output file — all five routed through `recordShowFailure(index:reason:)`, see "Recording Failure Retry Backoff" above) — `discordRecordingCard` fires an event-specific embed ("⚠️ Recording Failed", "💾 Recording Skipped", etc). If `discord_start_msg_id` is already set (prior attempt card), it edits that card; otherwise it creates a new one and captures the ID. The ID is **not** cleared — a subsequent retry start will edit this failure card, keeping the entire lifecycle in one Discord message.
4. **Progress update** — the idle loop checks once per 5-minute boundary: if `show_recording && !discord_start_msg_id.isEmpty && Discord_on_progress`, it calls `editDiscordEmbed` with an "⏺ Recording In Progress" embed containing `"Xm elapsed · Ym remaining"`.
5. **Recording ends** — `stopRecording` / file-verify path passes `editMessageId: show.discord_start_msg_id` to `discordShow`, which calls `editDiscordEmbed` (PATCH) instead of `sendDiscordEmbed` (POST). `discord_start_msg_id` is cleared to `""` after the terminal event (complete or paused).

6. **App restart recovery** — `reattachRecordings()` (step 2 of startup) scans for shows with a non-empty `discord_start_msg_id` that were not reattached as actively recording. For each, it sends a recovery embed: "✅ Recording Complete" if `show_recording_path` file has non-zero size, or "⚠️ Recording Interrupted" otherwise. The ID is cleared before the send so a crash during the PATCH doesn't re-trigger on the next launch.

**Helper split**: `discordEffectiveURL(enabled:webhookURL:)` is the shared gate — returns the URL to post to, or `nil` when `enabled` is false, the URL is empty, or `Discord_enabled` is false (for default-webhook calls). `buildDiscordShowEmbed(event:show:color:extra:)` builds the `[String: Any]` embed dict. `discordRecordingCard(showId:event:color:enabled:extra:)` is the central `@MainActor async` helper used by all lifecycle paths — it checks `discord_start_msg_id`: if set, calls `editDiscordEmbed`; otherwise calls `sendDiscordEmbedCapturing` and stores the returned message ID. `discordShow` routes to either `sendDiscordEmbed` or `editDiscordEmbed` based on `editMessageId` and is used by terminal events (stop, web-delete) that also clear the ID. `sendDiscordEmbedCapturing` and `editDiscordEmbed` are free functions in `DiscordNotifier.swift`.

---

## @Published Safety Rule

In a SwiftUI `.menu`-style `MenuBarExtra`, the menu body re-evaluates on every `@Published` change.

**Never assign `guideByDevice = ...` unconditionally after a failed/empty response.** A failed load that assigns `guideByDevice` triggers `didSet → rebuildMenuEntries → @Published changes → re-eval → ...` at ~35ms/loop, freezing the menu. Guards: `ensureGuideLoaded` only assigns when `guideStore.channels(deviceId:)` is non-empty; `guideApiBackoff: [String: APIBackoff]` enforces exponential backoff (1 → 5 → 15 → 30 → 60 min) on failed devices.

`rebuildMenuEntries()` is called from `guideByDevice.didSet` (after every guide load) and from the idle loop (guarded by `menuIsOpen`). It rebuilds: `managedShowBySeriesID`/`managedShowByTitle` (O(1) show lookups for WatchNow + menus), `channelImageURLs` (logo URL map for WatchNow), `menuScheduledEntry`/`menuUpcomingSlots` (pre-computed guide matches for scheduled/paused menus), and `conflictingShowIDs` (one O(N²) conflict pass instead of one per open).

`fetchDeviceStatus(for:)` applies the same guard: writes to `@Published` properties `deviceTunerOccupancy` and `tunerStatus` are skipped entirely while `menuIsOpen`. Signal alerting (Discord notifications, `signalDropoutTicks`, `ChannelSignalStore` recording) still runs unconditionally because it is not display-only. The next idle tick applies the deferred `@Published` updates. The `/tunerN/vstatus` fetch is also skipped while `menuIsOpen` since its only purpose is to update `tunerStatus`.

**Conflict detection** uses `candidateShows = shows.filter { show_active && !show_paused }` — this includes currently-recording shows (`show_recording == true`), unlike `activeShows` which excludes them. A scheduled show that overlaps an already-recording show is therefore correctly flagged. `conflictNotifiedEpochs: [String: TimeInterval]` (keyed by `show_id`, value = `show_next` epoch) is cleared per show on each `scheduleNextAir`, fail-threshold pause, and manual stop — so stale entries don't accumulate across airings.

---

## Show Delete / Skip (`deleteShow`, `skipRecording`)

Both functions call `recordingManager.stop(showId:)` first (sends SIGKILL to curl and releases the show's sleep assertion — see `docs/RecordingManager.md` for why SIGTERM isn't used), then `VLCPlayerWindowManager.shared.closeIfPlaying(showId:url:)` — if the in-app VLC player is currently streaming the deleted/skipped show (matched by relay showId or stream URL) the player window is closed, freeing the tuner.

`deleteShow` removes the show from `shows` and saves config. `skipRecording` additionally marks `show_paused = true`, sets `show_fail_reason = "Skipped"`, and calls `scheduleNextAir` to advance to the next airing.

---

## Quit (`quit()`)

All three exit branches call `VLCBridge.shared.releasePlayer()` before terminating so the in-app player releases its HDHR tuner immediately:

- **No recordings** — `releasePlayer()` → `recordingManager.stopAll()` → `NSApplication.terminate(nil)`
- **Keep Recording & Quit** — `releasePlayer()` → `NSApplication.terminate(nil)` (curl orphaned to launchd; reattach on relaunch via `reattachRecordings()`)
- **Stop Recordings & Quit** — `releasePlayer()` → `recordingManager.stopAll()` → `NSApplication.terminate(nil)`
