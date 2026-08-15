import SwiftUI
import AppKit
import MediaPlayer

private extension Notification.Name {
    static let vlcChannelNext = Notification.Name("vlcChannelNext")
    static let vlcChannelPrev = Notification.Name("vlcChannelPrev")
}

// ── VLCVideoSurface ───────────────────────────────────────────────────────────
// Zero-overhead NSView that VLC renders video into.
// We call setDrawable() on the bridge (not updateNSView) so VLC keeps the view
// reference across channel switches — VLC holds a weak NSObject reference internally.

private struct VLCVideoSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = CGColor(gray: 0, alpha: 1)
        glog("[VLC] VLCVideoSurface.makeNSView — new drawable view=\(ObjectIdentifier(v))")
        VLCBridge.shared.setDrawable(v)
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// ── VLCPlayerView ─────────────────────────────────────────────────────────────
// SwiftUI content for the VLC player window.
// Hosted in an NSHostingView inside VLCPlayerWindowManager's NSWindow.

struct VLCPlayerView: View {
    @EnvironmentObject var state: AppState

    // The device whose lineup populates the channel picker.
    // Fixed at window-open time — no device switching in the player toolbar.
    let device: HDHRDevice
    // Stream URL active when the window opened; used to pre-select the channel picker.
    let initialURL: String

    @State private var selectedChannel: LineupEntry?
    @State private var suppressNextChannelPlay = false
    @State private var selectedAudioTrackId: Int32 = -1  // -1 = not yet loaded; set when audioTracks first appear
    @State private var selectedSpuTrackId:   Int32 = -1  // -1 = CC off (default)
    @AppStorage("vlcVolume") private var volume: Double = 50
    @State private var systemDevices: [(id: String, name: String)] = []
    @State private var selectedDevice: String = ""
    @State private var availableScreens: [NSScreen] = []
    @State private var posterHidden: Bool = false
    @State private var posterNSImage: NSImage? = nil
    @ObservedObject private var bridge = VLCBridge.shared
    @State private var bufferInfoHovered  = false
    @State private var nativeResHovered   = false
    @State private var scrubValue: Double = 0     // recording scrub bar — only meaningful while isScrubbing
    @State private var isScrubbing = false
    @State private var videoControlsHovered = false   // shows the recording scrub overlay on hover

    private var currentGuideEntry: GuideEntry? {
        guard let ch = selectedChannel else { return nil }
        let now = Date()
        return state.guideEntries(deviceId: device.DeviceID, channelNum: ch.GuideNumber)
            .first { $0.startDate <= now && $0.endDate > now }
    }

    private var lineup: [LineupEntry] {
        (state.lineups[device.DeviceID] ?? []).sorted {
            $0.GuideNumber.localizedStandardCompare($1.GuideNumber) == .orderedAscending
        }
    }

    // Favorites-first split for the channel picker below — same stable filter-partition
    // WatchNowView (favs/others, ~line 226) and the web Guide (favRows/otherRows,
    // WebServer.swift ~line 1556) already use, so all three surfaces agree on ordering.
    // Each half stays in `lineup`'s existing ascending-channel-number order.
    private var favoriteLineup: [LineupEntry] { lineup.filter(\.isFavorite) }
    private var otherLineup: [LineupEntry] { lineup.filter { !$0.isFavorite } }

    // MARK: - "Live" recording entries in the channel picker
    //
    // LineupEntry's Hashable/Equatable (AddShowView.swift) keys solely on GuideNumber, so a
    // synthetic entry must use a GuideNumber that can never collide with a real channel's — hence
    // the "live:" prefix — rather than reusing the show's actual channel number.
    private static let liveGuideNumberPrefix = "live:"

    private func showId(fromLiveGuideNumber guideNumber: String) -> String? {
        guard guideNumber.hasPrefix(Self.liveGuideNumberPrefix) else { return nil }
        return String(guideNumber.dropFirst(Self.liveGuideNumberPrefix.count))
    }

    // One synthetic row per show currently recording on this player's device — lets the picker
    // switch directly between simultaneous recordings via the relay (docs/WebServer.md), the same
    // way it switches between live channels.
    private var recordingChannelEntries: [LineupEntry] {
        state.recordingShows
            .filter { $0.hdhr_record == device.DeviceID }
            .sorted { $0.show_channel.localizedStandardCompare($1.show_channel) == .orderedAscending }
            .map { show in
                LineupEntry(GuideNumber: "\(Self.liveGuideNumberPrefix)\(show.show_id)",
                            GuideName: "Live \(show.show_channel)  \(show.show_title)",
                            URL: nil, HD: nil, Favorite: nil)
            }
    }

    // Media-key next/prev cycle order — recording rows first, then real channels in plain
    // ascending channel-number order. Deliberately NOT favorites-first like the picker's visual
    // order below: channel-up/down is a sequential-step gesture (user expects 5.1 → 5.2 → 6.1),
    // and reordering it to favorites-first would make each press jump unpredictably between a
    // favorite and its numeric neighbors instead of stepping through the dial in order.
    private var channelCycleOrder: [LineupEntry] { recordingChannelEntries + lineup }

    // HDHomeRun raw streams are always MPEG-2/AC-3; any transcode= param means H.264/AAC.
    private var inferredCodecs: (video: String, audio: String) {
        let url = bridge.currentURL ?? ""
        return url.contains("transcode=") ? ("H.264", "AAC") : ("MPEG-2", "AC-3")
    }

    private var canResizeToNative: Bool {
        bridge.videoPixelSize != nil && VLCPlayerWindowManager.shared.nativeVideoFitsCurrentScreen()
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ZStack {
                VLCVideoSurface()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !posterHidden && !bridge.hasError && !bridge.hasEnded {
                    posterOverlay
                        .transition(.opacity)
                }
                if bridge.hasError {
                    errorOverlay
                        .transition(.opacity)
                }
                if bridge.hasEnded {
                    endedOverlay
                        .transition(.opacity)
                }
                if posterHidden, !bridge.hasError, !bridge.hasEnded,
                   let showId = bridge.recordingShowId, let startDate = bridge.recordingStartDate {
                    VStack {
                        Spacer()
                        // .onHover sits after the outer padding so the whole margin around the bar
                        // is part of the hover target, not just the visible bar/background rect.
                        // Opacity (not allowsHitTesting) gates hover detection while hidden — a
                        // hidden view can still be hovered into, so this is how it reveals itself
                        // in the first place; there's no chicken-and-egg with hit-testing disabled.
                        recordingScrubBar(showId: showId, startDate: startDate)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                            .padding(20)
                            .opacity(videoControlsHovered ? 1 : 0)
                            .animation(.easeInOut(duration: 0.2), value: videoControlsHovered)
                            .onHover { videoControlsHovered = $0 }
                    }
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeOut(duration: 0.35), value: posterHidden)
            .animation(.easeOut(duration: 0.35), value: bridge.hasError)
            .animation(.easeOut(duration: 0.35), value: bridge.hasEnded)
            .animation(.easeInOut(duration: 0.2), value: bridge.recordingShowId)
            .task(id: currentGuideEntry?.ImageURL) {
                guard let url = currentGuideEntry?.ImageURL else { posterNSImage = nil; return }
                posterNSImage = await ChannelIconCache.shared.image(for: url)
            }
        }
        .onAppear {
            glog("[VLC] VLCPlayerView.onAppear device=\(device.DeviceID) initialURL=\(initialURL)")
            availableScreens = NSScreen.screens   // NSScreen.screens is main-thread-only; safe here
            VLCBridge.shared.liveMinRate = Float(state.config.Player_buffer_min_rate) / 100.0
            VLCBridge.shared.setVolume(0)   // muted until Start is clicked
            refreshAudioDevices()
            VLCBridge.shared.startDeviceChangeMonitoring { refreshAudioDevices() }
            syncChannel(to: initialURL)
            let cc = MPRemoteCommandCenter.shared()
            cc.stopCommand.isEnabled = true
            cc.stopCommand.addTarget { _ in
                // Remote stop (media key / Now Playing widget) — calls VLCBridge.stop(), a soft
                // stop that leaves drawableView attached so a later play() can resume in place.
                glog("[VLC] remote stopCommand received")
                Task { @MainActor in VLCBridge.shared.stop() }
                return .success
            }
            cc.nextTrackCommand.isEnabled = true
            cc.nextTrackCommand.addTarget { _ in NotificationCenter.default.post(name: .vlcChannelNext, object: nil); return .success }
            cc.previousTrackCommand.isEnabled = true
            cc.previousTrackCommand.addTarget { _ in NotificationCenter.default.post(name: .vlcChannelPrev, object: nil); return .success }
        }
        .onChange(of: state.vlcCurrentURL) { _, rawURL in
            // Sync picker when watchInApp is called while the window is already open.
            glog("[VLC] vlcCurrentURL changed → syncChannel: \(rawURL.isEmpty ? "(empty)" : rawURL)")
            syncChannel(to: rawURL)
        }
        .onChange(of: bridge.recordingShowId) { _, showId in
            // AppState.watchRecordingInApp defers setting this to the next run-loop turn, so the
            // very first syncChannel(to:) call (from .onAppear, in the same synchronous window-
            // open transaction) can run before it lands — re-sync once it does.
            guard showId != nil, let url = bridge.currentURL else { return }
            syncChannel(to: url)
        }
        .onChange(of: state.config.Player_buffer_min_rate) { _, pct in
            glog("[VLC] Player_buffer_min_rate changed → \(pct)%")
            VLCBridge.shared.liveMinRate = Float(pct) / 100.0
        }
        .onChange(of: bridge.audioTracks.count) { _, count in
            // When audio tracks first appear, sync picker to first track (VLC already plays it).
            guard count > 0, selectedAudioTrackId < 0 else { return }
            selectedAudioTrackId = bridge.audioTracks[0].id
        }
        .onChange(of: bridge.spuTracks.count) { _, count in
            // Explicitly disable CC on every channel load; some streams auto-enable it.
            guard count > 0 else { return }
            VLCBridge.shared.setSpuTrack(id: -1)
        }
        .onDisappear {
            // Safety-net for window close — releasePlayer() is idempotent so calling it here
            // after playerWindowDidClose() already ran is fine. Catches any path where the
            // window delegate didn't fire (e.g. window deallocated without close()).
            glog("[VLC] VLCPlayerView.onDisappear")
            VLCBridge.shared.releasePlayer()
            VLCBridge.shared.stopDeviceChangeMonitoring()
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState  = .stopped
            let cc = MPRemoteCommandCenter.shared()
            cc.stopCommand.removeTarget(nil)
            cc.nextTrackCommand.removeTarget(nil)
            cc.previousTrackCommand.removeTarget(nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .vlcChannelNext)) { _ in
            // channelCycleOrder (recording rows + real channels) matches the picker's own display
            // order, so media-key next/prev also cycles through "Live" recording entries — not
            // just real channels, which would otherwise leave next/prev dead while on one of them.
            let order = channelCycleOrder
            guard let ch = selectedChannel,
                  let idx = order.firstIndex(where: { $0.GuideNumber == ch.GuideNumber }) else { return }
            selectedChannel = order[idx < order.count - 1 ? idx + 1 : 0]
        }
        .onReceive(NotificationCenter.default.publisher(for: .vlcChannelPrev)) { _ in
            let order = channelCycleOrder
            guard let ch = selectedChannel,
                  let idx = order.firstIndex(where: { $0.GuideNumber == ch.GuideNumber }) else { return }
            selectedChannel = order[idx > 0 ? idx - 1 : order.count - 1]
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            availableScreens = NSScreen.screens
        }
    }

    // MARK: - Poster overlay

    private var posterOverlay: some View {
        let entry = currentGuideEntry
        return ZStack {
            Color.black

            HStack(alignment: .center, spacing: 24) {
                // Poster image
                Group {
                    if let img = posterNSImage {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image(systemName: "tv")
                            .font(.system(size: 48))
                            .foregroundStyle(.white.opacity(0.25))
                    }
                }
                .containerRelativeFrame(.horizontal) { w, _ in w * 0.30 }
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Episode info + synopsis
                VStack(alignment: .leading, spacing: 8) {
                    if let entry {
                        Text(entry.Title)
                            .font(.title2.bold())
                            .foregroundStyle(.white)
                            .lineLimit(2)

                        let epNum   = entry.EpisodeNumber
                        let epTitle = entry.EpisodeTitle
                        switch (epNum, epTitle) {
                        case (let n?, let t?):
                            Text("\(n)  \(t)")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.75))
                                .lineLimit(1)
                        case (let n?, nil):
                            Text(n)
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.75))
                        case (nil, let t?):
                            Text(t)
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.75))
                                .lineLimit(1)
                        case (nil, nil):
                            EmptyView()
                        }

                        if let synopsis = entry.Synopsis, !synopsis.isEmpty {
                            Text(synopsis)
                                .font(.callout)
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Button {
                        let lag = VLCBridge.shared.bufferInfo.lagSec
                        glog("[VLC] Start clicked — buffer ~\(String(format: "%.1f", lag))s built before unmute")
                        posterHidden = true
                        VLCBridge.shared.setVolume(Int(volume))
                    } label: {
                        HStack(spacing: 8) {
                            if bridge.isPlaying {
                                Image(systemName: "play.fill")
                            } else {
                                ProgressView().controlSize(.small)
                            }
                            Text(bridge.isPlaying ? "Start" : "Connecting…")
                        }
                        .font(.title3.bold())
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(bridge.isPlaying ? .white : .white.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                    .disabled(!bridge.isPlaying)
                    .padding(.top, 4)
                }
                .frame(maxWidth: 360, alignment: .leading)
            }
            .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    // MARK: - Error overlay

    private var errorOverlay: some View {
        ZStack {
            Color.black.opacity(0.85)
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)
                Text("Stream Unavailable")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                if let host = bridge.currentURL.flatMap({ URL(string: $0)?.host }) {
                    Text(host)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                Button {
                    posterHidden = false
                    VLCBridge.shared.catchUpToLive()
                } label: {
                    overlayButtonLabel("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    // MARK: - Ended overlay

    // Shown when libvlc reaches EOF (state 6) — e.g. a finished recording relay read to its last
    // byte. Without this the player would just freeze on the final frame. Retry replays the current
    // URL from the top (for a relay that means from its seek anchor); for live it reconnects.
    private var endedOverlay: some View {
        ZStack {
            Color.black.opacity(0.85)
            VStack(spacing: 16) {
                Image(systemName: "stop.circle")
                    .font(.system(size: 44))
                    .foregroundStyle(.white.opacity(0.8))
                Text("Playback Ended")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                if let url = bridge.currentURL {
                    Button {
                        posterHidden = false
                        bridge.play(url: url)
                    } label: {
                        overlayButtonLabel("Play Again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    // Shared styling for the Retry/Play Again overlay buttons above — identical appearance, kept
    // as one helper so they can't visually drift apart.
    private func overlayButtonLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.callout.bold())
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(.white)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        let canResize = canResizeToNative
        // Glow when native is achievable but the window isn't already sized to it.
        let notAtNative = canResize && !VLCPlayerWindowManager.shared.isAtNativeResolution()
        return HStack(spacing: 10) {
            // Channel picker — sorted by guide number
            Picker("Channel", selection: $selectedChannel) {
                // Fallback: selected whenever selectedChannel is nil and nothing else matched
                // (shouldn't normally happen once recordingChannelEntries covers every relay
                // stream, but avoids ever rendering blank). Hidden entirely when nothing on this
                // device is recording — there's no "Live" to fall back to in that case.
                if !recordingChannelEntries.isEmpty {
                    Text("Live").tag(Optional<LineupEntry>.none)
                }
                // One row per show currently recording on this device — GuideName already holds
                // the full "Live 5.1  Title" label, so it's rendered directly (not the
                // "GuideNumber  GuideName" template below, which would show the synthetic tag).
                ForEach(recordingChannelEntries, id: \.GuideNumber) { entry in
                    Text(entry.GuideName).tag(Optional(entry))
                }
                // Favorites-first, matching WatchNowView's favTopBorder split and the web
                // Guide's favRows/otherRows — a labeled Section reads as the closest
                // Picker-compatible equivalent to those views' visual "★ Favorites" divider.
                if !favoriteLineup.isEmpty {
                    Section("★ Favorites") {
                        ForEach(favoriteLineup, id: \.GuideNumber) { ch in
                            Text("\(ch.GuideNumber)  \(ch.GuideName)").tag(Optional(ch))
                        }
                    }
                }
                ForEach(otherLineup, id: \.GuideNumber) { ch in
                    Text("\(ch.GuideNumber)  \(ch.GuideName)").tag(Optional(ch))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 220)
            .onChange(of: selectedChannel) { _, ch in
                posterHidden = false
                posterNSImage = nil
                VLCBridge.shared.setVolume(0)
                // Reset unconditionally, before the suppress check below — a synced (externally
                // triggered) channel switch still means the track list underneath genuinely
                // changed, even though suppressNextChannelPlay skips re-triggering playback here.
                // Resetting only on the non-suppressed path left the picker holding a stale track
                // id from the previous channel after a synced switch.
                selectedAudioTrackId = -1
                selectedSpuTrackId   = -1
                if suppressNextChannelPlay { suppressNextChannelPlay = false; return }
                guard let ch else { return }
                if let showId = showId(fromLiveGuideNumber: ch.GuideNumber) {
                    guard let show = state.shows.first(where: { $0.show_id == showId }) else { return }
                    state.watchRecordingInApp(show)
                } else {
                    playChannel(ch)
                }
            }

            Spacer()

            // Buffer monitor + catch-up: grouped into a single control unit when buffering is active.
            // Both relate to live-stream temporal state, so they share a pill background with a
            // hairline divider between them. Catch-up stands alone when buffering is disabled.
            if bridge.bufferInfo.enabled {
                HStack(spacing: 0) {
                    bufferMonitor
                        .padding(.trailing, 5)
                    Divider().frame(height: 14)
                    catchUpButton
                        .padding(.leading, 5)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            } else {
                catchUpButton
            }

            // Native resolution: resize window to 1:1 physical pixels.
            // Glows blue when native is achievable but the window isn't already there.
            Button {
                VLCPlayerWindowManager.shared.sizeToNativeVideo()
            } label: {
                Image(systemName: "aspectratio")
                    .foregroundStyle(notAtNative ? AnyShapeStyle(Color.accentColor) : canResize ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                    .shadow(color: notAtNative ? Color.accentColor.opacity(0.6) : .clear, radius: 5)
            }
            .buttonStyle(.plain)
            .disabled(!canResize)
            .onHover { if $0 { nativeResHovered = true } }
            .popover(isPresented: $nativeResHovered, arrowEdge: .bottom) { nativeResPopover }

            // Live wall-clock time. The recording scrub bar lives in a hover overlay on the video
            // instead (see body's ZStack) rather than here — it needs more room than this toolbar
            // has to spare alongside everything else.
            TimelineView(.periodic(from: .now, by: 1.0)) { ctx in
                Text(ctx.date, style: .time)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 70)
            }

            // Volume
            Image(systemName: "speaker.wave.2")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(value: $volume, in: 0...100)
                .frame(width: 100)
                .accessibilityLabel("Volume")
                .onChange(of: volume) { _, v in
                    VLCBridge.shared.setVolume(Int(v))
                }

            // Audio track picker — shown when the stream has more than one audio track
            if bridge.audioTracks.count > 1 {
                Divider().frame(height: 18)
                Image(systemName: "headphones")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Audio track")
                Picker("Audio Track", selection: $selectedAudioTrackId) {
                    ForEach(bridge.audioTracks, id: \.id) { track in
                        Text(track.name).tag(track.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 150)
                .onChange(of: selectedAudioTrackId) { _, id in
                    guard id >= 0 else { return }
                    VLCBridge.shared.setAudioTrack(id: id)
                }
            }

            // CC picker — shown only when closed-caption tracks are detected in the stream
            if !bridge.spuTracks.isEmpty {
                Divider().frame(height: 18)
                Image(systemName: "captions.bubble")
                    .foregroundStyle(selectedSpuTrackId >= 0 ? .primary : .secondary)
                    .accessibilityLabel("Closed captions")
                Picker("Captions", selection: $selectedSpuTrackId) {
                    Text("Off").tag(Int32(-1))
                    ForEach(bridge.spuTracks, id: \.id) { track in
                        Text(track.name).tag(track.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 130)
                .onChange(of: selectedSpuTrackId) { _, id in
                    VLCBridge.shared.setSpuTrack(id: id)
                }
            }

            // Audio output picker — all CoreAudio output devices (built-in, Bluetooth, AirPlay, USB)
            if !systemDevices.isEmpty {
                Divider().frame(height: 18)
                Image(systemName: "airplayaudio").foregroundStyle(.secondary)
                    .accessibilityLabel("Audio output")
                Picker("Audio Output", selection: $selectedDevice) {
                    ForEach(systemDevices, id: \.id) { dev in
                        Text(dev.name).tag(dev.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 200)
                .onChange(of: selectedDevice) { _, devId in
                    VLCBridge.shared.setAudioDevice(output: "auhal", deviceId: devId)
                }
            }

            // Screen picker — shown when a second display (including AirPlay) is available.
            // Connect an AirPlay display via Control Center → Screen Mirroring first.
            if availableScreens.count > 1 {
                Divider().frame(height: 18)
                Menu {
                    ForEach(availableScreens, id: \.displayID) { screen in
                        Button(screen.localizedName) {
                            VLCPlayerWindowManager.shared.moveToScreen(screen)
                        }
                    }
                } label: {
                    Image(systemName: "airplayvideo")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .frame(maxWidth: 24)
                .help("Move to display")
                .accessibilityLabel("Select display")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
        .onChange(of: bridge.bufferInfo.enabled) { _, enabled in
            if !enabled { bufferInfoHovered = false }
        }
        .onChange(of: bridge.isPlaying) { _, playing in
            if !playing { nativeResHovered = false }
        }
    }

    // MARK: - Recording scrub bar

    // Shown as a hover overlay on the video (see body's ZStack), not the toolbar — standard
    // video-player convention, and there's no room for it in the toolbar alongside everything
    // else. Labels use local clock time (when the show started / live edge right now) rather than
    // elapsed duration, since "started at 7:00 PM" reads more naturally than "0:00" for a
    // recording. The raw MPEG-TS file has no index, so this isn't a true libvlc time-based seek —
    // see VLCBridge.recordingPlaybackSeconds. Position ticks at wall-clock pace between scrubs; a
    // drag commits by reconnecting the relay at a new byte offset (AppState.seekRecording).
    private func recordingScrubBar(showId: String, startDate: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { ctx in
            let elapsed = max(1, ctx.date.timeIntervalSince(startDate))
            let display = min(isScrubbing ? scrubValue : VLCBridge.shared.recordingPlaybackSeconds, elapsed)
            VStack(spacing: 4) {
                Text(startDate.addingTimeInterval(display), style: .time)
                    .font(.caption.bold())
                    .monospacedDigit()
                    .foregroundStyle(.white)
                HStack(spacing: 8) {
                    Text(startDate, style: .time)
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.7))
                    Slider(value: Binding(get: { display }, set: { scrubValue = $0 }), in: 0...elapsed,
                           onEditingChanged: { editing in
                        if editing {
                            scrubValue  = display
                            isScrubbing = true
                        } else {
                            isScrubbing = false
                            state.seekRecording(showId: showId, toSeconds: scrubValue)
                        }
                    })
                    .accessibilityLabel("Recording position")
                    Text(ctx.date, style: .time)
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
    }

    // MARK: - Buffer monitor

    private var catchUpButton: some View {
        // For a recording-relay session, VLCBridge.catchUpToLive() alone just replays the current
        // URL verbatim — reconnecting at the same stale &start= byte offset, doing nothing toward
        // "live". AppState.seekRecordingToLiveEdge computes a fresh near-live-edge offset instead.
        Button {
            if let showId = bridge.recordingShowId {
                state.seekRecordingToLiveEdge(showId: showId)
            } else {
                VLCBridge.shared.catchUpToLive()
            }
        } label: {
            Image(systemName: "forward.end.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(bridge.recordingShowId != nil
              ? "Jump to the live edge of the recording"
              : "Speed up to live — discard buffer and jump to live edge")
    }

    private var bufferMonitor: some View {
        let info = bridge.bufferInfo
        let fill = min(1.0, info.lagSec / 8.0)
        let barColor: Color = fill > 0.875 ? .green : .accentColor
        return HStack(spacing: 4) {
            Image(systemName: "waveform")
                .font(.caption2)
                .foregroundStyle(barColor.opacity(0.9))
                .accessibilityHidden(true)
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.18))
                Capsule().fill(barColor.opacity(0.85))
                    .frame(width: max(3, 50 * fill))
            }
            .frame(width: 50, height: 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live buffer")
        .accessibilityValue("\(min(8, Int(info.lagSec.rounded()))) of 8 seconds")
        .onHover { if $0 { bufferInfoHovered = true } }
        .popover(isPresented: $bufferInfoHovered, arrowEdge: .bottom) { bufferPopover }
    }

    private var bufferPopover: some View {
        let info = bridge.bufferInfo
        let pct  = Int((min(info.lagSec, 8.0) / 8.0 * 100).rounded())
        return VStack(alignment: .leading, spacing: 5) {
            Text("Live Buffer").font(.subheadline.bold())
            Divider()
            row("Lag",       String(format: "%.1fs / 8s  (%d%%)", info.lagSec, pct))
            row("Rate",      String(format: "%.3f×", info.rate))
            if info.demuxBitrate > 0 {
                row("Bitrate", String(format: "%.0f kB/s", info.demuxBitrate))
            }
            row("Corrupted", "\(info.corrupted)")
        }
        .padding(12)
        .frame(minWidth: 210)
        .font(.caption)
    }

    private var nativeResPopover: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Native Resolution").font(.subheadline.bold())
            Divider()
            if let px = bridge.videoPixelSize {
                let scale = VLCPlayerWindowManager.shared.currentScreenScale
                let logW  = Int(px.width  / scale)
                let logH  = Int(px.height / scale)
                let (vid, aud) = inferredCodecs
                row("Resolution", "\(Int(px.width))×\(Int(px.height)) px")
                row("Display",    "\(logW)×\(logH) pt @ \(String(format: "%.0f", scale))×")
                row("Video",      vid)
                row("Audio",      aud)
                if !VLCPlayerWindowManager.shared.nativeVideoFitsCurrentScreen() {
                    Divider()
                    Label("Too large for current display", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            } else {
                Text("No video decoded yet")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(minWidth: 200)
        .font(.caption)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }

    // MARK: - Helpers

    private func syncChannel(to url: String) {
        guard !url.isEmpty else { return }
        let base = url.urlBase
        // Recording-relay stream: match against this device's currently-recording shows instead
        // of the lineup — the relay URL (docs/WebServer.md) never matches a real channel URL.
        // AppState.watchRecordingInApp defers setting bridge.recordingShowId to the next run-loop
        // turn (see its comment — a SwiftUI render-timing fix), so this can miss on the very first
        // call from .onAppear; the .onChange(of: bridge.recordingShowId) handler below re-runs it
        // once that lands.
        if base.contains("/api/watch-recording"), let showId = bridge.recordingShowId,
           let entry = recordingChannelEntries.first(where: { self.showId(fromLiveGuideNumber: $0.GuideNumber) == showId }) {
            glog("[VLC] syncChannel matched recording \(entry.GuideName) for url=\(base)")
            MPNowPlayingInfoCenter.default().nowPlayingInfo = [
                MPMediaItemPropertyTitle:             entry.GuideName,
                MPMediaItemPropertyArtist:            "Live",
                MPNowPlayingInfoPropertyIsLiveStream: true
            ]
            MPNowPlayingInfoCenter.default().playbackState = .playing
            guard selectedChannel?.GuideNumber != entry.GuideNumber else { return }
            suppressNextChannelPlay = true
            selectedChannel = entry
            return
        }
        if let match = lineup.first(where: { ($0.URL ?? "").hasPrefix(base) || base.hasPrefix($0.URL ?? "") }) {
            glog("[VLC] syncChannel matched \(match.GuideNumber) \(match.GuideName) for url=\(base)")
            updateNowPlaying(channel: match)
            // Only suppress and update picker if the channel is actually changing — if it's
            // already selected, setting it again won't fire onChange, leaving suppress=true
            // and swallowing the next user-initiated picker selection.
            guard selectedChannel?.GuideNumber != match.GuideNumber else { return }
            suppressNextChannelPlay = true
            selectedChannel = match
        } else {
            glog("[VLC] syncChannel no match in \(lineup.count)-entry lineup for url=\(base)", level: .warning)
        }
    }

    private func playChannel(_ ch: LineupEntry) {
        guard let rawURL = ch.URL, !rawURL.isEmpty else {
            glog("[VLC] playChannel skipped — no URL for ch=\(ch.GuideNumber) \(ch.GuideName)", level: .warning)
            return
        }
        // VLC handles MPEG-2 natively — no forced transcode; "none" = raw stream
        let url = state.config.applyTranscode(rawURL)
        glog("[VLC] playChannel \(ch.GuideNumber) \(ch.GuideName) → \(url)")

        // Start buffering immediately — the poster overlay is visible so the user
        // hasn't clicked Start yet; we want the buffer building the whole time they
        // are reading the poster info. VLCBridge.play() resets estimatedLagSec=0 and
        // rate=minRate, so the rate controller begins filling the buffer right away.
        VLCBridge.shared.play(url: url)
        updateNowPlaying(channel: ch)
        state.refreshTunerOccupancy()

        // Check tuner occupancy in the background — stream is already started, this
        // is for logging and a non-blocking warning if we appear to be over capacity.
        Task {
            guard let statusURL = URL(string: device.statusURL),
                  let (data, _) = try? await URLSession.shared.data(from: statusURL),
                  let tuners = try? JSONDecoder().decode([DeviceTunerInfo].self, from: data) else { return }
            let tunerCount  = device.TunerCount ?? 2
            let active      = tuners.filter { $0.VctNumber != nil }.count
            let weActive    = VLCBridge.shared.currentURL != nil ? 1 : 0
            let otherActive = active - weActive
            glog("[VLC] post-switch tuner status ch \(ch.GuideNumber): \(active)/\(tunerCount) active (ours=\(weActive) other=\(otherActive))")
            if otherActive >= tunerCount {
                glog("[VLC] WARNING: all \(tunerCount) tuner(s) appear occupied by other streams — stream may have been rejected", level: .warning)
            }
        }
    }

    private func updateNowPlaying(channel: LineupEntry) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle:             channel.GuideName,
            MPMediaItemPropertyArtist:            "Ch \(channel.GuideNumber)",
            MPNowPlayingInfoPropertyIsLiveStream: true
        ]
        MPNowPlayingInfoCenter.default().playbackState = .playing
    }

    private func refreshAudioDevices() {
        systemDevices = VLCBridge.shared.systemAudioOutputDevices()
        guard !systemDevices.isEmpty else { return }
        // Pre-select system default; fall back to first device if default isn't in the list.
        if selectedDevice.isEmpty || !systemDevices.contains(where: { $0.id == selectedDevice }) {
            let uid = VLCBridge.shared.systemDefaultOutputUID() ?? systemDevices[0].id
            selectedDevice = uid
            VLCBridge.shared.setAudioDevice(output: "auhal", deviceId: uid)
        }
    }
}

// ── VLCPlayerWindowManager ────────────────────────────────────────────────────
// Singleton NSWindow manager. Keeps one reusable window alive (isReleasedWhenClosed
// = false) so re-opening doesn't create a second window.

@MainActor
final class VLCPlayerWindowManager {
    static let shared = VLCPlayerWindowManager()
    private var window: NSWindow?
    private var closeObserver: WindowCloseObserver?  // strong ref — NSWindow.delegate is weak

    /// DeviceID of the tuner currently occupied by the player window; nil when closed.
    private(set) var currentDeviceID: String?
    /// GuideNumber of the channel `open()` was last called with; nil when closed or when the
    /// caller didn't pass one (e.g. the watch-recording relay, which occupies no tuner at all —
    /// see AppState.vlcOccupiesTuner). Lets AppState.vlcLiveChannel(for:) tell "this app is live-
    /// watching this exact channel" apart from "some other tuner on this device is in use", so the
    /// in-use-by-other-tuner marker doesn't flag your own live Watch session as someone else's.
    private(set) var currentChannelNumber: String?
    private weak var appState: AppState?

    private init() {}

    /// Bring the player window to the front without switching the stream.
    func focus() {
        guard let win = window else { return }
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    /// Close the player window if it is currently playing the given show — either its raw tuner
    /// stream URL, or (Watch Now! relay playback) VLCBridge.recordingShowId matching the show's ID,
    /// since the relay plays a local /api/watch-recording URL that never equals show_url.
    func closeIfPlaying(showId: String, url: String) {
        let matchesURL   = !url.isEmpty && VLCBridge.shared.currentURL?.urlBase == url
        let matchesRelay = !showId.isEmpty && VLCBridge.shared.recordingShowId == showId
        guard matchesURL || matchesRelay else { return }
        window?.close()   // triggers windowWillClose → playerWindowDidClose
    }

    /// Open (or bring forward) the player window and start playing url on device.
    /// If the window is already showing, the stream is switched immediately.
    func open(url: String, title: String, device: HDHRDevice, appState: AppState, channelNumber: String? = nil) {
        self.appState = appState
        currentDeviceID = device.DeviceID
        currentChannelNumber = channelNumber
        VLCBridge.shared.liveMinRate = Float(appState.config.Player_buffer_min_rate) / 100.0
        VLCBridge.shared.setVolume(0)   // mute before buffering starts; Start click unmutes
        VLCBridge.shared.ensurePlayer() // create fresh player if previous session released it
        VLCBridge.shared.play(url: url)

        if let win = window {
            glog("[VLC] WindowManager.open — reusing existing window, title=\(title)")
            win.title = title
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        glog("[VLC] WindowManager.open — creating new window, device=\(device.DeviceID) url=\(url)")

        let playerView = VLCPlayerView(device: device, initialURL: url)
            .environmentObject(appState)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = title
        win.contentView = NSHostingView(rootView: playerView)
        win.isReleasedWhenClosed = false   // retain for reuse on next open()
        let observer = WindowCloseObserver(manager: self)
        closeObserver = observer
        win.delegate = observer
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
    }

    /// Move the player window to the centre of the given screen (handles AirPlay displays).
    func moveToScreen(_ screen: NSScreen) {
        guard let win = window else { return }
        // setFrameOrigin is silently ignored while miniaturized; deminiaturize first.
        if win.isMiniaturized { win.deminiaturize(nil) }
        let sf = screen.visibleFrame
        let wf = win.frame
        // Clamp so the window can't be placed off-screen when it's larger than the target display.
        let x = max(sf.minX, sf.minX + (sf.width  - wf.width)  / 2)
        let y = max(sf.minY, sf.minY + (sf.height - wf.height) / 2)
        win.setFrameOrigin(NSPoint(x: x, y: y))
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Backing scale of the screen the player window is on (falls back to main screen).
    var currentScreenScale: CGFloat {
        window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
    }

    /// True when the window's content area already matches the stream's 1:1 pixel size.
    func isAtNativeResolution() -> Bool {
        guard let px = VLCBridge.shared.videoPixelSize,
              let win = window,
              let content = win.contentView?.frame.size else { return false }
        let scale = win.screen?.backingScaleFactor ?? currentScreenScale
        return abs(content.width  - px.width  / scale)      < 1 &&
               abs(content.height - px.height / scale - 44) < 1
    }

    /// True when the stream's native resolution fits within the current display's visible frame
    /// (accounting for the 44pt toolbar added by sizeToNativeVideo).
    func nativeVideoFitsCurrentScreen() -> Bool {
        guard let px = VLCBridge.shared.videoPixelSize,
              let screen = window?.screen ?? NSScreen.main else { return true }
        let scale = screen.backingScaleFactor
        return px.width  / scale <= screen.visibleFrame.width &&
               px.height / scale + 44 <= screen.visibleFrame.height
    }

    /// Resize the window so the video surface is displayed at 1:1 physical pixels.
    func sizeToNativeVideo() {
        guard let win = window,
              let pixels = VLCBridge.shared.videoNativeSize() else { return }
        let scale   = win.screen?.backingScaleFactor ?? 2.0
        let videoW  = pixels.width  / scale
        let videoH  = pixels.height / scale
        let toolbar = CGFloat(44)   // fixed: toolbar padding 8+8 + row ~26pt
        win.setContentSize(CGSize(width: videoW, height: videoH + toolbar))
        win.center()
    }

    fileprivate func playerWindowDidClose() {
        glog("[VLC] WindowManager.playerWindowDidClose")
        // Stop audio listener before releasing the player — windowWillClose fires before onDisappear,
        // so without this the CoreAudio callback fires into a partially torn-down view.
        VLCBridge.shared.stopDeviceChangeMonitoring()
        VLCBridge.shared.releasePlayer() // full teardown — releases mediaPlayer and nils currentURL; Combine auto-clears vlcCurrentURL
        currentDeviceID = nil
        currentChannelNumber = nil
        window = nil
        // Release the VLC sleep assertion immediately rather than waiting for releaseAllAssertions()
        // inside refreshTunerOccupancy — that path is blocked when a recording is simultaneously active.
        appState?.recordingManager.releaseAssertion(id: "vlc")
        appState?.releaseRecordingRelayIfNeeded()
        appState?.refreshTunerOccupancy()
    }
}

private final class WindowCloseObserver: NSObject, NSWindowDelegate {
    weak var manager: VLCPlayerWindowManager?
    init(manager: VLCPlayerWindowManager) { self.manager = manager }
    func windowWillClose(_ notification: Notification) { manager?.playerWindowDidClose() }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
