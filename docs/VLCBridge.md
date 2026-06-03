# VLCBridge.swift — Runtime libvlc Wrapper

## Intent

`VLCBridge` loads `libvlc.dylib` from VLC.app at runtime using `dlopen`/`dlsym`. The app has **no compile-time dependency on VLC** — it builds and runs normally when VLC is not installed; the player feature is simply unavailable. The gate for all "Watch Now!" UI is `VLCBridge.shared.isAvailable`, which is `true` only when the dylib loads and the two sentinel symbols resolve successfully.

---

## Why dlopen Instead of a Framework

The alternative (linking VLCKit as a framework or SPM package) would require distributing a copy of VLC inside the app bundle (~100 MB) or require the user to have VLCKit installed separately. Neither is acceptable for a menu bar utility. With `dlopen`:

- Binary stays small — no VLC code at link time
- User's already-installed `/Applications/VLC.app` is used as-is
- The feature degrades gracefully when VLC is absent

---

## Initialization

`VLCBridge` is a `@MainActor` singleton (`VLCBridge.shared`). Its `private init()` runs once on first access.

```
dlopen("/Applications/VLC.app/Contents/MacOS/lib/libvlc.dylib", RTLD_LAZY | RTLD_LOCAL)
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
"--network-caching=2000"     // 2s initial prebuffer — near-instant start
"--drop-late-frames"         // drop corrupt/late frames rather than showing artifacts
"--avcodec-hurry-up"         // drop non-essential B-frames under decode pressure
"--no-audio-time-stretch"    // prevent audio init crash when sample rate is 0 on first MPEG-2 frame
```

`--no-audio-time-stretch` is specifically required for live MPEG-2 transport streams from HDHomeRun tuners. VLC's audio time-stretch module tries to initialize before the first audio frame arrives, sees a 0 Hz sample rate, and fails with `too low audio sample frequency (0)` / `module not functional`. The option prevents that module from loading for live streams.

An adaptive rate controller runs every 3 seconds via a repeating `Timer` (`statsTimer`):

- **Fill phase**: Plays at `minRate` (from `AppConfig.Player_buffer_min_rate`; default 0.93). Stream arrives ~7% faster than consumed — VLC's demux buffer grows.
- **Hold phase**: Rate ramps linearly toward 1.0 as `estimatedLagSec` approaches the 8-second target. At 8s the rate reaches 1.0 and the buffer stabilises.
- **Auto catch-up**: Same tick polls `libvlc_media_player_get_stats`. If `i_demux_corrupted` rises by >15 or `i_lost_pictures` rises by >20 in 3s, calls `catchUpToLive()` with a 30s debounce.

Rate formula applied every tick:
```
estimatedLagSec += (1.0 - currentRate) * 3.0   // capped at 8.0
fillRatio = estimatedLagSec / 8.0
newRate   = minRate + (1.0 - minRate) * fillRatio
```

`catchUpToLive()` calls `play(url: currentURL)`, which stops the stream, resets `estimatedLagSec` to 0, and restarts the fill phase from scratch.

When `minRate == 1.0` (buffering disabled in Settings), rate control is skipped entirely; the stats timer still runs for corruption detection only.

### Stream state detection

Each `tickController` tick calls `libvlc_media_player_get_state` before the rate-control logic:

| State value | libvlc constant | Action |
|---|---|---|
| 3 | `libvlc_Playing` | Sets `isPlaying = true` on first confirmation; enables Start button in UI |
| 7 | `libvlc_Error` | Sets `hasError = true`, stops timer; error overlay appears in UI |
| other | — | No action; rate controller proceeds normally |

`hasError` and `isPlaying` are reset to `false` in `play()`, `stop()`, and `releasePlayer()` so state is clean on every new stream attempt.

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
| Auto catch-up | INFO | `[VLC] signal corruption detected (corrupt=N lost=N) — catching up to live` |

### Known risks

- **VLC 4.x stats struct** — `VLCStats` mirrors the VLC 3.x `libvlc_media_stats_t` field layout. VLC 4 reorganised the struct; on VLC 4 the corruption/lost-frame counters will read garbage. The version check at init logs a WARNING if major ≥ 4, and the stats return-value check logs a WARNING if the call returns non-1. Both degrade gracefully: auto catch-up stops working but playback is unaffected.
- **`set_rate` on live streams** — `libvlc_media_player_set_rate` may be silently ignored for non-seekable streams on some VLC versions. After setting rate, `libvlc_media_player_get_rate` is called to verify; a mismatch logs a WARNING. If ignored, the buffer never grows but playback continues normally at 1.0x.

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

```swift
func play(url: String) {
    stopStatsTimer()
    _mpStop?(mp)
    if let old = currentMedia { _mediaRelease?(old); currentMedia = nil }
    guard let media = url.withCString({ _mediaNL?(inst, $0) }) else { return }
    for opt in ["--network-caching=2000", "--drop-late-frames", "--avcodec-hurry-up"] {
        opt.withCString { _mediaAddOpt?(media, $0) }
    }
    currentURL = url; currentMedia = media
    estimatedLagSec = 0; currentRate = minRate
    _mpSetMedia?(mp, media)
    _ = _mpPlay?(mp)
    _ = _mpSetRate?(mp, minRate)   // verified immediately after; logs WARNING if ignored
    startStatsTimer()
}
```

The sequence stop → cancel timer → release old media → add options → set on player → play → set rate → start timer is the correct libvlc pattern. `libvlc_media_add_option` must be called before `libvlc_media_player_set_media` — options set after that call are silently ignored. The `currentMedia` reference is retained because libvlc does not retain the media object after `libvlc_media_player_set_media`.

---

## Volume Scale

libvlc uses 0–200 (100 = unity gain). The UI uses 0–100. The bridge maps:
- `volume()` → `Int(vlcVol) / 2` clamped to 0–100
- `setVolume(_:)` → `Int32(v * 2)` clamped to 0–200

---

## Audio Device

The player routes audio through `auhal` (CoreAudio) on macOS. Devices are enumerated directly from the CoreAudio HAL via `systemAudioOutputDevices()` — this includes built-in speakers, USB/Bluetooth headphones, and AirPlay audio receivers when they are active. `setAudioDevice(output:deviceId:)` passes `"auhal"` as the output and the CoreAudio device UID as the device ID.

`startDeviceChangeMonitoring(callback:)` registers a CoreAudio property listener for `kAudioHardwarePropertyDevices`. It guards against double-registration: if `deviceChangeContext` is already set it calls `stopDeviceChangeMonitoring()` first, ensuring the old opaque pointer is removed before ARC frees it (a freed pointer left registered with CoreAudio is a use-after-free on the next device-change event). `stopDeviceChangeMonitoring()` removes the listener and nils `deviceChangeContext`.

---

## Public API

```swift
var isAvailable: Bool                                          // false when VLC not installed
var minRate: Float                                             // fill-phase floor (0.90–1.0); set from AppConfig
var currentURL: String?                                        // URL currently playing; nil when stopped
@Published var bufferInfo: VLCBufferInfo                      // rate/lag/bitrate snapshot; published every 3s tick
@Published var hasError:    Bool                              // true when libvlc_Error (state 7) detected; cleared on play/stop/release
@Published var isPlaying:   Bool                              // true after libvlc_Playing (state 3) first confirmed; cleared on play/stop/release
@Published var audioTracks: [(id: Int32, name: String)]       // stream audio tracks; empty = single/unknown; populated ~3s after playing
@Published var spuTracks:   [(id: Int32, name: String)]       // CC/subtitle tracks; empty = none detected; populated ~3s after playing
func setDrawable(_ view: NSView)                              // must be called before first play()
func play(url: String)                                        // stop + switch to new URL; resets rate controller, hasError, isPlaying
func stop()                                                   // stop + release media; cancels stats timer; clears hasError, isPlaying
func releasePlayer()                                          // full teardown; releases mediaPlayer; clears hasError, isPlaying
func catchUpToLive()                                          // discard buffer, reconnect at live edge
func videoNativeSize() -> CGSize?                             // pixel dims from libvlc_video_get_size; nil until decoding
func volume() -> Int                                          // 0–100
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
