# VLCPlayerView.swift — VLC In-App Player Window

## Visual Appearance

### Overall window
`NSWindow` created by `VLCPlayerWindowManager`. Initial size **1080×600** (widened from 960×600 on 2026-08-21 for the toolbar's new text labels — see "Toolbar" below), resizable and closable. Title = the show/channel name passed at open time. Centers on first open; re-uses same position on subsequent opens (not re-centered). Opts into native macOS fullscreen (`.fullScreenPrimary` collection behavior) — see "Fullscreen and keyboard shortcuts" below.

### Layout
`VStack(spacing: 0)`:
1. **Toolbar** (~42pt tall, `windowBackgroundColor` background)
2. **Video surface** (fills all remaining space, black background)

### Toolbar
`HStack(spacing: 10)`, 12pt horizontal and 8pt vertical padding:

- **Channel picker** (left, max 220pt wide): standard `Picker` popup. Three row groups, in order: (1) a bare **"Live"** fallback row, tagged `Optional<LineupEntry>.none` — selected only if `selectedChannel` is nil and nothing else below matched, so the picker never renders blank; hidden entirely when nothing on this device is recording (`recordingChannelEntries.isEmpty`), since there's no "Live" to fall back to then; (2) one **"Live 5.1  Show Title"** row per show currently recording on this device (`recordingChannelEntries` — see below); (3) the device's real channels, split into a `Section("★ Favorites")` (`favoriteLineup`) followed by the rest (`otherLineup`) when any favorites exist — matching `WatchNowView`/the web guide's favorites-first pattern — each row `"5.1  NBC"` channel number + name. Hidden label. `onChange(of: selectedChannel)` routes: a `recordingChannelEntries` tag → `AppState.watchRecordingInApp(_:)` (switch to that recording's relay stream, no new tuner); anything else → `playChannel()` (live device channel, new tuner).
- **Quick-record button** (`Label("Record", systemImage: "record.circle")`, `.plain` style, red — labeled 2026-08-21, previously icon-only), a `quickRecordMenu` (`GuideViewHelpers.swift`) pulldown of the four `ShowState` types, same one `WatchNowRow`'s Record button uses — see `docs/WatchNowView.md`'s Action row entry for the shared implementation. Hidden when: watching a recording-relay stream already (`bridge.recordingShowId != nil` — it's already being captured), nothing's currently airing on the selected channel (`currentGuideEntry == nil`), this exact channel already has an active managed show (a direct `state.shows` filter on `hdhr_record`+`show_channel`, not a full `ManagedGuideMatcher` — a `seriesAll` show that's merely following this series from another channel won't suppress the button, a deliberately simple check rather than the fuller one `WatchNowView`'s ring-state logic uses), or the current entry is paid programming (`entry.isInfomercial`, checked inside `quickRecordMenu` itself — see `docs/WatchNowView.md`'s Record bullet). Picking a type calls `state.tunersFull(for:)` first; if full, one of two things happens: if the sole blocker is *this instance's own live Watch Now stream* on the same device (`AppState.tunerBlockedOnlyByOwnWatchNow(for:)`), a `"Stop Watching & Record?"` `.confirmationDialog` offers to drop it and record instead (`yieldWatchNowConfirm` state, `state.startYieldingWatchNowToRecord(...)` on confirm — a tracked-`Task` wrapper, added 2026-09-11, not a raw `Task { await ... }`, so `playerWindowDidClose()` (see below) can cancel the wait if the window closes mid-flow — see "Yield-to-record progress overlay" below); otherwise the same "All Tuners Busy" alert `WatchNowRow` shows (`showTunerFullAlert` state + `.alert` on `body`).
- **Spacer**
- **Buffer monitor + catch-up pill** (visible only when buffering is enabled, i.e. `minRate < 1.0`): `waveform` SF Symbol (`.accessibilityHidden(true)`) + 50pt fill-bar capsule, grouped with the catch-up button into one pill (`.secondary.opacity(0.08)` background, hairline `Divider` between them) — both relate to live-stream temporal state. Bar fill = `estimatedLagSec / 8s`; blue while filling, green when ≥ 87.5% full (≥ 7s). Hover → popover showing lag, rate, bitrate (kB/s from `f_demux_bitrate`), and cumulative corruption count. Driven by `@Published VLCBridge.bufferInfo` (updated every 3s by the rate controller tick). Published unconditionally so the bar appears even when `_mpGetStats` is unavailable (VLC 4+). Accessibility: collapsed to a single element — `.accessibilityLabel("Live buffer")`, `.accessibilityValue("N of 8 seconds")` using whole seconds to avoid flooding VoiceOver with fine-grained changes on each 3-second tick. Never shown for a recording-relay session — `play(url:)` forces `minRate = 1.0` there (see `docs/VLCBridge.md`), since a local loopback file read has no network jitter to buffer against; only `catchUpButton(showLabel: true)` (standalone, no pill) is shown then. The catch-up button *inside* this pill stays icon-only (`showLabel: false`) — no room for text at this width, and the pill's own hover popover already covers detail.
- **Native resolution button** (`Label("Native", systemImage: "aspectratio")`, `.plain` style — labeled 2026-08-21): calls `VLCPlayerWindowManager.shared.sizeToNativeVideo()` — reads the stream's pixel dimensions via `libvlc_video_get_size`, divides by the screen's backing scale factor to get logical points, adds 44pt for the toolbar, and resizes the window with `setContentSize` + `center()`. `.disabled(!canResizeToNative)`, where `canResizeToNative` requires **both** a decoded video frame (`bridge.videoPixelSize != nil`) **and** that the native size fits the current screen (`nativeVideoFitsCurrentScreen()`) — not just "no video decoded yet". No `.help()` tooltip; instead hover opens a `.popover` (`nativeResPopover`) showing a network-vs-disk source indicator (see below), resolution (px), display size (pt @ scale), inferred video/audio codec, and — when the stream is too large for the current display — an orange "Too large for current display" warning row. **Icon color, added 2026-09-11, three-way as of 2026-09-13**: doubles as a source indicator via `nativeIconSourceColor` — `.purple` for the local recording relay (`bridge.recordingShowId != nil`), `.indigo` for a remote FEED session (`device.isVirtualRelay`), else `.blue` for a live network tuner stream — replaces the plain accent-color glow this icon used to have. Full-saturation + soft shadow when native is achievable but the window isn't already sized to it (`notAtNative`); dimmed to 55% of the same hue once already at native; `.tertiary` (gray, hue dropped entirely) when disabled. The popover's own top row repeats this as a small colored dot + a label, shown even before a frame has decoded (unlike the resolution/codec rows below it, which need `bridge.videoPixelSize`): "Live network stream" / "Local recording (disk)" / and, for FEED, `"Network → Disk (FEED from <hostname>)"` (the hostname from `currentFeedEntry?.virtualRelaySourceHostname`, the same `/lineup.json` extra `MenuContent`'s "Watching FEED from <hostname>" row uses, omitted if somehow unknown) — added 2026-09-13 since "Live network stream" was technically true but misleading for FEED: the data arrives over the network like a live tuner, but what's actually on the other end is the *source* Mac's own recording being read off *its* disk, not a live broadcast. **"On disk" row, added 2026-09-12**: for the local-recording-relay case only, a plain stat of the recording file's current size (`VLCPlayerView.recordingSizeText`, `FileManager.attributesOfItem`) — deliberately a one-shot snapshot recomputed only when the popover reopens, not a tracked/ticking value like the buffer-monitor pill's `lagSec` above; requested specifically as something that doesn't need continuous updates. Not shown for FEED — there's no local file to stat (the in-memory proxy has no disk copy) and no live size feed from the remote Mac's own recording exposed today.
- **`inferredCodecs`, corrected 2026-09-13** — the popover's video/audio codec row used to guess purely from whether the currently-playing URL contained `&transcode=` (and whether it was literally `=auto`, this app's own software-transcode marker), defaulting to `"MPEG-2"`/`"AC-3"` otherwise. That default is wrong for a raw FEED relay (or local Watch Now) of a recording that was captured with a real hardware transcode profile (`show_transcode`) — a raw passthrough request never carries `&transcode=` at all, so the popover showed "MPEG-2" for a recording that's genuinely H.264. Now: for a FEED session, reads `currentFeedEntry?.VideoCodec` directly (published by the source Mac via `Show.effectiveVideoCodec`, see `docs/VirtualTunerService.md`, which already accounts for the recording's own transcode profile, not just the channel's raw broadcast codec); for local Watch Now, computes the same `Show.effectiveVideoCodec` locally (show and device are both already known); only a live channel (no relay of any kind) still uses the URL-based heuristic, since that's genuinely the only remaining producer of a `&transcode=` param. Audio also corrected from a previously-unverified `"AAC"` guess for the hardware-profile case to `"AC-3"` — confirmed live via `ffprobe` against a real "heavy" recording (MPEG-TS container, H.264 High profile video, AC-3 2ch/48kHz audio); every real transcode path this app can produce, hardware or its own software one, turns out to use AC-3.
  **Second gap found and fixed same day**: the FEED branch above still missed one case — `currentFeedEntry?.VideoCodec` reflects the *source recording's own* codec, not what the viewer is actually watching right now. Once the viewer's own H.264 toggle (`feedIsTranscoding`) requests a software transcode of a genuinely-MPEG-2 source, the popover kept reporting "MPEG-2" (the untransformed source codec) even while a real H.264-transcoded stream was playing. `inferredCodecs` now checks `feedIsTranscoding` first — true means the popover reports `("H.264", "AC-3")` unconditionally, regardless of the source's own codec, since that's what's actually arriving over the wire at that moment.
- **Speed up to live / catch-up button** (`catchUpButton(showLabel:)`, `forward.end.circle`, `.plain` style — labeled `"Catch Up"`/`"Live Edge"` since 2026-08-21 when standalone, icon-only inside the buffer pill above): for a live channel, calls `VLCBridge.shared.catchUpToLive()` — stops the stream, discards the accumulated buffer, and reconnects at the live edge; the rate controller resets and the fill phase starts over. The poster overlay does **not** re-appear after catch-up (it only shows on a fresh channel switch, not on a same-channel restart). For a recording-relay stream (`bridge.recordingShowId != nil`), calls `AppState.seekRecordingToLiveEdge(showId:)` instead — plain `catchUpToLive()` would just replay the current URL verbatim at the same stale `&start=` offset, so a fresh near-live-edge offset is computed (the same `elapsed - recordingLiveEdgeBackoffSeconds` math `watchRecordingInApp` uses on first open) and reconnected. Tooltip changes accordingly: `"Speed up to live — discard buffer and jump to live edge"` vs. `"Jump to the live edge of the recording"`; label text changes the same way (`"Catch Up"` vs. `"Live Edge"`).
- **Info button** (`info.circle`, `.plain` style, added 2026-09-19 — "like pressing 'i' on a TV remote"): toggles `infoOverlayVisible`, which shows/hides `infoBanner` (see "Info banner" under Video surface below). The `"i"` key itself is handled by `VLCPlayerWindowManager.installKeyMonitor` (a local `NSEvent` monitor posting `.vlcToggleInfoOverlay`, matched by `.onReceive` in `body`) rather than a `.keyboardShortcut` on this button — switched 2026-09-26 after a live report that the shortcut sometimes didn't fire: a bare, unmodified letter-key `.keyboardShortcut` only reaches SwiftUI if no other focused control (e.g. the toolbar's own channel `Picker`, an `NSPopUpButton` under the hood, which intercepts a plain letter keystroke for its own type-ahead item-jump behavior) claims it first, whereas a local monitor runs before responder-chain dispatch and can't lose that race — the same reasoning `installKeyMonitor`'s pre-existing arrow-key/Esc handling already relied on. Pressing again while the banner is showing dismisses it immediately; otherwise a `.task(id: infoOverlayVisible)` auto-hides it after `infoOverlayAutoHideSeconds` (6s). Identifier `vlc-info-button`.
- **Divider** (18pt tall, always visible — added 2026-09-19, reported "crowded": groups buffer/catch-up/H.264/native/info together and sets the clock apart as its own section)
- **Live clock**: `TimelineView(.periodic(from: .now, by: 1.0))` rendering current wall time in monospacedDigit secondary-color text, min 70pt width. Updates every second.
- **Divider** (18pt tall, always visible — added 2026-09-19, same reasoning: separates the clock from volume)
- **Volume section**:
  - `speaker.wave.2` SF Symbol in secondary color (`.accessibilityHidden(true)` — decorative)
  - `Slider(in: 0...100)`, 100pt wide, `.accessibilityLabel("Volume")`
- **Divider** (18pt tall, visible only when at least one of the "More options" sub-menus below applies) — this one predates 2026-09-19's pass; unchanged
- **More options menu** (`ellipsis.circle`, max 24pt wide, `.menuStyle(.borderlessButton)`) — added 2026-09-13, consolidating previously-standalone icon+picker toolbar groups (audio track, captions, audio output, display, and — added 2026-09-20 — cast) into one overflow menu, since these are "set once per session, rarely touched again" choices unlike the always-visible controls above. Hidden entirely when none of its sub-menus would have anything to show — except Cast (see its own entry below), which is a deliberate exception to that rule. Tooltip: `"Audio, captions, output, display, and cast options"`. Accessibility label: `"More options"`, identifier `vlc-more-options-menu`. Each sub-menu below keeps exactly the same visibility condition, VLCBridge call, and state it had as a standalone `Picker` — nothing was removed, only regrouped. **Captions listed first** (moved 2026-09-19, was after Audio Track — reported "crowded, and not well placed"; simple reordering, not a new placement outside the menu):
  - **Captions** submenu (`captions.bubble` icon, shown when `!bridge.spuTracks.isEmpty && bridge.recordingShowId == nil`): "Off" row plus one per CC track from `libvlc_video_get_spu_description`, checkmarked when selected. Selecting calls `VLCBridge.shared.setSpuTrack(id:)` and sets `spuChoiceIsExplicit = true` (every tap through this menu is a real, explicit choice). Identifier `vlc-cc-picker`. See "Toolbar Layout" below for the full CC auto-enable/auto-disable behavior, unchanged by this regrouping. **Only shows up once `bridge.spuTracks` is actually populated** — see `VLCBridge.fetchTracks()`'s own doc comment (`docs/VLCBridge.md`) for the 2026-09-19 fix to a real bug where CC tracks could go permanently undetected for a whole session if they weren't yet enumerable by libvlc at the exact tick audio tracks were.
  - **Audio Track** submenu (`headphones` icon, shown when `bridge.audioTracks.count > 1`): one row per track from `libvlc_audio_get_track_description`, checkmarked when selected. Selecting calls `VLCBridge.shared.setAudioTrack(id:)`. Identifier `vlc-audio-track-picker`.
  - **Audio Output** submenu (`airplayaudio` icon, shown when `systemDevices` non-empty): one row per CoreAudio output device (built-in, Bluetooth, AirPlay, USB), checkmarked when selected. Selecting calls `setAudioDevice(output: "auhal", deviceId:)`. An AirPlay-transport device (added 2026-09-20 — `systemAudioOutputDevices()`'s `isAirPlay` field) gets its row label suffixed `" (AirPlay)"` rather than a second icon, since a `Menu` row only has room for one `Label`/systemImage. Identifier `vlc-audio-output-picker`.
  - **Display** submenu (`airplayvideo` icon, shown when `availableScreens.count > 1`): a leading, non-interactive tip row (`Text("Tip: connect via Control Center → Screen Mirroring first")`, added 2026-09-20 — a `Button`/`InfoButton` here would dismiss the submenu on tap, since any `Button` inside a SwiftUI `Menu` closes the enclosing menu; a bare `Text` with no action renders inert instead), then one row per `NSScreen.localizedName`. Selecting a screen row calls `VLCPlayerWindowManager.shared.moveToScreen(_:)` to centre the window on that display (deminiaturizes first, then clamps the origin so a larger window can't land off-screen on a smaller target). AirPlay displays appear here once connected via Control Center → Screen Mirroring; the list refreshes automatically on `NSApplication.didChangeScreenParametersNotification`. Also carries a `.help()` tooltip (added 2026-09-20) repeating the same Control Center guidance. Identifier `vlc-display-menu`.
  - **Cast** submenu (`tv` icon, added 2026-09-20) — the one entry that does **not** follow the hide-when-empty rule the other four use: shown whenever `bridge.isAvailable`, regardless of whether any Chromecast has actually been found yet. Chromecast discovery (`VLCBridge.startCastDiscovery()`, LAN mDNS via libvlc's bundled renderer module — see `docs/VLCBridge.md`'s "Chromecast / Renderer Discovery") is asynchronous and can take several seconds; hiding the entry until a device turns up would make it look broken rather than "nothing to cast to yet." Contents: `"No devices found"` (inert, secondary-colored) when `bridge.castDevices` is empty; otherwise a synthetic **"This Mac"** row (checkmarked when `bridge.castingDeviceID == nil` — the same "explicit off-state row inside the submenu" shape the Captions picker's own "Off" row already uses) followed by one row per discovered device, checkmarked when `dev.id == bridge.castingDeviceID`. Selecting a device calls `VLCBridge.shared.castTo(deviceID:)`; selecting "This Mac" calls `stopCasting()`. Started/stopped from `.onAppear`/`.onDisappear` (and `playerWindowDidClose()`) alongside the existing audio-device-monitoring calls. Identifier `vlc-cast-picker`.

### Video surface
`VLCVideoSurface: NSViewRepresentable` — a plain `NSView` with `wantsLayer = true` and black `CALayer` background. VLC renders directly into this layer via `VLCBridge.shared.setDrawable(_:)`.

The video surface is wrapped in a `ZStack` with a **poster overlay**, an **error overlay**, an **ended overlay**, and an **info banner** sitting on top. The poster is visible when `posterHidden == false && !bridge.hasError && !bridge.hasEnded`; it still fades in (and back out, e.g. on error) with `.easeOut(duration: 0.35)` in general, but `startPlayback(auto:)` (Start click / FEED auto-play) sets `posterHidden = true` inside an explicit `Transaction` with `disablesAnimations = true`, so *that specific* reveal is instant rather than a 0.35s crossfade — added 2026-09-26 after a live report that the crossfade left the picture visibly appearing ~350ms after `setVolume(Int(volume))` (called synchronously right after, also instant/un-ramped) had already unmuted the audio; audio and video now become audible/visible in the same frame. The poster reappears (by resetting `posterHidden = false`, still animated normally) whenever `selectedChannel` changes. The error overlay (see below) appears on top of both the video and poster when `bridge.hasError == true`, suppressing the poster entirely until the user retries. The ended overlay appears when `bridge.hasEnded == true` (see "Ended Overlay" below), also suppressing the poster.

**Info banner** (`infoBanner`, added 2026-09-19, restyled 2026-09-26 after an old MTV/VH1 music-video ID card reference, narrowed to exactly three lines later the same day per explicit request) — a non-interactive (`allowsHitTesting(false)`) stack of plain serif (`design: .serif`) text lines shown directly over the picture (no card/material background) while `infoOverlayVisible` is true (toggled by the toolbar's Info button above), left-aligned in the lower-left, `Color(white: 0.94)` with a small black drop shadow for legibility over any content. Bottom-padded (88pt) to clear the recording scrub bar (`posterHidden`'s own hover-revealed overlay, same `ZStack`) rather than sharing its edge — the two would otherwise visually collide while watching a recording; this preserves the original top-pinned placement's no-collision intent from the new lower band. Exactly three stacked lines: the show/channel name (`currentGuideEntry?.Title`, falling back to the FEED relay's `virtualRelayShowTitle` the same way `posterOverlay` does when `currentGuideEntry` is nil for a virtual-relay device, then `selectedChannel?.GuideName` as a last resort), the episode info line (`GuideEntry.episodeInfoLabel` — the `SxxEyy` convention, from `EpisodeNumber`/`EpisodeTitle` — or the FEED extras' episode number/title joined the same way), and an italic closing **source** line (`infoBannerSourceLine(feedEntry:)`) that describes the *kind* of source, not just the channel: `"Live OTA · Ch <num>  <name>"` for a real tuner channel on this window's own `device` — or, for a cross-device PiP swap (`VLCPlayerWindowManager.shared.currentDeviceID != device.DeviceID`), `"Live OTA · <deviceId> · Ch <num>  <name>"`, naming the actual tuner rather than reading identically to a same-device channel (added 2026-09-26, live report: "Live OTA · Ch 5.1 KMSP" alone gave no hint the picture was actually coming from a different Mac's tuner than the one the window opened on) — `"Recording · Ch <real channel>"` for a Watch Now own-recording session, or `"FEED · <hostname>"` for a remote relay (direct or, via `state.remoteRelayEntries`, a cross-device-swapped-in one). `selectedChannel` can hold one of two synthetic picker rows (`recordingChannelEntries`'s `"live:showId"` or `feedChannelEntry`'s `"live-feed:url"`) whose `GuideNumber` is an ID/URL, not a real channel number — both are resolved back to real detail rather than shown raw (found live 2026-09-26, right after the restyle shipped: a Watch Now session initially showed the raw synthetic ID, `"Ch live:df96c6d0…  Live 9.6  The Carol Burnett Show"`). The earlier separate `"New Episode"`/`"Originally Aired <date>"` tag line (`isNewEpisode(entry)` / `origAirdateFormatter`, `GuideViewHelpers.swift`) was dropped the same day to keep to exactly three lines — that information could return as part of the source line later if wanted. `.animation(.easeOut(duration: 0.25), value: infoOverlayVisible)`.

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
let device: HDHRDevice    // fixed for this VLCPlayerView *instance*; determines which lineup the channel picker shows
let initialURL: String    // stream URL active when this instance was created; drives initial channel selection

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

`device` is `let` — fixed for the lifetime of one `VLCPlayerView` *instance* — but that instance is no longer necessarily the window's only instance. There is still no device picker inside the player toolbar itself; the channel picker always shows channels from whatever `device` the currently-hosted instance was constructed with. **Cross-device window reuse** (fixed 2026-08-22 — see `issues_resolved.md`): `VLCPlayerWindowManager.open()` reuses the same `NSWindow`/`NSHostingView` across opens rather than recreating them, so simply calling `open()` with a different device used to leave the already-hosted view's `device` — and everything the toolbar derives from it (`lineup`, `recordingChannelEntries`, the quick-record target, tuner-status polling) — silently pointing at the old tuner. `open()`'s reuse branch now detects a device change and swaps the window's hosted view (`NSHostingView.rootView`) to a freshly-constructed `VLCPlayerView(device:initialURL:)` with a new `.id(device.DeviceID)`, forcing SwiftUI to treat it as a genuinely new view identity — `@State` resets and `.onAppear` re-fires the same setup a truly fresh window's first appearance does. See `VLCPlayerWindowManager`'s `open()`/`hostingView` below for the mechanics.

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
    let recordingShow = showId(fromLiveGuideNumber: ch.GuideNumber)
        .flatMap { id in state.recordingShows.first { $0.show_id == id } }
    let channelNum = recordingShow?.show_channel ?? ch.GuideNumber
    let anchorTime = recordingShow?.show_next ?? now
    let guideDeviceId = recordingShow?.hdhr_record ?? VLCPlayerWindowManager.shared.currentDeviceID ?? device.DeviceID
    return state.guideEntries(deviceId: guideDeviceId, channelNum: channelNum)
        .first { $0.startDate <= anchorTime && $0.endDate > anchorTime }
}
```

Returns the currently-airing `GuideEntry` for a plain live-channel selection, or — when `selectedChannel` is a recording-relay row — the `GuideEntry` that was airing when *that recording* started, not necessarily whatever's airing right now. Used by the poster overlay to display title, episode info, synopsis, and to fetch the poster image via `ChannelIconCache`. A `.task(id: currentGuideEntry?.ImageURL)` on the ZStack re-fetches the poster image whenever the on-air entry changes (e.g. top-of-hour handoff). **Fixed 2026-08-21** (see `issues_resolved.md`): when `selectedChannel` is a recording-relay row (`recordingChannelEntries`' synthetic `"live:showId"` `GuideNumber`, used so the channel picker can show/cycle recordings), that placeholder never matched a real channel in the guide — `currentGuideEntry` was always `nil`, so the poster/synopsis overlay went blank for the entire time you were watching an in-progress recording, regardless of whether you opened it from the menu bar or from `WatchNowView` (both funnel through `AppState.watchRecordingInApp`, which produces exactly this kind of `selectedChannel`). Now resolves the synthetic id back to the recording show's real `show_channel` first via `showId(fromLiveGuideNumber:)` + a `state.recordingShows` lookup, falling through unchanged for an ordinary real channel. **Fixed 2026-09-13**: the guide-entry lookup itself used to query "what's airing on this channel right now" (wall-clock `Date()`) even for the recording-relay case — broke for a Bonus Time recording, since once wall-clock time passes the original guide slot's own end, that query resolves to whatever *different* program the channel has since moved on to, showing the wrong title/episode/synopsis/poster for a still-correctly-recording show. Now anchors to the recording show's own `show_next` (scheduled start) instead, which always resolves to the entry that was airing when recording began — a plain live-channel selection (no matching `recordingShow`) is unaffected and still uses wall-clock now. Same root cause and fix as `MenuContent.recordingMenu`'s "Recording Now" row — see `docs/MenuContent.md`. **Fixed 2026-09-26**: the guide-data lookup always queried `device.DeviceID` regardless of which device `selectedChannel` actually resolved to — harmless before the cross-device `syncChannel()` fixes above existed (a mismatch there just meant `selectedChannel` itself was already `nil`), but once those fixes let `selectedChannel` correctly resolve to a *different* device's channel or recording after a cross-device PiP swap, this line kept querying the wrong (often guide-data-less, e.g. a virtual relay) device and returned `nil` anyway — live report: show name/episode info disappeared entirely right after the `syncChannel()` fix shipped, trading "Unknown" for blank. Now queries the recording's own `hdhr_record` device when `selectedChannel` is a recording row, else `VLCPlayerWindowManager.shared.currentDeviceID` (falling back to `device.DeviceID`) — both correctly equal `device.DeviceID` for the common, non-cross-device case, so this changes nothing there.

### onAppear / Channel Sync

`.onAppear` populates `availableScreens = NSScreen.screens` (main-thread-only; unsafe to set as a `@State` default), calls `refreshAudioDevices()` — populates `systemDevices` from `VLCBridge.shared.systemAudioOutputDevices()`, pre-selects the system default via `systemDefaultOutputUID()`, and routes VLC to it immediately with `setAudioDevice(output: "auhal", deviceId:)`. `startDeviceChangeMonitoring` is also started, calling `refreshAudioDevices()` whenever CoreAudio devices change (Bluetooth connect, AirPlay connect, etc.).

`volume` is not read back from VLC on appear because the player is already muted at open time — reading back would return `0`, overwriting the user's saved preference. `@AppStorage("vlcVolume")` preserves the last-used volume across sessions; `setVolume(Int(volume))` in the Start button action restores it at the moment the user dismisses the overlay.

`syncChannel(to:)` strips query params, matches against `lineup`, sets `suppressNextChannelPlay = true`, then sets `selectedChannel`. The `suppressNextChannelPlay` flag prevents the `onChange(of: selectedChannel)` handler from calling `playChannel()` when the selection change was driven by `syncChannel` rather than a user tap — avoiding a redundant second `_mpPlay` call on an already-playing stream. A second, narrower flag, `suppressSameContent`, is set alongside it **only** by `syncChannel`'s recording-relay match branch (the live→disk yield handoff, relabeling the picker for the *same* show already playing) — every other suppressed case, most notably switching which FEED show is playing via `VLCPlayerWindowManager.open()` reusing this window, is genuinely new content and still gets the poster/mute reset below even though playback itself is suppressed. See "Poster reappears" below.

`state.vlcCurrentURL` is set by `AppState.watchInApp()` before calling `open()`. When the player window is already open and a different "Watch Now!" is clicked, `onChange(of: vlcCurrentURL)` fires inside the running window's SwiftUI tree and syncs the picker to the new channel without reopening the window.

Initial pre-selection strips query parameters from `initialURL` before matching because the URL passed to `open()` may have `?transcode=heavy` appended while `LineupEntry.URL` is the raw base URL. Both `hasPrefix` directions are checked to handle edge cases where one URL is a prefix of the other.

Pre-selection via `syncChannel` only updates `selectedChannel` — it does **not** call `playChannel()`. The stream is already playing (started by `VLCPlayerWindowManager.open()` before the window appears).

### Live recording entries

Lets the channel picker switch directly between simultaneous recordings on this device (via the relay — `docs/WebServer.md`'s `/api/watch-recording`), the same way it switches between live channels — no separate menu needed.

`LineupEntry`'s `Equatable` (`AddShowView.swift`) compares `GuideNumber` **and** `Favorite`; `Hashable` hashes `GuideNumber` alone. Either way, a synthetic row can't reuse the show's real channel number (it would collide with — compare equal to, or at least hash-collide with — that channel's real lineup row). Instead:

- `recordingChannelEntries: [LineupEntry]` — one entry per `state.recordingShows` on this device (`show.hdhr_record == device.DeviceID`), sorted by channel. `GuideNumber` is `"live:{show_id}"` (never collides with a real channel number); `GuideName` holds the full display label, `"Live 5.1  The Closer"` — rendered directly (`Text(entry.GuideName)`) rather than through the `"GuideNumber  GuideName"` template used for real channels, which would show the synthetic tag.
- `showId(fromLiveGuideNumber:)` — strips the `"live:"` prefix; returns `nil` for a real channel's `GuideNumber` or the bare-fallback row.
- Picker row order: bare **"Live"** fallback (`Optional<LineupEntry>.none`, selected only if nothing below matched — keeps the picker from ever rendering blank; hidden when `recordingChannelEntries.isEmpty`, since there's nothing to fall back to) → `recordingChannelEntries` → the device's real channels, split into a `Section("★ Favorites")` (`favoriteLineup`) followed by the rest (`otherLineup`) when any favorites exist.
- `onChange(of: selectedChannel)`: `showId(fromLiveGuideNumber:)` non-nil → looks up the `Show` in `state.shows` and calls `AppState.watchRecordingInApp(_:)` (switches the relay stream, no new tuner); otherwise → `playChannel()` as before (live device channel, new tuner).
- `syncChannel(to:)` checks `bridge.recordingShowId` first before falling back to the lineup-URL match, so a relay URL pre-selects the matching "Live 5.1  Title" row instead of falling through to "no match in lineup." As of 2026-09-26 this matches against *all* `state.recordingShows` directly (via the extracted `liveRecordingEntry(for:)`, not `recordingChannelEntries`, which stays device-filtered and is used only to build the picker's own rows) — see "Picture-in-picture" below for why. Also updates `MPNowPlayingInfoCenter` with the show's title and `"Live"` as artist (not the synthetic `GuideNumber`).
- `.onChange(of: bridge.recordingShowId)` re-runs `syncChannel(to: bridge.currentURL)` once it becomes non-nil — needed because `AppState.watchRecordingInApp(_:)` defers setting it to the next run-loop turn (a SwiftUI render-timing fix — see `docs/AppState.md`), so the very first `syncChannel` call from `.onAppear` (same synchronous window-open transaction) can run before it lands.

### Toolbar Layout

```
[Channel picker ─────────] Spacer [buffer|⏭ pill] [☑ H.264] [1:1] [🕐] [🔊] [─── slider ───] | [⋯ more options]
```

`[⋯ more options]`, added 2026-09-13, replaces four previously-always-visible groups (audio track, CC, audio output, display — each its own icon + `Picker`/`Menu` + `Divider`) with one `ellipsis.circle` overflow menu, since the toolbar had grown too dense with controls that are typically set once per session rather than adjusted repeatedly during playback. See "Visual Appearance" above for the full per-sub-menu breakdown; nothing about *when* each choice is offered or *what* it does changed, only where it lives.

`[☑ H.264]` only appears for a remote FEED session (see "Auto-play for a remote FEED session" above) whose source isn't already a modern codec — hidden entirely otherwise, same condition as MenuContent's own "Watch (H.264)" menu item.

`[🕐]` is the live wall-clock `TimelineView` — always shown here, unconditionally, for every stream including a recording-relay session. The recording scrub bar does **not** live in the toolbar (see "Recording scrub overlay" below); it's a hover overlay on the video instead — the toolbar had no room to spare for it alongside everything else.

**Accessibility, added 2026-09-04**: every interactive toolbar control (and the poster's Start button, the error/ended overlays' Retry/Play Again buttons, and the recording scrub slider) carries an explicit `.accessibilityIdentifier("vlc-...")`, and the channel picker's `.labelsHidden()` `Picker` has its `.accessibilityLabel` moved onto the picker itself rather than left on the adjacent decorative icon (which is now `.accessibilityHidden(true)`) — VoiceOver was previously getting an unlabeled control next to a static, non-interactive label. Confirmed live via `RUN_WINDOW_NAV_TESTS=1 swift test --filter WindowNavigationTests`'s `vlcPlayerControlsAreAccessible` that these identifiers actually surface through System Events' `value of attribute "AXIdentifier"` — a materially more reliable lookup for future automation than text-matching `help`/`description`, which `watchNowRowButtonsAreAccessible`'s own doc comment found don't reliably surface for this app's SwiftUI/AppKit controls the way `AXIdentifier` does. (Audio track/CC/audio output/display moved off standalone `.labelsHidden()` pickers into the `[⋯ more options]` menu's own sub-menus 2026-09-13 — each still keeps its own `.accessibilityIdentifier`, listed above.)

- **Channel picker**: `.labelsHidden()`, max width 220 pt, tags use `Optional(ch)` to match the `LineupEntry?` binding. See "Live recording entries" below for the "Live" fallback row and per-recording rows shown above the real channel list.
- **Buffer monitor + catch-up pill**: visible only when `bufferInfo.enabled` (i.e. `minRate < 1.0`) — never true for a recording-relay session (see below), so only `catchUpButton` shows there, standalone with no pill. When shown, the buffer monitor and catch-up button share one pill background with a hairline divider, positioned before the native-resolution button.
- **Raw/H.264 toggle, added 2026-09-04** (checkbox-style `Toggle`, shown only for a remote FEED session — `device.isVirtualRelay` — whose source isn't already a modern codec): lets a viewer switch between the FEED's raw passthrough and its transcoded H.264 stream without backing out to the menu bar's "Watch"/"Watch (H.264)" pair and reopening the window. `currentFeedEntry` re-derives the matching `LineupEntry` from `bridge.currentURL` (path-only match via `.urlBase`, since `lineup` here is already scoped to this one device's own `state.lineups[device.DeviceID]`) to read its `VideoCodec` (`feedSourceAlreadyModern`, mirroring MenuContent's own `alreadyModern` check) and its canonical un-transcoded `URL`. Toggling calls `toggleFeedTranscode(to:)`, which reconnects via `bridge.play(url:)` directly — the same reconnect-by-URL mechanism the recording scrub bar and `catchUpToLive()` already use — appending/removing `&transcode=auto` from that canonical URL rather than mutating `bridge.currentURL`'s own query string (so a channel-disambiguating `?dev=` param already on the entry's URL is never lost). Unlike a channel-picker switch, this does **not** reset `posterHidden`/mute — it's a mid-session codec swap, not a new channel, so the video just briefly rebuffers in place.
- **Native resolution button** (`aspectratio`): calls `sizeToNativeVideo()`, disabled unless a frame has decoded and the native size fits the current screen; hover shows a popover with resolution/codec detail (see "Visual Appearance" above for the full breakdown)
- **Catch Up button** (`forward.end.circle`): live-channel vs. recording-relay behavior and tooltip differ — see "Visual Appearance" above for the full breakdown.
- **Clock**: live wall-clock `TimelineView`, monospaced — unconditional, same for every stream
- **Volume**: speaker icon + `Slider(value:in:0...100)`. `onChange` maps to `VLCBridge.shared.setVolume(Int(v))`.
All four of the following now live inside the `[⋯ more options]` menu described above, not as standalone toolbar controls — the visibility conditions, VLCBridge calls, and state below are unchanged by that regrouping.

- **Audio Track submenu** (when `bridge.audioTracks.count > 1`): one row per audio track from `libvlc_audio_get_track_description` with `id ≥ 0`, checkmarked when selected. Appears ~3 s after playback starts (first `tickController` tick after `isPlaying`). Defaults to the first track (already active in VLC). Selecting calls `VLCBridge.shared.setAudioTrack(id:)`. Reset to unloaded (id = −1) on every channel switch.
- **Captions submenu** (when `!bridge.spuTracks.isEmpty` **and** `bridge.recordingShowId == nil`): first row is always "Off" (tag `Int32(-1)`); remaining rows are CC tracks from `libvlc_video_get_spu_description` with `id ≥ 0`, checkmarked when selected. Selecting calls `VLCBridge.shared.setSpuTrack(id:)` and marks the choice explicit (see below). Reset on channel switch. Hidden entirely during a recording-relay session — switching SPU tracks while reading the relay's on-disk file back doesn't produce a visible result, so a menu that looks like it does something without actually working would be worse than not offering it.
  - **A remote FEED session needs no special-casing here, verified 2026-09-04**: `bridge.recordingShowId` is only ever set by the *local* Watch Now relay (`AppState.watchRecordingInApp`/`beginRecordingSeek`) — `watchRemoteRelay` never touches it, so it stays `nil` for a FEED session and this picker's existing condition just works unmodified. A **raw** FEED carries the source's embedded CC through untouched (byte-identical passthrough), and libvlc genuinely decodes it — confirmed by pointing VLC directly at a live FEED URL and seeing `main input debug: Adding CC track 1-4 for es[49]` in its own log, the same detection a live channel gets. A **transcoded** FEED does *not* carry CC — VLC's own `x264` stream-out module has no exposed option for A/53 caption passthrough (checked `vlc -p x264 --advanced --help-verbose`: nothing caption/SEI-related), so the MPEG-2 decode → H.264 encode pipeline silently drops it; `mediainfo` confirms 0 Text tracks in transcoded output vs. 6 in the untouched raw file. This isn't a bug to fix here — `bridge.spuTracks` is correctly empty for that session, so the picker correctly stays hidden rather than offering a control that wouldn't do anything, the same "don't show what won't work" principle the recording-relay case above already follows. Preserving CC through the transcode itself would need a different encode pipeline (e.g. shelling out to `ffmpeg -a53cc 1`) or a custom TS-level CC extract/re-inject step — out of scope unless asked for.
  - **Default/auto-enable behavior**: defaults to Off, and some streams auto-enable CC on their own so `setSpuTrack(id: -1)` is called explicitly when `spuTracks` first loads (`onChange(of: bridge.spuTracks.count)`) — *unless* the volume is at 0 at that moment (and this isn't a relay session), in which case the first available CC track is auto-selected instead, since there's no audio to convey what's being said otherwise. The same auto-enable also fires on a rising edge into muted mid-playback (`onChange(of: volume)`, `oldValue > 0 && newValue == 0`) if tracks were already known — skipped if the user already made an explicit selection, tracked by `spuChoiceIsExplicit` (even "Off" chosen on purpose) so it doesn't fight a deliberate choice. `-1` alone can't distinguish "user picked Off" from "no choice made yet" (it's both the "Off" row's tag and the reset sentinel), which is exactly what `spuChoiceIsExplicit` exists to disambiguate — fixed 2026-08-15 (pre-release review caught that a real tap of "Off" got silently overridden by the next mute). Only a real tap on a Captions submenu row (any of them, including "Off") sets it `true` — until 2026-09-13 this was a wrapped `Picker(selection: Binding(get:set:))`, now each row's own `Button` action sets it directly, same effect; every programmatic reset of `selectedSpuTrackId` (channel load, channel switch) resets it back to `false` too, so a new channel always gets a fresh auto-enable decision rather than inheriting the previous channel's explicit choice forever.
  - **Auto-disable on unmute**: the same `onChange(of: volume)` handler also covers the falling edge out of muted (`oldValue == 0 && newValue > 0`) — if CC is still on and the user never made an explicit choice while muted (`!spuChoiceIsExplicit`), it's turned back off (`setSpuTrack(id: -1)`) now that there's audio again. A real Picker pick during the muted stretch — including re-picking the same track "on" — sets `spuChoiceIsExplicit` and survives unmuting; only the mute-triggered auto-enable gets auto-reverted. Added 2026-08-17 — previously CC stayed on indefinitely after unmuting even without an explicit pick.
  - **Considered and reverted 2026-08-22**: briefly changed to default CC on unconditionally (any mute state); reverted same day at the user's explicit request — this off-unless-muted behavior is the intended one.
- **Audio Output submenu**: shown when `!systemDevices.isEmpty`. Lists all CoreAudio output devices (built-in, Bluetooth, AirPlay audio, USB), checkmarked when selected. Selecting calls `setAudioDevice(output: "auhal", deviceId:)`. An AirPlay device's row is suffixed `" (AirPlay)"` (added 2026-09-20).
- **Display submenu**: shown when `availableScreens.count > 1`. Leads with a non-interactive `Text` tip row (added 2026-09-20) pointing at Control Center → Screen Mirroring, then lists `NSScreen.localizedName` entries. Selecting a screen calls `VLCPlayerWindowManager.shared.moveToScreen(_:)` to centre the window on that display. AirPlay video displays appear here once connected via Control Center → Screen Mirroring. Also carries a `.help()` tooltip repeating the same guidance.
- **Cast submenu** (added 2026-09-20): shown whenever `bridge.isAvailable`, not gated on any device having been found yet (Chromecast mDNS discovery is asynchronous — hiding the entry until something turns up would read as broken rather than "nothing to cast to yet"). Lists discovered devices from `bridge.castDevices` plus a synthetic "This Mac" row for returning to local playback; selecting a device calls `VLCBridge.shared.castTo(deviceID:)`. See `docs/VLCBridge.md`'s "Chromecast / Renderer Discovery" section for the full discovery/casting mechanism.

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

    // Reusing an already-held tuner slot on this device → start immediately, same as always.
    // Anything else (a FEED/Watch Now relay, or a different device — see below) → pre-flight
    // AppState.tunerAvailable(_:context:) check first, same as watchInApp's device-change path.
    if reusingExistingTunerHere { startPlayChannel(ch, url: url) }
    else { Task { if await state.tunerAvailable(device, context: ch.GuideName) { startPlayChannel(ch, url: url) } } }
}

private func startPlayChannel(_ ch: LineupEntry, url: String) {
    // Buffer immediately — stream starts the moment the poster appears.
    VLCBridge.shared.play(url: url)
    updateNowPlaying(channel: ch)

    // Tuner check runs in background after play() so it never delays buffering.
    Task { /* fetch status.json, log active/total, warn if over capacity */ }
}
```

Uses `AppConfig.applyTranscode(_:override:)` — applies `Default_transcode` without a per-show override (the picker is device/lineup-level, not show-level). When transcode is `"none"` or empty the raw stream URL is used; VLC decodes MPEG-2 natively.

**Pre-flight tuner check, added 2026-09-19** — found live: with the primary a FEED (0 tuners held on this device) and the device already at its real hardware limit from two *other* machines' recordings, picking a live channel here silently hung with no explanation instead of the "All Tuners Busy" alert every other channel-opening path (`AppState.watchInApp`) already shows. `playChannel` used to always start immediately, on the theory that a same-device channel switch just reuses the tuner slot already held (matching `watchInApp`'s own "switching within an already-open player on the same device skips the check" rule) — true for a genuine live-channel-to-live-channel switch, but false whenever the primary currently holds no real tuner slot on *this* device at all. `reusingExistingTunerHere` (`VLCPlayerView`, computed at the top of `playChannel`) captures that distinction: `VLCPlayerWindowManager.currentDeviceID == device.DeviceID && bridge.recordingShowId == nil && VLCPlayerWindowManager.currentFeedRemoteURL == nil && bridge.currentURL` non-empty. True → same behavior as always (start immediately, zero added latency for the common case). False (most commonly reachable via a PiP swap — see the "cross-device swap" note above) → awaits `AppState.tunerAvailable(device:context:)` first (the same fresh-status-poll-then-alert helper `watchInApp` uses for its own device-change path; made non-`private` for this cross-file call) before starting, showing a proper "All Tuners Busy" `NSAlert` instead of silently timing out against a device with no free tuner. The decision itself is a pure function, `reusesExistingTuner(currentDeviceID:targetDeviceID:recordingShowId:currentFeedRemoteURL:currentURL:)` — unit tested in `Tests/hdhr_VCRTests/Views/VLCPlayerViewTunerReuseTests.swift`.

**Immediate buffering** (the `reusingExistingTunerHere` / already-checked-and-available path): `play()` is called synchronously, before the background Task that checks tuner occupancy. The poster overlay is visible from the moment the channel changes, so every millisecond of poster time is also buffer-build time. By the time the user reads the episode info and clicks Start, the stream has been filling at `minRate` since the picker change.

**Now Watching sync**: `VLCBridge.play(url:)` sets `currentURL` synchronously (drawable already exists for an open window). The Combine sink in `AppState` picks this up immediately and updates `vlcCurrentURL` — no manual assignment needed in `playChannel`.

**Background tuner check**: after `play()` returns (inside `startPlayChannel`), a `Task` fetches `status.json` and logs `[VLC] post-switch tuner status ch X.X: N/M active (ours=N other=N)`. If all non-VLC slots appear occupied it logs a warning — this diagnostic-only check is unchanged; it's not what the pre-flight check above replaces (that check happens *before* `startPlayChannel`/`play()` runs at all, and only for the not-`reusingExistingTunerHere` case).

**Tuner occupancy refresh**: `state.refreshTunerOccupancy()` is called after every channel switch so the menu header reflects the new tuner state within ~1.5 s.

**Start button — gated on `isPlaying`**: the Start button is disabled and shows a spinner + "Connecting…" until `VLCBridge.shared.isPlaying` becomes `true` (first `libvlc_Playing` state confirmation — see `docs/VLCBridge.md`'s "Startup state poll" for how quickly that now happens). Once enabled it shows the normal play icon + "Start". This prevents the user from unmuting before any data has arrived.

**Start button log**: the Start button (which dismisses the poster overlay) logs `[VLC] Start clicked — buffer ~X.Xs built before unmute`, showing exactly how much buffer headroom accumulated during the poster phase.

### onAppear / onDisappear

`onAppear` logs `[VLC] VLCPlayerView.onAppear device=… initialURL=…`, sets up the rate controller, audio devices, media-key remote commands, and calls `syncChannel`.

`onDisappear` logs `[VLC] VLCPlayerView.onDisappear`, then calls `VLCBridge.shared.releasePlayer()` — full teardown: stops the stream, releases the media object, releases and nils the media player, and frees the tuner immediately — and `VLCBridge.shared.stopDeviceChangeMonitoring()`, clears `MPNowPlayingInfoCenter.default().nowPlayingInfo` and sets its `playbackState` to `.stopped`, and removes the stop/next-track/previous-track targets from `MPRemoteCommandCenter.shared()`. This is a safety net; `playerWindowDidClose()` normally fires first via the window delegate and does the same teardown (plus more — see below). `releasePlayer()` is idempotent so calling it twice is harmless.

**Remote stop command**: the Now Playing / media-key Stop command calls `VLCBridge.stop()`. This used to clear `drawableView = nil`, leaving every subsequent `play()` queued as pending forever (the SwiftUI view stays alive so `makeNSView` never re-fires) — the window went black until closed and reopened. Fixed: `stopAndClearState()` now deliberately leaves `drawableView` attached, so a subsequent `play()` finds a live surface to render into. Only `releasePlayer()` (full teardown, window close) nils it. Logged as `[VLC] remote stopCommand received` immediately before `[VLC] stop called — drawable=had view`.

**Media-key next/prev-track**: `.onReceive(.vlcChannelNext/.vlcChannelPrev)` cycles `selectedChannel` through `channelCycleOrder` (`recordingChannelEntries + lineup` — the same order the picker itself lists rows in), not `lineup` alone — otherwise pressing next/prev while `selectedChannel` is one of the synthetic "Live" recording rows would find no match in `lineup` and silently no-op.

---

## Poster Overlay

When the player opens or changes channel, a full-area `posterOverlay` view sits on top of `VLCVideoSurface`. It displays the currently-airing show's poster image, title, episode number + title, and synopsis. A **Start** button at the bottom-left of the info column dismisses the overlay instantly (see the `ZStack` note above on why this specific dismissal skips the poster's usual 0.35s fade), revealing the live video underneath in the same moment the audio unmutes.

**Why**: VLC begins buffering the stream immediately when `open()` is called (before the window appears). By the time the user reads the episode info and clicks Start, VLC has had several seconds to buffer — the stream plays instantly rather than showing a spinner.

**Poster reappears** on channel change: `onChange(of: selectedChannel)` resets `posterHidden = false`, `posterNSImage = nil`, and calls `setVolume(0)` before calling `playChannel()`, so the new stream buffers silently behind the overlay until Start is clicked. This reset is skipped for `syncChannel`'s recording-relay "relabel the picker" update after a live→disk takeover (`suppressNextChannelPlay` **and** `suppressSameContent`-gated, returns before the reset) — root-caused 2026-09-11: it used to fire unconditionally, and since the resolved `currentGuideEntry`'s image URL doesn't actually change for that internal update, nothing ever repopulated `posterNSImage`, silently losing the show's poster/logo for the rest of the session. Every other suppressed switch (`suppressNextChannelPlay` true, `suppressSameContent` false) — most notably switching which FEED show is playing while the player window is reused (`VLCPlayerWindowManager.open()` skips rebuilding the view when the source device doesn't change) — still runs this reset, just without the redundant `playChannel()`/`watchRecordingInApp()` call, since the caller already started that exact stream. Root-caused 2026-09-14, live report: without this, `posterHidden` stayed `true` (left over from the *first* FEED show's successful auto-play), so `attemptFeedAutoPlay`'s `!posterHidden` guard silently failed for every subsequent FEED show switch — the video genuinely changed but audio stayed muted at the volume 0 `VLCPlayerWindowManager.open()` sets before every `play()` call, forever.

**Also skipped for a PiP swap's own resulting `syncChannel` resolution, added 2026-09-19** — found live: swapping to a live channel (not a recording/FEED) wrongly ran this reset, silently dropping the poster/summary and re-muting an already-live, already-decoding stream (forcing the user to click Start again for content that never actually stopped playing). `swapPrimaryAndSecondary()`'s own `selectedChannel = nil` is already fully suppressed via `suppressNextChannelPlay`/`suppressSameContent`, but `bridge.currentURL` changing (inside `bridge.swapSlots()`) independently fires `.onChange(of: state.vlcCurrentURL)` → `syncChannel(to:)` a moment later, which resolves `selectedChannel` to the *real* new-primary entry — a second, separate `selectedChannel` assignment `swapPrimaryAndSecondary()`'s own flags don't cover. A dedicated `suppressPosterResetForSwap` flag (set only by `swapPrimaryAndSecondary()`, read-and-cleared once at the top of every `syncChannel(to:)` call) carries the suppression across to that second assignment. The recording-relay and cross-device-FEED match branches don't need it — both are reachable only via a swap already (see `feedChannelEntry`'s own doc comment below), so they set `suppressSameContent` unconditionally; only the plain-lineup-match branch (shared with a genuine `open()`-driven channel switch, which legitimately *does* want the reset) checks the flag.

**Yield-to-record progress overlay, added 2026-09-11**: while `AppState.yieldRecordingProgress` is non-nil (the "Stop Watching & Record?" flow above is in progress), the poster overlay's Start/Connecting button area is replaced with a live, ticking status line instead — `"Waiting for the tuner to free up… (Ns, checked N×)"`, then `"Tuner free — starting the recording…"`, then `"Waiting for the recording file to appear on disk…"`, then `"Recording confirmed — reconnecting…"` — same non-interactive spinner treatment as the FEED buffering case just below it in the view. Cleared once `AppState.recordAfterYieldingWatchNow` either reconnects playback (`watchRecordingInApp`, whose own `open()`/`play()` drives the normal Connecting/Start state from there) or gives up — or, if the player window closes mid-wait, immediately by `cancelYieldRecordingIfInProgress()` (see below).

**Auto-play for a remote FEED session, added 2026-09-04**: when `device.isVirtualRelay` is true — i.e. this window is playing another hdhrVCRplus instance's FEED (`AppState.watchRemoteRelay`, MenuContent's "Recording on Another Mac" rows), never a real tuner or a local Watch Now! session — the Start click is skipped entirely. `attemptFeedAutoPlay()` calls the same `startPlayback(auto:)` helper the Start button itself calls once **both** `bridge.isPlaying` is `true` **and** `feedAutoPlayMinDelay` (**8s as of 2026-09-12, was 10s** — see that constant's own doc comment) of real time has passed since the current stream opened — still gated by `!posterHidden` so a later brief rebuffer (isPlaying flipping false→true again) can't re-fire it. The floor was added 2026-09-04, after live use showed `isPlaying` alone (first confirmed decode, ~3s) fired auto-play too early to build a real cushion against `Player_buffer_min_rate`'s slow ramp (`docs/VLCBridge.md`'s "Fill phase") — a manual Start click naturally got more of that ramp for free from however long a human spent reading the poster first; auto-play removed that dwell entirely, so this restores a flat minimum instead. Shortened from 10s to 8s on 2026-09-12 to exactly match the ramp's own `maxLagSec` (fixed 2026-09-06 to reliably complete in 8 real seconds, not the pre-fix's occasional multi-minute crawl) — the extra 2s was dead air left over from before that ramp-linearity fix existed; not yet live-verified against a real FEED session. A `.task(id: bridge.currentURL)` arms `feedAutoPlayDelayElapsed` after the wait; keying it on `currentURL` means a channel switch mid-session (a genuinely new stream) restarts the wait via SwiftUI's own automatic `.task(id:)` cancellation, rather than the old stream's timer firing late against the new one. One constant covers both halves of `startPlayback` — the poster reveal and the volume restore/unmute always fire together, so there's no separate "audio delay" apart from this. Real live-channel and local-recording sessions keep the manual gate unchanged.

**Show identity during the FEED buffering wait, added 2026-09-12**: `currentGuideEntry` is always `nil` for a remote FEED device — nothing populates a discoverer's `guideByDevice[relayId]` today (see `TODO.md`'s "FEED consumers should get a minimal, locally-sourced 'now playing' guide/lineup"). Without a fallback, the poster overlay showed a blank `tv` icon and "Buffering…" with no show identity at all for the full wait above. `posterOverlay` now falls back to `currentFeedEntry`'s own `/lineup.json` extras (`VirtualTunerService.swift`'s `episodeTitleKey`/`episodeNumberKey`/`synopsisKey`/`imageURLKey` — mirror `AppState.DiscordEpisodeSnapshot` exactly, captured once at "Recording Started") when `currentGuideEntry` is nil and `device.isVirtualRelay` — same title/episode/synopsis layout as the `currentGuideEntry` branch, sourced differently. `effectivePosterImageURL` (falls back to `currentFeedEntry?.virtualRelayImageURL`, the source show's channel logo — not a true per-episode image, this app has no such concept anywhere else) drives the poster image the same way for both branches, not just the fallback text.

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

## Picture-in-picture

Lets the single reusable player window drive a second, deliberately minimal concurrent stream — a
small muted corner thumbnail — alongside the primary, full-controls stream. Works for any
combination of Watch Now (local in-progress recording) and FEED (another instance's relay) in
either slot; both funnel through the same `AppState.watchAsSecondary` entry point once resolved to
their local relay URL. Entry point: whenever the player window already has something watchable
open, the Recording Now and "Recording on Another Mac" menu rows each gain a "Watch alongside
current (PiP)" action (`pip.fill` icon) next to their normal Watch button — never automatic.
`WatchNowView`'s per-channel rows get the same action too (see `docs/WatchNowView.md`), which is
the entry point for a genuine live channel as the secondary.

**The secondary is not restricted to the primary's own tuner/device** — playback works correctly
for any combination, same-device or cross-device. The only cross-device caveat is cosmetic and
toolbar-only (see "Tap-to-swap" below): after swapping in a stream from a *different* device, the
toolbar's channel picker doesn't re-list that device's channels until the window is reopened.
Nothing about opening, watching, or swapping the stream itself is affected.

**Second player, not a second window.** `VLCBridge` holds two independent libvlc
player/media/drawable triples internally (`PlayerSlot.primary`/`.secondary`, both sharing the one
`vlcInstance` — the same pattern already proven safe by the headless `TranscodeSession` mechanism).
`.secondary` is polled by a separate, much smaller `tickSecondary()` — no stats/rate-ramp/track-
fetch/pixel-size work, since the thumbnail has no buffer pill, track picker, or scrub bar to drive.
It is always muted (`VLCPlayerWindowManager.openSecondary`'s `ensurePlayer(slot: .secondary)` →
`setVolume(0, slot: .secondary)` → `play(url:slot:.secondary)`, in that order — `setVolume` is a
no-op against a not-yet-created player, and unlike the primary, whose player already exists from
`VLCBridge.init()` at app launch, the secondary's only ever comes into existence right there;
muting before `ensurePlayer` silently did nothing and left the secondary audible at libvlc's
default volume, found live 2026-09-19) and never sets `recordingShowId` (that field stays strictly
primary-only, so a swap's scrub-bar anchor always describes whichever URL is *currently* primary).

**Layout**: composited as a `ZStack` sibling in `VLCPlayerView.body`, pinned to whichever corner
`pipCorner` holds via the same `Spacer()+padding+.ultraThinMaterial` idiom as the recording scrub
bar / fullscreen toolbar overlays — not new chrome (see "Positioning the thumbnail" below). Fixed
192pt-wide, height following the secondary stream's own native aspect ratio (`pipThumbnailSize`,
computed from `bridge.secondaryVideoPixelSize` — published by `tickSecondary()`'s own
`videoNativeSize(slot: .secondary)` poll, mirroring `tickPrimary`'s `videoPixelSize`; falls back to
16:9 before the first decoded frame, since libvlc hasn't reported real dimensions yet) rather than
assuming every channel is 16:9 — a 4:3 source gets a 4:3 thumbnail, not letterboxed inside a wider
box. The sizing math itself is a pure function, `pipThumbnailSize(nativePixelSize:maxWidth:)` —
unit tested in `Tests/hdhr_VCRTests/Views/VLCPlayerViewPipThumbnailSizeTests.swift`. Video-only
(`VLCSecondaryVideoSurface`), a small spinner/error/
ended glyph keyed off `bridge.secondaryIsPlaying`/`secondaryHasError`/`secondaryHasEnded` (the
`libvlc_Ended`, state-6 case — added 2026-09-19; `tickSecondary()` originally only checked for
error and playing, so a secondary reaching EOF, e.g. a finished Watch Now recording, just froze on
its last frame forever with no indication at all), and a small "×" close button
(`VLCPlayerWindowManager.closeSecondary()`) — the only way to stop the secondary without swapping
it to primary first.

**No track picker, no scrub bar, no controls beyond tap-to-swap, the "×" close button, and — for a
live-channel secondary — the right-click "Channel" submenu below.** A FEED or Watch Now secondary
has no in-place way to retune (no channel lineup to switch within — `secondaryChannelNumber` is
nil for both, see "Positioning the thumbnail" below); the only ways to change one of those are (1)
close it and open a different "Watch alongside (PiP)" selection for whatever you actually want, or
(2) swap it to primary, where the full toolbar's channel picker is available.

**Tap-to-swap** (`VLCPlayerView.swapPrimaryAndSecondary()` → `VLCBridge.swapSlots()`): redesigned
twice on 2026-09-19. First redesign, after live feedback that the original reconnect-by-URL version
(calling `play(url:slot:)` on both slots, the same shape `toggleFeedTranscode`/`catchUpToLive` use)
caused a visible rebuffer on every swap: re-target each already-playing player's rendering surface
(`libvlc_media_player_set_nsobject`) onto the *other* slot's view live, no reconnect. Found live the
same day that this doesn't reliably work: a single `set_nsobject` call to the new view correctly
swapped audio (which follows `mediaPlayer` object identity) but left the picture on whichever view
the vout attached to at its *first* `play()` — macOS's vout module reads `drawable-nsobject` once
at attach and doesn't reliably react to it changing while already rendering; a nil-then-set retry
didn't help either.

**Second (current) redesign — move the view, not the attachment.** Each slot's `NSView` is now two
layers: a `containerView` (what `VLCVideoSurface`/`VLCSecondaryVideoSurface` actually hand to
SwiftUI — the big video area and the corner thumbnail, positioned by SwiftUI as always and never
touched again after creation) hosting a `drawableView`/`content` view as its sole, bounds-filling
subview (`VLCBridge.fill(container:with:)`) — *that* inner view is the one `_mpSetNSO` actually
targets, attached exactly once per player and never re-targeted again. `swapSlots()` moves
`drawableView` (plus its `retainedDrawable` strong ref) into the *other* slot's `containerView` via
plain `addSubview`/`removeFromSuperview` — ordinary AppKit view reparenting, which doesn't depend on
libvlc's vout honoring anything live; the player keeps rendering into the exact same `NSView` object
it always has, that view just now sits inside a different container. Swaps the Swift-side
bookkeeping the same way both redesigns always have (`currentURL`/
`secondaryURL`, `hasError`/`isPlaying`/`hasEnded`, track lists, rate-ramp/stall-tracking state — the
newly-primary stream inherits the secondary's always-already-1.0 rate, since the secondary slot
never ramps). Both streams keep playing/decoding uninterrupted throughout, so the transition is
instant. `VLCPlayerView.swapPrimaryAndSecondary()` then calls `AppState
.reanchorRecordingSeekForSwap(newPrimaryURL:)` (`recordingShowId` is derived from the URL/Show, not
swappable state, so `swapSlots()` deliberately leaves it alone),
`VLCPlayerWindowManager.swapTrackingFieldsForPiPSwap()` (also updates the window's own `.title` to
the newly-primary stream's — found live 2026-09-19 that the title previously stayed whatever the
window opened with, regardless of any later swap), and sets final per-slot volumes (live changes on
already-active players, not part of any mute-before-play dance — there's no reconnect for that
dance to apply to). `swapPrimaryAndSecondary()` also resets `selectedAudioTrackId`/
`selectedSpuTrackId`/`spuChoiceIsExplicit` and `selectedChannel` (via `suppressNextChannelPlay`/
`suppressSameContent` so `.onChange(of: selectedChannel)`'s own handler treats the `nil` as a no-op,
not a real channel switch) — otherwise the toolbar's pickers keep describing the pre-swap primary;
`nil` rather than resolving the new primary's actual `LineupEntry` since this view's own `device`/
`lineup` stay bound to whichever device the window originally opened on, so a cross-device swap (the
secondary can be on a different tuner) has no correct entry to resolve against this view's lineup at
all — `nil` is the safe "don't show a wrong channel" choice for both the same- and cross-device
case alike. In practice the existing `.onChange(of: state.vlcCurrentURL)` → `syncChannel()` path
(driven by `currentURL` itself changing) re-resolves `selectedChannel` correctly right afterward for
a same-device swap (confirmed live: swapping in a Watch Now relay resynced the picker to its
synthetic "Live" entry). **A cross-device swap landing on a FEED is now also labeled correctly**
(fixed 2026-09-19, found live: swapping in a Mac Mini FEED from a laptop Watch Now window left the
channel picker showing the plain favorites/rest list with nothing selected) via `feedChannelEntry`/
`syncChannel()`'s matching branch for it — see `feedChannelEntry`'s own doc comment. The
matching/label logic is a pure function, `feedChannelEntry(remoteURL:remoteRelayEntries:)` — unit
tested in `Tests/hdhr_VCRTests/Views/VLCPlayerViewFeedChannelEntryTests.swift`.

**A cross-device swap landing on a plain live channel or a recording relay is now labeled correctly
too** (fixed 2026-09-26, live report: the info banner showed "Unknown" and the picker stayed blank
indefinitely — `watchAsSecondary`'s device picker and `watchRecordingInAppAsSecondary` both allow a
PiP secondary on a *different* device than the window's own bound `device`, and neither case had a
`syncChannel()` branch for it before this). The live-channel case looks up the swapped-in device's
own lineup directly (`state.lineups[otherDeviceId]`, matched by `.urlBase`) rather than this view's
own `lineup`, gated only on `otherDeviceId != device.DeviceID` — **not** also on
`!device.isVirtualRelay` (a first version of this fix added that redundant extra check and shipped
broken, confirmed via the laptop's own log: watching a Mac Mini FEED with a real channel swapped in
as primary via PiP logged `swapSlots()` → `syncChannel: <real channel URL>` → `"no match in 1-entry
lineup"` — the FEED window's own `device` *is* the virtual relay, so `!device.isVirtualRelay` blocked
this exact case; `otherDeviceId != device.DeviceID` alone already correctly excludes an
untouched-FEED-primary, since `currentDeviceID` still equals `device.DeviceID` then); the recording case now matches `bridge.recordingShowId` against *all*
`state.recordingShows` instead of only the ones filtered to this window's `device`
(`recordingChannelEntries` itself, used by the picker's own "Live" rows, stays device-filtered — the
fix is in `syncChannel()`'s lookup only, via the newly-extracted `liveRecordingEntry(for:)`, which
both now share). This is still narrowly scoped to *labeling what's already playing*, not full
re-scoping: the rest of a cross-device swap's toolbar (the channel list itself still only ever lists
`device`'s own lineup, so you can't pick a *different* channel on the swapped-in device from here)
remains a known deeper limitation of this view's per-window device binding. Unlike the old reconnect-based version, this does
**not** reset `posterHidden`/`posterNSImage` — the newly-primary stream was already playing with its
poster long since dismissed, and forcing it back to `false` would wrongly show a Start-gate poster
over an already-live stream. (The `.onChange(of: selectedChannel)` reuse-without-a-fresh-`.onAppear`
trap that reset applied to for a *reconnect* doesn't apply here, since nothing reconnects.)

**Tuner occupancy**: a secondary stream watching a real live-tuner channel occupies a tuner exactly
like the primary would (`AppState.secondaryVlcOccupiesTuner`, summed into `activeTunerCount`); a
secondary FEED or Watch-Now relay does not, matching the primary's own `vlcOccupiesTuner` rule.

**Selecting which device/tuner becomes the secondary**: there's no tuner picker — selection is
implicit in which "Watch alongside (PiP)" button you click. Recording Now and "Recording on
Another Mac" (FEED) menu rows each get one (any device), and `WatchNowView`'s per-channel rows get
one too (any live channel on whichever device its own tuner `Picker` currently has selected) — see
`docs/WatchNowView.md`'s action-row entry. Matches this app's existing device-only (never per-port)
tuner addressing — there's no way to pick "tuner0 vs tuner1" on the same multi-tuner device, for
the secondary any more than for the primary.

**Positioning the thumbnail** (`pipCorner`, `@AppStorage("vlcPipCorner")`, persisted like `volume`):
right-clicking the thumbnail shows `pipCornerMenu` — four corners (`PipCorner.allCases`), a
checkmark on whichever is currently in effect. `pipOverlay`'s `VStack`/`HStack` conditionally place
a `Spacer()` before or after the thumbnail based on `pipCorner.isTop`/`.isLeading` rather than a
fixed `alignment:` — the same "pin to whichever edge" idiom already used for its own bottom-pinned
placement, just parameterized. No drag-and-drop — corner-only, chosen explicitly by the user.

**Changing the channel** (`pipChannelMenu`, same right-click menu as `pipCornerMenu` above, added
below a `Divider()`): only rendered when `VLCPlayerWindowManager.shared.secondaryChannelNumber !=
nil` — set only by `PiPPickerView`'s live-channel rows (`watchAsSecondary(channelNumber:)`), never
by `watchRemoteRelayAsSecondary`/`watchRecordingInAppAsSecondary`, so a FEED or Watch Now secondary
never shows a "Channel" submenu (neither has a lineup to switch within). Lists the secondary's own
device's lineup (`state.lineups[secondaryDeviceID]`, favorites first) — not necessarily the
primary's bound `device`, since a cross-device secondary is supported (see above). Picking a
channel calls `VLCPlayerView.playSecondaryChannel(_:deviceId:)`, which reconnects just the
secondary player (`VLCBridge.play(url:slot:.secondary)` — the primary is completely unaffected) and
updates `VLCPlayerWindowManager.retuneSecondary(channelNumber:title:)` so a later tap-to-swap
inherits the channel actually playing now, not whichever one the PiP was originally opened with.
No tuner-availability re-check — same-device channel switches reuse the existing slot/connection,
mirroring the primary toolbar channel picker's own "switching within an already-open player on the
same device skips the check" rule (see `AppState.watchInApp`'s tuner-availability note above).

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

**`playerWindowDidClose()`**: called by `WindowCloseObserver.windowWillClose`. Calls `appState?.cancelYieldRecordingIfInProgress()` first, added 2026-09-11 — the window closing mid-wait means the user no longer wants playback reopened once the yield-to-record flow's recording actually starts; the recording itself (if already scheduled/started by this point) is left alone, this only stops the flow from later calling `watchRecordingInApp` and silently reopening a window the user just closed. Then calls `VLCBridge.shared.stopDeviceChangeMonitoring()` — `windowWillClose` fires before `onDisappear`, so without this the CoreAudio device-change listener would fire callbacks into a partially torn-down view. Then calls `VLCBridge.shared.releasePlayer()` (full teardown — releases `mediaPlayer` so the tuner is freed immediately; also nils `currentURL`, which triggers the Combine chain in `AppState` to clear `vlcCurrentURL` automatically), removes the key-event monitor installed in `open()` (see "Fullscreen and keyboard shortcuts" below) via `NSEvent.removeMonitor(_:)`, clears `currentDeviceID`, sets `window = nil`, releases the VLC sleep assertion immediately via `appState?.recordingManager.releaseAssertion(id: "vlc")` (rather than waiting for `refreshTunerOccupancy()`'s own `releaseAllAssertions()`, which is blocked while a recording is simultaneously active), calls `appState?.releaseRecordingRelayIfNeeded()`, and calls `appState?.refreshTunerOccupancy()` so the menu header reflects the freed tuner within ~1.5 s. No explicit `vlcCurrentURL = ""` needed — the Combine sink handles it. The `appState` weak reference is set in `open()` and persists for the window lifetime.

### Fullscreen and keyboard shortcuts

Added 2026-08-21, alongside the toolbar labels and window-width bump above.

**True fullscreen**: `open()`'s new-window branch inserts `.fullScreenPrimary` into the window's `collectionBehavior` right after creating it. That alone is enough to opt a resizable `NSWindow` into native macOS fullscreen — hovering the green traffic-light button now shows the expand-arrows icon, and both it and the system-standard Cmd+Ctrl+F shortcut enter a true fullscreen Space (not just a maximized window), with zero other code required to *enter* it. **Exiting via Esc**, though, is not something AppKit binds automatically for a fullscreen window — that's what the key monitor below adds.

**Toolbar hides in fullscreen, reveals on hover-near-top** (fixed 2026-08-22, reported from live use the day fullscreen shipped): left as an always-visible top row in fullscreen, the toolbar visually competed with macOS's own top-of-screen hover-reveal menu bar for the same real estate — both sit at the top edge of a fullscreen Space. `body`'s `if !isFullScreen { toolbar }` (a normal top-row `VStack` child, unchanged from before fullscreen existed) becomes, while `isFullScreen`, a floating overlay *inside* the video `ZStack` instead — `VStack(spacing: 0) { toolbar.onHover { toolbarHovered = $0 }; Spacer() }`, opacity gated on `toolbarHovered`. Same "hidden view can still be hovered into, opacity alone doesn't disable hit-testing" trick the recording scrub bar overlay already uses at the bottom edge (see below), just mirrored to the top and scoped to `toolbar`'s own rect specifically (not the whole video) via `.onHover` sitting on `toolbar` itself rather than the wrapping `VStack` — only moving the cursor up near the very top reveals it, matching how the system's own menu bar behaves in fullscreen, not a hover anywhere over the video. `isFullScreen` is `@State`, driven by `.onReceive(.vlcFullScreenChanged)` — a notification `WindowCloseObserver`'s two new `NSWindowDelegate` methods (`windowDidEnterFullScreen`/`windowDidExitFullScreen`) post, covering every entry/exit path (green-button hover, Cmd+Ctrl+F, or this file's own Esc handler) uniformly, since they all funnel through the same delegate callbacks regardless of trigger. Windowed mode is completely unaffected — the toolbar stays exactly the always-visible top row it always was.

**Covered by the native title-bar reveal strip** (found live 2026-08-22, same day the above shipped): true `NSWindow` fullscreen still auto-reveals the window's own native title bar (traffic lights + title) as a system-drawn overlay when the cursor nears the top — that overlay draws *above* app content, so the toolbar above, placed right at the ZStack's own top edge, rendered underneath it instead of being visible ("the bar shows up, but it's mostly empty" — that empty bar was the native strip, not this toolbar). Fix: `Self.fullScreenTopInset` (`private static let CGFloat = 32`) pushes the toolbar's visible position down by roughly a title-bar's height so it clears the native strip instead of sitting behind it. Still an estimate — macOS doesn't expose the reveal strip's actual height as an API.

**Hover zone has to cover the inset too, not just the toolbar's own pixels** (found live 2026-08-22, round two — the first fix alone made the toolbar not show up *at all*): the first version applied `fullScreenTopInset` as `.padding(.top:)` on the wrapping `VStack` but left `.onHover` on `toolbar` alone — so the toolbar's *hoverable* rect moved down with the offset too, and hovering at the actual top edge (the natural place to check, and where the native reveal also triggers) hit nothing but empty padding. Fixed by grouping `Color.clear.frame(height: fullScreenTopInset)` + `toolbar` into their own inner `VStack`, giving that group `.contentShape(Rectangle())` (makes the whole band — including the empty padding — hit-testable, not just where `toolbar` draws actual pixels) and moving `.onHover`/`.opacity` onto that group instead of `toolbar` alone. The outer `Spacer()` filling the rest of the video stays outside this hover-scoped group, so hovering anywhere else on the video still does nothing — matches the same "only the intended band, not the whole video" scoping the original design called for.

**Arrow-key seek + Esc-to-exit-fullscreen** (`VLCPlayerWindowManager.installKeyMonitor(for:)`, called once from `open()`'s new-window branch, torn down in `playerWindowDidClose()`): a single `NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp])` monitor, scoped by comparing `event.window === win` so it can never act on a keystroke meant for some other window (e.g. Settings) that happens to be key at the same moment a recording is playing elsewhere. Deliberately a local NSEvent monitor rather than a SwiftUI `.onKeyPress` — the latter is at the mercy of which toolbar control (a `Picker`, the volume `Slider`) currently holds keyboard focus, where a monitor intercepts the key event regardless of focus, then explicitly re-emits it (`return event`, not `nil`) for anything it doesn't act on so normal focus-driven behavior (e.g. arrow keys nudging a focused slider) is untouched.

- **Left arrow / right arrow**: only acts while `VLCBridge.shared.recordingShowId != nil` (an on-disk recording, actually seekable) — passed through untouched for a live channel, which has no seek concept. `-15`/`+30` per press — asymmetric on purpose: catching up 30s past a distraction is more common than needing a deep rewind, and 15s is usually enough to recover a missed line.
  - **Debounced on keyUp, not committed per keyDown** (fixed 2026-08-22 — see `issues_resolved.md`): each keyDown only accumulates into `pendingSeekDelta`; the actual reconnect (`seekRecordingRelative(_:)`) fires once, on keyUp, with the accumulated total. The first shipped version committed a full relay reconnect on every keyDown — harmless for one tap, but macOS's key-repeat fires a keyDown every ~100-300ms while a key is held, so holding the key hammered the relay with that many reconnect-and-rebuffer cycles a second, which read as repeated playback drops. Caught live: a burst of 6 reconnects in ~2 seconds, each landing ~15s earlier than the last. Mirrors the scrub-bar slider's own release-based commit (`onEditingChanged`, above) — accumulate locally while "held," commit once on release.
- **Escape**: only acts while `win.styleMask.contains(.fullScreen)` — calls `win.toggleFullScreen(nil)` to exit and consumes the event; passed through untouched otherwise (e.g. so Esc can still dismiss a popover normally). Stays keyDown-only — no debounce needed for a single toggle.

`seekRecordingRelative(_ delta:)` reuses the exact same commit path the scrub-bar drag already uses (`AppState.seekRecording(showId:toSeconds:)` — see "Recording scrub overlay" above), just computing the target from `VLCBridge.shared.recordingPlaybackSeconds + delta` (clamped to `0...elapsed`, `elapsed` from `bridge.recordingStartDate` the same way the scrub bar computes it) instead of an absolute slider position — so a keyboard seek and a mouse-drag seek can never disagree about how a recording's position is estimated or committed. Because nothing reconnects mid-hold, `recordingPlaybackSeconds` keeps advancing naturally off the *still-live* connection for the whole hold, so it's still the correct base to add the accumulated `pendingSeekDelta` to once keyUp finally commits.

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

1080×600 pt (widened from 960×600 on 2026-08-21 — see "Fullscreen and keyboard shortcuts" below for the rest of that pass). Resizable, titled, closable, miniaturizable. The width gives the toolbar enough room to show all pickers — plus the text labels added to the previously icon-only quick-record/native-resolution/catch-up/screen buttons — without truncation at typical VLC stream resolutions. The video surface itself has no fixed size anywhere in the layout (`VLCVideoSurface().frame(maxWidth: .infinity, maxHeight: .infinity)` inside the toolbar's sibling `ZStack`), so it always fills whatever space AppKit gives the window on resize — libvlc aspect-fits the picture into that NSView's current bounds on every frame, the same way the poster overlay already scales proportionally with the window (see "Layout" above). Dragging the window bigger or smaller, and entering/exiting fullscreen, both just resize that same NSView — there's no separate zoom/crop state elsewhere that resizing could reset.

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

## AppState.watchAsSecondary

The picture-in-picture counterpart to `watchInApp`/`watchRemoteRelay`/`watchRecordingInApp` above —
see the "Picture-in-picture" section earlier in this doc for the full design. `watchAsSecondary(url
:title:device:channelNumber:)` requires `hasPlayablePrimarySession` (a primary session already
open) and lands on `VLCPlayerWindowManager.openSecondary(...)` instead of `open(...)`, so it becomes
the muted corner thumbnail rather than replacing whatever's primary. `watchRemoteRelayAsSecondary`
and `watchRecordingInAppAsSecondary` are thin wrappers resolving a FEED/local-recording URL to its
correct relay form first, mirroring `watchRemoteRelay`/`watchRecordingInApp`'s own URL construction,
then handing off to `watchAsSecondary`. A genuine live-tuner URL runs the same `tunerAvailable`
gate `watchInApp` uses, since a secondary real-tuner stream occupies a tuner exactly like the
primary would.

**Refuses to duplicate the primary, added 2026-09-19** — reported live: watching the same show/
channel in both the primary window and the PiP thumbnail was still reachable from every "Watch
alongside (PiP)" entry point *except* `PiPPickerView` (which had already gained "dim and disable if
this is what's already playing" checks the same day — see its own doc comment). MenuContent's
Recording Now/FEED rows and `WatchNowView`'s per-channel rows all call straight through to
`watchAsSecondary`/`watchRemoteRelayAsSecondary`/`watchRecordingInAppAsSecondary` with no such
check, so any of them could still add a second, muted connection to content already playing full-
size. Each of the three now refuses at the top, before doing anything else (in
`watchRemoteRelayAsSecondary`'s case, before even starting the local relay session that duplicate
would have needed): `watchAsSecondary` compares device+channel for a live channel,
`watchRemoteRelayAsSecondary` compares the FEED's remote URL, `watchRecordingInAppAsSecondary`
compares `recordingShowId` — reusing `PiPPickerView.isCurrentLiveChannel`/`isCurrentFeed`/
`isCurrentRecording` directly rather than a second copy of the same comparisons, so the picker's
own dimming and this functional guard can never drift apart. Device+channel (not raw URL) for the
live-channel case specifically per explicit request — a transcode/query-param difference in the
URL shouldn't defeat the guard. `PiPPickerView.isCurrentRecording(recordingShowId:showId:)`/
`isCurrentLiveChannel(currentDeviceID:currentChannelNumber:targetDeviceID:targetChannelNumber:)`/
`isCurrentFeed(currentFeedRemoteURL:entryURL:)` are pure functions, unit tested in
`Tests/hdhr_VCRTests/Views/PiPPickerViewIsCurrentTests.swift` — including a real bug that testing
`isCurrentFeed` found the same day: a bare `currentFeedRemoteURL == entryURL` is `true` when both
are `nil` (no FEED playing, and a malformed lineup entry with no URL), which would have incorrectly
dimmed/disabled a row with nothing to do with what's playing. Fixed with an explicit
both-non-`nil` guard before comparing. The guard functions above are not independently unit
tested — they call straight into these already-tested comparisons against live
`VLCBridge.shared`/`VLCPlayerWindowManager.shared` state, and this suite deliberately doesn't
drive those real singletons directly (see `Tests/hdhr_VCRTests/Recording/TunerOccupancyTests.swift`'s
own comment on `VLCPlayerWindowManager.currentDeviceID` for the same scope boundary applied
elsewhere).

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

### Viewer-side decode is already hardware-accelerated for H.264

`VLCBridge`'s global libvlc init (`VLCBridge.swift`, the `libvlc_new` argv) never sets `--avcodec-hw` — only the two x264 GOP options (`--sout-x264-keyint`/`-min-keyint`, encode-side only, see `docs/VirtualTunerService.md`'s Phase 2 section) are passed. That leaves libvlc at its own default, `avcodec-hw=any` (confirmed via `vlc -p avcodec --advanced --help-verbose`), which attempts hardware decode whenever the codec/platform supports it. Live-verified 2026-09-04: playing a VideoToolbox-eligible source through the same untouched libvlc engine spawned `VTDecoderXPCService` (macOS's hardware VideoToolbox decode helper) — direct proof decode is running on the GPU/media engine, not the CPU, with no code change needed.

This applies to any H.264 stream the on-screen player receives — a source channel that's natively H.264, or a FEED transcoded server-side to H.264 (see `docs/VirtualTunerService.md`'s "H.264 option" and "In-player raw/H.264 toggle"). It does **not** apply to raw MPEG-2 playback — VideoToolbox cannot hardware-decode MPEG-2 on Apple Silicon at all (`VTIsHardwareDecodeSupported` returns `false`), a hardware/OS limitation independent of VLC or this app, so MPEG-2 decode is always software regardless. Encode is a separate story entirely: this VLC install has no hardware H.264 *encoder* module at all (see `TODO.md`'s "Virtual tuner relay transcode" item 3), so the server-side transcode step (`startTranscodeSession`) stays pure-software CPU work no matter what.
