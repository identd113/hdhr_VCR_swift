# Resolved Issues

Historical record of bugs that were found and fixed. Split out from `ISSUES.md` on 2026-08-10 to keep that file focused on what's still open or accepted-as-is — this file is the "how was X fixed before" reference, not something you need to read to know current state.

Every entry below was re-verified against the current codebase on 2026-08-10 before being filed here (see the staleness-check note at the end for what that turned up).

---

# Full-source review — 2026-07-17

A 5-way whole-file correctness sweep of all `Sources/` files (not just the recent diff). Crasher + all four medium findings fixed this pass.

## RESOLVED — `GuideHours == 0` in a corrupt config crashes the app on every page render (division by zero)

**File:** `Models.swift` — `AppConfig.init(from:)`; trap surfaces in `WebServer.pct()`

**Root cause**: The decoder clamped only the upper bound (`min(28, decode ?? 24)`). A hand-edited/corrupt `hdhr_VCR-{hostname}.json` with `"GuideHours":0` decodes to 0, so `winSec = GuideHours*3600 = 0`, and `pct()` does `offset * 1_000_000 / winSec` → Swift integer division-by-zero trap → process abort at startup (`prebuildPageHTML`) and on every `GET /`.

**Resolution**: Clamp both ends — `max(1, min(28, …))`. The Settings stepper already enforces 1…28; this guards the corrupt/hand-edited config path.

**Resolving commit**: pending (uncommitted at time of writing)

## RESOLVED — Web server torn down out from under an in-use holder (Settings toggle-off / Add-Show close)

**File:** `AppState.swift` — `setupWebServer()`; `Views/AddShowView.swift` — `onAppear`/`onDisappear`

**Root cause**: Two refcount-imbalance bugs on the internal web-server use-count. (1) `setupWebServer()`'s disable branch called `webServer.stop()` unconditionally, ignoring `internalWebServerUseCount` — flipping the Settings toggle off killed an in-app guide WKWebView or a Watch-Now-from-disk relay still holding a use-count. (2) `AddShowView.onDisappear` always released, but `onAppear` only acquired on the guide path (not the `pendingAddEntry` "straight to details" path, which can still navigate Back to the guide) — an unbalanced release that could underflow the count and stop the server for another holder.

**Resolution**: `setupWebServer` disable branch now stops only when `internalWebServerUseCount == 0` (mirrors `releaseInternalWebServer`). `AddShowView.onAppear` now calls `ensureWebServerRunning()` on every entry path so the unconditional release stays balanced.

**Resolving commit**: pending (uncommitted at time of writing)

## RESOLVED — Blocking `waitpid` on the main actor can freeze the menu-bar UI

**File:** `RecordingManager.swift` — `stop(showId:)`

**Root cause**: `RecordingManager` is `@MainActor`; `stop()` reaped the killed curl with a blocking `waitpid(pid, nil, 0)`. SIGKILL can't be delivered while the target is in an uninterruptible (D-state) syscall — e.g. curl blocked writing to a stalled network mount, a valid recording target — so the wait (and `stopAll()`, which loops it) beachballs the UI until the mount recovers.

**Resolution**: Clear `pids[showId]` first, then reap on a detached background queue (`DispatchQueue.global(qos:.utility).async { waitpid(pid,nil,0) }`). Safe because `isRunning()` guards on `pids`, so no other waitpid site can touch the pid again.

**Resolving commit**: pending (uncommitted at time of writing)

## RESOLVED — Corruption auto-catch-up rewinds a recording-relay session

**File:** `VLCBridge.swift` — `tickController()`

**Root cause**: On a demux-corruption spike the tick called `catchUpToLive()` unconditionally, which replays `currentURL` verbatim. A recording-relay URL carries a fixed `&start=<byteOffset>`, so reconnecting at that anchor yanked playback *backward* to the last seek, discarding progress. The manual catch-up button already special-cases relays (routes to `seekRecordingToLiveEdge`); the auto path did not.

**Resolution**: `guard recordingShowId == nil else { return }` before the corruption threshold — the user is deliberately behind live while watching an in-progress recording, so auto catch-up doesn't apply to relays.

**Resolving commit**: pending (uncommitted at time of writing)

## RESOLVED — `libvlc_Ended` (state 6) unhandled — player freezes on last frame, timer polls forever

**File:** `VLCBridge.swift` — `tickController()`; `Views/VLCPlayerView.swift`

**Root cause**: `tickController` handled only state 7 (Error) and 3 (Playing). On EOF (state 6 — a finished recording relay read to its last byte, or a live source closing) `isPlaying` stayed true and the 3s stats timer kept polling a stopped player forever, with the video frozen on the last frame and no indication.

**Resolution**: Handle state 6 → publish new `hasEnded`, set `isPlaying=false`, stop the stats timer; reset `hasEnded` in `play()`/`stopAndClearState()`. `VLCPlayerView` shows a "Playback Ended" overlay with a Play-Again button, gated like the error overlay.

**Resolving commit**: pending (uncommitted at time of writing)

## RESOLVED — Deferred low-severity findings from the 2026-07-17 sweep

Verified real, deferred by scope decision at the time (crasher + medium fixed then; these logged for a later pass). Re-verified each against current code before fixing, as part of a pre-release pass — all seven still applied unchanged.

- **`ChannelIconCache.swift:29,48`** — disk cache keyed by `URL.lastPathComponent` only; two logo URLs sharing a basename (or both hitting the `"icon.png"` default) collided → wrong channel logo after a restart, and `countMissing` under-counted so it was never re-fetched. **Fixed**: keys the on-disk file by a SHA256 hash of the full URL (extension preserved). Invalidates the existing disk cache once (harmless re-download).
- **`EditShowView.swift:149`** — Save button had no `.disabled` gate and Title had no non-empty check; a user could clear the title or type a non-existent channel (free-text field) and save a show that never records correctly. **Fixed**: added a `canSave` gate (non-empty title + channel-in-lineup, falling back to a bare non-empty check when the device's lineup isn't currently known so editing a show on a temporarily offline tuner isn't blocked), wired through the Save button and both close-time "Unsaved Changes" alert paths.
- **`AddShowView.swift:266`** — `canAdvance` for `.details` didn't check `airDays`; a DateTime (recurring) show with all days deselected saved and never fired. **Fixed**: requires `!airDays.isEmpty` when `seriesType == .dateTime`.
- **`AppState.swift:483`** — `probeForNewDevices()` had no reentrancy guard and was launched detached from the idle loop; if `discoverDevices` ran longer than the probe interval, two runs could each capture `existingIDs` before appending → a first-seen device appended twice. **Fixed**: added a `probeInFlight` guard mirroring `idleLoopRunning`.
- **`AppState.swift:2669`** — in `fetchDeviceStatusUncached`, the `tunerStatus[show.show_id]` write happened after the per-tuner `vstatus` await; a web-UI delete during that await could re-add the entry for a show `deleteShow` already cleared → a display-only leak that never cleared again. **Fixed**: re-checks the show still exists in `shows` after the await before writing.
- **`WebServer.swift:2781`** — `setDev('\(defaultDev)')` interpolated a DeviceID raw into a JS string literal, bypassing the file's `jsEscapeForScript`/`he` discipline. Not attacker-controlled (DeviceIDs are hardware hex), but the one escaping-discipline gap. **Fixed**: routed through `jsEscapeForScript` like every other dynamic value in the page's inline `<script>` block.
- **`VLCPlayerView.swift:399` / `VLCBridge.swift:454`** — (a) `selectedAudioTrackId`/`selectedSpuTrackId` reset sat after the `suppressNextChannelPlay` early-return, so a synced (external) channel switch didn't reset them and the picker could hold a stale track id; (b) the stats/playback `Timer` was scheduled in `.default` run-loop mode, so it stalled during modal tracking (open menu / live resize) — e.g. "Connecting…" could stick until a menu closed. **Fixed**: track ids now reset unconditionally before the suppress check; the timer now explicitly joins `RunLoop.main` in `.common` mode.

**Resolving commit**: `f47b087`

---

## RESOLVED — "No active tuner" shown after a UDP-only startup with the device's HTTP briefly down

**File:** `AppState.swift` — `probeForNewDevices()`; symptom surfaces in `WebServer.computeDevTuners`

**Symptom**: The tuner badge disappeared for a device (app showed no active tuner) even while it was actively recording. Confirmed via log: a startup discovered the device via UDP only (`known=0 mDNS=0 UDP=1`) and its `/discover.json` fetch failed, so it was cached with `TunerCount == nil`.

**Root cause**: A bare UDP-discovered device carries `TunerCount: nil` (capacity comes from the HTTP `/discover.json` fetch, which `udpDiscoverAndFetch` falls back from on failure). `discoverDevices` does `devices = found` at startup, and the ongoing `probeForNewDevices` merge only re-applied `DeviceAuth`/`LocalIP` — never `TunerCount` — so a device that started at nil stayed nil for the whole session. `computeDevTuners` renders no tuner badge when `total == 0`. Exposed by the recent DeviceAuth-over-UDP change, which makes UDP-only-with-HTTP-down startups viable rather than fully broken.

**Resolution**: `probeForNewDevices` now also restores `TunerCount` and `FirmwareVersion` from a fresh probe when present, and schedules a 60 s quick re-probe while any **reachable** (`isAvailable`) device has a nil `TunerCount` — so capacity (and the badge) is restored within ~60 s of the device's HTTP server becoming reachable. The `isAvailable` guard (follow-up) stops a device that never yields a `discover.json` `TunerCount` (e.g. the fake `FFFF0001` test device) from pinning the quick-probe cadence at 60 s for the whole session.

**Resolving commit**: `256cf69` (restore + unguarded re-probe); follow-up commit adds the `isAvailable` guard on the re-probe condition.

---

## RESOLVED — Web Edit endpoint accepted an arbitrary recording output directory (`saveDir`)

**File:** `WebServer.swift` — `handleEdit`

**Symptom / risk**: The `/api/edit-show` endpoint accepted a `saveDir` field and wrote it to `show_dir`/`show_temp_dir`. Since the LAN API has no auth beyond subnet matching, any host on the network could redirect where a show's recording is written. This also contradicted the documented behavior ("Save Directory is not editable from the web UI").

**Resolution**: Removed `saveDir` handling from `handleEdit` entirely — the endpoint now ignores any output-path field; directory changes require local app access. Also dropped the now-unused `data-dir` (local path) attribute from the web show-row data to avoid leaking filesystem paths to LAN browsers. Supersedes the earlier "harden saveDir" change (the field is no longer accepted at all). Docs (`docs/WebServer.md`) updated.

**Resolving commit**: pending (uncommitted at time of writing)

---

## RESOLVED — Web guide: open tuner dropdown vanishes when its device goes offline and is referenced by no scheduled show

**File:** `WebServer.swift` — `deviceOnline`/`deviceOffline` dev-bar swap

**Symptom**: When the user has a tuner's schedule dropdown expanded in the web guide and that device flaps offline, the dropdown can silently disappear instead of being restored.

**Root cause**: The dev-bar swap remembers the open `.tdrop` id and reopens it after `innerHTML` replacement. But if the now-offline device is referenced by no scheduled show, `buildDevBarHTML` renders no box for it, so the reopen-by-id lookup returns null and the dropdown is lost. The common case (device stays present) works.

**Resolution**: The swap now parses the incoming `d.devbar` HTML first and, if it lacks the currently-open dropdown's id, skips the `innerHTML` swap entirely — preserving the user's open dropdown rather than destroying it. The next full `refreshGuide()`/`guide_refreshed` reconciles the bar.

**Resolving commit**: pending (uncommitted at time of writing)

---

## RESOLVED — Web guide: `showTunerInfo` element-id mismatch (latent, pre-existing)

**File:** `WebServer.swift` — `showTunerInfo`

**Root cause**: `rid` is built from `hej(r.tuner).replace(/\W/g,'')` but the later lookups use `r.tuner.replace(/\W/g,'')`. If a tuner `Resource` ever contained `& < >`, `hej()` expands it and the two `.replace(/\W/g,'')` results diverge, so `getElementById(rid)` fails and the click/enrichment handlers never bind. Benign today because `Resource` is always `tunerN`. Predates the recent fix passes.

**Resolution**: The `rid` builder now uses the raw `r.tuner.replace(/\W/g,'')`, matching the lookups. An `id` attribute doesn't need HTML escaping, so dropping `hej()` there is safe and removes the divergence.

**Resolving commit**: pending (uncommitted at time of writing)

---

## RESOLVED — Discord webhook host check is case-sensitive

**File:** `DiscordNotifier.swift` — `isDiscordHost`

**Root cause**: The host comparison is case-sensitive against lowercase literals, and `URL.host` preserves case, so a user pasting `https://DISCORD.COM/...` is silently rejected (no-op send). Fails safe (never accepts a non-Discord host), so it's a UX edge, not a security issue. Real Discord webhook URLs are always lowercase.

**Resolution**: `isDiscordHost` now lowercases the host before comparing (hostnames are case-insensitive). Still exact-match / proper-subdomain only, so no lookalike-host bypass is introduced.

**Resolving commit**: pending (uncommitted at time of writing)

---

## RESOLVED — UDP discovery skips an interface whose netmask sockaddr reports `sa_family == 0`

**File:** `HDHRManager.swift` — `subnetBroadcastAddresses`

**Root cause**: The directed-broadcast computation requires `ifa_netmask.sa_family == AF_INET`; on macOS a live IPv4 interface occasionally reports its netmask sockaddr with `sa_family == 0`, so that interface's directed broadcast isn't sent. Masked by the `255.255.255.255` global-broadcast fallback, so it degrades to "may miss a device on an odd config," never a crash.

**Resolution**: The netmask guard now also accepts `sa_family == 0` (the `s_addr` mask bytes are valid at the same offset regardless), so the interface is still gated on its *address* being `AF_INET` but no longer dropped for an unusual netmask family.

**Resolving commit**: pending (uncommitted at time of writing)

---

## RESOLVED — `startDeviceChangeMonitoring()` leaks CoreAudio listener / dangling pointer if called twice

**File:** `VLCBridge.swift` ~line 664

`startDeviceChangeMonitoring()` assigned a new `AudioDeviceChangeContext` to `deviceChangeContext` without first calling `stopDeviceChangeMonitoring()`. ARC immediately deallocates the old context object, but CoreAudio still holds the raw opaque pointer registered via `AudioObjectAddPropertyListener`. The next audio device change fires `audioDeviceChangeProc` with a freed pointer — use-after-free.

**Fix (verified present in current code)**: `if deviceChangeContext != nil { stopDeviceChangeMonitoring() }` at the top of `startDeviceChangeMonitoring()`, with a comment explaining why, before registering the new listener.

---

## RESOLVED — `playerWindowDidClose()` does not call `stopDeviceChangeMonitoring()` — CoreAudio listener outlives VLC teardown

**File:** `VLCPlayerView.swift` ~line 958

`playerWindowDidClose()` called `releasePlayer()` but never `stopDeviceChangeMonitoring()`. With `isReleasedWhenClosed = false`, `windowWillClose` fires before `onDisappear`, leaving a real gap where VLC's media player is released but the CoreAudio device-change listener still fires `refreshAudioDevices()` callbacks into a partially torn-down view.

**Fix (verified present in current code)**: `VLCBridge.shared.stopDeviceChangeMonitoring()` is called from `playerWindowDidClose()` alongside `releasePlayer()`.

---

## RESOLVED — `moveToScreen()` places window off-screen when window is larger than the target display

**File:** `VLCPlayerView.swift` ~line 907

Centering formula: `x = sf.minX + (sf.width - wf.width) / 2`. When the player window is wider or taller than the target screen's `visibleFrame` (e.g. a native-resolution 1920×1080 window moved to a 1280×720 AirPlay receiver), the result is negative relative to `sf.minX` — no clamping applied. Part of the window extends off-screen with no title bar to drag it back.

**Fix (verified present in current code)**: `max(sf.minX, x)` / `max(sf.minY, y)` clamp on both axes.

---

## RESOLVED — `moveToScreen()` ignores miniaturized window state — `setFrameOrigin` silently no-ops

**File:** `VLCPlayerView.swift` ~line 907

`moveToScreen()` called `setFrameOrigin` then `makeKeyAndOrderFront`. If the window was miniaturized, macOS silently ignores `setFrameOrigin`; `makeKeyAndOrderFront` then deminiaturized the window at its pre-miniaturize position on the original screen rather than the target screen.

**Fix (verified present in current code)**: Checks `win.isMiniaturized` and calls `win.deminiaturize(nil)` before `setFrameOrigin`.

---

## RESOLVED — `managedShowByTitle` last-writer-wins: duplicate show titles produce wrong scheduled badge in `WatchNowView`

**File:** `WatchNowView.swift` (root cause: `AppState` `managedShowByTitle` dict)

`AppState.managedShowByTitle` was built with `byTitle[show.show_title] = show`, iterating shows in order. If two scheduled shows shared a title (e.g. "News" scheduled on two different channels), only the last one written survived. `WatchNowRow`'s `scheduled` check then tested device/channel/slot against whichever show landed last — the other entry incorrectly showed as unscheduled with a Record button instead of Edit.

**Fix (verified present in current code)**: `managedShowByTitle` is now `[String: [Show]]` (title → array); `WatchNowRow.managedShow` filters the array by device/channel/slot.

---

## RESOLVED — `@State var availableScreens = NSScreen.screens` evaluated at struct init, which may run off the main thread

**File:** `VLCPlayerView.swift` line 47

`NSScreen.screens` is main-thread-only. `@State` default values in SwiftUI structs are not guaranteed to be evaluated on the main actor during reconciliation. If SwiftUI evaluates this default off-main, the `NSScreen.screens` call is undefined behavior.

**Fix (verified present in current code)**: Initialized to `[]`, populated in `.onAppear`-driven code paths (`availableScreens = NSScreen.screens`, with a comment noting `NSScreen.screens` is main-thread-only and this call site is safe).

---

## RESOLVED — Nil `show_next` maps to sentinel `-1`, which spuriously matches a guide entry with `StartTime == -1`

**File:** `WatchNowView.swift` line 259

`Int(show.show_next?.timeIntervalSince1970 ?? -1) == entry.StartTime`: when `show_next` was nil the expression evaluated to `-1`. A malformed guide API response with `StartTime = -1` would produce a false-positive scheduled match for a show that has no air time scheduled.

**Fix (verified present in current code)**: `guard let nextDate = show.show_next else { return false }` before the epoch comparison.

---

## RESOLVED — `GuideStore.entries(key:after:)` is internal, not private

**File:** `GuideStore.swift` line 277

The `entries(key:after:)` overload added as an efficiency helper was declared with default (internal) access rather than `private`. Any code in the module could call it with an arbitrary string, bypassing the `deviceId:channelNum:` key format contract enforced by the public `entries(deviceId:channelNum:after:)`. A caller passing a malformed key silently got an empty array.

**Fix (verified present in current code)**: `private func entries(key: String, after: Date = Date())`.

---

## RESOLVED — `Int()` truncation in VLC buffer VoiceOver value

**File:** `VLCPlayerView.swift` ~line 679

`Int(info.lagSec)` truncated toward zero — `lagSec = 7.9` announced as "7 of 8 seconds" while the visual bar showed full.

**Fix (verified present in current code)**: `Int(info.lagSec.rounded())`.

---

## RESOLVED — Menu glitch feedback loop on guide load failure

**Symptom**: When a device's guide API returned 403 (e.g., the FFFF0001 test EXTEND device), the menu became completely unresponsive, firing HTTP requests at ~35ms intervals and locking the UI.

**Root cause**: `ensureGuideLoaded` was called inline in the SwiftUI menu `@ViewBuilder`. A failed load that assigned `guideByDevice = []` (even empty) triggered `didSet → rebuildMenuEntries → 3 @Published changes → SwiftUI re-eval → ensureGuideLoaded → HTTP request → failure → assign → didSet → ...` in a tight loop.

**What was tried and didn't work**: Guarding on `menuIsOpen` in `didSet` — guide loads are infrequent and must always populate `menuGuideEntries` even if the menu is open, so this guard was too broad. Adding `NSMenuDelegate` + lazy `menuNeedsUpdate` — rejected as too architecturally complex for the problem.

**Resolution**: `ensureGuideLoaded` only assigns `guideByDevice` when `guideStore.channels(deviceId:)` is non-empty after the load (empty result = no assignment = no re-eval trigger). Added `guideLoadFailTimes: [String: Date]` for 5-minute backoff on failed devices so repeated failures don't hammer the API. The `guideByDevice.didSet` is intentionally not guarded by `menuIsOpen`.

**Resolving commit**: `52c5107` (approximate)

---

## RESOLVED — AVPlayer does not support MPEG-2 transport streams

**Symptom**: The in-app player (using AVKit/AVPlayer) silently failed to play HDHomeRun streams. No error was shown; the player just displayed a black frame.

**Root cause**: AVPlayer on macOS does not support MPEG-2 transport streams, which is the native format from HDHomeRun tuners without transcoding. Forcing `transcode=heavy` as a workaround degraded quality and still failed for some streams.

**What was tried and didn't work**: Forcing transcoding on all streams — quality loss, still unreliable. Custom `AVAssetResourceLoaderDelegate` to pre-buffer — too complex, same underlying codec limitation.

**Resolution**: Replaced AVKit player entirely with VLC via `VLCBridge` (dlopen runtime loader for `libvlc.dylib`). VLC handles MPEG-2 natively so no forced transcoding is needed. The old `PlayerView.swift` is superseded by `VLCPlayerView.swift`. See `docs/VLCBridge.md` and `docs/VLCPlayerView.md`.

**Resolving commit**: in-app player VLC adoption (see git log for VLCBridge introduction)

---

## RESOLVED — TCC permission reset on app re-signing during deploy

**Symptom**: After running `deploy.sh`, the app lost Notification Center permission and folder-access entitlements. Users had to re-grant permissions after every deploy.

**Root cause**: Ad-hoc code signing (`codesign --force`) changes the code signature, which macOS treats as a new app identity — TCC (Transparency, Consent, and Control) ties permissions to the signature.

**Resolution**: Moved the config file from `~/Documents/hdhr_VCR-{hostname}.json` to `~/Library/Application Support/hdhrVCRplus/hdhr_VCR-{hostname}.json`. `ConfigManager` auto-migrates on first launch. This scopes the app's folder access to its own support directory (always granted without a prompt) instead of `~/Documents`. The old file is left in place so the AppleScript app can still read it. Added `setbuf(stdout, nil)` for reliable log flushing after the process model changed.

**Resolving commit**: config migration commit (see git log for `ConfigManager` path change)

---

## RESOLVED — Disk-full "Recording Skipped" posted a brand-new Discord message on every retry

**File:** `AppState.swift` → `startRecording(index:)`, disk-check guard

**Symptom**: While a show's tuner slot stayed ready but the disk was over the free-space threshold, every idle-loop retry posted a fresh "💾 Recording Skipped" Discord message instead of updating one card — spamming the channel once per retry.

**Root cause**: This was the one failure path still calling the fire-and-forget `discordShow(...)` helper with no `editMessageId`, instead of the `discordRecordingCard(showId:event:color:enabled:extra:)` helper the other four failure paths (curl exit, no stream URL, launch error, empty output file) already used. `discordShow` neither reuses `discord_start_msg_id` nor captures a new message ID, so each call was an orphaned POST.

**Resolution**: Switched the disk-full path to `discordRecordingCard`, matching the other failure paths — reuses the existing card if `discord_start_msg_id` is set, otherwise creates one and captures the ID. Found and fixed alongside adding the idle-loop retry backoff.

**Resolving commit**: pending (uncommitted at time of writing)

---

## RESOLVED — Recording fires on a stale `show_next` after repeated "no episode found in guide" rescans, recording whatever's actually airing

**File:** `AppState.swift` — the hourly guide-rescan path that logs `"no episode found in guide — show_next already future, leaving unchanged"` (feeds `resolveSeriesAir`/`scheduleNextAir`); fix lives in `startRecording(index:)`

**Symptom**: A recurring SeriesID show (`The Late Show With Stephen Colbert`) recorded a program that didn't match its SeriesID — user identified the actual content as a Byron Allen syndicated program, not Colbert.

**Root cause**: `show_next` was locked in from an earlier successful SeriesID match against the guide. Five consecutive hourly rescans (19:00, 20:00, 22:00, 23:00, 00:00) all failed to reconfirm any guide entry for that SeriesID at that time slot, each logging "no episode found in guide — show_next already future, leaving unchanged" — i.e. the guide had stopped listing Colbert there at all, most likely because the network swapped in different programming (a live preemption) and the guide provider's data caught up to reflect it. The "leave unchanged" fallback is reasonable for a single transient guide gap, but had no escalation once a slot goes unconfirmed for hours — the idle loop's ready-check (`next <= now+10`) only cared that the stored timestamp arrived, not whether the guide still backs it up, so the show recorded blind at the stale time and captured whatever was actually broadcasting.

**Resolution**: `startRecording(index:)` now does a final, synchronous, live re-check for any SeriesID-based show (`show_use_seriesid`) right before actually recording — `GuideStore.currentEpisode`/`currentEntryByTitle` against the show's own resolved device+channel, the same SeriesID-then-title trust tiers `scheduleNextAir` already uses. The title-only tier runs even when `show_seriesid` is empty (a real, already-handled case for guide entries that omit SeriesID — fixed in review after an initial version gated the whole check on a non-empty `show_seriesid`, silently leaving those shows unprotected). If neither confirms the airing anymore, the recording is skipped, `show_next` is cleared to `nil`, `scheduleNextAir` is called immediately — falling into its own existing "no match, retry in `Series_scan_retry_hours`" branch, the same path a brand-new show's first resolution takes — and a `show_updated` guide-change event is broadcast (using the post-reschedule channel/device) so an open web guide doesn't show stale schedule info. No new state machinery.

**Resolving commit**: pending (uncommitted at time of writing)

---

# Found during WebServer.swift CSS/JS/HTML extraction — 2026-08-02

## RESOLVED — `CHANGELOG.md` never copied into the app bundle; in-app changelog view silently renders empty

**File:** `Views/SettingsView.swift` (`Bundle.main.url(forResource: "CHANGELOG", withExtension: "md")`); `deploy.sh`/`deploy_release.sh`; `Package.swift`

**Root cause**: `Package.swift` declares `CHANGELOG.md` via SPM's `resources: [.copy(...)]`, which relies on the `Bundle.module` mechanism. The generated `Bundle.module` accessor looks for the resource bundle at `Bundle.main.bundleURL.appendingPathComponent("hdhr_VCR_hdhr_VCR.bundle")` — i.e. as a *sibling* of `Contents/` inside the `.app` (like `hdhrVCRplus.app/hdhr_VCR_hdhr_VCR.bundle`) — which neither `deploy.sh` nor `deploy_release.sh` ever creates. `SettingsView.swift` actually calls `Bundle.main.url(...)`, not `Bundle.module`, so it's not even reaching that (broken) mechanism — either way, `CHANGELOG.md` never lands anywhere `Bundle.main` looks (`Contents/Resources/`), so the lookup returns nil and the changelog view renders empty in every deployed build.

**Resolution**: Took option (a) from the original fix note — added `cp CHANGELOG.md "$APP/Contents/Resources/CHANGELOG.md"` to both `deploy.sh` and `deploy_release.sh`, matching how `favicon.ico`/`AppIcon.icns`/`app*.jpg` already land there. Left the SPM `resources:` declaration in `Package.swift` alone (harmless, unused by `Bundle.main`). Verified via a real `./deploy.sh` run: `hdhrVCRplus.app/Contents/Resources/CHANGELOG.md` now exists and diffs identical to the repo copy.

**Resolving commit**: pending (uncommitted at time of writing)

## RESOLVED — `deploy_release.sh` has no favicon generation/copy step

**File:** `deploy_release.sh`

**Root cause**: `deploy.sh` generates `favicon.ico` from `Resources/AppIcon-source.png` and copies it into `Contents/Resources/` (`deploy.sh:71-83` at time of writing). `deploy_release.sh` has no equivalent step at all — release builds silently rely on whatever `Resources/favicon.ico` happens to already be checked into git from a prior `deploy.sh` run, rather than regenerating it themselves.

**Resolution**: Added the same favicon-generation block from `deploy.sh` (built from the iconset `deploy_release.sh` already generates for `AppIcon.icns`, no duplicate `sips` work) plus the `Contents/Resources/favicon.ico` copy. Verified via `./deploy_release.sh 1.4.6 --adhoc`: the regenerated `Resources/favicon.ico` is byte-identical to the previously committed one, and it lands correctly in the bundle before the (pre-existing, unrelated) iCloud FinderInfo codesign flake was hit.

**Resolving commit**: pending (uncommitted at time of writing)

---

# Superseded by removal — FloatingGuideView / CableGuideView (native guide views, fully removed)

The native `FloatingGuideView.swift` and `CableGuideView.swift` were entirely deleted from the codebase — replaced by the WKWebView-embedded web guide everywhere (see `docs/*.md`'s superseded-doc notes). Every finding below was originally logged as `RESOLVED` against those files; verified 2026-08-10 that neither file exists anymore, so there's no code left for any of these to still be true or false about. Kept here only so a future search for the symptom text doesn't come up empty and wonder if it's still lurking.

- `FloatingGuideView` did not reset `genreFilter` on device change — stale filter left the guide non-interactive.
- `AddShowView`'s (pre-web-guide) native genre filter had the same silent-reset UX gap.
- `managedSeriesIDShows` was computed 4× per render in `FloatingGuideView`.
- `CableGuideView`'s accessibility action gate condition was duplicated in name and handler body.
- VoiceOver "Record" action could trigger on already-managed (recording/scheduled) guide entries in `CableGuideView`.
- VoiceOver actions in `CableGuideView` weren't gated by `matchesFilter`, so a genre-dimmed cell was still activatable.
- `ShowBlocksRow.==` omitted `totalW`/`rowH`/`pxPerMin`, causing stale cell geometry after a window resize.
- `guideTimeRange()` was called inside an `.accessibilityLabel` closure on every render in `CableGuideView`.
- `FloatingGuideView`'s `summaryPanel` used O(n) `contains(where:)` instead of a Set lookup.
- `MenuContent.showInfoHeader`'s "already scheduled" yellow triangle badge showed on every menu context, not just guide-browsing — the badge concept itself no longer exists in `showInfoHeader` at all (verified 2026-08-10: zero "managed badge" logic remains in that function), so whatever replaced it (if anything) isn't this bug.

---

## Staleness check, 2026-08-10

Every entry above that only had a prescriptive `**Fix:**` note (rather than a past-tense `**Resolution:**`) was individually re-verified against the current source before filing here — grepped for the described symptom and confirmed the described fix's actual code is present (or, for the FloatingGuideView/CableGuideView group, confirmed the file is gone entirely). Nothing in this file is guessed or assumed still-true from the original write-up.
