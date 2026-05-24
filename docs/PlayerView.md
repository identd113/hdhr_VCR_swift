# PlayerView.swift — In-App Video Player

## Intent

`PlayerView.swift` provides a pop-out AVKit player window for watching live HDTV streams in-app. It is gated behind a `Player_unlocked` easter egg (5-tap on the About logo in Settings). Once unlocked, "Watch in App" buttons appear in the guide summary panel and recording menus alongside "Watch in VLC".

The player is managed by a singleton `PlayerWindowManager` — calling `play()` reuses the same window rather than opening duplicates.

---

## `PlayerWindowManager`

```swift
@MainActor
final class PlayerWindowManager {
    static let shared = PlayerWindowManager()
    private var window: NSWindow?
    private var player: AVPlayer?
    private var statusObserver: NSKeyValueObservation?
}
```

**Why a singleton with a reused window**: `NSWindow` from a `.menu`-style `MenuBarExtra` must be opened with `DispatchQueue.main.async` (same reason as `MenuContent.open(_:)`). A new `NSWindow` per stream would accumulate if the user clicks Watch in App repeatedly. The singleton holds one `NSWindow?` and one `AVPlayer?`; calling `play()` a second time replaces the stream in the same window.

**`isReleasedWhenClosed = false`**: Standard `NSWindow` behavior is to dealloc on close. Setting this to `false` keeps the `NSWindow` object alive in `self.window` so the next `play()` call can reuse it. Without this, the second call to `play()` hits `if let win = window` with a stale pointer and crashes or opens a new window instead of reusing.

---

## `play(url:title:)`

```swift
func play(url: URL, title: String) {
    let avPlayer = AVPlayer(url: url)
    self.player = avPlayer
    let playerView = AVPlayerView()
    playerView.player = avPlayer
    playerView.controlsStyle = .inline

    if let win = window {
        win.contentView = playerView   // replace stream in existing window
        win.title = title
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    } else {
        let win = NSWindow(...)        // create 960×560 window first time
        win.isReleasedWhenClosed = false
        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    avPlayer.play()
}
```

The `statusObserver` KVO on `avPlayer.currentItem.status` logs errors to `~/Library/Logs/hdhr_player.log`. Each `play()` call invalidates the previous observer before creating a new one.

---

## MPEG-2 Constraint — CRITICAL

**AVPlayer does NOT support MPEG-2 transport streams.** HDHomeRun tuners stream MPEG-2 by default. Calling `play()` with an untranscoded stream URL always results in a black screen with status `failed`.

**The fix**: `AppState.watchInApp(url:title:)` forces `transcode=heavy` on the stream URL before passing it to `PlayerWindowManager.shared.play()`:

```swift
func watchInApp(url: String, title: String) {
    guard config.Player_unlocked,
          let baseURL = URL(string: url) else { return }
    // Force heavy transcode — AVPlayer cannot decode MPEG-2
    var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
    var items = comps.queryItems ?? []
    items.removeAll { $0.name == "transcode" }
    items.append(URLQueryItem(name: "transcode", value: "heavy"))
    comps.queryItems = items
    guard let streamURL = comps.url else { return }
    PlayerWindowManager.shared.play(url: streamURL, title: title)
}
```

**Never pass a raw (untranscoded) stream URL to `PlayerWindowManager`.** The `watchInApp` helper is the only correct call site. Do not add additional call sites without going through this helper.

---

## `Player_unlocked` Easter Egg

The player is hidden until `state.config.Player_unlocked == true`. This field is set by tapping the app logo in Settings → About exactly 5 times. On unlock:
- An alert is shown: `"In-App Player unlocked"`
- `state.config.Player_unlocked = true` is written to disk
- `draft.Player_unlocked = true` is mirrored so the Settings view doesn't show the draft as dirty

Once unlocked, "Watch in App" buttons appear:
- In `AddShowView` summary panel (conditional on `config.Player_unlocked && onAir`)
- In `MenuContent.recordingMenu` (conditional on `config.Watch_in_VLC`-style check; shares the same button row)

The unlocked state persists across restarts via `AppConfig`. There is no way to re-lock it through the UI — edit the config JSON directly if needed.

---

## Log File

`~/Library/Logs/hdhr_player.log` — appended to (not overwritten) on each `play()` call. Each block:
```
[2026-05-23 20:11:05] play url=http://192.168.1.5:5004/auto/v5.1?...
[2026-05-23 20:11:06] item status=2 error=The operation couldn't be completed. ...
```

Status codes: 0 = unknown, 1 = readyToPlay, 2 = failed. Status 2 with MPEG-2 URL is the expected failure if `watchInApp` is bypassed.

The `appendLine(to:)` helper (`String` extension, file-private) opens the file handle, seeks to end, writes, closes. Falls back to `write(to:)` for the first write (file doesn't exist yet).
