# VLCPlayerView.swift — VLC In-App Player Window

## Visual Appearance

### Overall window
`NSWindow` created by `VLCPlayerWindowManager`. Initial size **960×600**, resizable and closable. Title = the show/channel name passed at open time. Centers on first open; re-uses same position on subsequent opens (not re-centered).

### Layout
`VStack(spacing: 0)`:
1. **Toolbar** (~42pt tall, `windowBackgroundColor` background)
2. **Video surface** (fills all remaining space, black background)

### Toolbar
`HStack(spacing: 10)`, 12pt horizontal and 8pt vertical padding:

- **Channel picker** (left, max 220pt wide): standard `Picker` popup. Three row groups, in order: (1) a bare **"Live"** fallback row, tagged `Optional<LineupEntry>.none` — selected only if `selectedChannel` is nil and nothing else below matched, so the picker never renders blank; hidden entirely when nothing on this device is recording (`recordingChannelEntries.isEmpty`), since there's no "Live" to fall back to then; (2) one **"Live 5.1  Show Title"** row per show currently recording on this device (`recordingChannelEntries` — see below); (3) the device's real channels, `"5.1  NBC"` channel number + name. Hidden label. `onChange(of: selectedChannel)` routes: a `recordingChannelEntries` tag → `AppState.watchRecordingInApp(_:)` (switch to that recording's relay stream, no new tuner); anything else → `playChannel()` (live device channel, new tuner).
- **Quick-record button** (`record.circle`, `.plain` style, red) — icon-only (no room for a labeled button here), a `quickRecordMenu` (`GuideViewHelpers.swift`) pulldown of the four `ShowState` types, same one `WatchNowRow`'s Record button uses — see `docs/WatchNowView.md`'s Action row entry for the shared implementation. Hidden when: watching a recording-relay stream already (`bridge.recordingShowId != nil` — it's already being captured), nothing's currently airing on the selected channel (`currentGuideEntry == nil`), or this exact channel already has an active managed show (a direct `state.shows` filter on `hdhr_record`+`show_channel`, not a full `ManagedGuideMatcher` — a `seriesAll` show that's merely following this series from another channel won't suppress the button, a deliberately simple check rather than the fuller one `WatchNowView`'s ring-state logic uses). Picking a type calls `state.tunersFull(for:)` first; if full, shows the same "All Tuners Busy" alert `WatchNowRow` shows (new `showTunerFullAlert` state + `.alert` on `body`, this view didn't have one before).
- **Spacer**
- **Buffer monitor + catch-up pill** (visible only when buffering is enabled, i.e. `minRate < 1.0`): `waveform` SF Symbol (`.accessibilityHidden(true)`) + 50pt fill-bar capsule, grouped with the catch-up button into one pill (`.secondary.opacity(0.08)` background, hairline `Divider` between them) — both relate to live-stream temporal state. Bar fill = `estimatedLagSec / 8s`; blue while filling, green when ≥ 87.5% full (≥ 7s). Hover → popover showing lag, rate, bitrate (kB/s from `f_demux_bitrate`), and cumulative corruption count. Driven by `@Published VLCBridge.bufferInfo` (updated every 3s by the rate controller tick). Published unconditionally so the bar appears even when `_mpGetStats` is unavailable (VLC 4+). Accessibility: collapsed to a single element — `.accessibilityLabel("Live buffer")`, `.accessibilityValue("N of 8 seconds")` using whole seconds to avoid flooding VoiceOver with fine-grained changes on each 3-second tick. Never shown for a recording-relay session — `play(url:)` forces `minRate = 1.0` there (see `docs/VLCBridge.md`), since a local loopback file read has no network jitter to buffer against; only `catchUpButton` (standalone, no pill) is shown then.
- **Native resolution button** (`aspectratio`, `.plain` style): calls `VLCPlayerWindowManager.shared.sizeToNativeVideo()` — reads the stream's pixel dimensions via `libvlc_video_get_size`, divides by the screen's backing scale factor to get logical points, adds 44pt for the toolbar, and resizes the window with `setContentSize` + `center()`. `.disabled(!canResizeToNative)`, where `canResizeToNative` requires **both** a decoded video frame (`bridge.videoPixelSize != nil`) **and** that the native size fits the current screen (`nativeVideoFitsCurrentScreen()`) — not just "no video decoded yet". No `.help()` tooltip; instead hover opens a `.popover` (`nativeResPopover`) showing resolution (px), display size (pt @ scale), inferred video/audio codec, and — when the stream is too large for the current display — an orange "Too large for current display" warning row. The icon itself glows accent-color with a soft shadow when native is achievable but the window isn't already sized to it (`notAtNative`); otherwise it's `.secondary` (achievable) or `.tertiary` (disabled).
- **Speed up to live / catch-up button** (`forward.end.circle`, `.plain` style, grouped into the buffer-monitor pill above when buffering is enabled, standalone otherwise): for a live channel, calls `VLCBridge.shared.catchUpToLive()` — stops the stream, discards the accumulated buffer, and reconnects at the live edge; the rate controller resets and the fill phase starts over. The poster overlay does **not** re-appear after catch-up (it only shows on a fresh channel switch, not on a same-channel restart). For a recording-relay stream (`bridge.recordingShowId != nil`), calls `AppState.seekRecordingToLiveEdge(showId:)` instead — plain `catchUpToLive()` would just replay the current URL verbatim at the same stale `&start=` offset, so a fresh near-live-edge offset is computed (the same `elapsed - recordingLiveEdgeBackoffSeconds` math `watchRecordingInApp` uses on first open) and reconnected. Tooltip changes accordingly: `"Speed up to live — discard buffer and jump to live edge"` vs. `"Jump to the live edge of the recording"`.
- **Live clock**: `TimelineView(.periodic(from: .now, by: 1.0))` rendering current wall time in monospacedDigit secondary-color text, min 70pt width. Updates every second.
- **Volume section**:
  - `speaker.wave.2` SF Symbol in secondary color (`.accessibilityHidden(true)` — decorative)
  - `Slider(in: 0...100)`, 100pt wide, `.accessibilityLabel("Volume")`
- **Divider** (18pt tall, visible only when audio devices are present)
- **Audio output section** (when `systemDevices` non-empty):
  - `airplayaudio` SF Symbol in secondary color (accessibilityLabel: `"Audio output"`)
  - `Picker` (max 200pt wide) listing all CoreAudio output devices by name — built-in speakers, Bluetooth, AirPlay, USB audio. Selecting routes VLC to that device via `setAudioDevice(output: "auhal", deviceId:)`.
- **Divider** (18pt tall, visible only when 2+ screens available)
- **Screen/display section** (when `availableScreens.count > 1`):
  - `airplayvideo` SF Symbol button (`.menuStyle(.borderlessButton)`, max 24pt wide) — opens a `Menu` listing all `NSScreen.screens` by `localizedName`. Selecting moves the player window to the centre of that screen via `VLCPlayerWindowManager.shared.moveToScreen(_:)`. `moveToScreen` deminiaturizes the window first (otherwise `setFrameOrigin` is silently ignored), then clamps the resulting origin so a window larger than the target screen can't be placed off-screen (e.g. 1080p player on a 720p AirPlay receiver). AirPlay displays appear here once connected via Control Center → Screen Mirroring. Tooltip: `"Move to display"`. Accessibility label: `"Select display"`.
  - Screen list refreshes automatically on `NSApplication.didChangeScreenParametersNotification`.

### Video surface
`VLCVideoSurface: NSViewRepresentable` — a plain `NSView` with `wantsLayer = true` and black `CALayer` background. VLC renders directly into this layer via `VLCBridge.shared.setDrawable(_:)`.

The video surface is wrapped in a `ZStack` with a **poster overlay**, an **error overlay**, and an **ended overlay** sitting on top. The poster is visible when `posterHidden == false && !bridge.hasError && !bridge.hasEnded` and fades out with `.easeOut(duration: 0.35)` when the user clicks **Start**. The poster reappears (by resetting `posterHidden = false`) whenever `selectedChannel` changes. The error overlay (see below) appears on top of both the video and poster when `bridge.hasError == true`, suppressing the poster entirely until the user retries. The ended overlay appears when `bridge.hasEnded == true` (see "Ended Overlay" below), also suppressing the poster.

## Intent

Replaces `PlayerView.swift` (AVKit / `AVPlayer`). AVPlayer cannot decode MPEG-2 transport streams — the native broadcast format from HDHomeRun tuners — and silently failed on any show with `transcode = none`. The VLC-based player decodes MPEG-2 natively, so the user's configured transcode setting is respected without any forced override.

The player opens as a detached `NSWindow` with a SwiftUI toolbar above the video surface. It has a channel picker, volume slider, audio device selector, and a screen/display picker (shown when multiple displays are connected, including AirPlay). The window is reusable — opening it a second time switches the stream rather than creating a new window.

Gate: `VLCBridge.shared.isAvailable` (VLC.app installed anywhere Launch Services can resolve it — see `docs/VLCBridge.md`, not assumed at a fixed path) must be true for "Watch Now!" buttons to appear. No easter egg gate — the player is always accessible when VLC is installed.

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
@AppStorage("vlcVolume") private var volume: Double = 50         // persists across sessions
@State private var systemDevices: [(id: String, name: String)] = []  // CoreAudio output devices
@State private var selectedDevice: String = ""                   // CoreAudio device UID of active output
@State private var availableScreens: [NSScreen] = []                // populated in onAppear — NSScreen.screens is main-thread-only
@State private var posterHidden: Bool = false   // false = show poster overlay; true = live video visible
@State private var posterNSImage: NSImage? = nil // poster fetched via ChannelIconCache for currentGuideEntry
@State private var selectedAudioTrackId: Int32 = -1  // −1 = not yet loaded; set to first track id when audioTracks appears
@State private var selectedSpuTrackId:   Int32 = -1  // −1 = CC off (default)
@State private var spuChoiceIsExplicit:  Bool  = false  // true only after a real Picker tap — see below
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

### currentGuideEntry Computed Property

```swift
private var currentGuideEntry: GuideEntry? {
    guard let ch = selectedChannel else { return nil }
    let now = Date()
    return state.guideEntries(deviceId: device.DeviceID, channelNum: ch.GuideNumber)
        .first { $0.startDate <= now && $0.endDate > now }
}
```

Returns the currently-airing `GuideEntry` for the selected channel. Used by the poster overlay to display title, episode info, synopsis, and to fetch the poster image via `ChannelIconCache`. A `.task(id: currentGuideEntry?.ImageURL)` on the ZStack re-fetches the poster image whenever the on-air entry changes (e.g. top-of-hour handoff).

### onAppear / Channel Sync

`.onAppear` populates `availableScreens = NSScreen.screens` (main-thread-only; unsafe to set as a `@State` default), calls `refreshAudioDevices()` — populates `systemDevices` from `VLCBridge.shared.systemAudioOutputDevices()`, pre-selects the system default via `systemDefaultOutputUID()`, and routes VLC to it immediately with `setAudioDevice(output: "auhal", deviceId:)`. `startDeviceChangeMonitoring` is also started, calling `refreshAudioDevices()` whenever CoreAudio devices change (Bluetooth connect, AirPlay connect, etc.).

`volume` is not read back from VLC on appear because the player is already muted at open time — reading back would return `0`, overwriting the user's saved preference. `@AppStorage("vlcVolume")` preserves the last-used volume across sessions; `setVolume(Int(volume))` in the Start button action restores it at the moment the user dismisses the overlay.

`syncChannel(to:)` strips query params, matches against `lineup`, sets `suppressNextChannelPlay = true`, then sets `selectedChannel`. The `suppressNextChannelPlay` flag prevents the `onChange(of: selectedChannel)` handler from calling `playChannel()` when the selection change was driven by `syncChannel` rather than a user tap — avoiding a redundant second `_mpPlay` call on an already-playing stream.

`state.vlcCurrentURL` is set by `AppState.watchInApp()` before calling `open()`. When the player window is already open and a different "Watch Now!" is clicked, `onChange(of: vlcCurrentURL)` fires inside the running window's SwiftUI tree and syncs the picker to the new channel without reopening the window.

Initial pre-selection strips query parameters from `initialURL` before matching because the URL passed to `open()` may have `?transcode=heavy` appended while `LineupEntry.URL` is the raw base URL. Both `hasPrefix` directions are checked to handle edge cases where one URL is a prefix of the other.

Pre-selection via `syncChannel` only updates `selectedChannel` — it does **not** call `playChannel()`. The stream is already playing (started by `VLCPlayerWindowManager.open()` before the window appears).

### Live recording entries

Lets the channel picker switch directly between simultaneous recordings on this device (via the relay — `docs/WebServer.md`'s `/api/watch-recording`), the same way it switches between live channels — no separate menu needed.

`LineupEntry`'s `Equatable` (`AddShowView.swift`) compares `GuideNumber` **and** `Favorite`; `Hashable` hashes `GuideNumber` alone. Either way, a synthetic row can't reuse the show's real channel number (it would collide with — compare equal to, or at least hash-collide with — that channel's real lineup row). Instead:

- `recordingChannelEntries: [LineupEntry]` — one entry per `state.recordingShows` on this device (`show.hdhr_record == device.DeviceID`), sorted by channel. `GuideNumber` is `"live:{show_id}"` (never collides with a real channel number); `GuideName` holds the full display label, `"Live 5.1  The Closer"` — rendered directly (`Text(entry.GuideName)`) rather than through the `"GuideNumber  GuideName"` template used for real channels, which would show the synthetic tag.
- `showId(fromLiveGuideNumber:)` — strips the `"live:"` prefix; returns `nil` for a real channel's `GuideNumber` or the bare-fallback row.
- Picker row order: bare **"Live"** fallback (`Optional<LineupEntry>.none`, selected only if nothing below matched — keeps the picker from ever rendering blank; hidden when `recordingChannelEntries.isEmpty`, since there's nothing to fall back to) → `recordingChannelEntries` → the device's real channels.
- `onChange(of: selectedChannel)`: `showId(fromLiveGuideNumber:)` non-nil → looks up the `Show` in `state.shows` and calls `AppState.watchRecordingInApp(_:)` (switches the relay stream, no new tuner); otherwise → `playChannel()` as before (live device channel, new tuner).
- `syncChannel(to:)` checks `bridge.recordingShowId` first (via `recordingChannelEntries`) before falling back to the lineup-URL match, so a relay URL pre-selects the matching "Live 5.1  Title" row instead of falling through to "no match in lineup." Also updates `MPNowPlayingInfoCenter` with the show's title and `"Live"` as artist (not the synthetic `GuideNumber`).
- `.onChange(of: bridge.recordingShowId)` re-runs `syncChannel(to: bridge.currentURL)` once it becomes non-nil — needed because `AppState.watchRecordingInApp(_:)` defers setting it to the next run-loop turn (a SwiftUI render-timing fix — see `docs/AppState.md`), so the very first `syncChannel` call from `.onAppear` (same synchronous window-open transaction) can run before it lands.

### Toolbar Layout

```
[Channel picker ─────────] Spacer [buffer|⏭ pill] [1:1] [🕐] [🔊] [─── slider ───] | [🎧 audio track] | [CC picker] | [♩ audio device] | [📺 screen menu]
```

`[🕐]` is the live wall-clock `TimelineView` — always shown here, unconditionally, for every stream including a recording-relay session. The recording scrub bar does **not** live in the toolbar (see "Recording scrub overlay" below); it's a hover overlay on the video instead — the toolbar had no room to spare for it alongside everything else.

- **Channel picker**: `.labelsHidden()`, max width 220 pt, tags use `Optional(ch)` to match the `LineupEntry?` binding. See "Live recording entries" below for the "Live" fallback row and per-recording rows shown above the real channel list.
- **Buffer monitor + catch-up pill**: visible only when `bufferInfo.enabled` (i.e. `minRate < 1.0`) — never true for a recording-relay session (see below), so only `catchUpButton` shows there, standalone with no pill. When shown, the buffer monitor and catch-up button share one pill background with a hairline divider, positioned before the native-resolution button.
- **Native resolution button** (`aspectratio`): calls `sizeToNativeVideo()`, disabled unless a frame has decoded and the native size fits the current screen; hover shows a popover with resolution/codec detail (see "Visual Appearance" above for the full breakdown)
- **Catch Up button** (`forward.end.circle`): live-channel vs. recording-relay behavior and tooltip differ — see "Visual Appearance" above for the full breakdown.
- **Clock**: live wall-clock `TimelineView`, monospaced — unconditional, same for every stream
- **Volume**: speaker icon + `Slider(value:in:0...100)`. `onChange` maps to `VLCBridge.shared.setVolume(Int(v))`.
- **Audio track picker** (when `bridge.audioTracks.count > 1`): `headphones` SF Symbol + `Picker` (max 150 pt). Shows all audio tracks returned by `libvlc_audio_get_track_description` with `id ≥ 0`. Appears ~3 s after playback starts (first `tickController` tick after `isPlaying`). Defaults to the first track (already active in VLC). `onChange` calls `VLCBridge.shared.setAudioTrack(id:)`. Reset to unloaded (id = −1) on every channel switch.
- **CC picker** (when `!bridge.spuTracks.isEmpty` **and** `bridge.recordingShowId == nil`): `captions.bubble` SF Symbol + `Picker` (max 130 pt). First row is always "Off" (tag `Int32(-1)`); remaining rows are CC tracks from `libvlc_video_get_spu_description` with `id ≥ 0`. Icon highlights (`.primary`) when a CC track is active. `onChange` calls `VLCBridge.shared.setSpuTrack(id:)`. Reset on channel switch. Hidden entirely during a recording-relay session — switching SPU tracks while reading the relay's on-disk file back doesn't produce a visible result, so the picker would look like it does something without actually working.
  - **Default/auto-enable behavior**: defaults to Off, and some streams auto-enable CC on their own so `setSpuTrack(id: -1)` is called explicitly when `spuTracks` first loads (`onChange(of: bridge.spuTracks.count)`) — *unless* the volume is at 0 at that moment (and this isn't a relay session), in which case the first available CC track is auto-selected instead, since there's no audio to convey what's being said otherwise. The same auto-enable also fires on a rising edge into muted mid-playback (`onChange(of: volume)`, `oldValue > 0 && newValue == 0`) if tracks were already known — skipped if the user already made an explicit selection, tracked by `spuChoiceIsExplicit` (even "Off" chosen on purpose) so it doesn't fight a deliberate choice. `-1` alone can't distinguish "user picked Off" from "no choice made yet" (it's both the Picker's own "Off" tag and the reset sentinel), which is exactly what `spuChoiceIsExplicit` exists to disambiguate — fixed 2026-08-15 (pre-release review caught that a real Picker tap of "Off" got silently overridden by the next mute). Only the Picker's own binding (a wrapped `Binding(get:set:)`, not `$selectedSpuTrackId` directly) sets it `true`; every programmatic reset of `selectedSpuTrackId` (channel load, channel switch) resets it back to `false` too, so a new channel always gets a fresh auto-enable decision rather than inheriting the previous channel's explicit choice forever.
  - **Auto-disable on unmute**: the same `onChange(of: volume)` handler also covers the falling edge out of muted (`oldValue == 0 && newValue > 0`) — if CC is still on and the user never made an explicit choice while muted (`!spuChoiceIsExplicit`), it's turned back off (`setSpuTrack(id: -1)`) now that there's audio again. A real Picker pick during the muted stretch — including re-picking the same track "on" — sets `spuChoiceIsExplicit` and survives unmuting; only the mute-triggered auto-enable gets auto-reverted. Added 2026-08-17 — previously CC stayed on indefinitely after unmuting even without an explicit pick.
- **Audio device picker**: shown when `!systemDevices.isEmpty`. Lists all CoreAudio output devices (built-in, Bluetooth, AirPlay audio, USB). `onChange` calls `setAudioDevice(output: "auhal", deviceId:)`.
- **Screen menu**: shown when `availableScreens.count > 1`. `airplayvideo` icon button opens a `Menu` of `NSScreen.localizedName` entries. Selecting calls `VLCPlayerWindowManager.shared.moveToScreen(_:)` to centre the window on that display. AirPlay video displays appear here once connected via Control Center → Screen Mirroring.

`VLCBridge.shared.liveMinRate` is set from `state.config.Player_buffer_min_rate / 100.0` in `.onAppear`, `.onChange(of: state.config.Player_buffer_min_rate)`, and in `VLCPlayerWindowManager.open()` before `play()` so the rate is correct for window-open channel switches. `liveMinRate` is only the *configured* floor — `VLCBridge.play(url:)` decides the floor actually in effect (`minRate`): `liveMinRate` for a normal stream, forced to `1.0` for the recording relay (see `docs/VLCBridge.md`).

### Recording scrub overlay

Shown as a bottom-aligned hover overlay directly on the video (in `body`'s `ZStack`, alongside `posterOverlay`/`errorOverlay`) — not in the toolbar. Standard video-player convention (like a hover-to-reveal transport bar), chosen over a toolbar control because there's no library-provided equivalent available here: `AVPlayerView` gives this for free but requires an `AVPlayer` as the decoder, which can't play MPEG-2 (the reason this app uses VLC at all — see `docs/VLCBridge.md`); the actual VLCKit framework has no built-in transport chrome either, so apps built on it (e.g. IINA) all hand-roll their own, same as here.

- **Presence**: `posterHidden && !bridge.hasError && bridge.recordingShowId != nil && bridge.recordingStartDate != nil` gates whether the overlay exists in the view tree at all — `.transition(.opacity)` + `.animation(_:value: bridge.recordingShowId)` on the parent `ZStack` gives it a quick fade in/out as a recording-relay session starts or ends (e.g. switching to a live channel). `bridge.recordingShowId`/`recordingStartDate` are set by `AppState.watchRecordingInApp(_:)` when Watch Now! is used on an actively-recording show (see `docs/WebServer.md`'s `/api/watch-recording` relay) — this overlay never appears for a plain live channel.
- **Hover-to-reveal**: `@State videoControlsHovered`, set by `.onHover` attached directly to the bar's own padded/background region (not the whole video `ZStack`) — only hovering over the bar itself (plus its 20pt outer margin) reveals it, not anywhere on the video. `.opacity(videoControlsHovered ? 1 : 0)` + `.animation(.easeInOut(duration: 0.2), value: videoControlsHovered)` drives the quick fade. No `.allowsHitTesting` gating: a view at zero opacity can still be hovered into (that's what lets it reveal itself in the first place) — hit-testing is only meaningfully disabled by `.allowsHitTesting(false)`, which this doesn't use.
- **Content** (`recordingScrubBar(showId:startDate:)`, `.ultraThinMaterial` rounded-rect background): a current-position label above the slider (`startDate + display`, as a local clock time via `Text(_:style:.time)`), then a row of `[recording-start clock time] Slider [live/now clock time]`. Labels use local time-of-day rather than elapsed duration — "started at 7:00 PM" reads more naturally than "0:00" for a recording.
- **Position tracking**: all inside a 1s `TimelineView` tick. Position is estimated from wall-clock time via `VLCBridge.recordingPlaybackSeconds` (seek base + time since last reconnect) — the raw file has no index, so this is not a real libvlc time-based seek. Dragging sets local `@State isScrubbing`/`scrubValue` (so the 1s tick doesn't fight the user's finger); releasing calls `AppState.seekRecording(showId:toSeconds:)`, which estimates a byte offset from (file size / elapsed recording time) and reconnects the relay URL with `&start={offset}` — a new connection, not an in-place seek, so there's a brief rebuffer on each scrub commit.

### playChannel

```swift
private func playChannel(_ ch: LineupEntry) {
    guard let rawURL = ch.URL, !rawURL.isEmpty else { return }
    let url = state.config.applyTranscode(rawURL)   // "none"/empty → raw; otherwise appends ?transcode=…

    // Buffer immediately — stream starts the moment the poster appears.
    VLCBridge.shared.play(url: url)
    updateNowPlaying(channel: ch)

    // Tuner check runs in background after play() so it never delays buffering.
    Task { /* fetch status.json, log active/total, warn if over capacity */ }
}
```

Uses `AppConfig.applyTranscode(_:override:)` — applies `Default_transcode` without a per-show override (the picker is device/lineup-level, not show-level). When transcode is `"none"` or empty the raw stream URL is used; VLC decodes MPEG-2 natively.

**Immediate buffering**: `play()` is called synchronously, before the background Task that checks tuner occupancy. The poster overlay is visible from the moment the channel changes, so every millisecond of poster time is also buffer-build time. By the time the user reads the episode info and clicks Start, the stream has been filling at `minRate` since the picker change.

**Now Watching sync**: `VLCBridge.play(url:)` sets `currentURL` synchronously (drawable already exists for an open window). The Combine sink in `AppState` picks this up immediately and updates `vlcCurrentURL` — no manual assignment needed in `playChannel`.

**Background tuner check**: after `play()` returns, a `Task` fetches `status.json` and logs `[VLC] post-switch tuner status ch X.X: N/M active (ours=N other=N)`. If all non-VLC slots appear occupied it logs a warning. No alert is shown — the stream is already running and the HDHR may succeed regardless.

**Tuner occupancy refresh**: `state.refreshTunerOccupancy()` is called after every channel switch so the menu header reflects the new tuner state within ~1.5 s.

**Start button — gated on `isPlaying`**: the Start button is disabled and shows a spinner + "Connecting…" until `VLCBridge.shared.isPlaying` becomes `true` (first `libvlc_Playing` state confirmation, ~3 s after stream open). Once enabled it shows the normal play icon + "Start". This prevents the user from unmuting before any data has arrived.

**Start button log**: the Start button (which dismisses the poster overlay) logs `[VLC] Start clicked — buffer ~X.Xs built before unmute`, showing exactly how much buffer headroom accumulated during the poster phase.

### onAppear / onDisappear

`onAppear` logs `[VLC] VLCPlayerView.onAppear device=… initialURL=…`, sets up the rate controller, audio devices, media-key remote commands, and calls `syncChannel`.

`onDisappear` logs `[VLC] VLCPlayerView.onDisappear`, then calls `VLCBridge.shared.releasePlayer()` — full teardown: stops the stream, releases the media object, releases and nils the media player, and frees the tuner immediately — and `VLCBridge.shared.stopDeviceChangeMonitoring()`, clears `MPNowPlayingInfoCenter.default().nowPlayingInfo` and sets its `playbackState` to `.stopped`, and removes the stop/next-track/previous-track targets from `MPRemoteCommandCenter.shared()`. This is a safety net; `playerWindowDidClose()` normally fires first via the window delegate and does the same teardown (plus more — see below). `releasePlayer()` is idempotent so calling it twice is harmless.

**Remote stop command**: the Now Playing / media-key Stop command calls `VLCBridge.stop()`. This used to clear `drawableView = nil`, leaving every subsequent `play()` queued as pending forever (the SwiftUI view stays alive so `makeNSView` never re-fires) — the window went black until closed and reopened. Fixed: `stopAndClearState()` now deliberately leaves `drawableView` attached, so a subsequent `play()` finds a live surface to render into. Only `releasePlayer()` (full teardown, window close) nils it. Logged as `[VLC] remote stopCommand received` immediately before `[VLC] stop called — drawable=had view`.

**Media-key next/prev-track**: `.onReceive(.vlcChannelNext/.vlcChannelPrev)` cycles `selectedChannel` through `channelCycleOrder` (`recordingChannelEntries + lineup` — the same order the picker itself lists rows in), not `lineup` alone — otherwise pressing next/prev while `selectedChannel` is one of the synthetic "Live" recording rows would find no match in `lineup` and silently no-op.

---

## Poster Overlay

When the player opens or changes channel, a full-area `posterOverlay` view sits on top of `VLCVideoSurface`. It displays the currently-airing show's poster image, title, episode number + title, and synopsis. A **Start** button at the bottom-left of the info column dismisses the overlay with a 0.35s fade, revealing the live video underneath.

**Why**: VLC begins buffering the stream immediately when `open()` is called (before the window appears). By the time the user reads the episode info and clicks Start, VLC has had several seconds to buffer — the stream plays instantly rather than showing a spinner.

**Poster reappears** on channel change: `onChange(of: selectedChannel)` resets `posterHidden = false`, `posterNSImage = nil`, and calls `setVolume(0)` before calling `playChannel()`, so the new stream buffers silently behind the overlay until Start is clicked.

### Error Overlay (`errorOverlay`)

When `VLCBridge.shared.hasError` is `true` (set when `libvlc_media_player_get_state` returns 7 = `libvlc_Error`), the `errorOverlay` appears on top of both the video surface and the poster overlay.

```
ZStack (black 85% opacity, fills video area)
  VStack (spacing 16)
    exclamationmark.triangle.fill SF Symbol (44pt, orange)
    "Stream Unavailable" (.title2.bold, white)
    host URL string (.callout, white 50% opacity) — e.g. "hdhr-105404be.local"
    Retry button
      — Label("Retry", systemImage: "arrow.clockwise"), .callout.bold
      — .ultraThinMaterial background, RoundedRectangle(8pt)
      — sets posterHidden = false, calls VLCBridge.shared.catchUpToLive()
```

The overlay appears within ~3 seconds of a stream failure (one rate-controller tick). It suppresses the poster (condition `!bridge.hasError` on the poster's `if`) so the user always sees the error rather than a confusing "Start" button that would do nothing.

Clicking **Retry** resets `posterHidden = false` (returns to poster state so the buffer can rebuild) and calls `catchUpToLive()`, which calls `play(url: currentURL)` — resetting `hasError = false` and starting the fill phase again.

### Ended Overlay (`endedOverlay`)

When `VLCBridge.shared.hasEnded` is `true` (state 6 = `libvlc_Ended`, e.g. a recording-relay file reaching EOF), the `endedOverlay` appears on top of both the video surface and the poster overlay, suppressing the poster.

```
ZStack (black 85% opacity, fills video area)
  VStack (spacing 16)
    stop.circle SF Symbol (44pt, white 80% opacity)
    "Playback Ended" (.title2.bold, white)
    Play Again button (shown only if bridge.currentURL is non-nil)
      — Label("Play Again", systemImage: "arrow.clockwise"), .callout.bold
      — .ultraThinMaterial background, RoundedRectangle(8pt)
      — sets posterHidden = false, calls bridge.play(url: currentURL)
```

### Layout (`posterOverlay`)

```
ZStack (black background, fills video area)
  HStack (32pt padding, centered vertically)
    Poster image (30% of video-area width, `.containerRelativeFrame(.horizontal) { w, _ in w * 0.30 }`, clipShape RoundedRectangle 8pt)
      — Image(nsImage: posterNSImage) .resizable().scaledToFit(), or tv SF Symbol placeholder at 25% white
      — scales with player window resize; at default 960pt window ≈ 288pt wide
    VStack (max 360pt, leading alignment)
      Title (.title2.bold, white, 2 lines max)
      Episode info (.subheadline, white 75% opacity)
        — switches on (EpisodeNumber?, EpisodeTitle?) to handle 4 cases
      Synopsis (.callout, white 60% opacity, 4 lines max)
      Start button
        — Label("Start", systemImage: "play.fill"), .title3.bold
        — .ultraThinMaterial background, RoundedRectangle(10pt)
        — sets posterHidden = true and calls setVolume(Int(volume)) on tap
```

### Poster image loading

`.task(id: currentGuideEntry?.ImageURL)` on the ZStack body runs whenever the on-air entry's poster URL changes. It calls `ChannelIconCache.shared.image(for: url)` — the same disk-backed actor cache used by channel logos. `posterNSImage` is set to `nil` first (showing the placeholder) until the async fetch returns.

**Why `ChannelIconCache` and not `AsyncImage`**: `AsyncImage` has no way to prevent redundant fetches or persist images across view invalidations. The cache avoids re-downloading the same poster on every channel-picker re-evaluation and makes the overlay feel instant when switching back to a previously-seen channel.

---

## VLCPlayerWindowManager

```swift
@MainActor
final class VLCPlayerWindowManager {
    static let shared = VLCPlayerWindowManager()
    private var window: NSWindow?
    private weak var appState: AppState?   // stored so playerWindowDidClose can clear vlcCurrentURL

    func focus() {
        guard let win = window else { return }
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    func open(url: String, title: String, device: HDHRDevice, appState: AppState, channelNumber: String? = nil) {
        self.appState = appState
        VLCBridge.shared.setVolume(0)            // mute before buffering starts; Start click unmutes
        VLCBridge.shared.ensurePlayer()          // recreate mediaPlayer if releasePlayer() was called on last close
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

**`focus()`**: brings the player window to the front without switching the stream. Called from the "Now Watching" button in `MenuContent` (via `DispatchQueue.main.async` to defer past NSMenu teardown). No-op when `window` is nil.

**`closeIfPlaying(showId: String, url: String)`**: closes the player window if it's playing the given show — either its raw tuner stream URL (`VLCBridge.shared.currentURL?.urlBase == url`) or, for Watch Now! relay playback, `VLCBridge.shared.recordingShowId == showId` (the relay plays a local `/api/watch-recording` URL that never equals `show_url`, so the URL check alone would miss it). Called from `AppState.deleteShow` and `AppState.skipRecording` immediately after `recordingManager.stop()` — if the user is watching the same show they just deleted/skipped (live or via relay), the VLC window tears down cleanly and the tuner is freed. No-op when neither matches or no window is open. Triggers `windowWillClose → playerWindowDidClose → VLCBridge.releasePlayer()`. (Renamed from `closeIfPlayingURL(_:)`; the relay-match branch is new.)

**`playerWindowDidClose()`**: called by `WindowCloseObserver.windowWillClose`. Calls `VLCBridge.shared.stopDeviceChangeMonitoring()` first — `windowWillClose` fires before `onDisappear`, so without this the CoreAudio device-change listener would fire callbacks into a partially torn-down view. Then calls `VLCBridge.shared.releasePlayer()` (full teardown — releases `mediaPlayer` so the tuner is freed immediately; also nils `currentURL`, which triggers the Combine chain in `AppState` to clear `vlcCurrentURL` automatically), clears `currentDeviceID`, sets `window = nil`, releases the VLC sleep assertion immediately via `appState?.recordingManager.releaseAssertion(id: "vlc")` (rather than waiting for `refreshTunerOccupancy()`'s own `releaseAllAssertions()`, which is blocked while a recording is simultaneously active), calls `appState?.releaseRecordingRelayIfNeeded()`, and calls `appState?.refreshTunerOccupancy()` so the menu header reflects the freed tuner within ~1.5 s. No explicit `vlcCurrentURL = ""` needed — the Combine sink handles it. The `appState` weak reference is set in `open()` and persists for the window lifetime.

### Singleton NSWindow with isReleasedWhenClosed = false

```swift
win.isReleasedWhenClosed = false
```

By default, macOS releases (deallocates) an `NSWindow` when it is closed. For a reusable player window, this is wrong — closing the window should merely hide it. `isReleasedWhenClosed = false` keeps the window object alive in `self.window` so the next `open()` call can bring it forward without recreating the hosting view, the SwiftUI state, or the VLC drawable attachment.

Without this, the second `open()` call would create a new window with a new `NSHostingView`, triggering `VLCVideoSurface.makeNSView` again — which would call `setDrawable` again and interrupt any stream that was resumed before the window appeared.

### Stream-First Design

`VLCBridge.shared.setVolume(0)` is called in `open()` **before** `play()`, so the stream always starts muted regardless of how the window was opened (first open or channel switch via an external "Watch Now!" click). The Start button inside the running window then calls `setVolume(Int(volume))` to restore audio.

`VLCBridge.shared.play(url: url)` is called **before** any window logic. This means:
- The stream starts immediately on first open, before the window appears
- On re-open while the window is already visible, the stream switches immediately without waiting for UI interactions
- The channel picker's initial selection (set in `.onAppear`) reflects what is already playing, not what triggers play

### Window Size

960×600 pt. Resizable, titled, closable, miniaturizable. The 960 wide minimum gives the toolbar enough room to show all pickers without truncation at typical VLC stream resolutions.

---

## AppState.watchInApp

```swift
func watchInApp(url: String, title: String, deviceId: String? = nil, transcode: String? = nil, guideNumber: String? = nil) {
    guard VLCBridge.shared.isAvailable else { return }
    let device = devices.first { $0.DeviceID == (deviceId ?? "") } ?? devices.first
    guard let device else { return }
    guard !url.isEmpty else { /* NSAlert "No Stream URL"; return */ }
    let streamURL = config.applyTranscode(url, override: transcode)
    let mgr = VLCPlayerWindowManager.shared

    Task {
        // Already playing this exact channel on this device? Just focus the window.
        if isAlreadyPlaying() { mgr.focus(); return }
        // Switching channels within an already-open player on this device skips the
        // tuner check (reuses the same slot) — only a device switch needs one.
        if mgr.currentDeviceID != device.DeviceID {
            await fetchDeviceStatus(for: device)
            if tunersFull(for: device.DeviceID) { alertTunerFull(...); return }
        }
        // Re-check after the await — a second concurrent call (e.g. a double-click)
        // could have already opened the player while this one was suspended.
        if isAlreadyPlaying() { mgr.focus(); return }
        mgr.open(url: streamURL, title: title, device: device, appState: self, channelNumber: guideNumber)
        refreshTunerOccupancy()
    }
}
```

**Tuner availability check**: switching channels within an already-open player on the *same* device skips the check entirely (reuses the existing slot). Opening on a *different* device first awaits a fresh `fetchDeviceStatus(for:)` poll, then checks `tunersFull(for:)` — the same `max(hardware-polled count, recordingShows + in-app VLC stream)` logic documented in `docs/AppState.md`'s Invariants, not a raw `VctNumber` scan of `status.json`. If full, shows an NSAlert (`alertTunerFull`) explaining why the player can't open.

**Empty-URL guard**: a missing/empty lineup URL passed straight to libvlc can leave the player stuck on "Connecting…" forever with no error surfaced — `watchInApp` catches this upfront with its own NSAlert ("No Stream URL") before opening the window at all.

**Already-playing dedup**: `isAlreadyPlaying()` (`mgr.currentDeviceID == device.DeviceID && VLCBridge.shared.currentURL?.urlBase == url.urlBase`) is checked both before and after the tuner-status `await` — re-opening the same channel from Watch Now while it's already playing would otherwise call `mgr.open()` a second time, muting an already-playing stream with no recovery UI. On a match, it just calls `mgr.focus()` instead of restarting the stream.

`vlcCurrentURL` is no longer set manually here. `open()` calls `VLCBridge.play()`, which sets `currentURL` on the bridge; the Combine sink in `AppState` maps that through `.urlBase` and updates `vlcCurrentURL` automatically. `onChange(of: state.vlcCurrentURL)` in a running `VLCPlayerView` fires and syncs the channel picker.

`deviceId`/`guideNumber` call sites:
- `WatchNowView`: passes `device.DeviceID`/the channel's `GuideNumber`

Falls back to `devices.first` if no `deviceId` match.

## VLCPlayerWindowManager.currentDeviceID

```swift
private(set) var currentDeviceID: String?
```

Set to `device.DeviceID` in `open()`, cleared to `nil` in `playerWindowDidClose()`. Read by `watchInApp` to skip the tuner availability check when the player already occupies a slot on the target device (channel switching should always be allowed without a free-tuner check).

`playerWindowDidClose()` calls `releasePlayer()`, which nils `VLCBridge.currentURL`; the Combine chain in `AppState` picks this up and clears `vlcCurrentURL` — the "Now Watching" indicator disappears without any explicit assignment in the close path.

---

## Logging Reference

All VLC log lines are prefixed `[VLC]` and written via `glog()` to the unified logging system (OSLog subsystem `com.hdhr.vcrplus`). View live with:
```
log stream --level debug --predicate 'subsystem == "com.hdhr.vcrplus"'
```
Or open Console.app → use Settings → Advanced → Logging → "Show App Log in Console".

| Log line | When it fires |
|---|---|
| `VLCVideoSurface.makeNSView — new drawable view=…` | SwiftUI creates the NSView VLC renders into |
| `setDrawable view=… mp=ready/nil pending=yes/no` | Drawable attached; shows whether mediaPlayer is ready and whether a pending URL is queued |
| `setDrawable firing pending play: …` | Drawable set while a URL was queued — plays immediately |
| `play url=…` | Normal play/switch; stream starts |
| `play deferred — no drawable yet` ⚠ | Drawable is nil (VLC not yet attached to a view); URL queued as pending. **Primary black-screen precursor.** |
| `play deferred — vlcInstance=nil / mediaPlayer=nil` ⚠ | VLC library not yet initialised; URL queued as pending |
| `WARNING: libvlc_media_player_play returned N` ⚠ | libvlc rejected the play call |
| `stop called — drawable=had view/already nil currentURL=…` | stop() called; tracks whether drawable was still live |
| `remote stopCommand received` ⚠ | Media key or Now Playing widget Stop pressed — **calls stop(), clears drawable, causes black screen** |
| `catchUpToLive — reconnecting to: …` | Manual or auto catch-up triggered |
| `VLCPlayerView.onAppear device=… initialURL=…` | Player view appeared (window opened or SwiftUI re-mount) |
| `VLCPlayerView.onDisappear` | Window closed; stop() about to be called |
| `vlcCurrentURL changed → syncChannel: …` | watchInApp or playChannel updated vlcCurrentURL |
| `syncChannel matched X.X ChName for url=…` | Channel picker pre-selected to match the playing URL |
| `syncChannel no match in N-entry lineup for url=…` ⚠ | No lineup entry matches the URL — picker may be wrong |
| `playChannel X.X ChName → url` | User changed the channel picker; stream switching |
| `Start clicked — buffer ~X.Xs built before unmute` | User dismissed poster overlay; shows buffer depth at that moment |
| `stream playing confirmed` | `libvlc_Playing` (state 3) detected on first tick — Start button enabled |
| `stream error state — publishing hasError` ⚠ | `libvlc_Error` (state 7) detected — error overlay shown |
| `post-switch tuner status ch X.X: N/M active (ours=N other=N)` | Post-switch status.json check result |
| `WARNING: all N tuner(s) appear occupied` ⚠ | Other streams hold all slots after the switch |
| `WindowManager.open — reusing existing window` | Channel switch on an already-open player |
| `WindowManager.open — creating new window, device=… url=…` | First open; NSWindow being created |
| `WindowManager.playerWindowDidClose` | Window closed; VLCBridge.stop() about to fire |

**Black screen diagnosis sequence** — look for this pattern to confirm the remote-Stop cause:
```
[VLC] remote stopCommand received
[VLC] stop called — drawable=had view currentURL=http://…
[VLC] play deferred — no drawable yet, queuing as pending: http://…
```

---

## What Replaced What

| Old (PlayerView.swift) | New |
|---|---|
| `PlayerWindowManager` (AVKit) | `VLCPlayerWindowManager` + `VLCBridge` |
| `AVPlayer` + `AVPlayerView` | `VLCVideoSurface` (NSView drawable) |
| Forced `transcode=heavy` for all streams | Respects show/default transcode; "none" = raw stream |
| No channel picker | Channel picker for current device's lineup |
| No audio output control | CoreAudio device picker + screen/AirPlay display selector |
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
