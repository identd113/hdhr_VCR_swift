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
    @AppStorage("vlcVolume") private var volume: Double = 50
    @State private var systemDevices: [(id: String, name: String)] = []
    @State private var selectedDevice: String = ""
    @State private var availableScreens: [NSScreen] = []
    @State private var posterHidden: Bool = false
    @State private var posterNSImage: NSImage? = nil
    @ObservedObject private var bridge = VLCBridge.shared
    @State private var bufferInfoHovered = false

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

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ZStack {
                VLCVideoSurface()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !posterHidden && !bridge.hasError {
                    posterOverlay
                        .transition(.opacity)
                }
                if bridge.hasError {
                    errorOverlay
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeOut(duration: 0.35), value: posterHidden)
            .animation(.easeOut(duration: 0.35), value: bridge.hasError)
            .task(id: currentGuideEntry?.ImageURL) {
                guard let url = currentGuideEntry?.ImageURL else { posterNSImage = nil; return }
                posterNSImage = await ChannelIconCache.shared.image(for: url)
            }
        }
        .onAppear {
            glog("[VLC] VLCPlayerView.onAppear device=\(device.DeviceID) initialURL=\(initialURL)")
            availableScreens = NSScreen.screens   // NSScreen.screens is main-thread-only; safe here
            VLCBridge.shared.minRate = Float(state.config.Player_buffer_min_rate) / 100.0
            VLCBridge.shared.setVolume(0)   // muted until Start is clicked
            refreshAudioDevices()
            VLCBridge.shared.startDeviceChangeMonitoring { refreshAudioDevices() }
            syncChannel(to: initialURL)
            let cc = MPRemoteCommandCenter.shared()
            cc.stopCommand.isEnabled = true
            cc.stopCommand.addTarget { _ in
                // Remote stop (media key / Now Playing widget) — calls VLCBridge.stop() which
                // clears drawableView; window will go black until closed and reopened.
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
        .onChange(of: state.config.Player_buffer_min_rate) { _, pct in
            glog("[VLC] Player_buffer_min_rate changed → \(pct)%")
            VLCBridge.shared.minRate = Float(pct) / 100.0
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
            guard let ch = selectedChannel,
                  let idx = lineup.firstIndex(where: { $0.GuideNumber == ch.GuideNumber }) else { return }
            selectedChannel = lineup[idx < lineup.count - 1 ? idx + 1 : 0]
        }
        .onReceive(NotificationCenter.default.publisher(for: .vlcChannelPrev)) { _ in
            guard let ch = selectedChannel,
                  let idx = lineup.firstIndex(where: { $0.GuideNumber == ch.GuideNumber }) else { return }
            selectedChannel = lineup[idx > 0 ? idx - 1 : lineup.count - 1]
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
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.callout.bold())
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            // Channel picker — sorted by guide number
            Picker("Channel", selection: $selectedChannel) {
                ForEach(lineup, id: \.GuideNumber) { ch in
                    Text("\(ch.GuideNumber)  \(ch.GuideName)").tag(Optional(ch))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 220)
            .onChange(of: selectedChannel) { _, ch in
                posterHidden = false
                posterNSImage = nil
                VLCBridge.shared.setVolume(0)
                if suppressNextChannelPlay { suppressNextChannelPlay = false; return }
                if let ch { playChannel(ch) }
            }

            Spacer()

            if bridge.bufferInfo.enabled { bufferMonitor }

            // Native resolution: resize window to 1:1 physical pixels
            Button {
                VLCPlayerWindowManager.shared.sizeToNativeVideo()
            } label: {
                Image(systemName: "aspectratio")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Native resolution — resize window to 1:1 pixels")

            // Speed up to live: discard buffer and reconnect at live edge
            Button {
                VLCBridge.shared.catchUpToLive()
            } label: {
                Image(systemName: "forward.end.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Speed up to live — discard buffer and jump to live edge")

            // Live wall-clock time — meaningful for live TV; no elapsed/scrubbing concept
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
    }

    // MARK: - Buffer monitor

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
        .onHover { bufferInfoHovered = $0 }
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
    private weak var appState: AppState?

    private init() {}

    /// Bring the player window to the front without switching the stream.
    func focus() {
        guard let win = window else { return }
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    /// Close the player window if it is currently playing the given URL.
    func closeIfPlayingURL(_ url: String) {
        guard !url.isEmpty, VLCBridge.shared.currentURL?.urlBase == url else { return }
        window?.close()   // triggers windowWillClose → playerWindowDidClose
    }

    /// Open (or bring forward) the player window and start playing url on device.
    /// If the window is already showing, the stream is switched immediately.
    func open(url: String, title: String, device: HDHRDevice, appState: AppState) {
        self.appState = appState
        currentDeviceID = device.DeviceID
        VLCBridge.shared.minRate = Float(appState.config.Player_buffer_min_rate) / 100.0
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
        window = nil
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
