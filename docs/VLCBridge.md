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

## C Struct Mirrors

libvlc returns linked lists for audio outputs and devices. Since we have no VLC headers at compile time, the structs are mirrored in Swift:

```swift
private struct vlc_audio_output_t {
    let psz_name:        UnsafePointer<CChar>?
    let psz_description: UnsafePointer<CChar>?
    let p_next:          UnsafeMutablePointer<vlc_audio_output_t>?
}

private struct vlc_audio_output_device_t {
    let p_next:          UnsafeMutablePointer<vlc_audio_output_device_t>?
    let psz_device:      UnsafePointer<CChar>?
    let psz_description: UnsafePointer<CChar>?
}
```

**Field order is critical** — it must exactly match the layout in `libvlc_media_player.h`. Note that `vlc_audio_output_device_t` has `p_next` first (before the string fields), which is the opposite of `vlc_audio_output_t`. Getting this wrong produces garbage reads or crashes.

---

## @convention(c) Typedef Constraints

Swift's `@convention(c)` requires that all parameter and return types be representable in Objective-C. Swift structs — even those containing only C-compatible types — do **not** satisfy this requirement. This caused a build failure when the list get/release typedefs used typed `UnsafeMutablePointer<vlc_audio_output_t>`.

**Fix**: the list get/release typedefs use `UnsafeMutableRawPointer` instead:

```swift
private typealias vlc_aout_list_get_fn = @convention(c) (OpaquePointer?) -> UnsafeMutableRawPointer?
private typealias vlc_aout_list_rel_fn = @convention(c) (UnsafeMutableRawPointer?) -> Void
```

The typed pointer is recovered via `bindMemory` at the call site:
```swift
var node = rawHead.bindMemory(to: vlc_audio_output_t.self, capacity: 1)
```

This is safe because `rawHead` is the address of the first node in a libvlc-allocated linked list whose layout we know exactly.

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
    _mpStop?(mp)
    if let old = currentMedia { _mediaRelease?(old); currentMedia = nil }
    guard let media = url.withCString({ _mediaNL?(inst, $0) }) else { return }
    currentMedia = media
    _mpSetMedia?(mp, media)
    _ = _mpPlay?(mp)
}
```

The sequence stop → release old media → new media → set on player → play is the correct libvlc pattern. Skipping `_mpStop` before setting new media can leave the previous stream in flight and produce audio bleed. The `currentMedia` reference is retained because libvlc does not retain the media object after `libvlc_media_player_set_media` — releasing it immediately would deallocate the media while VLC is still reading it.

---

## Volume Scale

libvlc uses 0–200 (100 = unity gain). The UI uses 0–100. The bridge maps:
- `volume()` → `Int(vlcVol) / 2` clamped to 0–100
- `setVolume(_:)` → `Int32(v * 2)` clamped to 0–200

---

## Audio Output vs Audio Device

These are two separate concepts in libvlc:

- **Audio output** (`libvlc_audio_output_*`) — the output *module*, e.g. `auhal` (CoreAudio) or `display` (HDMI/DisplayPort output). On macOS there are usually 2.
- **Audio device** (`libvlc_audio_output_device_*`) — the specific hardware device within an output module, e.g. "Built-in Speakers", "AirPods Pro", "HDMI". There may be many.

The device list is output-scoped: you call `libvlc_audio_output_device_list_get(instance, outputName)` — a different list per output module. The bridge's `audioDevices(forOutput:)` takes the output name string for this reason.

Setting a device requires passing both the output name and device ID to `libvlc_audio_output_device_set`.

---

## Public API

```swift
var isAvailable: Bool                                          // false when VLC not installed
func setDrawable(_ view: NSView)                              // must be called before first play()
func play(url: String)                                        // stop + switch to new URL
func stop()                                                   // stop + release current media
func volume() -> Int                                          // 0–100
func setVolume(_ v: Int)                                      // 0–100
func audioOutputs() -> [(name: String, description: String)]
func setAudioOutput(_ name: String)
func audioDevices(forOutput: String) -> [(id: String, name: String)]
func setAudioDevice(output: String, deviceId: String)
```
