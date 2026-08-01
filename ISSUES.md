# Issue Log

Historical record of bugs encountered during development. Used as a "don't repeat this" reference during code reviews. Unrelated bugs found during work go here rather than fixed inline — note the resolving commit when done. Deferred features go in `TODO.md`.

**Format**: each issue has a status (`OPEN` or `RESOLVED`), a brief description, root cause, fix or resolution, and resolving commit if known.

---

# Full-source review — 2026-07-17

A 5-way whole-file correctness sweep of all `Sources/` files (not just the recent diff). Crasher + all four medium findings fixed this pass; low-severity findings logged OPEN below.

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

## OPEN — Deferred low-severity findings from the 2026-07-17 sweep

Verified real, deferred by scope decision (crasher + medium fixed; these logged for a later pass).

- **`ChannelIconCache.swift:29,48`** — disk cache keyed by `URL.lastPathComponent` only; two logo URLs sharing a basename (or both hitting the `"icon.png"` default) collide → wrong channel logo after a restart, and `countMissing` under-counts so it's never re-fetched. Fix: key the on-disk file by a hash of the full URL (preserve extension). Invalidates the existing disk cache once (harmless re-download).
- **`EditShowView.swift:149`** — Save button has no `.disabled` gate and Title has no non-empty check; a user can clear the title or type a non-existent channel (free-text field) and save a show that never records correctly. Fix: gate Save like `AddShowView.canAdvance` (non-empty title + channel-in-lineup).
- **`AddShowView.swift:266`** — `canAdvance` for `.details` doesn't check `airDays`; a DateTime (recurring) show with all days deselected saves and never fires. Fix: require `!airDays.isEmpty` when `seriesType == .dateTime`.
- **`AppState.swift:483`** — `probeForNewDevices()` has no reentrancy guard and is launched detached from the idle loop; if `discoverDevices` runs longer than the probe interval, two runs each capture `existingIDs` before appending → a first-seen device is appended twice (corrupting occupancy counts/menu/dev-bar for the session) and unseen devices' `missedProbes` double-increment. Fix: a `probeInFlight` guard mirroring `idleLoopRunning` (low probability — needs discovery > 300 s).
- **`AppState.swift:2669`** — in `fetchDeviceStatus`, the `tunerStatus[show.show_id]` write happens after the per-tuner `vstatus` await; a web-UI delete during that await re-adds the entry for a show `deleteShow` already cleared → a display-only leak that never clears again. Fix: re-check the show still exists after the await.
- **`WebServer.swift:2781`** — `setDev('\(defaultDev)')` interpolates a DeviceID raw into a JS string literal, bypassing the file's `jsEscapeForScript`/`he` discipline. Not attacker-controlled (DeviceIDs are hardware hex), but the one escaping-discipline gap. Fix: escape it.
- **`VLCPlayerView.swift:399` / `VLCBridge.swift:454`** — (a) `selectedAudioTrackId`/`selectedSpuTrackId` reset sits after the `suppressNextChannelPlay` early-return, so a synced (external) channel switch doesn't reset them and the picker can hold a stale track id; (b) the stats/playback `Timer` is scheduled in `.default` run-loop mode, so it stalls during modal tracking (open menu / live resize) — e.g. "Connecting…" can stick until a menu closes. Fix: reset track ids on synced switches; add the timer to `.common` modes.

## Notes — flagged, not scheduled (marginal / by-design)

- **`RecordingManager.swift:152`** — orphaned-recording liveness uses `kill(pid,0)`, which tests PID existence not identity; PID reuse could report a dead recording as running. Astronomically low probability (slow PID cycling); accept.
- **`Models.swift:464`** — `GuideEntry` `==`/`hash`/`id` are StartTime-only, unsafe for cross-channel `Set`/`ForEach(id:)`. Already documented (`WatchNowView.swift:28-29`) and every call site deliberately uses `\.GuideNumber` — latent trap, no live bug.
- **`WebServer.swift`** — `stateCallback`/`activePort`/`listener` are unsynchronized under `@unchecked Sendable` (benign word writes); a dropped SSE conn lingers in `sseConns` up to 25 s until the keepalive prunes it (self-heals). Neither observed to misbehave.
- **`VLCBridge.swift:55-60`** — a CoreAudio device-change callback already in flight during `stopDeviceChangeMonitoring()` teardown could read a freed context. Very edge; related listener-lifecycle issues already RESOLVED below.

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

**File:** `VLCBridge.swift` ~line 540

`startDeviceChangeMonitoring()` assigns a new `AudioDeviceChangeContext` to `deviceChangeContext` without first calling `stopDeviceChangeMonitoring()`. ARC immediately deallocates the old context object, but CoreAudio still holds the raw opaque pointer registered via `AudioObjectAddPropertyListener`. The next audio device change fires `audioDeviceChangeProc` with a freed pointer — use-after-free. Currently safe because `onAppear` only calls it once per window lifetime, but the guard is behavioral, not structural.

**Fix:** Add `if deviceChangeContext != nil { stopDeviceChangeMonitoring() }` at the top of `startDeviceChangeMonitoring()` before registering the new listener.

---

## RESOLVED — `playerWindowDidClose()` does not call `stopDeviceChangeMonitoring()` — CoreAudio listener outlives VLC teardown

**File:** `VLCPlayerView.swift` ~line 601

`playerWindowDidClose()` calls `releasePlayer()` but never `stopDeviceChangeMonitoring()`. With `isReleasedWhenClosed = false`, `windowWillClose` fires before `onDisappear`, leaving a real gap where VLC's media player is released but the CoreAudio device-change listener still fires `refreshAudioDevices()` callbacks into a partially torn-down view.

**Fix:** Call `VLCBridge.shared.stopDeviceChangeMonitoring()` from `playerWindowDidClose()` alongside `releasePlayer()`.

---

## RESOLVED — `moveToScreen()` places window off-screen when window is larger than the target display

**File:** `VLCPlayerView.swift` ~line 577

Centering formula: `x = sf.minX + (sf.width - wf.width) / 2`. When the player window is wider or taller than the target screen's `visibleFrame` (e.g. a native-resolution 1920×1080 window moved to a 1280×720 AirPlay receiver), the result is negative relative to `sf.minX` — no clamping applied. Part of the window extends off-screen with no title bar to drag it back.

**Fix:** Clamp the result: `max(sf.minX, x)` / `max(sf.minY, y)`, or use `NSWindow.constrainFrameRect(_:to:)`.

---

## RESOLVED — `moveToScreen()` ignores miniaturized window state — `setFrameOrigin` silently no-ops

**File:** `VLCPlayerView.swift` ~line 577

`moveToScreen()` calls `setFrameOrigin` then `makeKeyAndOrderFront`. If the window is miniaturized, macOS silently ignores `setFrameOrigin`; `makeKeyAndOrderFront` then deminiaturizes the window at its pre-miniaturize position on the original screen rather than the target screen.

**Fix:** Check `win.isMiniaturized` and call `win.deminiaturize(nil)` before `setFrameOrigin`, or move the origin set after `makeKeyAndOrderFront` with a short `DispatchQueue.main.async` delay.

---

## RESOLVED — `managedShowByTitle` last-writer-wins: duplicate show titles produce wrong scheduled badge in `WatchNowView`

**File:** `WatchNowView.swift` ~line 226 (root cause: `AppState` `managedShowByTitle` dict)

`AppState.managedShowByTitle` is built with `byTitle[show.show_title] = show`, iterating shows in order. If two scheduled shows share a title (e.g. "News" scheduled on two different channels), only the last one written survives. `WatchNowRow`'s `scheduled` check then tests device/channel/slot against whichever show landed last — the other entry incorrectly shows as unscheduled with a Record button instead of Edit.

**Fix:** Use `[String: [Show]]` (title → array) in `managedShowByTitle`, or match by both title and channel/device so a single-dict approach isn't used for slot-specific shows.

---

## RESOLVED — `@State var availableScreens = NSScreen.screens` evaluated at struct init, which may run off the main thread

**File:** `VLCPlayerView.swift` line 45

`NSScreen.screens` is main-thread-only. `@State` default values in SwiftUI structs are not guaranteed to be evaluated on the main actor during reconciliation. If SwiftUI evaluates this default off-main, the `NSScreen.screens` call is undefined behavior.

**Fix:** Initialize to `[]` and populate in `.onAppear`: `availableScreens = NSScreen.screens`.

---

## RESOLVED — Nil `show_next` maps to sentinel `-1`, which spuriously matches a guide entry with `StartTime == -1`

**File:** `WatchNowView.swift` ~line 231

`Int(show.show_next?.timeIntervalSince1970 ?? -1) == entry.StartTime`: when `show_next` is nil the expression evaluates to `-1`. A malformed guide API response with `StartTime = -1` would produce a false-positive scheduled match for a show that has no air time scheduled.

**Fix:** Guard on `show.show_next != nil` before the epoch comparison, or use `guard let next = show.show_next else { return false }` and compare `Int(next.timeIntervalSince1970) == entry.StartTime`.

---

## RESOLVED — `FloatingGuideView` does not reset `genreFilter` on device change

**File:** `FloatingGuideView.swift:109`

`onChange(of: selectedDevice)` clears `allChannels` and `refreshToken` but leaves `genreFilter` at its previous value. `availableGenres` repopulates for the new device, making the old filter value orphaned. If the new device has no content matching the stale genre, `CableGuideView` renders every row at 0.2 opacity with `allowsHitTesting` off — the guide appears loaded but is entirely non-interactive with no explanation. The identical bug was fixed in `AddShowView` (commit adding `genreFilter = nil`) but the same fix was not applied here.

**Fix:** Add `genreFilter = nil` to `FloatingGuideView`'s `onChange(of: selectedDevice)` handler (line 109), matching the fix already in `AddShowView.swift:304`.

---

## RESOLVED — `managedSeriesIDShows` computed 4× per render in `FloatingGuideView`

**File:** `FloatingGuideView.swift:29`

`managedSeriesIDs` and `managedTitles` are separate computed properties that each independently call `managedSeriesIDShows`, which runs `state.shows.filter(...)`. Both are accessed in `summaryPanel` (2 filter calls) and again in the `CableGuideView(...)` parameter list in `body` (2 more) — 4 filter passes per render where the original code ran one. Root cause: the refactor that promoted these from `let` vars in `body` to computed properties broke the single-pass structure by chaining them through an intermediate `managedSeriesIDShows` property.

**Fix:** Replace the three separate properties with one that computes both sets in a single pass:
```swift
private var managedSets: (seriesIDs: Set<String>, titles: Set<String>) {
    let shows = state.shows.filter { $0.state == .seriesChannel || $0.state == .seriesAll }
    return (
        Set(shows.compactMap { $0.show_seriesid.isEmpty ? nil : $0.show_seriesid }),
        Set(shows.map { $0.show_title })
    )
}
```
Update all call sites to use `managedSets.seriesIDs` and `managedSets.titles`.

---

## RESOLVED — `GuideStore.entries(key:after:)` is internal, not private

**File:** `GuideStore.swift:217`

The `entries(key:after:)` overload added as an efficiency helper is declared with default (internal) access rather than `private`. Any code in the module can call it with an arbitrary string, bypassing the `deviceId:channelNum:` key format contract enforced by the public `entries(deviceId:channelNum:after:)`. A caller passing a malformed key silently gets an empty array.

**Fix:** Mark the overload `private`.

---

## RESOLVED — Accessibility action gate condition duplicated in name and handler body

**File:** `CableGuideView.swift:681`

`.accessibilityAction(named: (isManaged || isRecording || isNextUp) ? "View" : "Record") { ... if !(isManaged || isRecording || isNextUp) { onConfirm?() } }` evaluates the same condition twice. Not a current bug — values are stable within a render — but if either expression is updated without the other, the action name and its behavior silently diverge (e.g. announces "View" but calls `onConfirm()`).

**Fix:** Bind to a local `let` before the modifier: `let alreadyManaged = isManaged || isRecording || isNextUp`, then use `alreadyManaged` in both places.

---

## RESOLVED — VoiceOver "Record" action triggers on already-managed guide entries

**File:** `CableGuideView.swift:676`

`.accessibilityAction(named: "Record")` is attached unconditionally to every show block, including blocks where `isRecording`, `isNextUp`, or `isManaged` is true. In the `AddShowView` context, `onConfirm` calls `applyGuideEntry()` (which resets `seriesType = .single`) then advances the wizard — completing it creates a duplicate or conflicting scheduled show. VoiceOver announces the cell as "Recording now" or "Scheduled" while still offering "Record" as a custom action; contradictory and data-corrupting.

**Fix:** Guard on `!(isRecording || isNextUp || isManaged)`, or rename to "Edit" / "View" for already-managed entries.

---

## RESOLVED — VoiceOver actions not gated by `matchesFilter` — activates genre-filtered (dimmed) cells

**File:** `CableGuideView.swift:676` (Record action) and `~713` (Bonus Time overlap)

`.allowsHitTesting(matchesFilter)` only suppresses pointer hit-testing, not accessibility actions. Both the "Record" action and the Bonus Time overlap default action fire without a `matchesFilter` guard. A VoiceOver user can focus and activate a dimmed cell that is supposed to be non-interactive.

**Fix:** Add `.accessibilityHidden(!matchesFilter)` to both the main show block and the Bonus Time overlap block.

---

## RESOLVED — `ShowBlocksRow.==` omits `totalW` / `rowH` / `pxPerMin` — stale cell geometry after window resize

**File:** `CableGuideView.swift:515`

`ShowBlocksRow` uses `.equatable()` to suppress redraws. Its `==` implementation does not include `totalW`, `rowH`, or `pxPerMin` — the three fields used to compute cell widths, positions, and frame sizes. A window resize changes these values without invalidating the row, leaving all block widths and positions stale until something else forces a redraw.

**Fix:** Add `totalW`, `rowH`, and `pxPerMin` to `==`.

---

## RESOLVED — `MenuBarExtra` accessibility labels may not reach VoiceOver; `nextShowMinutes` formats as raw `Double`

**File:** `hdhr_VCRApp.swift:89–94`

Per-`Image` `.accessibilityLabel` modifiers inside a `MenuBarExtra` label closure are not reliably forwarded to `NSStatusBarButton.accessibilityTitle` on macOS 13–15. Additionally, `nextShowMinutes` returns `Double?` so `\(mins)` interpolates the raw float (e.g. `"14.234 minutes"`), and `mins == 1` comparing `Double` to `1` is virtually never true.

**Fix:** Use `MenuBarExtra("hdhr VCR", ...)` with a dynamic title string, or set `NSStatusBarButton.setAccessibilityTitle()` via `NSViewRepresentable`. Use `Int(mins.rounded())` for display and pluralization.

---

## RESOLVED — `managedShow` computed 4× per `WatchNowRow` body evaluation

**File:** `WatchNowView.swift:225`

`managedShow` runs a dictionary lookup on every call and is accessed four times per body evaluation: twice via `isScheduled`, once for `managedShow?.show_recording`, once in `actionRow`. Each call redundantly re-runs the same lookup.

**Fix:** Cache at the top of `body`: `let managed = managedShow`.

---

## RESOLVED — `guideTimeRange()` called inside `.accessibilityLabel` closure on every render

**File:** `CableGuideView.swift:665`

macOS does not lazily evaluate SwiftUI modifier arguments. The closure passed to `.accessibilityLabel` calls `guideTimeRange(entry)` (two `DateFormatter.string(from:)` calls) on every view-tree construction pass — ~360 calls on initial render for a 60-channel guide, regardless of whether any accessibility client is connected.

**Fix:** Compute the accessibility string once as a `let` inside `showBlock` and pass it as a plain `String` to `.accessibilityLabel(...)`.

---

## RESOLVED — `FloatingGuideView` `summaryPanel` uses O(n) `contains(where:)` instead of Set lookup

**File:** `FloatingGuideView.swift:185–200`

`summaryPanel` is a separate `@ViewBuilder` and can't access the `managedSeriesIDs` / `managedTitles` / `managedDTSingleSlotKeys` Sets built in `body` (lines 42–49). It re-derives managed status via `contains(where:)` on `state.shows` on every render.

**Fix:** Promote the three sets to `private var` computed properties on `FloatingGuideView` so both `body` and `summaryPanel` share O(1) Set lookups from the same source.

---

## RESOLVED — Yellow "already scheduled" badge shows on all menus, not just guide browsing

**File:** `MenuContent.swift` — `showInfoHeader`

The managed-show triangle in `showInfoHeader` was designed to flag already-scheduled entries while browsing the Add Show guide. It lives in a shared helper also used by `recordingMenu`, `scheduledMenu`, and `pausedMenu`, where it's always true and conveys nothing useful.

**Fix:** Add a `showManagedBadge: Bool = false` parameter; pass `true` only from the guide-browsing context (`AddShowView` step 2 / `CableGuideView`).

---

## RESOLVED — Genre filter resets silently on tuner change in Add Show wizard

**File:** `AddShowView.swift`

When the tuner picker changes, `genreFilter` resets to `nil` because `availableGenres` repopulates for the new device. The user gets no indication this happened.

---

## RESOLVED — `guideStore.entries()` rebuilds key string on every call

**File:** `GuideStore.swift`

`"\(deviceId):\(channelNum)"` string interpolation happens at every call site. Fix: pass a pre-built key, or add a direct `entries(key:)` overload that accepts a pre-computed string.

---

## RESOLVED — `Int()` truncation in VLC buffer VoiceOver value

**File:** `VLCPlayerView.swift:378`

`Int(info.lagSec)` truncates toward zero — `lagSec = 7.9` announces as "7 of 8 seconds" while the visual bar shows full. Use `Int(info.lagSec.rounded())`.

---

## RESOLVED — Cable guide layout: pinned time header + channel column scroll sync

**Symptom**: Time header and channel label column needed to stay fixed while the guide grid scrolled both horizontally and vertically. Multiple layout attempts (10 documented in `docs/CableGuideView_pitfalls.md`) failed with various combinations of nested ScrollViews, sticky headers via `LazyVStack(pinnedViews:)`, and GeometryReader overlays.

**What failed**: Putting the time header inside the ScrollView with `LazyVStack(pinnedViews: [.sectionHeaders])` — works for vertical-only scroll but the header scrolls away horizontally. Nested ScrollViews with synced offsets via `PreferenceKey + GeometryReader` — offset notifications don't fire during AppKit-driven scroll momentum, causing the header to lag or jump.

**Resolution**: Channel label column is pinned outside the ScrollView entirely (fixed left column, `HStack { channelColumnFixed | ScrollView }`). Time header is also external, shifted via `.offset(x: -timeHeaderOffset)` to track horizontal scroll position. Scroll offset captured using `NSViewRepresentable + boundsDidChangeNotification` (AppKit scroll notification fires reliably; SwiftUI PreferenceKey does not during AppKit-driven scroll). A 1-pt threshold + `Transaction.disablesAnimations` prevent jitter. `LazyVStack(pinnedViews:)` inside a bidirectional ScrollView works correctly only on macOS 15+ — do not lower the deployment target.

**Resolving commit**: `a2189f6` (approximate; layout stabilized across several commits)

---

## RESOLVED — Menu glitch feedback loop on guide load failure

**Symptom**: When a device's guide API returned 403 (e.g., the FFFF0001 test EXTEND device), the menu became completely unresponsive, firing HTTP requests at ~35ms intervals and locking the UI.

**Root cause**: `ensureGuideLoaded` was called inline in the SwiftUI menu `@ViewBuilder`. A failed load that assigned `guideByDevice = []` (even empty) triggered `didSet → rebuildMenuEntries → 3 @Published changes → SwiftUI re-eval → ensureGuideLoaded → HTTP request → failure → assign → didSet → ...` in a tight loop.

**What failed**: Guarding on `menuIsOpen` in `didSet` — guide loads are infrequent and must always populate `menuGuideEntries` even if the menu is open, so this guard was too broad. Adding `NSMenuDelegate` + lazy `menuNeedsUpdate` — rejected as too architecturally complex for the problem.

**Resolution**: `ensureGuideLoaded` only assigns `guideByDevice` when `guideStore.channels(deviceId:)` is non-empty after the load (empty result = no assignment = no re-eval trigger). Added `guideLoadFailTimes: [String: Date]` for 5-minute backoff on failed devices so repeated failures don't hammer the API. The `guideByDevice.didSet` is intentionally not guarded by `menuIsOpen`.

**Resolving commit**: `52c5107` (approximate)

---

## RESOLVED — AVPlayer does not support MPEG-2 transport streams

**Symptom**: The in-app player (using AVKit/AVPlayer) silently failed to play HDHomeRun streams. No error was shown; the player just displayed a black frame.

**Root cause**: AVPlayer on macOS does not support MPEG-2 transport streams, which is the native format from HDHomeRun tuners without transcoding. Forcing `transcode=heavy` as a workaround degraded quality and still failed for some streams.

**What failed**: Forcing transcoding on all streams — quality loss, still unreliable. Custom `AVAssetResourceLoaderDelegate` to pre-buffer — too complex, same underlying codec limitation.

**Resolution**: Replaced AVKit player entirely with VLC via `VLCBridge` (dlopen runtime loader for `libvlc.dylib`). VLC handles MPEG-2 natively so no forced transcoding is needed. The old `PlayerView.swift` is superseded by `VLCPlayerView.swift`. See `docs/VLCBridge.md` and `docs/VLCPlayerView.md`.

**Resolving commit**: in-app player VLC adoption (see git log for VLCBridge introduction)

---

## RESOLVED — TCC permission reset on app re-signing during deploy

**Symptom**: After running `deploy.sh`, the app lost Notification Center permission and folder-access entitlements. Users had to re-grant permissions after every deploy.

**Root cause**: Ad-hoc code signing (`codesign --force`) changes the code signature, which macOS treats as a new app identity — TCC (Transparency, Consent, and Control) ties permissions to the signature.

**Resolution**: Moved the config file from `~/Documents/hdhr_VCR-{hostname}.json` to `~/Library/Application Support/hdhrVCRplus/hdhr_VCR-{hostname}.json`. `ConfigManager` auto-migrates on first launch. This scopes the app's folder access to its own support directory (always granted without a prompt) instead of `~/Documents`. The old file is left in place so the AppleScript app can still read it. Added `setbuf(stdout, nil)` for reliable log flushing after the process model changed.

**Resolving commit**: config migration commit (see git log for `ConfigManager` path change)

---

## RESOLVED — Scroll sync offset not firing during momentum scroll

**Symptom**: The pinned time header in `CableGuideView` lagged or snapped during fast/momentum horizontal scrolling — the SwiftUI offset tracking fell behind AppKit's scroll physics.

**Root cause**: `PreferenceKey + GeometryReader` inside a SwiftUI ScrollView reports geometry changes only during SwiftUI layout passes, not during AppKit-driven scroll momentum frames. The offset appeared to update correctly for slow drags but jumped on momentum release.

**Resolution**: Replaced with `NSViewRepresentable` wrapping the scroll view's `NSClipView`, observing `NSView.boundsDidChangeNotification`. This fires on every AppKit scroll frame including momentum. The CompatibilityHelpers extension uses `onScrollGeometryChange` natively on macOS 15+ and falls back to this AppKit approach on macOS 14.

**Resolving commit**: cable guide scroll sync stabilization (see git log)

---

## RESOLVED — Disk-full "Recording Skipped" posted a brand-new Discord message on every retry

**File:** `AppState.swift` → `startRecording(index:)`, disk-check guard

**Symptom**: While a show's tuner slot stayed ready but the disk was over the free-space threshold, every idle-loop retry posted a fresh "💾 Recording Skipped" Discord message instead of updating one card — spamming the channel once per retry.

**Root cause**: This was the one failure path still calling the fire-and-forget `discordShow(...)` helper with no `editMessageId`, instead of the `discordRecordingCard(showId:event:color:enabled:extra:)` helper the other four failure paths (curl exit, no stream URL, launch error, empty output file) already used. `discordShow` neither reuses `discord_start_msg_id` nor captures a new message ID, so each call was an orphaned POST.

**Resolution**: Switched the disk-full path to `discordRecordingCard`, matching the other failure paths — reuses the existing card if `discord_start_msg_id` is set, otherwise creates one and captures the ID. Found and fixed alongside adding the idle-loop retry backoff (see `TODO.md`'s former "No retry backoff for failed shows" entry).

**Resolving commit**: pending (uncommitted at time of writing)

---

## RESOLVED — Recording fires on a stale `show_next` after repeated "no episode found in guide" rescans, recording whatever's actually airing

**File:** `AppState.swift` — the hourly guide-rescan path that logs `"no episode found in guide — show_next already future, leaving unchanged"` (feeds `resolveSeriesAir`/`scheduleNextAir`); fix lives in `startRecording(index:)`

**Symptom**: A recurring SeriesID show (`The Late Show With Stephen Colbert`) recorded a program that didn't match its SeriesID — user identified the actual content as a Byron Allen syndicated program, not Colbert.

**Root cause**: `show_next` was locked in from an earlier successful SeriesID match against the guide. Five consecutive hourly rescans (19:00, 20:00, 22:00, 23:00, 00:00) all failed to reconfirm any guide entry for that SeriesID at that time slot, each logging "no episode found in guide — show_next already future, leaving unchanged" — i.e. the guide had stopped listing Colbert there at all, most likely because the network swapped in different programming (a live preemption) and the guide provider's data caught up to reflect it. The "leave unchanged" fallback is reasonable for a single transient guide gap, but had no escalation once a slot goes unconfirmed for hours — the idle loop's ready-check (`next <= now+10`) only cared that the stored timestamp arrived, not whether the guide still backs it up, so the show recorded blind at the stale time and captured whatever was actually broadcasting.

**Resolution**: `startRecording(index:)` now does a final, synchronous, live re-check for any SeriesID-based show (`show_use_seriesid`) right before actually recording — `GuideStore.currentEpisode`/`currentEntryByTitle` against the show's own resolved device+channel, the same SeriesID-then-title trust tiers `scheduleNextAir` already uses. If neither confirms the airing anymore, the recording is skipped, `show_next` is cleared to `nil`, and `scheduleNextAir` is called immediately — which falls into its own existing "no match, retry in `Series_scan_retry_hours`" branch and sets a fresh future time, the same path a brand-new show's first resolution takes. No new state machinery.

**Resolving commit**: pending (uncommitted at time of writing)
