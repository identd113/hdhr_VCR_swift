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

## RESOLVED — Settings could show a false "Unsaved Settings" close-confirmation with nothing actually edited

**File:** `Views/SettingsView.swift` (`isDirty`, `resetDrafts()`, `WindowCloseInterceptor`)

**Symptom**: Reopening Settings, navigating between sidebar tabs only (no field touched), and closing could trigger the app-modal "Unsaved Settings" alert (Save/Discard/Cancel) that's supposed to only appear when a real edit is pending. Found via `WindowNavigationTests.swift`'s `guideSourceToggleDoesNotBreakWindows`, which opens/closes Settings 4 times in one run — reliably reproduced on the 3rd/4th open, never the 1st or 2nd.

**Root cause (confirmed)**: `open(_:)` in `MenuContent.swift` calls `openWindow(id: "settings")` for single-instance `Window` scenes, which — per SwiftUI's documented behavior for that scene type, and this codebase's own comment acknowledging it ("Window scenes can't duplicate") — just refocuses the existing window rather than recreating its view when one is already alive. `SettingsView`'s `.onAppear { resetDrafts() }` therefore only ever fires once, on true first creation, not on later reopens. Any background `saveConfig()` unrelated to Settings (this app has several — idle loop, tuner probing, etc.) occurring between the first open and a later reopen then leaves `draft` silently stale relative to the live `state.config`, so `isDirty`'s `draft != state.config` check reads true even though the user touched nothing.

**Resolution**: Added `windowDidBecomeKey` to `WindowCloseInterceptor`'s `NSWindowDelegate` (fires on every real refocus, not just creation) wired to a new `resyncIfUntouched()`. Naively resyncing on every refocus was considered and rejected — it would silently discard a real in-progress edit if the user simply alt-tabbed away and back while mid-edit. Instead, added a `draftBaseline` snapshot (set alongside `draft` in both `resetDrafts()` and, to stay in lockstep, in `applyAndSave()`): `resyncIfUntouched()` only refreshes `draft` from `state.config` when `draft == draftBaseline` (provably untouched since the last sync) *and* `draft != state.config` (something actually changed to pick up) — the instant a user edits any field, `draft` diverges from `draftBaseline` and this becomes a guaranteed no-op until the user Saves or Discards, exactly matching the existing (unchanged) semantics for real edits. `EditShowView.swift`'s use of the same `WindowCloseInterceptor` doesn't need the new hook — its `isDirty` compares two snapshots taken together (`show` vs `originalShow`), not a snapshot against a live value, so it was never exposed to this class of bug; passes a no-op `onBecomeKey: {}`.

**Verified**: reproduced the failure directly first (4 rounds of open→click-all-8-tabs→close, no field touched — alert appeared by round 3 on the old code), confirmed absent on the same script post-fix (4/4 rounds, no alert). `WindowNavigationTests.swift`'s full 6-test suite passes twice in a row against the real fix (not just the test's own defensive alert-dismissal, which is now expected to rarely/never actually fire).

**Resolving commit**: pending (uncommitted at time of writing)

---

## RESOLVED — `ChannelIconCache.pruneDiskCacheIfNeeded()` ran a full directory scan + per-file `stat` after every single disk write

**File:** `ChannelIconCache.swift`

**Root cause**: The actor-isolated prune ran unconditionally after every icon write, listing the whole disk cache directory and calling `resourceValues` (a `stat`) on each file. `AppState.prefetchChannelIcons` fans out one concurrent `Task` per missing icon via `withTaskGroup` on cold start / lineup refresh — since the cache is an actor, every one of those (potentially hundreds, up to the ~2000-file cap) completions serialized through this full O(n) scan, turning a bulk prefetch into effectively O(n²) directory I/O and stalling unrelated cache-hit reads on the same actor during startup.

**Resolution**: Moved the prune call out of `image(for:)`'s per-write path entirely. `pruneDiskCacheIfNeeded()` is now `func` (not `private`) and called once from `AppState.prefetchChannelIcons` after its cold-cache download batch completes, instead of once per file inside the actor. Since `prefetchChannelIcons` itself only runs once per guide load (startup, the hourly `refreshGuides`, and on-demand per-device retries), this ties the directory scan to that natural cadence — a batch of hundreds of icon writes now costs one scan instead of hundreds.

**Resolving commit**: pending (uncommitted at time of writing)

---

## RESOLVED — `prebuildPageHTML` ran two full-page HTML builds + two sequential gzip passes on every guide-changing event

**File:** `WebServer.swift` (`prebuildPageHTML`, `@MainActor`)

**Root cause**: Vertical time-axis mode (`fbcbc09`, 2026-08-06) added a second cached page (`cachedVerticalHTML`/`cachedVerticalHTMLGzip` alongside `cachedHTML`/`cachedHTMLGzip`) for `GET /vertical`. It already avoided doubling the expensive shared grid build (1300+ program blocks, computed once and reused), but the two full-page `buildHTML` + `Self.gzip` wraps around it were left sequential — so every rebuild, which fires on every add/delete/pause/resume/edit/favorite-toggle and recording start/stop, now ran a ~30-60ms gzip pass twice, back to back, on `@MainActor`, roughly doubling how long menu/UI responsiveness blocked on each such state change versus before vertical mode existed.

**Resolution**: The two `buildHTML` calls still run serially (they read MainActor-isolated `AppState` synchronously, so they can't safely move off-actor). `Self.gzip`, though, only touches plain `Data` with no actor affinity, so the two compressions now run concurrently via `DispatchQueue.concurrentPerform(iterations: 2)`, writing into a raw `UnsafeMutablePointer<Data?>` (wrapped in a local `@unchecked Sendable` box to satisfy the compiler) since each iteration writes a distinct, non-overlapping slot.

**Follow-up fix, same session**: `/vertical` only matters for portrait-orientation mobile browsers — a much smaller (often zero) slice of traffic than `GET /`. `prebuildPageHTML` was still building+gzip'ing the vertical variant unconditionally on *every* rebuild even on installs that never see it requested. Added a sticky `verticalRouteEverRequested` flag, set by the `/vertical` route handler on its own first hit (which also builds+gzips+caches the page live for that request, so there's no extra cold-start penalty). `prebuildPageHTML` now skips the vertical build/gzip entirely — one pass instead of two, no concurrency needed — until that flag is true, at which point both variants go back to being rebuilt together as before. Updated `docs/WebServer.md`'s "Two independent page caches" section to match.

**Resolving commit**: pending (uncommitted at time of writing)

---

## RESOLVED — Verbose curl `-v` logging silently exceeded `RotatingLogFile`'s cap, and a rotation mid-recording could race an open curl file descriptor

**File:** `RecordingManager.swift` (curl's `-v` stderr piped via `posix_spawn`'s `stderrPath`); `Models.swift` (`RotatingLogFile`, new `curlVerboseLogFilePath`/`rotateCurlVerboseLogIfNeeded()`)

**Root cause**: `RotatingLogFile.bytesWritten` only incremented inside `RotatingLogFile.write()`, called by `glog()`. Verbose curl logging piped curl's own `-v` stderr straight into the *same* file (`logFilePath`) via its process spawn config, invisible to that byte counter — so the main log's documented 20MB cap wasn't actually enforced while verbose logging was active. Separately, if a rotation fired (renaming to `.log.1`) while curl's fd was still open and writing to the pre-rotation path, curl kept writing into the now-renamed file until it closed; a *second* rotation before that close could unlink that renamed file out from under curl, losing whatever it wrote in the interim.

**Resolution**: Gave verbose curl logging its own dedicated file, `curlVerboseLogFilePath` (`~/Library/Logs/hdhrVCRplus-curl.log`), completely separate from the main app log — mirroring the Discord log's own separately-capped file, per the issue's own suggested fix. Since curl writes to this path directly via a raw fd with no persistent Swift-side `FileHandle` involved, `RotatingLogFile`'s per-write byte-counting approach doesn't apply; instead `rotateCurlVerboseLogIfNeeded()` stats the file directly and renames it to `.1` (never truncates in place — truncating is what caused the original race back when this shared `logFilePath`) once per verbose recording start, called from `RecordingManager.start()` right before `writeCurlLogHeader`. This is a per-recording-start check rather than per-line — the practical limit given curl's writes happen entirely outside Swift's visibility once spawned — so a single verbose recording whose own `-v` output alone exceeds 5MB won't be caught until the next recording starts; multi-recording unbounded growth (the actual reported risk) is fully fixed. Updated `docs/RecordingManager.md`, `docs/Models.md`, `docs/SettingsView.md`, and CLAUDE.md's "Logs" note to describe the new dedicated file and rotation mechanism.

**Resolving commit**: pending (uncommitted at time of writing)

---

## RESOLVED — `RotatingLogFile.write()` advanced `bytesWritten` even when the underlying write silently no-opped

**File:** `Models.swift` (`RotatingLogFile`)

**Root cause**: If `open()` failed to obtain a `FileHandle` (transient permissions issue, full disk, Logs directory briefly unavailable), `handle?.write(data)` was a silent no-op via optional chaining, but `bytesWritten += UInt64(data.count)` ran unconditionally regardless. The counter could then cross `rotateThreshold` and trigger `rotate()` based on phantom growth that never actually reached disk.

**Resolution**: `write()` now guards on `handle` being non-nil before advancing `bytesWritten` — bytes are only counted once the write actually happens.

**Resolving commit**: pending (uncommitted at time of writing)

---

## RESOLVED — `seriesAll` shows could match/record on more than one tuner at once (originally a `TODO.md` item, not `ISSUES.md`)

**File:** `Models.swift` (`ManagedGuideMatcher`), `AppState.swift` (`resolveSeriesAir`, `nextGuideEpisode`, `scheduleNextAir`, the scheduled-menu cache builder), `GuideStore.swift` (`currentEntryByTitle`/`nextEntryByTitle`)

**Root cause**: `seriesAll` shows used bare, device-agnostic keys in `ManagedGuideMatcher` (`seriesAllIDs`/`seriesAllTitles`) and passed `deviceId: nil` to every `GuideStore` scheduling lookup — both by design, to let a series "follow" reruns/affiliates onto any tuner. In practice this meant the same recurring series could be picked up and recorded independently on more than one physical HDHomeRun device at once (wasted tuner capacity, duplicate files), and `scheduleNextAir`'s `applyMatch` could silently migrate a show's `hdhr_record` to a completely different device on every reschedule, since nothing pinned the search to the device the show was actually set up on.

**Resolution**: `seriesAll` is now scoped to a single assigned HDHomeRun device — the same one it was set up on (`hdhr_record`) — exactly like `seriesChannel` already was; the only remaining difference between the two states is *channel* scope on that one device (`seriesChannel` locks to one channel, `seriesAll` follows the series across any channel on the same device). `ManagedGuideMatcher`'s `seriesAllIDs`/`seriesAllTitles`/`seriesChKeys`/`seriesChTitles` were merged into unified device-scoped `seriesKeys`/`seriesTitles` (both states now produce identical `"device:SeriesID"`/`"device:title"` keys). Every `AppState` scheduling call site that previously computed `deviceId: isAll ? nil : device` now always passes the device (only the `channelNum` filter stays conditional on `isAll`). `GuideStore.currentEntryByTitle`/`nextEntryByTitle` previously only applied their device/channel filters when *both* were non-nil (a fast-path optimization) — extended to apply each filter independently, since the new device-only, channel-nil combination `seriesAll` now passes would otherwise have silently ignored the device filter entirely and kept scanning every device. Physical tuner ports within one device (e.g. a 4-tuner model) were never individually tracked and still aren't — "device" here always means the whole HDHomeRun unit (`hdhr_record`/`deviceId`), never a specific `tuner0`/`tuner1` slot; a device's own multiple tuners remain pooled, undifferentiated capacity (see CLAUDE.md's "Tuner occupancy" note).

Updated `ManagedGuideMatcherTests.swift`'s two now-invalid "matches any device" tests to their corrected "matches own device, any channel" + new "does not leak to other device" shape; added two more for the `byTitle` tier. Full suite (160 tests) passes. Updated CLAUDE.md, `docs/Models.md`, `docs/WebServer.md` to match.

**Resolving commit**: pending (uncommitted at time of writing)

---

## RESOLVED — `recordedEpisodeTags` directory scan could block the whole app, not just the Add/Edit dialog (originally a `TODO.md` item, not `ISSUES.md`)

**File:** `AppState.swift` (`recordedEpisodeTags`, `episodeTag(inFilename:)`, `duplicateEpisodeTag(for:isSeries:baseDir:)`), `Views/ShowFormSection.swift`

**Root cause**: The Add/Edit dialog's duplicate-episode check debounced with a 350ms delay before scanning, but the scan itself (`recordedEpisodeTags` — synchronous `FileManager` calls, two directory levels) ran inline on `@MainActor` with no suspension point to yield control. The debounce reduced how *often* it ran, not the *risk* each run carried — a slow-to-wake external/NAS-backed recording drive could stall the entire app for that one scan, not just the dialog.

**Resolution**: `recordedEpisodeTags`/`episodeTag(inFilename:)` are now `nonisolated` (pure `FileManager`/regex work, no actor-isolated state touched) — existing synchronous callers on `@MainActor` (`buildGuideGridHTML`, the title-based `duplicateEpisodeTag(title:episodeTag:baseDir:)` overload used by `startRecording`'s one-shot check) are unaffected. `duplicateEpisodeTag(for:isSeries:baseDir:)` — the one call site actually flagged (`ShowFormSection`'s live-typing debounce) — is now `async`: its cheap, in-memory guide lookup and config checks stay on `@MainActor`, but the actual disk scan is dispatched to a `Task.detached`, so a slow drive only stalls that one debounced check instead of the whole app.

**Resolving commit**: pending (uncommitted at time of writing)

---

## RESOLVED — Duplicate-episode override was a web-guide dead end (originally a `TODO.md` item, not `ISSUES.md`)

**File:** `WebServer.swift` (`handleEdit`, `buildGuideGridHTML`'s `showDA`, `buildTunerShowsHTML`), `Resources/guide.js`, `Resources/guide-shell.html`

**Root cause**: `willSkip` already rendered the green `.g-flag-skip` corner flag + "Already recorded · will skip" tooltip for a managed block the grid knew would be skipped as a duplicate, but `show_ignore_duplicate_once` (the per-show one-shot override) was only settable from the native Add/Edit dialogs — `handleRecord`/`handleEdit` never read or wrote it. A user watching the web guide saw "this won't record" with zero recourse short of switching to the native app.

**Resolution**: Added a "Duplicate Episodes" toggle (`#em-dup-row`/`#em-dup`) to the web guide's Edit modal, mirroring the native dialog's toggle — shown when `Series_subfolder_enabled && Skip_recorded_episodes` (baked into `guide.js` as the `SKIP_DUP_ENABLED` token) and the show is a series type, re-evaluated on every type-picker change via `updateDupVisibility()`. Round-trips via a new `data-show-ignoredup`/`data-ignoredup` attribute (both `showDA` in the grid and `buildTunerShowsHTML`'s per-tuner dropdown rows) → the checkbox → `POST /api/edit`'s new `ignoreDuplicateOnce` field → `handleEdit` → `show.show_ignore_duplicate_once`. Not added to the Record modal (`#rec-modal`) — a brand-new Record can't yet know whether the episode it's about to schedule will land on disk as a duplicate. Verified end-to-end in a real running instance (Chrome automation): opened the edit modal for a live `seriesAll` show, confirmed the toggle appeared, toggled it on, saved, reloaded the page, confirmed `data-show-ignoredup="1"` persisted server-side, then reverted. Also corrected a related stale claim in `docs/ShowFormSection.md` (the Record modal "mirrors these fields minus Folder" — it was also missing Duplicate Episodes, a second, pre-existing omission unrelated to this fix).

**Resolving commit**: pending (uncommitted at time of writing)

---

## RESOLVED — `WebServer.swift` `/api/guide-detail` Int-overflow crash on hostile window params

**File:** `WebServer.swift` (`/api/guide-detail` route)

**Root cause**: The route parsed client-supplied `{winStart}/{winSec}` path segments with bare `Int(...)` and then computed `winStart + winSec`; a LAN request like `/api/guide-detail/x/y/9223372036854775807/1` overflowed `Int` and trapped, killing the whole app (and any in-progress recordings). The existing fallback-to-server-window path only covered *malformed* segments, not well-formed-but-absurd ones.

**Resolution**: Both values are now clamped to a sane range before use (`winStart` within ±10 years of now, `winSec` in `1...(28*3600)`), falling back to `guideWindow(state:)` otherwise — same shape as the existing malformed-segment fallback. Verified live against the running app (`curl .../guide-detail/x/y/9223372036854775807/1` → 200, server still alive afterward) and added a regression test, `guideDetailOverflowWindowDoesNotCrash` in `WebServerTests.swift`, matching the existing `negativeContentLengthDoesNotCrash` pattern.

**Resolving commit**: `a6d67de`

---

## RESOLVED — `WebServer.swift` `isLocalAddress` treated non-loopback IPv6 as loopback

**File:** `WebServer.swift` (`isLocalAddress`)

**Root cause**: The loopback fast-path used `testIP.hasPrefix("::1")`, which matches any IPv6 address *beginning* "::1" (`::1234:5678`, `::123`, `::1:2:3` — the deprecated IPv4-compatible `::/96` space), granting those sources the loopback bypass past the subnet check entirely. Exploitability was low (those addresses are effectively unroutable from the public internet, and TCP spoofing is impractical), but the check was simply wrong as written.

**Resolution**: Exact-match `testIP == "::1"` instead (the IPv4-mapped `::ffff:127.0.0.1` case is already normalized to `127.0.0.1` by the strip above it). One-line fix. Verified live against the running app: both `127.0.0.1` and `::1` loopback access still return 200 after the change.

**Resolving commit**: `641e036`

---

## RESOLVED — `AppState.pendingRecordingChannels`/`WebServer.swift`+`WatchNowView.swift`'s "recording" status false-positive during a missed-start retry backoff

**File:** `AppState.swift` (`pendingRecordingChannels`), `Tests/hdhr_VCRTests/Recording/TunerOccupancyTests.swift`

**Root cause**: `pendingRecordingChannels(for:)` treated any channel whose managed show had `show_next <= now < show_end` and `show_recording == false` as recording — meant to cover the brief, normal startup lag between a show's scheduled time and `RecordingManager` actually flipping the flag, but it didn't distinguish that from a show that failed to start and is waiting out a `showRetryAfter` retry cooldown (only ever set by `recordShowFailure` after a genuine failure, never during ordinary startup) with `show_next` stuck in the past. This logic predated 2026-08-15 (originally `WebServer.swift`'s `pendingRecChannelsByDevice`, used only for a single guide block's ring badge), but that day's Watch Now/web-guide rework gave the false positive a much bigger megaphone: it pulled the whole channel row into the prominent "Recording"/"● RECORDING" section at the top of both Watch Now and the web guide (previously just a small ring icon), and suppressed a legitimate conflict badge via `buildGuideGridHTML`'s `isConflict`/`WatchNowView`'s `guideRingState`, both of which gate on `!isRecording`.

**Resolution**: `pendingRecordingChannels` now excludes a channel whose show has a live (unexpired) `showRetryAfter` entry — a stuck show falls through to whatever's actually true instead (scheduled or conflict), restoring the conflict badge and correct Favorites/Recording bucketing automatically since both downstream renderers already derive from this one function (no separate WebServer.swift/WatchNowView.swift changes needed). Once the backoff itself expires, the show is eligible for its next retry attempt and reads as pending again for that brief window — same behavior as the non-retry case. Added `pendingRecordingChannels_stuckRetryBackoff_isExcluded`/`_expiredRetryBackoff_isIncluded` to the existing `TunerOccupancyTests` suite (29 tests, all passing); verified live against the running app (real in-progress NFL recording, Chrome screenshot of the guide) that the normal recording path still renders correctly post-deploy.

**Resolving commit**: `3741d3b`

---

## RESOLVED — `ManagedGuideMatcher`'s `seriesChannel` badge could appear on a channel it would never actually record from

**File:** `Models.swift` (`ManagedGuideMatcher`), `Tests/hdhr_VCRTests/Models/ManagedGuideMatcherTests.swift`, `CLAUDE.md`, `docs/Models.md`, `docs/WebServer.md`

**Root cause**: `seriesKeys`/`seriesTitles` (the lookup behind the guide's blue "managed" ring + ⏱ badge, `ManagedGuideMatcher.owner(for:)`) were built from **both** `seriesChannel` and `seriesAll` shows alike, keyed only `"deviceId:SeriesID"`/`"deviceId:title"` — device-scoped but not channel-scoped. That matches `seriesAll`'s actual behavior (follows a series across any channel on its tuner, by design) but not `seriesChannel`'s, which `AppState.resolveSeriesAir`/`nextGuideEpisode`/`scheduleNextAir` lock to the one channel the show was added on. The mismatch meant a `seriesChannel` show's badge could appear on a same-SeriesID rerun airing on a *different* channel on the same tuner — found live: a `seriesChannel` "Saturday Night Live" show (locked to channel 11.1) badged a rerun of the same series airing on channel 23.4 (a syndicated rerun station, ROAR), even though the show would never actually record from that channel — 2026-08-15, reported by the user noticing the mismatch and reasoning through the tuner/channel scoping expectation for `seriesChannel` themselves.

**Resolution**: Split `seriesKeys`/`seriesTitles` by type — `seriesAll` keeps the original device-only keys; `seriesChannel` now gets its own `seriesChannelKeys`/`seriesChannelTitles`, keyed `"deviceId:channel:SeriesID"`/`"deviceId:channel:title"`. `owner(for:)` checks the channel-scoped tier first, then falls through to the device-only tier — so `seriesChannel`'s matching scope now exactly mirrors its scheduling scope, and `seriesAll` is unaffected. Added `seriesChannel_bySeriesID_doesNotMatchDifferentChannelSameDevice`/`_byTitle_doesNotMatchDifferentChannelSameDevice` (the exact SNL/ROAR case) to `ManagedGuideMatcherTests` (15 tests, all passing); full suite (264 tests) passes. Updated `CLAUDE.md`'s "Web guide managed markers are tuner-scoped" invariant, `docs/Models.md`'s `ManagedGuideMatcher` section, and `docs/WebServer.md`'s matching-tiers reference to match.

Post-deploy live verification (real SNL/ROAR guide data) turned up a second, independent copy of the same bug: `WebServer.buildNowJSON` (`/api/now.json`'s `isScheduled` field) had never actually used `ManagedGuideMatcher` — it maintained its own parallel lookup (`AppState.managedShowBySeriesID`/`managedShowByTitle`, device-scoped only, same gap) despite `docs/WebServer.md` claiming the two paths agreed. Fixed by routing `buildNowJSON` through the same `ManagedGuideMatcher` the guide grid uses, and deleted `managedShowBySeriesID`/`managedShowByTitle` (and their computation in `rebuildMenuEntries()`) once that was their only remaining reader — confirmed via grep before deleting.

**Resolving commit**: `e752ad6`

---

## RESOLVED — Web guide dev-bar showed a permanently-dimmed tuner box for an offline device with nothing scheduled on it

**File:** `WebServer.swift` (`buildDevBarHTML`), `CLAUDE.md`, `docs/WebServer.md`

**Root cause**: `buildDevBarHTML` rendered a `tunerBox` for every entry in `state.devices` unconditionally, dimmed (`.tuner-off`) once the device dropped out of `state.usableDeviceIDs` — regardless of whether any show actually referenced that device (`hdhr_record`). Found live 2026-08-15 while testing `tools/mock_hdhr.py`'s new `--lan` mode: bringing the mock device up and back down left its tuner box sitting in the dev-bar indefinitely, dimmed, with nothing depending on it and nothing useful to warn about.

**Resolution**: The per-device loop now skips a `state.devices` entry when it's both unusable and has zero shows referencing it (`deviceIDsWithShows.contains(d.DeviceID)`) — an unavailable device something still depends on continues to render exactly as before (verified live: the real `FFFF0001` fake-EXTEND test device, which has one show pointing at it, still rendered as `.tuner-off`/`d-btn-off` after the change). The separate, always-shown "offline device never discovered at all" case (`offlineIDs`, referenced by a show but absent from `state.devices` — CLAUDE.md's "Web guide offline devices" invariant) is untouched — it's built from `state.shows.map { $0.hdhr_record }` and so by construction only ever contains devices with a show attached. Full suite (264 tests) passes; the one failure seen mid-session (`guideRefreshLatency_underThreshold`) was the pre-existing documented flaky perf test (`TODO.md`), confirmed unrelated by re-running clean post-deploy.

**Resolving commit**: `ad6103a` (mock_hdhr.py `--lan` mode itself: `07ac196`)

---

## RESOLVED — Muting after explicitly turning captions off silently re-enabled them

**File:** `Views/VLCPlayerView.swift`, `docs/VLCPlayerView.md`

**Root cause**: `-1` was overloaded to mean two different things for `selectedSpuTrackId`: "no CC choice ever made" (the initial/reset state) *and* "user explicitly picked 'Off' in the Picker" (its tag value). The auto-enable-captions-on-mute guard (`onChange(of: volume)`, added this cycle) checked `selectedSpuTrackId < 0` to decide whether the user had already made a deliberate choice — but that check can't tell the two `-1` cases apart, so a real "Off" pick looked identical to "never chosen." The very next mute would silently re-enable captions the user had just explicitly turned off, directly contradicting the guard's own comment ("skipped... even 'Off' was picked on purpose"). Found via `swift-quality-reviewer` during pre-release review of `v2.0.3..main` (2026-08-15) — the bug ships with this same range's new captions-auto-enable feature, so it was never live in a prior release.

**Resolution**: Added a separate `spuChoiceIsExplicit: Bool` tracked independently of the `-1` sentinel. Only the Picker's own selection (via a wrapped `Binding(get:set:)`, not `$selectedSpuTrackId` directly) sets it `true` — every programmatic reset of `selectedSpuTrackId` (channel load, channel switch) resets it back to `false` too, so a new channel always gets a fresh auto-enable decision instead of inheriting the previous channel's explicit choice forever. The mute-guard now checks `!spuChoiceIsExplicit` instead of `selectedSpuTrackId < 0`. Verified via `swift build` (clean) and the full test suite (264 tests, no CC-specific automated coverage exists — this is pure SwiftUI `@State` interaction logic, not easily unit-testable without a UI test harness); manually reasoned through the four call sites that touch either variable to confirm the reset/set pairing is exhaustive. `docs/VLCPlayerView.md` updated to describe the new tracking mechanism in place of the buggy one.

**Resolving commit**: pending (uncommitted at time of writing)

---

## RESOLVED — `diskOK(for:)` could block recording on a large drive with tens of GB genuinely free

**File:** `Models.swift` (`Min_disk_free_gb` default), `docs/Config.md`

**Root cause**: `diskOK` refuses to record when *either* the drive is over 93% full (`maxDiskPct`, hardcoded) *or* free space drops below `Min_disk_free_gb` (Settings-configurable, defaulted to 10 GB). Found 2026-08-15 while adding test coverage for the recording-scheduling engine, surfaced by the dev machine's own real disk (461 GB, 94% used, 30 GB free) — 30 GB is triple the old 10 GB default, yet the independent 93%-full check still blocked every recording.

**Resolution**: Raised `Min_disk_free_gb`'s default from `10.0` to `30.0` GB (both the struct's stored-property default and the decode fallback for configs that never persisted the key) — explicit user instruction, confirmed via `AskUserQuestion` that this should land as the *existing* setting's new default rather than a second, separate hardcoded floor. Still user-adjustable in Settings → Recording (1–100 GB range, unchanged). Worth knowing: this does **not** by itself change whether a drive over 93% full gets flagged — that check is independent and intentionally unaffected by this change (per the same clarifying question) — so a machine in the exact situation that surfaced this (30 GB free, 94% used) is still correctly flagged, just now for the 93%-full reason alone rather than both. Full suite verified green after the change (`swift test`); `docs/Config.md`'s config-key table updated to the new default.

**Resolving commit**: pending (uncommitted at time of writing)

---

# Full-codebase audit — 2026-08-16

Eight parallel review passes across every subsystem, the full `docs/*.md` tree, and all fourteen documented invariants (not a diff review — the whole tree treated as the change under review). The four high-severity findings were fixed same-day; three medium findings (`HDHRManager.swift` UDP DeviceID collapse, `RecordingManager.swift` `headerFiles` leak on spawn failure, `DiscordNotifier.swift` silent JSON-encode failure) were left open in `ISSUES.md` — not fixed as part of this pass.

## RESOLVED — `VLCBridge.releasePlayer()`'s use-after-free safety net was un-wired by the earlier async-teardown refactor

**File:** `VLCBridge.swift` (`releasePlayer()`)

**Root cause**: `retainedDrawable`'s whole job is keeping the drawable `NSView` alive until *after* `_mpRelease` drains libvlc's off-main-thread callbacks (doc comment at the property; `docs/VLCBridge.md:300-302`). The 2026-08-15 fix for the `input_Close`/`pthread_join` deadlock (see this file's "recording-relay seek path" entry, `ISSUES.md`) correctly moved the actual `libvlc_media_player_release` call onto `VLCBridge.libvlcQueue.async` — but left `retainedDrawable = nil` / `drawableView = nil` running synchronously *before* that async block was even enqueued. If nothing else retained the view at that instant (the window-close case this code exists for), ARC could free it immediately while libvlc's deferred drawable callbacks were still in flight against it — the deadlock fix reopened the exact use-after-free window it was adjacent to. Found 2026-08-16 during a full-codebase audit; not previously logged.

**Resolution**: Moved both nil-outs into the `libvlcQueue.async` block, after `releaseFn?(mp)` returns, wrapped in `Task { @MainActor [weak self] in ... }`. Guarded on `self.mediaPlayer == nil` before clearing — a quick reopen via `ensurePlayer()` in the interim (which reuses `drawableView` if still set, per its own logic) creates a new `mediaPlayer` and legitimately reattaches the same view, and this guard prevents the now-stale deferred clear from clobbering that newer state. `swift build` clean; full test suite green aside from the two pre-existing, environment-flaky `AppStateRecordingEngineTests` (confirmed pre-existing by reproducing identically against the pre-fix code via `git stash`).

**Resolving commit**: pending (uncommitted at time of writing)

---

## RESOLVED — Cloud `DeviceAuth` credential logged in cleartext on every guide fetch

**File:** `GuideStore.swift` (`load`, `loadXMLTV`, `fetchAndIndex`)

**Root cause**: `glog("[\(id)] GET \(url.absoluteString)")` embedded the live `DeviceAuth=` token straight into the logged request URL, and two other lines (`load()`/`loadXMLTV()`'s own entry logs) logged the raw token value directly. Fired on every hourly/manual/startup guide load — not a debug-only path — so a user following the project's own documented troubleshooting flow (`tail`-ing `hdhrVCRplus.log`, or handing it to `log-detective`/a GitHub issue) would unknowingly leak a bearer credential for their SiliconDust cloud account. The log's ~2.5-week retention window meant multiple rotated tokens could accumulate over a long-running session. Found 2026-08-16 during a full-codebase audit.

**Resolution**: Added `GuideStore.redactingDeviceAuth(_:)`, which masks the `DeviceAuth=` query-param value (up to the next `&` or end of string) before a URL reaches `glog`. The two entry-log lines now log `"present"`/`"nil"` instead of the raw token, matching the pattern already used by the existing URL-build-failure error log a few lines away. `swift build` clean.

**Resolving commit**: pending (uncommitted at time of writing)

---

## RESOLVED — `/api/watch-recording` could stream a finished recording indefinitely, not just a live one

**File:** `WebServer.swift` (`handleWatchRecording`)

**Root cause**: The handler only checked that `show.show_recording_path` was non-empty, never that the show was still actually recording. `show_recording_path` is set once when a recording starts and is never cleared when it ends, and `show_id` values are visible in plain `data-show-id`/`data-id` attributes throughout the served guide HTML — so any LAN client could replay a finished show's `show_id` against this route and stream the raw file indefinitely, well past the "Watch Now!" live-relay use case `docs/WebServer.md:226-238` documents this route for. Found 2026-08-16 during a full-codebase audit.

**Resolution**: Added `show.show_recording` to the existing guard alongside the non-empty path check. The scrub-bar reconnect path this route also serves (per the function's own doc comment) is unaffected — it only ever reconnects while a recording is genuinely still in progress, i.e. `show_recording == true`. `swift build` clean.

**Resolving commit**: pending (uncommitted at time of writing)

---

## RESOLVED — Several `scheduleNextAir` reschedule paths left the web guide showing a stale schedule for up to ~59 minutes

**File:** `AppState.swift` (`stopRecording(index:natural:)`, `idleLoop()`)

**Root cause**: This is the same bug class already fixed once for the SeriesID-reconfirm path (see this file's "no episode found in guide" entry above, which added a `show_updated` broadcast specifically so "an open web guide doesn't show stale schedule info") — but the fix was never carried to the other reschedule call sites. `stopRecording(index:natural:)`'s main success-path reschedule didn't broadcast (its neighboring "OVERRIDE CLEARED" branch two lines away did), nor did its manual-stop `show_paused = true` branch or its empty-file-failure branch; `idleLoop()`'s own direct `scheduleNextAir` calls for auto-resuming a paused show and for advancing a stranded past-due `show_next` also didn't — the idle loop's end-of-tick only called `saveConfig()`/`rebuildMenuEntries()` (menu only, not the web UI). A finished recurring show could sit with the wrong next-airing time/channel shown in any open web guide tab until some unrelated event (another show's add/edit/delete/favorite-toggle, or the top-of-hour refresh) happened to trigger a rebuild. Found 2026-08-16 during a full-codebase audit.

**Resolution**: Added the same `pushShowUpdate(type: "show_updated", ...)` call already used correctly by `skipRecording` and the SeriesID-reconfirm branch to all five gaps — each re-resolving the show by `show_id` after its `await scheduleNextAir(...)` call (rather than reusing a possibly-stale index or pre-reschedule channel/device) so the broadcast reflects any device/channel migration the reschedule itself performed. All five use `rebuildMenu: false`, matching the sibling calls in the same functions — the idle-loop paths already get a menu rebuild from the loop's own end-of-tick `rebuildMenuEntries()` call, so this only adds the missing web-UI push. `swift build` clean; full test suite green aside from the two pre-existing, environment-flaky `AppStateRecordingEngineTests` (confirmed pre-existing via `git stash`).

**Resolving commit**: pending (uncommitted at time of writing)

---

## RESOLVED — Single-tuner setups never showed a "selected" (blue) tuner box on guide load

**File:** `Resources/guide.js` (`setDev`)

**Root cause**: `WebServer.swift`'s `defaultDev` computation is `""` (not a real device ID) whenever there's exactly one device — `setDev('{{DEFAULT_DEV}}')` at bootstrap therefore called `setDev('')`. `setDev`'s `.d-sel` toggle matched `.d-btn` elements by `b.dataset.dev===id`, and every real tuner button's `data-dev` is its actual device ID — never `''` — so no box ever matched and the sole tuner (the overwhelmingly common single-HDHomeRun setup) loaded with nothing visually marked as selected, even though it was already functionally the active filter (per the existing "second click opens the popover" logic, which already assumed the default tuner "starts out already selected"). Reported by the user 2026-08-16: "if a guide view is shown as the default hdhr model, highlight that in blue, like it is selected."

**Resolution**: `setDev`'s `.d-sel` toggle now special-cases the empty-`id` path: when `id` is falsy, it highlights the tuner box instead of matching by `data-dev` — specifically, whichever online `.d-btn[data-dev]` element is the only one present (offline tuners render as a `<span>` with no `data-dev`, so they're never eligible). This only ever applies in the single-online-tuner case, since a real `defaultDev` is used whenever there's more than one device online, so the fallback path is deliberately scoped to exactly that. Verified live against the running app (2 configured devices — one real, one the intentionally-kept fake `FFFF0001` test device that always renders offline — leaving exactly one online `.d-btn` to exercise the same code path): calling `setDev('')` directly in the browser console now applies `.d-sel` to the sole online tuner, confirmed against a side-by-side simulation of the old toggle logic which left both boxes unhighlighted. `node --check` (with `{{TOKEN}}` placeholders stripped) confirms syntax; deployed via `./deploy.sh` (full rebuild + resource copy + relaunch + post-deploy perf suite, all green) before verification. `docs/WebServer.md` updated (the "Default tuner" note and the `setDev(id)` table row) to describe the highlight explicitly instead of only the row-filtering behavior.

**Resolving commit**: pending (uncommitted at time of writing)

---

# Three medium findings + three test-coverage gaps — 2026-08-16

The three remaining medium-severity findings from the full-codebase audit, plus the three
test-coverage gaps from the same pass, fixed and added in one session.

## RESOLVED — UDP discovery reply with no DeviceID TLV silently collapsed two tuners into one

**File:** `HDHRManager.swift` (`udpDiscoverSync`)

**Root cause**: `deviceID` defaulted to `UInt32 = 0` and was only overwritten if the reply's TLV payload actually carried tag `0x02`. A reply that omitted or truncated it was recorded as `DeviceID: "00000000"` — indistinguishable from a second such device, so `discoverDevices()`'s DeviceID-based dedup would silently drop the second one, dropping a whole tuner with nothing logged.

**Resolution**: `deviceID` is now `UInt32?`, defaulting to `nil`; after the TLV loop, a reply with no DeviceID (`guard let deviceID else { ...; continue }`) is skipped with a warning logged instead of recorded under a colliding sentinel. `swift build` clean.

**Resolving commit**: pending (uncommitted at time of writing)

---

## RESOLVED — `RecordingManager.headerFiles[showId]` leaked if `posix_spawn` failed

**File:** `RecordingManager.swift` (`start()`)

**Root cause**: `headerFiles[showId] = hdrPath` was set unconditionally before the `try spawnDetached(...)` call, which can throw. A persistently-failing spawn (bad executable permissions, out of process slots) would leave that entry orphaned for the life of the app session if the show was then deleted before ever successfully starting — the same shape as the documented "new show_id-keyed tracking table must be cleared in deleteShow" invariant, just one level down inside `RecordingManager` rather than `AppState`.

**Resolution**: The spawn call is now wrapped in its own `do`/`catch`; on failure, `headerFiles.removeValue(forKey: showId)` runs before rethrowing (`pids[showId]` is never set on this path, so there's nothing else to undo). `swift build` clean.

**Resolving commit**: pending (uncommitted at time of writing)

---

## RESOLVED — A malformed Discord embed's JSON-encode failure logged nowhere

**File:** `DiscordNotifier.swift` (`sendDiscordEmbed`, `sendDiscordEmbedCapturing`, `editDiscordEmbed`)

**Root cause**: All three send functions did `guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }` before any of the send/failure logging that follows — the one branch with zero trace in either `glog` or `discordLog`, unlike every other failure path in the same functions (bad response type, non-2xx HTTP, network error), which all log to both. This made a malformed embed dict (a caller bug, not a network issue) the hardest failure class to diagnose from the logs `discordLog()` exists specifically to make reviewable.

**Resolution**: `let title = embedTitle(embed)` moved above the JSON-encode guard in all three functions so it's available for the failure log; the guard's `else` branch now logs to both `glog` and `discordLog` before returning/returning nil. `swift build` clean.

**Resolving commit**: pending (uncommitted at time of writing)

---

## RESOLVED — Bonus Time (sports-genre default + show_end padding) had zero test coverage

**File:** `Models.swift` (`Show.genreImpliesBonusTime`), `Views/AddShowView.swift`, `Tests/hdhr_VCRTests/Models/ShowTitleHelpersTests.swift`, `Tests/hdhr_VCRTests/Recording/AppStateRecordingEngineTests.swift`

**Root cause of the coverage gap**: the earlier audit finding attributed the sports-genre default to a nonexistent `applyGuideEntry()` function in `AppState.swift`; the real logic turned out to be duplicated across three places — `AddShowView.swift`'s `applyPendingEntry`/`applyWebGuideEntry` (both `private` methods on a SwiftUI View struct, not practically unit-testable as written) and `guide.js`'s client-side `_isSports` check. Only the `Sports_padding_minutes` extension arithmetic in `AppState.startRecording` was both testable and untested.

**Also found in the process**: `applyWebGuideEntry` matched only `"sports"` while `applyPendingEntry` and `guide.js` both matched `"sport"` — silently missing XMLTV's singular `"Sport"` category tag on the web-guide-driven entry path, a real (if narrow) behavioral divergence between the app's two Add-Show entry paths.

**Resolution**: Extracted the genre check into a shared `Show.genreImpliesBonusTime(_:)` static helper (`Models.swift`) using the correct `"sport"` substring match, and pointed both `AddShowView.swift` call sites at it — fixing the drift as a side effect of making the logic testable at all. Added a parameterized test table (`GenreImpliesBonusTimeTests`) pinning the match contract, plus three `AppState.startRecording` tests covering the padding-enabled/padding-disabled/show-opted-out combinations for the arithmetic itself. `guide.js`'s independent copy is unchanged (JS, outside this test suite's reach) but now has two, not three, Swift/JS copies to stay in sync with.

**Resolving commit**: pending (uncommitted at time of writing)

---

## RESOLVED — Idle-loop / `scheduleNextAir` stale-index-across-`await` safety had only happy-path coverage

**File:** `AppState.swift` (new `guideStore` injection seam), `Tests/hdhr_VCRTests/Recording/AppStateIdleLoopStaleIndexTests.swift` (new), `Tests/hdhr_VCRTests/TestFixtures.swift`

**Root cause of the coverage gap**: the documented invariant ("re-resolve `shows` by `show_id` after any `await`, never reuse a captured `Int` index") only has a real suspension point to test against for `.seriesChannel`/`.seriesAll` shows — `scheduleNextAir` never `await`s anything for `.single`/`.dateTime` shows, since they have no network dependency. Testing the series-show path needs a mocked guide fetch, which needs `AppState`'s `guideStore` to be injectable — it wasn't (unlike `recordingManager`/`configManager`).

**Resolution**: Added a `guideStore: GuideStore? = nil` init parameter to `AppState` (same optional-injection pattern as `recordingManager`, required for the same reason — both are `@MainActor` types, so a default *parameter value* expression can't construct one inline in the signature) and threaded it through `makeTestAppState`. The new test file mocks `GuideStore`'s `URLSession` and, from inside the mock's `requestHandler` closure — which runs synchronously as part of producing the HTTP response, guaranteeing it lands *during* `scheduleNextAir`'s `await guideStore.load(...)` suspension — mutates `state.shows` via `DispatchQueue.main.sync` (safe to reach the `@MainActor`-isolated property this way since the actor's underlying executor is the main thread, and `scheduleNextAir` is genuinely suspended off of it at that moment). Two tests: one deletes the show mid-fetch and asserts `scheduleNextAir` returns cleanly instead of trapping on the stale index; one inserts a decoy show ahead of it and asserts the eventual guide match is written to the *correct*, re-resolved show rather than clobbering whatever now sits at the original index. Needed `.serialized` on the suite (two tests sharing one mock protocol's static handler slot — same race `GuideStoreTests.swift` already documents and guards against).

**Also fixed in the process**: both new `AppState.startRecording` disk-gate tests above, and — tracing why they and the pre-existing `startRecording_happyPath_marksRecordingAndLaunchesRealProcess`/`idleLoop_startsShowWhoseWindowIsOpen`/`startRecording_launchFailure_recordsFailureWithoutMarkingRecording` tests had been intermittently failing all session (previously assumed pure environment flakiness, confirmed pre-existing via `git stash` earlier) — root-caused to `diskOK`'s independent `Min_disk_free_gb` free-space check: tests set `state.maxDiskPct = 100` to neutralize the percent-full check, but never touched the separate absolute-free-space floor (default 30 GB), so a test machine genuinely below that threshold failed every disk-gated test regardless of `maxDiskPct`. Added `state.config.Min_disk_free_gb = 0` alongside every existing `state.maxDiskPct = 100` in `AppStateRecordingEngineTests.swift`, which also resolved the previously-flaky tests as a side effect — not a coincidence, the same root cause.

**Resolving commit**: pending (uncommitted at time of writing)

---

# Tight skip/reschedule loop on already-recorded reruns — 2026-08-19

## RESOLVED — `GuideStore.currentEpisode` re-offered a known duplicate as the "on air" match, spinning `scheduleNextAir` in a ~10s retry loop for an episode's entire broadcast window

**File:** `GuideStore.swift` (`currentEpisode`), `Tests/hdhr_VCRTests/Network/GuideStoreTests.swift`

**Reported as:** "we are getting a lot of skipped episodes" — user asked whether this was correct behavior or a stale-cache bug. It was neither a normal rate of skips nor a cache problem; the on-disk duplicate check itself (`recordedEpisodeTags`) does a live, uncached `FileManager` scan on every call.

**Root cause**: found by reading `~/Library/Logs/hdhrVCRplus.log` — two shows ("The Parkers", "Star Trek: The Next Generation") each logged "SKIP — already recorded" for the *same* episode tag exactly once every 10 seconds for a full hour (360 occurrences each, 720 total in one day), each pairing a log line with a Discord "Skipped" card. Traced to `AppState.startRecording`'s duplicate check calling `scheduleNextAir` on every skip, which (for `.seriesChannel`/`.seriesAll`) calls `GuideStore.currentEpisode(...)` first to catch an in-progress airing. `currentEpisode`'s `preferUnrecorded` tie-break only activated when `candidates.count > 1`; for the ordinary single-channel case (exactly one candidate airing right now) it fell through to returning that candidate regardless of whether it was already recorded. Since the episode was still on air, `show_next` got set to a time already in the past, so the 10s idle loop immediately re-attempted `startRecording`, which skipped it again, called `scheduleNextAir` again, and got the exact same still-on-air duplicate back — a self-sustaining loop bounded only by how long that guide entry stayed on the air.

**Resolution**: `currentEpisode` now returns `nil` (not `first`) when every currently-airing candidate is confirmed already-recorded — including the single-candidate case, which previously had "nothing to tie-break against" and skipped the check entirely. This lets `scheduleNextAir` fall through to `nextEpisode`, which finds the actual next distinct future airing instead of re-selecting the stable, known-duplicate one. `nextEpisode`'s own behavior (return `first` even if it's a duplicate, for *future* candidates) is intentionally unchanged — a future entry's duplicate status can still change before it airs, so the real check correctly stays deferred to record time there; only `currentEpisode`'s "airing right now" case is a fact that's already fully known and won't change before the next idle-loop tick. Added `currentEpisode_preferUnrecorded_singleCandidateAlreadyRecorded_returnsNil` and a companion `..._singleCandidateNotRecorded_returnsIt` regression test (narrowing the existing two-channel simulcast fixture to one channel via `channelNum` to get a genuine single-candidate lookup). Full suite (316 tests) passes.

**Resolving commit**: pending (uncommitted at time of writing)

---

## RESOLVED — `resumeShow`/idleLoop's three resume paths didn't re-arm `notify_upnext_time`/`notify_recording_time`

**File:** `AppState.swift` (`applyResume`, and the two inline mutation sites in idleLoop's Pass 2 generic "paused window expired" auto-resume), `Tests/hdhr_VCRTests/Recording/AppStateRecordingEngineTests.swift`

**Root cause**: `notify_upnext_time`/`notify_recording_time` are cooldown markers — set to `now + Notify_upnext`/`Notify_recording` minutes after a pre-recording notification fires, so the same imminent airing doesn't re-notify on every subsequent idle-loop tick while it's still within the window. None of the three places a show transitions from paused back to active (`resumeShow`, idleLoop's tuner-detection auto-resume, and the older generic "paused window expired"/"next airing imminent" auto-resume) ever cleared these markers. A show paused after its "Up Next" notification had already fired, then resumed once the recording-soon window had also passed unnoticed (paused the whole time — Pass 2's notification block is skipped entirely for a paused show), would never get its "Recording Soon" heads-up at all for that occurrence: not because of a stale-cooldown suppression exactly, but because the window during which it *could* fire simply elapsed while paused, with nothing to compensate for it on resume. The recording itself was never affected — only the pre-notification.

**Resolution**: `applyResume` (used by both manual `resumeShow` and idleLoop's tuner-detection auto-resume) now also sets `notify_upnext_time`/`notify_recording_time` to `nil`; the two inline `show_paused = false` sites in idleLoop's older generic auto-resume (not routed through `applyResume`, since that branch also calls `scheduleNextAir`) got the same two lines added directly. This doesn't force an immediate notification — it just clears any stale cooldown so the normal `minutesAway`-window check gets a clean slate the next time it's evaluated, firing only if that window is genuinely open on some later tick. Added three regression tests: `idleLoop_autoResumesShowOnceItsTunerIsDetectedAgain` (extended with cooldown-clearing assertions), `resumeShow_rearmsNotificationCooldowns` (new — `resumeShow` had zero prior test coverage), and `idleLoop_genericWindowExpiredAutoResume_rearmsNotificationCooldowns` (new, exercises the third, previously-untested resume path). Full suite (262 tests) passes.

**Resolving commit**: `85f4f08`

---

## RESOLVED — Two more resume paths missed by the `notify_upnext_time`/`notify_recording_time` re-arm fix above

**File:** `AppState.swift` (`reactivatePausedShows`), `WebServer.swift` (`handleEdit`'s pause toggle), `Tests/hdhr_VCRTests/Recording/AppStateRecordingEngineTests.swift`

**Found by**: a 2026-08-19 time-boxed parallel-agent review sweep, run immediately after the fix above — one of the six agents was specifically tasked with re-auditing `AppState.swift` for anything the same session's own recent changes might have missed, and found that the fix above's resolved entry explicitly enumerates only three resume paths (`resumeShow`, idleLoop's tuner-detection auto-resume, idleLoop's generic "paused window expired" auto-resume) — two more `show_paused = false` sites existed outside that enumeration and were never touched.

**Root cause**: `reactivatePausedShows()` (Settings → Maintenance's bulk "Reactivate Paused Shows" action) predates `applyResume` and doesn't route through it — a plain `for` loop over every show, flipping `show_paused` directly. `WebServer.handleEdit`'s pause-toggle handling (the web guide Edit modal's pause/resume checkbox — the everyday resume path for anyone using the web UI, not the native app) builds a standalone `updated: Show` value that's committed later via `state.updateShow(_:)`, rather than mutating `AppState.shows` by index, so it structurally can't call the index-based `applyResume(index:)` either. Both were real, live gaps: a show paused after its "Up Next" notification, then resumed through either of these two paths, would still silently miss its "Recording Soon" heads-up for the next occurrence — the exact bug the fix above targeted, just via two paths that fix didn't cover.

**Resolution**: `reactivatePausedShows()` now clears `notify_upnext_time`/`notify_recording_time` inline inside its existing `if shows[i].show_paused` branch — deliberately *not* routed through `applyResume` itself, since that also fires a per-show `pushShowUpdate` broadcast that this bulk action never had before; adopting it wholesale could mean many broadcasts in one tight loop for a large paused-show list, a new side effect nobody asked for. `WebServer.handleEdit`'s un-pause branch now also clears `updated.notify_upnext_time`/`updated.notify_recording_time`, plus `state.showRetryAfter.removeValue(forKey: updated.show_id)` directly (`showRetryAfter` lives on `AppState`, not `Show`, so it can't be cleared via the local `updated` value the way the notify fields can). Added `reactivatePausedShows_rearmsNotificationCooldowns` regression test; `handleEdit`'s path was verified by build only — no existing test infrastructure exercises `/api/edit` at the HTTP level, and building one from scratch was out of scope for this fix. Full suite (276 tests) passes.

**Resolving commit**: `47d925f`

---

## RESOLVED — `RecordingManager.spawnDetached`'s curl (and every other spawned/inherited fd holder) inherited the app's entire open-fd table

**File:** `RecordingManager.swift` (`spawnDetached`), `Models.swift` (`RotatingLogFile.open`)

**Found by**: the 2026-08-19 parallel review sweep (logged in `ISSUES.md`), fixed 2026-08-20.

**Root cause**: `spawnDetached`'s `posix_spawnattr_setflags` call set only `POSIX_SPAWN_SETSID` — never `POSIX_SPAWN_CLOEXEC_DEFAULT` — so curl (deliberately `SETSID`'d to survive a force-quit of the parent) inherited every fd open at spawn time: the `NWListener` socket, all three `RotatingLogFile`-backed log handles, and live SSE connections. Only fds 0/1/2 were explicitly redirected via `posix_spawn_file_actions_addopen`. Separately, `RotatingLogFile.open()`'s `FileHandle(forWritingAtPath:)` never marked its own fd `FD_CLOEXEC`, so the same log-fd inheritance also applied to every *other* spawned child, not just curl — including `AppState`'s post-recording script hook (`Process()`-spawned, non-`SETSID`'d, can run arbitrary user-authored `/bin/sh` scripts for however long they take) and `reattachRecordings()`'s `ps` call.

**Failure scenario**: app is force-quit or crashes while a recording is running and the web server has open SSE connections — exactly the scenario `spawnDetached`'s `SETSID` design exists to survive. The orphaned curl process holds duplicate fds to the listener socket/logs/SSE sockets for the rest of the recording (potentially hours); those SSE client sockets don't fully close at the OS level until curl also exits.

**Resolution**: OR'd `POSIX_SPAWN_CLOEXEC_DEFAULT` into `spawnDetached`'s existing `posix_spawnattr_setflags` call — the standard Darwin idiom (all fds close-on-exec except ones explicitly added via `file_actions`, which are actively opened in the child rather than inherited, so the three stdin/stdout/stderr redirects are unaffected). Separately added `fcntl(fh.fileDescriptor, F_SETFD, FD_CLOEXEC)` right after `RotatingLogFile.open()` obtains its handle — this covers all three log files (main, Discord, curl-verbose, per CLAUDE.md) and closes the gap for every spawn path at once (curl, the post-recording script hook, `ps`), not just `spawnDetached`'s own. The `NWListener` socket's raw fd isn't exposed by Network.framework's public API, so it has no equivalent direct fix — it's covered only indirectly, by curl no longer inheriting it via `CLOEXEC_DEFAULT`. Verified via `RecordingManagerTests` (exercises `spawnDetached` through a real spawn/reap cycle against a test-double script) plus a full deploy + web-server perf-test pass; not verified against a live real-device recording (none was in progress at the time, and the flag-only nature of the change didn't warrant standing one up). Full suite (276 tests) passes.

**Resolving commit**: `40f15fa`

---

## RESOLVED — `GuideStore.currentEntryByTitle`/`nextEntryByTitle` picked a non-deterministic channel on a multi-channel tie, and had no favorite/unrecorded tie-break at all

**File:** `GuideStore.swift` (`currentEntryByTitle`, `nextEntryByTitle`, new private `titleFallbackScanKeys`), `AppState.swift` (`resolveSeriesAir`, `scheduleNextAir` call sites), `Tests/hdhr_VCRTests/Network/GuideStoreTests.swift`

**Found by**: the 2026-08-19 review sweep (`ISSUES.md`), fixed 2026-08-20.

**Root cause**: the title-only SeriesID-less fallback tier (used whenever a `seriesAll`/`seriesChannel` show's guide entries lack a SeriesID tag) scanned `channelEntryIndex.values.flatMap({ $0 })` — `channelEntryIndex` is a `[String: [GuideEntry]]` Dictionary, so `.values` iteration order is hash-based and can reorder across `buildIndex` rebuilds (every guide refresh). `currentEntryByTitle` picked `.first(where:)` off that unordered sequence; `nextEntryByTitle` used `.min(by: StartTime)`, deterministic for the *soonest* airing but not for a tie at the same StartTime, since `min(by:)` keeps the first-encountered element on a tie and "first encountered" was itself dictionary-order-dependent. Neither function accepted `preferFavorite`/`preferUnrecorded` at all, unlike `currentEpisode`/`nextEpisode` (hardened for the identical tie scenario this session via `cac5207`/`3b63615`).

**Failure scenario**: a `seriesAll` show without a SeriesID on a given occasion (e.g. "Local News") simulcasts on two channels of its assigned tuner; `resolveSeriesAir`/`scheduleNextAir` write whichever match came back straight into `show_channel`/`hdhr_record`. With no tie-break pinned to anything, different guide reloads could hand back a different channel on different idle-loop reconfirm passes — the show's assigned channel could silently flip between the two over time.

**Resolution**: both functions now scan via a new private `titleFallbackScanKeys(deviceId:)` — lineup order (mirrors `buildIndex`'s own channel-iteration order, the same source of determinism `seriesIndex`'s stable sort already relies on) instead of `channelEntryIndex`'s raw dictionary order — and both gained `preferUnrecorded`/`preferFavorite` parameters with the same tie-break logic as `currentEpisode`/`nextEpisode` (`currentEntryByTitle` applies it across every currently-airing candidate, since all are inherently concurrent; `nextEntryByTitle` narrows to the StartTime-tied prefix first, since future candidates aren't inherently concurrent). The four real call sites (`resolveSeriesAir`'s and `scheduleNextAir`'s title-fallback tiers) now pass `preferUnrecorded: preferUnrecordedEpisode(for: show), preferFavorite: isFavoriteChannel` — previously passed to the neighboring `currentEpisode`/`nextEpisode` calls but not to these. Added 4 regression tests (`current_noPreference_picksLineupOrderWinner`, `current_preferFavorite_picksFavoritedChannel`, `next_preferFavorite_picksFavoritedChannel`, `next_noPreference_picksLineupOrderWinner`) against a new title-only simulcast fixture. Full suite (280 tests) passes; deployed and confirmed the running app still serves guide/API correctly.

**Resolving commit**: `10e91e5`

---

## RESOLVED — `AddShowView.switchToAiring` didn't recompute `show_bonus_time` when re-anchoring to a different airing

**File:** `Views/AddShowView.swift` (`switchToAiring`)

**Found by**: the 2026-08-19 review sweep (`ISSUES.md`), fixed 2026-08-20.

**Root cause**: `switchToAiring` (the handler for double-clicking an "Other Upcoming Airings" row to re-anchor Add Show to a different occurrence of the same series) updated `show.show_genre` but never recomputed `show.show_bonus_time` from it — unlike the two other entry points that set a genre, `applyWebGuideEntry`/`applyPendingEntry`, which both immediately follow with `Show.genreImpliesBonusTime(genre) && state.config.Sports_padding_enabled`.

**Failure scenario**: pick an initial non-sports airing (Bonus Time defaults off), then double-click an "Other Upcoming Airings" row that's a sports broadcast of the same series — genre flips to "Sports" but the Bonus Time toggle silently stays off, so the recording schedules without the sports padding the genre would otherwise default to. Same gap in reverse (sports → non-sports leaves a stale `true`).

**Resolution**: `switchToAiring` now recomputes `show.show_bonus_time = Show.genreImpliesBonusTime(show.show_genre) && state.config.Sports_padding_enabled` right after setting `show_genre`, the same formula the other two entry points use. `switchToAiring` is a private method on a SwiftUI view with no existing unit-test seam (same boundary as `WebServer.handleEdit`'s un-pause branch in the fix two entries above) — verified by build only.

**Resolving commit**: `10e91e5`

---

# Live session fixes — 2026-08-21

Three bugs reported/found during a single interactive session, fixed and verified in place (build + full test suite + live browser reproduction where applicable) before moving to the next.

## RESOLVED — Web guide's hover-prefetch fired 100+ concurrent fetches from a single mouse sweep, delaying unrelated clicks

**File:** `Resources/guide.js` (`mouseover` listener added this same session, immediately after being added)

**Root cause**: a delegated `document`-level `mouseover` listener, added to warm the Summary panel's lazy-loaded fields (`fetchRowHeavy`) before a click needs them, fired on every `.g-prog` tile the cursor entered — including tiles merely passed over en route elsewhere, since `mouseover` fires per element-boundary crossing, not per intentional hover. Measured: dispatching synthetic `mouseover` across all `.g-prog` tiles in a real ~2600-tile guide triggered 103 concurrent `fetch()` calls to `/api/guide-detail` instantly.

**Failure scenario**: any normal mouse movement across the grid (e.g. moving from the top nav down to click a tile) crossed many rows, each firing a real network request. The resulting request pile-up backed up the MainActor-serialized `WebServer`, so unrelated click-driven requests (record, edit, tuner popover) queued behind it and felt delayed — reported by the user as "everything is delayed when clicking, seemed faster recently."

**Resolution**: gated the listener behind a ~150ms dwell timer (`_hoverPrefetchTimer`/`_hoverPrefetchEl`) — a fetch only fires if the pointer stays on the same tile past the timer; a new tile hovered before that clears the pending timer without fetching. Verified live: the same full-grid sweep now fires zero immediate fetches (down from 103); a genuine hover-and-pause still fires exactly one after the dwell period.

**Resolving commit**: pending (uncommitted at time of writing)

## RESOLVED — Web guide's selected tuner card needed two clicks to open its popover on a single-online-tuner setup

**File:** `Resources/guide.js` (`handleDevClick`)

**Root cause**: a single-online-tuner setup bootstraps with `setDev('')` (`WebServer.swift`'s `defaultDev` is forced to `""` whenever there's exactly one online device), so `curDev` starts out `''`. `handleDevClick`'s "already selected, open the popover" check was `id === curDev` — but the clicked button's `id` is always its real device ID, never `''`, so that check could never match on the very first click even though the tuner already read as visually selected (`.d-sel`). The first click silently no-op'd (a same-device `setDev(id)` reselect, which set `curDev` to the real ID); only the *second* click then matched and opened the popover.

**Failure scenario**: reported by the user 2026-08-21: "when i click the tuner card at the top, it doesnt open the tuner float menu as it used to." Reproduced live in a browser session against the actual single-real-tuner setup (a second configured device is the always-offline `FFFF0001` test fixture, so only one `.d-btn[data-dev]` button exists) — first click did nothing, second opened the popover.

**Resolution**: `handleDevClick` now also treats `curDev === '' && ` this is the sole online tuner button as "already selected" — the exact same `onlineBtns.length===1` rule `setDev` already uses for the `.d-sel` visual highlight, so the click behavior now matches what's on screen. Multi-tuner setups were never affected (their bootstrap `defaultDev` is always a real device ID). Verified live via a real DOM `.click()` dispatch on a freshly-loaded page — popover opened on the first click.

**Resolving commit**: pending (uncommitted at time of writing)

## RESOLVED — A channel stayed in the web guide's "Recording" section after its recording ended

**File:** `AppState.swift` (`teardownRecordingState`)

**Root cause**: the Recording/Favorites/Other row buckets (`buildGuideGridHTML`) are decided once, at grid-build time. Recording start/stop only ever pushed a lightweight fragment patch (`broadcastRecordingEvent` — ring color + tuner badge, patched onto the existing DOM in place); nothing rebuilt or re-swapped the grid itself, so a channel's row never physically moved between sections until some *unrelated* guide-changing event (an edit, another show starting, the hourly refresh) happened to trigger a full rebuild.

**Failure scenario**: reported by the user 2026-08-21: a channel whose recording had already ended stayed visually pinned at the top of the guide's Recording section, misleadingly, until something else refreshed the grid.

**Resolution**: `teardownRecordingState` (the single choke point for every stop path — natural end, manual stop, tuner-missing auto-pause, app-quit cleanup) now also fires `broadcastGuideChangeEvent` right after the existing `broadcastRecordingEvent` call, pushing a real full-grid rebuild through the same well-tested `applyGuidePayload` path used by add/edit/delete/pause/resume/favorite-toggle (preserves scroll position and the current Summary-panel selection). Scoped to the *stop* side only, matching what was reported — starting a recording still doesn't move the row into the Recording section immediately, only the ring color updates in place, and stays that way until the next full rebuild. Deliberately not deduped against the fragment patch's own grid-cache rebuild (two grid builds per stop event) — simpler and safer than merging the two broadcast paths, and stop events are infrequent enough that the extra cost is negligible.

**Resolving commit**: pending (uncommitted at time of writing)

## Staleness check, 2026-08-10

Every entry above that only had a prescriptive `**Fix:**` note (rather than a past-tense `**Resolution:**`) was individually re-verified against the current source before filing here — grepped for the described symptom and confirmed the described fix's actual code is present (or, for the FloatingGuideView/CableGuideView group, confirmed the file is gone entirely). Nothing in this file is guessed or assumed still-true from the original write-up.

---

## RESOLVED — A skip-eligible episode showed a false "Recording now" ring for its entire time slot

**File:** `AppState.swift` — `pendingRecordingChannels(for:)`

**Root cause**: `pendingRecordingChannels` treats any show with `show_next ≤ now < show_end` and `show_recording == false` as "about to start" (meant for the brief, normal startup lag between a show's scheduled time and `RecordingManager` actually flipping the flag). But when `Skip_recorded_episodes` is on and the on-air episode is already on disk, `startRecording` deliberately never flips `show_recording` — it logs `SKIP` and calls `scheduleNextAir`, which (since `GuideStore` checks the currently-airing episode first) just resolves back to the same still-airing episode, repeating every idle tick for the rest of that airing's window. The show sat in the "about to start" window indefinitely, misread as "recording" by both the web guide and Watch Now (both consume this same function) instead of showing the skip badge. Menu bar and tuner count were unaffected — they read the real `show_recording`/`recordingShows`, not this function.

**Reported**: live, via a screenshot showing "Star Trek: The Next Generation" ringed red as "Recording now" in the web guide and Watch Now while the menu bar correctly listed it under Scheduled and the tuner count read 0/2 — confirmed against the log (`SKIP S05E14 — already recorded` repeating every ~10s tick for the full 8:00–9:00 PM window).

**Resolution**: Added `willSkipCurrentAiring(_:)`, mirroring the exact skip-eligibility guard `startRecording` and `duplicateEpisodeTag(for:isSeries:baseDir:)` already use, and excluded it from `pendingRecordingChannels`. Verified live — the same episode now renders the slate `.g-st-skip` ring/badge instead of the false recording ring.

**Resolving commit**: pending (uncommitted at time of writing)

## RESOLVED — `ChannelIconCache.image(for:)` could double-download the same icon URL under concurrent requests

**File:** `ChannelIconCache.swift` — `image(for:)`

**Root cause**: flagged in ISSUES.md by the 2026-08-19 review sweep — the actor checked `mem`/`failedURLs`/on-disk cache all *before* its only `await` (`URLSession.shared.data(from:)`), and since the type is an `actor`, that await point makes the method reentrant: two overlapping calls for the same URL could both pass the miss checks before either wrote a result, each independently downloading and disk-writing the identical file.

**Resolution**: turned out to already be fixed by an earlier pass this same day (part of a broader `WebServer`/`AppState` performance sweep, unrelated to this specific ISSUES.md entry at the time) — an `inFlight: [String: Task<NSImage?, Never>]` dict now de-dupes concurrent callers: a second caller for a URL already being fetched awaits the same in-flight `Task` instead of starting its own. Confirmed by reading the current code (`ChannelIconCache.swift:18,68-74`) that the fix fully closes the described race. No further code change needed here — just moving this entry out of the open-issues list to reflect reality.

**Resolving commit**: pending (uncommitted at time of writing)

## RESOLVED — Web guide's per-tuner dropdown could go permanently stale for offline/undiscovered devices

**File:** `WebServer.swift` — `buildGuideRefreshPayload`, new `tdropDeviceIDs(state:)`

**Root cause**: flagged by the 2026-08-19 review sweep — `buildGuideRefreshPayload` only built a `tdrop` (per-tuner dropdown) SSE payload entry for `state.usableDeviceIDs` (discovered *and* reachable), but `buildDevBarHTML` renders a real dropdown DOM element for two more categories per CLAUDE.md's "Web guide offline devices" invariant: a previously-discovered device gone unreachable, and a device referenced by some show's `hdhr_record` that was never discovered at all. `guide.js`'s `applyGuidePayload` only updates a dropdown whose device key is present in the pushed payload — never clears or flags a missing one — so either category's dropdown went stale after any edit/delete/pause/resume broadcast, permanently for a never-discovered device (it has no "come back online" moment to trigger a full rebuild).

**Resolution**: added `tdropDeviceIDs(state:)`, unioning `state.usableDeviceIDs` with every show's `hdhr_record` (matching the device set `buildDevBarHTML` actually renders boxes for), and switched `buildGuideRefreshPayload`'s tdrop-building loop to iterate that instead of `usableDeviceIDs` alone. Build + full test suite pass.

**Resolving commit**: pending (uncommitted at time of writing)

## RESOLVED — The whole LAN web server ran on one serial queue, so a stalled disk read could freeze it for every client

**File:** `WebServer.swift` — new `fileIOQueue`; `handleWatchRecording`, `streamGrowingFile`, `pumpGrowingFile`, new `handleGrowingFileChunk`

**Root cause**: flagged by the 2026-08-19 review sweep — the single serial `queue` backed *everything*: accepting connections, all other clients' request/response I/O, SSE keepalives, and the Watch Now relay's synchronous `FileHandle`/`handle.readData(ofLength:)` disk reads. A slow/contended external or network-mounted recording volume stalling that read froze the entire web server — no guide loads, no `/api/record`/`/api/edit`, no SSE keepalives — for every other LAN client, not just the one streaming connection. Same architectural class as the already-fixed `RecordingManager.stop()` blocking-`waitpid` bug.

**Resolution**: added a dedicated `fileIOQueue` (serial, `.utility`) for exactly the blocking file operations — `FileHandle` open/seek/`attributesOfItem`, `readData(ofLength:)`, `closeFile()` — while every actual `NWConnection` interaction (`send`) stays on the original `queue`. `pumpGrowingFile` now dispatches its read to `fileIOQueue`, then hops the result back to `queue` via the new `handleGrowingFileChunk` to continue the existing send/wait/recurse logic unchanged. `fileIOQueue` is itself serial, so concurrent Watch Now sessions' disk reads still queue relative to each other (fine — avoids disk thrashing) but no longer contend with the network queue at all, closing the freeze. Build + full test suite pass.

**Resolving commit**: pending (uncommitted at time of writing)

## RESOLVED — `GuideStore.buildIndex` never pruned `channelEntryIndex` for a channel dropped from a device's lineup

**File:** `GuideStore.swift` — `buildIndex(deviceId:channels:)`

**Root cause**: flagged by the 2026-08-19 review sweep (lower confidence/severity, self-limiting) — `buildIndex` explicitly dropped a device's stale `seriesIndex` entries before rebuilding, but only *overwrote* `channelEntryIndex` keys present in the new fetch, leaving a dropped channel's old `"device:channel"` entry lingering with stale data instead of being cleared — visible for up to the last fetch's `GuideHours` window (max ~28h) after the channel actually vanished.

**Resolution**: added a prune step mirroring the existing `seriesIndex` one — computes the fresh fetch's channel-number set, then removes any existing `channelEntryIndex` key for this device whose channel isn't in that set. Added `entries_channelDroppedFromLineup_isPrunedNotStale` (`Tests/hdhr_VCRTests/Network/GuideStoreTests.swift`): loads a 2-channel guide, confirms both channels' entries exist, reloads the same device with one channel dropped, confirms the dropped channel's entries are gone and the remaining channel's are untouched. Build + full test suite pass.

**Resolving commit**: pending (uncommitted at time of writing)

## RESOLVED — `VLCPlayerWindowManager.open()` reused the player window across devices without updating the hosted view

**File:** `Views/VLCPlayerView.swift` — `VLCPlayerWindowManager.open()`, new `hostingView` property

**Root cause**: flagged by the 2026-08-19 review sweep — `VLCPlayerView` takes `device`/`initialURL` as immutable `let`s, set only when the hosting `NSHostingView` is first created. `open()`'s "already open" reuse path updated the window title and called `VLCBridge.shared.play(url:)` with the new stream, but never touched the already-hosted view's `device` — even though `AppState.watchInApp` explicitly supports switching devices on an already-open window. With 2+ tuners, opening Watch Now on Tuner A then switching to a Tuner B channel without closing the player window correctly switched playback, but left the visible channel picker/lineup/recording-relay rows/quick-record target/tuner-status poll all still referencing Tuner A — picking any channel afterward could play or schedule against the wrong tuner.

**Resolution**: `VLCPlayerWindowManager` now keeps a typed `hostingView: NSHostingView<AnyView>?` reference. `open()` captures `deviceChanged = currentDeviceID != device.DeviceID` before overwriting `currentDeviceID`; on a reuse where the device actually changed, it swaps `hostingView.rootView` to a freshly-constructed `VLCPlayerView(device:initialURL:)` tagged `.id(device.DeviceID)` — the `.id()` forces SwiftUI to treat it as a genuinely new view identity (not an in-place property update), so `@State` resets and `.onAppear` re-fires the same setup a truly fresh window's first appearance does (audio devices, media-key targets, channel-picker pre-selection). A same-device reuse (the common case — just switching channels/streams) skips this entirely, relying on the existing `onChange(of: state.vlcCurrentURL)` re-sync path unchanged. `hostingView` is cleared in `playerWindowDidClose()` alongside `window`. Corrected `docs/VLCPlayerView.md`'s stale "device is fixed at window-open time, there is no device switching" claim, which directly contradicted this fix. Build + full test suite pass; no dedicated unit test (this is AppKit/NSWindow-level UI code with no existing seam for it in this test suite, matching TODO.md's note on why `WebServer.swift`/window-manager code is generally hard to unit test here) — a manual/live check is still worth doing next time the app is open with 2+ tuners.

**Resolving commit**: pending (uncommitted at time of writing)

## RESOLVED — Watching an in-progress recording never showed its poster/synopsis

**File:** `Views/VLCPlayerView.swift` — `currentGuideEntry`

**Root cause**: `AppState.watchRecordingInApp` (called identically by the menu bar's "Recording Now" submenu and by `WatchNowView`'s own "Watch Now!" button — both funnel through the exact same function with the exact same arguments) plays the recording via the local relay URL. `VLCPlayerView`'s channel picker represents that as a synthetic `LineupEntry` with `GuideNumber = "live:<showId>"` (`recordingChannelEntries`, so the picker can show/cycle recording rows the same way it does real channels) — `syncChannel(to:)` correctly resolves and selects this synthetic entry (confirmed live in the log: `syncChannel matched recording Live 11.1  The Tonight Show...`). But `currentGuideEntry` — the computed property the poster image and synopsis overlay both read — looked up `state.guideEntries(deviceId:channelNum:)` using that same synthetic `"live:<showId>"` string directly. Real guide data is keyed by actual channel numbers (`"11.1"`, etc.), so that lookup always missed, `currentGuideEntry` was always `nil` for the whole time a recording played, and the poster overlay stayed on its generic placeholder.

**Reported**: live, after the user watched a recording via the menu bar and noticed the poster/summary panel was blank, unlike watching a live channel.

**Resolution**: `currentGuideEntry` now checks whether `selectedChannel.GuideNumber` is one of these synthetic recording ids (`showId(fromLiveGuideNumber:)`, an existing helper in the same file) and, if so, resolves it back to the actual show's `show_channel` via `state.recordingShows` before doing the guide lookup — falling through to the original `ch.GuideNumber` unchanged for a normal live channel. Confirmed the fix compiles and the full 284-test suite passes; deployed.

**Resolving commit**: pending (uncommitted at time of writing)

## RESOLVED — Holding the new arrow-key seek caused repeated playback drops instead of a smooth rewind/skip

**File:** `Views/VLCPlayerView.swift` — `VLCPlayerWindowManager.installKeyMonitor(for:)`

**Root cause**: shipped the same day as the arrow-key seek feature itself. The key monitor committed a full `seekRecordingRelative(_:)` (a real recording-relay reconnect — new file handle, new HTTP connection, VLC re-buffers) on every `keyDown` event. macOS's key-repeat fires a `keyDown` roughly every 100-300ms while a key stays held, so holding left/right didn't scrub smoothly — it hammered the relay with that many reconnect-and-rebuffer cycles per second.

**Reported**: user noticed "it would drop off every 5-6 seconds for 2 seconds" while recording/watching and asked to check the logs. Found a burst of 6 relay reconnects within a ~2-second window, each landing ~15s earlier than the last — exactly the left-arrow step size, confirming this was the arrow-key feature (likely being test-driven by holding the key) rather than a signal or network issue. `ChannelSignalStore`'s own SNQ history for the channel stayed flat at 98-100 throughout, ruling out a real tuner/reception problem.

**Resolution**: the monitor now watches both `.keyDown` and `.keyUp`. `keyDown` only accumulates the delta into a new `pendingSeekDelta` instance var; the actual reconnect fires once, on `keyUp`, with the accumulated total. Mirrors the scrub-bar slider's own release-based commit (`onEditingChanged`) — accumulate locally while "held," commit once on release. `pendingSeekDelta` is also reset in `playerWindowDidClose()` in case a window closes mid-hold before a matching `keyUp` arrives. Full test suite (285 tests) passes; deployed.

**Resolving commit**: pending (uncommitted at time of writing)

## RESOLVED — Player toolbar stayed visible in fullscreen, competing with macOS's own menu-bar reveal

**File:** `Views/VLCPlayerView.swift` — `body`, `WindowCloseObserver`

**Root cause**: the toolbar had no notion of fullscreen state at all — it was just a normal, always-visible top `VStack` row, so entering true fullscreen (shipped the same day) left it permanently rendered at the top of the screen. macOS's own top-of-screen hover-reveal menu bar occupies that exact same real estate in fullscreen, so the two visually competed.

**Reported**: live, the same day fullscreen shipped — "when full screen, the bar at the top disappears if I hover over it. It should disappear when full screen, but appear when cursor is brought up to that area."

**Resolution**: `WindowCloseObserver` gained `windowDidEnterFullScreen`/`windowDidExitFullScreen` (posts a new `.vlcFullScreenChanged` notification with the state), observed by a new `@State isFullScreen` in `VLCPlayerView`. In windowed mode the toolbar is unchanged — a normal top row. In fullscreen, it moves into the video `ZStack` as a top-pinned overlay whose opacity is gated on `toolbarHovered`, set via `.onHover` on the toolbar itself (not the wrapping positioning `VStack`, so only hovering near the top reveals it, not anywhere over the video) — the same "opacity alone doesn't disable hit-testing on a hidden view" trick the recording scrub bar overlay already used at the bottom edge. Full test suite (293 tests) passes; deployed.

**Resolving commit**: pending (uncommitted at time of writing)

## LIKELY RESOLVED, NOT VISUALLY CONFIRMED — Fullscreen toolbar revealed but appeared empty

**File:** `Views/VLCPlayerView.swift` — fullscreen toolbar overlay (`body`), new `fullScreenTopInset`

**Root cause (reasoned, not directly observed)**: reported immediately after the fullscreen hover-reveal toolbar shipped — hovering near the top in fullscreen revealed *a* bar, but it looked empty. True `NSWindow` fullscreen still auto-reveals the window's own native title bar (traffic lights + title) as a system-drawn overlay when the cursor nears the top, and that overlay draws above app content — the toolbar, placed right at the video `ZStack`'s own top edge (y=0), most likely rendered underneath that native strip rather than actually being empty.

**Resolution**: added `Self.fullScreenTopInset` (`32pt`) applied as top padding on the toolbar overlay's wrapping `VStack`, pushing both its visible position and its `.onHover` catch zone down far enough to clear the native strip instead of sitting behind it.

**Not yet confirmed**: this environment has no way to screenshot the real running app's native windows, so this fix is reasoned from how AppKit's fullscreen title-bar reveal is known to behave, not verified against what was actually seen. The `32pt` offset is an estimate (macOS doesn't expose the reveal strip's real height as an API) and may need adjusting once actually looked at. Full test suite (293 tests) passes; deployed.

**Resolving commit**: pending (uncommitted at time of writing)

## RESOLVED — An interrupted recording could be permanently mistaken for a completed one

**File:** `AppState.swift` — `recordedEpisodeTags(forTitle:baseDir:expectedMinutes:)`, `duplicateEpisodeTag(title:episodeTag:baseDir:expectedMinutes:)`

**Root cause**: curl writes straight to the final `Title_SxxExx_channel_date.ts` filename from the first byte (`Show.outputPath`) — there's no rename-on-completion marker, so a file truncated by a crash/forced-restart/reboot mid-recording is indistinguishable *by name* from a finished one. The skip-already-recorded feature's on-disk scan only filtered out files under a flat ~1 MB as "crashed/zero-byte stubs" — a real HDHomeRun TS stream runs tens of MB per minute, so any interruption past the first several seconds sailed straight past that floor. With `Skip_recorded_episodes` + `Series_subfolder_enabled` on, the next attempt at that same `SxxExx` would see the truncated file, log `SKIP — already recorded`, and move on via `scheduleNextAir` — the truncated file was never replaced or retried.

**Reported**: surfaced while investigating the "false recording ring" bug above — noticed the real on-disk file backing that investigation (`S05E14`, 779,661 KB) was legitimately complete, which raised the question of what happens when a file *isn't*.

**Resolution**: `recordedEpisodeTags` gained an `expectedMinutes: Int = 0` parameter (default preserves the old flat-floor behavior for existing tests/callers with no duration handy). When a real duration is passed, the floor becomes `expectedMinutes * (~1.5 Mbps, a safe minimum even for the lowest-bitrate ATSC subchannel this app has recorded against, converted to bytes/minute) * 0.8` — the 20% fuzz applied only below the assumed-bitrate floor, since only the lower bound matters (a genuinely low-bitrate SD/subchannel recording must still pass). `expectedMinutes` is the show's own `show_length`, threaded through from all four real call sites (`startRecording`, the new `willSkipCurrentAiring`, `preferUnrecordedEpisode`'s closure, `WebServer.buildGuideGridHTML`'s `recordedTagsByShow`, `WatchNowView.refreshRecordedTags`, and `duplicateEpisodeTag(for:isSeries:baseDir:)`) — every episode of a series is assumed the same length, since a per-file guide lookup isn't available for old episodes. Full test suite (282 tests) passes unmodified, including the two suites (`RecordedEpisodeTagsTests`, `DuplicateEpisodeTagTests`) that directly exercise the old flat-floor behavior via the new parameter's default.

**Follow-up (same day)**: the truncated file itself was still left sitting on disk under its original recording extension once `startRecording` decided to record over it — indistinguishable from a real recording to any media server pointed at the folder. `recordedEpisodeTags` gained a `renameTruncatedTag: String? = nil` parameter — when set (only `startRecording`'s call passes it, right before writing the fresh file), any file found below the size floor whose tag matches gets renamed in place to `.partial` (same directory walk already computing size/tag per file, no separate scan) instead of just being left uncounted. Nothing is deleted. Added two tests (`renameTruncatedTagRenamesOnlyTheMatchingBelowFloorFile`, `renameTruncatedTagLeavesAboveFloorFilesAlone`) confirming only the matching below-floor file is touched. Full suite (284 tests) passes.

**Resolving commit**: pending (uncommitted at time of writing)
