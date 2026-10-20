import Foundation

// Over-the-air guide (docs: overtime/README.md, overtime/APP_PLAN.md). Decodes the ATSC 1.0 PSIP tables (A/65) that every
// station broadcasts inside its multiplex: channel names and numbers (TVCT), titles/times/ratings (EIT), descriptions (ETT)
// and the broadcast clock (STT). Pure data in, pure data out: no network, no files, no main actor, so it is unit-tested with a
// captured fixture and can be fed straight from a tuner stream a chunk at a time (the raw multiplex is never stored).

/// One virtual channel announced by a multiplex.
struct OTAChannel: Equatable, Sendable {
    var name: String
    var major: Int
    var minor: Int
    var program: Int
    var sourceId: Int
    /// 2 = digital TV, 3 = audio, 4 = data.
    var serviceType: Int
    var hidden: Bool
    var accessControlled: Bool
    var number: String { "\(major).\(minor)" }
}

/// One program in a channel's schedule.
struct OTAEvent: Equatable, Sendable {
    var sourceId: Int
    var eventId: Int
    var start: Date
    var lengthSeconds: Int
    var title: String
    /// Content advisory text such as "TV-PG", or "".
    var rating: String
    /// Extended description (ETT), or "".
    var description: String
    var end: Date { start.addingTimeInterval(TimeInterval(lengthSeconds)) }
}

struct OTADecodeResult: Equatable, Sendable {
    var broadcastTime: Date?
    var gpsUTCOffset: Int
    var channels: [OTAChannel]
    var events: [OTAEvent]
    /// How many guide tables the Master Guide Table announced (0 = this station sends no guide).
    var announcedEITCount: Int
}

/// Streaming PSIP decoder. Feed it transport-stream bytes in any chunk size with `ingest(_:)`; read the picture so far with
/// `result()`. Only the PIDs that can carry PSIP are looked at (the base PID, then the guide PIDs the Master Guide Table names).
final class PSIPDecoder {
    static let basePID = 0x1FFB
    private static let gpsEpoch: TimeInterval = 315_964_800   // 1980-01-06 as a Unix time

    private var carry = [UInt8]()                       // bytes of an unfinished 188-byte packet
    private var assemblers: [Int: [UInt8]] = [:]        // PID -> section being assembled
    private var wanted: Set<Int> = [PSIPDecoder.basePID]
    private var gotMGT = false
    private var announcedEIT = 0
    private var channelsBySource: [Int: OTAChannel] = [:]
    private var gps: (seconds: UInt32, leap: Int)?
    private var events: [EventKey: Event] = [:]
    private var descriptions: [EventKey: String] = [:]
    private var seenSections: Set<SectionKey> = []

    private struct EventKey: Hashable { let sourceId: Int; let eventId: Int }
    private struct SectionKey: Hashable { let pid: Int; let table: Int; let extra: Int; let version: Int; let number: Int }
    private struct Event { var startGPS: UInt32; var length: Int; var title: String; var rating: String }

    init() {}

    /// True once the Master Guide Table has been seen (so a caller knows whether waiting longer can help).
    var hasMasterGuide: Bool { gotMGT }

    func ingest(_ data: Data) {
        carry.append(contentsOf: data)
        var i = 0
        let n = carry.count
        while i + 188 <= n {
            if carry[i] != 0x47 {   // lost sync: skip to the next position where a packet start repeats 188 bytes later
                var j = i + 1
                while j + 188 < n, !(carry[j] == 0x47 && carry[j + 188] == 0x47) { j += 1 }
                if j + 188 >= n { break }
                i = j
                continue
            }
            handlePacket(at: i)
            i += 188
        }
        carry.removeFirst(i)
    }

    // MARK: packets → sections

    private func handlePacket(at i: Int) {
        let pid = (Int(carry[i + 1] & 0x1F) << 8) | Int(carry[i + 2])
        guard wanted.contains(pid), carry[i + 3] & 0x10 != 0 else { return }   // not ours, or no payload
        var p = i + 4
        if carry[i + 3] & 0x20 != 0 { p += 1 + Int(carry[i + 4]) }              // adaptation field
        guard p < i + 188 else { return }
        let payload = carry[p..<(i + 188)]
        if carry[i + 1] & 0x40 != 0 {   // payload unit start: a pointer field, the tail of the previous section, then a new one
            let pointer = Int(payload[payload.startIndex])
            let bodyStart = payload.startIndex + 1
            guard bodyStart + pointer <= payload.endIndex else { assemblers[pid] = nil; return }
            if pointer > 0, var open = assemblers[pid] {
                open.append(contentsOf: payload[bodyStart..<(bodyStart + pointer)])
                assemblers[pid] = open
                drain(pid)
            }
            assemblers[pid] = Array(payload[(bodyStart + pointer)...])
            drain(pid)
        } else if assemblers[pid] != nil {
            assemblers[pid]!.append(contentsOf: payload)
            drain(pid)
        }
    }

    /// Pops every complete, CRC-valid section off the front of the PID's buffer.
    private func drain(_ pid: Int) {
        while let buf = assemblers[pid], buf.count >= 3 {
            if buf[0] == 0xFF { assemblers[pid] = []; return }   // stuffing
            let length = 3 + ((Int(buf[1] & 0x0F) << 8) | Int(buf[2]))
            guard buf.count >= length else { return }
            let section = Array(buf[0..<length])
            assemblers[pid] = Array(buf[length...])
            if Self.crc32(section) == 0 { handle(section: section, pid: pid) }
        }
    }

    // MARK: sections

    private func handle(section s: [UInt8], pid: Int) {
        guard s.count >= 12 else { return }
        let table = Int(s[0])
        let key = SectionKey(pid: pid, table: table, extra: (Int(s[3]) << 8) | Int(s[4]), version: Int(s[5] & 0x3E), number: Int(s[6]))
        switch table {
        case 0xC7: parseMGT(s)
        case 0xC8: parseTVCT(s)
        case 0xCD: parseSTT(s)
        case 0xCB, 0xCC:
            guard seenSections.insert(key).inserted else { return }   // a table repeats every second or so: decode each version once
            if table == 0xCB { parseEIT(s) } else { parseETT(s) }
        default: break
        }
    }

    private func parseMGT(_ s: [UInt8]) {
        guard !gotMGT, s.count >= 11 else { return }
        let count = (Int(s[9]) << 8) | Int(s[10])
        var pos = 11
        var pids: Set<Int> = []
        var eit = 0
        for _ in 0..<count {
            guard pos + 11 <= s.count else { break }
            let type = (Int(s[pos]) << 8) | Int(s[pos + 1])
            let tablePID = (Int(s[pos + 2] & 0x1F) << 8) | Int(s[pos + 3])
            let descriptorsLength = (Int(s[pos + 9] & 0x0F) << 8) | Int(s[pos + 10])
            if (0x0100...0x017F).contains(type) { pids.insert(tablePID); eit += 1 }   // EIT-0 … EIT-127
            if (0x0200...0x027F).contains(type) { pids.insert(tablePID) }               // ETT-0 … ETT-127
            pos += 11 + descriptorsLength
        }
        gotMGT = true
        announcedEIT = eit
        wanted.formUnion(pids)
    }

    private func parseTVCT(_ s: [UInt8]) {
        guard s.count > 10 else { return }
        let count = Int(s[9])
        var pos = 10
        for _ in 0..<count {
            guard pos + 32 <= s.count else { break }
            let nameBytes = Data(s[pos..<(pos + 14)])
            let name = (String(data: nameBytes, encoding: .utf16BigEndian) ?? "").replacingOccurrences(of: "\u{0}", with: "").trimmingCharacters(in: .whitespaces)
            let major = (Int(s[pos + 14] & 0x0F) << 6) | (Int(s[pos + 15]) >> 2)
            let minor = (Int(s[pos + 15] & 0x03) << 8) | Int(s[pos + 16])
            let program = (Int(s[pos + 24]) << 8) | Int(s[pos + 25])
            let flags = (Int(s[pos + 26]) << 8) | Int(s[pos + 27])
            let sourceId = (Int(s[pos + 28]) << 8) | Int(s[pos + 29])
            let descriptorsLength = (Int(s[pos + 30] & 0x03) << 8) | Int(s[pos + 31])
            channelsBySource[sourceId] = OTAChannel(
                name: name, major: major, minor: minor, program: program, sourceId: sourceId,
                serviceType: flags & 0x3F, hidden: flags & 0x1000 != 0, accessControlled: flags & 0x2000 != 0)
            pos += 32 + descriptorsLength
        }
    }

    private func parseSTT(_ s: [UInt8]) {
        guard gps == nil, s.count >= 14 else { return }
        let secs = (UInt32(s[9]) << 24) | (UInt32(s[10]) << 16) | (UInt32(s[11]) << 8) | UInt32(s[12])
        gps = (secs, Int(s[13]))
    }

    private func parseEIT(_ s: [UInt8]) {
        guard s.count > 10 else { return }
        let sourceId = (Int(s[3]) << 8) | Int(s[4])
        let count = Int(s[9])
        var pos = 10
        for _ in 0..<count {
            guard pos + 12 <= s.count else { break }
            let eventId = (Int(s[pos] & 0x3F) << 8) | Int(s[pos + 1])
            let start = (UInt32(s[pos + 2]) << 24) | (UInt32(s[pos + 3]) << 16) | (UInt32(s[pos + 4]) << 8) | UInt32(s[pos + 5])
            let length = (Int(s[pos + 6] & 0x0F) << 16) | (Int(s[pos + 7]) << 8) | Int(s[pos + 8])
            let titleLength = Int(s[pos + 9])
            guard pos + 10 + titleLength + 2 <= s.count else { break }
            let title = Self.multipleString(Array(s[(pos + 10)..<(pos + 10 + titleLength)]))
            pos += 10 + titleLength
            let descriptorsLength = (Int(s[pos] & 0x0F) << 8) | Int(s[pos + 1])
            guard pos + 2 + descriptorsLength <= s.count else { break }
            let rating = Self.rating(in: Array(s[(pos + 2)..<(pos + 2 + descriptorsLength)]))
            pos += 2 + descriptorsLength
            events[EventKey(sourceId: sourceId, eventId: eventId)] = Event(startGPS: start, length: length, title: title, rating: rating)
        }
    }

    private func parseETT(_ s: [UInt8]) {
        guard s.count >= 17 else { return }
        let etm = (UInt32(s[9]) << 24) | (UInt32(s[10]) << 16) | (UInt32(s[11]) << 8) | UInt32(s[12])
        guard etm & 0x3 == 2 else { return }   // an event ETT (not a channel ETT)
        let key = EventKey(sourceId: Int((etm >> 16) & 0xFFFF), eventId: Int((etm >> 2) & 0x3FFF))
        descriptions[key] = Self.multipleString(Array(s[13..<(s.count - 4)]))
    }

    // MARK: A/65 text

    /// Multiple string structure → its first string. Huffman-compressed strings (rare in the US) come back as "".
    static func multipleString(_ b: [UInt8]) -> String {
        guard let strings = b.first, strings > 0 else { return "" }
        var pos = 1
        guard pos + 4 <= b.count else { return "" }
        pos += 3                                  // ISO 639 language
        let segments = Int(b[pos]); pos += 1
        var text = ""
        for _ in 0..<segments {
            guard pos + 3 <= b.count else { break }
            let compression = b[pos], mode = b[pos + 1], count = Int(b[pos + 2])
            pos += 3
            guard pos + count <= b.count else { break }
            let raw = Array(b[pos..<(pos + count)]); pos += count
            guard compression == 0 else { continue }
            switch mode {
            case 0x00: text += String(raw.map { Character(Unicode.Scalar($0)) })   // U+0000–U+00FF (ASCII / Latin-1)
            case 0x3F: text += String(data: Data(raw), encoding: .utf16BigEndian) ?? ""
            default: text += String(raw.compactMap { Unicode.Scalar((UInt32(mode) << 8) | UInt32($0)).map(Character.init) })
            }
        }
        return text
    }

    /// Content advisory descriptor (0x87): the first rating text found ("TV-PG"), or "".
    static func rating(in descriptors: [UInt8]) -> String {
        var pos = 0
        while pos + 2 <= descriptors.count {
            let tag = descriptors[pos], length = Int(descriptors[pos + 1])
            guard pos + 2 + length <= descriptors.count else { break }
            if tag == 0x87, length > 0 {
                let body = Array(descriptors[(pos + 2)..<(pos + 2 + length)])
                let regions = Int(body[0] & 0x3F)
                var p = 1
                for _ in 0..<regions {
                    guard p + 2 <= body.count else { break }
                    let dimensions = Int(body[p + 1]); p += 2
                    for _ in 0..<dimensions { guard p + 2 <= body.count else { break }; p += 2 }
                    guard p < body.count else { break }
                    let textLength = Int(body[p]); p += 1
                    guard p + textLength <= body.count else { break }
                    let text = multipleString(Array(body[p..<(p + textLength)]))
                    if !text.isEmpty { return text }
                    p += textLength
                }
            }
            pos += 2 + length
        }
        return ""
    }

    // MARK: result

    func result() -> OTADecodeResult {
        let leap = gps?.leap ?? 18
        func date(_ gpsSeconds: UInt32) -> Date { Date(timeIntervalSince1970: Self.gpsEpoch + TimeInterval(gpsSeconds) - TimeInterval(leap)) }
        let out: [OTAEvent] = events.map { key, e in
            OTAEvent(sourceId: key.sourceId, eventId: key.eventId, start: date(e.startGPS), lengthSeconds: e.length,
                     title: e.title, rating: e.rating, description: descriptions[key] ?? "")
        }.sorted { ($0.sourceId, $0.start) < ($1.sourceId, $1.start) }
        let channels = channelsBySource.values.sorted { ($0.major, $0.minor) < ($1.major, $1.minor) }
        return OTADecodeResult(broadcastTime: gps.map { date($0.seconds) }, gpsUTCOffset: leap,
                               channels: channels, events: out, announcedEITCount: announcedEIT)
    }

    // MARK: CRC-32/MPEG-2

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i) << 24
        for _ in 0..<8 { c = (c & 0x8000_0000 != 0) ? (c << 1) ^ 0x04C1_1DB7 : (c << 1) }
        return c
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes { crc = (crc << 8) ^ crcTable[Int((crc >> 24) ^ UInt32(b)) & 0xFF] }
        return crc
    }
}
