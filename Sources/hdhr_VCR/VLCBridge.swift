import AppKit
import Combine
import CoreAudio

// ── C struct mirrors matching libvlc header layouts exactly ──────────────────
// Field order must match the structs in libvlc_media_player.h.

// Mirrors libvlc_media_stats_t (VLC 3.x layout). Field order and types must match exactly.
// VLC 4.x changed this struct — if stats polling misbehaves on VLC 4, disable it.
private struct VLCStats {
    var i_read_bytes:          Int32 = 0
    var f_input_bitrate:       Float = 0
    var i_demux_read_bytes:    Int32 = 0
    var f_demux_bitrate:       Float = 0
    var i_demux_corrupted:     Int32 = 0
    var i_demux_discontinuity: Int32 = 0
    var i_decoded_video:       Int32 = 0
    var i_decoded_audio:       Int32 = 0
    var i_displayed_pictures:  Int32 = 0
    var i_lost_pictures:       Int32 = 0
}

// ── Function pointer typedefs (all @convention(c)) ───────────────────────────

private typealias vlc_new_fn             = @convention(c) (Int32, UnsafePointer<UnsafePointer<CChar>?>?) -> OpaquePointer?
private typealias vlc_media_new_loc_fn   = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> OpaquePointer?
private typealias vlc_media_release_fn   = @convention(c) (OpaquePointer?) -> Void
private typealias vlc_mp_new_fn          = @convention(c) (OpaquePointer?) -> OpaquePointer?   // libvlc_media_player_new
private typealias vlc_mp_set_media_fn    = @convention(c) (OpaquePointer?, OpaquePointer?) -> Void
private typealias vlc_mp_release_fn      = @convention(c) (OpaquePointer?) -> Void
private typealias vlc_mp_set_nso_fn      = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void
private typealias vlc_mp_play_fn         = @convention(c) (OpaquePointer?) -> Int32
private typealias vlc_mp_stop_fn         = @convention(c) (OpaquePointer?) -> Void
private typealias vlc_audio_set_vol_fn   = @convention(c) (OpaquePointer?, Int32) -> Int32
private typealias vlc_adev_set_fn        = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
private typealias vlc_media_add_opt_fn   = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Void
private typealias vlc_mp_set_rate_fn     = @convention(c) (OpaquePointer?, Float) -> Int32
private typealias vlc_mp_get_rate_fn     = @convention(c) (OpaquePointer?) -> Float
private typealias vlc_mp_get_state_fn    = @convention(c) (OpaquePointer?) -> Int32
private typealias vlc_mp_get_stats_fn    = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Int32
private typealias vlc_video_get_size_fn  = @convention(c) (OpaquePointer?, UInt32, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?) -> Int32
private typealias vlc_get_version_fn     = @convention(c) () -> UnsafePointer<CChar>?
private typealias vlc_track_desc_fn      = @convention(c) (OpaquePointer?) -> OpaquePointer?
private typealias vlc_track_rel_fn       = @convention(c) (OpaquePointer?) -> Void
private typealias vlc_track_set_fn       = @convention(c) (OpaquePointer?, Int32) -> Int32

// ── CoreAudio device change monitoring ───────────────────────────────────────

private final class AudioDeviceChangeContext {
    let callback: () -> Void
    init(_ cb: @escaping () -> Void) { callback = cb }
}

private let audioDeviceChangeProc: AudioObjectPropertyListenerProc = { _, _, _, clientData in
    guard let clientData else { return noErr }
    let ctx = Unmanaged<AudioDeviceChangeContext>.fromOpaque(clientData).takeUnretainedValue()
    DispatchQueue.main.async { ctx.callback() }
    return noErr
}

// ── VLCBridge ────────────────────────────────────────────────────────────────
// Loads libvlc.dylib from VLC.app at runtime via dlopen.
// Snapshot of the live buffer state, published on every tickController tick.
struct VLCBufferInfo {
    var lagSec:       Double = 0     // estimated buffer lag behind live edge (0..8s target)
    var rate:         Float  = 1.0   // current playback rate (minRate..1.0 while filling, 1.0 when full)
    var demuxBitrate: Float  = 0     // f_demux_bitrate from libvlc stats (kB/s)
    var corrupted:    Int32  = 0     // cumulative i_demux_corrupted count
    var enabled:      Bool   = false // false when minRate == 1.0 (buffering disabled)
}

// No compile-time dependency — the app builds without VLC installed.
// All methods must be called from the MainActor.

@MainActor
final class VLCBridge: ObservableObject {
    static let shared = VLCBridge()

    /// Resolves the installed VLC.app via Launch Services (bundle identifier lookup) instead of
    /// assuming /Applications/VLC.app — works for Homebrew cask installs, ~/Applications, or any
    /// other location the user (or macOS) put it.
    static func locateApp() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.videolan.vlc")
    }

    private let libHandle: UnsafeMutableRawPointer?

    /// True when VLC.app is installed and libvlc loaded successfully.
    let isAvailable: Bool

    private var vlcInstance:  OpaquePointer?
    private var mediaPlayer:  OpaquePointer?
    private var currentMedia: OpaquePointer?

    /// Retained so channel switches can reattach the same NSView after stop/play.
    private(set) var drawableView: NSView?
    /// Extra strong reference keeping the drawable NSView alive until after _mpRelease drains libvlc callbacks.
    private var retainedDrawable: NSView?
    /// URL queued before the drawable view was ready; played in setDrawable().
    private var pendingURL: String?
    private var deviceChangeContext: AudioDeviceChangeContext?

    // MARK: - Buffer rate controller state
    /// Configured fill-phase floor for **live** streams (from AppConfig, set by VLCPlayerView).
    /// 1.0 = disabled. Not used directly — play(url:) copies it into `minRate` for a live URL, or
    /// forces `minRate = 1.0` for the recording relay (a local loopback file read has no network
    /// jitter to buffer against, so the ramp — and the toolbar's buffer pill — would be theatre).
    var liveMinRate: Float = 0.93
    /// The floor actually in effect for the current stream — live-appropriate or forced to 1.0 for
    /// the recording relay. Set by play(url:); do not set externally.
    private var minRate: Float = 1.0
    @Published var bufferInfo = VLCBufferInfo()
    @Published var hasError:   Bool = false
    @Published var hasEnded:   Bool = false   // true after libvlc_Ended (state 6) — stream reached EOF
    @Published var isPlaying:  Bool = false   // true only after libvlc_Playing (state 3) confirmed
    @Published var audioTracks: [(id: Int32, name: String)] = []  // stream audio tracks; empty = single/unknown
    @Published var spuTracks:   [(id: Int32, name: String)] = []  // CC/subtitle tracks; empty = none detected
    @Published private(set) var currentURL: String?
    @Published private(set) var videoPixelSize: CGSize? = nil  // physical pixels; nil until first decoded frame

    // MARK: - Recording-playback scrub anchor
    // Set by AppState.watchRecordingInApp(_:)/seekRecording(_:) when playing a recording through
    // the WebServer relay (docs/WebServer.md's /api/watch-recording). The relay has no declared
    // Content-Length, so libvlc can't report a real duration/seek — position is instead derived
    // purely from wall-clock time assuming ~1x realtime playback (true for a live TV recording),
    // anchored to the base offset set at the last (re)connect. A scrub commits by reconnecting at
    // a new byte offset (AppState.seekRecording), which resets the anchor via beginRecordingSeek.
    @Published private(set) var recordingShowId:    String? = nil
    @Published private(set) var recordingStartDate: Date?   = nil
    private var recordingSeekBaseSeconds: Double = 0
    private var recordingReopenedAt:      Date   = .distantPast

    func beginRecordingSeek(showId: String, recordingStart: Date, seekBaseSeconds: Double) {
        // Guard against a stale deferred call: AppState.watchRecordingInApp posts this call via
        // DispatchQueue.main.async (a separate run-loop turn so SwiftUI's toolbar picks up the
        // update — see its own comment), creating a brief window where the user can switch to a
        // live channel before this runs. play(url:) for a live URL already calls
        // clearRecordingSeek() synchronously in that case; applying this deferred call anyway
        // would resurrect a dead recordingShowId and corrupt vlcOccupiesTuner's "is this really a
        // zero-cost relay session" check. currentURL still encoding this exact show's id confirms
        // nothing else has taken over the player since this call was scheduled.
        guard let url = currentURL, url.contains("/api/watch-recording"), url.contains("show=\(showId)") else {
            glog("[VLC] beginRecordingSeek — ignored stale call for showId=\(showId), currentURL=\(currentURL ?? "nil") no longer matches", level: .warning)
            return
        }
        recordingShowId          = showId
        recordingStartDate       = recordingStart
        recordingSeekBaseSeconds = seekBaseSeconds
        recordingReopenedAt      = Date()
        glog("[VLC] beginRecordingSeek — showId=\(showId) recordingStart=\(recordingStart) seekBase=\(seekBaseSeconds)s")
    }

    func clearRecordingSeek() {
        guard recordingShowId != nil else { return }
        glog("[VLC] clearRecordingSeek — was showId=\(recordingShowId ?? "?")")
        recordingShowId          = nil
        recordingStartDate       = nil
        recordingSeekBaseSeconds = 0
        recordingReopenedAt      = .distantPast
    }

    /// Estimated position within the recording — seek base plus wall-clock time since the last
    /// (re)connect. Meaningless unless recordingShowId is non-nil.
    var recordingPlaybackSeconds: Double {
        recordingSeekBaseSeconds + Date().timeIntervalSince(recordingReopenedAt)
    }

    private var statsTimer:      Timer?
    private var currentRate:     Float  = 1.0
    private var estimatedLagSec: Double = 0.0
    private var lastCorrupted:   Int32  = 0
    private var catchUpCooldown: Date   = .distantPast
    private var tracksFetched:   Bool   = false

    private let _new:          vlc_new_fn?
    private let _mediaNL:      vlc_media_new_loc_fn?
    private let _mediaRelease: vlc_media_release_fn?
    private let _mpNew:        vlc_mp_new_fn?         // libvlc_media_player_new(instance)
    private let _mpSetMedia:   vlc_mp_set_media_fn?   // libvlc_media_player_set_media
    private let _mpRelease:    vlc_mp_release_fn?
    private let _mpSetNSO:     vlc_mp_set_nso_fn?     // libvlc_media_player_set_nsobject
    private let _mpPlay:       vlc_mp_play_fn?
    private let _mpStop:       vlc_mp_stop_fn?
    private let _audioSetVol:  vlc_audio_set_vol_fn?
    private let _adevSet:      vlc_adev_set_fn?
    private let _mediaAddOpt:  vlc_media_add_opt_fn?
    private let _mpSetRate:     vlc_mp_set_rate_fn?
    private let _mpGetRate:     vlc_mp_get_rate_fn?
    private let _mpGetState:    vlc_mp_get_state_fn?
    private let _mpGetStats:    vlc_mp_get_stats_fn?
    private let _videoGetSize:  vlc_video_get_size_fn?
    private let _getVersion:    vlc_get_version_fn?
    private let _audioTrackDesc:   vlc_track_desc_fn?  // libvlc_audio_get_track_description
    private let _audioSetTrack:    vlc_track_set_fn?   // libvlc_audio_set_track
    private let _spuDesc:          vlc_track_desc_fn?  // libvlc_video_get_spu_description
    private let _spuSet:           vlc_track_set_fn?   // libvlc_video_set_spu
    private let _trackDescRelease: vlc_track_rel_fn?   // libvlc_track_description_list_release

    private init() {
        let vlcAppURL = Self.locateApp()
        let vlcLibDir = vlcAppURL?.appendingPathComponent("Contents/MacOS/lib")
        let h = vlcLibDir.flatMap { libDir -> UnsafeMutableRawPointer? in
            dlopen(libDir.appendingPathComponent("libvlccore.dylib").path, RTLD_LAZY | RTLD_GLOBAL)
            return dlopen(libDir.appendingPathComponent("libvlc.dylib").path, RTLD_LAZY | RTLD_LOCAL)
        }
        libHandle = h

        func sym<T>(_ name: String) -> T? {
            guard let h, let p = dlsym(h, name) else { return nil }
            return unsafeBitCast(p, to: T?.self)
        }

        _new          = sym("libvlc_new")
        _mediaNL      = sym("libvlc_media_new_location")
        _mediaRelease = sym("libvlc_media_release")
        _mpNew        = sym("libvlc_media_player_new")
        _mpSetMedia   = sym("libvlc_media_player_set_media")
        _mpRelease    = sym("libvlc_media_player_release")
        _mpSetNSO     = sym("libvlc_media_player_set_nsobject")
        _mpPlay       = sym("libvlc_media_player_play")
        _mpStop       = sym("libvlc_media_player_stop")
        _audioSetVol  = sym("libvlc_audio_set_volume")
        _adevSet      = sym("libvlc_audio_output_device_set")
        _mediaAddOpt  = sym("libvlc_media_add_option")
        _mpSetRate    = sym("libvlc_media_player_set_rate")
        _mpGetRate    = sym("libvlc_media_player_get_rate")
        _mpGetState   = sym("libvlc_media_player_get_state")
        _mpGetStats   = sym("libvlc_media_player_get_stats")
        _videoGetSize = sym("libvlc_video_get_size")
        _getVersion   = sym("libvlc_get_version")
        _audioTrackDesc   = sym("libvlc_audio_get_track_description")
        _audioSetTrack    = sym("libvlc_audio_set_track")
        _spuDesc          = sym("libvlc_video_get_spu_description")
        _spuSet           = sym("libvlc_video_set_spu")
        _trackDescRelease = sym("libvlc_track_description_list_release")

        isAvailable = h != nil && _new != nil && _mpNew != nil
        guard isAvailable else { return }

        // Log VLC version; warn if VLC 4+ (stats struct layout changed — auto catch-up may misbehave).
        if let versionFn = _getVersion, let versionPtr = versionFn() {
            let version = String(cString: versionPtr)
            let major = Int(version.prefix(while: { $0.isNumber })) ?? 0
            if major >= 4 {
                glog("[VLC] WARNING: VLC \(version) detected — stats struct changed in VLC 4; corruption auto-detect may read wrong fields. Buffer rate control still works.", level: .warning)
            } else {
                glog("[VLC] loaded version \(version)")
            }
        }

        // libvlc_new loads 300+ plugins — run off-main to avoid blocking the UI.
        // C function pointers are plain values, safe to capture across threads.
        let newFn   = _new!
        let mpNewFn = _mpNew!
        if let pluginPath = vlcAppURL?.appendingPathComponent("Contents/MacOS/plugins").path {
            setenv("VLC_PLUGIN_PATH", pluginPath, 1)
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            // OpaquePointer isn't Sendable, but these are freshly-created VLC handles with no
            // other owner yet — safe to hand across the actor boundary to MainActor.run below.
            nonisolated(unsafe) let inst = newFn(0, nil)
            nonisolated(unsafe) let mp   = inst.flatMap { mpNewFn($0) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.vlcInstance = inst
                self.mediaPlayer = mp
                if mp != nil, let url = self.pendingURL, let view = self.drawableView {
                    self.pendingURL = nil
                    self._mpSetNSO?(mp, Unmanaged.passUnretained(view).toOpaque())
                    self.retainedDrawable = view
                    self.play(url: url)
                }
            }
        }
    }

    // MARK: - Drawable

    /// Attach an NSView for VLC to render video into.
    /// Call this from VLCVideoSurface.makeNSView so it's set before the first play().
    func setDrawable(_ view: NSView) {
        glog("[VLC] setDrawable view=\(ObjectIdentifier(view)) mp=\(mediaPlayer != nil ? "ready" : "nil") pending=\(pendingURL != nil ? "yes" : "no")")
        drawableView = view
        guard let mp = mediaPlayer else { return }
        _mpSetNSO?(mp, Unmanaged.passUnretained(view).toOpaque())
        retainedDrawable = view
        if let url = pendingURL {
            pendingURL = nil
            glog("[VLC] setDrawable firing pending play: \(url)")
            play(url: url)
        }
    }

    // MARK: - Playback

    // Every call that used to invoke libvlc_media_player_stop (`_mpStop`) directly on the
    // MainActor now routes through this one serial background queue instead. libvlc_media_player_
    // stop is a *synchronous, blocking* call (superseded by the async libvlc_media_player_stop_
    // async in VLC 4+) — it blocks the calling thread until VLC's internal input thread fully
    // unwinds. For the recording-relay path, that input thread can itself be blocked reading the
    // next chunk from WebServer.pumpGrowingFile, which — once caught up to the live edge — needs a
    // `Task { @MainActor in ... }` hop to check show_recording before it can send more bytes. Call
    // _mpStop synchronously on the MainActor at exactly the wrong instant and neither side can ever
    // unblock the other: the MainActor is frozen waiting for VLC's input thread to close, and VLC's
    // input thread is waiting for bytes gated behind that same frozen MainActor. Caught live via a
    // crash report — an ~11 minute app-wide hang (issues_resolved.md, 2026-08-15).
    //
    // Routing every _mpStop/_mpRelease call through this one serial (not concurrent) queue keeps
    // the MainActor free to service other work — including the relay's own poll-hop — while VLC's
    // teardown runs, and preserves the same effective ordering the old blocking calls gave for
    // free: two overlapping play()/stop()/releasePlayer() calls for the same player still execute
    // their native teardown/reconnect work strictly in call order, since a serial DispatchQueue is
    // FIFO. libvlc's own public API is documented safe to call from any thread — only this Swift
    // wrapper's convenience of doing everything on the MainActor was ever a hard requirement.
    private static let libvlcQueue = DispatchQueue(label: "hdhrVCRplus.vlc.io", qos: .userInitiated)

    /// Switch to a new stream URL (or start playback if idle).
    /// Stops current media, sets new media on the same player, resumes play.
    /// Applies a network cache (2s for a live tuner stream, 300ms for the /api/watch-recording
    /// disk relay — see the network-caching comment below), drops late/corrupt frames, and starts
    /// the rate controller.
    func play(url: String) {
        // Auto-clear the scrub anchor for any URL that isn't the recording relay — covers every
        // call site that starts a live stream (playChannel, watchInApp) without each of them
        // needing to remember to clear it themselves. For a relay URL, refresh the wall-clock
        // anchor point on every (re)connect — including catchUpToLive(), which replays the exact
        // same relay URL — so recordingPlaybackSeconds doesn't drift ahead of what's actually
        // playing after a reconnect that isn't a scrub (no seekBaseSeconds change needed there).
        // AppState.seekRecording/watchRecordingInApp additionally set seekBaseSeconds afterward
        // via beginRecordingSeek().
        let isRecordingRelay = url.contains("/api/watch-recording")
        if isRecordingRelay {
            recordingReopenedAt = Date()
            minRate = 1.0   // local loopback file read — no network jitter to buffer against
        } else {
            clearRecordingSeek()
            minRate = liveMinRate
        }
        guard drawableView != nil else {
            glog("[VLC] play deferred — no drawable yet, queuing as pending: \(url)", level: .warning)
            pendingURL = url
            return
        }
        guard let vlcInst = vlcInstance, let playerMp = mediaPlayer else {
            glog("[VLC] play deferred — vlcInstance=\(vlcInstance != nil ? "ok" : "nil") mediaPlayer=\(mediaPlayer != nil ? "ok" : "nil"), queuing: \(url)", level: .warning)
            pendingURL = url
            return
        }
        glog("[VLC] play url=\(url)")
        stopStatsTimer()
        hasError  = false
        hasEnded  = false
        isPlaying = false
        // Reset track state for the new stream — tickController's fetchTracks() only runs once
        // per !tracksFetched, so without this an ordinary channel switch would keep showing the
        // previous channel's audio/CC tracks, and selecting one could call setAudioTrack/
        // setSpuTrack with an id that doesn't exist on the new stream.
        audioTracks    = []
        spuTracks      = []
        tracksFetched  = false
        // currentURL updates synchronously (matching the old code's timing) — beginRecordingSeek
        // is called by AppState.seekRecording immediately after this returns and depends on
        // currentURL already reflecting this exact request to pass its staleness guard; it can't
        // wait for the background reconnect below to actually finish.
        currentURL = url
        // Claimed synchronously, same moment the old blocking _mpStop?(mp) used to run — so a
        // second play()/stop()/releasePlayer() landing before this call's background work finishes
        // can't also capture and release the same media pointer (a double-free otherwise).
        let oldMediaCaptured = currentMedia
        currentMedia = nil

        // C function pointers are Sendable (@convention(c), no captured state); OpaquePointers
        // aren't, but these are stable handles this instance already owns exclusively for the
        // duration of this call — safe to hand to the background queue (same reasoning as
        // init()'s Task.detached above).
        let stopFn         = _mpStop
        let mediaReleaseFn = _mediaRelease
        let mediaNLFn      = _mediaNL
        let mediaAddOptFn  = _mediaAddOpt
        let setMediaFn     = _mpSetMedia
        let playFn         = _mpPlay
        let setRateFn      = _mpSetRate
        let getRateFn      = _mpGetRate
        nonisolated(unsafe) let mp       = playerMp
        nonisolated(unsafe) let inst     = vlcInst
        nonisolated(unsafe) let oldMedia = oldMediaCaptured
        let targetMinRate = minRate
        // --no-audio-time-stretch prevents VLC from crashing audio init on MPEG-2 streams
        // where the sample rate is reported as 0 before the first audio frame arrives.
        // network-caching is tuned per source: a real tuner stream needs 2000ms to smooth over
        // genuine over-the-air/network jitter (bytes arrive only as fast as the broadcast delivers
        // them), but the /api/watch-recording relay serves bytes that are already sitting on disk
        // the instant playback starts — pumpGrowingFile (WebServer.swift) reads and sends each
        // 37.6KB chunk back-to-back over 127.0.0.1 with no artificial pacing of its own, so the
        // only real latency in that path is local disk I/O + loopback socket overhead, not network
        // jitter. 300ms is enough to absorb that dispatch-queue/disk-read jitter and give VLC's TS
        // demuxer a couple of chunks to sync on the PAT/PMT before it starts decoding, without
        // paying for 1.7s of buffering the relay path doesn't need — this is what lets Watch Now
        // catch up to the live edge (and start playback) much faster than a live tuner stream.
        let networkCachingMs = isRecordingRelay ? 300 : 2000

        Self.libvlcQueue.async {
            stopFn?(mp)
            if let oldMedia { mediaReleaseFn?(oldMedia) }
            guard let media = url.withCString({ mediaNLFn?(inst, $0) }) else {
                glog("[VLC] ERROR: libvlc_media_new_location returned nil for url=\(url)", level: .error)
                return
            }
            for opt in ["--network-caching=\(networkCachingMs)", "--drop-late-frames", "--avcodec-hurry-up", "--no-audio-time-stretch"] {
                opt.withCString { mediaAddOptFn?(media, $0) }
            }
            setMediaFn?(mp, media)
            let rc = playFn?(mp) ?? -1
            if rc != 0 { glog("[VLC] WARNING: libvlc_media_player_play returned \(rc)", level: .warning) }
            if targetMinRate < 1.0 {
                _ = setRateFn?(mp, targetMinRate)
                // Verify rate was accepted — live streams may ignore it on some VLC versions.
                let actual = getRateFn?(mp) ?? 1.0
                if abs(actual - targetMinRate) > 0.01 {
                    glog("[VLC] WARNING: set_rate(\(String(format: "%.2f", targetMinRate))) ignored — actual rate is \(String(format: "%.2f", actual)); buffer will not grow. Playback unaffected.", level: .warning)
                } else {
                    glog("[VLC] rate set to \(String(format: "%.2f", targetMinRate)) (fill phase)")
                }
            }
            nonisolated(unsafe) let mediaForCommit = media
            Task { @MainActor [weak self] in
                guard let self, self.currentURL == url else {
                    // Superseded by a newer play() call before this one's reconnect landed —
                    // don't leak the native media object we just created for it.
                    mediaReleaseFn?(mediaForCommit)
                    return
                }
                self.currentMedia    = mediaForCommit
                self.estimatedLagSec = 0.0
                self.currentRate     = targetMinRate
                self.lastCorrupted   = 0
                self.startStatsTimer()
            }
        }
    }

    func stop() {
        // Soft stop, resumable in place: drawableView is intentionally left attached (see
        // releasePlayer() below) so a later play() finds a live surface to render into instead
        // of queuing as pendingURL forever. Used for the remote-command Stop key.
        glog("[VLC] stop called — drawable=\(drawableView != nil ? "had view" : "already nil") currentURL=\(currentURL ?? "none")")
        stopAndClearState()
    }

    /// Full teardown called on window close — stops, releases, and nils the media player so
    /// libvlc drops its HTTP connection and frees the tuner immediately. ensurePlayer() must
    /// be called before the next play() session.
    func releasePlayer() {
        glog("[VLC] releasePlayer — stopping and releasing mediaPlayer, currentURL=\(currentURL ?? "none")")
        stopAndClearState()
        guard let oldMp = mediaPlayer else { return }
        // Claimed synchronously so a subsequent ensurePlayer() (e.g. a quick reopen) creates a
        // genuinely fresh player instead of finding this now-being-torn-down one still in place.
        mediaPlayer      = nil
        retainedDrawable = nil
        drawableView     = nil
        let releaseFn = _mpRelease
        nonisolated(unsafe) let mp = oldMp
        // Enqueued after stopAndClearState's own libvlcQueue work below (same serial queue — FIFO
        // guarantees this mp's stop finishes before its release runs).
        Self.libvlcQueue.async {
            releaseFn?(mp)
            glog("[VLC] releasePlayer — mediaPlayer released, tuner freed")
        }
    }

    /// Shared teardown: stops the stats timer, resets state flags, stops media, releases current media object.
    /// Does NOT release the media player itself — call releasePlayer() for full teardown.
    /// Deliberately does NOT clear drawableView — see stop()'s doc comment.
    private func stopAndClearState() {
        stopStatsTimer()
        clearRecordingSeek()
        hasError       = false
        hasEnded       = false
        isPlaying      = false
        currentURL     = nil
        pendingURL     = nil
        audioTracks    = []
        spuTracks      = []
        tracksFetched  = false
        videoPixelSize = nil
        guard let playerMp = mediaPlayer else { return }
        let oldMediaCaptured = currentMedia
        currentMedia = nil
        let stopFn         = _mpStop
        let mediaReleaseFn = _mediaRelease
        nonisolated(unsafe) let mp       = playerMp
        nonisolated(unsafe) let oldMedia = oldMediaCaptured
        Self.libvlcQueue.async {
            stopFn?(mp)
            if let oldMedia { mediaReleaseFn?(oldMedia) }
        }
    }

    /// Create a fresh media player from the already-loaded vlcInstance.
    /// Called by VLCPlayerWindowManager.open() before each new player session.
    func ensurePlayer() {
        guard mediaPlayer == nil else { return }
        guard let inst = vlcInstance, let mpNewFn = _mpNew else {
            glog("[VLC] ensurePlayer — vlcInstance or _mpNew not ready, will retry via pendingURL path", level: .warning)
            return
        }
        mediaPlayer = mpNewFn(inst)
        glog("[VLC] ensurePlayer — new mediaPlayer created")
        // Re-attach drawable if it was set before the player was ready.
        if let view = drawableView, let mp = mediaPlayer {
            _mpSetNSO?(mp, Unmanaged.passUnretained(view).toOpaque())
            retainedDrawable = view
        }
    }

    /// Discard buffered content and reconnect to the live edge. Resets the rate controller.
    func catchUpToLive() {
        guard let url = currentURL else {
            glog("[VLC] catchUpToLive — no currentURL, ignoring")
            return
        }
        glog("[VLC] catchUpToLive — reconnecting to: \(url)")
        play(url: url)
    }

    /// Returns the video's native pixel dimensions once decoding has started; nil otherwise.
    func videoNativeSize() -> CGSize? {
        guard let mp = mediaPlayer, let fn = _videoGetSize else { return nil }
        var w: UInt32 = 0
        var h: UInt32 = 0
        guard fn(mp, 0, &w, &h) == 0, w > 0, h > 0 else { return nil }
        return CGSize(width: CGFloat(w), height: CGFloat(h))
    }

    // MARK: - Rate controller (private)

    private func startStatsTimer() {
        // Always starts — tickController does more than the rate ramp/stats (isPlaying/hasError
        // state detection, track fetching, video pixel size), all needed regardless of minRate.
        // The old guard (`minRate < 1.0 || _mpGetStats != nil`) could skip the timer entirely
        // whenever minRate == 1.0 and _mpGetStats somehow failed to resolve, silently disabling
        // isPlaying detection too — exactly the kind of stall a recording-relay session (which now
        // always sets minRate = 1.0) would hit if that ever happened.
        // Timer.scheduledTimer(withTimeInterval:) implicitly runs in .default run-loop mode, which
        // stalls while the run loop is in .eventTracking mode (an open NSMenu, a live window
        // resize/drag) — isPlaying/hasError detection and the rate ramp would silently freeze for
        // the duration, e.g. "Connecting…" sticking until a menu closes. .common includes both
        // .default and .eventTracking, so the timer keeps firing through UI tracking.
        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickController() }
        }
        RunLoop.main.add(timer, forMode: .common)
        statsTimer = timer
    }

    private func stopStatsTimer() {
        statsTimer?.invalidate()
        statsTimer = nil
    }

    private func tickController() {
        guard let mp = mediaPlayer else { return }

        if let getState = _mpGetState {
            let state = getState(mp)
            if state == 7 {  // libvlc_Error: connection refused, no route to host, etc.
                glog("[VLC] stream error state — publishing hasError", level: .error)
                hasError  = true
                isPlaying = false
                stopStatsTimer()
                return
            }
            if state == 6 {  // libvlc_Ended: stream reached EOF (a finished recording relay read to its
                // final byte, or a live source closed). Without handling this, isPlaying stays true and
                // the stats timer polls a stopped player forever, freezing on the last frame with no
                // indication. Publish hasEnded so the view shows an "ended" overlay, and stop polling.
                glog("[VLC] stream ended (libvlc_Ended) — publishing hasEnded")
                hasEnded  = true
                isPlaying = false
                stopStatsTimer()
                return
            }
            if state == 3 && !isPlaying {  // libvlc_Playing: first confirmed decode tick
                isPlaying = true
                glog("[VLC] stream playing confirmed")
            }
        }
        // Fetch track descriptions once playing; retry every tick until audio tracks appear.
        if isPlaying && !tracksFetched { fetchTracks() }

        // Adaptive rate: ramp from minRate toward 1.0 as estimated buffer lag grows toward 8s.
        if minRate < 1.0 {
            estimatedLagSec = min(8.0, estimatedLagSec + Double(1.0 - currentRate) * 3.0)
            let fillRatio   = Float(estimatedLagSec / 8.0)
            let newRate     = minRate + (1.0 - minRate) * fillRatio
            if abs(newRate - currentRate) > 0.001 {
                currentRate = newRate
                _ = _mpSetRate?(mp, newRate)
                glog("[VLC] rate → \(String(format: "%.3f", newRate)) (lag ~\(Int(estimatedLagSec))s / 8s)")
            }
        }

        // Resolve stats fields — carry previous values when stats are unavailable.
        var newBitrate   = bufferInfo.demuxBitrate
        var newCorrupted = bufferInfo.corrupted
        var corruptDelta: Int32 = 0
        if let getStats = _mpGetStats {
            var s = VLCStats()
            let ok = withUnsafeMutableBytes(of: &s) { getStats(mp, $0.baseAddress) }
            if ok == 1 {
                corruptDelta  = s.i_demux_corrupted - lastCorrupted
                lastCorrupted = s.i_demux_corrupted
                newBitrate    = s.f_demux_bitrate
                newCorrupted  = lastCorrupted
            } else {
                glog("[VLC] WARNING: get_stats returned \(ok) — stats polling skipped (may indicate VLC 4 struct mismatch)", level: .warning)
            }
        }
        // Single publish per tick — bar is always updated, bitrate/corrupted carry forward when stats fail.
        bufferInfo = VLCBufferInfo(lagSec: estimatedLagSec, rate: currentRate,
                                   demuxBitrate: newBitrate, corrupted: newCorrupted,
                                   enabled: minRate < 1.0)
        let newPixelSize = videoNativeSize()
        if newPixelSize != videoPixelSize { videoPixelSize = newPixelSize }
        // i_lost_pictures is a rendering metric — it spikes when the window is backgrounded
        // (macOS stops compositing the surface). Only use i_demux_corrupted (stream-level) to
        // avoid false catch-up loops when the window isn't visible.
        // Never auto-catch-up a recording-relay session. catchUpToLive() replays currentURL verbatim,
        // and a relay URL carries a fixed &start=<byteOffset>; reconnecting at that anchor yanks
        // playback *backward* to the last seek, discarding progress. The user is deliberately behind
        // live while watching an in-progress recording, so catch-up doesn't apply — the manual
        // catch-up button routes relays to seekRecordingToLiveEdge instead. Checked before the cooldown
        // so a relay never even arms it. (recordingShowId is nil for live-tuner playback.)
        guard recordingShowId == nil else { return }
        guard corruptDelta > 15 else { return }
        guard Date() > catchUpCooldown else { return }
        catchUpCooldown = Date().addingTimeInterval(30)
        glog("[VLC] stream corruption detected (i_demux_corrupted delta=\(corruptDelta)) — catching up to live")
        catchUpToLive()
    }

    // MARK: - Track selection (audio tracks and CC/subtitle tracks)

    /// Fetch audio and SPU track descriptions from libvlc. Called from tickController once
    /// playing; retries every 3s until audio tracks appear (they may not be ready immediately).
    func fetchTracks() {
        guard let mp = mediaPlayer else { return }
        if let ptr = _audioTrackDesc?(mp) {
            let filtered = parseTrackDescriptions(ptr).filter { $0.id >= 0 }
            if !filtered.isEmpty {
                audioTracks   = filtered
                tracksFetched = true
            }
        }
        if tracksFetched, let ptr = _spuDesc?(mp) {
            spuTracks = parseTrackDescriptions(ptr).filter { $0.id >= 0 }
        }
        if !audioTracks.isEmpty {
            glog("[VLC] tracks — audio: \(audioTracks.map { "\($0.id):\($0.name)" }.joined(separator: ", "))" +
                 (spuTracks.isEmpty ? "" : "  spu: \(spuTracks.map { "\($0.id):\($0.name)" }.joined(separator: ", "))"))
        }
    }

    func setAudioTrack(id: Int32) {
        guard let mp = mediaPlayer else { return }
        _ = _audioSetTrack?(mp, id)
        glog("[VLC] setAudioTrack id=\(id)")
    }

    func setSpuTrack(id: Int32) {
        guard let mp = mediaPlayer else { return }
        _ = _spuSet?(mp, id)
        glog("[VLC] setSpuTrack id=\(id) (\(id < 0 ? "off" : "on"))")
    }

    /// Walk a libvlc_track_description_t linked list and return (id, name) pairs.
    /// C layout on 64-bit: i_id Int32 at offset 0, psz_name ptr at offset 8, p_next ptr at offset 16.
    /// Releases the list via libvlc_track_description_list_release before returning.
    private func parseTrackDescriptions(_ ptr: OpaquePointer) -> [(id: Int32, name: String)] {
        var result: [(id: Int32, name: String)] = []
        var raw: UnsafeRawPointer? = UnsafeRawPointer(ptr)
        while let r = raw {
            let id      = r.load(fromByteOffset: 0,  as: Int32.self)
            let namePtr = r.load(fromByteOffset: 8,  as: UnsafePointer<CChar>?.self)
            let nextPtr = r.load(fromByteOffset: 16, as: OpaquePointer?.self)
            let name    = namePtr.map { String(cString: $0) } ?? ""
            result.append((id: id, name: name.isEmpty ? "Track \(result.count + 1)" : name))
            raw = nextPtr.map { UnsafeRawPointer($0) }
        }
        _trackDescRelease?(ptr)
        return result
    }

    // MARK: - Volume  (UI scale 0–100; VLC scale 0–200, unity = 100)

    func setVolume(_ v: Int) {
        guard let mp = mediaPlayer else { return }
        _ = _audioSetVol?(mp, Int32(max(0, min(100, v)) * 2))
    }

    // MARK: - Audio device

    func setAudioDevice(output: String, deviceId: String) {
        guard let mp = mediaPlayer else { return }
        output.withCString { outp in
            deviceId.withCString { devp in
                _adevSet?(mp, outp, devp)
            }
        }
    }

    // MARK: - System Audio Devices (CoreAudio HAL)

    /// All CoreAudio output devices: built-in speakers, USB, Bluetooth (AirPods etc.), AirPlay receivers.
    /// Returns (id: CoreAudio device UID, name: display name).
    /// Pass the UID to setAudioDevice(output: "auhal", deviceId: uid) to route VLC there.
    func systemAudioOutputDevices() -> [(id: String, name: String)] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope:    kAudioObjectPropertyScopeGlobal,
                                              mElement:  kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { deviceID in
            // Skip devices with no output streams (e.g. input-only microphones)
            var streamAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                         mScope:    kAudioObjectPropertyScopeOutput,
                                                         mElement:  kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &streamAddr, 0, nil, &streamSize) == noErr,
                  streamSize > 0 else { return nil }
            guard let uid  = coreAudioString(deviceID, kAudioDevicePropertyDeviceUID),
                  let name = coreAudioString(deviceID, kAudioObjectPropertyName) else { return nil }
            return (id: uid, name: name)
        }
    }

    /// UID of the current system-default output device (matches System Settings → Sound → Output).
    func systemDefaultOutputUID() -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope:    kAudioObjectPropertyScopeGlobal,
                                              mElement:  kAudioObjectPropertyElementMain)
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr else { return nil }
        return coreAudioString(deviceID, kAudioDevicePropertyDeviceUID)
    }

    // MARK: - Device Change Monitoring

    func startDeviceChangeMonitoring(callback: @escaping () -> Void) {
        // Guard against double-registration: old opaque pointer would be freed by ARC while
        // CoreAudio still holds it, causing use-after-free on the next device-change event.
        if deviceChangeContext != nil { stopDeviceChangeMonitoring() }
        let ctx = AudioDeviceChangeContext(callback)
        deviceChangeContext = ctx
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope:    kAudioObjectPropertyScopeGlobal,
                                              mElement:  kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       audioDeviceChangeProc,
                                       Unmanaged.passUnretained(ctx).toOpaque())
    }

    func stopDeviceChangeMonitoring() {
        guard let ctx = deviceChangeContext else { return }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope:    kAudioObjectPropertyScopeGlobal,
                                              mElement:  kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject), &addr,
                                          audioDeviceChangeProc,
                                          Unmanaged.passUnretained(ctx).toOpaque())
        deviceChangeContext = nil
    }

    private func coreAudioString(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope:    kAudioObjectPropertyScopeGlobal,
                                              mElement:  kAudioObjectPropertyElementMain)
        // CoreAudio returns a +1 retained CFStringRef; use Unmanaged to take ownership safely.
        var propSize = UInt32(MemoryLayout<UnsafeRawPointer>.size)
        var rawPtr: UnsafeRawPointer? = nil
        let status = withUnsafeMutablePointer(to: &rawPtr) {
            AudioObjectGetPropertyData(objectID, &addr, 0, nil, &propSize, $0)
        }
        guard status == noErr, let p = rawPtr else { return nil }
        let s = Unmanaged<CFString>.fromOpaque(p).takeRetainedValue() as String
        return s.isEmpty ? nil : s
    }
}
