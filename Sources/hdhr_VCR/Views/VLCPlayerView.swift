import SwiftUI
import AppKit
import MediaPlayer

private extension Notification.Name {
    static let vlcChannelNext = Notification.Name("vlcChannelNext")
    static let vlcChannelPrev = Notification.Name("vlcChannelPrev")
    // userInfo["isFullScreen"]: Bool — posted by WindowCloseObserver's NSWindowDelegate fullscreen
    // callbacks, for any entry/exit path (green-button hover, Cmd+Ctrl+F, or our own Esc handler's
    // toggleFullScreen(nil) call) alike, since they all funnel through the same NSWindow delegate
    // methods regardless of trigger.
    static let vlcFullScreenChanged = Notification.Name("vlcFullScreenChanged")
    // Posted by VLCPlayerWindowManager's installKeyMonitor (below) on a bare "i" keydown — see its
    // own doc comment for why the info banner needs this same local-monitor treatment the arrow
    // keys/Esc already get, instead of relying on the toolbar Info button's own
    // .keyboardShortcut("i", modifiers: []).
    static let vlcToggleInfoOverlay = Notification.Name("vlcToggleInfoOverlay")
}

// ── VLCVideoSurface ───────────────────────────────────────────────────────────
// Zero-overhead NSView that VLC renders video into.
// We call setDrawable() on the bridge (not updateNSView) so VLC keeps the view
// reference across channel switches — VLC holds a weak NSObject reference internally.

private struct VLCVideoSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let (container, content) = makeVLCVideoContainerAndContent()
        glog("[VLC] VLCVideoSurface.makeNSView — container=\(ObjectIdentifier(container)) content=\(ObjectIdentifier(content))")
        VLCBridge.shared.setContainer(container)
        VLCBridge.shared.setDrawable(content)
        return container
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// ── VLCSecondaryVideoSurface ──────────────────────────────────────────────────
// Same "attach once in makeNSView, never updateNSView" shape as VLCVideoSurface above, just wired
// to VLCBridge's secondary slot — the muted picture-in-picture corner thumbnail (see
// docs/VLCPlayerView.md's "Picture-in-picture" section).

private struct VLCSecondaryVideoSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let (container, content) = makeVLCVideoContainerAndContent()
        glog("[VLC] VLCSecondaryVideoSurface.makeNSView — container=\(ObjectIdentifier(container)) content=\(ObjectIdentifier(content))")
        VLCBridge.shared.setContainer(container, slot: .secondary)
        VLCBridge.shared.setDrawable(content, slot: .secondary)
        return container
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// Shared by both surfaces above. `container` is the view SwiftUI actually manages (positioned by
// the big pane's ZStack or the thumbnail's fixed-size overlay, never reparented again); `content`
// is the one libvlc's _mpSetNSO actually targets, added as container's sole, bounds-filling
// subview. Splitting these is what lets VLCBridge.swapSlots() move `content` between containers
// via a plain AppKit addSubview/removeFromSuperview instead of re-targeting an already-playing
// player's rendering surface — see swapSlots()'s own doc comment for why the latter doesn't work
// live on macOS's vout module.
private func makeVLCVideoContainerAndContent() -> (container: NSView, content: NSView) {
    let container = NSView()
    container.wantsLayer = true
    container.layer?.backgroundColor = CGColor(gray: 0, alpha: 1)
    let content = NSView()
    content.wantsLayer = true
    content.layer?.backgroundColor = CGColor(gray: 0, alpha: 1)
    return (container, content)
}

// ── PipCorner ─────────────────────────────────────────────────────────────────
// Which corner of the video area the PiP thumbnail is pinned to — user-chosen via the thumbnail's
// own right-click context menu (VLCPlayerView.pipCornerMenu), persisted across sessions the same
// way `volume` is (@AppStorage). RawRepresentable (String) so @AppStorage can store it directly.
enum PipCorner: String, CaseIterable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    var isTop:     Bool { self == .topLeading    || self == .topTrailing }
    var isLeading: Bool { self == .topLeading    || self == .bottomLeading }

    var displayName: String {
        switch self {
        case .topLeading:     return "Top Left"
        case .topTrailing:    return "Top Right"
        case .bottomLeading:  return "Bottom Left"
        case .bottomTrailing: return "Bottom Right"
        }
    }
}

// ── VLCPlayerView ─────────────────────────────────────────────────────────────
// SwiftUI content for the VLC player window.
// Hosted in an NSHostingView inside VLCPlayerWindowManager's NSWindow.

struct VLCPlayerView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    // The device whose lineup populates the channel picker.
    // Fixed at window-open time — no device switching in the player toolbar.
    let device: HDHRDevice
    // Stream URL active when the window opened; used to pre-select the channel picker.
    let initialURL: String

    @State private var selectedChannel: LineupEntry?
    @State private var suppressNextChannelPlay = false
    // Set alongside suppressNextChannelPlay only by syncChannel's recording-relay match branch
    // (the live→disk yield handoff, matching the *same* show already playing under a synthetic
    // entry) — distinguishes that relabel-only case from a genuine synced content change (e.g.
    // switching which FEED show is playing via VLCPlayerWindowManager.open, which also sets
    // suppressNextChannelPlay to avoid a redundant playChannel call, but IS new content and still
    // needs the poster/mute reset below). See .onChange(of: selectedChannel)'s own comment.
    @State private var suppressSameContent = false
    // Set only by swapPrimaryAndSecondary(), consumed (read-and-cleared) at the top of the very
    // next syncChannel(to:) call — tells its plain-lineup-match branch (shared with a genuine
    // open()-driven channel switch, which legitimately does want the poster/mute reset) that THIS
    // particular resolution is a swap relabel, not new content. The recording-relay and
    // cross-device-FEED match branches don't need this: both are reachable only via a swap already
    // (see feedChannelEntry's own doc comment), so they set suppressSameContent unconditionally.
    // Found live 2026-09-19: without this, swapping to a live channel (not a recording/FEED) wrongly
    // re-triggered the poster/mute reset, dropping the poster/summary and re-muting an
    // already-live stream — see swapPrimaryAndSecondary's own comment for the full story.
    @State private var suppressPosterResetForSwap = false
    @State private var selectedAudioTrackId: Int32 = -1  // -1 = not yet loaded; set when audioTracks first appear
    @State private var selectedSpuTrackId:   Int32 = -1  // -1 = CC off (default)
    // -1 is also the Picker's own "Off" tag, so it can't by itself distinguish "user explicitly
    // turned captions off" from "no choice made yet" — this tracks that separately. Only ever set
    // true by the Picker binding below (a real user pick); every programmatic reset of
    // selectedSpuTrackId (channel load, channel switch) sets this back to false too, so a fresh
    // channel always gets a fresh auto-enable-on-mute decision instead of inheriting the previous
    // channel's explicit choice forever.
    @State private var spuChoiceIsExplicit:  Bool  = false
    @AppStorage("vlcVolume") private var volume: Double = 50
    // PiP thumbnail's pinned corner — set via its own right-click context menu (pipCornerMenu).
    @AppStorage("vlcPipCorner") private var pipCorner: PipCorner = .bottomTrailing
    @State private var systemDevices: [(id: String, name: String, isAirPlay: Bool)] = []
    @State private var selectedDevice: String = ""
    @State private var availableScreens: [NSScreen] = []
    @State private var posterHidden: Bool = false
    @State private var posterNSImage: NSImage? = nil
    @ObservedObject private var bridge = VLCBridge.shared
    @State private var bufferInfoHovered  = false
    @State private var nativeResHovered   = false
    // Captured once when nativeResHovered flips true (see the .onHover below) rather than read
    // live from recordingSizeText inside nativeResPopover — that computed property's own doc
    // comment always claimed "recomputed only when the popover reopens," but `body` actually
    // re-evaluates on every bridge.bufferInfo publish (every ~3s while playing, VLCBridge.swift),
    // which re-derives nativeResPopover (and therefore recordingSizeText's blocking disk stat)
    // that often for as long as the popover stays open — not just once per open. This @State
    // snapshot is what actually delivers the "recompute only on open" behavior the comment describes.
    @State private var recordingSizeSnapshot: String?
    // Cache for inferredCodecs' local Watch-Now (recording-relay) branch — that branch does three
    // linear scans (state.shows.first, a device lookup, a channel-lineup scan) to derive the
    // show's effective codec, and previously re-ran them on every `body` evaluation (~3s while
    // playing, per bridge.bufferInfo publishing) even though the answer only actually changes once
    // per recording. Recomputed in .onAppear and the bridge.recordingShowId .onChange handler below
    // rather than inside inferredCodecs itself (a computed property read during view-body
    // evaluation must not mutate @State).
    @State private var cachedLocalRelayCodecs: (showId: String, video: String, audio: String)?
    @State private var scrubValue: Double = 0     // recording scrub bar — only meaningful while isScrubbing
    @State private var isScrubbing = false
    @State private var videoControlsHovered = false   // shows the recording scrub overlay on hover
    @State private var showTunerFullAlert = false      // quick-record toolbar button (see toolbar)
    // Set instead of showTunerFullAlert when the only thing blocking a quick-record is this
    // instance's own live Watch Now stream on the same device — see TODO.md's "Watch Now should
    // yield its tuner" entry and quickRecordMenu's yieldWatchNowConfirm parameter.
    @State private var yieldWatchNowConfirm: QuickRecordYieldRequest? = nil
    @State private var isFullScreen = false      // driven by WindowCloseObserver's NSWindowDelegate callbacks
    @State private var toolbarHovered = false     // reveals the toolbar overlay while isFullScreen (see body)
    // Gates FEED auto-play (see startPlayback's own doc comment) until this much real time has
    // passed since the current stream opened — set by a .task(id: bridge.currentURL) below, so a
    // channel switch mid-session restarts the wait for the newly-opened stream.
    @State private var feedAutoPlayDelayElapsed = false
    // Toolbar "Info" button ("i" on a TV remote) — toggled true/false; a `.task(id:)` below
    // auto-hides it infoOverlayAutoHideSeconds after it's shown. See infoBanner's own doc comment.
    @State private var infoOverlayVisible = false

    private var currentGuideEntry: GuideEntry? {
        guard let ch = selectedChannel else { return nil }
        let now = Date()
        // A recording-relay selection's GuideNumber is the synthetic "live:showId" placeholder
        // recordingChannelEntries makes for the channel picker — not a real channel number the
        // guide is keyed by, so it never matches below on its own. Resolve it back to the show's
        // actual channel first so poster/synopsis still resolve while watching a recording.
        let recordingShow = showId(fromLiveGuideNumber: ch.GuideNumber)
            .flatMap { id in state.recordingShows.first { $0.show_id == id } }
        let channelNum = recordingShow?.show_channel ?? ch.GuideNumber
        // Anchored to the recording's own scheduled start, not wall-clock `now`, when watching a
        // recording — same fix as MenuContent.recordingMenu's identical bug: a Bonus Time recording
        // keeps running past its guide slot's own end, so querying "what's live on this channel
        // right now" past that point resolves to whatever program the channel has since moved on
        // to, not the one actually being recorded. Confirmed live 2026-09-13 (MenuContent's
        // "Recording Now" row showed an unrelated news-magazine episode mid-Bonus-Time-recording).
        // Plain live-channel selections (recordingShow == nil) keep using wall-clock `now`, unchanged.
        let anchorTime = recordingShow?.show_next ?? now
        return state.guideEntries(deviceId: device.DeviceID, channelNum: channelNum)
            .first { $0.startDate <= anchorTime && $0.endDate > anchorTime }
    }

    // Falls back to the FEED relay's own lineup extra (see currentFeedEntry's own doc comment)
    // when currentGuideEntry is nil — always true for a remote FEED device today (no local guide
    // data exists for one). Not a true per-episode image (currentFeedEntry.virtualRelayImageURL is
    // the source show's channel logo, same as Discord's embed thumbnail) but still real identity
    // instead of the generic "tv" placeholder icon.
    private var effectivePosterImageURL: String? {
        currentGuideEntry?.ImageURL
            ?? (device.isVirtualRelay ? currentFeedEntry?.virtualRelayImageURL : nil)
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

    // Rough estimate of the native fullscreen title-bar reveal strip's height (traffic lights +
    // title, drawn by AppKit above app content when the cursor nears the top of a true-fullscreen
    // window) — see body's isFullScreen toolbar overlay for why this exists. Not an exact value;
    // macOS doesn't expose the real strip height, so this may need tuning after an actual look.
    private static let fullScreenTopInset: CGFloat = 32

    // Minimum real time a remote FEED session must sit buffering before auto-play unhides the
    // poster and unmutes — requested 2026-09-04 after auto-play's own isPlaying-only gate turned
    // out to fire too early (~3s, first confirmed decode) to build up a meaningful cushion against
    // Player_buffer_min_rate's slow ramp (see docs/VLCPlayerView.md's "Auto-play for a remote FEED
    // session"). One constant for both halves of startPlayback(auto:) — the poster reveal and the
    // volume restore/unmute fire together, always have — so there's no separate "audio delay" to
    // track apart from this.
    //
    // Was 10 until 2026-09-12: the fill-phase ramp itself was fixed 2026-09-06 (rampedFillRate's
    // linearity fix, VLCBridge.swift) to reliably finish in its own maxLagSec (8.0, default param
    // of rampedFillRate) real seconds instead of the pre-fix's occasional multi-minute crawl, but
    // this constant was never revisited afterward — 10s was leaving 2s of pure dead air on top of
    // an already-reliable 8s ramp. Dropped to match maxLagSec exactly so the poster reveals right
    // as the ramp completes rather than after. Not live-tested against a real FEED session yet —
    // revert to 10 if a live check shows video revealing visibly mid-ramp (a few seconds of
    // subtly-slow-motion playback) rather than right at 1.0× rate.
    private static let feedAutoPlayMinDelay: TimeInterval = 8

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

    // Builds the synthetic "live:showId" picker row for one recording — extracted out of
    // recordingChannelEntries below so syncChannel's cross-device recording-relay match (added
    // 2026-09-26) can build the same shape for a show on a DIFFERENT device than this window's own
    // bound `device`, without duplicating the literal.
    private static func liveRecordingEntry(for show: Show) -> LineupEntry {
        LineupEntry(GuideNumber: "\(liveGuideNumberPrefix)\(show.show_id)",
                    GuideName: "Live \(show.show_channel)  \(show.show_title)",
                    URL: nil, HD: nil, Favorite: nil)
    }

    // One synthetic row per show currently recording on this player's device — lets the picker
    // switch directly between simultaneous recordings via the relay (docs/WebServer.md), the same
    // way it switches between live channels.
    private var recordingChannelEntries: [LineupEntry] {
        state.recordingShows
            .filter { $0.hdhr_record == device.DeviceID }
            .sorted { $0.show_channel.localizedStandardCompare($1.show_channel) == .orderedAscending }
            .map(Self.liveRecordingEntry)
    }

    // Synthetic row for a FEED (another Mac's in-progress recording) currently playing as primary
    // whose source doesn't match this window's own bound `device` — the case recordingChannelEntries
    // above can't cover, since it only ever looks at *this* device's own recordingShows. Reachable
    // after a cross-device PiP swap (VLCBridge.swapSlots()/swapPrimaryAndSecondary()): this view's
    // `device`/`lineup` stay bound to whichever device the window originally opened on (see
    // docs/VLCPlayerView.md's "cross-device swap" note), so a swapped-in FEED from a different
    // source Mac has no entry in `lineup` to resolve against at all — found live 2026-09-19, the
    // channel picker just showed the plain favorites/rest list with nothing selected. A FEED opened
    // directly (not via a swap) already works without this: device.isVirtualRelay is true then, so
    // it resolves through the normal lineup-matching path in syncChannel(to:) instead — this entry
    // only ever appears for the cross-device case, gated the same way in that function.
    // Not private: referenced by feedChannelEntry(deviceIsVirtualRelay:remoteURL:remoteRelayEntries:)'s
    // own unit tests.
    nonisolated static let liveFeedGuideNumberPrefix = "live-feed:"

    private var feedChannelEntry: LineupEntry? {
        Self.feedChannelEntry(deviceIsVirtualRelay: device.isVirtualRelay,
                               remoteURL: VLCPlayerWindowManager.shared.currentFeedRemoteURL,
                               remoteRelayEntries: state.remoteRelayEntries)
    }

    /// Pure decision, extracted for unit testing — matches `remoteURL` against the discovered FEED
    /// entries and, if found, builds the synthetic picker row for it. See feedChannelEntry's own
    /// call site (the property above) for why this exists.
    nonisolated static func feedChannelEntry(deviceIsVirtualRelay: Bool, remoteURL: String?,
                                              remoteRelayEntries: [(device: HDHRDevice, entry: LineupEntry)]) -> LineupEntry? {
        // Cross-device-swap case only (see the doc comment above) — a direct FEED open already has
        // device.isVirtualRelay == true and resolves through the normal lineup-matching path in
        // syncChannel(to:) instead, so this must stay nil then or every call site (the toolbar
        // Picker included) would show a duplicate synthetic row alongside the real, lineup-matched
        // entry for the same content.
        guard !deviceIsVirtualRelay else { return nil }
        guard let remoteURL, let pair = remoteRelayEntries.first(where: { $0.entry.URL == remoteURL })
        else { return nil }
        let title = pair.entry.virtualRelayShowTitle ?? pair.entry.GuideName
        let label = pair.entry.virtualRelaySourceHostname.map { "\(title) — \($0)" } ?? title
        return LineupEntry(GuideNumber: "\(liveFeedGuideNumberPrefix)\(remoteURL)",
                            GuideName: "FEED  \(label)", URL: nil, HD: nil, Favorite: nil)
    }

    // Media-key next/prev cycle order — recording rows first, then real channels in plain
    // ascending channel-number order. Deliberately NOT favorites-first like the picker's visual
    // order below: channel-up/down is a sequential-step gesture (user expects 5.1 → 5.2 → 6.1),
    // and reordering it to favorites-first would make each press jump unpredictably between a
    // favorite and its numeric neighbors instead of stepping through the dial in order.
    private var channelCycleOrder: [LineupEntry] { recordingChannelEntries + lineup }

    // HDHomeRun raw streams are always MPEG-2/AC-3. Every real, actually-applied transcode
    // path — a real device EXTEND hardware profile (heavy/mobile/internet*) *and* this app's own
    // software transcode (VLCBridge.startTranscodeSession, the FEED raw/H.264 toggle and
    // MenuContent's "Watch (H.264)" item) — produces H.264/AC-3. Confirmed live 2026-09-13 via
    // ffprobe against a real "heavy" hardware-transcoded recording (previously assumed AAC for
    // the hardware-profile case; that was never actually verified and was wrong).
    private var inferredCodecs: (video: String, audio: String) {
        // FEED: the source Mac's own effective codec is now published directly in /lineup.json
        // (Show.effectiveVideoCodec, WebServer.buildVirtualTunerLineupJSON) — already accounts
        // for a real hardware transcode profile overriding the channel's own raw broadcast
        // codec, so this is authoritative rather than a guess from a URL query string (raw
        // passthrough of an already-modern-codec recording never carries &transcode= at all,
        // which the old URL-only heuristic had no way to see past).
        if device.isVirtualRelay {
            // feedIsTranscoding first: once the viewer's own H.264 toggle has requested a
            // software transcode (&transcode=auto on the remote URL), what's actually arriving
            // is genuinely H.264 regardless of what the *source* recording itself is — checking
            // currentFeedEntry?.VideoCodec alone (the source's own codec) would keep reporting
            // the untransformed source codec even while watching a transcoded stream.
            if feedIsTranscoding { return ("H.264", "AC-3") }
            let codec = currentFeedEntry?.VideoCodec ?? "unknown"
            guard MPEGVideoStreamType.isAlreadyModernCodec(codec) else { return ("MPEG-2", "AC-3") }
            return (Self.displayCodecName(codec), "AC-3")
        }
        // Local Watch Now (recording-relay): same effective-codec logic, computed directly since
        // both the show and its device are already known locally — no publishing step needed.
        // Served from cachedLocalRelayCodecs (kept fresh by .onAppear / the recordingShowId
        // .onChange handler below) when it matches the current show; only falls through to a live
        // recompute the first time this show's codec hasn't been cached yet.
        if let showId = bridge.recordingShowId {
            if let cached = cachedLocalRelayCodecs, cached.showId == showId {
                return (cached.video, cached.audio)
            }
            if let show = state.shows.first(where: { $0.show_id == showId }) {
                return Self.computeLocalRelayCodecs(show: show, state: state)
            }
        }
        // Live channel, not a relay of any kind — the only remaining producer of a &transcode=
        // URL param is this app's own on-the-fly software transcode toggle.
        let url = bridge.currentURL ?? ""
        return url.contains("transcode=") ? ("H.264", "AC-3") : ("MPEG-2", "AC-3")
    }

    // Recomputes cachedLocalRelayCodecs for the given show, or clears it when there's no local
    // recording-relay playback active. Called from .onAppear and the bridge.recordingShowId
    // .onChange handler — never from inferredCodecs itself, which is a computed property read
    // during view-body evaluation and must not mutate @State.
    private func refreshCachedLocalRelayCodecs(showId: String?) {
        guard let showId, let show = state.shows.first(where: { $0.show_id == showId }) else {
            cachedLocalRelayCodecs = nil
            return
        }
        let codecs = Self.computeLocalRelayCodecs(show: show, state: state)
        cachedLocalRelayCodecs = (showId: showId, video: codecs.video, audio: codecs.audio)
    }

    // "H264" (the raw VideoCodec string form) → "H.264" for display; anything else passed through
    // as-is (e.g. "HEVC" already reads fine unpunctuated). Internal, not private — MenuContent's
    // "Recording on Another Mac" menu reuses this for its own already-modern "Watch (H.264)"
    // label, so the two surfaces can't drift on how a codec string is displayed.
    static func displayCodecName(_ codec: String) -> String {
        codec.uppercased() == "H264" ? "H.264" : codec
    }

    // The actual three-scan derivation inferredCodecs' local-relay branch needs — factored out so
    // it can be run once (cachedLocalRelayCodecs) instead of on every body evaluation.
    private static func computeLocalRelayCodecs(show: Show, state: AppState) -> (video: String, audio: String) {
        let deviceSupportsTranscode = state.deviceSupportsTranscode(forDeviceID: show.hdhr_record)
        let channelCodec = state.lineups[show.hdhr_record]?.first(where: { $0.GuideNumber == show.show_channel })?.VideoCodec
        let codec = Show.effectiveVideoCodec(transcode: show.show_transcode,
                                              deviceSupportsTranscode: deviceSupportsTranscode,
                                              channelVideoCodec: channelCodec) ?? "unknown"
        guard MPEGVideoStreamType.isAlreadyModernCodec(codec) else { return ("MPEG-2", "AC-3") }
        return (displayCodecName(codec), "AC-3")
    }

    // A plain stat of the recording file's current size. Only ever called from the "Native" button's
    // .onHover (captured into recordingSizeSnapshot) — never read directly from nativeResPopover's
    // body, which would re-run this blocking disk stat on every bridge.bufferInfo publish (~3s while
    // playing) for as long as the popover stayed open, not just once per open as originally intended.
    private var recordingSizeText: String? {
        guard let showId = bridge.recordingShowId,
              let show = state.shows.first(where: { $0.show_id == showId }),
              let attrs = try? FileManager.default.attributesOfItem(atPath: show.show_recording_path),
              let size = attrs[.size] as? Int64, size > 0 else { return nil }
        let mb = Double(size) / 1_048_576
        return mb >= 1024 ? String(format: "%.2f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }

    // MARK: - Remote FEED raw/H.264 toggle (docs/VirtualTunerService.md's "Recording on Another
    // Mac" menu already offers this as two separate menu items at open time; this is the same
    // choice made reachable inside an already-open player window instead of requiring a reopen).
    //
    // Only meaningful for a remote FEED session (device.isVirtualRelay — MenuContent's own
    // "Recording on Another Mac" rows are the only source of a VLCPlayerWindowManager.open() call
    // against such a device; watchInApp/watchRecordingInApp never pass one). `lineup` here is
    // already scoped to this one device (state.lineups[device.DeviceID]), so matching by URL path
    // alone (urlBase strips both the raw entry's own "?dev=" and an added "&transcode=") is
    // unambiguous — every entry in this list already shares this device's DeviceID.
    private var currentFeedEntry: LineupEntry? {
        // Matched against the true remote URL, not bridge.currentURL — once the FEED client-side
        // local relay is in play, bridge.currentURL holds a LOCAL http://127.0.0.1/api/
        // feed-local-relay?... URL (see currentFeedRemoteURL's own doc comment), which would never
        // match any of this device's real lineup entries.
        guard device.isVirtualRelay, let url = VLCPlayerWindowManager.shared.currentFeedRemoteURL else { return nil }
        let target = url.urlBase
        return lineup.first { ($0.URL ?? "").urlBase == target }
    }

    private var feedIsTranscoding: Bool {
        (VLCPlayerWindowManager.shared.currentFeedRemoteURL ?? "").contains("transcode=")
    }

    // True only for the standalone-PIP window (VLCPlayerWindowManager.ensureWindowForStandalonePiP):
    // primary never received a URL to play (initialURL empty, syncChannel's own guard on non-empty
    // rawSyncURL means selectedChannel stays nil), so bridge.isPlaying can never flip true — the
    // ordinary Start/Connecting… button below would otherwise render permanently disabled.
    private var isPrimaryIdle: Bool {
        initialURL.isEmpty && selectedChannel == nil && bridge.recordingShowId == nil
    }

    // Mirrors MenuContent's own `alreadyModern` check — unset/"unknown" VideoCodec (older
    // firmware, or a source lineup entry that never set it) is treated as "not confirmed modern,"
    // same as there, so the toggle is offered rather than hidden.
    private var feedSourceAlreadyModern: Bool {
        MPEGVideoStreamType.isAlreadyModernCodec(currentFeedEntry?.VideoCodec ?? "unknown")
    }

    // Tears down and reopens the current FEED connection with (or without) &transcode=auto — routed
    // through state.startFeedLocalRelay (same as watchRemoteRelay's initial open) rather than
    // calling bridge.play(url:) directly against the raw remote URL: doing that would reconnect
    // libvlc straight to the remote Mac and reintroduce the exact cross-machine stall bug the FEED
    // client-side local relay exists to avoid, just for this one interaction.
    private func toggleFeedTranscode(to wantsTranscode: Bool) {
        guard wantsTranscode != feedIsTranscoding, let rawURL = currentFeedEntry?.URL else { return }
        let newRemoteURL = wantsTranscode ? rawURL + "&transcode=auto" : rawURL
        glog("[VLC] FEED transcode toggle → \(wantsTranscode ? "H.264" : "raw"): \(newRemoteURL)")
        let localURL = state.startFeedLocalRelay(remoteURL: newRemoteURL, device: device)
        bridge.play(url: localURL)
    }

    // MARK: - Picture-in-picture tap-to-swap
    //
    // Tap the corner thumbnail to make it the front (full controls + audio) stream, and demote
    // whatever was previously front to the muted corner — a genuine reconnect, the same
    // reconnect-by-URL shape as toggleFeedTranscode/catchUpToLive above: mutate which URL each
    // slot's already-alive player is pointed at, no window/view recreation. A brief rebuffer on
    // swap is expected, not a regression.
    private func swapPrimaryAndSecondary() {
        let mgr = VLCPlayerWindowManager.shared
        guard bridge.secondaryURL != nil, mgr.secondaryDeviceID != nil else { return }

        // Re-targets each already-playing player's rendering surface onto the other slot's fixed
        // view — no stop/reconnect, so this is instant, not a rebuffer (see swapSlots' own doc
        // comment for the full reasoning; this replaced an earlier reconnect-by-URL design after
        // live feedback that it caused a visible rebuffer on every swap).
        bridge.swapSlots()

        // recordingShowId is strictly primary-only and derived from the URL, not swappable state
        // (swapSlots() deliberately leaves it alone) — re-anchor it now that currentURL reflects
        // whatever is newly primary, or every recordingShowId-gated check (vlcOccupiesTuner, the
        // scrub bar, the disk-relay color indicator) keeps describing the pre-swap primary.
        state.reanchorRecordingSeekForSwap(newPrimaryURL: bridge.currentURL ?? "")

        mgr.swapTrackingFieldsForPiPSwap()

        // New primary gets real audio, new secondary goes silent. Both players are already alive,
        // so these are live volume changes, not part of any mute-before-play/unmute-after-buffered
        // dance — there's no reconnect here for that dance to apply to.
        bridge.setVolume(0, slot: .secondary)
        bridge.setVolume(Int(volume), slot: .primary)

        // No posterHidden/posterNSImage reset needed (unlike the old reconnect-based swap) — the
        // newly-primary stream was already playing with its poster long since dismissed; forcing
        // posterHidden back to false here would wrongly show a Start-gate poster over an
        // already-live stream.

        // Toolbar UI state doesn't auto-follow a swap (there's no fresh .onAppear/user picker
        // interaction driving it) — reset it directly so the channel/track pickers stop describing
        // the pre-swap primary. Found live 2026-09-19 alongside the window-title fix above.
        // selectedChannel = nil rather than resolving the new primary's actual entry: this
        // VLCPlayerView instance's own `device`/`lineup` stay bound to whichever device the window
        // was *originally* opened on, so a same-device swap could in principle resolve the right
        // LineupEntry, but a cross-device swap (the secondary can be on a different tuner) has no
        // correct entry to resolve against this view's own lineup at all — nil is the safe
        // "don't show a wrong channel" choice for both cases alike; a deeper fix would need this
        // view's own device binding to become swappable too, out of scope here.
        // suppressNextChannelPlay + suppressSameContent make this a no-op for .onChange(of:
        // selectedChannel)'s own handler (no playChannel call, no poster/mute reset — this swap
        // already set the correct final volumes above).
        selectedAudioTrackId = -1
        selectedSpuTrackId   = -1
        spuChoiceIsExplicit  = false
        suppressNextChannelPlay = true
        suppressSameContent     = true
        selectedChannel = nil
        // This nil assignment's own onChange is already fully suppressed by the two flags just
        // above — but currentURL changing (inside bridge.swapSlots() earlier) independently fires
        // .onChange(of: state.vlcCurrentURL) → syncChannel(to:), which resolves selectedChannel to
        // the new primary's *real* entry a moment later. That later resolution needs its own
        // poster/mute-reset suppression, which this flag carries across to it — see the flag's own
        // doc comment for why only the plain-lineup-match branch needs to consume it.
        suppressPosterResetForSwap = true

        state.refreshTunerOccupancy()
    }

    // The Native-resolution icon's color now also encodes whether the current stream is being
    // read from the network (a live tuner stream) or from disk (the recording relay) — requested
    // 2026-09-11, see TODO.md's "Watch Now should show whether the video is currently reading
    // from the network or from disk". `bridge.recordingShowId` is the same signal AppState's
    // `vlcOccupiesTuner`/`vlcLiveChannel` already key off for this exact distinction elsewhere.
    // Blue = network, purple = disk — replaces the plain `.accentColor` this icon used to glow
    // (see the toolbar's own comment on how "achievable but not yet native" is still conveyed:
    // full-saturation + shadow vs. a dimmed version of the same hue, not a color swap).
    //
    // A third case, added 2026-09-13: a remote FEED session (`device.isVirtualRelay`) is neither
    // of the above — it arrives over the network like a live tuner stream, but what's actually on
    // the other end is the *source* Mac's own in-progress recording being read off *its* disk, not
    // a live broadcast feed. Indigo (between blue and purple) reflects that it's genuinely a blend
    // of both, not a strict either/or the binary above assumes.
    private var nativeIconSourceColor: Color {
        if device.isVirtualRelay { return .indigo }
        return bridge.recordingShowId != nil ? .purple : .blue
    }

    private var canResizeToNative: Bool {
        bridge.videoPixelSize != nil && VLCPlayerWindowManager.shared.nativeVideoFitsCurrentScreen()
    }

    var body: some View {
        VStack(spacing: 0) {
            // Windowed mode: toolbar is a normal, always-visible top row, same as always. In true
            // fullscreen it moves into the ZStack below instead (see the isFullScreen block there)
            // — a floating hover-reveal overlay, not a row that would permanently claim space from
            // an otherwise-immersive video. Reported 2026-08-22: with the toolbar left as an
            // always-visible top row in fullscreen, it visually competed with macOS's own
            // top-of-screen hover-reveal menu bar for the same real estate.
            if !isFullScreen {
                toolbar
            }
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
                if infoOverlayVisible {
                    infoBanner
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
                if isFullScreen {
                    // Top-pinned floating overlay, hover-revealed — same "hidden-but-still-
                    // hoverable via opacity, not hit-testing" trick as the recording scrub bar
                    // above, just mirrored to the top edge.
                    //
                    // fullScreenTopInset: true NSWindow fullscreen still auto-reveals the window's
                    // own native title bar (traffic lights + title) as a system-drawn overlay when
                    // the cursor nears the very top — that overlay draws above app content, so a
                    // toolbar placed right at y=0 renders *underneath* it instead of being visible.
                    // Reported 2026-08-22: the revealed bar showed as empty — this was that native
                    // strip covering our own toolbar, not a rendering bug. Offsetting our toolbar
                    // down by roughly a title-bar's height clears it (still an estimate — macOS
                    // doesn't expose the reveal strip's exact height).
                    //
                    // Hover zone must cover that top inset too, not just where the toolbar itself
                    // draws pixels — reported 2026-08-22 (round two): with .onHover scoped to
                    // `toolbar` alone, the offset pushed the toolbar's hoverable rect down with it,
                    // so hovering at the actual top edge (where the native reveal also triggers,
                    // and where a user naturally checks) hit nothing. `.contentShape(Rectangle())`
                    // makes the *whole* topInset+toolbar band hit-testable, including the empty
                    // padding above the toolbar, so hovering anywhere in that band reveals it — the
                    // outer `Spacer()` below stays outside this hover-scoped group entirely, so
                    // hovering the rest of the video still does nothing (unlike a naive `.onHover`
                    // on the whole VStack, which would reveal the toolbar from anywhere on screen).
                    VStack(spacing: 0) {
                        VStack(spacing: 0) {
                            Color.clear.frame(height: Self.fullScreenTopInset)
                            toolbar
                        }
                        .contentShape(Rectangle())
                        .onHover { toolbarHovered = $0 }
                        .opacity(toolbarHovered ? 1 : 0)
                        .animation(.easeInOut(duration: 0.2), value: toolbarHovered)
                        Spacer()
                    }
                    .transition(.opacity)
                }
                if VLCPlayerWindowManager.shared.secondaryDeviceID != nil {
                    pipOverlay
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Right-click anywhere on the main video pane — a single simple entry that opens the
            // shared PiPPickerView (the only entry point now — MenuContent's redundant "Add
            // Picture-in-Picture…" menu-bar button was removed 2026-09-19). Attached to this outer
            // ZStack, not VLCVideoSurface alone, so it still triggers while the poster/error/idle
            // overlay sits on top. Distinct from — and never shadows — pipOverlay's own
            // .contextMenu { pipCornerMenu; pipChannelMenu } below, which is scoped to the small
            // corner thumbnail Button itself; SwiftUI resolves a right-click to whichever is
            // deepest under the pointer.
            .contextMenu {
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    if let w = NSApp.windows.first(where: { $0.title == "Add Picture-in-Picture" }) {
                        w.makeKeyAndOrderFront(nil)
                    } else {
                        openWindow(id: "pip-picker")
                    }
                } label: {
                    Label("Add Picture-in-Picture…", systemImage: "pip.fill")
                }
            }
            .animation(.easeOut(duration: 0.35), value: posterHidden)
            .animation(.easeOut(duration: 0.35), value: bridge.hasError)
            .animation(.easeOut(duration: 0.35), value: bridge.hasEnded)
            .animation(.easeOut(duration: 0.25), value: infoOverlayVisible)
            .animation(.easeInOut(duration: 0.2), value: bridge.recordingShowId)
            .onReceive(NotificationCenter.default.publisher(for: .vlcFullScreenChanged)) { note in
                isFullScreen = (note.userInfo?["isFullScreen"] as? Bool) ?? false
            }
            .task(id: effectivePosterImageURL) {
                guard let url = effectivePosterImageURL else { posterNSImage = nil; return }
                posterNSImage = await ChannelIconCache.shared.image(for: url)
            }
        }
        .alert("All Tuners Busy", isPresented: $showTunerFullAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            let count = device.TunerCount.map { "\($0)" } ?? "all"
            Text("\(currentGuideEntry?.Title ?? "This show") is on now, but \(count) tuner(s) on \(device.DeviceID) are occupied. Free a tuner first, then add this show.")
        }
        // See TODO.md's "Watch Now should yield its tuner" entry — offered only when
        // quickRecordMenu's failure handler determined the sole blocker is this instance's own
        // live Watch Now stream on this device (never a real recording or another device/TV).
        .confirmationDialog("Stop Watching & Record?", isPresented: Binding(
            get: { yieldWatchNowConfirm != nil }, set: { if !$0 { yieldWatchNowConfirm = nil } }
        ), presenting: yieldWatchNowConfirm) { req in
            Button("Stop Watching & Record") {
                // Set synchronously, before the Task below even gets a scheduler turn, so the
                // overlay never shows a stale/blank state even for one frame — recordAfterYielding
                // WatchNow itself immediately overwrites this with the same text as its own first
                // step, this just guarantees there's no gap before that Task actually starts.
                posterHidden = false
                state.yieldRecordingProgress = "Stopping live playback — starting \(req.entry.Title)…"
                // startYieldingWatchNowToRecord (not a raw Task) — tracks the task so
                // playerWindowDidClose can cancel it if this window closes mid-wait, and guards
                // against a second overlapping trigger. It already clears yieldRecordingProgress
                // itself on every exit path (success, cancellation, or give-up) — nothing left to
                // do here.
                state.startYieldingWatchNowToRecord(type: req.type, entry: req.entry, device: req.device, channel: req.channel)
            }
            Button("Cancel", role: .cancel) { }
        } message: { req in
            Text("This tuner is only busy because you're watching it here. Stop watching \(req.entry.Title) and start recording it instead? Playback will resume from the recording in a moment.")
        }
        .onAppear {
            glog("[VLC] VLCPlayerView.onAppear device=\(device.DeviceID) initialURL=\(initialURL)")
            refreshCachedLocalRelayCodecs(showId: bridge.recordingShowId)
            availableScreens = NSScreen.screens   // NSScreen.screens is main-thread-only; safe here
            VLCBridge.shared.liveMinRate = Float(state.config.Player_buffer_min_rate) / 100.0
            VLCBridge.shared.setVolume(0)   // muted until Start is clicked
            refreshAudioDevices()
            VLCBridge.shared.startDeviceChangeMonitoring { refreshAudioDevices() }
            VLCBridge.shared.startCastDiscovery()
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
        .onChange(of: bridge.isPlaying) { _, _ in
            // Auto-play for a remote FEED session only — see attemptFeedAutoPlay's own doc
            // comment for the full gate (isPlaying alone isn't enough; also needs
            // feedAutoPlayDelayElapsed, set by the .task(id: bridge.currentURL) below).
            attemptFeedAutoPlay()
        }
        // Arms feedAutoPlayDelayElapsed feedAutoPlayMinDelay seconds after the current stream
        // opened — keyed on bridge.currentURL so a channel switch mid-session (a genuinely new
        // stream, posterHidden reset to false by playChannel) restarts the wait; SwiftUI's own
        // .task(id:) cancellation means the old wait is torn down automatically, never firing late
        // against the new stream.
        .task(id: bridge.currentURL) {
            guard device.isVirtualRelay else { return }
            feedAutoPlayDelayElapsed = false
            try? await Task.sleep(for: .seconds(Self.feedAutoPlayMinDelay))
            guard !Task.isCancelled else { return }
            feedAutoPlayDelayElapsed = true
            attemptFeedAutoPlay()
        }
        // Auto-hides the info banner — keyed on infoOverlayVisible itself, so toggling it false
        // manually (pressing Info again) cancels this pending sleep via .task(id:)'s own identity
        // change rather than needing a separately-tracked Task handle to cancel by hand; toggling
        // it true again (while already true, or after a prior auto-hide) always restarts a fresh
        // window rather than reusing whatever time was left on an old one.
        .task(id: infoOverlayVisible) {
            guard infoOverlayVisible else { return }
            try? await Task.sleep(for: .seconds(Self.infoOverlayAutoHideSeconds))
            guard !Task.isCancelled else { return }
            infoOverlayVisible = false
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
            refreshCachedLocalRelayCodecs(showId: showId)
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
            guard count > 0 else { return }
            // Muted with captions available (and not a recording-relay session — see the CC
            // picker's own guard for why toggling has no visible effect there) — auto-enable
            // instead of the usual force-off below, since there's no audio to convey what's
            // being said otherwise. selectedSpuTrackId is set (not just the direct VLCBridge
            // call) so the Picker's own label reflects the auto-selection instead of drifting
            // from what's actually playing.
            if volume == 0, bridge.recordingShowId == nil, let first = bridge.spuTracks.first {
                selectedSpuTrackId = first.id
                spuChoiceIsExplicit = false
                VLCBridge.shared.setSpuTrack(id: first.id)
            } else {
                // Explicitly disable CC on every channel load; some streams auto-enable it.
                selectedSpuTrackId = -1
                spuChoiceIsExplicit = false
                VLCBridge.shared.setSpuTrack(id: -1)
            }
        }
        .onChange(of: volume) { oldValue, newValue in
            // Rising edge into muted — auto-enable captions the same way the spuTracks-count
            // handler above does on channel load, for the case where the tracks were already
            // known and the user mutes mid-playback instead. Skipped if the user already made an
            // explicit choice (spuChoiceIsExplicit, even "Off" was picked on purpose — -1 is both
            // the Picker's "Off" tag and the unset sentinel, so that alone can't tell the two
            // apart) or this is a recording-relay session (CC picker is hidden there entirely —
            // see its guard).
            if newValue == 0, oldValue > 0, !spuChoiceIsExplicit,
               bridge.recordingShowId == nil, let first = bridge.spuTracks.first {
                selectedSpuTrackId = first.id
                VLCBridge.shared.setSpuTrack(id: first.id)
                return
            }
            // Falling edge out of muted — undo the auto-enable above now that there's audio
            // again. Only fires if the user never made an explicit CC choice while muted
            // (spuChoiceIsExplicit); a real Picker pick during that time — including picking
            // the same track "on" again — is a deliberate choice and must survive unmuting.
            if newValue > 0, oldValue == 0, !spuChoiceIsExplicit, selectedSpuTrackId != -1 {
                selectedSpuTrackId = -1
                VLCBridge.shared.setSpuTrack(id: -1)
            }
        }
        .onDisappear {
            // Safety-net for window close — releasePlayer() is idempotent so calling it here
            // after playerWindowDidClose() already ran is fine. Catches any path where the
            // window delegate didn't fire (e.g. window deallocated without close()).
            glog("[VLC] VLCPlayerView.onDisappear")
            VLCBridge.shared.releasePlayer()
            VLCBridge.shared.stopDeviceChangeMonitoring()
            VLCBridge.shared.stopCastDiscovery()
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
        .onReceive(NotificationCenter.default.publisher(for: .vlcToggleInfoOverlay)) { _ in
            infoOverlayVisible.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            availableScreens = NSScreen.screens
        }
    }

    // Unhides the poster and restores the saved volume — shared by the manual Start click and the
    // remote-FEED auto-play path below, so the two can never drift apart (e.g. one restoring
    // volume, the other forgetting to). `auto` only changes the log line, not the behavior: a FEED
    // session skips the click entirely (see the onChange(of: bridge.isPlaying) handler in body),
    // but still needs the exact same pre-buffer window a manual Start gets — this only fires once
    // bridge.isPlaying is already true, same as the button's own `.disabled(!bridge.isPlaying)`.
    private func startPlayback(auto: Bool) {
        let lag = VLCBridge.shared.bufferInfo.lagSec
        glog("[VLC] \(auto ? "FEED auto-play" : "Start clicked") — buffer ~\(String(format: "%.1f", lag))s built before unmute")
        // Instant, not the poster overlay's usual 0.35s crossfade (.animation(value: posterHidden)
        // in body) — the video has already been decoding/rendering underneath the poster this whole
        // time (mute only silences audio), so an instant reveal exactly matches setVolume's own
        // instant, un-ramped unmute just below. Without this, the poster's fade left the picture
        // visibly appearing ~350ms after audio already started — reported live 2026-09-26.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            posterHidden = true
        }
        VLCBridge.shared.setVolume(Int(volume))
    }

    // Gate for the FEED auto-play path — called both when bridge.isPlaying flips and when the
    // feedAutoPlayMinDelay timer (the .task(id: bridge.currentURL) in body) elapses, since either
    // one can be the last condition to become true. Requested 2026-09-04: isPlaying alone (first
    // confirmed decode, ~3s) fired auto-play too early to build a real cushion against
    // Player_buffer_min_rate's slow ramp — feedAutoPlayDelayElapsed adds a flat minimum real-time
    // wait on top, same value for both the poster reveal and the volume restore/unmute (they fire
    // together in startPlayback — there's no separate "audio delay" to track apart from this).
    private func attemptFeedAutoPlay() {
        guard device.isVirtualRelay, bridge.isPlaying, feedAutoPlayDelayElapsed, !posterHidden else { return }
        startPlayback(auto: true)
    }

    // MARK: - Info overlay ("i" button)

    // How long the info banner stays up before auto-hiding — the toolbar Info button (and its "i"
    // keyboard shortcut) flip infoOverlayVisible true, and the .task(id: infoOverlayVisible) in
    // body sleeps this long then flips it back false, mirroring a TV remote's "i" button (a quick
    // glance at what's playing, then it goes away on its own — pressing it again dismisses early).
    private static let infoOverlayAutoHideSeconds: Double = 6

    // Styled after the classic MTV/VH1 music-video ID card (per-request reference 2026-09-26): a
    // stack of plain serif lines directly over the picture — no card/material background — sitting
    // lower-left rather than the old top-pinned material banner. Deliberately still clears the
    // bottom-pinned recording scrub bar (posterHidden's own overlay above in body, hover-revealed)
    // via bottomClearance below rather than sharing its exact edge, preserving the original
    // no-collision intent while moving into the reference's lower band. Prefers currentGuideEntry
    // (works for both a live channel and a Watch Now recording relay — see its own doc comment on
    // why both anchor correctly) and falls back to the FEED relay's lineup extras the same way
    // posterOverlay already does. Exactly three lines, per explicit request 2026-09-26: show name,
    // episode info (SxxEyy convention, from GuideEntry.episodeInfoLabel), and a last line that
    // describes the *source* rather than the channel alone — "Live OTA"/"Recording"/"FEED", plus
    // whichever channel/hostname detail identifies it (infoBannerSourceLine below). The earlier
    // separate NEW/Originally-aired tag line was dropped to keep to exactly this last line — that
    // info can come back as part of it later if wanted.
    private var infoBanner: some View {
        let entry = currentGuideEntry
        let feedEntry = (entry == nil && device.isVirtualRelay) ? currentFeedEntry : nil

        let title = entry?.Title ?? feedEntry?.virtualRelayShowTitle ?? selectedChannel?.GuideName ?? "Unknown"
        let episodeInfo: String? = entry?.episodeInfoLabel ?? feedEntry.flatMap { fe in
            let parts = [fe.virtualRelayEpisodeNumber, fe.virtualRelayEpisodeTitle].compactMap { s -> String? in
                guard let s, !s.isEmpty else { return nil }
                return s
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
        let sourceLine = infoBannerSourceLine(feedEntry: feedEntry)

        return VStack(alignment: .leading, spacing: 0) {
            Spacer()
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 30, weight: .bold, design: .serif))
                    .lineLimit(2)
                if let episodeInfo {
                    Text(episodeInfo)
                        .font(.system(size: 21, weight: .medium, design: .serif))
                        .lineLimit(1)
                }
                if let sourceLine {
                    Text(sourceLine)
                        .font(.system(size: 17, weight: .regular, design: .serif))
                        .italic()
                        .lineLimit(1)
                }
            }
            .foregroundStyle(Color(white: 0.94))
            .shadow(color: .black.opacity(0.9), radius: 2, x: 1, y: 1)
            .padding(.leading, 44)
            // Clears the recording scrub bar's own 20pt outer padding + its own vertical padding/
            // content height (posterHidden's overlay above) rather than sitting flush on the edge —
            // same no-collision intent the old top-pinned placement had, just satisfied from below.
            .padding(.bottom, 88)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)\(episodeInfo.map { ", \($0)" } ?? "")\(sourceLine.map { ", \($0)" } ?? "")")
    }

    // The card's closing line — what kind of source this is, not just which channel. Live/Recording/
    // FEED are the three sources this app can ever be watching (docs/VLCPlayerView.md's own "Live
    // TV"/"Watch Now"/"FEED" vocabulary), so this always starts with exactly one of those three
    // words, followed by whichever detail identifies it (channel for Live/Recording, source
    // hostname for FEED) — added 2026-09-26 per explicit request that the last line read as
    // descriptive ("Live OTA/Recording/FEED, etc"), not just a bare channel number. selectedChannel
    // can also hold one of two synthetic picker rows (recordingChannelEntries' "live:showId" or
    // feedChannelEntry's "live-feed:url", both above) whose GuideNumber is an ID/URL, not a real
    // channel number — showing it raw ("Ch live:df96c6d0…") would be gibberish, so each resolves
    // back to real detail instead: the recording's own show_channel (mirroring currentGuideEntry's
    // identical showId(fromLiveGuideNumber:) resolution, so this line and the title/episode lines
    // above it always agree on which channel they're describing), or — for a cross-device-swap FEED
    // entry (docs/VLCPlayerView.md's "cross-device swap" note) — the same remoteRelayEntries lookup
    // feedChannelEntry itself used to build that synthetic row, so both paths report the same
    // hostname for the same FEED rather than one showing it and the other falling back to a plain
    // channel label.
    private func infoBannerSourceLine(feedEntry: LineupEntry?) -> String? {
        if let hostname = feedEntry?.virtualRelaySourceHostname { return "FEED · \(hostname)" }
        guard let ch = selectedChannel else { return nil }
        if let recordingShowId = showId(fromLiveGuideNumber: ch.GuideNumber),
           let show = state.recordingShows.first(where: { $0.show_id == recordingShowId }) {
            return "Recording · Ch \(show.show_channel)"
        }
        if ch.GuideNumber.hasPrefix(Self.liveFeedGuideNumberPrefix) {
            let remoteURL = String(ch.GuideNumber.dropFirst(Self.liveFeedGuideNumberPrefix.count))
            let hostname = state.remoteRelayEntries.first { $0.entry.URL == remoteURL }?.entry.virtualRelaySourceHostname
            return "FEED · \(hostname ?? "another Mac")"
        }
        return "Live OTA · Ch \(ch.GuideNumber)  \(ch.GuideName)"
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
                    } else if device.isVirtualRelay, let feedEntry = currentFeedEntry,
                              let feedTitle = feedEntry.virtualRelayShowTitle, !feedTitle.isEmpty {
                        // currentGuideEntry is always nil for a remote FEED device — nothing
                        // populates a discoverer's guideByDevice[relayId] today (a known,
                        // documented gap, TODO.md's "FEED consumers should get a minimal,
                        // locally-sourced 'now playing' guide/lineup"). Without this fallback the
                        // poster showed nothing at all for the full feedAutoPlayMinDelay wait.
                        // These fields (added 2026-09-12) mirror AppState.DiscordEpisodeSnapshot,
                        // carried over the relay's own /lineup.json — see
                        // VirtualTunerService.episodeTitleKey's own doc comment. Same layout as the
                        // currentGuideEntry branch above, just sourced differently.
                        Text(feedTitle)
                            .font(.title2.bold())
                            .foregroundStyle(.white)
                            .lineLimit(2)

                        let epNum   = feedEntry.virtualRelayEpisodeNumber
                        let epTitle = feedEntry.virtualRelayEpisodeTitle
                        switch (epNum, epTitle) {
                        case (let n?, let t?) where !n.isEmpty && !t.isEmpty:
                            Text("\(n)  \(t)")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.75))
                                .lineLimit(1)
                        case (let n?, _) where !n.isEmpty:
                            Text(n)
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.75))
                        case (_, let t?) where !t.isEmpty:
                            Text(t)
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.75))
                                .lineLimit(1)
                        default:
                            EmptyView()
                        }

                        if let synopsis = feedEntry.virtualRelaySynopsis, !synopsis.isEmpty {
                            Text(synopsis)
                                .font(.callout)
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    // FEED sessions never need a click — attemptFeedAutoPlay() always fires once
                    // buffered, whether or not this is on screen — so rendering a *clickable*
                    // Button here would be actively misleading (it looks actionable but clicking
                    // it does nothing auto-play wasn't already about to do on its own). Requested
                    // 2026-09-07 after a live cross-machine test made this visible: the button
                    // rendered for the several real seconds attemptFeedAutoPlay's own buffer/delay
                    // gate takes, reading as "click here" rather than "buffering, please wait."
                    // Same visual content, just non-interactive — the buffering feedback itself
                    // (spinner + label) stays, only the affordance-that-does-nothing goes away.
                    if let yieldProgress = state.yieldRecordingProgress {
                        // Same non-interactive "buffering" treatment as the FEED case just below —
                        // nothing to click here either, this resolves on its own once the new
                        // recording takes over (or, on failure, the normal error/Tuner Conflict
                        // paths this same request would have hit anyway take it from here). Bound
                        // to AppState.yieldRecordingProgress (not a local, set-once @State string)
                        // so this updates live as recordAfterYieldingWatchNow actually progresses —
                        // requested explicitly 2026-09-11: "show what we are doing... provide a
                        // timer, each tick is an attempt to check the status.json... if there is a
                        // delay, provide updates" — a single static message for the whole wait
                        // wasn't good enough once real waits started running 20-40s.
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(yieldProgress)
                        }
                        .font(.title3.bold())
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.white.opacity(0.45))
                        .accessibilityLabel("hdhrVCRplus — \(yieldProgress)")
                        .padding(.top, 4)
                    } else if device.isVirtualRelay {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Buffering…")
                        }
                        .font(.title3.bold())
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.white.opacity(0.45))
                        .accessibilityLabel("hdhrVCRplus — buffering, playback will start automatically")
                        .padding(.top, 4)
                    } else if isPrimaryIdle {
                        // Standalone PIP path (VLCPlayerWindowManager.ensureWindowForStandalonePiP):
                        // the window exists but primary was never handed a URL to play, so
                        // bridge.isPlaying can never become true — without this branch the plain
                        // Button below would show a permanently-disabled "Connecting…" spinner,
                        // reading as stuck rather than intentionally idle.
                        Text("Nothing playing — pick something from the menu bar, or right-click for Picture-in-Picture")
                            .font(.title3.bold())
                            .padding(.horizontal, 22)
                            .padding(.vertical, 12)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                    } else {
                        Button {
                            startPlayback(auto: false)
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
                        .accessibilityIdentifier("vlc-start-button")
                        .padding(.top, 4)
                    }
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
                .accessibilityIdentifier("vlc-retry-button")
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
                    .accessibilityIdentifier("vlc-play-again-button")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    // MARK: - Picture-in-picture corner overlay
    //
    // Small, fixed-size, video-only, always-muted corner thumbnail for whatever is playing in
    // VLCBridge's secondary slot — see TODO.md's "Watch two live streams at once" entry for the
    // full design. Deliberately minimal: no track picker, no scrub bar, no buffer overlay. Pinned
    // to whichever corner `pipCorner` holds (right-click the thumbnail to change it) using the
    // same "Spacer()+padding+.ultraThinMaterial" idiom as the recording scrub bar/fullscreen
    // toolbar overlays above, not new chrome.
    // Sized to the secondary stream's own native aspect ratio once known
    // (bridge.secondaryVideoPixelSize — published by tickSecondary(), nil until the first decoded
    // frame) rather than assuming 16:9, so a 4:3 (or any other) channel's thumbnail is shaped to
    // match instead of always being letterboxed/pillarboxed inside a fixed 16:9 box. Width fixed;
    // height follows the ratio. Falls back to 16:9 before real dimensions are known.
    private static let pipThumbnailMaxWidth: CGFloat = 192

    private var pipThumbnailSize: CGSize {
        Self.pipThumbnailSize(nativePixelSize: bridge.secondaryVideoPixelSize, maxWidth: Self.pipThumbnailMaxWidth)
    }

    /// Pure decision, extracted for unit testing. `nativePixelSize` invalid/unknown (nil, or either
    /// dimension <= 0) → 16:9 fallback, since libvlc hasn't reported real dimensions yet.
    nonisolated static func pipThumbnailSize(nativePixelSize: CGSize?, maxWidth: CGFloat) -> CGSize {
        guard let native = nativePixelSize, native.width > 0, native.height > 0 else {
            return CGSize(width: maxWidth, height: (maxWidth * 9 / 16).rounded())
        }
        let height = (maxWidth * native.height / native.width).rounded()
        return CGSize(width: maxWidth, height: height)
    }

    private var pipOverlay: some View {
        VStack {
            if !pipCorner.isTop { Spacer() }
            HStack {
                if !pipCorner.isLeading { Spacer() }
                ZStack(alignment: .topTrailing) {
                    // A real Button, not .onTapGesture — every other clickable control in this file
                    // (Start, Retry, Play Again, the close button right below) is a Button for this
                    // exact reason: a bare .onTapGesture over a hosted NSViewRepresentable doesn't
                    // expose any actionable accessibility element (confirmed live: VoiceOver/AX
                    // automation could find and click the close button below by its identifier, but
                    // never found any element at all for a .onTapGesture-only thumbnail) — a plain
                    // Button gets that for free.
                    Button {
                        swapPrimaryAndSecondary()
                    } label: {
                        ZStack {
                            VLCSecondaryVideoSurface()
                            if bridge.secondaryHasError {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.yellow)
                            } else if bridge.secondaryHasEnded {
                                Image(systemName: "stop.circle")
                                    .foregroundStyle(.white.opacity(0.8))
                            } else if !bridge.secondaryIsPlaying {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            }
                        }
                        .frame(width: pipThumbnailSize.width, height: pipThumbnailSize.height)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.25)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("vlc-pip-thumbnail")
                    .accessibilityLabel("Swap to picture-in-picture stream")
                    .contextMenu {
                        pipCornerMenu
                        pipChannelMenu
                    }

                    Button {
                        VLCPlayerWindowManager.shared.closeSecondary()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.white, .black.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                    .accessibilityIdentifier("vlc-pip-close-button")
                    .accessibilityLabel("Close picture-in-picture")
                }
                if pipCorner.isLeading { Spacer() }
            }
            if pipCorner.isTop { Spacer() }
        }
        .padding(16)
    }

    // Right-click menu on the PiP thumbnail — the user-facing way to move it, per an explicit
    // request (TODO.md's PiP entry). A checkmark marks the corner currently in effect, matching
    // the convention a native macOS pull-down/context menu uses for a single-choice setting.
    @ViewBuilder
    private var pipCornerMenu: some View {
        ForEach(PipCorner.allCases, id: \.self) { corner in
            Button {
                pipCorner = corner
            } label: {
                if corner == pipCorner {
                    Label(corner.displayName, systemImage: "checkmark")
                } else {
                    Text(corner.displayName)
                }
            }
        }
    }

    // In-place channel switch for the PiP secondary, added to its right-click menu alongside
    // pipCornerMenu above — live-channel secondaries only (secondaryChannelNumber is nil for a
    // FEED or Watch Now secondary, see PiPPickerView/watchAsSecondary call sites; neither has a
    // channel lineup to switch within). Reverses the original "no in-place channel/source changes"
    // design (docs/VLCPlayerView.md) per explicit request — the corner-only right-click menu was
    // the only way to reposition, so extending that same menu to also retune was the natural fit
    // rather than a separate picker UI. Scoped to the secondary's own device (state.lineups[
    // deviceId]), which may differ from the primary's bound device (cross-device secondaries are
    // supported — see "The secondary is not restricted to the primary's own tuner/device" above).
    @ViewBuilder
    private var pipChannelMenu: some View {
        let mgr = VLCPlayerWindowManager.shared
        if let deviceId = mgr.secondaryDeviceID, mgr.secondaryChannelNumber != nil {
            let all = (state.lineups[deviceId] ?? []).sorted {
                $0.GuideNumber.localizedStandardCompare($1.GuideNumber) == .orderedAscending
            }
            let favs = all.filter(\.isFavorite)
            let others = all.filter { !$0.isFavorite }
            Divider()
            Menu("Channel") {
                ForEach(favs, id: \.GuideNumber) { ch in
                    Button("\(ch.GuideNumber)  \(ch.GuideName)") { playSecondaryChannel(ch, deviceId: deviceId) }
                }
                if !favs.isEmpty && !others.isEmpty { Divider() }
                ForEach(others, id: \.GuideNumber) { ch in
                    Button("\(ch.GuideNumber)  \(ch.GuideName)") { playSecondaryChannel(ch, deviceId: deviceId) }
                }
            }
        }
    }

    private func playSecondaryChannel(_ ch: LineupEntry, deviceId: String) {
        guard let rawURL = ch.URL, !rawURL.isEmpty else {
            glog("[VLC] playSecondaryChannel skipped — no URL for ch=\(ch.GuideNumber) \(ch.GuideName)", level: .warning)
            return
        }
        let url = state.config.applyTranscode(rawURL)

        // Same reuses-existing-tuner gate as playChannel (see its own doc comment) — the Channel
        // submenu is always built from state.lineups[mgr.secondaryDeviceID], so deviceId here
        // normally equals the device the secondary already holds (a same-device retune, safe to
        // start immediately). Still checked the same way playChannel is, rather than assumed,
        // in case a future caller ever routes a genuinely different device through this function.
        let mgr = VLCPlayerWindowManager.shared
        let reusingExistingTunerHere = Self.reusesExistingTuner(
            currentDeviceID: mgr.secondaryDeviceID,
            targetDeviceID: deviceId,
            recordingShowId: nil,
            currentFeedRemoteURL: mgr.secondaryFeedRemoteURL,
            currentURL: VLCBridge.shared.secondaryURL)

        func startPlaySecondaryChannel() {
            glog("[VLC] playSecondaryChannel \(ch.GuideNumber) \(ch.GuideName) → \(url)")
            VLCBridge.shared.play(url: url, slot: .secondary)
            VLCPlayerWindowManager.shared.retuneSecondary(channelNumber: ch.GuideNumber, title: ch.GuideName)
        }

        if reusingExistingTunerHere {
            startPlaySecondaryChannel()
        } else if let target = state.recordableDevices.first(where: { $0.DeviceID == deviceId }) {
            Task {
                guard await state.tunerAvailable(target, context: ch.GuideName) else { return }
                startPlaySecondaryChannel()
            }
        } else {
            startPlaySecondaryChannel()
        }
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
                if !recordingChannelEntries.isEmpty || feedChannelEntry != nil {
                    Text("Live").tag(Optional<LineupEntry>.none)
                }
                // One row per show currently recording on this device — GuideName already holds
                // the full "Live 5.1  Title" label, so it's rendered directly (not the
                // "GuideNumber  GuideName" template below, which would show the synthetic tag).
                ForEach(recordingChannelEntries, id: \.GuideNumber) { entry in
                    Text(entry.GuideName).tag(Optional(entry))
                }
                // A cross-device FEED swapped in as primary — see feedChannelEntry's own doc
                // comment for why this is separate from recordingChannelEntries above.
                if let feedEntry = feedChannelEntry {
                    Text(feedEntry.GuideName).tag(Optional(feedEntry))
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
            .accessibilityLabel("Channel")
            .accessibilityIdentifier("vlc-channel-picker")
            .onChange(of: selectedChannel) { _, ch in
                // Reset unconditionally, before the suppress check below — a synced (externally
                // triggered) channel switch still means the track list underneath genuinely
                // changed, even though suppressNextChannelPlay skips re-triggering playback here.
                // Resetting only on the non-suppressed path left the picker holding a stale track
                // id from the previous channel after a synced switch.
                selectedAudioTrackId = -1
                selectedSpuTrackId   = -1
                spuChoiceIsExplicit  = false
                if suppressNextChannelPlay {
                    suppressNextChannelPlay = false
                    // The live→disk yield handoff (syncChannel's recording-relay match) is the one
                    // suppressed case that ISN'T a genuine content change — it relabels the picker
                    // for the *same* show already playing, so it alone also sets suppressSameContent
                    // and must skip the poster/mute reset below — root-caused 2026-09-11: this
                    // handler used to unconditionally blank posterNSImage/reopen posterHidden anyway,
                    // and since .task(id: currentGuideEntry?.ImageURL) only re-fires when the image
                    // URL actually changes (it doesn't here — currentGuideEntry's own synthetic-entry
                    // resolution deliberately maps back to the same real show), nothing ever
                    // repopulated it: the show's poster/logo was gone for the rest of that session.
                    if suppressSameContent { suppressSameContent = false; return }
                    // Any other suppressed switch IS genuine new content — most notably switching
                    // which FEED show is playing (VLCPlayerWindowManager.open reuses this window/
                    // view when the source device doesn't change, so no fresh .onAppear ever runs
                    // for the new stream). Root-caused 2026-09-14, live report: without this reset,
                    // posterHidden stayed true (left over from the *first* FEED show's successful
                    // auto-play), so attemptFeedAutoPlay's `!posterHidden` guard silently failed for
                    // every subsequent switch — the video genuinely changed (VLCBridge.play(url:)
                    // loaded the new stream regardless) but audio stayed muted at the volume 0
                    // VLCPlayerWindowManager.open sets before every play() call, forever. Falling
                    // through to the same poster/mute reset the direct-picker path uses below lets
                    // attemptFeedAutoPlay's delayed re-arm (.task(id: bridge.currentURL), already
                    // correctly restarting on the new URL) actually restore volume once buffered —
                    // playChannel/watchRecordingInApp itself must still stay skipped since the
                    // caller (VLCPlayerWindowManager.open) already started this exact stream.
                    posterHidden = false
                    posterNSImage = nil
                    VLCBridge.shared.setVolume(0)
                    return
                }
                posterHidden = false
                posterNSImage = nil
                VLCBridge.shared.setVolume(0)
                guard let ch else { return }
                if let showId = showId(fromLiveGuideNumber: ch.GuideNumber) {
                    guard let show = state.shows.first(where: { $0.show_id == showId }) else { return }
                    state.watchRecordingInApp(show)
                } else {
                    playChannel(ch)
                }
            }

            // Quick-record: same four-type pulldown as Watch Now's Record button
            // (WatchNowRow/quickRecordMenu, GuideViewHelpers.swift) — icon-only here since the
            // toolbar has no room to spare for a labeled button. Hidden while watching a
            // recording-relay stream (already being captured, see bridge.recordingShowId),
            // when nothing's currently airing on the selected channel, or when this exact
            // channel already has an active managed show (avoids offering a redundant add).
            if bridge.recordingShowId == nil, let ch = selectedChannel, let entry = currentGuideEntry,
               !state.shows.contains(where: { $0.show_active && $0.hdhr_record == device.DeviceID && $0.show_channel == ch.GuideNumber }) {
                quickRecordMenu(state: state, entry: entry, device: device, channel: ch,
                                 tunerFullAlert: $showTunerFullAlert, yieldWatchNowConfirm: $yieldWatchNowConfirm) {
                    Label("Record", systemImage: "record.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .accessibilityLabel("Record \(entry.Title)")
                .accessibilityIdentifier("vlc-quick-record")
                .help("Record \(entry.Title)")
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
                    catchUpButton(showLabel: false)
                        .padding(.leading, 5)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            } else {
                catchUpButton(showLabel: true)
            }

            // Raw/H.264 toggle for a remote FEED session — see currentFeedEntry's own doc comment.
            // Hidden when the source is already a modern codec, same as MenuContent's own "Recording
            // on Another Mac" menu only offering a second Watch (H.264) item under that condition —
            // a source that's already H.264/HEVC would just get relayed as-is regardless, making the
            // toggle a no-op.
            if device.isVirtualRelay, !feedSourceAlreadyModern {
                Divider().frame(height: 18)
                Toggle(isOn: Binding(
                    get: { feedIsTranscoding },
                    set: { toggleFeedTranscode(to: $0) }
                )) {
                    Text("H.264")
                }
                .toggleStyle(.checkbox)
                .help(feedIsTranscoding ? "Switch to the raw source stream" : "Switch to H.264 (transcoded by the source Mac)")
                .accessibilityLabel("H.264 transcode")
                .accessibilityValue(feedIsTranscoding ? "On" : "Off")
                .accessibilityIdentifier("vlc-feed-transcode-toggle")
            }

            // Native resolution: resize window to 1:1 physical pixels.
            // Glows at full saturation when native is achievable but the window isn't already
            // there; dims to the same hue once already at native. The hue itself is
            // nativeIconSourceColor (blue = network, purple = disk, indigo = FEED — added
            // 2026-09-11, FEED case added 2026-09-13) so the icon doubles as an at-a-glance
            // "where is this data actually coming from" indicator, not just "can I resize this."
            Button {
                VLCPlayerWindowManager.shared.sizeToNativeVideo()
            } label: {
                Label("Native", systemImage: "aspectratio")
                    .foregroundStyle(!canResize ? AnyShapeStyle(.tertiary) : AnyShapeStyle(nativeIconSourceColor.opacity(notAtNative ? 1.0 : 0.55)))
                    .shadow(color: notAtNative ? nativeIconSourceColor.opacity(0.6) : .clear, radius: 5)
            }
            .buttonStyle(.plain)
            .disabled(!canResize)
            .accessibilityIdentifier("vlc-native-resolution")
            .onHover { if $0 { recordingSizeSnapshot = recordingSizeText; nativeResHovered = true } }
            .popover(isPresented: $nativeResHovered, arrowEdge: .bottom) { nativeResPopover }

            // Info ("i" on a TV remote) — toggles a temporary banner over the video with the show
            // name, episode info, and a source-type closing line. See infoBanner's own doc comment
            // for what it shows per source type. The "i" key itself is handled by
            // VLCPlayerWindowManager's installKeyMonitor (a local NSEvent monitor, not
            // .keyboardShortcut here) — see that method's own doc comment for why a bare-letter
            // SwiftUI shortcut wasn't reliable; this button's click action stays the same either way.
            Button {
                infoOverlayVisible.toggle()
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.plain)
            .help("Show info")
            .accessibilityLabel("Show info")
            .accessibilityIdentifier("vlc-info-button")

            // Group dividers, added 2026-09-19 (reported "crowded") — purely visual breathing room
            // between logical clusters (stream state: buffer/catch-up/H.264/native — clock — volume
            // — the existing pre-overflow divider below), no functional change to any control.
            Divider().frame(height: 18)

            // Live wall-clock time. The recording scrub bar lives in a hover overlay on the video
            // instead (see body's ZStack) rather than here — it needs more room than this toolbar
            // has to spare alongside everything else.
            TimelineView(.periodic(from: .now, by: 1.0)) { ctx in
                Text(ctx.date, style: .time)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 70)
            }

            Divider().frame(height: 18)

            // Volume
            Image(systemName: "speaker.wave.2")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(value: $volume, in: 0...100)
                .frame(width: 100)
                .accessibilityLabel("Volume")
                .accessibilityIdentifier("vlc-volume-slider")
                .onChange(of: volume) { _, v in
                    VLCBridge.shared.setVolume(Int(v))
                }

            // Audio track / captions / audio output / display — consolidated into one overflow
            // menu (added 2026-09-13) rather than up to four always-visible icon+picker+divider
            // groups. These are "set once per session, rarely touched again" choices, unlike the
            // channel picker/catch-up/native/volume controls above, which stay directly in the
            // toolbar since they're adjusted far more often. No option was removed — every one of
            // these four sub-menus keeps exactly the same visibility condition and side effect
            // (VLCBridge call / state update) it had as a standalone Picker; still individually
            // hidden here when not applicable (e.g. a single-audio-track live channel shows no
            // "Audio Track" row at all, same as it previously showed no picker at all).
            let hasAudioTrackChoice = bridge.audioTracks.count > 1
            let hasCaptionChoice = !bridge.spuTracks.isEmpty && bridge.recordingShowId == nil
            let hasOutputChoice = !systemDevices.isEmpty
            let hasDisplayChoice = availableScreens.count > 1
            // Unlike the other three, this doesn't hide when empty — Chromecast discovery is
            // async LAN mDNS and can take several seconds, so a menu entry that sometimes exists
            // and sometimes doesn't (purely based on discovery timing) would read as broken
            // rather than "not applicable." Always offered once VLC itself is available;
            // discovery result only affects the submenu's *contents*.
            let hasCastEntry = bridge.isAvailable
            if hasAudioTrackChoice || hasCaptionChoice || hasOutputChoice || hasDisplayChoice || hasCastEntry {
                Divider().frame(height: 18)
                Menu {
                    // Captions listed first — moved to the top 2026-09-19 per explicit request
                    // ("crowded, and not well placed"); previously sorted after Audio Track. Never
                    // shown for a recording-relay session (bridge.recordingShowId != nil):
                    // switching SPU tracks while reading the relay's on-disk file back doesn't
                    // produce a visible result, so a menu that looks like it does something but
                    // doesn't would be worse than not offering it at all.
                    if hasCaptionChoice {
                        Menu {
                            // A direct assignment here (not the custom binding the old Picker
                            // used) still marks the choice explicit — spuChoiceIsExplicit only
                            // exists to distinguish a real tap from the programmatic resets
                            // elsewhere in this file, and every path through this menu is a real tap.
                            Button {
                                selectedSpuTrackId = -1; spuChoiceIsExplicit = true
                                VLCBridge.shared.setSpuTrack(id: -1)
                            } label: {
                                if selectedSpuTrackId < 0 { Label("Off", systemImage: "checkmark") } else { Text("Off") }
                            }
                            ForEach(bridge.spuTracks, id: \.id) { track in
                                Button {
                                    selectedSpuTrackId = track.id; spuChoiceIsExplicit = true
                                    VLCBridge.shared.setSpuTrack(id: track.id)
                                } label: {
                                    if track.id == selectedSpuTrackId { Label(track.name, systemImage: "checkmark") }
                                    else { Text(track.name) }
                                }
                            }
                        } label: { Label("Captions", systemImage: "captions.bubble") }
                        .accessibilityIdentifier("vlc-cc-picker")
                    }
                    if hasAudioTrackChoice {
                        Menu {
                            ForEach(bridge.audioTracks, id: \.id) { track in
                                Button {
                                    selectedAudioTrackId = track.id
                                    VLCBridge.shared.setAudioTrack(id: track.id)
                                } label: {
                                    if track.id == selectedAudioTrackId { Label(track.name, systemImage: "checkmark") }
                                    else { Text(track.name) }
                                }
                            }
                        } label: { Label("Audio Track", systemImage: "headphones") }
                        .accessibilityIdentifier("vlc-audio-track-picker")
                    }
                    if hasOutputChoice {
                        Menu {
                            ForEach(systemDevices, id: \.id) { dev in
                                // AirPlay speakers get a name suffix, not a second icon — a Menu
                                // row only renders one Label/systemImage slot (checkmark or
                                // plain), so a second badge glyph has nowhere to go.
                                let label = dev.isAirPlay ? "\(dev.name) (AirPlay)" : dev.name
                                Button {
                                    selectedDevice = dev.id
                                    VLCBridge.shared.setAudioDevice(output: "auhal", deviceId: dev.id)
                                } label: {
                                    if dev.id == selectedDevice { Label(label, systemImage: "checkmark") }
                                    else { Text(label) }
                                }
                            }
                        } label: { Label("Audio Output", systemImage: "airplayaudio") }
                        .accessibilityIdentifier("vlc-audio-output-picker")
                    }
                    if hasDisplayChoice {
                        Menu {
                            // Plain, non-interactive tip row — a Button (e.g. InfoButton) here
                            // would dismiss this submenu the instant it's tapped, since any
                            // Button inside a SwiftUI Menu closes the enclosing menu. A bare Text
                            // with no action renders inert, same idea as a disabled row.
                            Text("Tip: connect via Control Center → Screen Mirroring first")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(availableScreens, id: \.displayID) { screen in
                                Button(screen.localizedName) {
                                    VLCPlayerWindowManager.shared.moveToScreen(screen)
                                }
                            }
                        } label: { Label("Display", systemImage: "airplayvideo") }
                        .help("Connect an Apple TV or AirPlay-capable TV via Control Center → Screen Mirroring first, then pick it here to move playback to that display.")
                        .accessibilityIdentifier("vlc-display-menu")
                    }
                    if hasCastEntry {
                        Menu {
                            if bridge.castDevices.isEmpty {
                                Text("No devices found").foregroundStyle(.secondary)
                            } else {
                                // "This Mac" is the explicit off-state row (same shape as the
                                // Captions picker's own "Off" row above), not a separate action.
                                Button {
                                    VLCBridge.shared.stopCasting()
                                } label: {
                                    if bridge.castingDeviceID == nil { Label("This Mac", systemImage: "checkmark") }
                                    else { Text("This Mac") }
                                }
                                ForEach(bridge.castDevices, id: \.id) { dev in
                                    Button {
                                        VLCBridge.shared.castTo(deviceID: dev.id)
                                    } label: {
                                        if dev.id == bridge.castingDeviceID { Label(dev.name, systemImage: "checkmark") }
                                        else { Text(dev.name) }
                                    }
                                }
                            }
                        } label: { Label("Cast", systemImage: "tv") }
                        .accessibilityIdentifier("vlc-cast-picker")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .frame(maxWidth: 24)
                .help("Audio, captions, output, display, and cast options")
                .accessibilityLabel("More options")
                .accessibilityIdentifier("vlc-more-options-menu")
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
                    .accessibilityIdentifier("vlc-recording-scrub-slider")
                    Text(ctx.date, style: .time)
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
    }

    // MARK: - Buffer monitor

    // showLabel: false inside the compact buffer-monitor pill (no room for text there — the pill's
    // own hover popover already covers detail); true standalone, where there's space for a label.
    private func catchUpButton(showLabel: Bool) -> some View {
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
            Group {
                if showLabel {
                    Label(bridge.recordingShowId != nil ? "Live Edge" : "Catch Up", systemImage: "forward.end.circle")
                } else {
                    Image(systemName: "forward.end.circle")
                }
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(bridge.recordingShowId != nil
              ? "Jump to the live edge of the recording"
              : "Speed up to live — discard buffer and jump to live edge")
        // The icon-only (showLabel: false) case has no Text for SwiftUI to auto-derive a label
        // from — explicit here so VoiceOver announces something meaningful either way, not just
        // the SF Symbol's raw name.
        .accessibilityLabel(bridge.recordingShowId != nil ? "Live Edge" : "Catch Up")
        .accessibilityIdentifier("vlc-catch-up-button")
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
        .accessibilityIdentifier("vlc-buffer-monitor")
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
            // Shown regardless of whether a frame has decoded yet — recordingShowId is known
            // (or not) independent of video-pixel-size, and this is the more fundamental fact.
            HStack {
                Circle().fill(nativeIconSourceColor).frame(width: 8, height: 8)
                // FEED case added 2026-09-13, same reasoning as nativeIconSourceColor's own
                // comment — "Live network stream" was true but misleading for a FEED session: it
                // reads over the network like a live tuner does, but what's actually arriving is
                // the source Mac's own recording being read off *its* disk, not a live broadcast.
                // Names the source Mac when known (LineupEntry.virtualRelaySourceHostname, the
                // same /lineup.json extra MenuContent's "Watching FEED from <hostname>" row uses)
                // rather than just "FEED" alone, for the same reason that row does.
                if device.isVirtualRelay {
                    Text("Network → Disk (FEED" + (currentFeedEntry?.virtualRelaySourceHostname.map { " from \($0)" } ?? "") + ")")
                } else {
                    Text(bridge.recordingShowId != nil ? "Local recording (disk)" : "Live network stream")
                }
            }
            // A plain on-disk-size snapshot, not a tracked/ticking value like the separate "Live
            // Buffer" popover's lagSec — recomputed fresh each time this popover opens (captured
            // into recordingSizeSnapshot by the "Native" button's .onHover, not read live here),
            // not on any timer, per an explicit request that this not need continuous tracking.
            // Only meaningful for the disk-relay case (a live network stream has no local file to
            // check).
            if bridge.recordingShowId != nil, let recordingSizeSnapshot {
                row("On disk", recordingSizeSnapshot)
            }
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

    private func syncChannel(to rawSyncURL: String) {
        guard !rawSyncURL.isEmpty else { return }
        // Read-and-clear once per call — see the flag's own doc comment.
        let wasSwap = suppressPosterResetForSwap
        suppressPosterResetForSwap = false
        // FEED's client-side local relay (docs/VirtualTunerService.md) means every caller of this
        // function — .onAppear's initialURL, state.vlcCurrentURL, bridge.recordingShowId's onChange
        // — now hands this a LOCAL http://127.0.0.1/api/feed-local-relay?... URL for a virtual
        // relay device, which can never match anything in `lineup` (this device's real, remote
        // lineup entries). Same fix as currentFeedEntry/feedIsTranscoding above: substitute the
        // true remote URL before matching.
        let url = device.isVirtualRelay ? (VLCPlayerWindowManager.shared.currentFeedRemoteURL ?? rawSyncURL) : rawSyncURL
        let base = url.urlBase
        // A FEED swapped in as primary from a *different* device than this window's own bound
        // `device` — device.isVirtualRelay is false here (this window opened on a real tuner, not
        // the FEED's source), so the substitution just above never fires and `lineup` has nothing
        // to match against at all. feedChannelEntry's own doc comment has the full story; this is
        // its resolution counterpart, checked via VLCPlayerWindowManager.currentFeedRemoteURL
        // directly (a definitive "is a FEED primary right now" signal) rather than fuzzy URL
        // matching, the same way the recording-relay branch below trusts bridge.recordingShowId
        // over matching its own local relay URL.
        if !device.isVirtualRelay, VLCPlayerWindowManager.shared.currentFeedRemoteURL != nil,
           let entry = feedChannelEntry {
            glog("[VLC] syncChannel matched cross-device FEED \(entry.GuideName) for url=\(base)")
            MPNowPlayingInfoCenter.default().nowPlayingInfo = [
                MPMediaItemPropertyTitle:             entry.GuideName,
                MPMediaItemPropertyArtist:            "Live",
                MPNowPlayingInfoPropertyIsLiveStream: true
            ]
            MPNowPlayingInfoCenter.default().playbackState = .playing
            guard selectedChannel?.GuideNumber != entry.GuideNumber else { return }
            // This branch is only ever reachable via a PiP swap — device.isVirtualRelay is false
            // means this window opened on a real device, and the only way currentFeedRemoteURL can
            // be non-nil then is swapPrimaryAndSecondary() having brought a FEED in as primary (a
            // direct FEED open always sets device to the virtual relay itself, taking the normal
            // lineup-match branch below instead). Always "relabel only," never genuine new content
            // — the stream is already playing/decoding, unlike an open()-driven switch — so
            // suppressSameContent is safe unconditionally here (found live 2026-09-19 without it:
            // the poster/mute reset below wrongly fired, re-gating an already-live swapped-in
            // stream behind a Start button and dropping its poster/summary).
            suppressNextChannelPlay = true
            suppressSameContent     = true
            selectedChannel = entry
            return
        }
        // Recording-relay stream: match against bridge.recordingShowId directly against ALL
        // recording shows, not just this device's own (recordingChannelEntries) — the relay URL
        // (docs/WebServer.md) never matches a real channel URL, and bridge.recordingShowId already
        // uniquely identifies the exact show regardless of which device it's recording on, so no
        // device filter is needed here at all. Fixed 2026-09-26, live report ("Unknown" in the info
        // banner): watchRecordingInAppAsSecondary lets a PiP secondary be a recording on a
        // *different* device (PiPPickerView's recording list isn't scoped to one device) — the old
        // device-filtered recordingChannelEntries lookup silently missed that show entirely once a
        // swap made it primary, same root cause as the cross-device live-channel branch below.
        // AppState.watchRecordingInApp defers setting bridge.recordingShowId to the next run-loop
        // turn (see its comment — a SwiftUI render-timing fix), so this can miss on the very first
        // call from .onAppear; the .onChange(of: bridge.recordingShowId) handler below re-runs it
        // once that lands.
        if base.contains("/api/watch-recording"), let showId = bridge.recordingShowId,
           let show = state.recordingShows.first(where: { $0.show_id == showId }) {
            let entry = Self.liveRecordingEntry(for: show)
            glog("[VLC] syncChannel matched recording \(entry.GuideName) for url=\(base)")
            MPNowPlayingInfoCenter.default().nowPlayingInfo = [
                MPMediaItemPropertyTitle:             entry.GuideName,
                MPMediaItemPropertyArtist:            "Live",
                MPNowPlayingInfoPropertyIsLiveStream: true
            ]
            MPNowPlayingInfoCenter.default().playbackState = .playing
            guard selectedChannel?.GuideNumber != entry.GuideNumber else { return }
            suppressNextChannelPlay = true
            suppressSameContent     = true   // same show, relabel-only — see its own doc comment
            selectedChannel = entry
            return
        }
        // Cross-device swap landing on a plain LIVE channel (not FEED, not a recording relay) — the
        // one case feedChannelEntry doesn't cover. `lineup` below only ever reflects this window's
        // own bound `device`, so a live channel actually belonging to a *different* device (reached
        // via watchAsSecondary's device picker, PiPPickerView's "Live TV" section) has nothing in it
        // to match `base` against — docs/VLCPlayerView.md's "cross-device swap" note explicitly
        // called this an accepted deeper limitation, unlike the FEED case fixed 2026-09-19.
        // Deliberately NOT gated on `!device.isVirtualRelay` (an earlier version of this fix was,
        // and shipped broken) — `device` being the virtual relay itself doesn't mean the CURRENT
        // primary still is: a FEED window (device.isVirtualRelay == true) with a real live channel
        // swapped into primary via PiP is exactly this same gap, confirmed live via the laptop's own
        // log right after this fix's first deploy: `swapSlots()` → `syncChannel: <real channel URL>`
        // → `"no match in 1-entry lineup"` (the FEED device's own 1-entry synthetic lineup, which a
        // real channel from an unrelated device obviously isn't in). `otherDeviceId != device.DeviceID`
        // alone already correctly excludes the untouched-FEED-primary case (currentDeviceID still
        // equals device.DeviceID then), so the extra check was both redundant and wrong. Fixed
        // 2026-09-26, live report: left selectedChannel nil indefinitely, showing "Unknown" in the
        // info banner (and a blank picker) for as long as the swap lasted. Looks up the swapped-in
        // device's own lineup directly rather than this view's `lineup`.
        if let otherDeviceId = VLCPlayerWindowManager.shared.currentDeviceID,
           otherDeviceId != device.DeviceID,
           let match = (state.lineups[otherDeviceId] ?? []).first(where: { ($0.URL ?? "").urlBase == base }) {
            glog("[VLC] syncChannel matched cross-device live channel \(match.GuideNumber) \(match.GuideName) on \(otherDeviceId) for url=\(base)")
            updateNowPlaying(channel: match)
            guard selectedChannel?.GuideNumber != match.GuideNumber else { return }
            suppressNextChannelPlay = true
            suppressSameContent     = true   // already playing/decoding via the swap, not a fresh switch
            selectedChannel = match
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
            if wasSwap { suppressSameContent = true }
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

        // A genuine live-channel-to-live-channel switch on this device reuses the tuner slot
        // already held by whatever's currently playing — matches AppState.watchInApp's own
        // "switching channels within an already-open player on the same device skips the check
        // entirely (reuses the existing slot)" rule, so it's safe to start immediately just like
        // always. But the primary might currently hold no real tuner slot on THIS device at all —
        // a FEED or Watch Now relay (recordingShowId/currentFeedRemoteURL non-nil), or a live
        // channel from a *different* device (currentDeviceID != device.DeviceID) — most commonly
        // reachable here via a PiP swap (see docs/VLCPlayerView.md's "cross-device swap" note). In
        // that case this genuinely is a brand-new tuner request, and needs the same pre-flight
        // availability check watchInApp already does before opening on a different device — found
        // live 2026-09-19: FEED (0 tuners on this device) → live-channel switch, on a device
        // already at capacity from two other machines' recordings, silently hung with no
        // explanation instead of the "All Tuners Busy" alert every other entry point shows.
        let reusingExistingTunerHere = Self.reusesExistingTuner(
            currentDeviceID: VLCPlayerWindowManager.shared.currentDeviceID,
            targetDeviceID: device.DeviceID,
            recordingShowId: bridge.recordingShowId,
            currentFeedRemoteURL: VLCPlayerWindowManager.shared.currentFeedRemoteURL,
            currentURL: bridge.currentURL)

        if reusingExistingTunerHere {
            startPlayChannel(ch, url: url)
        } else {
            Task {
                guard await state.tunerAvailable(device, context: ch.GuideName) else { return }
                startPlayChannel(ch, url: url)
            }
        }
    }

    /// Pure decision, extracted for unit testing — true when switching to a channel on
    /// `targetDeviceID` would reuse a tuner slot already held there, false when it's a genuinely
    /// new tuner request that needs a pre-flight availability check first. See playChannel's own
    /// doc comment for the full reasoning.
    nonisolated static func reusesExistingTuner(currentDeviceID: String?, targetDeviceID: String,
                                                 recordingShowId: String?, currentFeedRemoteURL: String?,
                                                 currentURL: String?) -> Bool {
        currentDeviceID == targetDeviceID
            && recordingShowId == nil
            && currentFeedRemoteURL == nil
            && !(currentURL ?? "").isEmpty
    }

    private func startPlayChannel(_ ch: LineupEntry, url: String) {
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
    // Typed reference to the hosted content so open()'s reuse branch can swap rootView when the
    // device changes (see open()'s deviceChanged handling) — window.contentView alone is only
    // NSView, with no rootView setter. AnyView-erased rather than NSHostingView<VLCPlayerView>
    // because the actual rootView type is VLCPlayerView wrapped in .environmentObject()/.id()
    // modifiers (an unspellable-by-hand generic), not VLCPlayerView itself.
    private var hostingView: NSHostingView<AnyView>?
    private var closeObserver: WindowCloseObserver?  // strong ref — NSWindow.delegate is weak

    /// DeviceID of the tuner currently occupied by the player window; nil when closed.
    private(set) var currentDeviceID: String?
    /// GuideNumber of the channel `open()` was last called with; nil when closed or when the
    /// caller didn't pass one (e.g. the watch-recording relay, which occupies no tuner at all —
    /// see AppState.vlcOccupiesTuner). Lets AppState.vlcLiveChannel(for:) tell "this app is live-
    /// watching this exact channel" apart from "some other tuner on this device is in use", so the
    /// in-use-by-other-tuner marker doesn't flag your own live Watch session as someone else's.
    private(set) var currentChannelNumber: String?
    // FEED client-side local relay (docs/VirtualTunerService.md) — set by AppState.
    // startFeedLocalRelay right before it hands VLC the local relay URL, so VLCPlayerView can
    // still tell which remote Mac/URL is actually being watched even though bridge.currentURL now
    // holds the local http://127.0.0.1:<port>/api/feed-local-relay?... URL, not the real one.
    private(set) var currentFeedRemoteURL: String?
    private(set) var currentFeedSessionId: String?

    // MARK: - PiP secondary slot tracking — mirrors the four primary fields just above, but for
    // whatever is playing in VLCBridge's secondary slot (the muted corner thumbnail). Lives inside
    // the same window as the primary — there is no second NSWindow for PiP.
    private(set) var secondaryDeviceID: String?
    private(set) var secondaryChannelNumber: String?
    private(set) var secondaryFeedRemoteURL: String?
    private(set) var secondaryFeedSessionId: String?
    // The window's own `.title` is the primary's title (set at open()/swap time) — there's no
    // separate `currentTitle` var to mirror, so this is the one extra field the secondary needs
    // that the primary doesn't.
    private(set) var secondaryTitle: String?

    private weak var appState: AppState?
    // Local NSEvent monitor for arrow-key seek + Esc-to-exit-fullscreen — installed once per real
    // window (created in `open()`'s new-window branch), torn down in `playerWindowDidClose()`.
    private var keyMonitor: Any?
    // Accumulates arrow-key presses between keyDown and keyUp — see installKeyMonitor's doc
    // comment for why this can't just commit a reconnect on every keyDown.
    private var pendingSeekDelta: Double = 0

    private init() {}

    /// Records which FEED session/remote URL is now backing the player, right before
    /// AppState.startFeedLocalRelay hands VLCBridge the local relay URL — see currentFeedRemoteURL's
    /// own doc comment. Cleared in playerWindowDidClose.
    func setFeedRelayTracking(remoteURL: String, sessionId: String) {
        currentFeedRemoteURL = remoteURL
        currentFeedSessionId = sessionId
    }

    /// Secondary-slot counterpart to setFeedRelayTracking above — same purpose, for a PiP corner
    /// FEED relay instead of the primary stream. Cleared in closeSecondary()/playerWindowDidClose().
    func setSecondaryFeedRelayTracking(remoteURL: String, sessionId: String) {
        secondaryFeedRemoteURL = remoteURL
        secondaryFeedSessionId = sessionId
    }

    /// The primary stream's display title — the window's own `.title`, which `open()`/
    /// `swapTrackingFieldsForPiPSwap()` always keep pointed at whatever is currently primary.
    /// Exposed for callers (MenuContent's "Watching" menu entry) that need a plain display name
    /// without re-deriving one from currentDeviceID/currentFeedRemoteURL — that lineup-based
    /// lookup can't resolve a Watch Now (own in-progress recording) session, since its
    /// /api/watch-recording relay URL never matches a real lineup channel.
    var currentTitle: String? { window?.title }

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
        let matchesPrimaryURL   = !url.isEmpty && VLCBridge.shared.currentURL?.urlBase == url
        let matchesPrimaryRelay = !showId.isEmpty && VLCBridge.shared.recordingShowId == showId
        if matchesPrimaryURL || matchesPrimaryRelay {
            window?.close()   // triggers windowWillClose → playerWindowDidClose
            return
        }
        // The show could instead be playing only in the PiP secondary slot (watchAsSecondary/
        // watchRecordingInAppAsSecondary/watchRemoteRelayAsSecondary) — recordingShowId is
        // strictly primary-only (VLCBridge.play(url:slot:)'s own doc comment), so match by URL
        // shape directly, the same way AppState.secondaryVlcOccupiesTuner already does. Tears down
        // only the secondary, not the whole window — the primary (if any) is unrelated and should
        // keep playing.
        let matchesSecondaryURL   = !url.isEmpty && VLCBridge.shared.secondaryURL?.urlBase == url
        let matchesSecondaryRelay = !showId.isEmpty && (VLCBridge.shared.secondaryURL?.contains("show=\(showId)") ?? false)
        if matchesSecondaryURL || matchesSecondaryRelay {
            closeSecondary()
        }
    }

    /// Open (or bring forward) the player window and start playing url on device.
    /// If the window is already showing, the stream is switched immediately.
    func open(url: String, title: String, device: HDHRDevice, appState: AppState, channelNumber: String? = nil) {
        self.appState = appState
        // Captured before currentDeviceID is overwritten below — this is the one signal that
        // distinguishes "same device, just switching channels/streams" (the common case; the
        // existing view's own onChange(of: state.vlcCurrentURL) already re-syncs the picker for
        // that) from "reusing the window across devices" (ISSUES.md: previously left the hosted
        // view's device/lineup/recording-relay rows silently pointing at the old tuner).
        let deviceChanged = currentDeviceID != device.DeviceID
        currentDeviceID = device.DeviceID
        currentChannelNumber = channelNumber
        VLCBridge.shared.liveMinRate = Float(appState.config.Player_buffer_min_rate) / 100.0
        VLCBridge.shared.setVolume(0)   // mute before buffering starts; Start click unmutes
        VLCBridge.shared.ensurePlayer() // create fresh player if previous session released it
        VLCBridge.shared.play(url: url)

        if let win = window {
            glog("[VLC] WindowManager.open — reusing existing window, title=\(title)")
            win.title = title
            if deviceChanged {
                // The hosted NSHostingView is reused across opens (see "Singleton NSWindow" below)
                // rather than recreated, so VLCPlayerView's own `let device`/`initialURL` would
                // otherwise stay frozen at whatever device first opened this window. Swapping
                // rootView to a freshly-constructed VLCPlayerView fixes that; .id(device.DeviceID)
                // forces SwiftUI to treat it as a genuinely new view identity (not an in-place
                // property update) so @State resets and .onAppear actually re-fires for the new
                // device — re-syncing audio devices, media-key targets, and the channel picker,
                // the same setup a truly fresh window's first appearance already does.
                glog("[VLC] WindowManager.open — device changed on reuse, swapping hosted view to device=\(device.DeviceID)")
                hostingView?.rootView = AnyView(
                    VLCPlayerView(device: device, initialURL: url)
                        .environmentObject(appState)
                        .id(device.DeviceID)
                )
            }
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        glog("[VLC] WindowManager.open — creating new window, device=\(device.DeviceID) url=\(url)")

        let playerView = AnyView(
            VLCPlayerView(device: device, initialURL: url)
                .environmentObject(appState)
                .id(device.DeviceID)
        )

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = title
        let hosting = NSHostingView(rootView: playerView)
        win.contentView = hosting
        self.hostingView = hosting
        win.isReleasedWhenClosed = false   // retain for reuse on next open()
        // Opts into the native macOS fullscreen: hovering the green traffic-light button shows the
        // expand-arrows icon, and both it and Cmd+Ctrl+F now enter true fullscreen (a separate
        // Space, not just a maximized window) — standard AppKit behavior, no other code needed to
        // enter. Exiting via Esc, though, AppKit does NOT bind that itself; installKeyMonitor below
        // adds it explicitly.
        win.collectionBehavior.insert(.fullScreenPrimary)
        let observer = WindowCloseObserver(manager: self)
        closeObserver = observer
        win.delegate = observer
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
        installKeyMonitor(for: win)
    }

    /// Brings up the singleton player window with primary left idle (no URL handed to VLCBridge,
    /// currentDeviceID/currentChannelNumber left nil) so AppState.watchAsSecondary can populate the
    /// PIP corner thumbnail even when nothing was already playing. No-ops if a window already
    /// exists — covers both "primary already playing" and "an idle placeholder window is already
    /// up from a previous standalone-PIP call," never double-creating. Deliberately duplicates
    /// open()'s new-window construction rather than calling through it, since open() unconditionally
    /// calls VLCBridge.shared.play(url:) and sets currentDeviceID — both must NOT happen here, or a
    /// later real open() call would see deviceChanged == false and skip re-syncing the hosted view.
    func ensureWindowForStandalonePiP(placeholderDevice: HDHRDevice, appState: AppState) {
        guard window == nil else { return }
        self.appState = appState
        glog("[VLC] WindowManager.ensureWindowForStandalonePiP — creating idle primary window, placeholder device=\(placeholderDevice.DeviceID)")

        let playerView = AnyView(
            VLCPlayerView(device: placeholderDevice, initialURL: "")
                .environmentObject(appState)
                .id(placeholderDevice.DeviceID)
        )

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "hdhrVCRplus"
        let hosting = NSHostingView(rootView: playerView)
        win.contentView = hosting
        self.hostingView = hosting
        win.isReleasedWhenClosed = false   // retain for reuse on next open()
        win.collectionBehavior.insert(.fullScreenPrimary)
        let observer = WindowCloseObserver(manager: self)
        closeObserver = observer
        win.delegate = observer
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
        installKeyMonitor(for: win)
    }

    /// Start `url` playing as the PiP secondary (muted corner thumbnail) alongside whatever's
    /// already primary. Unlike open(), never creates/reuses an NSWindow — the thumbnail lives
    /// inside the existing primary window's VLCPlayerView (see the ZStack's pipOverlay). Callers
    /// (AppState.watchAsSecondary) are responsible for confirming a primary session is already open
    /// — this is a defensive backstop, not the real gate.
    func openSecondary(url: String, title: String, device: HDHRDevice, channelNumber: String? = nil) {
        guard window != nil else {
            glog("[VLC] WindowManager.openSecondary — no primary window open, ignoring", level: .warning)
            return
        }
        secondaryDeviceID      = device.DeviceID
        secondaryChannelNumber = channelNumber
        secondaryTitle         = title
        glog("[VLC] WindowManager.openSecondary — device=\(device.DeviceID) url=\(url)")
        // ensurePlayer BEFORE setVolume, not after — setVolume(_:slot:) is a no-op when that
        // slot's mediaPlayer is still nil (its own guard), and unlike the primary (already created
        // by VLCBridge's own init() at app launch, well before any open() call), the secondary
        // player only ever comes into existence right here. Muting before the player exists
        // silently did nothing, then ensurePlayer created a fresh player at libvlc's own default
        // (audible) volume and nothing ever muted it afterward — found live 2026-09-19 (PiP audio
        // was audibly coming from the corner thumbnail instead of the primary).
        VLCBridge.shared.ensurePlayer(slot: .secondary)
        VLCBridge.shared.setVolume(0, slot: .secondary)
        VLCBridge.shared.play(url: url, slot: .secondary)
    }

    /// In-place channel switch for an already-open secondary (PiP thumbnail's right-click "Channel"
    /// submenu) — the caller has already reconnected the player itself via
    /// VLCBridge.play(url:slot:.secondary); this just keeps secondaryChannelNumber/secondaryTitle in
    /// sync so a later swap-to-primary, and the thumbnail's own bookkeeping, reflect the channel
    /// actually playing now rather than whichever one the PiP was originally opened with.
    func retuneSecondary(channelNumber: String, title: String) {
        secondaryChannelNumber = channelNumber
        secondaryTitle         = title
    }

    /// Stop and tear down just the secondary slot — the user-facing "close PiP without swapping
    /// first" affordance (the corner thumbnail's own × button). Leaves the primary untouched.
    func closeSecondary() {
        glog("[VLC] WindowManager.closeSecondary")
        VLCBridge.shared.releasePlayer(slot: .secondary)
        if let sessionId = secondaryFeedSessionId {
            appState?.webServer.unregisterFeedRelaySession(id: sessionId)
        }
        secondaryDeviceID      = nil
        secondaryChannelNumber = nil
        secondaryFeedRemoteURL = nil
        secondaryFeedSessionId = nil
        secondaryTitle         = nil
        appState?.refreshTunerOccupancy()
    }

    /// Atomically swaps every primary/secondary tracking field — called by VLCPlayerView's
    /// swapPrimaryAndSecondary() right after it has already reconnected each slot's libvlc player
    /// to the other's URL. Atomic (one method, not eight individual setters) so no half-swapped
    /// state is ever visible to a reader in between — matters for AppState's tuner-occupancy checks
    /// (vlcOccupiesTuner/secondaryVlcOccupiesTuner), which key off these exact fields. Also updates
    /// the window's own `.title` to the newly-primary stream's title (found live 2026-09-19: the
    /// title previously stayed whatever the window opened with, regardless of any later swap).
    func swapTrackingFieldsForPiPSwap() {
        (currentDeviceID, secondaryDeviceID)           = (secondaryDeviceID, currentDeviceID)
        (currentChannelNumber, secondaryChannelNumber) = (secondaryChannelNumber, currentChannelNumber)
        (currentFeedRemoteURL, secondaryFeedRemoteURL) = (secondaryFeedRemoteURL, currentFeedRemoteURL)
        (currentFeedSessionId, secondaryFeedSessionId) = (secondaryFeedSessionId, currentFeedSessionId)
        if let newPrimaryTitle = secondaryTitle {
            secondaryTitle = window?.title
            window?.title = newPrimaryTitle
        }
    }

    // Arrow-key seek (recording playback only) + Esc to exit fullscreen + "i" for the info banner.
    // A local monitor rather than a SwiftUI .onKeyPress/.keyboardShortcut so none of these are at
    // the mercy of which toolbar control currently has focus, and scoped to this exact window
    // (`event.window === win`) so it can never fire for a keystroke intended for some other window
    // (e.g. Settings) that happens to be key at the time.
    //
    // "i" moved here 2026-09-26, live report: the toolbar Info button's own
    // `.keyboardShortcut("i", modifiers: [])` sometimes didn't fire at all. A bare, unmodified
    // letter key equivalent like that only reaches SwiftUI's shortcut system if nothing else in the
    // responder chain claims it first — the toolbar's own channel-picker `Picker` (an NSPopUpButton
    // under the hood) intercepts a plain letter keystroke for its own type-ahead "jump to item
    // starting with this letter" behavior whenever it (or another focusable control) currently held
    // first-responder status, silently consuming the "i" before it ever reached the button's
    // shortcut. A local monitor runs *before* responder-chain dispatch, so it can't lose that race —
    // exactly the same reasoning arrow-key seek below already relied on for this same class of bug.
    // Posts `.vlcToggleInfoOverlay` (matched in `body`'s `.onReceive`) rather than mutating
    // `infoOverlayVisible` directly — that's `@State` on the View struct, this method lives on
    // VLCPlayerWindowManager (a persistent class singleton with no reference to whichever View
    // struct instance SwiftUI currently has live), the same reason `vlcChannelNext`/`vlcChannelPrev`
    // already bridge this class's remote-command handlers into View-struct state via notification
    // rather than a direct call.
    //
    // Arrow keys accumulate into `pendingSeekDelta` on keyDown and only actually commit (one
    // relay reconnect, via seekRecordingRelative) on keyUp — matching the scrub-bar slider's own
    // release-based commit (`onEditingChanged`, VLCPlayerView.swift). Without this, macOS's normal
    // key-repeat fires a keyDown roughly every 100-300ms while a key is held, and committing on
    // every one of those meant holding the key hammered the relay with a full reconnect-and-
    // rebuffer that many times a second — felt like repeated playback drops rather than a smooth
    // rewind/skip. Found live 2026-08-22: a burst of 6 reconnects in ~2 seconds, each landing
    // ~15s earlier than the last (exactly this feature's left-arrow step), while testing it.
    private func installKeyMonitor(for win: NSWindow) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self, weak win] event in
            guard let self, let win, event.window === win else { return event }
            // Bare "i" only — charactersIgnoringModifiers (not keyCode) so this matches by the same
            // layout-independent character SwiftUI's KeyEquivalent("i") itself would have used, and
            // the modifier check keeps Cmd/Option/Control/Shift-I from also triggering this (Shift
            // would type "I", a different KeyEquivalent than the bare "i" the toolbar button asked
            // for — .keyboardShortcut("i", modifiers: []) never matched that either).
            if event.type == .keyDown, event.charactersIgnoringModifiers?.lowercased() == "i",
               event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                NotificationCenter.default.post(name: .vlcToggleInfoOverlay, object: nil)
                return nil
            }
            switch (event.type, event.keyCode) {
            case (.keyDown, 123), (.keyDown, 124):
                // Only meaningful for an on-disk recording — a live broadcast has nothing to seek
                // into, so this no-ops there (and leaves pendingSeekDelta untouched at 0, so a
                // stray keyUp right after switching to a live channel mid-hold has nothing to
                // commit either).
                guard VLCBridge.shared.recordingShowId != nil else { return event }
                self.pendingSeekDelta += event.keyCode == 123 ? -15 : 30
                return nil
            case (.keyUp, 123), (.keyUp, 124):
                guard self.pendingSeekDelta != 0 else { return event }
                self.seekRecordingRelative(self.pendingSeekDelta)
                self.pendingSeekDelta = 0
                return nil
            case (.keyDown, 53):   // escape — only consumed while actually in fullscreen, so a
                                    // plain Esc elsewhere (e.g. dismissing a popover) still works.
                guard win.styleMask.contains(.fullScreen) else { return event }
                win.toggleFullScreen(nil)
                return nil
            default:
                return event
            }
        }
    }

    // Skips the currently-playing recording by `delta` seconds (right arrow: +30, left: -15 per
    // keypress — a bigger forward skip than back, since catching up past a distraction is more
    // common than needing a deep rewind; a held key accumulates multiple steps into one `delta`
    // via pendingSeekDelta above before this ever runs). Reuses the exact same commit path the
    // scrub-bar drag already uses (AppState.seekRecording), just computing the target from a
    // relative delta instead of an absolute slider position.
    private func seekRecordingRelative(_ delta: Double) {
        guard let showId = VLCBridge.shared.recordingShowId,
              let startDate = VLCBridge.shared.recordingStartDate,
              let appState else { return }
        let elapsed = max(1, Date().timeIntervalSince(startDate))
        let current = min(VLCBridge.shared.recordingPlaybackSeconds, elapsed)
        let target  = max(0, min(current + delta, elapsed))
        appState.seekRecording(showId: showId, toSeconds: target)
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
        // Cancel any in-flight "yield tuner to record" wait before it can reopen a window the user
        // just closed — see AppState.cancelYieldRecordingIfInProgress's own doc comment.
        appState?.cancelYieldRecordingIfInProgress()
        // Stop audio listener before releasing the player — windowWillClose fires before onDisappear,
        // so without this the CoreAudio callback fires into a partially torn-down view.
        VLCBridge.shared.stopDeviceChangeMonitoring()
        VLCBridge.shared.stopCastDiscovery()
        VLCBridge.shared.releasePlayer() // full teardown — releases mediaPlayer and nils currentURL; Combine auto-clears vlcCurrentURL
        VLCBridge.shared.releasePlayer(slot: .secondary) // PiP secondary shares this one window — tear it down too
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        pendingSeekDelta = 0   // in case the window closed mid-hold, before a matching keyUp arrived
        // FEED client-side local relay teardown — guarded so a normal live-tuner/Watch-Now close
        // pays no new cost. Unregistering the session is enough: FeedRelayProxyDelegate's own
        // cleanup (invalidating its URLSession) fires from conn.cancel() below closing the
        // NWConnection it's forwarding into — there's no separate process or temp file to tear down
        // now that this relay is in-memory (see issues_resolved.md's "VLC-side FEED playback
        // stalls" entry for the 2026-09-12 simplification).
        if let sessionId = currentFeedSessionId {
            appState?.webServer.unregisterFeedRelaySession(id: sessionId)
        }
        if let sessionId = secondaryFeedSessionId {
            appState?.webServer.unregisterFeedRelaySession(id: sessionId)
        }
        currentFeedRemoteURL = nil
        currentFeedSessionId = nil
        currentDeviceID = nil
        currentChannelNumber = nil
        secondaryFeedRemoteURL = nil
        secondaryFeedSessionId = nil
        secondaryDeviceID = nil
        secondaryChannelNumber = nil
        secondaryTitle = nil
        window = nil
        hostingView = nil
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
    // Lets VLCPlayerView hide its own toolbar by default in true fullscreen (see body's ZStack) —
    // without this, our toolbar and macOS's own top-of-screen hover-reveal menu bar compete for
    // the same real estate, since both sit at the top edge of a fullscreen window/space.
    func windowDidEnterFullScreen(_ notification: Notification) {
        NotificationCenter.default.post(name: .vlcFullScreenChanged, object: nil, userInfo: ["isFullScreen": true])
    }
    func windowDidExitFullScreen(_ notification: Notification) {
        NotificationCenter.default.post(name: .vlcFullScreenChanged, object: nil, userInfo: ["isFullScreen": false])
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
