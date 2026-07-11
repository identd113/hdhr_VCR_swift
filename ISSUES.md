# Issue Log

Historical record of bugs encountered during development. Used as a "don't repeat this" reference during code reviews. Unrelated bugs found during work go here rather than fixed inline — note the resolving commit when done. Deferred features go in `TODO.md`.

**Format**: each issue has a status (`OPEN` or `RESOLVED`), a brief description, root cause, fix or resolution, and resolving commit if known.

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
