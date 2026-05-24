# VLCPlayerView.swift — VLC In-App Player Window

## Intent

Replaces `PlayerView.swift` (AVKit / `AVPlayer`). AVPlayer cannot decode MPEG-2 transport streams — the native broadcast format from HDHomeRun tuners — and silently failed on any show with `transcode = none`. The VLC-based player decodes MPEG-2 natively, so the user's configured transcode setting is respected without any forced override.

The player opens as a detached `NSWindow` with a SwiftUI toolbar above the video surface. It has a channel picker, volume slider, audio output selector, and audio device selector. The window is reusable — opening it a second time switches the stream rather than creating a new window.

Gate: both `Player_unlocked` (5-tap easter egg in Settings → About) **and** `VLCBridge.shared.isAvailable` (VLC.app installed at `/Applications/VLC.app`) must be true for "Watch Now!" buttons to appear anywhere in the UI.

---

## File Structure

Three components live in this file:

```
VLCVideoSurface       NSViewRepresentable — the black NSView VLC renders into
VLCPlayerView         SwiftUI View — toolbar + video surface; content of the NSWindow
VLCPlayerWindowManager  @MainActor singleton — creates and reuses the NSWindow
```

---

## VLCVideoSurface

```swift
private struct VLCVideoSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = CGColor(gray: 0, alpha: 1)
        VLCBridge.shared.setDrawable(v)
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
```

`makeNSView` is the only meaningful method — `updateNSView` is intentionally empty. The key call is `VLCBridge.shared.setDrawable(v)`, which attaches the NSView to VLC's internal render target via `libvlc_media_player_set_nsobject`. This must happen before `play()` is first called; the timing is guaranteed because `makeNSView` runs during the first layout pass, which precedes any user interaction with the channel picker.

**Why setDrawable in makeNSView and not updateNSView**: `updateNSView` can be called any time SwiftUI re-evaluates the view. Calling `setDrawable` there would call `libvlc_media_player_set_nsobject` on every re-evaluation, which interrupts active playback. `makeNSView` runs exactly once per view lifetime, which is the correct moment to attach the drawable.

**wantsLayer = true**: required for VLC to render into the view. Without it, VLC has no CALayer to composite into and the video surface stays black.

---

## VLCPlayerView

### Props and State

```swift
let device: HDHRDevice    // fixed at window-open; determines which lineup the channel picker shows
let initialURL: String    // stream URL active when the window opened; drives initial channel selection

@State private var selectedChannel: LineupEntry?
@State private var volume: Double = 50
@State private var audioOutputs: [(name: String, description: String)] = []
@State private var selectedOutput: String = ""
@State private var audioDevices: [(id: String, name: String)] = []
@State private var selectedDevice: String = ""
```

`device` is fixed at window-open time. There is no device switching in the player toolbar — the channel picker always shows channels from the device that was streaming when the window was opened. This keeps the UI simple and avoids the complexity of re-discovering tuner availability mid-session.

### Lineup Computed Property

```swift
private var lineup: [LineupEntry] {
    (state.lineups[device.DeviceID] ?? []).sorted {
        $0.GuideNumber.localizedStandardCompare($1.GuideNumber) == .orderedAscending
    }
}
```

Reads from `AppState.lineups` (already loaded at app startup). `localizedStandardCompare` sorts guide numbers correctly: `2`, `2.1`, `2.2`, `5.1`, `10`, `10.1` rather than lexicographic order which would put `10` before `2`.

### onAppear

```swift
.onAppear {
    volume = Double(VLCBridge.shared.volume())
    audioOutputs = VLCBridge.shared.audioOutputs()
    if selectedOutput.isEmpty, let first = audioOutputs.first {
        selectedOutput = first.name
    }
    refreshAudioDevices()
    if selectedChannel == nil, !initialURL.isEmpty {
        let baseURL = initialURL.components(separatedBy: "?").first ?? initialURL
        selectedChannel = lineup.first { ($0.URL ?? "").hasPrefix(baseURL) || baseURL.hasPrefix($0.URL ?? "") }
    }
}
```

The initial channel pre-selection strips query parameters from `initialURL` before matching because the URL passed to `open()` may have `?transcode=heavy` appended while `LineupEntry.URL` is the raw base URL. Both `hasPrefix` directions are checked to handle edge cases where one URL is a prefix of the other.

The pre-selection only sets `selectedChannel` — it does **not** call `playChannel()`. The stream is already playing (started by `VLCPlayerWindowManager.open()` before the window appears). Setting `selectedChannel` purely populates the picker UI.

### Toolbar Layout

```
[Channel picker ─────────] Spacer [🔊] [─── slider ───] | [Output picker] [Device picker]
```

- **Channel picker**: `.labelsHidden()`, max width 220 pt, tags use `Optional(ch)` to match the `LineupEntry?` binding
- **Volume**: speaker icon + `Slider(value:in:0...100)`. `onChange` maps to `VLCBridge.shared.setVolume(Int(v))`.
- **Audio output picker**: only shown when `!audioOutputs.isEmpty`. Selecting an output also triggers `refreshAudioDevices()` because the device list is output-scoped.
- **Audio device picker**: only shown when `audioDevices.count > 1`. Hiding it when there is only one device avoids a pointless single-item picker cluttering the toolbar on most setups.

### playChannel

```swift
private func playChannel(_ ch: LineupEntry) {
    guard let rawURL = ch.URL, !rawURL.isEmpty else { return }
    let transcode = state.config.Default_transcode.lowercased()
    let url = (transcode.isEmpty || transcode == "none")
        ? rawURL
        : "\(rawURL)?transcode=\(transcode)"
    VLCBridge.shared.play(url: url)
}
```

Reads `config.Default_transcode` (not the show's per-show transcode, since the channel picker is device/lineup-level, not show-level). When transcode is `"none"` or empty, the raw stream URL is used — VLC decodes MPEG-2 natively so no transcode is needed. This is the key difference from the old AVPlayer path, which always forced `heavy`.

### onDisappear

Calls `VLCBridge.shared.stop()` when the window closes. This releases the current media object and stops the stream cleanly. The player itself (`VLCBridge.shared.mediaPlayer`) is not destroyed — it stays alive for the next `open()` call.

---

## VLCPlayerWindowManager

```swift
@MainActor
final class VLCPlayerWindowManager {
    static let shared = VLCPlayerWindowManager()
    private var window: NSWindow?

    func open(url: String, title: String, device: HDHRDevice, appState: AppState) {
        VLCBridge.shared.play(url: url)          // always start/switch the stream immediately
        if let win = window {
            win.title = title
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // first open: create window ...
    }
}
```

### Singleton NSWindow with isReleasedWhenClosed = false

```swift
win.isReleasedWhenClosed = false
```

By default, macOS releases (deallocates) an `NSWindow` when it is closed. For a reusable player window, this is wrong — closing the window should merely hide it. `isReleasedWhenClosed = false` keeps the window object alive in `self.window` so the next `open()` call can bring it forward without recreating the hosting view, the SwiftUI state, or the VLC drawable attachment.

Without this, the second `open()` call would create a new window with a new `NSHostingView`, triggering `VLCVideoSurface.makeNSView` again — which would call `setDrawable` again and interrupt any stream that was resumed before the window appeared.

### Stream-First Design

`VLCBridge.shared.play(url: url)` is called **before** any window logic. This means:
- The stream starts immediately on first open, before the window appears
- On re-open while the window is already visible, the stream switches immediately without waiting for UI interactions
- The channel picker's initial selection (set in `.onAppear`) reflects what is already playing, not what triggers play

### Window Size

960×600 pt. Resizable, titled, closable, miniaturizable. The 960 wide minimum gives the toolbar enough room to show all pickers without truncation at typical VLC stream resolutions.

---

## AppState.watchInApp

```swift
func watchInApp(url: String, title: String, deviceId: String? = nil, transcode: String? = nil) {
    guard config.Player_unlocked, VLCBridge.shared.isAvailable else { return }
    let profile = (transcode ?? config.Default_transcode).lowercased().trimmingCharacters(in: .whitespaces)
    let streamURL = (profile.isEmpty || profile == "none") ? url : "\(url)?transcode=\(profile)"
    let device = devices.first { $0.DeviceID == (deviceId ?? "") } ?? devices.first
    guard let device else { return }
    VLCPlayerWindowManager.shared.open(url: streamURL, title: title, device: device, appState: self)
}
```

`deviceId` is passed at each call site so the channel picker knows which device's lineup to show. Three call sites:
- Guide entry menu (`entryMenu`): passes `device.DeviceID` (HDHRDevice is in scope)
- Recording menu (`recordingMenu`): passes `show.hdhr_record` (the device ID stored on the show)
- AddShowView summary panel: passes `selectedDevice?.DeviceID`

Falls back to `devices.first` if no match, so the picker always has a device even if the stored ID is stale.

---

## What Replaced What

| Old (PlayerView.swift) | New |
|---|---|
| `PlayerWindowManager` (AVKit) | `VLCPlayerWindowManager` + `VLCBridge` |
| `AVPlayer` + `AVPlayerView` | `VLCVideoSurface` (NSView drawable) |
| Forced `transcode=heavy` for all streams | Respects show/default transcode; "none" = raw stream |
| No channel picker | Channel picker for current device's lineup |
| No audio output control | Audio output + device pickers |
| MPEG-2 fails silently | MPEG-2 plays natively via VLC |

---

## Transcode Behavior

| `Default_transcode` | URL sent to VLC |
|---|---|
| `"none"` or `""` | `http://{device}/auto/vX.X` (raw stream) |
| `"heavy"` | `http://{device}/auto/vX.X?transcode=heavy` |
| `"mobile"` | `http://{device}/auto/vX.X?transcode=mobile` |
| `"internet720"` | `http://{device}/auto/vX.X?transcode=internet720` |

For the channel picker, `Default_transcode` is used (no show-specific transcode because the picker is not show-aware). For "Watch Now!" from a recording or guide entry, the show's `show_transcode` is passed and takes priority.
