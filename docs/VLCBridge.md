# VLCBridge.swift — Runtime libvlc Wrapper

## Intent

`VLCBridge` loads `libvlc.dylib` from VLC.app at runtime using `dlopen`/`dlsym`. The app has **no compile-time dependency on VLC** — it builds and runs normally when VLC is not installed; the player feature is simply unavailable. The gate for all "Watch Now!" UI is `VLCBridge.shared.isAvailable`, which is `true` only when the dylib loads and the two sentinel symbols resolve successfully.

---

## Why dlopen Instead of a Framework

The alternative (linking VLCKit as a framework or SPM package) would require distributing a copy of VLC inside the app bundle (~100 MB) or require the user to have VLCKit installed separately. Neither is acceptable for a menu bar utility. With `dlopen`:

- Binary stays small — no VLC code at link time
- User's already-installed VLC.app is used as-is, wherever it's actually installed
- The feature degrades gracefully when VLC is absent

---

## Initialization

`VLCBridge` is a `@MainActor` singleton (`VLCBridge.shared`). Its `private init()` runs once on first access.

VLC's location is resolved dynamically via Launch Services rather than assumed at `/Applications/VLC.app` — `VLCBridge.locateApp()` calls `NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.videolan.vlc")`, which works for Homebrew cask installs, `~/Applications`, or any other location the user (or macOS) put it. The resolved app URL is then used to build the lib path:

```
dlopen("\(vlcAppURL)/Contents/MacOS/lib/libvlc.dylib", RTLD_LAZY | RTLD_LOCAL)
```

`RTLD_LOCAL` prevents VLC's symbols from polluting the global namespace. `RTLD_LAZY` defers symbol resolution until call time.

Every function pointer is resolved via a local helper:
```swift
func sym<T>(_ name: String) -> T? {
    guard let h, let p = dlsym(h, name) else { return nil }
    return unsafeBitCast(p, to: T?.self)
}
```

`unsafeBitCast` is used because `dlsym` returns `void*` and Swift cannot directly cast a raw function pointer to a typed function pointer through normal bridging. This is safe because the symbol name, ABI, and calling convention are all known.

`isAvailable` is set to `true` only when both `libvlc_new` and `libvlc_media_player_new` resolved — the minimum two symbols needed to actually play anything.

On success, init creates:
1. A libvlc instance via `libvlc_new(0, nil)` — no extra argv; VLC's defaults are fine
2. A media player via `libvlc_media_player_new(instance)` — the **no-media constructor**

**Why no-media constructor**: `libvlc_media_player_new` takes only the instance and creates a player with no media attached. Media is set later via `libvlc_media_player_set_media`. This lets the same player object live for the entire session and switch channels without recreating it, which avoids re-attaching the drawable NSView on every channel change.

---

## Buffered Playback & Rate Controller

Every `play(url:)` call applies four media options before starting:

```swift
"--network-caching=\(networkCachingMs)"  // 2000ms for a live stream, 300ms for the recording relay — see below
"--drop-late-frames"         // drop corrupt/late frames rather than showing artifacts
"--avcodec-hurry-up"         // drop non-essential B-frames under decode pressure
"--no-audio-time-stretch"    // prevent audio init crash when sample rate is 0 on first MPEG-2 frame
```

`--no-audio-time-stretch` is specifically required for live MPEG-2 transport streams from HDHomeRun tuners. VLC's audio time-stretch module tries to initialize before the first audio frame arrives, sees a 0 Hz sample rate, and fails with `too low audio sample frequency (0)` / `module not functional`. The option prevents that module from loading for live streams.

An adaptive rate controller runs every 3 seconds via a repeating `Timer` (`statsTimer`), added to `RunLoop.main` explicitly under `.common` mode (`RunLoop.main.add(timer, forMode: .common)` rather than the implicit `.default`) so it keeps ticking during `.eventTracking` (an open NSMenu, a live window resize/drag) — previously `isPlaying`/`hasError` detection and the rate ramp could stall during tracking, leaving a "Connecting…" state stuck on screen:

- **Fill phase**: Plays at `minRate` (from `AppConfig.Player_buffer_min_rate`; default 0.93). Stream arrives ~7% faster than consumed — VLC's demux buffer grows.
- **Hold phase**: Rate ramps linearly toward 1.0 as `estimatedLagSec` approaches the 8-second target. At 8s the rate reaches 1.0 and the buffer stabilises.
- **Auto catch-up**: Same tick polls `libvlc_media_player_get_stats`. If `i_demux_corrupted` rises by >15 in 3s, calls `catchUpToLive()` with a 30s debounce.

Rate formula applied every tick:
```
estimatedLagSec += (1.0 - currentRate) * 3.0   // capped at 8.0
fillRatio = estimatedLagSec / 8.0
newRate   = minRate + (1.0 - minRate) * fillRatio
```

`catchUpToLive()` calls `play(url: currentURL)`, which stops the stream, resets `estimatedLagSec` to 0, and restarts the fill phase from scratch.

When `minRate == 1.0` (buffering disabled in Settings, or forced — see below), rate control is skipped entirely; the stats timer still runs — it continues driving `isPlaying`/`hasError` state detection, track fetching, `videoPixelSize` updates, and corruption detection, just not the buffer-rate adjustment itself.

**`minRate` vs `liveMinRate`**: `liveMinRate` is the externally-configured floor (`AppConfig.Player_buffer_min_rate`, set by `VLCPlayerView`); `minRate` is the floor actually in effect, set internally by `play(url:)` — `liveMinRate` for a normal stream, forced to `1.0` for the recording-playback relay (`/api/watch-recording`, see `docs/WebServer.md`). A local loopback file read has no network jitter to buffer against, so the fill ramp — and the buffer pill it drives in the toolbar — would just be theatre there. External code should set `liveMinRate`, never `minRate` directly.

### Stream state detection

Each `tickController` tick calls `libvlc_media_player_get_state` before the rate-control logic:

| State value | libvlc constant | Action |
|---|---|---|
| 3 | `libvlc_Playing` | Sets `isPlaying = true` on first confirmation; enables Start button in UI |
| 6 | `libvlc_Ended` | Sets `hasEnded = true`, `isPlaying = false`, stops timer; "Playback Ended" overlay appears in UI |
| 7 | `libvlc_Error` | Sets `hasError = true`, stops timer; error overlay appears in UI |
| other | — | No action; rate controller proceeds normally |

`hasError`, `hasEnded`, and `isPlaying` are reset to `false` in `play()`, `stop()`, and `releasePlayer()` so state is clean on every new stream attempt.

### Logging

Every significant controller event is logged to `hdhrVCRplus.log`:

| Event | Level | Message |
|---|---|---|
| VLC loaded | INFO | `[VLC] loaded version 3.0.21 Vetinari` |
| VLC 4+ detected | WARN | `[VLC] WARNING: VLC 4.x detected — stats struct changed…` |
| Rate accepted | INFO | `[VLC] rate set to 0.93 (fill phase)` |
| Rate ignored | WARN | `[VLC] WARNING: set_rate(0.93) ignored — actual rate is 1.00; buffer will not grow…` |
| Rate ramp tick | INFO | `[VLC] rate → 0.961 (lag ~3s / 8s)` |
| Stream playing confirmed | INFO | `[VLC] stream playing confirmed` |
| Stream error state | ERROR | `[VLC] stream error state — publishing hasError` |
| Track descriptions loaded | INFO | `[VLC] tracks — audio: 1:English, 2:Spanish  spu: 0:CC1` |
| Audio track selected | INFO | `[VLC] setAudioTrack id=2` |
| SPU/CC track selected | INFO | `[VLC] setSpuTrack id=0 (on)` / `id=-1 (off)` |
| Stats call failed | WARN | `[VLC] WARNING: get_stats returned N — stats polling skipped (may indicate VLC 4 struct mismatch)` |
| Auto catch-up | INFO | `[VLC] stream corruption detected (i_demux_corrupted delta=N) — catching up to live` |

### Known risks

- **VLC 4.x stats struct** — `VLCStats` mirrors the VLC 3.x `libvlc_media_stats_t` field layout. VLC 4 reorganised the struct; on VLC 4 the corruption/lost-frame counters will read garbage. The version check at init logs a WARNING if major ≥ 4, and the stats return-value check logs a WARNING if the call returns non-1. Both degrade gracefully: auto catch-up stops working but playback is unaffected.
- **`set_rate` on live streams** — `libvlc_media_player_set_rate` may be silently ignored for non-seekable streams on some VLC versions. After setting rate, `libvlc_media_player_get_rate` is called to verify; a mismatch logs a WARNING. If ignored, the buffer never grows but playback continues normally at 1.0x.
- **Recording-relay stop/reconnect deadlock (mitigated, not proven via forced reproduction)** — see "Channel Switching (play)" above for the full mechanism. Fixed 2026-08-15 by moving `libvlc_media_player_stop`/`_release` off the MainActor onto `libvlcQueue`. The fix is reasoned from code (the blocking call plus the relay's `@MainActor` poll-hop are a textbook mutual-deadlock shape) and passes the full test suite, but the original failure was never deliberately forced to reproduce — it was caught once, live, via a crash report. If an app-wide hang during recording playback ever recurs, re-open `ISSUES.md`/`issues_resolved.md` rather than assuming this fix is airtight.

---

## Drawable

`libvlc_media_player_set_nsobject` takes an Objective-C `id` — VLC's way of accepting an `NSView` as its render target on macOS. Swift has no direct cast from `NSView` to `void*`, so:

```swift
_mpSetNSO?(mp, Unmanaged.passUnretained(view).toOpaque())
```

`Unmanaged.passUnretained` produces an unmanaged reference (no retain count change) and `.toOpaque()` gives the raw `void*`. This is correct because VLC holds its own weak reference to the view internally — we don't need ARC to be involved.

`setDrawable` is called once from `VLCVideoSurface.makeNSView`. It does **not** need to be called again on channel switches because the player object is reused — VLC retains the drawable across `stop`/`play` cycles.

---

## Channel Switching (play)

`play(url:)` keeps a synchronous signature — every call site is unchanged — but as of 2026-08-15 its actual libvlc work is split into a synchronous prefix (runs immediately, on the MainActor) and a deferred tail (runs on `libvlcQueue`, a private serial background queue, then commits back via a `Task { @MainActor in ... }`):

```swift
func play(url: String) {
    // synchronous prefix — MainActor, unchanged in spirit from before
    stopStatsTimer()
    hasError = false; isPlaying = false
    audioTracks = []; spuTracks = []; tracksFetched = false
    currentURL = url                 // updates immediately — beginRecordingSeek depends on this
    let oldMedia = currentMedia; currentMedia = nil   // claimed now, so a second play() can't double-release it

    // deferred tail — libvlcQueue (serial, off-main)
    libvlcQueue.async {
        _mpStop?(mp)                                          // the call that used to block the MainActor
        if let oldMedia { _mediaRelease?(oldMedia) }
        guard let media = url.withCString({ _mediaNL?(inst, $0) }) else { return }
        for opt in ["--network-caching=...", "--drop-late-frames", "--avcodec-hurry-up", "--no-audio-time-stretch"] {
            opt.withCString { _mediaAddOpt?(media, $0) }
        }
        _mpSetMedia?(mp, media)
        _ = _mpPlay?(mp)
        _ = _mpSetRate?(mp, minRate)   // verified immediately after; logs WARNING if ignored
        Task { @MainActor in
            guard currentURL == url else { _mediaRelease?(media); return }   // superseded — don't leak it
            currentMedia = media; estimatedLagSec = 0; currentRate = minRate
            startStatsTimer()
        }
    }
}
```

**Why the split — `libvlc_media_player_stop` is a blocking call.** `_mpStop?(mp)` is `libvlc_media_player_stop`, which is *synchronous* (superseded by the async `libvlc_media_player_stop_async` in VLC 4+): it blocks the calling thread until VLC's internal input thread fully unwinds. Calling it on the MainActor was the root cause of a real, caught-live deadlock (`issues_resolved.md`, 2026-08-15, ~11 minute app-wide hang): `WebServer.pumpGrowingFile` (the recording-relay's data pump — see `docs/WebServer.md`) needs a `Task { @MainActor in ... }` hop once it catches up to the live edge, just to check `show_recording` before it can send the next chunk. If `_mpStop` ran on the MainActor at the exact instant VLC's own input thread was blocked reading that next chunk, neither side could ever unblock the other. Routing `_mpStop`/`_mpRelease` through `libvlcQueue` instead — shared by `play()`, `stop()`, `releasePlayer()`, and `stopAndClearState()` — keeps the MainActor free to service that exact poll-hop (and anything else) while VLC's teardown runs, breaking the cycle. Because `libvlcQueue` is serial (not concurrent), two overlapping calls for the same player object still execute their native work in strict submission order, matching the old blocking code's effective serialization for free.

**Correctness details worth knowing if you touch this again:**
- `currentURL` is still set synchronously (not deferred to the tail) — `AppState.seekRecording` calls `beginRecordingSeek` immediately after `play()` returns, and that call's staleness guard depends on `currentURL` already reflecting the just-requested URL.
- `currentMedia` is claimed (captured old value, then nil'd) synchronously, not in the tail — otherwise a second `play()`/`stop()`/`releasePlayer()` landing before the first call's tail runs could also capture the same old pointer and double-release it.
- The tail's final MainActor commit re-checks `currentURL == url` before writing `currentMedia`/starting the timer — if a newer `play()` call has since changed it, this call was superseded; it releases the media object it just created instead of leaking it, and does not resurrect stale state.
- The sequence inside the tail — stop → release old media → add options → set on player → play → set rate — is still the correct libvlc pattern; `libvlc_media_add_option` still must be called before `libvlc_media_player_set_media`.

`audioTracks`/`spuTracks`/`tracksFetched` are reset in the synchronous prefix (not just in `stopAndClearState()`/`releasePlayer()`) — `tickController` only calls `fetchTracks()` when `!tracksFetched`, so without this reset an ordinary channel switch would leave the *previous* channel's track lists showing in the toolbar pickers, and selecting one could call `setAudioTrack`/`setSpuTrack` with an id that doesn't exist on the new stream.

---

## Recording-Relay Seek State

`recordingShowId: String?` / `recordingStartDate: Date?` are the signal `AppState.vlcOccupiesTuner(for:)` reads to tell a zero-cost recording-playback relay session (`/api/watch-recording`, see `docs/WebServer.md`) apart from a real, tuner-occupying live stream — non-nil `recordingShowId` means "this is the relay, don't count it." `recordingSeekBaseSeconds`/`recordingReopenedAt` back `estimatedElapsedSeconds` (byte-offset-derived playback position, meaningless unless `recordingShowId` is non-nil).

`beginRecordingSeek(showId:recordingStart:seekBaseSeconds:)` and `clearRecordingSeek()` set/clear all four together. `AppState.watchRecordingInApp` calls `mgr.open()` synchronously to start the relay, then defers `beginRecordingSeek` via `DispatchQueue.main.async` (a separate run-loop turn so SwiftUI's toolbar picks up the update). `beginRecordingSeek` guards against that deferred call landing *after* the player has since moved on to a different stream (e.g. the user switched to a live channel in the gap before it fired, which already called `clearRecordingSeek()` synchronously via `play(url:)`): it only applies the update if `currentURL` still points at a `/api/watch-recording` URL containing `show=<showId>`; otherwise it logs a warning and no-ops rather than resurrecting a `recordingShowId` for a session that's no longer live, which would have made `vlcOccupiesTuner` under-count a real live stream as a free relay.

---

## Volume Scale

libvlc uses 0–200 (100 = unity gain). The UI uses 0–100. The bridge maps:
- `setVolume(_:)` → `Int32(v * 2)` clamped to 0–200

There is no `volume()` getter — it had zero call sites and was removed; callers track the 0–100 UI value themselves and only ever push it one-way via `setVolume(_:)`.

---

## Audio Device

The player routes audio through `auhal` (CoreAudio) on macOS. Devices are enumerated directly from the CoreAudio HAL via `systemAudioOutputDevices()` — this includes built-in speakers, USB/Bluetooth headphones, and AirPlay audio receivers when they are active. `setAudioDevice(output:deviceId:)` passes `"auhal"` as the output and the CoreAudio device UID as the device ID.

`startDeviceChangeMonitoring(callback:)` registers a CoreAudio property listener for `kAudioHardwarePropertyDevices`. It guards against double-registration: if `deviceChangeContext` is already set it calls `stopDeviceChangeMonitoring()` first, ensuring the old opaque pointer is removed before ARC frees it (a freed pointer left registered with CoreAudio is a use-after-free on the next device-change event). `stopDeviceChangeMonitoring()` removes the listener and nils `deviceChangeContext`.

---

## Public API

```swift
var isAvailable: Bool                                          // false when VLC not installed
var liveMinRate: Float                                         // fill-phase floor for live streams (0.90–1.0); set from AppConfig — external code sets this, never minRate
@Published var currentURL: String?                            // URL currently playing; nil when stopped
@Published var bufferInfo: VLCBufferInfo                      // rate/lag/bitrate snapshot; published every 3s tick
@Published var hasError:    Bool                              // true when libvlc_Error (state 7) detected; cleared on play/stop/release
@Published var hasEnded:    Bool                              // true after libvlc_Ended (state 6) detected; cleared on play/stop/release
@Published var isPlaying:   Bool                              // true after libvlc_Playing (state 3) first confirmed; cleared on play/stop/release
@Published var audioTracks: [(id: Int32, name: String)]       // stream audio tracks; empty = single/unknown; populated ~3s after playing
@Published var spuTracks:   [(id: Int32, name: String)]       // CC/subtitle tracks; empty = none detected; populated ~3s after playing
@Published var videoPixelSize: CGSize?                        // physical pixel dims from the decoded frame; nil until first frame; drives canResizeToNative/native-res popover in VLCPlayerView
var recordingShowId: String?                                  // non-nil while playing the /api/watch-recording relay for this show_id; nil = live stream (see Recording-Relay Seek State)
var recordingStartDate: Date?                                 // paired with recordingShowId; the recording's scheduled start, for elapsed-time display
var recordingPlaybackSeconds: Double                           // computed elapsed seconds into the relay playback; meaningless unless recordingShowId is non-nil (drives scrub position in VLCPlayerView)
static func locateApp() -> URL?                                // resolves installed VLC.app via Launch Services bundle-id lookup; used as the VLC-installed gate in Settings/AppState
func beginRecordingSeek(showId: String, recordingStart: Date, seekBaseSeconds: Double)  // arms recording-relay seek state; no-ops if currentURL no longer matches showId (stale deferred call)
func clearRecordingSeek()                                     // clears recording-relay seek state; called by play(url:) for any non-relay URL
func setDrawable(_ view: NSView)                              // must be called before first play()
func play(url: String)                                        // stop + switch to new URL; resets rate controller, hasError, isPlaying — synchronous call, but the actual libvlc stop/reconnect work runs on libvlcQueue (off the MainActor); see "Channel Switching (play)"
func stop()                                                   // soft/resumable stop: stop + release media; cancels stats timer; clears hasError, isPlaying — deliberately leaves drawableView attached so a later play() renders immediately (used by the remote-Stop key); native stop work deferred to libvlcQueue
func releasePlayer()                                          // full teardown; releases mediaPlayer; clears hasError, isPlaying, drawableView — window close only; ensurePlayer() must run before the next play(); native stop/release work deferred to libvlcQueue
func catchUpToLive()                                          // discard buffer, reconnect at live edge
func videoNativeSize() -> CGSize?                             // pixel dims from libvlc_video_get_size; nil until decoding
func setVolume(_ v: Int)                                      // 0–100
func setAudioDevice(output: String, deviceId: String)         // output = "auhal"; deviceId = CoreAudio device UID
func systemAudioOutputDevices() -> [(id: String, name: String)]  // all CoreAudio output devices (built-in, BT, AirPlay, USB)
func systemDefaultOutputUID() -> String?                      // UID of current system-default output device
func fetchTracks()                                            // poll libvlc for audio/SPU track descriptions; called from tickController; retries until audio found
func setAudioTrack(id: Int32)                                 // select audio track by libvlc track id
func setSpuTrack(id: Int32)                                   // select CC/subtitle track; −1 = off
```

### VLCBufferInfo

Published snapshot of the live buffer state, updated on every `tickController` tick:

```swift
struct VLCBufferInfo {
    var lagSec:       Double  // estimated buffer lag behind live edge (0..8s)
    var rate:         Float   // current playback rate (minRate..1.0)
    var demuxBitrate: Float   // f_demux_bitrate from libvlc stats (kB/s); 0 when stats unavailable
    var corrupted:    Int32   // cumulative i_demux_corrupted count
    var enabled:      Bool    // false when minRate == 1.0 (buffering disabled)
}
```

`rate`/`lag` are published unconditionally each tick (before the stats guard) so the buffer monitor bar remains functional even when `_mpGetStats` is unavailable (VLC 4+). `demuxBitrate` and `corrupted` retain their previous values when stats are skipped.

---

## Initialization Details

### `libvlccore.dylib` preload

Before loading `libvlc.dylib`, the init loads (using the `vlcAppURL` resolved by `locateApp()`, not a hardcoded path):

```swift
dlopen("\(vlcAppURL)/Contents/MacOS/lib/libvlccore.dylib", RTLD_LAZY | RTLD_GLOBAL)
```

`RTLD_GLOBAL` exposes `libvlccore`'s symbols to the dynamic linker's global namespace. This is required because `libvlc.dylib` calls into `libvlccore` by symbol name at load time; if the core isn't already globally visible, `libvlc` fails to find its own symbols and the dlopen returns nil.

### `VLC_PLUGIN_PATH`

Set before `libvlc_new` runs, again derived from the resolved `vlcAppURL`:

```swift
setenv("VLC_PLUGIN_PATH", "\(vlcAppURL)/Contents/MacOS/plugins", 1)
```

VLC discovers its codec and mux plugins via this path. Without it, `libvlc_new` can't find any decoders and the player creates successfully but nothing plays.

### Off-main-thread `libvlc_new`

`libvlc_new` loads 300+ plugin bundles and takes 0.3–1s depending on the machine. The call runs inside `Task.detached(priority: .userInitiated)` to avoid blocking the main actor (and thus the SwiftUI layout engine) during app startup or first VLC use. The media player, drawable attachment, and initial `play()` call are all serialized after init completes via `@MainActor.run`.

If `play(url:)` is called before init finishes (e.g. a Watch button tapped immediately), the URL is stored in `pendingURL` and replayed as soon as the detached task posts back to the main actor.

---

## `pendingURL` Queue

`pendingURL: String?` holds a single deferred URL when playback is requested before the player is ready:

- **Case 1 — init not yet complete**: `play()` is called but `mediaPlayer` is nil. URL stored in `pendingURL`; the detached `libvlc_new` task checks `pendingURL` after posting to main actor and calls `play()` immediately.
- **Case 2 — drawable not yet set**: `play()` is called before `setDrawable(_:)`. URL stored in `pendingURL`; `setDrawable` calls `play()` as soon as the view arrives.

At most one URL is queued (last write wins). This is sufficient because `VLCPlayerWindowManager` sequences these calls and never queues more than one.

---

## `retainedDrawable`

`retainedDrawable: NSView?` holds a strong reference to the drawable `NSView` after `releasePlayer()` is called. libvlc dispatches video/drawable callbacks off the main thread; those callbacks can fire briefly after `libvlc_media_player_release` returns. If the NSView is deallocated while a callback is in flight, the result is a use-after-free crash. `retainedDrawable` keeps the view alive until the next `setDrawable` call (which replaces it) or until `ensurePlayer()` is called and attaches the same view to the new player.

---

## `ensurePlayer()`

```swift
func ensurePlayer()
```

Recreates the media player after `releasePlayer()` without reloading the full VLC stack. Called by `VLCPlayerWindowManager.open()` before each new player session. Steps:

1. No-op if `mediaPlayer` is already non-nil (already created for this session)
2. Creates a new `mediaPlayer` via `_mpNew?(vlcInstance)`
3. If `drawableView` is non-nil, re-attaches it: calls `_mpSetNSO?(mp, ...)` and sets `retainedDrawable = view` (assigns the drawable view, doesn't clear it)

`ensurePlayer()` does **not** start playback itself — it has no `pendingURL` handling. `VLCPlayerWindowManager.open()` calls `ensurePlayer()` and then `play(url:)` as two separate steps right after.

If `vlcInstance` or `_mpNew` is nil (VLC not loaded), logs a warning and returns without crashing — the `isAvailable` gate in the UI prevents this path from being reached under normal conditions.
