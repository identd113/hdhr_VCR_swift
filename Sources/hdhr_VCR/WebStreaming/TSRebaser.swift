import Foundation

// Part of the web-streaming feature (docs/WebStreaming.md "Timestamp rebasing"). AVFoundation's MPEG-TS reader
// cannot read a file whose 90 kHz timestamps cross 2^32 (a recording started a few minutes before the tuner's clock
// reaches 47,721.86 s: the reader returns a handful of frames and stops). The HDHomeRun's clock runs from power-on,
// so this happens to one recording in every ~26 hours. The fix is to hand AVFoundation a copy whose timestamps start
// near zero: same packets, same pictures, every PTS/DTS/PCR moved back by one fixed amount. Pure byte patching, no
// re-encoding. Pure and I/O-free so it is unit-tested alone; `TSRebaseSpool` below does the file tailing.

struct TSRebaser {
    static let packetSize = 188
    private static let mask33: UInt64 = (1 << 33) - 1
    /// How far before the first kept picture the new timeline starts, so audio and the PCR that lead the picture stay non-negative.
    static let preroll: UInt64 = 2 * 90_000

    private var pending = [UInt8]()          // bytes of an unfinished packet from the previous call
    private var synced = false
    private var patPacket: [UInt8]?
    private var pmtPacket: [UInt8]?
    private var pmtPID: Int?
    private var videoPID: Int?
    private var videoIsH264 = false
    private var esPIDs = Set<Int>()
    private var pcrPID: Int?
    /// nil until the first keyframe has been found; everything before it is dropped.
    private(set) var offset: UInt64?
    /// Source PTS/DTS (90 kHz) of the first kept picture, for callers that want to map the new timeline back.
    private(set) var firstVideoTimestamp: UInt64?

    var hasStarted: Bool { offset != nil }

    /// Keeps the program tables but forgets any picture found so far and any half-read packet: the next bytes come from a
    /// different place in the file, and output must begin at the first keyframe after that point.
    mutating func restartPicture() {
        offset = nil; firstVideoTimestamp = nil; pending = []; synced = false
    }

    /// Feeds the next run of source bytes; returns the rebased bytes ready to append (empty until the first keyframe).
    mutating func process(_ data: [UInt8]) -> [UInt8] {
        var bytes = pending + data
        pending = []
        var out = [UInt8]()
        var i = 0
        if !synced {
            guard let s = Self.findSync(bytes) else { pending = Array(bytes.suffix(Self.packetSize * 4)); return [] }
            i = s; synced = true
        }
        while i + Self.packetSize <= bytes.count {
            if bytes[i] != 0x47 {   // lost sync (a damaged stretch): look for the next run of sync bytes
                synced = false
                guard let s = Self.findSync(Array(bytes[i...])) else { pending = Array(bytes.suffix(Self.packetSize * 4)); return out }
                i += s; synced = true
                continue
            }
            handle(&bytes, at: i, into: &out)
            i += Self.packetSize
        }
        pending = Array(bytes[i...])
        return out
    }

    /// First index where a 0x47 byte repeats at the packet stride (needs three in a row when the data allows).
    static func findSync(_ b: [UInt8]) -> Int? {
        guard b.count >= packetSize * 2 else { return nil }
        for s in 0..<min(packetSize, b.count) where b[s] == 0x47 {
            var ok = true
            var k = s + packetSize
            var checked = 0
            while k < b.count && checked < 2 { if b[k] != 0x47 { ok = false; break }; k += packetSize; checked += 1 }
            if ok && checked >= 1 { return s }
        }
        return nil
    }

    private mutating func handle(_ b: inout [UInt8], at i: Int, into out: inout [UInt8]) {
        let pid = (Int(b[i + 1] & 0x1f) << 8) | Int(b[i + 2])
        let pusi = b[i + 1] & 0x40 != 0
        let afc = (b[i + 3] >> 4) & 3
        var payload = i + 4
        if afc & 2 != 0 { payload += 1 + Int(b[i + 4]) }
        let hasPayload = afc & 1 != 0 && payload < i + Self.packetSize

        if pid == 0 && pusi && hasPayload { parsePAT(b, payload: payload, packet: Array(b[i..<i + Self.packetSize])) }
        if let p = pmtPID, pid == p && pusi && hasPayload { parsePMT(b, payload: payload, packet: Array(b[i..<i + Self.packetSize])) }

        if offset == nil {
            // Wait for the first picture that can be decoded on its own, then start the output with the tables.
            guard pid == videoPID, pusi, hasPayload, let pat = patPacket, let pmt = pmtPacket,
                  Self.startsDecodableGroup(b, payload: payload, end: i + Self.packetSize, h264: videoIsH264),
                  let stamp = Self.pesTimestamp(b, payload: payload, end: i + Self.packetSize, preferDTS: true) else { return }
            firstVideoTimestamp = stamp
            offset = stamp >= Self.preroll ? stamp - Self.preroll : stamp &+ (Self.mask33 + 1) - Self.preroll
            out += pat; out += pmt
        }
        guard let off = offset else { return }

        if afc & 2 != 0, pid == pcrPID, b[i + 4] >= 7, b[i + 5] & 0x10 != 0 {
            let base = Self.readPCR(b, at: i + 6)
            Self.writePCR(&b, at: i + 6, base: (base &+ (Self.mask33 + 1) &- off) & Self.mask33)
        }
        if pusi, hasPayload, esPIDs.contains(pid) { Self.shiftPES(&b, payload: payload, end: i + Self.packetSize, by: off) }
        out.append(contentsOf: b[i..<i + Self.packetSize])
    }

    // MARK: Tables

    private mutating func parsePAT(_ b: [UInt8], payload: Int, packet: [UInt8]) {
        let p = payload + 1 + Int(b[payload])   // pointer field
        guard p + 12 <= b.count, b[p] == 0x00 else { return }
        let len = (Int(b[p + 1] & 0x0f) << 8) | Int(b[p + 2])
        var q = p + 8
        let end = min(p + 3 + len - 4, b.count)
        while q + 4 <= end {
            let program = (Int(b[q]) << 8) | Int(b[q + 1])
            if program != 0 { pmtPID = (Int(b[q + 2] & 0x1f) << 8) | Int(b[q + 3]); patPacket = packet; return }
            q += 4
        }
    }

    private mutating func parsePMT(_ b: [UInt8], payload: Int, packet: [UInt8]) {
        let p = payload + 1 + Int(b[payload])
        guard p + 12 <= b.count, b[p] == 0x02 else { return }
        let len = (Int(b[p + 1] & 0x0f) << 8) | Int(b[p + 2])
        let end = min(p + 3 + len - 4, b.count)
        pcrPID = (Int(b[p + 8] & 0x1f) << 8) | Int(b[p + 9])
        var q = p + 12 + ((Int(b[p + 10] & 0x0f) << 8) | Int(b[p + 11]))
        var es = Set<Int>()
        var video: Int?
        var h264 = false
        while q + 5 <= end {
            let type = b[q]
            let pid = (Int(b[q + 1] & 0x1f) << 8) | Int(b[q + 2])
            es.insert(pid)
            if video == nil, type == 0x02 || type == 0x01 || type == 0x1b || type == 0x24 { video = pid; h264 = type == 0x1b || type == 0x24 }
            q += 5 + ((Int(b[q + 3] & 0x0f) << 8) | Int(b[q + 4]))
        }
        videoPID = video; videoIsH264 = h264; esPIDs = es; pmtPacket = packet
    }

    // MARK: Pictures and timestamps

    /// True when this video PES starts a group that decodes on its own: an MPEG-2 sequence header, or an H.264 SPS/IDR.
    static func startsDecodableGroup(_ b: [UInt8], payload: Int, end: Int, h264: Bool) -> Bool {
        guard payload + 9 <= end, b[payload] == 0, b[payload + 1] == 0, b[payload + 2] == 1 else { return false }
        let start = payload + 9 + Int(b[payload + 8])   // after the PES header
        var k = start
        while k + 4 <= end {
            if b[k] == 0, b[k + 1] == 0, b[k + 2] == 1 {
                let c = b[k + 3]
                if !h264 { if c == 0xb3 { return true } }
                else if c & 0x1f == 7 || c & 0x1f == 5 { return true }
            }
            k += 1
        }
        return false
    }

    /// DTS (or PTS when `preferDTS` is false or there is no DTS) of the PES whose header starts at `payload`.
    static func pesTimestamp(_ b: [UInt8], payload: Int, end: Int, preferDTS: Bool) -> UInt64? {
        guard payload + 14 <= end, b[payload] == 0, b[payload + 1] == 0, b[payload + 2] == 1, b[payload + 6] & 0xc0 == 0x80 else { return nil }
        let flags = b[payload + 7] >> 6
        guard flags & 2 != 0, Int(b[payload + 8]) >= (flags == 3 ? 10 : 5), payload + (flags == 3 ? 19 : 14) <= end else { return nil }
        if flags == 3 && preferDTS { return readTS(b, at: payload + 14) }
        return readTS(b, at: payload + 9)
    }

    /// Moves the PTS (and DTS) of the PES header at `payload` back by `off`.
    static func shiftPES(_ b: inout [UInt8], payload: Int, end: Int, by off: UInt64) {
        guard payload + 14 <= end, b[payload] == 0, b[payload + 1] == 0, b[payload + 2] == 1, b[payload + 6] & 0xc0 == 0x80 else { return }
        let flags = b[payload + 7] >> 6
        guard flags & 2 != 0, Int(b[payload + 8]) >= (flags == 3 ? 10 : 5), payload + (flags == 3 ? 19 : 14) <= end else { return }
        let wrap = mask33 + 1
        writeTS(&b, at: payload + 9, value: (readTS(b, at: payload + 9) &+ wrap &- off) & mask33)
        if flags == 3 { writeTS(&b, at: payload + 14, value: (readTS(b, at: payload + 14) &+ wrap &- off) & mask33) }
    }

    static func readTS(_ b: [UInt8], at k: Int) -> UInt64 {
        (UInt64(b[k] >> 1) & 7) << 30 | UInt64(b[k + 1]) << 22 | UInt64(b[k + 2] >> 1) << 15 | UInt64(b[k + 3]) << 7 | UInt64(b[k + 4] >> 1)
    }

    static func writeTS(_ b: inout [UInt8], at k: Int, value v: UInt64) {
        b[k] = (b[k] & 0xf1) | UInt8((v >> 29) & 0x0e)
        b[k + 1] = UInt8((v >> 22) & 0xff)
        b[k + 2] = UInt8((v >> 14) & 0xfe) | 1
        b[k + 3] = UInt8((v >> 7) & 0xff)
        b[k + 4] = UInt8((v << 1) & 0xfe) | 1
    }

    static func readPCR(_ b: [UInt8], at k: Int) -> UInt64 {
        UInt64(b[k]) << 25 | UInt64(b[k + 1]) << 17 | UInt64(b[k + 2]) << 9 | UInt64(b[k + 3]) << 1 | UInt64(b[k + 4] >> 7)
    }

    static func writePCR(_ b: inout [UInt8], at k: Int, base v: UInt64) {
        b[k] = UInt8((v >> 25) & 0xff)
        b[k + 1] = UInt8((v >> 17) & 0xff)
        b[k + 2] = UInt8((v >> 9) & 0xff)
        b[k + 3] = UInt8((v >> 1) & 0xff)
        b[k + 4] = (b[k + 4] & 0x7f) | UInt8((v & 1) << 7)
    }

    /// The first PCR (90 kHz base) in `data`, scanning packets from the first sync; nil when there is none.
    static func firstPCR(in data: [UInt8]) -> UInt64? { lastOrFirstPCR(in: data, last: false) }
    /// The last PCR (90 kHz base) in `data`.
    static func lastPCR(in data: [UInt8]) -> UInt64? { lastOrFirstPCR(in: data, last: true) }

    private static func lastOrFirstPCR(in data: [UInt8], last: Bool) -> UInt64? {
        guard let s = findSync(data) else { return nil }
        var found: UInt64?
        var i = s
        while i + packetSize <= data.count {
            if data[i] == 0x47, (data[i + 3] >> 4) & 2 != 0, data[i + 4] >= 7, data[i + 5] & 0x10 != 0 {
                found = readPCR(data, at: i + 6)
                if !last { return found }
            }
            i += packetSize
        }
        return found
    }
}

/// Tails a recording and writes a rebased copy next to the stream's other files. The follower reads the copy.
final class TSRebaseSpool: @unchecked Sendable {
    /// Most the copy may grow to (about 3 hours at 7 Mb/s): then it stops, so the stream ends instead of filling the disk.
    static let maxBytes: Int64 = 10 * 1024 * 1024 * 1024
    static let chunk = 1 << 20

    private let lock = NSLock()
    private var _drained = false
    /// True once the source has stopped growing and every byte of it has been copied.
    var drained: Bool { lock.lock(); defer { lock.unlock() }; return _drained }
    /// Marks the copy complete (also used when copying cannot continue, so the stream ends instead of waiting forever).
    func finish() { lock.lock(); _drained = true; lock.unlock() }

    let source: URL
    let destination: URL
    private let joinBehindLive: Double?
    private let sourceIsGrowing: @Sendable () -> Bool

    init(source: URL, destination: URL, joinBehindLive: Double?, sourceIsGrowing: @escaping @Sendable () -> Bool) {
        self.source = source; self.destination = destination
        self.joinBehindLive = joinBehindLive; self.sourceIsGrowing = sourceIsGrowing
    }

    /// Runs until the source stops growing and is fully copied, or the task is cancelled.
    func run() async throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let reader = try FileHandle(forReadingFrom: source)
        let writer = try FileHandle(forWritingTo: destination)
        defer { try? reader.close(); try? writer.close() }
        var rebaser = TSRebaser()
        var position: UInt64 = 0
        if let behind = joinBehindLive, sourceIsGrowing() {
            // Join near the live end: learn the program tables from the start of the file, then jump.
            _ = rebaser.process([UInt8](try reader.read(upToCount: 2 << 20) ?? Data()))
            let size = try reader.seekToEnd()
            if let begin = Self.joinOffset(reader: reader, size: size, secondsBehind: behind) {
                position = begin
                rebaser.restartPicture()
            } else {
                rebaser = TSRebaser()   // too short to measure: copy from the start
            }
        }
        var written: Int64 = 0
        while true {
            try Task.checkCancellation()
            let growing = sourceIsGrowing()
            try reader.seek(toOffset: position)
            var gotAny = false
            while let data = try reader.read(upToCount: Self.chunk), !data.isEmpty {
                gotAny = true
                position += UInt64(data.count)
                let out = rebaser.process([UInt8](data))
                if !out.isEmpty { try writer.write(contentsOf: Data(out)); written += Int64(out.count) }
                if written > Self.maxBytes {
                    glog("[Stream] \(source.lastPathComponent): stopped copying at \(Self.maxBytes / 1_000_000_000) GB; the stream ends here", level: .warning)
                    finish(); return
                }
                try Task.checkCancellation()
            }
            if !growing && !gotAny { finish(); return }
            if !gotAny { try await Task.sleep(nanoseconds: 150_000_000) }
        }
    }

    /// Byte offset about `secondsBehind` before the end, from the file's own bitrate (PCR at the start and the end).
    static func joinOffset(reader: FileHandle, size: UInt64, secondsBehind: Double) -> UInt64? {
        guard size > 8 << 20 else { return nil }
        guard (try? reader.seek(toOffset: 0)) != nil, let a = try? reader.read(upToCount: 1 << 20),
              (try? reader.seek(toOffset: size - (1 << 20))) != nil, let z = try? reader.read(upToCount: 1 << 20),
              let first = TSRebaser.firstPCR(in: [UInt8](a)), let last = TSRebaser.lastPCR(in: [UInt8](z)) else { return nil }
        let ticks = (last &+ (1 << 33) &- first) & ((1 << 33) - 1)
        let seconds = Double(ticks) / 90_000
        guard seconds > secondsBehind * 2 else { return nil }
        let bytesPerSecond = Double(size) / seconds
        let back = UInt64(secondsBehind * bytesPerSecond)
        let target = size - min(size, back)
        return target - target % UInt64(TSRebaser.packetSize)
    }
}
