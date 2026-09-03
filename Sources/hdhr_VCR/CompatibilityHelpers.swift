import SwiftUI
import Darwin

// MARK: - CRC-32

// IEEE 802.3 / ISO 3309 (polynomial 0xEDB88320) — shared by HDHRManager's UDP discovery packet
// trailer and WebServer's gzip response trailer. Both are cold paths (once per discovery packet,
// once per gzip response), so a table-driven scalar loop is plenty; no need for Data's
// withUnsafeBytes fast path here.
private let crc32Table: [UInt32] = (0..<256).map { i in
    var c = UInt32(i)
    for _ in 0..<8 { c = (c & 1) == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    return c
}

func crc32<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
    var c: UInt32 = 0xFFFF_FFFF
    for b in bytes { c = crc32Table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
    return c ^ 0xFFFF_FFFF
}

// MARK: - MPEG-TS video codec detection

// PMT stream_type values this app cares about distinguishing — MPEG-1/2 video vs. H.264/HEVC.
// See docs/HDHRFindings.md's transcode-profile findings (verified live 2026-07-18): every profile
// — including "none" — is an MPEG-TS container; only the video stream_type inside it changes.
enum MPEGVideoStreamType {
    static let mpeg1Video: UInt8 = 0x01
    static let mpeg2Video: UInt8 = 0x02
    static let h264:       UInt8 = 0x1b
    static let hevc:       UInt8 = 0x24
    /// True for a codec the virtual-tuner relay's transcode step would produce nothing new by
    /// re-encoding into — i.e. it's already H.264/HEVC, so transcoding it again would just spend
    /// CPU for a quality loss with no format benefit. See WebServer.handleVirtualTunerStream.
    static func isAlreadyModernCodec(_ streamType: UInt8) -> Bool { streamType == h264 || streamType == hevc }

    /// Same question, for `LineupEntry.VideoCodec`'s own string form ("MPEG2"/"H264" confirmed live
    /// against a real device's /lineup.json 2026-09-02 — see that property's own doc comment).
    /// Case-insensitive: nothing in what's actually been observed pins the exact casing down as
    /// contractual, and a couple of spelling variants are included defensively since this field
    /// isn't documented by SiliconDust anywhere this project has found.
    static func isAlreadyModernCodec(_ videoCodec: String) -> Bool {
        switch videoCodec.uppercased() {
        case "H264", "H.264", "AVC", "HEVC", "H265", "H.265": return true
        default: return false
        }
    }
}

/// Scans a byte buffer (188-byte MPEG-TS packets, sync byte `0x47`) for the PAT (PID 0) to find the
/// program's PMT PID, then the PMT for the first video elementary stream's `stream_type` byte
/// (`MPEGVideoStreamType`). Returns nil if the buffer doesn't contain a complete PAT+PMT pair yet
/// (e.g. too little of the file has been scanned) or isn't a transport stream at all. Pulled out of
/// `TranscodeStreamFormatTests.swift` (2026-07-18's live-captured PAT/PMT ground truth) into
/// production code so the virtual-tuner relay's real-source-codec check (`WebServer.swift`) and
/// that test's own fixture assertions share exactly one parser — see `Tests/hdhr_VCRTests/Models/
/// TranscodeStreamFormatTests.swift` for the byte-level field-offset reasoning this follows.
func mpegTSVideoStreamType(_ data: [UInt8]) -> UInt8? {
    guard data.count >= 189, data[0] == 0x47, data[188] == 0x47 else { return nil }

    // Pass 1 — PAT (PID 0): collect the program's PMT PID(s). Reads the PID straight out of `data`
    // (not a sliced `pkt` array) for every packet, since the overwhelming majority of packets in a
    // multiplex aren't PID 0 — only materializing an Array once a PID match is confirmed avoids
    // paying for a 188-byte copy (up to ~11,000 times for the default 2MB scan) that's almost always
    // thrown away unread. Breaks as soon as a PAT packet actually yields a PMT PID — a real
    // broadcast repeats the PAT identically every ~100ms (see mpegTSVideoStreamType(inFileAt:)'s own
    // doc comment), so the first hit already has everything pass 1 needs; scanning the rest of a
    // multi-megabyte buffer for more PAT repeats would just re-derive the same PID set.
    var pmtPIDs = Set<Int>()
    var idx = 0
    while idx + 188 <= data.count {
        let base = idx
        idx += 188
        let pid = (Int(data[base + 1] & 0x1f) << 8) | Int(data[base + 2])
        guard pid == 0, data[base + 1] & 0x40 != 0 else { continue }   // PID 0 + payload-unit-start
        let pkt = Array(data[base..<base + 188])
        let p = 4 + 1 + Int(pkt[4])                            // skip TS header + pointer field
        guard p + 3 <= pkt.count else { continue }
        let sectionLen = (Int(pkt[p + 1] & 0x0f) << 8) | Int(pkt[p + 2])
        var i = p + 8                                          // first program entry
        let end = p + 3 + sectionLen - 4                       // minus CRC32
        while i + 4 <= end, i + 4 <= pkt.count {
            let programNum = (Int(pkt[i]) << 8) | Int(pkt[i + 1])
            let mapPID = (Int(pkt[i + 2] & 0x1f) << 8) | Int(pkt[i + 3])
            if programNum != 0 { pmtPIDs.insert(mapPID) }
            i += 4
        }
        if !pmtPIDs.isEmpty { break }
    }
    guard !pmtPIDs.isEmpty else { return nil }

    // Pass 2 — PMT: first video stream_type (MPEG-1/2 video, H.264, or HEVC). Same PID-before-slice
    // ordering as pass 1 above.
    idx = 0
    while idx + 188 <= data.count {
        let base = idx
        idx += 188
        let pid = (Int(data[base + 1] & 0x1f) << 8) | Int(data[base + 2])
        guard pmtPIDs.contains(pid), data[base + 1] & 0x40 != 0 else { continue }
        let pkt = Array(data[base..<base + 188])
        let p = 4 + 1 + Int(pkt[4])
        guard p + 12 <= pkt.count else { continue }
        let sectionLen = (Int(pkt[p + 1] & 0x0f) << 8) | Int(pkt[p + 2])
        let programInfoLen = (Int(pkt[p + 10] & 0x0f) << 8) | Int(pkt[p + 11])
        var q = p + 12 + programInfoLen                       // first ES entry
        let end = p + 3 + sectionLen - 4
        while q + 5 <= end, q + 5 <= pkt.count {
            let streamType = pkt[q]
            let esInfoLen = (Int(pkt[q + 3] & 0x0f) << 8) | Int(pkt[q + 4])
            if [MPEGVideoStreamType.mpeg1Video, MPEGVideoStreamType.mpeg2Video,
                MPEGVideoStreamType.h264, MPEGVideoStreamType.hevc].contains(streamType) {
                return streamType
            }
            q += 5 + esInfoLen
        }
    }
    return nil
}

/// Reads up to `maxBytesToScan` from the start of the file at `path` and probes it for the video
/// codec via `mpegTSVideoStreamType(_:)`. A real broadcast repeats the PAT/PMT roughly every
/// 100ms, so a few hundred KB from the start of a recording is comfortably enough even if the very
/// first packets happen to land between repeats — 2MB is a generous margin, not a measured minimum.
func mpegTSVideoStreamType(inFileAt path: String, maxBytesToScan: Int = 2 * 1024 * 1024) -> UInt8? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: maxBytesToScan), !data.isEmpty else { return nil }
    return mpegTSVideoStreamType([UInt8](data))
}

struct NetworkInterfaceInfo: Identifiable {
    var id: String { name }
    let name: String
    let ip: String
    var displayLabel: String { "\(name)  \(ip)" }
}

// IFF_POINTOPOINT catches all tunnel/VPN types (utun*, cscotun*, gpd*, zt*, etc.) regardless of name prefix.
func isPointToPointInterface(_ name: String) -> Bool {
    var ptr: UnsafeMutablePointer<ifaddrs>? = nil
    guard getifaddrs(&ptr) == 0 else { return false }
    defer { freeifaddrs(ptr) }
    var cur = ptr
    while let iface = cur {
        defer { cur = iface.pointee.ifa_next }
        guard String(cString: iface.pointee.ifa_name) == name else { continue }
        return iface.pointee.ifa_flags & UInt32(IFF_POINTOPOINT) != 0
    }
    return false
}

// Returns IPv4 interfaces for the discovery/recording NIC picker.
// VPN/tunnel interfaces are admitted only if UP+RUNNING and non-link-local; loopback, AWDL, llw, gif, stf excluded.
func availableNetworkInterfaces() -> [NetworkInterfaceInfo] {
    var results: [NetworkInterfaceInfo] = []
    var ptr: UnsafeMutablePointer<ifaddrs>? = nil
    guard getifaddrs(&ptr) == 0 else { return results }
    defer { freeifaddrs(ptr) }
    var cur = ptr
    while let iface = cur {
        defer { cur = iface.pointee.ifa_next }
        guard let addr = iface.pointee.ifa_addr,
              addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
        let name = String(cString: iface.pointee.ifa_name)
        guard !name.hasPrefix("lo"), !name.hasPrefix("awdl"), !name.hasPrefix("llw"),
              !name.hasPrefix("gif"), !name.hasPrefix("stf"),
              !results.contains(where: { $0.name == name }) else { continue }
        let flags = iface.pointee.ifa_flags
        var ip = ""
        addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &sin.pointee.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
            ip = String(cString: buf)
        }
        // Point-to-point flag identifies all tunnel/VPN types regardless of name.
        if flags & UInt32(IFF_POINTOPOINT) != 0 {
            guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_RUNNING) != 0 else { continue }
            guard !ip.hasPrefix("169.254.") else { continue }
        }
        results.append(NetworkInterfaceInfo(name: name, ip: ip))
    }
    return results.sorted { $0.name < $1.name }
}


