import Foundation
import Testing
@testable import hdhr_VCR

/// Builds tiny but valid transport streams: PAT (PID 0) → PMT (PID 0x30) → MPEG-2 video (0x31) + AC-3 audio (0x34), PCR on the video PID.
private enum TS {
    static func packet(pid: Int, pusi: Bool, cc: Int, adaptation: [UInt8]? = nil, payload: [UInt8]) -> [UInt8] {
        var p: [UInt8] = [0x47, UInt8((pusi ? 0x40 : 0) | (pid >> 8)), UInt8(pid & 0xff)]
        var af = adaptation ?? []
        let room = 184 - (af.isEmpty ? 0 : af.count + 1)
        var body = payload
        if body.count < room {   // pad with adaptation-field stuffing
            let pad = room - body.count
            if af.isEmpty { af = pad == 1 ? [] : [0x00] + [UInt8](repeating: 0xff, count: pad - 2); if pad == 1 { af = [] } }
            else { af += [UInt8](repeating: 0xff, count: pad) }
            body = payload
        }
        let hasAF = !af.isEmpty || body.count < 184
        if hasAF {
            var field = af
            if body.count < 184 - (field.count + 1) { field += [UInt8](repeating: 0xff, count: 184 - (field.count + 1) - body.count) }
            p.append(UInt8(0x30 | (cc & 15)))
            p.append(UInt8(field.count))
            p += field + body
        } else {
            p.append(UInt8(0x10 | (cc & 15)))
            p += body
        }
        return Array(p.prefix(188)) + [UInt8](repeating: 0xff, count: max(0, 188 - p.count))
    }

    static func section(_ table: [UInt8]) -> [UInt8] { [0x00] + table }   // pointer field + section

    static let pat = packet(pid: 0, pusi: true, cc: 0, payload: section([0x00, 0xb0, 0x0d, 0x00, 0x01, 0xc1, 0x00, 0x00, 0x00, 0x03, 0xe0, 0x30, 0, 0, 0, 0]))
    static let pmt = packet(pid: 0x30, pusi: true, cc: 0, payload: section([
        0x02, 0xb0, 0x17, 0x00, 0x03, 0xc1, 0x00, 0x00, 0xe0, 0x31, 0xf0, 0x00,
        0x02, 0xe0, 0x31, 0xf0, 0x00,
        0x81, 0xe0, 0x34, 0xf0, 0x00, 0, 0, 0, 0]))

    static func ts5(_ marker: UInt8, _ v: UInt64) -> [UInt8] {
        [marker << 4 | UInt8((v >> 29) & 0x0e) | 1, UInt8((v >> 22) & 0xff), UInt8((v >> 14) & 0xfe) | 1, UInt8((v >> 7) & 0xff), UInt8((v << 1) & 0xfe) | 1]
    }

    /// A video PES packet (PTS+DTS) whose payload starts with an MPEG-2 sequence header (a keyframe) or a plain picture header.
    static func video(pts: UInt64, dts: UInt64, keyframe: Bool, pcr: UInt64? = nil) -> [UInt8] {
        let es: [UInt8] = keyframe ? [0, 0, 1, 0xb3, 0x50, 0x02, 0xd0] : [0, 0, 1, 0x00, 0x00, 0x0f]
        let pes: [UInt8] = [0, 0, 1, 0xe0, 0, 0, 0x80, 0xc0, 10] + ts5(3, pts) + ts5(1, dts) + es
        var af: [UInt8]?
        if let pcr {
            af = [0x10, UInt8((pcr >> 25) & 0xff), UInt8((pcr >> 17) & 0xff), UInt8((pcr >> 9) & 0xff), UInt8((pcr >> 1) & 0xff), UInt8((pcr & 1) << 7) | 0x7e, 0x00]
        }
        return packet(pid: 0x31, pusi: true, cc: 0, adaptation: af, payload: pes)
    }

    static func audio(pts: UInt64) -> [UInt8] {
        packet(pid: 0x34, pusi: true, cc: 0, payload: [0, 0, 1, 0xbd, 0, 0, 0x80, 0x80, 5] + ts5(2, pts) + [0x0b, 0x77, 0x00])
    }

    static func pesTimestamp(of packet: [UInt8]) -> UInt64? {
        TSRebaser.pesTimestamp(packet, payload: payloadStart(packet), end: 188, preferDTS: false)
    }
    static func payloadStart(_ p: [UInt8]) -> Int { ((p[3] >> 4) & 2 != 0) ? 5 + Int(p[4]) : 4 }
}

@Suite("Transport-stream timestamp rebasing (AVFoundation 2^32 bug)")
struct TSRebaserTests {
    private let wrap32: UInt64 = 1 << 32

    @Test func outputStartsAtTheFirstKeyframeWithTheTablesAndNearZeroTimestamps() {
        var rb = TSRebaser()
        let base = wrap32 - 90_000 * 60   // a minute before the 2^32 boundary
        var input = TS.pat + TS.pmt
        input += TS.audio(pts: base - 10_000)                                       // before the first keyframe: dropped
        input += TS.video(pts: base + 3_000, dts: base, keyframe: false)             // not decodable on its own: dropped
        input += TS.video(pts: base + 13_000, dts: base + 10_000, keyframe: true)    // first keyframe
        input += TS.audio(pts: base + 12_000)
        let out = rb.process(input)
        #expect(out.count == 188 * 4)                         // PAT, PMT, keyframe, audio
        #expect(Array(out[0..<188]) == TS.pat)
        #expect(Array(out[188..<376]) == TS.pmt)
        let key = Array(out[376..<564]), aud = Array(out[564..<752])
        #expect(TS.pesTimestamp(of: key) == 13_000 - 10_000 + TSRebaser.preroll)   // PTS = 3000 + 2 s
        #expect(TS.pesTimestamp(of: aud) == 12_000 - 10_000 + TSRebaser.preroll)
    }

    @Test func timestampsKeepIncreasingAcrossTheBoundary() {
        var rb = TSRebaser()
        let base = wrap32 - 90_000 * 2
        var input = TS.pat + TS.pmt + TS.video(pts: base + 3_000, dts: base, keyframe: true)
        for n in 1...8 { let t = base + UInt64(n) * 90_000; input += TS.video(pts: t + 3_000, dts: t, keyframe: false) }   // crosses 2^32 after 2 s
        let out = rb.process(input)
        let stamps = stride(from: 188 * 2, to: out.count, by: 188).compactMap { TS.pesTimestamp(of: Array(out[$0..<$0 + 188])) }
        #expect(stamps.count == 9)
        #expect(stamps == stamps.sorted())
        #expect(stamps.allSatisfy { $0 < wrap32 })            // nothing near 2^32 remains
        #expect(stamps.last! - stamps.first! == 8 * 90_000)
    }

    @Test func pcrOnTheVideoPidIsMovedByTheSameAmount() {
        var rb = TSRebaser()
        let base: UInt64 = 4_278_295_742
        let out = rb.process(TS.pat + TS.pmt + TS.video(pts: base + 3_000, dts: base, keyframe: true, pcr: base - 20_000))
        let key = Array(out[376..<564])
        #expect(TSRebaser.readPCR(key, at: 6) == TSRebaser.preroll - 20_000)
    }

    @Test func aWrappedTimestampStillComesOutPositive() {
        var rb = TSRebaser()
        let nearEnd: UInt64 = (1 << 33) - 30_000   // 33-bit clock about to wrap
        var input = TS.pat + TS.pmt + TS.video(pts: nearEnd + 3_000, dts: nearEnd, keyframe: true)
        input += TS.video(pts: 3_000 + 40_000 - 30_000, dts: 40_000 - 30_000, keyframe: false)   // after the wrap
        let out = rb.process(input)
        let a = TS.pesTimestamp(of: Array(out[376..<564]))!, b = TS.pesTimestamp(of: Array(out[564..<752]))!
        #expect(a == 3_000 + TSRebaser.preroll)
        #expect(b == a + 40_000)
    }

    @Test func packetsSplitAcrossCallsAreReassembled() {
        let base: UInt64 = 5_000_000_000
        let input = TS.pat + TS.pmt + TS.video(pts: base + 3_000, dts: base, keyframe: true) + TS.audio(pts: base + 2_000)
        var whole = TSRebaser()
        let expected = whole.process(input)
        var split = TSRebaser()
        var got = [UInt8]()
        for chunk in stride(from: 0, to: input.count, by: 97) { got += split.process(Array(input[chunk..<min(chunk + 97, input.count)])) }
        #expect(got == expected)
        #expect(!expected.isEmpty)
    }

    @Test func nothingIsWrittenUntilAKeyframeArrives() {
        var rb = TSRebaser()
        let out = rb.process(TS.pat + TS.pmt + TS.video(pts: 3_000, dts: 0, keyframe: false) + TS.audio(pts: 100))
        #expect(out.isEmpty)
        #expect(!rb.hasStarted)
    }

    @Test func restartPictureKeepsTheTablesButWaitsForTheNextKeyframe() {
        var rb = TSRebaser()
        _ = rb.process(TS.pat + TS.pmt + TS.video(pts: 3_000, dts: 0, keyframe: true))
        #expect(rb.hasStarted)
        rb.restartPicture()
        #expect(!rb.hasStarted)
        let later = rb.process(TS.video(pts: 903_000, dts: 900_000, keyframe: false) + TS.video(pts: 993_000, dts: 990_000, keyframe: true))
        #expect(later.count == 188 * 3)   // PAT, PMT (kept from before) and the new keyframe
    }

    @Test func writeThenReadOfATimestampIsLossless() {
        for v: UInt64 in [0, 1, 90_000, wrap32 - 1, wrap32, wrap32 + 12345, (1 << 33) - 1] {
            var b = TS.ts5(3, 0)
            TSRebaser.writeTS(&b, at: 0, value: v)
            #expect(TSRebaser.readTS(b, at: 0) == v)
            #expect(b[0] >> 4 == 3)    // the marker nibble is kept
        }
    }
}
