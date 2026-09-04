import Foundation
import Darwin

// Responds to real HDHomeRun UDP discovery (broadcast/unicast to port 65001) while — and only
// while — this app has at least one show actively recording, so another HDHomeRun-aware client
// (including another hdhrVCRplus instance) can discover a temporary "tuner" whose channels are
// whatever's currently being captured to disk, and watch it via WebServer's relay instead of
// opening a second real tuner session against the actual device for content already on disk. See
// docs/VirtualTunerService.md and the "Rebroadcast an in-progress recording" plan.
//
// Deliberately dumb: this class owns only the UDP socket lifecycle and replies with whatever
// DeviceID it's told to advertise. It does not track the lineup, does not know about Shows, and
// exposes no readable state back to callers — AppState (already the source of truth for what's
// recording and already MainActor-isolated) remembers its own copy of the DeviceID it started this
// service with, which is both simpler than synchronizing state across the UDP read queue and
// exactly what AppState needs for its own self-exclusion check (never adding *this instance's own*
// virtual tuner back into `state.devices` via normal discovery).
//
// UDP wire format mirrors `HDHRManager.swift`'s existing *client-side* discovery code
// (`udpDiscoverSync`) and `tools/mock_hdhr.py`'s reference server-side responder — raw BSD sockets,
// not Network.framework, to reuse the already-correct `crc32(_:)` (`CompatibilityHelpers.swift`)
// and stay in the same style as the rest of this app's own HDHomeRun-protocol code. Incoming
// request validation is deliberately as loose as the real protocol tolerates (and as loose as
// `mock_hdhr.py` itself is) — just enough bytes and the right type field, no TLV/CRC parsing of the
// request, since a broadcast discovery probe is meant to be answered by everything listening.
final class VirtualTunerService {
    // Non-standard field names, additive to the otherwise-real HDHomeRun /discover.json and
    // /lineup.json shapes WebServer's builders produce — a real client ignores an unknown field;
    // this app's own HDHRDevice/GuideEntryDTO-style decoding recognizes them. virtualRelayMarkerKey
    // is what HDHRDevice.isVirtualRelay decodes from (see that property's own doc comment);
    // showTitleKey is what lets a discovering hdhrVCRplus instance's menu bar say "Recording on
    // <title>" instead of just a bare channel number (a generic lineup entry has no room for that).
    // transcodeViewersKey mirrors that same reasoning for MenuContent's "Recording on Another Mac"
    // submenu — see buildVirtualTunerLineupJSON's own comment on why this is per-show, not
    // machine-wide, and why it reflects viewers of an ALREADY-active remote transcode session, not
    // anything this instance's own click would request (watchRemoteRelay never applies a transcode
    // override today). signalQualityKey, added 2026-09-04, carries the source tuner's own estimated
    // signal (same 0-100 snq scale a real device's /status.json SignalQualityPercent field uses —
    // WebServer.liveSignalQualityPercent(for:state:) is the shared lookup both that route and this
    // key's own producer, buildVirtualTunerLineupJSON, read from) — a real lineup entry has no
    // per-channel signal field at all, only /status.json does, so this has to be a synthetic key
    // here rather than reusing the real field name the way VideoCodec/AudioCodec do above.
    static let virtualRelayMarkerKey = "HdhrVCRplusVirtualRelay"
    static let showTitleKey = "HdhrVCRplusShowTitle"
    static let transcodeViewersKey = "HdhrVCRplusTranscodeViewers"
    static let signalQualityKey = "HdhrVCRplusSignalQualityPercent"

    private let queue = DispatchQueue(label: "hdhrVCRplus.virtualtuner.udp", qos: .utility)
    private var sock: Int32 = -1
    private var readSource: DispatchSourceRead?
    // Written and read only on `queue` — start()/stop() hop onto it before touching either, and
    // handleReadable() already runs on it (it's the read source's target queue), so no lock needed.
    private var advertisedDeviceID: UInt32 = 0
    private var advertisedBaseURL: String = ""
    private var advertisedTunerCount: UInt8 = 0

    /// Begins responding to discovery requests as `deviceID` (8 hex chars, e.g. "FEED1234"),
    /// advertising `baseURL` (e.g. "http://10.0.2.100:1980") and `tunerCount` in the reply's own
    /// TLVs — added 2026-09-02 after live-capturing a real EXTEND's actual DISCOVER_REPLY and
    /// finding it carries DeviceType/BaseURL/TunerCount/LineupURL, none of which this responder
    /// used to send. Without BaseURL specifically, a real third-party client has no way to learn
    /// this relay runs on a non-standard port (1980, not the real protocol's usual 80) and either
    /// assumes port 80 (connection refused) or discards the reply outright — this app's own client
    /// (HDHRManager.udpDiscoverSync) never needed it because it always went straight to the HTTP
    /// JSON routes for metadata, but that's not how compliant third-party discovery actually works.
    /// Safe to call again while already running (updates all three advertised fields in place, no
    /// rebind) — AppState.updateVirtualTunerPresence relies on this to refresh TunerCount whenever
    /// a show starts/stops recording after the relay is already up.
    /// Bind failure (port 65001 already in use — another instance, or a real libhdhomerun-based
    /// tool) is non-fatal: logs and leaves the responder off, same graceful-degradation behavior
    /// `mock_hdhr.py` documents for a real device losing that race. `onBindResult`, if given, is
    /// called once (on an arbitrary queue) with whether the UDP responder actually came up — lets
    /// AppState.updateVirtualTunerPresence back out `activeVirtualTunerDeviceID` on failure rather
    /// than leaving the HTTP JSON routes advertising a "live" relay no UDP client can discover.
    /// Not called at all when already running (the early `self.sock < 0` return below) — a caller
    /// only needs the result of the bind attempt that mints a fresh device ID.
    func start(deviceID: String, baseURL: String = "", tunerCount: Int = 0, onBindResult: ((Bool) -> Void)? = nil) {
        guard let idValue = UInt32(deviceID, radix: 16) else {
            glog("[VirtualTuner] invalid deviceID '\(deviceID)' — not starting", level: .warning)
            onBindResult?(false)
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.advertisedDeviceID = idValue
            self.advertisedBaseURL = baseURL
            self.advertisedTunerCount = UInt8(clamping: tunerCount)
            guard self.sock < 0 else { return }   // already bound — just updated the advertised fields above

            let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard s >= 0 else {
                glog("[VirtualTuner] socket() failed errno=\(errno) — discovery responder disabled", level: .warning)
                onBindResult?(false)
                return
            }
            var yes: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(65001).bigEndian
            addr.sin_addr.s_addr = INADDR_ANY
            let bindResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    bind(s, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0 else {
                glog("[VirtualTuner] UDP bind(:65001) failed errno=\(errno) — discovery responder disabled", level: .warning)
                Darwin.close(s)
                onBindResult?(false)
                return
            }
            self.sock = s
            let source = DispatchSource.makeReadSource(fileDescriptor: s, queue: self.queue)
            source.setEventHandler { [weak self] in self?.handleReadable() }
            source.setCancelHandler { Darwin.close(s) }
            source.resume()
            self.readSource = source
            glog("[VirtualTuner] started, DeviceID=\(deviceID)")
            onBindResult?(true)
        }
    }

    /// Stops responding and closes the socket. Safe to call when not running.
    func stop() {
        queue.async { [weak self] in
            guard let self, self.sock >= 0 else { return }
            self.readSource?.cancel()   // cancel handler closes the fd
            self.readSource = nil
            self.sock = -1
            glog("[VirtualTuner] stopped")
        }
    }

    // Runs on `queue` (the read source's target queue). Parses an incoming discovery request
    // (type 0x0002) as loosely as mock_hdhr.py's own reference implementation — length ≥4 bytes and
    // the big-endian type field — and replies unicast with a DISCOVER_REPLY (type 0x0003) carrying
    // the same TLVs a real device's own reply does (see buildDiscoverReply's own doc comment for
    // the live-captured ground truth this is built from).
    private func handleReadable() {
        var buf = [UInt8](repeating: 0, count: 1024)
        let bufCapacity = buf.count
        var from = sockaddr_in()
        var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = buf.withUnsafeMutableBytes { raw -> Int in
            withUnsafeMutablePointer(to: &from) { fromPtr in
                fromPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    recvfrom(sock, raw.baseAddress!, bufCapacity, 0, saPtr, &fromLen)
                }
            }
        }
        guard n >= 4, Self.isDiscoverRequest(Array(buf[0..<n])) else { return }
        // inet_ntoa's static buffer is safe here — handleReadable() only ever runs serially on
        // `queue` (the read source's own target queue), never concurrently with itself.
        let fromIP = String(cString: inet_ntoa(from.sin_addr))
        glog("[VirtualTuner] UDP discovery request from \(fromIP):\(UInt16(bigEndian: from.sin_port)) — replying with DeviceID=\(String(format: "%08X", advertisedDeviceID)) BaseURL=\(advertisedBaseURL)")
        let pkt = Self.buildDiscoverReply(deviceID: advertisedDeviceID, baseURL: advertisedBaseURL,
                                           tunerCount: advertisedTunerCount)

        pkt.withUnsafeBytes { raw in
            withUnsafePointer(to: from) { fromPtr in
                fromPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    _ = sendto(sock, raw.baseAddress!, pkt.count, 0, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    /// Pure, byte-for-byte match of a real DISCOVER_REQUEST's leading type field (0x0002,
    /// big-endian) — as loose as mock_hdhr.py's own reference implementation, no TLV/CRC parsing of
    /// the request itself. Extracted from handleReadable() as a free function of just the bytes so
    /// it's unit-testable without a live socket (see VirtualTunerServiceTests.swift).
    static func isDiscoverRequest(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 4 && bytes[0] == 0x00 && bytes[1] == 0x02
    }

    /// Pure builder for the DISCOVER_REPLY (type 0x0003). TLV set and order (DeviceType, DeviceID,
    /// BaseURL, TunerCount, LineupURL) match a real EXTEND's actual reply byte-for-byte, live-
    /// captured 2026-09-02 via a raw discovery probe against DeviceID 105404BE — ground truth, not
    /// a guess at the libhdhomerun wire format. That capture also carries a DeviceAuth (0x2B) TLV;
    /// this relay has no such secret to advertise (it's not a real tuner with cloud-guide access)
    /// so it's omitted rather than faked — tried as a synthetic placeholder during a 2026-09-03
    /// Channels DVR compatibility investigation (see FAILED_APPROACHES.md) and reverted when it
    /// didn't change that client's behavior at all.
    ///
    /// `baseURL`/`tunerCount` empty/zero (the defaults) produce a reply usable only for the invalid-
    /// deviceID early-exit test path, never a real advertisement — every real call site
    /// (AppState.updateVirtualTunerPresence) always supplies both. Extracted from handleReadable()
    /// for the same unit-testability reason as isDiscoverRequest(_:) above.
    static func buildDiscoverReply(deviceID: UInt32, baseURL: String = "", tunerCount: UInt8 = 0) -> [UInt8] {
        var payload: [UInt8] = [0x01, 0x04, 0x00, 0x00, 0x00, 0x01]   // DeviceType = tuner (0x00000001)
        payload += [0x02, 0x04] + withUnsafeBytes(of: deviceID.bigEndian) { Array($0) }   // DeviceID
        let baseURLBytes = Array(baseURL.utf8.prefix(255))
        payload += [0x2A, UInt8(baseURLBytes.count)] + baseURLBytes                        // BaseURL
        payload += [0x10, 0x01, tunerCount]                                                // TunerCount
        let lineupURLBytes = Array("\(baseURL)/lineup.json".utf8.prefix(255))
        payload += [0x27, UInt8(lineupURLBytes.count)] + lineupURLBytes                    // LineupURL

        var pkt: [UInt8] = [0x00, 0x03, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)] + payload
        let crc = crc32(pkt)
        pkt += withUnsafeBytes(of: crc.littleEndian) { Array($0) }
        return pkt
    }

    /// Fallback generator only, as of 2026-09-03 — see `relayDeviceID(sourceDeviceID:)` below for
    /// the primary path and the reasoning behind why it exists.
    ///
    /// Distinct from any real DeviceID and from this project's own FFFF0001 fake EXTEND test
    /// device (an unrelated sentinel — see project memory): "FEED" isn't a value any real
    /// SiliconDust allocation uses. The suffix mixes this Mac's own hostname (crc32, reusing the
    /// existing routine rather than adding a second one) with a fresh random value on every call, so
    /// this fallback path alone still can't collide across two different Macs or return the same ID
    /// twice.
    static func makeDeviceID() -> String {
        let host = ProcessInfo.processInfo.hostName
        let hostHash = crc32(Array(host.utf8)) & 0xFFFF
        let session = UInt32.random(in: 0...0xFFFF)
        let suffix = hostHash ^ session
        return String(format: "FEED%04X", suffix)
    }

    /// The virtual tuner's advertised DeviceID for a relay session — stable and deterministic per
    /// source tuner (2026-09-03, explicit user request) instead of a fully random ID minted fresh
    /// on every relay restart, replacing a fresh random ID that left yet another
    /// now-permanently-unavailable `FEED####` entry behind in every other instance's device list on
    /// every relay restart (a plain relaunch during dev testing, or just normal daily recording
    /// start/stop), with nothing to ever clean them up — see `AppState.probeForNewDevices()`'s
    /// stale-device pruning (`deviceUnavailableSince`/`staleDeviceForgetAfter`) for the other half
    /// of that same fix. Reusing the same ID across sessions is safe here specifically *because* it
    /// depends only on the source tuner's own DeviceID, which never changes between sessions either
    /// — a client sees a consistent "the relay for tuner X" identity across restarts instead of a
    /// series of arbitrary, unrelated-looking session markers.
    ///
    /// **Not literally `"<sourceDeviceID>_Relay"`** — an earlier version of this function did
    /// exactly that and shipped briefly the same day, but `VirtualTunerService.start(deviceID:)`
    /// parses this string via `UInt32(deviceID, radix: 16)` to build the real UDP wire protocol's
    /// binary DeviceID TLV (`docs/VirtualTunerService.md`'s "Wire protocol" section) — a
    /// non-hex-suffixed string isn't valid hex, so `start()` rejected it outright and the relay
    /// failed to bind at all, caught live within minutes via `"invalid deviceID ... — not
    /// starting"` in the log, mid-recording. A `u32` has exactly 8 hex digits of room, full stop —
    /// no format lets a DeviceID carry more than that.
    ///
    /// **`"FEED" + the source's own last 4 hex digits`** — same 4-digit `FEED` sentinel prefix
    /// `makeDeviceID()` already uses (2026-09-03: kept deliberately, rather than trimming it to a
    /// 2-digit `"FE"` marker to show more of the source's digits, a version of this function briefly
    /// carried — for one consistent "known-fake" brand across every DeviceID this app ever mints,
    /// real or relay, instead of two slightly different reserved prefixes). Spends 4 of the 8
    /// available digits on that marker, leaving room for the source's own last 4
    /// (`105404BE` → `FEED04BE`). Never collides with the source's own DeviceID (a real device's
    /// own ID starting with `FEED` would be exactly as surprising as one starting `FE` alone), so
    /// nothing keying a device dictionary by DeviceID (including this app's own
    /// `AppState.devices`/`lineups`/etc.) can confuse the two. The human-readable "which real tuner
    /// is this relaying" connection lives primarily in `FriendlyName`
    /// (`"<source>-Relay"`, `WebServer.buildVirtualTunerDiscoverJSON`) — a free-text field with no
    /// hex constraint — the last-4-digits match here is a bonus, not the primary signal.
    ///
    /// Falls back to `makeDeviceID()`'s random scheme when `sourceDeviceID` is nil or isn't exactly
    /// an 8-hex-digit value itself (no show is recording, or its `hdhr_record` device was somehow
    /// never discovered, or was only ever UDP-discovered with some other ID shape — shouldn't
    /// happen in practice, since this is only ever called from
    /// `AppState.updateVirtualTunerPresence()`'s `isRecording`-gated branch against a real,
    /// HTTP-discovered device).
    static func relayDeviceID(sourceDeviceID: String?) -> String {
        guard let sourceDeviceID, sourceDeviceID.count == 8,
              UInt32(sourceDeviceID, radix: 16) != nil
        else { return makeDeviceID() }
        return "FEED\(sourceDeviceID.suffix(4).uppercased())"
    }
}
