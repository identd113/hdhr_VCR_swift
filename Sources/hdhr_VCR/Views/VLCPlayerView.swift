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
    // Posted by installKeyMonitor on a bare Tab keydown, but only while a PiP secondary is open —
    // same reasoning as vlcToggleInfoOverlay: the swap lives on VLCPlayerView (needs `state`/
    // `bridge`/toolbar @State), not on VLCPlayerWindowManager where the key monitor itself lives.
    static let vlcSwapPiP = Notification.Name("vlcSwapPiP")
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
// own right-click context menu (VLCPlayerView.makePipNSMenu), persisted across sessions the same
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

/// Three short parallel diagonal lines — the standard window-resize grip — hugging one corner of
/// its rect. `atTop`/`atLeading` say which corner of the *thumbnail* it sits in (the lines always run
/// perpendicular to the corner's diagonal, pointing at it).
struct PipResizeGrip: Shape {
    var atTop: Bool
    var atLeading: Bool

    func path(in rect: CGRect) -> Path {
        var p = Path()
        // Drawn for the bottom-trailing corner, then mirrored via x/y flips for the others.
        func x(_ v: CGFloat) -> CGFloat { atLeading ? rect.minX + (rect.maxX - v) : v }
        func y(_ v: CGFloat) -> CGFloat { atTop ? rect.minY + (rect.maxY - v) : v }
        let w = rect.width, h = rect.height
        for i in 0..<3 {
            let o = CGFloat(i) * (min(w, h) / 3.2)      // offset of each line from the corner
            p.move(to: CGPoint(x: x(rect.maxX), y: y(rect.minY + o)))
            p.addLine(to: CGPoint(x: x(rect.minX + o), y: y(rect.maxY)))
        }
        return p
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
    // Identifies this hosted instance to VLCPlayerWindowManager (hostedViewToken). open() swaps
    // rootView to a fresh VLCPlayerView on a device change *after* already calling play(url:), and
    // the superseded view's onDisappear lands after that — without this check its releasePlayer()
    // tore down the stream that had just been started (and could also unhook the new view's
    // device-change monitor / media-key targets if its onAppear ran first). nil (tests/previews)
    // means "always the current view".
    var hostToken: UUID? = nil

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
    // PiP thumbnail's pinned corner — set via its own right-click menu (makePipNSMenu).
    @AppStorage("vlcPipCorner") private var pipCorner: PipCorner = .bottomTrailing
    // Bumped per live channel pick so a switch still waiting on a tuner can tell a newer pick replaced it.
    @State private var switchGeneration = 0
    // The in-flight tuner-wait switch (cancelled on a newer pick / window close), and whether it has
    // stopped our own stream — while it has, a second pick still counts as "reusing our tuner"
    // (currentURL is nil then, so reusesExistingTuner alone would send it down the pre-flight branch,
    // where AppState.vlcOccupiesTuner still counts the stopped stream → a false "All Tuners Busy").
    @State private var switchTask: Task<Void, Never>?
    @State private var ownStreamStoppedForSwitch = false
    // User-chosen PiP size as a fraction of the video pane's width (0 = automatic sizing), set by
    // dragging the thumbnail's inner-corner handle. A fraction (not points) so it keeps scaling with
    // the window like the automatic size does. Aspect ratio is always the stream's native one.
    // Local @State while dragging; committed to AppConfig.PiP_width_fraction (the config file, so it
    // survives quits AND reinstalls, unlike an @AppStorage default) only when the drag ends — writing
    // the @Published config on every drag tick would churn the menu/save on each frame.
    @State private var pipWidthFraction: Double = 0
    @State private var pipResizeStartWidth: CGFloat?
    // True only while the pointer is near the resize handle's corner (its own hover zone, not the whole thumbnail).
    @State private var pipHandleHovered = false
    @State private var systemDevices: [(id: String, name: String, isAirPlay: Bool)] = []
    @State private var selectedDevice: String = ""
    @State private var audioFollowsDefault = true      // mirrors VLCBridge.audioFollowsSystemDefault for the menu checkmark
    @State private var availableScreens: [NSScreen] = []
    @State private var posterHidden: Bool = false
    @State private var posterNSImage: NSImage? = nil
    @ObservedObject private var bridge = VLCBridge.shared
    // Optional status bar under the video (docs/VLCPlayerView.md, "Status bar"); remembered across windows and launches.
    @AppStorage("playerStatusBarVisible") private var statusBarEnabled = false   // the user's choice only; a brief peek never writes it
    @State private var barRowOpen = false          // the bar's row exists in the window (the choice, or a peek in progress)
    // A stream that opens with the bar switched off still shows it briefly: it slides up over the bottom of the picture
    // for tempBarSeconds, then slides away and the ⓘ icon pulses as a hint to press it. See `revealStatusBarBriefly`.
    @State private var liveJumpTextShown = false   // the words follow the chevron by a beat
    @State private var liveJumpText: String?       // "5 seconds to live" flash on the picture after Live Edge is clicked
    @State private var handledPeekToken = 0        // last peek token acted on (see the .task on the toolbar)
    @State private var handledFlashCount = 0
    @State private var barIsPeek = false           // the bar is open only briefly (a stream just opened); a click keeps it
    @State private var barSlidIn = false           // the persistent bar is wanted (true from the moment it starts opening)
    @State private var barContentOffset: CGFloat = 0   // the bar's own bounce inside its growing row
    @State private var barShimmerToken = 0             // bumped when the bar opens; PlayerStatusBar runs its shimmer wave
    @State private var barRowHeight: CGFloat = 0   // animated 0...52 in step with the window's own resize
    @State private var barCloseTask: Task<Void, Never>?
    @State private var tempBarToken = 0
    @State private var feedMatchSnapshot: GuideStore.SeriesMatch?   // a FEED show's airing found in the guide, once per show
    @State private var upcomingSnapshot: [GuideEntry] = []   // next-show strip, rebuilt only when the current show changes
    @State private var infoFlashCount = 0     // bumped to pulse the ⓘ icon
    @State private var infoGlow = false
    private static let tempBarSeconds: Double = 5.5   // plus the 0.45 s slide-in: back up about 6 s after the video starts
    /// One quick motion for every appearance of the status bar: about half a second, the window and the bar's row on
    /// the same curve, with a bounce and a highlight sweep as it opens and a small wind-up as it closes.
    private static let barSlideSeconds: Double = 0.45
    @State private var streamInfoHovered   = false
    @State private var popoverAnchorHovered = false   // pointer on ⓘ
    @State private var popoverBodyHovered = false     // pointer inside the popover itself
    @State private var linkInfo: NetworkLinkInfo?   // measured when the Stream popover opens (see connectionSection)
    // The recording's file size, read once when the Stream popover opens (ⓘ onHover). Reading it inside the popover body
    // would repeat the blocking disk stat on every stats tick while the popover is open.
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
    @State private var toolbarWidth: CGFloat = 0   // measured width of the toolbar row (0 until first measured) — drives the overflow plan
    @State private var toolbarPlanMemo: ToolbarOverflowPlanner.Plan?   // the plan in force, for the planner's hysteresis
    @State private var toolbarHovered = false     // reveals the toolbar overlay while isFullScreen (see body)
    @State private var pipHovered = false         // reveals the PiP thumbnail's close button on hover (see pipOverlay)
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
        // The channel/recording selectedChannel resolves to isn't necessarily on THIS view's own
        // bound `device` anymore — a cross-device PiP swap (syncChannel's own cross-device branches)
        // can leave it pointing at a different device's channel or recording entirely. Query THAT
        // device's guide data, not device.DeviceID unconditionally, or this returns nil for a
        // perfectly resolvable channel just because the wrong device's guide was checked. Found live
        // 2026-09-26, right after the cross-device syncChannel fix shipped: selectedChannel now
        // resolved correctly, but the info banner still showed no show title/episode at all (having
        // silently swapped one symptom, "Unknown", for another, blank) because this line still
        // queried device.DeviceID — for a FEED window with a real channel swapped into primary,
        // that's the virtual relay, which never has real guide data at all. A same-device selection
        // (the common case, and same-device PiP swaps) is unaffected: currentDeviceID already equals
        // device.DeviceID then.
        let guideDeviceId = recordingShow?.hdhr_record ?? VLCPlayerWindowManager.shared.currentDeviceID ?? device.DeviceID
        // `after: anchorTime`, not the default (now): during Bonus Time the recording's own slot has already ended, and
        // a "still airing" filter would drop it, leaving the bar and banner generic (seen live 2026-10-18, 10:34 PM).
        return state.guideStore.entries(deviceId: guideDeviceId, channelNum: channelNum, after: anchorTime)
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
    // The real tuner whose channels the picker lists — this window's own device, or for a window
    // bound to a FEED (virtual relay, no channels of its own) the first real tuner, so the picker
    // always offers the full Recording → FEED → Favorites → rest stack (2026-10-02, explicit
    // request). With several real tuners only the first is listed here.
    private var channelSourceDevice: HDHRDevice? {
        device.isVirtualRelay ? state.recordableDevices.first : device
    }
    private var channelLineup: [LineupEntry] {
        guard let src = channelSourceDevice else { return [] }
        return Self.sortedChannels(state.lineups[src.DeviceID] ?? [])
    }

    /// Plain ascending channel-number order ("5.1" < "5.2" < "5.10" — numeric, not lexical), the
    /// order every channel list in the player uses. Pure, for unit testing.
    nonisolated static func sortedChannels(_ lineup: [LineupEntry]) -> [LineupEntry] {
        lineup.sorted { $0.GuideNumber.localizedStandardCompare($1.GuideNumber) == .orderedAscending }
    }

    /// Media-key next/prev order: recording rows, then FEED rows, then the real channels in plain
    /// ascending order — minus any plain row whose channel is recording (its "Live …" row covers
    /// it, and stepping onto the plain row redirects back to that row, so up/down could never get
    /// past it). Pure, for unit testing.
    nonisolated static func channelCycleOrder(recording: [LineupEntry], feeds: [LineupEntry],
                                               channels: [LineupEntry], recordingChannels: Set<String>) -> [LineupEntry] {
        recording + feeds + channels.filter { !recordingChannels.contains($0.GuideNumber) }
    }
    private var favoriteLineup: [LineupEntry] { channelLineup.filter(\.isFavorite) }
    private var otherLineup: [LineupEntry] { channelLineup.filter { !$0.isFavorite } }

    // Rough estimate of the native fullscreen title-bar reveal strip's height (traffic lights +
    // title, drawn by AppKit above app content when the cursor nears the top of a true-fullscreen
    // window) — see body's isFullScreen toolbar overlay for why this exists. Not an exact value;
    // macOS doesn't expose the real strip height, so this may need tuning after an actual look.
    private static let fullScreenTopInset: CGFloat = 32

    // Auto-start (2026-10-03): every stream — live TV, FEED, Watch Now — reveals and unmutes on
    // its own as soon as VLC has decoded the first video frame (bridge.hasVideoFrame), replacing
    // the live-TV Start button and FEED's fixed 8s wait (which only existed to cover the old
    // 0.93× fill ramp, removed the same day; see VLCBridge.minRate). The start buffer itself is
    // VLC's network-caching (≤3s, set per source in VLCBridge.play). Gating on the first frame,
    // not just isPlaying, keeps audio from starting over a blank screen while the video decoder
    // waits for a keyframe.

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


    // Every discovered FEED (another Mac's in-progress recording) as a synthetic "live-feed:" row —
    // the picker's FEED section, in every window (2026-10-02: the picker always offers the full
    // stack; it briefly showed *only* FEEDs in a FEED view, 2026-10-01).
    private var allFeedEntries: [LineupEntry] {
        let relays = state.remoteRelayEntries
        return relays.compactMap { pair in
            pair.entry.URL.flatMap { Self.feedChannelEntry(deviceIsVirtualRelay: false, remoteURL: $0, remoteRelayEntries: relays) }
        }
    }

    // The FEED row for whatever FEED is primary right now, if any — what syncChannel selects.
    private var currentFeedRow: LineupEntry? {
        Self.feedChannelEntry(deviceIsVirtualRelay: false,
                               remoteURL: VLCPlayerWindowManager.shared.currentFeedRemoteURL,
                               remoteRelayEntries: state.remoteRelayEntries)
    }

    private func remoteURL(fromLiveFeedGuideNumber guideNumber: String) -> String? {
        guard guideNumber.hasPrefix(Self.liveFeedGuideNumberPrefix) else { return nil }
        return String(guideNumber.dropFirst(Self.liveFeedGuideNumberPrefix.count))
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
    // Same order as the picker: Recording, FEED, then the channels (plain ascending, not
    // favorites-first — see above). Plain rows for a channel recording on this device are left
    // out — their "Live …" row covers them, and stepping onto the plain row redirected to that
    // "Live" row, so up/down could never get past it (2026-10-01 review #13).
    private var channelCycleOrder: [LineupEntry] {
        let recordingChannels = Set(state.recordingShows.filter { $0.hdhr_record == device.DeviceID }.map(\.show_channel))
        return Self.channelCycleOrder(recording: recordingChannelEntries, feeds: allFeedEntries,
                                       channels: channelLineup, recordingChannels: recordingChannels)
    }

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

    // A plain stat of the recording file's size; read only on the ⓘ onHover (into recordingSizeSnapshot), never from the popover body.
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
    // through state.startFeedCacheSession (same as watchRemoteRelay's initial open) rather than
    // calling bridge.play(url:) directly against the raw remote URL: doing that would reconnect
    // libvlc straight to the remote Mac and reintroduce the exact cross-machine stall bug the FEED
    // local disk cache exists to avoid, just for this one interaction. Necessarily starts a fresh
    // cache file at byte 0 (the old one is deleted) — no scrub-position continuity across the
    // raw↔H.264 switch, matching this toggle's existing reconnect-on-switch behavior.
    /// Pure decision, extracted for unit testing: true when a FEED session that just finished starting
    /// has no live window to belong to (closed, or this view was superseded by a rebind).
    nonisolated static func feedToggleOutlivedWindow(windowOpen: Bool, myToken: UUID?, hostedToken: UUID) -> Bool {
        !windowOpen || (myToken != nil && myToken != hostedToken)
    }

    private func toggleFeedTranscode(to wantsTranscode: Bool) {
        guard wantsTranscode != feedIsTranscoding, let rawURL = currentFeedEntry?.URL else { return }
        let newRemoteURL = wantsTranscode ? rawURL + "&transcode=auto" : rawURL
        glog("[VLC] FEED transcode toggle → \(wantsTranscode ? "H.264" : "raw"): \(newRemoteURL)")
        let token = hostToken
        Task {
            guard let session = await state.startFeedCacheSession(
                remoteURL: newRemoteURL, device: device,
                title: VLCPlayerWindowManager.shared.currentTitle ?? device.FriendlyName ?? "FEED") else { return }
            // The startup wait is 2–5 s; if the window closed (or was rebound to another device's view)
            // meanwhile, playerWindowDidClose already ran and won't see this session — it would sit
            // tracked on a dead window (puller + cache file alive until quit) and bridge.play would
            // re-create a released player. Not cancelled via Task.cancel: the startup poll's
            // `try? Task.sleep` returns instantly when cancelled and would spin into a bogus failure alert.
            let mgr = VLCPlayerWindowManager.shared
            if Self.feedToggleOutlivedWindow(windowOpen: mgr.currentTitle != nil, myToken: token, hostedToken: mgr.hostedViewToken) {
                glog("[VLC] FEED transcode toggle: window closed during startup — releasing session \(session.sessionId)")
                mgr.clearFeedRelayTracking(ifSessionId: session.sessionId)
                state.stopFeedCacheSession(sessionId: session.sessionId)
                state.webServer.unregisterFeedRelaySession(id: session.sessionId)
                return
            }
            bridge.play(url: session.url)
            DispatchQueue.main.async {
                VLCBridge.shared.beginRecordingSeek(showId: session.sessionId, recordingStart: session.startedAt, seekBaseSeconds: 0)
            }
        }
    }

    // MARK: - Picture-in-picture tap-to-swap
    //
    // Tap the corner thumbnail to make it the front (full controls + audio) stream, and demote
    // whatever was previously front to the muted corner — a genuine reconnect, the same
    // reconnect-by-URL shape as toggleFeedTranscode/catchUpToLive above: mutate which URL each
    // slot's already-alive player is pointed at, no window/view recreation. A brief rebuffer on
    // swap is expected, not a regression.
    private func swapPrimaryAndSecondary() {
        // A Tab-swap during a tuner-wait switch would demote the stopped primary slot — cancel the
        // pending switch (code review 2026-10-03).
        if ownStreamStoppedForSwitch {
            switchGeneration += 1
            switchTask?.cancel()
            ownStreamStoppedForSwitch = false
        }
        let mgr = VLCPlayerWindowManager.shared
        guard bridge.secondaryURL != nil, mgr.secondaryDeviceID != nil else { return }

        // Re-targets each already-playing player's rendering surface onto the other slot's fixed
        // view — no stop/reconnect, so this is instant, not a rebuffer (see swapSlots' own doc
        // comment for the full reasoning; this replaced an earlier reconnect-by-URL design after
        // live feedback that it caused a visible rebuffer on every swap).
        // Nothing below may run for a swap that didn't happen (review #12) — it would describe the
        // corner stream as primary while libvlc still plays them the other way round.
        guard bridge.swapSlots() else { return }

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
        bridge.logAudioVolumes(after: "PiP swap")

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

    // Source color for the ⓘ icon and the Stream popover: blue = network (live tuner), purple = disk (recording relay).
    // `bridge.recordingShowId` is the same signal `AppState.vlcOccupiesTuner` keys off.
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

    // body is split into staged `let` bindings (core → withDialogs → withTasks → return) rather
    // than one continuous chained expression — as one expression this ~300-line VStack/ZStack +
    // .alert/.confirmationDialog/.onAppear/.task×2/.onChange×6/.onDisappear/.onReceive×4 chain
    // pushed the type-checker past its time budget ("unable to type-check this expression in
    // reasonable time"), failing `swift build` intermittently in CI depending on runner speed.
    var body: some View {
        let core: some View = VStack(spacing: 0) {
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
                // Aspect-fit to the stream's native shape as an ordinary SwiftUI frame — the same way the
                // PiP thumbnail is sized — so resizing the window just rescales this pane. Always
                // applied (16:9 until the first frame reports a size): a conditional wrapper would
                // change the view's identity and rebuild the surface mid-playback.
                VLCVideoSurface()
                    .aspectRatio(bridge.videoPixelSize.flatMap { $0.height > 0 ? $0.width / $0.height : nil } ?? 16.0 / 9.0,
                                 contentMode: .fit)
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
                if let liveJumpText {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.forward.2").font(.title2.weight(.bold))
                            .symbolEffect(.variableColor.iterative, options: .repeating)
                        if liveJumpTextShown {
                            Text(liveJumpText).font(.title3.weight(.semibold)).monospacedDigit()
                                .transition(.move(edge: .leading).combined(with: .opacity))
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(.black.opacity(0.6), in: Capsule())
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    .accessibilityIdentifier("vlc-live-jump")
                }
                if infoOverlayVisible {
                    infoBanner
                        // Slides in from the left edge with its backdrop (2026-10-03).
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                // "?" keyboard-shortcuts card — any key (or a click) closes it; see installKeyMonitor.
                if bridge.keyboardHelpVisible {
                    KeyboardShortcutsOverlay(
                        title: "Keyboard Shortcuts",
                        rows: PlayerShortcuts.rows(canSeek: bridge.recordingShowId != nil,
                                                   canPause: bridge.canPause || bridge.isPaused,
                                                   hasPiP: bridge.secondaryURL != nil,
                                                   isFullScreen: isFullScreen),
                        onDismiss: { bridge.keyboardHelpVisible = false })
                        .transition(.opacity)
                }
                // Space-bar pause (VLCBridge.togglePause, disk-backed streams only) — a centered,
                // non-interactive glyph so a deliberately frozen frame never reads as a stall.
                if bridge.isPaused {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(26)
                        .background(.ultraThinMaterial, in: Circle())
                        .allowsHitTesting(false)
                        .accessibilityLabel("Paused")
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
            // .overlay { NativeContextMenuHost { makePipNSMenu() } } below, which is scoped to the small
            // corner thumbnail Button itself; SwiftUI resolves a right-click to whichever is
            // deepest under the pointer.
            //
            // Only offered while no secondary is open — there's only ever one PiP slot
            // (VLCBridge.PlayerSlot has exactly .primary/.secondary, no third slot to "add" into),
            // so showing "Add Picture-in-Picture…" while one's already active is misleading: picking
            // a new source there doesn't add a second thumbnail, it silently replaces the existing
            // one (AppState.watchAsSecondary just overwrites the single secondary slot). To change or
            // remove the current PiP, close it first via its own "×" button (or the thumbnail's own
            // right-click "Channel" submenu, for a live-channel secondary — see docs/VLCPlayerView.md's
            // "Picture-in-picture" section). Found in code review 2026-09-28.
            .contextMenu {
                if VLCPlayerWindowManager.shared.secondaryDeviceID == nil {
                    Button {
                        // The PiP opens in the quadrant of the pane that was right-clicked
                        // (captured by VLCPlayerWindowManager's rightMouseDown monitor — a SwiftUI
                        // .contextMenu doesn't expose the click point). Persisted via pipCorner like a
                        // manual choice; the thumbnail's own right-click menu can still move it.
                        if let corner = VLCPlayerWindowManager.shared.lastRightClickCorner { pipCorner = corner }
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
            }
            .animation(.easeOut(duration: 0.35), value: posterHidden)
            .animation(.easeOut(duration: 0.35), value: bridge.hasError)
            .animation(.easeOut(duration: 0.35), value: bridge.hasEnded)
            .animation(.easeOut(duration: 0.35), value: infoOverlayVisible)
            .animation(.easeOut(duration: 0.18), value: bridge.keyboardHelpVisible)
            .animation(.easeInOut(duration: 0.2), value: bridge.recordingShowId)
            .onReceive(NotificationCenter.default.publisher(for: .vlcFullScreenChanged)) { note in
                isFullScreen = (note.userInfo?["isFullScreen"] as? Bool) ?? false
                if isFullScreen, barIsPeek { barIsPeek = false; setStatusBar(false, persist: false) }   // its timer ends with the toolbar copy
                // The bar may have been toggled while fullscreen (no resize then); catch the window up on the way out.
                if !isFullScreen { VLCPlayerWindowManager.shared.syncWindowToStatusBar() }
            }
            .task(id: effectivePosterImageURL) {
                guard let url = effectivePosterImageURL else { posterNSImage = nil; return }
                posterNSImage = await ChannelIconCache.shared.image(for: url)
            }
            // Optional status bar: a fixed row under the video, part of the window (never over the picture). Not drawn
            // in fullscreen, where there is no room below the video.
            if barRowOpen && !isFullScreen {
                // The row is reserved at full height (window already resized, no animation) so the picture never
                // moves; only the bar inside it slides.
                // The row grows (and the window grows with it) so the bar pops down from the picture's bottom edge.
                statusBarView()
                    .offset(y: barContentOffset)
                    .frame(height: barRowHeight, alignment: .bottom)
                    .clipped()
            }
        }

        let withDialogs: some View = core
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
            barRowOpen = statusBarEnabled   // a bar left on opens already in place
            barSlidIn = statusBarEnabled
            barRowHeight = statusBarEnabled ? VLCPlayerWindowManager.playerStatusBarHeight : 0
            VLCPlayerWindowManager.shared.setStatusBarVisible(statusBarEnabled)
            if bridge.hasVideoFrame { revealStatusBarBriefly() }
            refreshCachedLocalRelayCodecs(showId: bridge.recordingShowId)
            availableScreens = NSScreen.screens   // NSScreen.screens is main-thread-only; safe here
            VLCBridge.shared.setVolume(0)   // muted until Start is clicked
            refreshAudioDevices()
            VLCBridge.shared.startDeviceChangeMonitoring { refreshAudioDevices() }
            VLCBridge.shared.startCastDiscovery()
            syncChannel(to: initialURL)
            let cc = MPRemoteCommandCenter.shared()
            // Drop any targets a previous hosted view registered (a device-change rootView swap
            // skips the old view's onDisappear teardown — see hostToken) so media keys never fire
            // twice (a doubled next-track would skip two channels).
            cc.stopCommand.removeTarget(nil)
            cc.nextTrackCommand.removeTarget(nil)
            cc.previousTrackCommand.removeTarget(nil)
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

        let withTasks: some View = withDialogs
        .onChange(of: bridge.readyToReveal) { _, ready in
            attemptAutoStart()
            // Self-heal: a stream's first frame always re-asserts the user's volume once the poster
            // gate is open. Some paths mute (setVolume(0)) and then leave posterHidden true, so the
            // gate above never runs startPlayback and the audio stays silent until the slider is
            // touched. Never fires while the poster/Start gate is still showing.
            if ready, posterHidden, !isPrimaryIdle { VLCBridge.shared.setVolume(Int(volume)) }
        }
        // The poster can come back over a stream that's already decoded (a Tab swap or FEED
        // switch resets it) — reveal straight away then, rather than waiting for readyToReveal to
        // change, which it won't (live-found 2026-10-03: a 6s blank after every Tab).
        .onChange(of: posterHidden) { _, hidden in if !hidden { attemptAutoStart() } }
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
        // Keep the window's shape matching the picture when the stream's native size changes (e.g. a
        // 16:9 HD channel → a 4:3 SD one) — see VLCPlayerWindowManager.conformWindowToVideoAspect.
        .onChange(of: bridge.videoPixelSize) { _, new in
            guard new != nil else { return }
            VLCPlayerWindowManager.shared.conformWindowToVideoAspect()
        }
        .onChange(of: bridge.recordingShowId) { _, showId in
            // AppState.watchRecordingInApp defers setting this to the next run-loop turn, so the
            // very first syncChannel(to:) call (from .onAppear, in the same synchronous window-
            // open transaction) can run before it lands — re-sync once it does.
            refreshCachedLocalRelayCodecs(showId: showId)
            guard showId != nil, let url = bridge.currentURL else { return }
            syncChannel(to: url)
        }

        return withTasks
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
            // A pending tuner-wait switch must not outlive its window: it would otherwise call
            // startPlayChannel on a closed window (phantom currentDeviceID, queued pendingURL).
            switchTask?.cancel()
            ownStreamStoppedForSwitch = false
            // Safety-net for window close — releasePlayer() is idempotent so calling it here
            // after playerWindowDidClose() already ran is fine. Catches any path where the
            // window delegate didn't fire (e.g. window deallocated without close()).
            // A view superseded by open()'s device-change rootView swap must not tear anything
            // down — see hostToken.
            if let hostToken, VLCPlayerWindowManager.shared.hostedViewToken != hostToken {
                glog("[VLC] VLCPlayerView.onDisappear — superseded by a newer hosted view, skipping teardown")
                return
            }
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
            // "i": the status bar when it can show; in full screen (no bar) the brief info banner instead.
            if isFullScreen { infoOverlayVisible.toggle() } else { userToggleStatusBar() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .vlcSwapPiP)) { _ in
            swapPrimaryAndSecondary()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            availableScreens = NSScreen.screens
        }
    }

    // Unhides the poster and restores the saved volume — the one place a stream becomes visible
    // and audible (auto-start, see attemptAutoStart).
    private func startPlayback(reason: String) {
        glog("[VLC] auto-start — \(reason)")
        // Instant, not the poster overlay's usual 0.35s crossfade (.animation(value: posterHidden)
        // in body) — the video has already been decoding/rendering underneath the poster (mute only
        // silences audio), so an instant reveal exactly matches setVolume's own instant, un-ramped
        // unmute just below. Without this, the poster's fade left the picture visibly appearing
        // ~350ms after audio already started — reported live 2026-09-26.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            posterHidden = true
        }
        VLCBridge.shared.setVolume(Int(volume))
    }

    // Auto-start gate — called when VLCBridge.readyToReveal flips (first frame decoded, or the
    // bridge's audio-only give-up) and whenever the poster reappears.
    private func attemptAutoStart() {
        guard bridge.isPlaying, bridge.readyToReveal, !posterHidden, !isPrimaryIdle else { return }
        startPlayback(reason: bridge.hasVideoFrame ? "first video frame decoded" : "no video frame (audio-only fallback)")
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

        let (title, episodeInfo) = titleAndEpisode(entry: entry, feedEntry: feedEntry)
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
            // Omnidirectional halo, not a single offset drop shadow — found live 2026-09-26 via a
            // batch of screenshots across several live channels: a directional shadow (x:1,y:1) only
            // darkens one edge of each glyph, which reads fine over mid-to-dark content (a football
            // field, a dim interior scene) but nearly disappears over a bright/white broadcast
            // graphic (a golf stats card, a QVC product shot) — exactly the white-text-on-white-ish-
            // background case captions/lower-thirds solve with a full outline, not a shadow. SwiftUI
            // has no text-stroke modifier, so two stacked zero-offset `.shadow` passes approximate
            // one: a tight, near-opaque inner halo plus a softer, wider outer one, both centered
            // (x:0,y:0) so they surround every glyph evenly instead of favoring one side.
            .shadow(color: .black.opacity(0.95), radius: 2, x: 0, y: 0)
            .shadow(color: .black.opacity(0.85), radius: 5, x: 0, y: 0)
            // Neutral backdrop panel behind the text (2026-10-03, explicit request) — slides in with
            // the banner. The leading padding is inside the panel, so it runs flush to the window's
            // left edge with the text inset 44pt as before.
            .padding(.leading, 44)
            .padding(.trailing, 64)
            .padding(.vertical, 18)
            .background(alignment: .leading) { infoBannerBackdrop }
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

    /// Greyscale lower-third panel — charcoal gradient with a thin pale accent bar, no colour so it
    /// sits behind any channel's picture. Rounded only on its trailing corners (it bleeds off the
    /// window's left edge).
    private var infoBannerBackdrop: some View {
        ZStack(alignment: .leading) {
            UnevenRoundedRectangle(bottomTrailingRadius: 14, topTrailingRadius: 14)
                .fill(LinearGradient(colors: [Color(white: 0.08).opacity(0.90), Color(white: 0.18).opacity(0.80)],
                                     startPoint: .leading, endPoint: .trailing))
            Rectangle()
                .fill(Color(white: 0.85).opacity(0.9))
                .frame(width: 3)
                .padding(.vertical, 16)
                .padding(.leading, 28)
        }
        .shadow(color: .black.opacity(0.45), radius: 10, x: 2, y: 0)
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
        // Cross-device PiP swap (the branch above resolves selectedChannel to it, but doesn't say
        // so) — name the actual tuner this channel is playing from, the same way the FEED lines
        // above name theirs, rather than reading identically to a same-device live channel. Found
        // live 2026-09-26 alongside the currentGuideEntry cross-device fix: without this, "Live OTA
        // · Ch 5.1 KMSP" gave no hint the picture was actually coming from a different device than
        // the one this window opened on.
        if let otherDeviceId = VLCPlayerWindowManager.shared.currentDeviceID, otherDeviceId != device.DeviceID {
            return "Live OTA · \(otherDeviceId) · Ch \(ch.GuideNumber)  \(ch.GuideName)"
        }
        return "Live OTA · Ch \(ch.GuideNumber)  \(ch.GuideName)"
    }

    // MARK: - Status bar data

    private func statusBarView() -> some View {
        PlayerStatusBar(state: state, device: device, channel: selectedChannel, info: statusBarInfo,
                        poster: posterNSImage, channelLogoURL: statusBarChannelLogoURL,
                        upcoming: statusBarUpcoming, canRecordUpcoming: statusBarCanRecordUpcoming, shimmerToken: barShimmerToken)
    }

    /// Switches the persistent status bar on or off. The window is resized in the same step as the state change (and
    /// without animation), so the picture never sees an intermediate layout — animating the window while the bar's row
    /// appeared at once made the video jitter.
    private func setStatusBar(_ on: Bool, persist: Bool = true) {
        guard on != barWanted else { return }
        barCloseTask?.cancel()
        let seconds = Self.barSlideSeconds
        barSlidIn = on
        if persist { statusBarEnabled = on }   // a peek leaves the saved choice alone, so it can never get stuck open
        let target = on ? VLCPlayerWindowManager.playerStatusBarHeight : 0
        if on {
            if !barRowOpen {   // a bar still closing re-opens from where it is, not from zero
                barRowHeight = 0
                barContentOffset = -22   // the bar starts lifted into the picture, then drops and bounces into place
            }
            barShimmerToken += 1
            barRowOpen = true
        } else {
            // A small upward wind-up, then the row and window collapse together.
            withAnimation(.easeOut(duration: 0.12)) { barContentOffset = -7 }
        }
        barCloseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(on ? 30 : 120))   // let the empty row exist / the wind-up play
            guard !Task.isCancelled else { return }
            if on {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.5)) { barContentOffset = 0 }
            }
            await slideBarRow(to: target, seconds: seconds)
            guard !Task.isCancelled else { return }
            if !on {
                barRowOpen = false   // the window has already shrunk; this just drops the empty row
                barContentOffset = 0
                infoFlashCount += 1   // hint: press ⓘ to bring it back
            }
        }
    }

    /// Moves the bar's row and the window together, one frame at a time from a single clock. Two separate animations
    /// (SwiftUI for the row, AppKit for the window) drift apart by a frame or two, which shows as the video shaking;
    /// here the window's height and the row's height are set in the same step from the same eased value, so the
    /// video area never changes size.
    private func slideBarRow(to target: CGFloat, seconds: Double) async {
        let manager = VLCPlayerWindowManager.shared
        let from = barRowHeight
        guard from != target else { manager.commitStatusBarHeight(target); return }
        guard let base = manager.beginStatusBarSlide() else {   // fullscreen or no window: nothing to resize
            barRowHeight = target; manager.setStatusBarVisible(target > 0); return   // owes the resize until fullscreen ends
        }
        let start = Date()
        while !Task.isCancelled {
            let t = min(1, Date().timeIntervalSince(start) / seconds)
            let eased = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
            let row = from + (target - from) * CGFloat(eased)
            barRowHeight = row
            manager.setContentHeightDuringSlide(base + (row - from))
            if t >= 1 { break }
            try? await Task.sleep(for: .milliseconds(16))
        }
        if !Task.isCancelled { manager.commitStatusBarHeight(target) }
    }

    /// ⓘ / the I key. During the brief opening peek a click keeps the bar open instead of closing it.
    private func userToggleStatusBar() {
        if barIsPeek { barIsPeek = false; statusBarEnabled = true; return }   // a click during the peek keeps the bar
        setStatusBar(!barWanted)
    }

    /// What the user has asked for: on from the moment it starts sliding in, off from the moment it starts sliding out.
    private var barWanted: Bool { barRowOpen && barSlidIn }

    /// Opens the bar for `tempBarSeconds` when a stream starts (the same pop-down as switching it on, window and all),
    /// then closes it and pulses ⓘ. Only when the bar is off, and never in full screen.
    private func revealStatusBarBriefly() {
        guard !barWanted || barIsPeek, !isFullScreen else { return }
        tempBarToken += 1
    }


    /// Title and episode line, shared by the info banner and the status bar so the two always agree.
    private func titleAndEpisode(entry: GuideEntry?, feedEntry: LineupEntry?) -> (title: String, episode: String?) {
        let title = entry?.Title ?? feedEntry?.virtualRelayShowTitle ?? selectedChannel?.GuideName ?? "Unknown"
        let episode: String? = entry?.episodeInfoLabel ?? feedEntry.flatMap { fe in
            let parts = [fe.virtualRelayEpisodeNumber, fe.virtualRelayEpisodeTitle].compactMap { s -> String? in
                guard let s, !s.isEmpty else { return nil }
                return s
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
        return (title, episode)
    }

    private var statusBarSource: PlayerStatusInfo.Source {
        if bridge.recordingShowId != nil { return .recording }
        let isFeed = device.isVirtualRelay || (selectedChannel?.GuideNumber.hasPrefix(Self.liveFeedGuideNumberPrefix) ?? false)
        if isFeed {
            var host = currentFeedEntry?.virtualRelaySourceHostname
            if host == nil, let ch = selectedChannel, ch.GuideNumber.hasPrefix(Self.liveFeedGuideNumberPrefix) {
                let remoteURL = String(ch.GuideNumber.dropFirst(Self.liveFeedGuideNumberPrefix.count))
                host = state.remoteRelayEntries.first { $0.entry.URL == remoteURL }?.entry.virtualRelaySourceHostname
            }
            return .feed(host: host)
        }
        let deviceID = VLCPlayerWindowManager.shared.currentDeviceID ?? device.DeviceID
        let quality = state.deviceTunerOccupancy[deviceID]?
            .first { $0.VctNumber == selectedChannel?.GuideNumber }?.SignalQualityPercent
        return .liveTuner(deviceID: deviceID, signalQuality: quality)
    }

    private var statusBarInfo: PlayerStatusInfo {
        // A FEED session has no guide entry of its own; borrow the matching airing from a guide this Mac holds so the
        // bar shows the same time, genre and synopsis a local show does.
        let guide = currentGuideEntry
        let entry = guide ?? feedMatchSnapshot?.entry   // the FEED match is looked up once per show (see computeUpcoming)
        let feedEntry = (guide == nil && device.isVirtualRelay) ? currentFeedEntry : nil
        let source = statusBarSource
        let (title, episode) = titleAndEpisode(entry: entry, feedEntry: feedEntry)
        return PlayerStatusInfo(
            title: title, episodeLine: episode,
            timeRange: entry.map { PlayerStatusFormat.timeRange(start: $0.startDate, end: $0.endDate) },
            genres: entry.map { PlayerStatusFormat.genreTags($0) } ?? [],
            detailLine: PlayerStatusFormat.detailLine(synopsis: entry?.Synopsis ?? feedEntry?.virtualRelaySynopsis,
                                                      originalAirdate: entry?.OriginalAirdate,
                                                      isNew: entry.map(isNewEpisode) ?? false),
            isNew: entry.map(isNewEpisode) ?? false,
            source: source,
            airing: statusBarAiring(entry, source: source),
            slotEnd: entry?.endDate,
            accent: entry.flatMap { $0.firstGenre == nil ? nil : guideEntryColor(for: $0, onAir: true) })
    }

    /// The network logo the bar falls back to when the show has no image (or it failed to load).
    private var statusBarChannelLogoURL: String? {
        if let entry = currentGuideEntry, !entry.channelNum.isEmpty {
            return state.channelImageURLs["\(entry.deviceId):\(entry.channelNum)"]
        }
        guard let ch = selectedChannel else { return nil }
        return state.channelImageURLs["\(VLCPlayerWindowManager.shared.currentDeviceID ?? device.DeviceID):\(ch.GuideNumber)"]
    }

    /// Progress only makes sense for a live tuner: a recording plays from disk, so wall-clock time says nothing about it.
    private func statusBarAiring(_ entry: GuideEntry?, source: PlayerStatusInfo.Source) -> DateInterval? {
        guard let entry, case .liveTuner = source, entry.endDate > entry.startDate else { return nil }
        return DateInterval(start: entry.startDate, end: entry.endDate)
    }

    /// The airing a FEED session's show came from, found by title in the guides we hold (the relay's lineup carries
    /// no channel number). Anchored to when its recording file began so a later airing of the same series isn't picked.
    private func feedGuideMatch(guide: GuideEntry?) -> GuideStore.SeriesMatch? {
        guard guide == nil, device.isVirtualRelay, let feed = currentFeedEntry,
              let title = feed.virtualRelayShowTitle, !title.isEmpty else { return nil }
        let at = feed.virtualRelayFileStartedAt.map { Date(timeIntervalSince1970: $0 + 60) } ?? Date()
        return state.guideStore.currentEntryByTitle(title, at: at)
    }

    /// The channel's next shows after the current one, from the guide the app already holds.
    private var statusBarUpcoming: [GuideEntry] { upcomingSnapshot }

    /// Changes only when the current show (or channel) does; the strip is rebuilt then, not on every redraw.
    private var upcomingKey: String {
        if let e = currentGuideEntry { return "\(e.deviceId):\(e.channelNum):\(e.StartTime)" }
        return "feed:\(currentFeedEntry?.virtualRelayShowTitle ?? ""):\(currentFeedEntry?.virtualRelayFileStartedAt ?? 0)"
    }

    private func computeUpcoming() -> [GuideEntry] {
        let guide = currentGuideEntry
        feedMatchSnapshot = feedGuideMatch(guide: guide)
        if let m = feedMatchSnapshot {
            return PlayerStatusFormat.upcoming(
                after: m.entry,
                in: state.guideStore.entries(deviceId: m.deviceId, channelNum: m.channelNum, after: m.entry.endDate),
                horizon: .infinity, limit: .max)
        }
        guard let entry = guide, !entry.channelNum.isEmpty else { return [] }
        return PlayerStatusFormat.upcoming(
            after: entry,
            in: state.guideStore.entries(deviceId: entry.deviceId, channelNum: entry.channelNum, after: entry.endDate),
            horizon: .infinity, limit: .max)
    }

    /// Same conditions as the toolbar's Record button, minus the "on now" requirement: a live tuner session, a real
    /// channel, and no active managed show already covering this channel.
    private var statusBarCanRecordUpcoming: Bool {
        guard bridge.recordingShowId == nil, !device.isVirtualRelay, let ch = selectedChannel else { return false }
        return !state.shows.contains { $0.show_active && $0.hdhr_record == device.DeviceID && $0.show_channel == ch.GuideNumber }
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
                        // poster showed nothing at all while the stream started.
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

                    // No session needs a click (2026-10-03): every stream auto-starts on its first
                    // decoded video frame (attemptAutoStart), so everything below is
                    // non-interactive status — spinner + label, no button.
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
                        // Status only (2026-10-03): playback starts by itself once the first video
                        // frame is decoded (attemptAutoStart) — this replaced the Start button.
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(bridge.isPlaying ? "Starting…" : "Connecting…")
                        }
                        .font(.title3.bold())
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.white.opacity(0.6))
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("vlc-start-status")
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
    //
    // Target width scales with the video pane's own current size, not a single fixed pixel value —
    // a fixed 192pt (the pre-2026-09-29 behavior) looked reasonable only near the default ~1080pt
    // window width: tiny on a window resized up toward a 4K/5K native size, oversized on a window
    // shrunk down small. `pipThumbnailWidthFraction` of the pane's current width, clamped to
    // [pipThumbnailMinWidth, pipThumbnailMaxWidthCap] so it never drops below a usable hit-target/
    // readability floor or grows large enough to compete with the primary video.
    // 2026-10-03 (explicit user request: bigger, scaling with the window): 0.18 → 0.32, [140, 340] →
    // [200, 640].
    nonisolated private static let pipThumbnailWidthFraction: CGFloat = 0.32
    nonisolated private static let pipThumbnailMinWidth: CGFloat = 200
    nonisolated private static let pipThumbnailMaxWidthCap: CGFloat = 640

    /// Pure decision, extracted for unit testing.
    nonisolated static func pipThumbnailMaxWidth(containerWidth: CGFloat) -> CGFloat {
        max(pipThumbnailMinWidth, min(pipThumbnailMaxWidthCap, containerWidth * pipThumbnailWidthFraction))
    }

    // The *actual* rendered size snaps to a clean power-of-two fraction of the secondary stream's
    // own native pixel size (nativeWidth/4, /8, /16, /32 — same integer applied to both axes) rather
    // than scaling to an arbitrary target width. Reported live 2026-09-29: a plain "scale to
    // targetWidth px" (the original design) produces a non-clean downscale ratio against the
    // source's real resolution, which introduced a slight moiré on some content (fine grids/text)
    // — an arbitrary ratio doesn't land on pixel-aligned sample boundaries the way a clean binning
    // ratio does. Dividing width and height by the *same* integer also guarantees the aspect ratio
    // is preserved exactly (no separate rounding of each axis to drift apart), and — since the
    // smallest divisor is 4 — this can only ever downscale, never upscale past native, however small
    // the window gets.
    nonisolated private static let pipThumbnailDivisors: [Int] = [4, 8, 16, 32]
    // 2026-10-03: power-of-two steps alone jump 2× at a time (480→240 wide on a 1080p source), so a
    // bigger thumbnail stopped tracking the window smoothly. These extra integers are also clean
    // binning ratios, but only used when they divide BOTH native axes exactly (1920×1080 → 2, 3, 5,
    // 6, 10, 12 all qualify; 1280×720 skips 3), so neither axis is ever rounded. Candidates are the
    // union with `pipThumbnailDivisors`, so a source with no exact extras (e.g. 1366×768) behaves
    // exactly as before. Smallest is 2, so still never upscales past native.
    nonisolated private static let pipThumbnailExtraDivisors: [Int] = [2, 3, 5, 6, 10, 12]

    private func pipThumbnailSize(containerWidth: CGFloat) -> CGSize {
        Self.pipThumbnailSize(nativePixelSize: bridge.secondaryVideoPixelSize,
                               targetWidth: Self.pipThumbnailMaxWidth(containerWidth: containerWidth))
    }

    /// Pure decision, extracted for unit testing. Picks whichever `pipThumbnailDivisors` entry
    /// divides the native size into a width closest to `targetWidth`, then divides *both* axes by
    /// that same integer. `nativePixelSize` invalid/unknown (nil, or either dimension <= 0, i.e.
    /// before libvlc has reported real dimensions) falls back to a plain 16:9 box sized exactly to
    /// `targetWidth` — there's no native size yet to snap against.
    nonisolated static func pipThumbnailSize(nativePixelSize: CGSize?, targetWidth: CGFloat) -> CGSize {
        guard let native = nativePixelSize, native.width > 0, native.height > 0 else {
            return CGSize(width: targetWidth, height: (targetWidth * 9 / 16).rounded())
        }
        let exactExtras = pipThumbnailExtraDivisors.filter {
            native.width.truncatingRemainder(dividingBy: CGFloat($0)) == 0
                && native.height.truncatingRemainder(dividingBy: CGFloat($0)) == 0
        }
        let candidates = pipThumbnailDivisors + exactExtras
        let bestDivisor = candidates.min { a, b in
            abs(native.width / CGFloat(a) - targetWidth) < abs(native.width / CGFloat(b) - targetWidth)
        } ?? pipThumbnailDivisors[0]
        let width = (native.width / CGFloat(bestDivisor)).rounded()
        let height = (native.height / CGFloat(bestDivisor)).rounded()
        return CGSize(width: width, height: height)
    }

    // GeometryReader added 2026-09-29 (alongside the fixed→proportional maxWidth change above) —
    // the only reason this overlay needs its container's actual size at all.
    private var pipAvoidsInfoBanner: Bool { Self.pipAvoidsInfoBanner(corner: pipCorner, bannerVisible: infoOverlayVisible) }

    /// Pure: whether the PiP must step out of the way of the info banner — only the lower-left corner, the banner's.
    nonisolated static func pipAvoidsInfoBanner(corner: PipCorner, bannerVisible: Bool) -> Bool {
        bannerVisible && corner == .bottomLeading
    }

    /// Pure: how far up a bottom-corner thumbnail moves to reach the top corner (the overlay's own 16pt padding on both sides).
    nonisolated static func pipBannerAvoidanceOffset(containerHeight: CGFloat, thumbHeight: CGFloat, padding: CGFloat = 16) -> CGFloat {
        max(0, containerHeight - thumbHeight - 2 * padding)
    }

    private var pipOverlay: some View {
        GeometryReader { geo in
        // Computed once per body evaluation rather than re-derived at each of its three use sites
        // below (found in code review: the same min/max-clamp + divisor-search math was redone
        // three times for the same geo.size.width).
        let thumbSize = pipWidthFraction > 0
            ? Self.pipUserThumbnailSize(nativePixelSize: bridge.secondaryVideoPixelSize,
                                        containerSize: geo.size, widthFraction: pipWidthFraction)
            : pipThumbnailSize(containerWidth: geo.size.width)
        let thumbAspect = thumbSize.height > 0 ? thumbSize.width / thumbSize.height : 16.0 / 9.0
        VStack {
            if !pipCorner.isTop { Spacer() }
            HStack {
                if !pipCorner.isLeading { Spacer() }
                // The resize handle sits on the thumbnail's inner corner; bottomLeading's inner corner
                // is top-trailing, where the close button lives, so the close button moves to top-leading.
                ZStack(alignment: pipCorner == .bottomLeading ? .topLeading : .topTrailing) {
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
                        .frame(width: thumbSize.width, height: thumbSize.height)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.25)))
                        .contentShape(Rectangle())
                        // Smooths the jump between quantized divisor sizes (see
                        // pipThumbnailSize) while dragging the window to resize it, rather than
                        // popping straight from one clean fraction to the next.
                        .animation(pipResizeStartWidth == nil ? .easeOut(duration: 0.15) : nil, value: thumbSize)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("vlc-pip-thumbnail")
                    .accessibilityLabel("Swap to picture-in-picture stream")
                    .help(VLCPlayerWindowManager.shared.secondaryTitle.map { "\($0) (picture-in-picture)" } ?? "Picture-in-picture")
                    // Native NSMenu, not .contextMenu — see NativeContextMenuHost (a SwiftUI context
                    // menu reloaded every few seconds while open, on VLCBridge/AppState publishes).
                    .overlay { NativeContextMenuHost { makePipNSMenu() } }

                    // Hover-revealed (opacity, not conditional rendering — the same "hidden but
                    // still hoverable" idiom the recording scrub bar/fullscreen toolbar overlays
                    // use above) rather than always-on, so the corner stays clean until you're
                    // actually near it. .onHover is on the outer ZStack below, not this button
                    // alone, so moving onto the thumbnail itself also reveals it — no chicken-
                    // and-egg problem where the button must already be visible to be hovered.
                    Button {
                        VLCPlayerWindowManager.shared.closeSecondary()
                    } label: {
                        // Hidden by colour, NOT opacity(0): SwiftUI drops an opacity-0 view from the accessibility
                        // tree, which left the close button unreachable for VoiceOver / keyboard users (and for AX
                        // automation) until the pointer happened to be over the PiP. A clear symbol is invisible but
                        // still a labelled button; the content shape keeps its hit area the same when hidden.
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(pipHovered ? Color.white : Color.clear,
                                             pipHovered ? Color.black.opacity(0.6) : Color.clear)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                    .accessibilityIdentifier("vlc-pip-close-button")
                    .accessibilityLabel("Close picture-in-picture")
                    .animation(.easeInOut(duration: 0.2), value: pipHovered)
                }
                .overlay(alignment: pipResizeHandleAlignment) {
                    pipResizeHandle(startWidth: thumbSize.width, aspect: thumbAspect, containerSize: geo.size)
                }
                .onHover { pipHovered = $0 }
                // The info ("i") banner sits lower-left; a PiP in that corner steps up to the top while it shows
                // and drops back when it auto-hides. Offset (not a different corner) so it slides, and the saved
                // corner / resize math are untouched.
                .offset(y: pipAvoidsInfoBanner ? -Self.pipBannerAvoidanceOffset(containerHeight: geo.size.height, thumbHeight: thumbSize.height) : 0)
                .animation(.easeOut(duration: 0.35), value: pipAvoidsInfoBanner)
                if pipCorner.isLeading { Spacer() }
            }
            if pipCorner.isTop { Spacer() }
        }
        .padding(16)
        }
        // Load the saved size each time the PiP appears (not mid-drag).
        .onAppear { if pipResizeStartWidth == nil { pipWidthFraction = state.config.PiP_width_fraction } }
    }

    // MARK: PiP resize handle (2026-10-03, explicit request)

    /// The thumbnail corner facing the video pane's centre — dragging it outward/inward grows/shrinks
    /// the thumbnail while the opposite (pinned) corner stays put.
    private func commitPipWidthFraction() {
        guard state.config.PiP_width_fraction != pipWidthFraction else { return }
        state.config.PiP_width_fraction = pipWidthFraction
        state.saveConfig()
    }

    private var pipResizeHandleAlignment: Alignment {
        switch pipCorner {
        case .bottomTrailing: return .topLeading
        case .bottomLeading:  return .topTrailing
        case .topTrailing:    return .bottomLeading
        case .topLeading:     return .bottomTrailing
        }
    }

    private var pipResizePointerPosition: FrameResizePosition {
        switch pipCorner {
        case .bottomTrailing: return .topLeading
        case .bottomLeading:  return .topTrailing
        case .topTrailing:    return .bottomLeading
        case .topLeading:     return .bottomTrailing
        }
    }

    @ViewBuilder
    private func pipResizeHandle(startWidth: CGFloat, aspect: CGFloat, containerSize: CGSize) -> some View {
        let atTop = pipResizeHandleAlignment == .topLeading || pipResizeHandleAlignment == .topTrailing
        let atLeading = pipResizeHandleAlignment == .topLeading || pipResizeHandleAlignment == .bottomLeading
        let visible = pipHandleHovered || pipResizeStartWidth != nil
        // Invisible hover/hit zone (a clear Color with a contentShape — a fully transparent *visible*
        // view isn't a reliable hover target) larger than the grip, so the grip fades in as the
        // pointer approaches the corner and clicks on it never reach the swap Button underneath.
        Color.clear
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .overlay(alignment: Self.pipGripAlignment(atTop: atTop, atLeading: atLeading)) {
                PipResizeGrip(atTop: atTop, atLeading: atLeading)
                    .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .shadow(color: .black.opacity(0.8), radius: 1.5)
                    .frame(width: 18, height: 18)
                    .padding(5)
                    .opacity(visible ? 1 : 0)
                    .animation(.easeInOut(duration: 0.15), value: visible)
                    .allowsHitTesting(false)
            }
            .onHover { pipHandleHovered = $0 }
            .pointerStyle(.frameResize(position: pipResizePointerPosition))
            .accessibilityElement()
            .accessibilityIdentifier("vlc-pip-resize-handle")
            .accessibilityLabel("Resize picture-in-picture")
            .help("Drag to resize (keeps the stream's aspect ratio) — double-click to reset")
            // Double first so it wins over the single (swallow-only) tap below.
            .onTapGesture(count: 2) { pipWidthFraction = 0; commitPipWidthFraction() }
            .onTapGesture { }
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { drag in
                        let base = pipResizeStartWidth ?? startWidth
                        pipResizeStartWidth = base
                        let width = Self.pipResizedWidth(startWidth: base, translation: drag.translation,
                                                         corner: pipCorner, aspect: aspect)
                        let clamped = Self.pipClampedWidth(width, aspect: aspect, containerSize: containerSize)
                        if containerSize.width > 0 { pipWidthFraction = Double(clamped / containerSize.width) }
                    }
                    .onEnded { _ in
                        pipResizeStartWidth = nil
                        commitPipWidthFraction()
                    }
            )
    }

    /// Grip sits flush in the thumbnail's own corner within the 44pt zone.
    nonisolated private static func pipGripAlignment(atTop: Bool, atLeading: Bool) -> Alignment {
        switch (atTop, atLeading) {
        case (true, true):   return .topLeading
        case (true, false):  return .topTrailing
        case (false, true):  return .bottomLeading
        case (false, false): return .bottomTrailing
        }
    }

    nonisolated private static let pipUserMinWidth: CGFloat = 120
    nonisolated private static let pipUserMaxPaneFraction: CGFloat = 0.8

    /// Pure: new thumbnail width after dragging the inner-corner handle by `translation` (screen
    /// points, y down). Dragging away from the pinned corner grows it; a height delta counts as
    /// `aspect`× its size in width, and the two axes are averaged so a diagonal drag feels natural.
    nonisolated static func pipResizedWidth(startWidth: CGFloat, translation: CGSize,
                                            corner: PipCorner, aspect: CGFloat) -> CGFloat {
        let sx: CGFloat = corner.isLeading ? 1 : -1
        let sy: CGFloat = corner.isTop ? 1 : -1
        return startWidth + (sx * translation.width + sy * translation.height * aspect) / 2
    }

    /// Pure: keeps the thumbnail between a usable minimum and 80% of the pane in both axes.
    nonisolated static func pipClampedWidth(_ width: CGFloat, aspect: CGFloat, containerSize: CGSize) -> CGFloat {
        let a = aspect > 0 ? aspect : 16.0 / 9.0
        let maxW = max(pipUserMinWidth, min(containerSize.width * pipUserMaxPaneFraction,
                                            containerSize.height * pipUserMaxPaneFraction * a))
        return max(pipUserMinWidth, min(maxW, width))
    }

    /// Pure: the rendered size for a user-chosen `widthFraction` of the pane — exactly the stream's
    /// native aspect ratio (16:9 until the first decoded frame), never stretched. Not snapped to the
    /// clean divisors the automatic size uses: the user picked this size.
    nonisolated static func pipUserThumbnailSize(nativePixelSize: CGSize?, containerSize: CGSize,
                                                 widthFraction: Double) -> CGSize {
        let aspect: CGFloat
        if let n = nativePixelSize, n.width > 0, n.height > 0 { aspect = n.width / n.height } else { aspect = 16.0 / 9.0 }
        let width = pipClampedWidth(containerSize.width * CGFloat(widthFraction), aspect: aspect, containerSize: containerSize)
        return CGSize(width: width.rounded(), height: (width / aspect).rounded())
    }

    // Right-click menu on the PiP thumbnail — the user-facing way to move it, resize-reset, retune
    // (live-channel secondaries only) and close it. Built imperatively at right-click time as a
    // native NSMenu (NativeContextMenuHost) so SwiftUI re-evaluations can't reload it while open.
    //
    // Channel submenu: reverses the original "no in-place channel/source changes" design
    // (docs/VLCPlayerView.md) per explicit request. Live-channel secondaries only
    // (secondaryChannelNumber is nil for a FEED or Watch Now secondary — neither has a channel
    // lineup to switch within). Scoped to the secondary's own device (state.lineups[deviceId]),
    // which may differ from the primary's bound device (cross-device secondaries are supported).
    // A checkmark marks the corner currently in effect, matching native single-choice menus.
    private func makePipNSMenu() -> NSMenu {
        let menu = NSMenu()
        if pipWidthFraction > 0 {
            menu.addItem(ClosureMenuItem(title: "Reset Size") { pipWidthFraction = 0; commitPipWidthFraction() })
            menu.addItem(.separator())
        }
        for corner in PipCorner.allCases {
            menu.addItem(ClosureMenuItem(title: corner.displayName, checked: corner == pipCorner) { pipCorner = corner })
        }
        let mgr = VLCPlayerWindowManager.shared
        if let deviceId = mgr.secondaryDeviceID, mgr.secondaryChannelNumber != nil {
            let all = (state.lineups[deviceId] ?? []).sorted {
                $0.GuideNumber.localizedStandardCompare($1.GuideNumber) == .orderedAscending
            }
            let favs = all.filter(\.isFavorite)
            let others = all.filter { !$0.isFavorite }
            let sub = NSMenu()
            for ch in favs {
                sub.addItem(ClosureMenuItem(title: "\(ch.GuideNumber)  \(ch.GuideName)") { playSecondaryChannel(ch, deviceId: deviceId) })
            }
            if !favs.isEmpty && !others.isEmpty { sub.addItem(.separator()) }
            for ch in others {
                sub.addItem(ClosureMenuItem(title: "\(ch.GuideNumber)  \(ch.GuideName)") { playSecondaryChannel(ch, deviceId: deviceId) })
            }
            menu.addItem(.separator())
            let channelItem = NSMenuItem(title: "Channel", action: nil, keyEquivalent: "")
            channelItem.submenu = sub
            menu.addItem(channelItem)
        }
        menu.addItem(.separator())
        // A second, always-discoverable way to close the secondary — the "×" button itself is
        // hover-revealed, so this covers anyone who right-clicks before hovering long enough to see it.
        menu.addItem(ClosureMenuItem(title: "Close Picture-in-Picture") { VLCPlayerWindowManager.shared.closeSecondary() })
        return menu
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

    /// The quick-record target (selected channel + airing entry) when the Record control applies; nil hides it.
    /// Hidden while watching a recording-relay stream (already being captured, see bridge.recordingShowId),
    /// when nothing's currently airing on the selected channel, or when this exact channel already has an
    /// active managed show (avoids offering a redundant add).
    private var quickRecordTarget: (channel: LineupEntry, entry: GuideEntry)? {
        guard bridge.recordingShowId == nil, let ch = selectedChannel, let entry = currentGuideEntry,
              !state.shows.contains(where: { $0.show_active && $0.hdhr_record == device.DeviceID && $0.show_channel == ch.GuideNumber })
        else { return nil }
        return (ch, entry)
    }

    private var showsH264Toggle: Bool { device.isVirtualRelay && !feedSourceAlreadyModern }

    /// The responsive toolbar's plan (docs/VLCPlayerView.md, "Responsive toolbar"): which controls are full, compact or
    /// folded into the "…" menu for the width measured so far. Unmeasured (0) = everything on the bar.
    private var toolbarPlan: ToolbarOverflowPlanner.Plan {
        let specs = PlayerToolbarItem.specs(hasRecord: quickRecordTarget != nil, bufferEnabled: bridge.bufferInfo.enabled,
                                            recordingRelay: bridge.recordingShowId != nil, hasH264: showsH264Toggle)
        return ToolbarOverflowPlanner.plan(items: specs, available: toolbarWidth > 0 ? toolbarWidth : .greatestFiniteMagnitude,
                                           previous: toolbarPlanMemo)
    }

    private var toolbar: some View {
        let plan = toolbarPlan
        let rec = quickRecordTarget
        // The row is an overlay on a flexible, fixed-height base: the base takes exactly the width the window offers (so the
        // measurement can't be inflated by controls that don't fit), and the controls overflow rather than push the window wide.
        return Color(NSColor.windowBackgroundColor)
            .frame(height: VLCPlayerWindowManager.playerToolbarHeight)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { toolbarWidth = $0 })
            .overlay { toolbarRow(plan: plan, rec: rec) }
        // Slide the bar in when a stream's first frame is decoded (every new stream, not just the window opening).
        .onChange(of: bridge.hasVideoFrame) { _, has in if has { revealStatusBarBriefly() } }
        .task(id: upcomingKey) { upcomingSnapshot = computeUpcoming() }
        .task(id: tempBarToken) {
            // The toolbar exists as two copies (windowed / full-screen overlay), so a fresh copy would otherwise re-run an
            // old token: handle each token once, and never while in full screen.
            guard tempBarToken > handledPeekToken, !isFullScreen else { return }
            handledPeekToken = tempBarToken
            barIsPeek = true
            setStatusBar(true, persist: false)
            try? await Task.sleep(for: .seconds(Self.barSlideSeconds + Self.tempBarSeconds))
            guard !Task.isCancelled, barIsPeek else { return }   // a click made it permanent
            barIsPeek = false
            setStatusBar(false, persist: false)
        }
        // Pulses the ⓘ icon three times.
        .task(id: infoFlashCount) {
            guard infoFlashCount > handledFlashCount else { return }
            handledFlashCount = infoFlashCount
            for _ in 0..<3 {
                withAnimation(.easeInOut(duration: 0.3)) { infoGlow = true }
                try? await Task.sleep(for: .milliseconds(300))
                withAnimation(.easeInOut(duration: 0.3)) { infoGlow = false }
                try? await Task.sleep(for: .milliseconds(350))
                if Task.isCancelled { infoGlow = false; return }
            }
        }
        .onChange(of: bridge.isPlaying) { _, playing in
            if !playing { streamInfoHovered = false }
        }
        // Remember the plan in force so the planner's hysteresis has something to compare against.
        .onChange(of: plan) { _, p in toolbarPlanMemo = p }
        // ⓘ folded into "…": its hover popover has no anchor any more — close it and forget the hover.
        .onChange(of: plan.isFolded(PlayerToolbarItem.info)) { _, folded in
            if folded { streamInfoHovered = false; popoverAnchorHovered = false; popoverBodyHovered = false }
        }
        .focusEffectDisabled()   // no blue focus box around whichever toolbar button was last clicked
    }

    /// The toolbar's controls, laid out per `plan`: a control the plan folds is not drawn here but offered at the top of the
    /// "…" menu (`foldedMenuItems`). Every control keeps its accessibility identifier in both places.
    @ViewBuilder
    private func toolbarRow(plan: ToolbarOverflowPlanner.Plan, rec: (channel: LineupEntry, entry: GuideEntry)?) -> some View {
        HStack(spacing: ToolbarOverflowPlanner.spacing) {
            // Channel picker — sorted by guide number
            Picker("Channel", selection: $selectedChannel) {
                // Fallback: selected whenever selectedChannel is nil and nothing else matched
                // (shouldn't normally happen once recordingChannelEntries covers every relay
                // stream, but avoids ever rendering blank). Hidden entirely when nothing on this
                // device is recording — there's no "Live" to fall back to in that case.
                if !recordingChannelEntries.isEmpty || currentFeedRow != nil {
                    Text("Live").tag(Optional<LineupEntry>.none)
                }
                // The standard stack (2026-10-02, explicit request) — Recording, then FEED, then
                // Favorites, then the rest — in every window, FEED views included.
                if !recordingChannelEntries.isEmpty {
                    Section("Recording") {
                        // GuideName already holds the full "Live 5.1  Title" label.
                        ForEach(recordingChannelEntries, id: \.GuideNumber) { entry in
                            Text(entry.GuideName).tag(Optional(entry))
                        }
                    }
                }
                if !allFeedEntries.isEmpty {
                    Section("FEED") {
                        ForEach(allFeedEntries, id: \.GuideNumber) { entry in
                            Text(entry.GuideName).tag(Optional(entry))
                        }
                    }
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
                Section(favoriteLineup.isEmpty ? "" : "Channels") {
                    ForEach(otherLineup, id: \.GuideNumber) { ch in
                        Text("\(ch.GuideNumber)  \(ch.GuideName)").tag(Optional(ch))
                    }
                }
            }
            .labelsHidden()
            // Shrinks (never folds) as the window narrows — see PlayerToolbarItem.
            .frame(maxWidth: plan.isCompact(PlayerToolbarItem.picker) ? PlayerToolbarItem.pickerCompact : PlayerToolbarItem.pickerFull)
            .accessibilityLabel("Channel")
            .accessibilityIdentifier("vlc-channel-picker")
            .onChange(of: selectedChannel) { oldCh, ch in handleChannelPickChanged(from: oldCh, to: ch) }

            // Quick-record: the same four-type pulldown as Watch Now's Record button
            // (WatchNowRow/quickRecordMenu, GuideViewHelpers.swift), a labeled red "Record" control.
            // Hidden under the conditions in `quickRecordTarget`; folds into a "Record" submenu of "…"
            // (first after the clock, live buffer and H.264 toggle) when the window gets narrow.
            if let rec, !plan.isFolded(PlayerToolbarItem.record) {
                quickRecordMenu(state: state, entry: rec.entry, device: device, channel: rec.channel,
                                 tunerFullAlert: $showTunerFullAlert, yieldWatchNowConfirm: $yieldWatchNowConfirm) {
                    Label("Record", systemImage: "record.circle")
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .accessibilityLabel("Record \(rec.entry.Title)")
                .accessibilityIdentifier("vlc-quick-record")
                .help("Record \(rec.entry.Title)")
            }

            Spacer(minLength: 0)

            // Buffer monitor + catch-up: grouped into a single control unit when buffering is active.
            // Both relate to live-stream temporal state, so they share a pill background with a
            // hairline divider between them. Catch-up stands alone when buffering is disabled.
            // With buffering on the catch-up button is icon-only (pill or not); without it, it carries a label
            // until the window is narrow enough for the planner to step it down to the icon.
            let bufferOn = bridge.bufferInfo.enabled
            let showBuffer = bufferOn && !plan.isFolded(PlayerToolbarItem.buffer)
            let showCatchUp = !plan.isFolded(PlayerToolbarItem.catchUp)
            if showBuffer && showCatchUp {
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
                if showBuffer {
                    bufferMonitor
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                }
                if showCatchUp {
                    catchUpButton(showLabel: !bufferOn && !plan.isCompact(PlayerToolbarItem.catchUp))
                }
            }

            // Raw/H.264 toggle for a remote FEED session — see currentFeedEntry's own doc comment.
            // Hidden when the source is already a modern codec, same as MenuContent's own "Recording
            // on Another Mac" menu only offering a second Watch (H.264) item under that condition —
            // a source that's already H.264/HEVC would just get relayed as-is regardless, making the
            // toggle a no-op.
            if showsH264Toggle, !plan.isFolded(PlayerToolbarItem.h264) {
                Divider().frame(height: 18)
                Toggle(isOn: feedTranscodeBinding) {
                    Text("H.264")
                }
                .toggleStyle(.checkbox)
                .help(feedIsTranscoding ? "Switch to the raw source stream" : "Switch to H.264 (transcoded by the source Mac)")
                .accessibilityLabel("H.264 transcode")
                .accessibilityValue(feedIsTranscoding ? "On" : "Off")
                .accessibilityIdentifier("vlc-feed-transcode-toggle")
            }

            // Info (ⓘ): toggles the status bar under the video; hovering it opens the Stream popover (health, source,
            // video file vs displayed resolution, throughput, connection). The "i" key toggles the bar too
            // (VLCPlayerWindowManager.installKeyMonitor). The icon's hue is nativeIconSourceColor — blue = live
            // network, purple = disk, indigo = FEED — so it doubles as an at-a-glance "where is this coming from".
            // Resizing to the picture's native size is the window's own Zoom (Option-click the green button, or
            // Window ▸ Zoom): VLCPlayerWindowManager.standardFrame.
            if !plan.isFolded(PlayerToolbarItem.info) {
                Button {
                    userToggleStatusBar()
                } label: {
                    Image(systemName: barWanted ? "info.circle.fill" : "info.circle")
                        .foregroundStyle(nativeIconSourceColor.opacity(barWanted ? 1.0 : 0.75))
                        .scaleEffect(infoGlow ? 1.35 : 1)
                        .shadow(color: nativeIconSourceColor.opacity(infoGlow ? 0.9 : 0), radius: infoGlow ? 7 : 0)
                }
                .buttonStyle(.plain)
                .help(barWanted ? "Hide status bar" : "Show status bar")
                .accessibilityLabel(barWanted ? "Hide status bar" : "Show status bar")
                .accessibilityIdentifier("vlc-status-bar-toggle")
                .onHover { inside in
                    popoverAnchorHovered = inside
                    if inside { recordingSizeSnapshot = recordingSizeText; streamInfoHovered = true }
                    else { closeStreamPopoverSoon() }
                }
                .task(id: streamInfoHovered) { await measureLink() }
                .popover(isPresented: $streamInfoHovered, arrowEdge: .bottom) {
                    streamPopover.onHover { inside in
                        popoverBodyHovered = inside
                        if !inside { closeStreamPopoverSoon() }
                    }
                }
            }

            // Group dividers, added 2026-09-19 (reported "crowded") — purely visual breathing room
            // between logical clusters (stream state: buffer/catch-up/H.264/native — clock — volume
            // — the existing pre-overflow divider below), no functional change to any control.
            // Live wall-clock time. The recording scrub bar lives in a hover overlay on the video
            // instead (see body's ZStack) rather than here — it needs more room than this toolbar
            // has to spare alongside everything else. Fixed width so the row's width never moves
            // with the digits; the first control to fold into "…".
            if !plan.isFolded(PlayerToolbarItem.clock) {
                Divider().frame(height: 18)
                TimelineView(.periodic(from: .now, by: 1.0)) { ctx in
                    Text(ctx.date, style: .time)
                        .monospacedDigit()
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                        .frame(width: PlayerToolbarItem.clockTextWidth)
                }
            }

            // Volume: the slider shrinks, then folds into a "Volume" submenu of "…".
            if !plan.isFolded(PlayerToolbarItem.volume) {
                Divider().frame(height: 18)
                Image(systemName: "speaker.wave.2")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Slider(value: $volume, in: 0...100)
                    .frame(width: plan.isCompact(PlayerToolbarItem.volume) ? PlayerToolbarItem.volumeSliderCompact : PlayerToolbarItem.volumeSliderFull)
                    .accessibilityLabel("Volume")
                    .accessibilityIdentifier("vlc-volume-slider")
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
            if hasAudioTrackChoice || hasCaptionChoice || hasOutputChoice || hasDisplayChoice || hasCastEntry || !plan.foldedIDs.isEmpty {
                Divider().frame(height: 18)
                Menu {
                    // Controls the toolbar had no room for, most recently folded first.
                    foldedMenuItems(plan: plan, rec: rec)
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
                            Button {
                                VLCBridge.shared.followSystemDefaultAudioDevice()
                                refreshAudioDevices()
                            } label: {
                                if audioFollowsDefault { Label("System Default", systemImage: "checkmark") }
                                else { Text("System Default") }
                            }
                            Divider()
                            ForEach(systemDevices, id: \.id) { dev in
                                // AirPlay speakers get a name suffix, not a second icon — a Menu
                                // row only renders one Label/systemImage slot (checkmark or
                                // plain), so a second badge glyph has nowhere to go.
                                let label = dev.isAirPlay ? "\(dev.name) (AirPlay)" : dev.name
                                Button {
                                    selectedDevice = dev.id
                                    audioFollowsDefault = false
                                    VLCBridge.shared.setAudioDevice(output: "auhal", deviceId: dev.id)
                                } label: {
                                    if dev.id == selectedDevice && !audioFollowsDefault { Label(label, systemImage: "checkmark") }
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
                    Divider()
                    Button { bridge.keyboardHelpVisible = true } label: {
                        Label("Keyboard Shortcuts (?)", systemImage: "keyboard")
                    }
                    .accessibilityIdentifier("vlc-keyboard-shortcuts")
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                // Chevron hidden + intrinsic sizing (2026-10-01, reported "crowded"): the old
                // .frame(maxWidth: 24) squeezed the icon *and* .borderlessButton's own dropdown
                // chevron into 24pt, jammed right up against the volume slider. The ellipsis icon
                // already reads as "more", so the chevron was redundant.
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More options — audio, captions, output, display, cast, and any controls that do not fit")
                .accessibilityLabel("More options")
                .accessibilityIdentifier("vlc-more-options-menu")
            }
        }
        .padding(.horizontal, ToolbarOverflowPlanner.horizontalPadding / 2)
        .onChange(of: volume) { _, v in VLCBridge.shared.setVolume(Int(v)) }   // here, not on the slider: the slider may be folded
    }

    /// "5 seconds to live" with a fast-forward chevron, shown on the picture for a moment when Live Edge is clicked.
    private func flashLiveJump(behind: Double?) {
        guard let behind, behind - AppState.recordingJumpToLiveSeconds >= 2 else { return }
        let s = Int((behind - AppState.recordingJumpToLiveSeconds).rounded())
        let text = s < 60 ? "\(s) seconds to live" : String(format: "%dm %02ds to live", s / 60, s % 60)
        liveJumpTextShown = false
        withAnimation(.easeOut(duration: 0.2)) { liveJumpText = text }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))   // chevron first, then the words
            guard liveJumpText == text else { return }
            withAnimation(.easeOut(duration: 0.25)) { liveJumpTextShown = true }
            try? await Task.sleep(for: .seconds(1.6))
            if liveJumpText == text { withAnimation(.easeIn(duration: 0.3)) { liveJumpText = nil; liveJumpTextShown = false } }
        }
    }

    /// The hover popover covers the picture, so it goes away shortly after the pointer leaves both ⓘ and the popover.
    private func closeStreamPopoverSoon() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            if !popoverAnchorHovered && !popoverBodyHovered { streamInfoHovered = false; popoverBodyHovered = false }
        }
    }

    /// Approximate distance behind the recording's live edge, for a recording (or FEED cache) played from disk.
    private func behindLiveSeconds(at date: Date) -> Double? {
        guard bridge.recordingShowId != nil, let start = bridge.recordingStartDate else { return nil }
        return max(0, date.timeIntervalSince(start) - bridge.recordingPlaybackSeconds)
    }

    /// "12s behind" / "2m 05s behind"; nil within a few seconds of live.
    private static func behindText(_ seconds: Double) -> String? {
        guard seconds >= 5 else { return nil }
        let s = Int(seconds.rounded())
        return s < 60 ? "\(s)s behind" : String(format: "%dm %02ds behind", s / 60, s % 60)
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
    /// The catch-up action, shared by the toolbar button and its folded "…" menu item.
    private func performCatchUp() {
        if let showId = bridge.recordingShowId {
            flashLiveJump(behind: behindLiveSeconds(at: Date()))
            state.seekRecordingToLiveEdge(showId: showId)
        } else {
            VLCBridge.shared.catchUpToLive()
        }
    }

    private var feedTranscodeBinding: Binding<Bool> {
        Binding(get: { feedIsTranscoding }, set: { toggleFeedTranscode(to: $0) })
    }

    /// Items the toolbar folded into the top of the "…" menu, most recently folded first, each with the accessibility
    /// identifier of the bar control it stands in for. Order and rules: docs/VLCPlayerView.md, "Responsive toolbar".
    @ViewBuilder
    private func foldedMenuItems(plan: ToolbarOverflowPlanner.Plan, rec: (channel: LineupEntry, entry: GuideEntry)?) -> some View {
        ForEach(plan.foldedIDs, id: \.self) { id in
            switch id {
            case PlayerToolbarItem.clock:
                Button {} label: {
                    Text("Time: \(Date.now.formatted(date: .omitted, time: .shortened))")
                }
                .disabled(true)
                .accessibilityIdentifier("vlc-clock")
            case PlayerToolbarItem.buffer:
                Button {} label: {
                    Text("Live buffer: \(min(8, Int(bridge.bufferInfo.lagSec.rounded()))) of 8 s")
                }
                .disabled(true)
                .accessibilityIdentifier("vlc-buffer-monitor")
            case PlayerToolbarItem.h264:
                Toggle(isOn: feedTranscodeBinding) { Text("H.264") }
                    .accessibilityIdentifier("vlc-feed-transcode-toggle")
            case PlayerToolbarItem.record:
                if let rec {
                    quickRecordMenu(state: state, entry: rec.entry, device: device, channel: rec.channel,
                                    tunerFullAlert: $showTunerFullAlert, yieldWatchNowConfirm: $yieldWatchNowConfirm) {
                        Label("Record", systemImage: "record.circle")
                    }
                    .accessibilityIdentifier("vlc-quick-record")
                }
            case PlayerToolbarItem.catchUp:
                Button { performCatchUp() } label: {
                    if bridge.recordingShowId != nil {
                        let behind = behindLiveSeconds(at: Date()).flatMap(Self.behindText)
                        Label(behind.map { "Live Edge · \($0)" } ?? "Live Edge", systemImage: "forward.end.circle")
                    } else {
                        Label("Catch Up", systemImage: "forward.end.circle")
                    }
                }
                .accessibilityIdentifier("vlc-catch-up-button")
            case PlayerToolbarItem.volume:
                Menu {
                    Button { volume = 0 } label: {
                        if Int(volume) == 0 { Label("Mute", systemImage: "checkmark") } else { Text("Mute") }
                    }
                    ForEach([25, 50, 75, 100], id: \.self) { preset in
                        Button { volume = Double(preset) } label: {
                            if Int(volume.rounded()) == preset { Label("\(preset)%", systemImage: "checkmark") } else { Text("\(preset)%") }
                        }
                    }
                } label: { Label("Volume", systemImage: "speaker.wave.2") }
                .accessibilityIdentifier("vlc-volume-slider")
            case PlayerToolbarItem.info:
                Button { userToggleStatusBar() } label: {
                    Label(barWanted ? "Hide Status Bar" : "Show Status Bar", systemImage: barWanted ? "info.circle.fill" : "info.circle")
                }
                .accessibilityIdentifier("vlc-status-bar-toggle")
            default:
                EmptyView()
            }
        }
        if !plan.foldedIDs.isEmpty { Divider() }
    }

    private func catchUpButton(showLabel: Bool) -> some View {
        // For a recording-relay session, VLCBridge.catchUpToLive() alone just replays the current
        // URL verbatim — reconnecting at the same stale &start= byte offset, doing nothing toward
        // "live". AppState.seekRecordingToLiveEdge computes a fresh near-live-edge offset instead.
        Button {
            performCatchUp()
        } label: {
            Group {
                if showLabel {
                    // Fixed widths + one line: the toolbar planner budgets these constants (PlayerToolbarItem).
                    if bridge.recordingShowId != nil {
                        TimelineView(.periodic(from: .now, by: 1.0)) { ctx in
                            let behind = behindLiveSeconds(at: ctx.date).flatMap(Self.behindText)
                            Label(behind.map { "Live Edge · \($0)" } ?? "Live Edge", systemImage: "forward.end.circle")
                                .monospacedDigit()
                                .lineLimit(1)
                                .frame(width: PlayerToolbarItem.catchUpRecordingLabelWidth, alignment: .leading)
                        }
                    } else {
                        Label("Catch Up", systemImage: "forward.end.circle")
                            .lineLimit(1)
                            .frame(width: PlayerToolbarItem.catchUpLabelWidth, alignment: .leading)
                    }
                } else {
                    Image(systemName: "forward.end.circle")
                }
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(bridge.recordingShowId != nil
              ? (behindLiveSeconds(at: Date()).map { Self.behindText($0) ?? "At the live edge" } ?? "Jump to the live edge of the recording")
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
    }

    /// Small grey group title inside the Stream popover.
    private func groupHeader(_ title: String) -> some View {
        Text(title.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
    }

    /// HEALTH: the dot and word, and the tuner/source with its signal quality — moved here from the status bar.
    @ViewBuilder
    private var healthSection: some View {
        let source = statusBarSource
        let quality: Int? = { if case .liveTuner(_, let q) = source { return q } else { return nil } }()
        let health = PlayerStatusFormat.health(throughput: bridge.throughput.state, signalQuality: quality)
        groupHeader("Health")
        HStack {
            Circle().fill(PlayerStatusFormat.color(health)).frame(width: 9, height: 9)
            Text(health.label).bold()
            Spacer()
            Text(PlayerStatusFormat.sourceText(source)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("vlc-stream-health")
    }

    /// SOURCE: where the data comes from (live network / disk / FEED) and, for a recording, its size on disk.
    @ViewBuilder
    private var sourceSection: some View {
        Divider()
        groupHeader("Source")
        // Shown regardless of whether a frame has decoded yet — recordingShowId is known independent of video size.
        // FEED reads over the network like a live tuner, but what arrives is the source Mac's recording off *its* disk.
        HStack {
            Circle().fill(nativeIconSourceColor).frame(width: 8, height: 8)
            if device.isVirtualRelay {
                Text("Network → Disk (FEED" + (currentFeedEntry?.virtualRelaySourceHostname.map { " from \($0)" } ?? "") + ")")
            } else {
                Text(bridge.recordingShowId != nil ? "Local recording (disk)" : "Live network stream")
            }
        }
        // A one-shot snapshot taken when the popover opens (the ⓘ button's .onHover), not a ticking value.
        if bridge.recordingShowId != nil, let recordingSizeSnapshot { row("On disk", recordingSizeSnapshot) }
        if bridge.recordingShowId != nil {
            TimelineView(.periodic(from: .now, by: 1.0)) { ctx in
                let behind = behindLiveSeconds(at: ctx.date)
                row("Behind live", behind.map { Self.behindText($0) ?? "at live edge" } ?? "—")
            }
        }
    }

    /// VIDEO: the file's own resolution, what is on screen now (with how much smaller/larger), codecs and display scale.
    @ViewBuilder
    private var videoSection: some View {
        Divider()
        groupHeader("Video")
        if let px = bridge.videoPixelSize {
            let manager = VLCPlayerWindowManager.shared
            let scale = manager.currentScreenScale
            let (vid, aud) = inferredCodecs
            row("Video file", "\(Int(px.width))×\(Int(px.height)) px")
            if let shown = manager.displayedVideoPixelSize() {
                let note = PlayerStatusFormat.scaleNote(displayed: shown, native: px)
                row("Displayed", "\(Int(shown.width.rounded()))×\(Int(shown.height.rounded())) px" + (note.map { " (\($0))" } ?? ""))
            }
            row("Codec", vid + " · " + aud)
            row("Display scale", String(format: "%.0f×", scale))
            if !manager.nativeVideoFitsCurrentScreen() {
                Label("Larger than the display — Native shows a clean half", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
        } else {
            Text("No video decoded yet").foregroundStyle(.secondary)
        }
    }

    private var streamPopover: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Stream").font(.subheadline.bold())
            healthSection
            sourceSection
            videoSection
            throughputSection
            connectionSection
        }
        .padding(12)
        .frame(minWidth: 260)
        .font(.caption)
    }

    /// Live bitrate in Mbps (VLC's raw × 8, see ThroughputTracker), colored by state, with the 2-minute average and a graph
    /// of the window. Replaces the old Live Buffer popover's bitrate row; shown for every session type VLC reports stats for.
    @ViewBuilder
    private var throughputSection: some View {
        let tp = bridge.throughput
        if let now = tp.currentMbps {
            Divider()
            groupHeader("Throughput")
            HStack {
                Text("Bitrate").foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f Mbps", now)).monospacedDigit().foregroundStyle(tp.state.color)
            }
            if let avg = tp.averageMbps { row("2-min avg", String(format: "%.1f Mbps", avg)) }
            HStack {
                Text("State").foregroundStyle(.secondary)
                Spacer()
                Text(tp.state.label).foregroundStyle(tp.state.color)
            }
            if tp.history.count > 2 {
                ThroughputGraph(samples: tp.history, average: tp.averageMbps)
                    .frame(height: 44)
                    .accessibilityHidden(true)
            }
        }
    }

    /// Ethernet or Wi-Fi, link rate, signal and round-trip time to the tuner (or FEED source). Not shown for a recording
    /// played from disk — nothing crosses the network then.
    @ViewBuilder
    private var connectionSection: some View {
        if bridge.recordingShowId == nil, let link = linkInfo {
            Divider()
            groupHeader("Connection")
            HStack {
                Text("Link").foregroundStyle(.secondary)
                Spacer()
                Text(link.linkText).foregroundStyle(link.kind == .wifi ? PlayerStatusFormat.color(link.quality ?? .measuring) : Color.primary)
            }
            if let rtt = link.rttMs {
                HStack {
                    Text(device.isVirtualRelay ? "Ping to source" : "Ping to tuner").foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.1f ms", rtt)).monospacedDigit()
                        .foregroundStyle(PlayerStatusFormat.color(link.quality ?? .measuring))
                }
            }
        }
    }

    /// Measured once each time the popover opens (a few short TCP connects), never on a timer.
    private func measureLink() async {
        guard streamInfoHovered, bridge.recordingShowId == nil else { return }
        let comps = URLComponents(string: device.BaseURL ?? "")
        let host = comps?.host ?? device.LocalIP
        let port = UInt16(comps?.port ?? 80)
        guard !host.isEmpty else { return }
        linkInfo = await NetworkLinkProbe.measure(host: host, port: port)
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
        // Any primary FEED (a FEED-bound window or a cross-device swap) selects its FEED row —
        // the picker lists FEEDs only as those synthetic rows now (2026-10-02).
        if VLCPlayerWindowManager.shared.currentFeedRemoteURL != nil, let entry = currentFeedRow {
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
        if LocalRelay.isWatchRecording(base), let showId = bridge.recordingShowId,
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
        if let match = lineup.entry(matchingStreamURL: base) {   // exact match — 5.1 ≠ 5.10 (see entry(matchingStreamURL:))
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

    /// The in-window channel picker's selection changed (body moved out of `.onChange` — the longer closure made the
    /// toolbar's view-builder expression too complex for the compiler to type-check).
    private func handleChannelPickChanged(from oldCh: LineupEntry?, to ch: LineupEntry?) {
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
            // auto-play), so the auto-start gate's `!posterHidden` guard silently failed for
            // every subsequent switch — the video genuinely changed (VLCBridge.play(url:)
            // loaded the new stream regardless) but audio stayed muted at the volume 0
            // VLCPlayerWindowManager.open sets before every play() call, forever. Falling
            // through to the same poster/mute reset the direct-picker path uses below lets
            // attemptAutoStart fire again for the new stream (play(url:) resets
            // hasVideoFrame, so its first frame re-triggers the gate) and restore volume —
            // playChannel/watchRecordingInApp itself must still stay skipped since the
            // caller (VLCPlayerWindowManager.open) already started this exact stream.
            posterHidden = false
            posterNSImage = nil
            VLCBridge.shared.setVolume(0)
            return
        }
        // Any user pick supersedes a pending tuner-wait switch — including picks that go through
        // watchInApp/watchRemoteRelay/watchRecordingInApp, which never touch switchGeneration.
        switchGeneration += 1
        switchTask?.cancel()
        // Picking a real channel while a FEED / recording relay / other-device stream is playing is a
        // brand-new tuner request: it must be pre-flighted (and the tuner allocated) BEFORE we touch the
        // stream the viewer is watching. Blanking behind the poster and muting here, up front, made the FEED
        // look paused for the whole pre-flight + connect (and left it blanked if the switch was then refused).
        // In that case the blanking moves to the instant the new stream actually starts
        // (blankForNewStream, called by playChannel / watchInApp's beforeOpen); on a refusal the picker
        // reverts and the FEED simply keeps playing. 2026-10-06.
        let keepStreamUntilReady = ch.map { shouldKeepCurrentStreamUntilNewOneStarts(for: $0) } ?? false
        if !keepStreamUntilReady { blankForNewStream() }
        guard let ch else { ownStreamStoppedForSwitch = false; return }
        if let feedURL = remoteURL(fromLiveFeedGuideNumber: ch.GuideNumber) {
            // Switch to a FEED row (allFeedEntries) — the same path MenuContent's
            // "Recording on Another Mac" Watch row takes. watchRemoteRelay dedups against
            // the FEED already playing, and rebinds the window to the FEED's own device.
            // A non-live pick supersedes a tuner-wait switch whose task just returned on the cancelled
            // check without clearing the flag — left true it would make the next live pick skip its
            // pre-flight and stop() a FEED that holds no tuner. (Live picks keep it: see playChannel.)
            ownStreamStoppedForSwitch = false
            guard let pair = state.remoteRelayEntries.first(where: { $0.entry.URL == feedURL }) else { return }
            state.watchRemoteRelay(url: feedURL, title: pair.entry.virtualRelayShowTitle ?? pair.entry.GuideName,
                                   device: pair.device)
        } else if let showId = showId(fromLiveGuideNumber: ch.GuideNumber) {
            ownStreamStoppedForSwitch = false
            guard let show = state.shows.first(where: { $0.show_id == showId }) else { return }
            state.watchRecordingInApp(show)
        } else if device.isVirtualRelay, let src = channelSourceDevice {
            // A real channel picked from a FEED-bound window — open it on the real tuner
            // (watchInApp's tuner check; open() rebinds this window to that device).
            // FEED rows themselves never get here: they're all "live-feed:" rows above,
            // routed through watchRemoteRelay/the disk cache (review #8).
            // (plain if-assignments, not `cond ? { … } : nil` — that ternary of optional closures defeats type inference)
            ownStreamStoppedForSwitch = false
            var beforeOpen: (@MainActor () -> Void)? = nil
            var onRefused: (@MainActor () -> Void)? = nil
            if keepStreamUntilReady {
                beforeOpen = { blankForNewStream() }
                onRefused = { revertPickerAfterRefusedSwitch(to: oldCh) }
            }
            state.watchInApp(url: ch.URL ?? "", title: ch.GuideName, deviceId: src.DeviceID, guideNumber: ch.GuideNumber,
                             beforeOpen: beforeOpen, onRefused: onRefused)
        } else {
            playChannel(ch, revertTo: keepStreamUntilReady ? oldCh : nil, resumeOnRefusal: oldCh)
        }
    }

    /// `resumeOnRefusal`: the channel that was playing before this pick — if the tuner-wait switch below has already
    /// stopped that stream and then finds every tuner held elsewhere, it is put back (see the timeout branch).
    private func playChannel(_ ch: LineupEntry, revertTo previous: LineupEntry? = nil, resumeOnRefusal: LineupEntry? = nil) {
        if VLCPlayerWindowManager.shared.secondaryIsShowing(deviceID: device.DeviceID, channelNumber: ch.GuideNumber) {
            glog("[VLC] playChannel \(ch.GuideNumber) — already in the PiP, swapping instead")
            ownStreamStoppedForSwitch = false
            swapPrimaryAndSecondary()
            return
        }
        guard let rawURL = ch.URL, !rawURL.isEmpty else {
            glog("[VLC] playChannel skipped — no URL for ch=\(ch.GuideNumber) \(ch.GuideName)", level: .warning)
            return
        }
        // This channel is being recorded on this device right now — play the recording's file
        // through the disk relay instead of opening a second, redundant live tuner connection for
        // the same channel (fixed 2026-10-01: picking the plain "11.1 KARE-HD" row, or reaching it
        // via channel up/down, used to do exactly that). Same as picking its "Live …" row.
        if let recording = state.recordingShows.first(where: {
            $0.hdhr_record == device.DeviceID && $0.show_channel == ch.GuideNumber
        }) {
            glog("[VLC] playChannel \(ch.GuideNumber) — currently recording '\(recording.show_title)', playing from disk instead of a second live tuner")
            ownStreamStoppedForSwitch = false
            state.watchRecordingInApp(recording)
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
        let reusingExistingTunerHere = ownStreamStoppedForSwitch || Self.reusesExistingTuner(
            currentDeviceID: VLCPlayerWindowManager.shared.currentDeviceID,
            targetDeviceID: device.DeviceID,
            recordingShowId: bridge.recordingShowId,
            currentFeedRemoteURL: VLCPlayerWindowManager.shared.currentFeedRemoteURL,
            currentURL: bridge.currentURL)

        if reusingExistingTunerHere {
            // Not unconditionally "reuses the slot": HDHomeRun frees the old stream's tuner only
            // once its HTTP connection actually closes, and libvlc can open the new /auto request
            // first. With every other tuner busy (e.g. a recording on a 2-tuner device) that new
            // request gets 805 "All Tuners In Use" and the player shows "Playback Ended" (found
            // live 2026-10-03). So when the device is at capacity, stop our own stream first and
            // wait for its tuner to actually free before opening the new channel.
            switchGeneration += 1
            let generation = switchGeneration
            switchTask?.cancel()
            switchTask = Task {
                let outcome = await waitForOwnTunerToFreeIfNeeded()
                // Superseded by a newer pick, or the window went away (cancelled) — the newer pick /
                // close owns cleanup, including the stopped-stream flag.
                guard !Task.isCancelled, generation == switchGeneration else { return }
                // Some other entry point (menu Watch, WatchNow, a FEED row) started a stream while we
                // waited — don't play over it.
                if outcome != .notNeeded, bridge.currentURL != nil {
                    ownStreamStoppedForSwitch = false
                    return
                }
                if outcome == .timedOut {
                    // Every tuner is held by someone else: say so (the standard "All Tuners Busy" alert)
                    // instead of opening a stream the device will refuse with 805 and a "Playback Ended".
                    ownStreamStoppedForSwitch = false
                    guard await state.tunerAvailable(device, context: ch.GuideName) else {
                        // We already stopped the stream that was playing, so a bare return left the player on
                        // "Connecting…" forever with the picker on a channel that never opened. Put the picker
                        // back and re-open what was playing: if its tuner is really free again that resumes it,
                        // otherwise the player shows the normal "Playback Ended" instead of a dead spinner.
                        guard generation == switchGeneration, bridge.currentURL == nil,
                              let prev = resumeOnRefusal, let prevRaw = prev.URL, !prevRaw.isEmpty else { return }
                        revertPickerAfterRefusedSwitch(to: prev)
                        posterHidden = false
                        VLCBridge.shared.setVolume(0)
                        startPlayChannel(prev, url: state.config.applyTranscode(prevRaw))
                        return
                    }
                    guard !Task.isCancelled, generation == switchGeneration else { return }
                }
                // Re-arm the auto-start gate + mute exactly as the picker handler did — but it ran
                // BEFORE this async hop, and in the gap the still-true readyToReveal of the OLD stream
                // let attemptAutoStart reveal it and restore the volume. Without this, the new
                // stream's first frame found posterHidden already true, the gate's `!posterHidden`
                // guard skipped it, and (combined with the handler's setVolume(0)) audio could stay
                // silent until the volume slider was touched (found live 2026-10-03: FEED primary +
                // OTA PiP, Tab-swap, then a channel switch). Set before play() so play()'s
                // synchronous readyToReveal reset lands before the onChange callback evaluates.
                posterHidden = false
                VLCBridge.shared.setVolume(0)
                ownStreamStoppedForSwitch = false
                startPlayChannel(ch, url: url)
            }
        } else {
            // Numbered like the live→live branch above: a second pick (or a channel-up/down burst) while this
            // pre-flight is still awaiting must supersede it — otherwise both tasks start a stream, in whatever
            // order their status fetches happen to finish, and the one that plays may not be the last one picked.
            let generation = switchGeneration
            switchTask?.cancel()
            switchTask = Task {
                // Allocate/verify the tuner FIRST. The stream being watched (a FEED, say) is untouched until this
                // passes; only then is it blanked and replaced — so a refusal costs nothing and the switch has no
                // artificial pause on top of the new stream's own connect time.
                guard await state.tunerAvailable(device, context: ch.GuideName) else {
                    // A newer pick owns the picker now — only undo our own optimistic label.
                    if generation == switchGeneration, let previous { revertPickerAfterRefusedSwitch(to: previous) }
                    return
                }
                guard !Task.isCancelled, generation == switchGeneration else { return }   // superseded while checking
                blankForNewStream()
                startPlayChannel(ch, url: url)
            }
        }
    }

    /// Hides the current picture behind the poster and mutes — done at the moment a NEW stream is about to
    /// replace it, so the auto-start gate re-arms for the new stream's first frame (see the picker handler).
    private func blankForNewStream() {
        posterHidden = false
        posterNSImage = nil
        VLCBridge.shared.setVolume(0)
    }

    /// After a refused channel switch (no tuner free, empty URL) the picker already shows the channel the user
    /// clicked while the old stream is still playing — put it back without triggering a play.
    private func revertPickerAfterRefusedSwitch(to previous: LineupEntry?) {
        guard let previous, selectedChannel?.GuideNumber != previous.GuideNumber else { return }
        suppressNextChannelPlay = true
        suppressSameContent = true     // relabel only — the old stream never stopped
        selectedChannel = previous
    }

    /// True for a live-channel pick that is a genuinely new tuner request while a stream that holds none on the
    /// target device (FEED, recording relay, or another device's channel) is playing — see the picker handler.
    private func shouldKeepCurrentStreamUntilNewOneStarts(for ch: LineupEntry) -> Bool {
        guard remoteURL(fromLiveFeedGuideNumber: ch.GuideNumber) == nil,
              showId(fromLiveGuideNumber: ch.GuideNumber) == nil,
              let target = channelSourceDevice?.DeviceID else { return false }
        let mgr = VLCPlayerWindowManager.shared
        return Self.shouldKeepStreamUntilNewOneStarts(
            currentlyPlaying: !(bridge.currentURL ?? "").isEmpty,
            reusesExistingTuner: ownStreamStoppedForSwitch || Self.reusesExistingTuner(
                currentDeviceID: mgr.currentDeviceID, targetDeviceID: target, recordingShowId: bridge.recordingShowId,
                currentFeedRemoteURL: mgr.currentFeedRemoteURL, currentURL: bridge.currentURL),
            channelIsBeingRecorded: state.recordingShows.contains { $0.hdhr_record == target && $0.show_channel == ch.GuideNumber },
            alreadyInPiP: mgr.secondaryIsShowing(deviceID: target, channelNumber: ch.GuideNumber))
    }

    /// Pure decision, extracted for unit testing: keep the current stream playing (don't blank/mute) until the new one
    /// actually starts. Only for a fresh tuner request over a stream that holds none on the target device; every
    /// other pick (live→live on the same tuner, a recording being watched from disk, a channel already in the PiP)
    /// keeps the existing immediate blank.
    nonisolated static func shouldKeepStreamUntilNewOneStarts(currentlyPlaying: Bool, reusesExistingTuner: Bool,
                                                              channelIsBeingRecorded: Bool, alreadyInPiP: Bool) -> Bool {
        currentlyPlaying && !reusesExistingTuner && !channelIsBeingRecorded && !alreadyInPiP
    }

    /// True when the device has no free tuner, so a live→live switch has to release our own first.
    /// Pure decision, extracted for unit testing.
    nonisolated static func mustFreeTunerBeforeSwitch(activeTuners: Int, tunerCount: Int) -> Bool {
        tunerCount > 0 && activeTuners >= tunerCount
    }

    private static let tunerFreeWaitTimeout: TimeInterval = 6.0
    private static let tunerFreePollInterval: TimeInterval = 0.25
    // Extra beat after status.json first reports a free tuner — the device can still be tearing down
    // the old stream's session for a moment after it stops listing it (user suggestion 2026-10-03).
    private static let tunerFreeSettleDelay: TimeInterval = 1.0

    private func activeTunerCount() async -> Int? {
        guard let url = URL(string: device.statusURL),
              let data = await LANFetch.data(from: url, label: "status.json (tuner wait)"),
              let tuners = try? JSONDecoder().decode([DeviceTunerInfo].self, from: data) else { return nil }
        return tuners.filter { $0.isInUse }.count
    }

    enum TunerWaitOutcome { case notNeeded, freed, timedOut }

    /// If the device is at capacity, stops our primary stream (closing its HTTP connection) and
    /// polls status.json until a tuner is actually free, up to `tunerFreeWaitTimeout`. `.timedOut`
    /// means every tuner is held by someone else (the caller shows the "All Tuners Busy" alert). A
    /// failed status fetch skips the wait (`.notNeeded`). Sets `ownStreamStoppedForSwitch` once it
    /// has stopped the stream; the caller clears it.
    private func waitForOwnTunerToFreeIfNeeded() async -> TunerWaitOutcome {
        let tunerCount = device.TunerCount ?? 2
        guard let before = await activeTunerCount(),
              Self.mustFreeTunerBeforeSwitch(activeTuners: before, tunerCount: tunerCount) else { return .notNeeded }
        glog("[VLC] channel switch: \(before)/\(tunerCount) tuners busy — stopping our stream and waiting for a tuner to free")
        VLCBridge.shared.stop()
        ownStreamStoppedForSwitch = true
        let started = Date()
        while Date().timeIntervalSince(started) < Self.tunerFreeWaitTimeout {
            try? await Task.sleep(nanoseconds: UInt64(Self.tunerFreePollInterval * 1_000_000_000))
            if Task.isCancelled { return .timedOut }
            if let now = await activeTunerCount(), now < tunerCount {
                glog("[VLC] channel switch: status.json shows a free tuner after \(String(format: "%.1f", Date().timeIntervalSince(started)))s (\(now)/\(tunerCount) active) — settling \(Self.tunerFreeSettleDelay)s")
                try? await Task.sleep(nanoseconds: UInt64(Self.tunerFreeSettleDelay * 1_000_000_000))
                glog("[VLC] channel switch: ready — opening new channel")
                return .freed
            }
        }
        glog("[VLC] channel switch: no tuner freed within \(Int(Self.tunerFreeWaitTimeout))s — every tuner is held elsewhere", level: .warning)
        return .timedOut
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
        // Before play(): ensures a player exists and the manager's device/channel/FEED tracking
        // describe this stream — see prepareInWindowLiveSwitch.
        VLCPlayerWindowManager.shared.prepareInWindowLiveSwitch(device: device, channelNumber: ch.GuideNumber, url: url)
        VLCBridge.shared.play(url: url)
        updateNowPlaying(channel: ch)
        state.refreshTunerOccupancy()

        // Check tuner occupancy in the background — stream is already started, this
        // is for logging and a non-blocking warning if we appear to be over capacity.
        Task {
            guard let statusURL = URL(string: device.statusURL),
                  let data = await LANFetch.data(from: statusURL, label: "status.json (post-switch)"),
                  let tuners = try? JSONDecoder().decode([DeviceTunerInfo].self, from: data) else { return }
            let tunerCount  = device.TunerCount ?? 2
            let active      = tuners.filter { $0.isInUse }.count
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
        // Follows the system default until the user picks a device; a pinned device that disappears falls back
        // to following (VLCBridge.resolveAudioTarget). Runs on open, on device-list changes and on default changes.
        if let uid = VLCBridge.shared.syncAudioDevice(available: systemDevices.map(\.id)) { selectedDevice = uid }
        audioFollowsDefault = VLCBridge.shared.audioFollowsSystemDefault
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
    // Token of the VLCPlayerView currently hosted in `window` — see VLCPlayerView.hostToken.
    private(set) var hostedViewToken = UUID()

    private func makeHostedPlayerView(device: HDHRDevice, initialURL: String, appState: AppState) -> AnyView {
        let token = UUID()
        hostedViewToken = token
        return AnyView(
            VLCPlayerView(device: device, initialURL: initialURL, hostToken: token)
                .environmentObject(appState)
                .id(device.DeviceID)
        )
    }

    /// The player window itself, for callers (the menu-bar icon's double-click) that need to tell it apart
    /// from the app's other windows.
    var playerWindow: NSWindow? { window }

    /// Brings the player window to the front and makes it key, restoring it first if minimized. False when
    /// there is no open player window.
    @discardableResult
    func bringToFront() -> Bool {
        guard let w = window, w.isVisible || w.isMiniaturized else { return false }
        if w.isMiniaturized { w.deminiaturize(nil) }
        w.makeKeyAndOrderFront(nil)
        return true
    }

    /// DeviceID of the tuner currently occupied by the player window; nil when closed.
    private(set) var currentDeviceID: String?
    /// GuideNumber of the channel `open()` was last called with; nil when closed or when the
    /// caller didn't pass one (e.g. the watch-recording relay, which occupies no tuner at all —
    /// see AppState.vlcOccupiesTuner). Lets AppState.vlcLiveChannel(for:) tell "this app is live-
    /// watching this exact channel" apart from "some other tuner on this device is in use", so the
    /// in-use-by-other-tuner marker doesn't flag your own live Watch session as someone else's.
    private(set) var currentChannelNumber: String?

    /// VLCPlayerView.startPlayChannel's in-window live channel switch — the bookkeeping open()
    /// does, minus the window/view setup (2026-10-01 review finding #7). Before this, only
    /// open() set currentDeviceID/currentChannelNumber, so after a cross-device PiP swap a picker
    /// switch back to this window's own device left currentDeviceID naming the *other* device
    /// (vlcOccupiesTuner miscounted both, and scheduled-recording preemption could stop the wrong
    /// stream); a stale FEED session kept its puller running; and a standalone-PiP window whose
    /// primary player had been released never recreated it, so play() sat queued forever.
    func prepareInWindowLiveSwitch(device: HDHRDevice, channelNumber: String, url: String) {
        if let staleId = currentFeedSessionId, !url.contains(staleId) {
            appState?.stopFeedCacheSession(sessionId: staleId)
            appState?.webServer.unregisterFeedRelaySession(id: staleId)
            currentFeedRemoteURL = nil
            currentFeedSessionId = nil
        }
        currentDeviceID = device.DeviceID
        currentChannelNumber = channelNumber
        VLCBridge.shared.ensurePlayer()
    }

    /// Non-blocking notice as a sheet on the player window (AppState's scheduled-recording
    /// preemption heads-up/stop notices) — a sheet, not runModal(), so it never blocks the idle
    /// loop that raises it. No-op without a window, or while another sheet is already showing.
    func presentNotice(title: String, message: String) {
        guard let win = window, win.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: win)
    }
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
    private var rightClickMonitor: Any?
    /// Quadrant of the player window's content that was last right-clicked (nil until one is) — read
    /// by the video pane's "Add Picture-in-Picture…" action to place the PiP where the user clicked.
    private(set) var lastRightClickCorner: PipCorner?
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

    /// Undoes setFeedRelayTracking for a session that started on a window that has since closed.
    /// No-op unless `sessionId` is still the tracked one.
    func clearFeedRelayTracking(ifSessionId sessionId: String) {
        guard currentFeedSessionId == sessionId else { return }
        currentFeedRemoteURL = nil
        currentFeedSessionId = nil
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
        // Opening anything other than the current primary FEED session's own relay URL (a live
        // channel or Watch Now from the menu) replaces it — tear it down now rather than at window
        // close, or a FEED-cache puller keeps writing the remote stream to disk for as long as this
        // window stays open on something else. (watchRemoteRelay sets tracking to the new session
        // before calling open(), so its own URL always contains the current id.)
        if let staleId = currentFeedSessionId, !url.contains(staleId) {
            appState.stopFeedCacheSession(sessionId: staleId)
            appState.webServer.unregisterFeedRelaySession(id: staleId)
            currentFeedRemoteURL = nil
            currentFeedSessionId = nil
        }
        currentDeviceID = device.DeviceID
        currentChannelNumber = channelNumber
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
                hostingView?.rootView = makeHostedPlayerView(device: device, initialURL: url, appState: appState)
            }
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        glog("[VLC] WindowManager.open — creating new window, device=\(device.DeviceID) url=\(url)")

        let playerView = makeHostedPlayerView(device: device, initialURL: url, appState: appState)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = title
        let hosting = NSHostingView(rootView: playerView)
        configureResizing(win, hosting: hosting)
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
        frameStatusBarHeight = 0   // a new window is the default 1080×600, without the bar's row
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
        // A previous window close released the primary player (releasePlayer); recreate it like
        // open() does, or a later picker channel/Tab swap in this window has no primary to use
        // (2026-10-01 review #12).
        VLCBridge.shared.ensurePlayer()

        let playerView = makeHostedPlayerView(device: placeholderDevice, initialURL: "", appState: appState)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "hdhrVCRplus"
        let hosting = NSHostingView(rootView: playerView)
        configureResizing(win, hosting: hosting)
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
        frameStatusBarHeight = 0   // a new window is the default 1080×600, without the bar's row
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
        // Same stale-FEED teardown as open() above, for the secondary slot — replacing a FEED
        // secondary (possibly a FEED-cache session moved here by a PiP swap) with a live channel
        // or recording would otherwise leave its relay/puller running until window close.
        if let staleId = secondaryFeedSessionId, !url.contains(staleId) {
            appState?.stopFeedCacheSession(sessionId: staleId)
            appState?.webServer.unregisterFeedRelaySession(id: staleId)
            secondaryFeedRemoteURL = nil
            secondaryFeedSessionId = nil
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
        // Tries both teardown paths — see playerWindowDidClose's identical pattern/doc comment for
        // why (a tap-to-swap can move a primary FEED-cache session's id into this slot).
        if let sessionId = secondaryFeedSessionId {
            appState?.stopFeedCacheSession(sessionId: sessionId)
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
    /// Whether the PiP corner is already playing exactly what a "watch X" request asks for — used
    /// by AppState's watch entry points and the in-player picker to promote the PiP (the Tab swap)
    /// instead of opening a duplicate primary of the same show (live-found 2026-10-03: picking the
    /// FEED already in the PiP from the menu opened a second cache session of it as primary).
    func secondaryIsShowing(feedRemoteURL: String? = nil, deviceID: String? = nil, channelNumber: String? = nil,
                            recordingShowId: String? = nil) -> Bool {
        guard secondaryDeviceID != nil else { return false }
        if let feedRemoteURL { return secondaryFeedRemoteURL == feedRemoteURL }
        if let recordingShowId {
            return VLCBridge.shared.secondaryURL?.contains("\(LocalRelay.watchRecordingPath)?show=\(recordingShowId)") ?? false
        }
        if let deviceID, let channelNumber {
            return secondaryFeedRemoteURL == nil && secondaryDeviceID == deviceID && secondaryChannelNumber == channelNumber
        }
        return false
    }

    /// Promotes the PiP to primary — the same swap Tab performs (VLCPlayerView.swapPrimaryAndSecondary).
    func promoteSecondaryToPrimary(reason: String) {
        glog("[VLC] promoting PiP to primary instead of opening a duplicate — \(reason)")
        NotificationCenter.default.post(name: .vlcSwapPiP, object: nil)
        focus()
    }

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

    // Arrow-key seek (recording playback only) + Space to pause/resume (same scope) + Esc to exit
    // fullscreen + "i" for the info banner.
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
        // Separate from keyMonitor below: that closure reads event.keyCode, which raises on a
        // non-key NSEvent.
        if let rightClickMonitor { NSEvent.removeMonitor(rightClickMonitor) }
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self, weak win] event in
            if let self, let win, event.window === win, let size = win.contentView?.bounds.size,
               size.width > 0, size.height > 0 {
                let p = event.locationInWindow   // origin bottom-left
                let isTop = p.y > size.height / 2
                let isLeading = p.x < size.width / 2
                self.lastRightClickCorner = isTop ? (isLeading ? .topLeading : .topTrailing)
                                                  : (isLeading ? .bottomLeading : .bottomTrailing)
            }
            return event
        }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self, weak win] event in
            guard let self, let win, event.window === win else { return event }
            // "?" help card: while it is showing, ANY key press closes it and is consumed (so Esc doesn't also
            // leave full screen and an arrow doesn't also seek). Shift is a modifier-only flagsChanged, not a
            // keyDown, so pressing it to type "?" doesn't close the card it just opened.
            if event.type == .keyDown, VLCBridge.shared.keyboardHelpVisible {
                VLCBridge.shared.keyboardHelpVisible = false
                return nil
            }
            // "?" (Shift-/ on a US layout) opens it — matched on the typed character, not the key code, so it
            // follows other layouts, and not with Command/Option/Control held.
            if event.type == .keyDown, event.characters == "?",
               event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                VLCBridge.shared.keyboardHelpVisible = true
                return nil
            }
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
            case (.keyDown, 49):   // space — pause/resume, added 2026-10-01. Disk-backed streams
                                    // only (VLCBridge.canPause: Watch Now or a FEED cache session,
                                    // the same scope as arrow-key seek above); a live channel
                                    // passes the key through untouched. Bare Space only.
                guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                      VLCBridge.shared.isPaused || VLCBridge.shared.canPause else { return event }
                VLCBridge.shared.togglePause()
                return nil
            case (.keyDown, 53):   // escape — only consumed while actually in fullscreen, so a
                                    // plain Esc elsewhere (e.g. dismissing a popover) still works.
                guard win.styleMask.contains(.fullScreen) else { return event }
                win.toggleFullScreen(nil)
                return nil
            case (.keyDown, 48):   // tab — swaps primary/secondary PiP, added 2026-09-29. Only
                                    // consumed while a secondary is actually open (self
                                    // .secondaryDeviceID != nil); otherwise Tab passes through
                                    // untouched so normal focus-cycling among toolbar controls
                                    // keeps working the rest of the time, when there's nothing to
                                    // swap anyway. Bare Tab only — Shift-Tab (reverse focus-cycle)
                                    // and any other modifier combo pass through unconsumed too.
                guard self.secondaryDeviceID != nil,
                      event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
                NotificationCenter.default.post(name: .vlcSwapPiP, object: nil)
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

    /// The video area's size in physical pixels as it is on screen right now (window content minus the toolbar and
    /// status bar, times the backing scale); nil without a window.
    func displayedVideoPixelSize() -> CGSize? {
        guard let win = window, let content = win.contentView?.frame.size else { return nil }
        let scale = win.screen?.backingScaleFactor ?? currentScreenScale
        return CGSize(width: content.width * scale, height: max(0, content.height - chromeHeight) * scale)
    }

    /// True when the stream's native resolution fits within the current display's visible frame
    /// (accounting for the 44pt toolbar added by sizeToNativeVideo).
    func nativeVideoFitsCurrentScreen() -> Bool {
        guard let px = VLCBridge.shared.videoPixelSize,
              let screen = window?.screen ?? NSScreen.main else { return true }
        let scale = screen.backingScaleFactor
        return px.width  / scale <= screen.visibleFrame.width &&
               px.height / scale + chromeHeight <= screen.visibleFrame.height
    }

    /// The content size Zoom (Window ▸ Zoom) aims for: 1:1 physical pixels when that fits `visible`, else the largest clean
    /// 1/2, 1/4, … of it that does. Pure.
    nonisolated static func nativeTarget(pixels: CGSize, scale: CGFloat, chrome: CGFloat,
                                         visible: CGSize) -> (content: CGSize, divisor: Int) {
        var divisor = 1
        while divisor < 8 &&
              (pixels.width / scale / CGFloat(divisor) > visible.width ||
               pixels.height / scale / CGFloat(divisor) + chrome > visible.height) {
            divisor *= 2
        }
        return (CGSize(width: pixels.width / scale / CGFloat(divisor),
                       height: pixels.height / scale / CGFloat(divisor) + chrome), divisor)
    }

    private func currentNativeTarget(_ win: NSWindow) -> CGSize? {
        guard let pixels = VLCBridge.shared.videoNativeSize() else { return nil }
        let screen = win.screen ?? NSScreen.main
        return Self.nativeTarget(pixels: pixels, scale: screen?.backingScaleFactor ?? 2.0, chrome: chromeHeight,
                                 visible: screen?.visibleFrame.size ?? CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)).content
    }

    /// NSWindowDelegate.windowWillUseStandardFrame — what the window's **Zoom** (Option-click the green button, Window ▸
    /// Zoom, or a title-bar double-click) resizes to: the picture at its native pixels, or a clean half/quarter when
    /// the display is too small (`nativeTarget`). AppKit remembers the size from before and zooms back to it on the next
    /// Zoom, so this toggles between the two sizes with no state of ours. Without a decoded frame, the system default.
    func standardFrame(for win: NSWindow, defaultFrame: NSRect) -> NSRect {
        guard win === window, let content = currentNativeTarget(win) else { return defaultFrame }
        var frame = win.frameRect(forContentRect: NSRect(origin: .zero, size: content))
        frame.origin = NSPoint(x: win.frame.minX, y: win.frame.maxY - frame.height)   // keep the top edge fixed
        return Self.frame(frame, keptWithin: defaultFrame)
    }

    // MARK: Aspect lock (2026-10-03, explicit request: window resizing keeps the stream's native shape)

    /// Height of the toolbar strip above the video — the same fixed 44pt sizeToNativeVideo and
    /// the other sizing math assume.
    nonisolated static let playerToolbarHeight: CGFloat = 44
    /// Height of the optional status bar under the video (docs/VLCPlayerView.md, "Status bar").
    nonisolated static let playerStatusBarHeight: CGFloat = 52
    /// 52 while the status bar is shown, else 0. Part of the chrome the aspect-lock math subtracts, like the toolbar.
    private(set) var statusBarHeight: CGFloat = 0
    /// Everything in the content area that is not the video: the toolbar plus the status bar when it is shown.
    var chromeHeight: CGFloat { Self.playerToolbarHeight + statusBarHeight }

    /// The status bar height the window's *current frame* was sized for. 0 whenever a fresh window is created at the default
    /// size, and unchanged while the window is fullscreen (the bar is not drawn and nothing resizes), so the difference
    /// between `statusBarHeight` and this is exactly the resize still owed.
    private(set) var frameStatusBarHeight: CGFloat = 0

    /// Records whether the status bar is wanted, then brings the window in line (`syncWindowToStatusBar`).
    func setStatusBarVisible(_ visible: Bool) {
        statusBarHeight = visible ? Self.playerStatusBarHeight : 0
        syncWindowToStatusBar()
    }

    /// The window's current content height, for a per-frame slide (`setContentHeightDuringSlide`); nil in fullscreen or
    /// without a window, where nothing is resized.
    func beginStatusBarSlide() -> CGFloat? {
        guard let win = window, !win.styleMask.contains(.fullScreen), let h = win.contentView?.frame.height else { return nil }
        return h
    }

    /// Sets the window's content height (top edge fixed, width unchanged), unanimated — called once per frame.
    func setContentHeightDuringSlide(_ height: CGFloat) {
        guard let win = window, let w = win.contentView?.frame.width else { return }
        applyContentSize(CGSize(width: w, height: height), to: win, animate: false)
    }

    /// Records the bar's final height as both wanted and already applied to the frame, once a slide has finished.
    func commitStatusBarHeight(_ height: CGFloat) {
        statusBarHeight = height
        frameStatusBarHeight = height
    }

    /// Grows or shrinks the window by whatever the bar's height differs from what the frame was sized for, top edge fixed,
    /// so the video area keeps its size and shape. A no-op in fullscreen (called again when fullscreen ends) and when
    /// there is no window yet (called again when the view appears in a new one).
    func syncWindowToStatusBar() {
        guard let win = window, !win.styleMask.contains(.fullScreen),
              let current = win.contentView?.frame.size else { return }
        let delta = statusBarHeight - frameStatusBarHeight
        guard delta != 0 else { return }
        frameStatusBarHeight = statusBarHeight
        applyContentSize(CGSize(width: current.width, height: current.height + delta), to: win, animate: false)
    }

    /// Narrowest content width the window can be dragged to (2026-10-22; was 640 — the toolbar could not shrink). The
    /// toolbar folds its controls into "…" to fit (`PlayerToolbarItem`); at this width it still has the compact channel
    /// picker, the compact volume slider, catch-up (icon), the ⓘ button and "…". Always above `PlayerToolbarItem.essentialWidth`.
    nonisolated static let playerMinContentWidth: CGFloat = 420
    /// Shortest content height the window can be dragged to: the toolbar plus a sliver of picture. The aspect settle on
    /// release (`windowDidEndLiveResize`) refits the height to the stream anyway.
    nonisolated static let playerMinContentHeight: CGFloat = playerToolbarHeight + 120

    /// Window setup shared by both construction sites: the explicit minimum content size, and a hosting view that no longer
    /// pushes SwiftUI's minimum size into the window (the toolbar's old intrinsic minimum is what kept the window wide).
    private func configureResizing(_ win: NSWindow, hosting: NSHostingView<AnyView>) {
        hosting.sizingOptions = []
        win.contentMinSize = NSSize(width: Self.playerMinContentWidth, height: Self.playerMinContentHeight)
    }

    /// Pure: content size whose video area (content minus the toolbar strip) has the stream's native
    /// aspect at the requested `width`, clamped to `minContentWidth` and `maxContent` (the screen).
    nonisolated static func contentSize(width: CGFloat, nativePixelSize native: CGSize,
                                        toolbarHeight: CGFloat = playerToolbarHeight,
                                        minContentWidth: CGFloat = playerMinContentWidth,
                                        maxContent: CGSize? = nil) -> CGSize {
        let aspect = native.width / native.height
        var w = width
        var floorW = minContentWidth
        if let maxContent {
            // The screen wins over the minimum: on a display narrower than the minimum, the minimum used to be
            // applied after the screen clamp and pushed the window off the edge.
            let screenW = min(maxContent.width, max(0, maxContent.height - toolbarHeight) * aspect)
            w = min(w, screenW)
            floorW = min(floorW, screenW)
        }
        w = max(w, floorW)
        return CGSize(width: w.rounded(), height: (w / aspect + toolbarHeight).rounded())
    }

    /// Pure: the content size to use for a window resize. The video area is held to the stream's
    /// native aspect ratio. Whichever axis the user moved more (in width-equivalent terms) drives the
    /// other, so dragging a top/bottom edge changes the width and a side edge the height. Unknown
    /// native size → the proposal is returned untouched.
    nonisolated static func aspectLockedContentSize(proposed: CGSize, current: CGSize, nativePixelSize: CGSize?,
                                                    toolbarHeight: CGFloat = playerToolbarHeight,
                                                    minContentWidth: CGFloat = playerMinContentWidth,
                                                    maxContent: CGSize? = nil) -> CGSize {
        guard let native = nativePixelSize, native.width > 0, native.height > 0 else { return proposed }
        let aspect = native.width / native.height
        let proposedVideoH = proposed.height - toolbarHeight
        guard proposedVideoH > 0 else { return proposed }
        let widthDelta = abs(proposed.width - current.width)
        let heightDeltaAsWidth = abs(proposedVideoH - (current.height - toolbarHeight)) * aspect
        let width = widthDelta >= heightDeltaAsWidth ? proposed.width : proposedVideoH * aspect
        return contentSize(width: width, nativePixelSize: native, toolbarHeight: toolbarHeight,
                           minContentWidth: minContentWidth, maxContent: maxContent)
    }

    private func screenMaxContent(for win: NSWindow) -> CGSize? {
        guard let vis = (win.screen ?? NSScreen.main)?.visibleFrame else { return nil }
        return win.contentRect(forFrameRect: NSRect(origin: .zero, size: vis.size)).size
    }

    private var liveResizeStartContent: CGSize?
    /// The native size `conformWindowToVideoAspect` last acted on — it re-fits once per picture-shape
    /// change, not on every republish of an unchanged (or window-size-dependent) value.
    private var lastConformedNative: CGSize?

    /// NSWindowDelegate.windowWillStartLiveResize — remembers where the drag began, so the snap on
    /// release can tell which axis the user was actually changing.
    func windowWillStartLiveResize(_ win: NSWindow) {
        guard win === window else { return }
        liveResizeStartContent = win.contentView?.frame.size
    }

    /// NSWindowDelegate.windowDidEndLiveResize — the window moves freely during the drag (the video
    /// pane just rescales inside it, like the PiP does, so nothing fights the drag), then settles to
    /// the stream's native aspect once, on release: whichever axis you moved more drives the other
    /// (`aspectLockedContentSize`), keeping the top-left corner fixed.
    func windowDidEndLiveResize(_ win: NSWindow) {
        defer { liveResizeStartContent = nil }
        guard win === window, !win.styleMask.contains(.fullScreen),
              let native = VLCBridge.shared.videoPixelSize, native.width > 0, native.height > 0,
              let end = win.contentView?.frame.size else { return }
        let start = liveResizeStartContent ?? end
        let target = Self.aspectLockedContentSize(proposed: end, current: start, nativePixelSize: native,
                                                  toolbarHeight: chromeHeight, maxContent: screenMaxContent(for: win))
        applyContentSize(target, to: win, animate: true)
    }

    private func applyContentSize(_ content: CGSize, to win: NSWindow, animate: Bool) {
        guard let current = win.contentView?.frame.size,
              abs(current.width - content.width) > 0.5 || abs(current.height - content.height) > 0.5 else { return }
        var frame = win.frameRect(forContentRect: NSRect(origin: .zero, size: content))
        frame.origin = NSPoint(x: win.frame.minX, y: win.frame.maxY - frame.height)   // keep the top edge fixed
        // Growing downward/rightward must not push the picture under the Dock or off the screen.
        if let visible = (win.screen ?? NSScreen.main)?.visibleFrame { frame = Self.frame(frame, keptWithin: visible) }
        win.setFrame(frame, display: true, animate: animate)
    }

    /// Pure: `frame` slid (never resized) to lie inside `visible`. A frame larger than `visible` is pinned to its
    /// top-left so the title bar and toolbar stay reachable.
    nonisolated static func frame(_ frame: CGRect, keptWithin visible: CGRect) -> CGRect {
        var f = frame
        f.origin.x = min(f.origin.x, visible.maxX - f.width)
        f.origin.x = max(f.origin.x, visible.minX)
        f.origin.y = max(f.origin.y, visible.minY)
        f.origin.y = min(f.origin.y, visible.maxY - f.height)
        return f
    }

    /// Re-fits the window to the stream's native aspect (keeping its width and top-left corner) when
    /// the picture's shape changes — e.g. switching from a 16:9 HD channel to a 4:3 SD one. No-op if
    /// already within 0.5%, in fullscreen, or before the first decoded frame.
    func conformWindowToVideoAspect() {
        // Never during a user drag (it would fight the resize), and only once per distinct native size.
        guard let win = window, !win.styleMask.contains(.fullScreen), !win.inLiveResize,
              let native = VLCBridge.shared.videoPixelSize, native.width > 0, native.height > 0,
              native != lastConformedNative,
              let current = win.contentView?.frame.size else { return }
        lastConformedNative = native
        glog("[VLC] conformWindowToVideoAspect: native \(Int(native.width))×\(Int(native.height)), content \(Int(current.width))×\(Int(current.height))")
        let aspect = native.width / native.height
        let videoH = current.height - chromeHeight
        guard videoH > 0, abs(current.width / videoH - aspect) / aspect > 0.005 else { return }
        let content = Self.contentSize(width: current.width, nativePixelSize: native, toolbarHeight: chromeHeight,
                                       maxContent: screenMaxContent(for: win))
        applyContentSize(content, to: win, animate: false)
    }

    fileprivate func playerWindowDidClose() {
        VLCBridge.shared.keyboardHelpVisible = false   // never reopen showing the "?" card
        glog("[VLC] WindowManager.playerWindowDidClose")
        lastConformedNative = nil   // a reopened window starts at its default shape and needs re-fitting
        // Cancel any in-flight "yield tuner to record" wait before it can reopen a window the user
        // just closed — see AppState.cancelYieldRecordingIfInProgress's own doc comment.
        appState?.cancelYieldRecordingIfInProgress()
        // Stop audio listener before releasing the player — windowWillClose fires before onDisappear,
        // so without this the CoreAudio callback fires into a partially torn-down view.
        VLCBridge.shared.stopDeviceChangeMonitoring()
        // Release the player first: stopCastDiscovery → stopCasting re-plays currentURL to leave the
        // renderer, which would reconnect to a real tuner stream just before it is torn down.
        VLCBridge.shared.releasePlayer() // full teardown — releases mediaPlayer and nils currentURL; Combine auto-clears vlcCurrentURL
        VLCBridge.shared.stopCastDiscovery()
        VLCBridge.shared.releasePlayer(slot: .secondary) // PiP secondary shares this one window — tear it down too
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let rightClickMonitor { NSEvent.removeMonitor(rightClickMonitor) }
        rightClickMonitor = nil
        pendingSeekDelta = 0   // in case the window closed mid-hold, before a matching keyUp arrived
        // FEED teardown — guarded so a normal live-tuner/Watch-Now close pays no new cost. A
        // primary FEED session is a local disk cache (AppState.stopFeedCacheSession — kills the
        // puller, deletes the cache file); a secondary one is still the plain in-memory proxy
        // (unregistering is enough — FeedRelayProxyDelegate's own cleanup fires from conn.cancel()
        // closing the NWConnection it's forwarding into, no process/file of its own to tear down).
        // Both teardown calls are tried for BOTH ids, not just their "usual" slot: a tap-to-swap
        // (swapTrackingFieldsForPiPSwap) can move a primary FEED-cache session's id into
        // secondaryFeedSessionId and vice versa, and each teardown call already no-ops harmlessly
        // for an id it doesn't recognize, so trying both is simpler and safer than tracking which
        // kind of session each slot currently holds through every possible swap.
        if let sessionId = currentFeedSessionId {
            appState?.stopFeedCacheSession(sessionId: sessionId)
            appState?.webServer.unregisterFeedRelaySession(id: sessionId)
        }
        if let sessionId = secondaryFeedSessionId {
            appState?.stopFeedCacheSession(sessionId: sessionId)
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
        frameStatusBarHeight = 0
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
    // Settles the window to the stream's native aspect ratio when a resize drag ends — see
    // VLCPlayerWindowManager.windowDidEndLiveResize.
    func windowWillStartLiveResize(_ notification: Notification) {
        if let win = notification.object as? NSWindow { manager?.windowWillStartLiveResize(win) }
    }
    func windowDidEndLiveResize(_ notification: Notification) {
        if let win = notification.object as? NSWindow { manager?.windowDidEndLiveResize(win) }
    }
    // Zoom (Option-click the green button / Window ▸ Zoom / title-bar double-click): the picture at its native size.
    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        manager?.standardFrame(for: window, defaultFrame: newFrame) ?? newFrame
    }
    // Lets VLCPlayerView hide its own toolbar by default in true fullscreen (see body's ZStack) —
    // without this, our toolbar and macOS's own top-of-screen hover-reveal menu bar compete for
    // the same real estate, since both sit at the top edge of a fullscreen window/space.
    func windowDidEnterFullScreen(_ notification: Notification) {
        NotificationCenter.default.post(name: .vlcFullScreenChanged, object: nil, userInfo: ["isFullScreen": true])
    }
    func windowDidExitFullScreen(_ notification: Notification) {
        NotificationCenter.default.post(name: .vlcFullScreenChanged, object: nil, userInfo: ["isFullScreen": false])
        // A channel change to a different picture shape (HD → SD) while fullscreen skipped the re-fit; do it now.
        manager?.conformWindowToVideoAspect()
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
