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
private typealias vlc_audio_get_vol_fn   = @convention(c) (OpaquePointer?) -> Int32
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
    /// Minimum playback rate (fill-phase floor). Set from AppConfig by VLCPlayerView. 1.0 = disabled.
    var minRate: Float = 0.93
    @Published var bufferInfo = VLCBufferInfo()
    @Published var hasError:   Bool = false
    @Published var isPlaying:  Bool = false   // true only after libvlc_Playing (state 3) confirmed
    @Published var audioTracks: [(id: Int32, name: String)] = []  // stream audio tracks; empty = single/unknown
    @Published var spuTracks:   [(id: Int32, name: String)] = []  // CC/subtitle tracks; empty = none detected
    @Published private(set) var currentURL: String?
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
    private let _audioGetVol:  vlc_audio_get_vol_fn?
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
        let vlcLib = "/Applications/VLC.app/Contents/MacOS/lib/"
        dlopen(vlcLib + "libvlccore.dylib", RTLD_LAZY | RTLD_GLOBAL)
        let libPath = vlcLib + "libvlc.dylib"
        let h = dlopen(libPath, RTLD_LAZY | RTLD_LOCAL)
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
        _audioGetVol  = sym("libvlc_audio_get_volume")
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
        setenv("VLC_PLUGIN_PATH", "/Applications/VLC.app/Contents/MacOS/plugins", 1)
        Task.detached(priority: .userInitiated) { [weak self] in
            let inst = newFn(0, nil)
            let mp   = inst.flatMap { mpNewFn($0) }
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

    /// Switch to a new stream URL (or start playback if idle).
    /// Stops current media, sets new media on the same player, resumes play.
    /// Always applies 2s network cache, drops late/corrupt frames, and starts the rate controller.
    func play(url: String) {
        guard drawableView != nil else {
            glog("[VLC] play deferred — no drawable yet, queuing as pending: \(url)", level: .warning)
            pendingURL = url
            return
        }
        guard let inst = vlcInstance, let mp = mediaPlayer else {
            glog("[VLC] play deferred — vlcInstance=\(vlcInstance != nil ? "ok" : "nil") mediaPlayer=\(mediaPlayer != nil ? "ok" : "nil"), queuing: \(url)", level: .warning)
            pendingURL = url
            return
        }
        glog("[VLC] play url=\(url)")
        stopStatsTimer()
        hasError  = false
        isPlaying = false
        _mpStop?(mp)
        if let old = currentMedia { _mediaRelease?(old); currentMedia = nil }
        guard let media = url.withCString({ _mediaNL?(inst, $0) }) else {
            glog("[VLC] ERROR: libvlc_media_new_location returned nil for url=\(url)", level: .error)
            return
        }
        // --no-audio-time-stretch prevents VLC from crashing audio init on MPEG-2 streams
        // where the sample rate is reported as 0 before the first audio frame arrives.
        for opt in ["--network-caching=2000", "--drop-late-frames", "--avcodec-hurry-up", "--no-audio-time-stretch"] {
            opt.withCString { _mediaAddOpt?(media, $0) }
        }
        currentURL        = url
        currentMedia      = media
        estimatedLagSec   = 0.0
        currentRate       = minRate
        lastCorrupted     = 0
        _mpSetMedia?(mp, media)
        let rc = _mpPlay?(mp) ?? -1
        if rc != 0 { glog("[VLC] WARNING: libvlc_media_player_play returned \(rc)", level: .warning) }
        if minRate < 1.0 {
            _ = _mpSetRate?(mp, minRate)
            // Verify rate was accepted — live streams may ignore it on some VLC versions.
            let actual = _mpGetRate?(mp) ?? 1.0
            if abs(actual - minRate) > 0.01 {
                glog("[VLC] WARNING: set_rate(\(String(format: "%.2f", minRate))) ignored — actual rate is \(String(format: "%.2f", actual)); buffer will not grow. Playback unaffected.", level: .warning)
            } else {
                glog("[VLC] rate set to \(String(format: "%.2f", minRate)) (fill phase)")
            }
        }
        startStatsTimer()
    }

    func stop() {
        // Lightweight stop used for remote-command Stop key — keeps the player alive for reuse.
        // drawableView is cleared so a subsequent play() queues as pending; the window goes black.
        glog("[VLC] stop called — drawable=\(drawableView != nil ? "had view" : "already nil") currentURL=\(currentURL ?? "none")")
        stopAndClearState()
    }

    /// Full teardown called on window close — stops, releases, and nils the media player so
    /// libvlc drops its HTTP connection and frees the tuner immediately. ensurePlayer() must
    /// be called before the next play() session.
    func releasePlayer() {
        glog("[VLC] releasePlayer — stopping and releasing mediaPlayer, currentURL=\(currentURL ?? "none")")
        stopAndClearState()
        guard let mp = mediaPlayer else { return }
        _mpRelease?(mp)
        mediaPlayer = nil
        retainedDrawable = nil
        glog("[VLC] releasePlayer — mediaPlayer released, tuner freed")
    }

    /// Shared teardown: stops the stats timer, resets state flags, stops media, releases current media object.
    /// Does NOT release the media player itself — call releasePlayer() for full teardown.
    private func stopAndClearState() {
        stopStatsTimer()
        hasError      = false
        isPlaying     = false
        currentURL    = nil
        pendingURL    = nil
        drawableView  = nil
        audioTracks   = []
        spuTracks     = []
        tracksFetched = false
        guard let mp = mediaPlayer else { return }
        _mpStop?(mp)
        if let old = currentMedia { _mediaRelease?(old); currentMedia = nil }
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
        guard minRate < 1.0 || _mpGetStats != nil else { return }
        statsTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickController() }
        }
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
        // i_lost_pictures is a rendering metric — it spikes when the window is backgrounded
        // (macOS stops compositing the surface). Only use i_demux_corrupted (stream-level) to
        // avoid false catch-up loops when the window isn't visible.
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

    func volume() -> Int {
        guard let mp = mediaPlayer else { return 50 }
        return max(0, min(100, Int(_audioGetVol?(mp) ?? 100) / 2))
    }

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
