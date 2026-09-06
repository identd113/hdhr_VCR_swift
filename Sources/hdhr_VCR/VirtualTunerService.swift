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
    // True only while this instance actually has a relay to advertise — guards handleReadable()'s
    // reply-to-a-request branch so a socket bound purely for beginPassiveListening() (see its own
    // doc comment) never answers a real discovery probe with stale/zeroed-out advertised fields.
    private var isAdvertising = false

    // Called (on `queue`) whenever an unsolicited DISCOVER_REPLY-shaped packet arrives from
    // somewhere other than this instance's own relay — see handleReadable()'s own comment on the
    // self-filter. AppState sets this once, at startup, to trigger an immediate probeForNewDevices()
    // instead of waiting for the next idle-loop tick — see AppState.init()'s own wiring.
    var onFeedAnnounce: ((String) -> Void)?

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
    /// than leaving the HTTP JSON routes advertising a "live" relay no UDP client can discover. In
    /// practice this fires `true` immediately in the overwhelmingly common case, since
    /// `AppState.init()`'s unconditional `beginPassiveListening()` call already bound the socket
    /// well before any show ever starts recording — `bindSocketIfNeeded`'s "already bound" fast path
    /// (see its own doc comment) still reports success rather than silently skipping the callback.
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
            self.isAdvertising = true
            guard self.bindSocketIfNeeded(onBindResult: onBindResult) else { return }
            glog("[VirtualTuner] started, DeviceID=\(deviceID)")
            onBindResult?(true)
            self.broadcastAnnounce()
        }
    }

    /// Binds the discovery socket if it isn't already bound, *without* advertising anything — used
    /// so this instance can passively receive other instances' unsolicited FEED announces (see
    /// `onFeedAnnounce`) even while it has no relay of its own running. Called once, unconditionally,
    /// at app startup (`AppState.init()`), independent of `start()`/`stop()`'s own relay lifecycle.
    /// A later `start(deviceID:)` call reuses this same already-bound socket (its own `guard
    /// self.sock < 0` early-exit, now inside `bindSocketIfNeeded`) rather than rebinding — exactly
    /// one socket per process ever binds :65001, deliberately: two sockets on the same host both
    /// bound there (this passive listener plus a separately-relaying instance's own responder) would
    /// let SO_REUSEPORT's per-flow hash silently route some real discovery requests to whichever
    /// socket isn't actually advertising, dropping them.
    func beginPassiveListening() {
        queue.async { [weak self] in
            _ = self?.bindSocketIfNeeded(onBindResult: nil)
        }
    }

    /// Must be called on `queue`. Returns whether the socket is bound (either just now, or already
    /// was) — false only on a genuine socket()/bind() failure. Shared by start() (which then also
    /// sets the advertised fields) and beginPassiveListening() (which leaves them untouched).
    private func bindSocketIfNeeded(onBindResult: ((Bool) -> Void)?) -> Bool {
        guard sock < 0 else { return true }   // already bound

        let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard s >= 0 else {
            glog("[VirtualTuner] socket() failed errno=\(errno) — discovery responder disabled", level: .warning)
            onBindResult?(false)
            return false
        }
        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        // Needed to send() this same socket's own unsolicited announce() broadcasts below — every
        // other use of this socket (replying to a specific requester) is unicast and never needed it.
        setsockopt(s, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
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
            return false
        }
        sock = s
        let source = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        source.setEventHandler { [weak self] in self?.handleReadable() }
        source.setCancelHandler { Darwin.close(s) }
        source.resume()
        readSource = source
        return true
    }

    /// Stops actively advertising a relay — a later discovery request gets no reply until `start()`
    /// is called again. Deliberately does NOT close the socket: it stays bound (and keeps receiving
    /// other instances' FEED announces via `onFeedAnnounce`) for the app's whole lifetime, same as
    /// beginPassiveListening()'s own reasoning. Safe to call when not currently advertising.
    func stop() {
        queue.async { [weak self] in
            guard let self, self.isAdvertising else { return }
            // One last announce reflecting the relay that's going away, before clearing the fields
            // it's built from — gives another instance's listener an immediate nudge to re-probe
            // (which will correctly find this device gone) instead of waiting up to ~10s for its
            // next idle-loop tick.
            self.broadcastAnnounce()
            self.isAdvertising = false
            self.advertisedDeviceID = 0
            self.advertisedBaseURL = ""
            self.advertisedTunerCount = 0
            glog("[VirtualTuner] stopped advertising (socket stays bound for passive listening)")
        }
    }

    /// Broadcasts the currently-advertised DISCOVER_REPLY unsolicited (to every active interface's
    /// subnet-directed broadcast plus the global fallback — reusing HDHRManager's own target list so
    /// this doesn't duplicate that logic) instead of unicasting it to a specific requester, so any
    /// other hdhrVCRplus instance's passive listener (see beginPassiveListening()) learns about a
    /// FEED appearing/changing/disappearing immediately rather than only on its next periodic
    /// discovery poll. Must be called on `queue`, with the socket already bound and something
    /// actually advertised — both call sites (start()/stop() above) already guarantee this.
    private func broadcastAnnounce() {
        guard sock >= 0, isAdvertising else { return }
        let pkt = Self.buildDiscoverReply(deviceID: advertisedDeviceID, baseURL: advertisedBaseURL,
                                           tunerCount: advertisedTunerCount)
        var targets = HDHRManager.subnetBroadcastAddresses(interface: "")
        targets.append(0xFFFFFFFF)   // INADDR_BROADCAST fallback — mirrors udpDiscoverSync's own reasoning
        for targetAddr in targets {
            var dst = sockaddr_in()
            dst.sin_family = sa_family_t(AF_INET)
            dst.sin_port = in_port_t(65001).bigEndian
            dst.sin_addr.s_addr = targetAddr
            pkt.withUnsafeBytes { raw in
                withUnsafePointer(to: dst) { dstPtr in
                    dstPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                        _ = sendto(sock, raw.baseAddress!, pkt.count, 0, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
        glog("[VirtualTuner] announced DeviceID=\(String(format: "%08X", advertisedDeviceID)) unsolicited to \(targets.count) broadcast target(s)")
    }

    // Runs on `queue` (the read source's target queue). Two shapes of inbound packet matter:
    //  - A discovery request (type 0x0002, mock_hdhr.py-loose validation) — replied to unicast with
    //    a DISCOVER_REPLY, same as always, but only while `isAdvertising` (a socket bound purely by
    //    beginPassiveListening() must never answer with stale/zeroed-out fields).
    //  - An unsolicited DISCOVER_REPLY (type 0x0003) from somewhere other than this instance's own
    //    relay — another hdhrVCRplus instance's broadcastAnnounce() — self-filtered by DeviceID (a
    //    broadcast can loop back to the sender's own socket on some setups) and forwarded to
    //    onFeedAnnounce so AppState can refresh immediately instead of waiting for its next poll.
    // Anything else (malformed, or a reply this instance itself just sent) is silently ignored.
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
        guard n >= 4 else { return }
        let bytes = Array(buf[0..<n])
        // inet_ntoa's static buffer is safe here — handleReadable() only ever runs serially on
        // `queue` (the read source's own target queue), never concurrently with itself.
        let fromIP = String(cString: inet_ntoa(from.sin_addr))

        if Self.isDiscoverRequest(bytes) {
            guard isAdvertising else { return }
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
            return
        }

        if Self.isDiscoverReply(bytes), let announcedID = Self.deviceID(fromReplyPacket: bytes) {
            guard !(isAdvertising && announcedID == advertisedDeviceID) else { return }   // our own broadcast looped back
            let hex = String(format: "%08X", announcedID)
            glog("[VirtualTuner] unsolicited FEED announce from \(fromIP) DeviceID=\(hex)")
            onFeedAnnounce?(hex)
        }
    }

    /// Pure, byte-for-byte match of a real DISCOVER_REQUEST's leading type field (0x0002,
    /// big-endian) — as loose as mock_hdhr.py's own reference implementation, no TLV/CRC parsing of
    /// the request itself. Extracted from handleReadable() as a free function of just the bytes so
    /// it's unit-testable without a live socket (see VirtualTunerServiceTests.swift).
    static func isDiscoverRequest(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 4 && bytes[0] == 0x00 && bytes[1] == 0x02
    }

    /// Pure match of a DISCOVER_REPLY's leading type field (0x0003, big-endian) — the shape
    /// broadcastAnnounce() broadcasts unsolicited and handleReadable() must recognize on the receiving
    /// end. Same looseness as isDiscoverRequest(_:) above (length + type only, no CRC check).
    static func isDiscoverReply(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 4 && bytes[0] == 0x00 && bytes[1] == 0x03
    }

    /// Extracts the DeviceID TLV (tag 0x02, 4 bytes, big-endian) from a DISCOVER_REPLY packet's
    /// payload, or nil if malformed/absent. Pure inverse of buildDiscoverReply's own DeviceID
    /// encoding, extracted for the same unit-testability reason as isDiscoverRequest(_:).
    static func deviceID(fromReplyPacket bytes: [UInt8]) -> UInt32? {
        guard bytes.count >= 4 else { return nil }
        let payloadLen = Int(bytes[2]) << 8 | Int(bytes[3])
        let end = min(4 + payloadLen, bytes.count)
        var off = 4
        while off + 2 <= end {
            let tag = bytes[off], len = Int(bytes[off + 1])
            off += 2
            guard off + len <= end else { return nil }
            if tag == 0x02, len == 4 {
                return (UInt32(bytes[off]) << 24) | (UInt32(bytes[off + 1]) << 16)
                     | (UInt32(bytes[off + 2]) << 8) | UInt32(bytes[off + 3])
            }
            off += len
        }
        return nil
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
