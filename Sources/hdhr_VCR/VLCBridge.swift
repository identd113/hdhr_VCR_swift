import AppKit

// ── C struct mirrors matching libvlc header layouts exactly ──────────────────
// Used to walk linked lists returned by libvlc_audio_output_list_get /
// libvlc_audio_output_device_list_get without needing the VLC headers at
// compile time. Field order must match the structs in libvlc_media_player.h.

private struct vlc_audio_output_t {
    let psz_name:        UnsafePointer<CChar>?
    let psz_description: UnsafePointer<CChar>?
    let p_next:          UnsafeMutablePointer<vlc_audio_output_t>?
}

private struct vlc_audio_output_device_t {
    let p_next:          UnsafeMutablePointer<vlc_audio_output_device_t>?
    let psz_device:      UnsafePointer<CChar>?
    let psz_description: UnsafePointer<CChar>?
}

// ── Function pointer typedefs (all @convention(c)) ───────────────────────────

private typealias vlc_new_fn             = @convention(c) (Int32, UnsafePointer<UnsafePointer<CChar>?>?) -> OpaquePointer?
private typealias vlc_release_fn         = @convention(c) (OpaquePointer?) -> Void
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
// Raw-pointer typedefs for list get/release: Swift structs aren't ObjC-representable,
// so we use UnsafeMutableRawPointer and rebind to the typed structs at the call site.
private typealias vlc_aout_list_get_fn   = @convention(c) (OpaquePointer?) -> UnsafeMutableRawPointer?
private typealias vlc_aout_list_rel_fn   = @convention(c) (UnsafeMutableRawPointer?) -> Void
private typealias vlc_aout_set_fn        = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Int32
private typealias vlc_adev_list_get_fn   = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
private typealias vlc_adev_list_rel_fn   = @convention(c) (UnsafeMutableRawPointer?) -> Void
private typealias vlc_adev_set_fn        = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void

// ── VLCBridge ────────────────────────────────────────────────────────────────
// Loads libvlc.dylib from VLC.app at runtime via dlopen.
// No compile-time dependency — the app builds without VLC installed.
// All methods must be called from the MainActor.

@MainActor
final class VLCBridge {
    static let shared = VLCBridge()

    private let libHandle: UnsafeMutableRawPointer?

    /// True when VLC.app is installed and libvlc loaded successfully.
    let isAvailable: Bool

    private var vlcInstance:  OpaquePointer?
    private var mediaPlayer:  OpaquePointer?
    private var currentMedia: OpaquePointer?

    /// Retained so channel switches can reattach the same NSView after stop/play.
    private(set) var drawableView: NSView?
    /// URL queued before the drawable view was ready; played in setDrawable().
    private var pendingURL: String?

    private let _new:          vlc_new_fn?
    private let _release:      vlc_release_fn?
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
    private let _aoutListGet:  vlc_aout_list_get_fn?
    private let _aoutListRel:  vlc_aout_list_rel_fn?
    private let _aoutSet:      vlc_aout_set_fn?
    private let _adevListGet:  vlc_adev_list_get_fn?
    private let _adevListRel:  vlc_adev_list_rel_fn?
    private let _adevSet:      vlc_adev_set_fn?

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
        _release      = sym("libvlc_release")
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
        _aoutListGet  = sym("libvlc_audio_output_list_get")
        _aoutListRel  = sym("libvlc_audio_output_list_release")
        _aoutSet      = sym("libvlc_audio_output_set")
        _adevListGet  = sym("libvlc_audio_output_device_list_get")
        _adevListRel  = sym("libvlc_audio_output_device_list_release")
        _adevSet      = sym("libvlc_audio_output_device_set")

        isAvailable = h != nil && _new != nil && _mpNew != nil
        guard isAvailable else { return }

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
                    self.play(url: url)
                }
            }
        }
    }

    // MARK: - Drawable

    /// Attach an NSView for VLC to render video into.
    /// Call this from VLCVideoSurface.makeNSView so it's set before the first play().
    func setDrawable(_ view: NSView) {
        drawableView = view
        guard let mp = mediaPlayer else { return }
        _mpSetNSO?(mp, Unmanaged.passUnretained(view).toOpaque())
        if let url = pendingURL {
            pendingURL = nil
            play(url: url)
        }
    }

    // MARK: - Playback

    /// Switch to a new stream URL (or start playback if idle).
    /// Stops current media, sets new media on the same player, resumes play.
    func play(url: String) {
        guard drawableView != nil else { pendingURL = url; return }
        guard let inst = vlcInstance, let mp = mediaPlayer else { pendingURL = url; return }
        _mpStop?(mp)
        if let old = currentMedia { _mediaRelease?(old); currentMedia = nil }
        guard let media = url.withCString({ _mediaNL?(inst, $0) }) else { return }
        currentMedia = media
        _mpSetMedia?(mp, media)
        _ = _mpPlay?(mp)
    }

    func stop() {
        pendingURL = nil
        drawableView = nil
        guard let mp = mediaPlayer else { return }
        _mpStop?(mp)
        if let old = currentMedia { _mediaRelease?(old); currentMedia = nil }
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

    // MARK: - Audio outputs

    func audioOutputs() -> [(name: String, description: String)] {
        guard let inst = vlcInstance,
              let listGet = _aoutListGet, let listRel = _aoutListRel,
              let rawHead = listGet(inst) else { return [] }
        defer { listRel(rawHead) }
        var results: [(name: String, description: String)] = []
        var node: UnsafeMutablePointer<vlc_audio_output_t>? = rawHead.bindMemory(to: vlc_audio_output_t.self, capacity: 1)
        while let cur = node {
            let name = cur.pointee.psz_name.map { String(cString: $0) } ?? ""
            let desc = cur.pointee.psz_description.map { String(cString: $0) } ?? name
            if !name.isEmpty { results.append((name: name, description: desc)) }
            node = cur.pointee.p_next
        }
        return results
    }

    func setAudioOutput(_ name: String) {
        guard let mp = mediaPlayer else { return }
        _ = name.withCString { _aoutSet?(mp, $0) }
    }

    // MARK: - Audio devices

    func audioDevices(forOutput outputName: String) -> [(id: String, name: String)] {
        guard let inst = vlcInstance,
              let listGet = _adevListGet, let listRel = _adevListRel,
              let rawHead = outputName.withCString({ listGet(inst, $0) }) else { return [] }
        defer { listRel(rawHead) }
        var results: [(id: String, name: String)] = []
        var node: UnsafeMutablePointer<vlc_audio_output_device_t>? = rawHead.bindMemory(to: vlc_audio_output_device_t.self, capacity: 1)
        while let cur = node {
            let id   = cur.pointee.psz_device.map { String(cString: $0) } ?? ""
            let desc = cur.pointee.psz_description.map { String(cString: $0) } ?? id
            if !id.isEmpty { results.append((id: id, name: desc)) }
            node = cur.pointee.p_next
        }
        return results
    }

    func setAudioDevice(output: String, deviceId: String) {
        guard let mp = mediaPlayer else { return }
        output.withCString { outp in
            deviceId.withCString { devp in
                _adevSet?(mp, outp, devp)
            }
        }
    }
}
