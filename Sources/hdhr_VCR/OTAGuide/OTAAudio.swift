import Foundation

// What the over-the-air scan can tell about a channel's sound (shown in the scan window's channel list, docs/OTAScanView.md): which
// elementary streams a channel carries (the TVCT's Service Location Descriptor: type, PID, language) and, for AC-3, the format read
// from the first audio frame (A/52 bit-stream info: sample rate, bit rate, speaker layout, dialogue level, service type).
// Pure functions on bytes, unit-tested; nothing here touches the network.

/// The audio format found in an AC-3 frame header.
struct OTAAudioFormat: Equatable, Sendable {
    var sampleRate: Int            // Hz
    var kbps: Int                  // the stream's nominal bit rate
    var acmod: Int                 // audio coding mode: 0 = 1+1 … 7 = 3/2 (front/rear speakers)
    var lfe: Bool                  // a low-frequency (subwoofer) channel
    var dialnorm: Int              // dialogue level, -31…-1 dB below full scale (a lower number is a quieter mix)
    var bsmod: Int                 // service type: 0 main, 2 visually impaired, 3 hearing impaired, 4 dialogue, 5 commentary …

    /// Full-range channels for each audio coding mode (not counting the LFE).
    static let channelsForMode = [2, 1, 2, 3, 3, 4, 4, 5]
    var channelCount: Int { Self.channelsForMode[acmod & 7] + (lfe ? 1 : 0) }
    /// "5.1", "2.0", "1.0" …
    var layout: String { "\(Self.channelsForMode[acmod & 7]).\(lfe ? 1 : 0)" }
    /// Speakers present, as (front, rear) counts, for drawing a layout: 3/2 = left, centre, right in front and two surrounds.
    var speakers: (front: Int, rear: Int) {
        switch acmod & 7 { case 0, 2: return (2, 0); case 1: return (1, 0); case 3: return (3, 0); case 4: return (2, 1); case 5: return (3, 1); case 6: return (2, 2); default: return (3, 2) }
    }
    var serviceText: String {
        switch bsmod { case 0: return "main audio"; case 1: return "music and effects"; case 2: return "for the visually impaired"
        case 3: return "for the hearing impaired"; case 4: return "dialogue"; case 5: return "commentary"; case 6: return "emergency"; default: return "voice-over" }
    }

    private static let bitrates = [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 576, 640]

    /// Reads an AC-3 frame (starting at its 0x0B77 sync word); nil when it is not one (E-AC-3 and damaged frames included).
    static func parseAC3(_ b: [UInt8]) -> OTAAudioFormat? {
        guard b.count >= 8, b[0] == 0x0B, b[1] == 0x77 else { return nil }
        let fscod = Int(b[4] >> 6), frmsizecod = Int(b[4] & 0x3F)
        let bsid = Int(b[5] >> 3), bsmod = Int(b[5] & 0x07)
        guard bsid <= 8, fscod < 3, frmsizecod < 38 else { return nil }
        let rates = [48_000, 44_100, 32_000]
        var bits = BitReader(Array(b[6..<min(b.count, 12)]))
        let acmod = bits.read(3)
        if acmod & 1 != 0, acmod != 1 { _ = bits.read(2) }   // centre mix level
        if acmod & 4 != 0 { _ = bits.read(2) }                // surround mix level
        if acmod == 2 { _ = bits.read(2) }                    // Dolby Surround mode
        let lfe = bits.read(1) == 1
        let dialnorm = bits.read(5)
        return OTAAudioFormat(sampleRate: rates[fscod], kbps: bitrates[frmsizecod >> 1], acmod: acmod, lfe: lfe,
                              dialnorm: dialnorm == 0 ? -31 : -dialnorm, bsmod: bsmod)
    }

    /// The AC-3 format in the start of a PES packet's payload (private stream 1: 00 00 01 BD …), or nil.
    static func sniffPES(_ payload: ArraySlice<UInt8>) -> OTAAudioFormat? {
        let p = Array(payload.prefix(80))
        guard p.count > 12, p[0] == 0, p[1] == 0, p[2] == 1, p[3] == 0xBD else { return nil }
        let start = 9 + Int(p[8])
        guard start + 8 <= p.count else { return nil }
        return parseAC3(Array(p[start...]))
    }

    private struct BitReader {
        let bytes: [UInt8]; var pos = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }
        mutating func read(_ n: Int) -> Int {
            var v = 0
            for _ in 0..<n {
                let byte = pos / 8
                let bit = byte < bytes.count ? Int(bytes[byte] >> UInt8(7 - pos % 8)) & 1 : 0
                v = (v << 1) | bit; pos += 1
            }
            return v
        }
    }
}

/// One elementary stream (video or audio) of a channel, from the TVCT's Service Location Descriptor, plus what was learned by reading it.
struct OTAElementaryStream: Equatable, Sendable {
    var pid: Int
    var streamType: Int
    var language: String           // ISO 639-2 ("eng"), or ""
    var audio: OTAAudioFormat?     // read from the first AC-3 frame
    var kbps: Double?              // measured over the scan's read, from the packets seen on this PID

    var isVideo: Bool { [0x02, 0x1B, 0x24].contains(streamType) }
    var isAudio: Bool { [0x03, 0x04, 0x0F, 0x11, 0x81, 0x87].contains(streamType) }
    var codec: String {
        switch streamType {
        case 0x02: return "MPEG-2 video"; case 0x1B: return "H.264 video"; case 0x24: return "HEVC video"
        case 0x03, 0x04: return "MPEG audio"; case 0x0F, 0x11: return "AAC"; case 0x81: return "AC-3"; case 0x87: return "E-AC-3"
        default: return String(format: "type 0x%02X", streamType)
        }
    }
    /// "English" for "eng"; the code itself when the system does not know it.
    var languageName: String {
        guard !language.isEmpty, language != "und" else { return "" }
        return Locale.current.localizedString(forLanguageCode: language)?.capitalized ?? language.uppercased()
    }

    /// The streams a TVCT channel lists in its Service Location Descriptor (tag 0xA1: PCR PID, then stream type, PID and language for each).
    static func serviceLocation(in descriptors: [UInt8]) -> [OTAElementaryStream] {
        var pos = 0
        while pos + 2 <= descriptors.count {
            let tag = descriptors[pos], length = Int(descriptors[pos + 1])
            guard pos + 2 + length <= descriptors.count else { break }
            if tag == 0xA1, length >= 3 {
                let body = Array(descriptors[(pos + 2)..<(pos + 2 + length)])
                var p = 3
                var out: [OTAElementaryStream] = []
                for _ in 0..<Int(body[2]) {
                    guard p + 6 <= body.count else { break }
                    let lang = String(bytes: body[(p + 3)..<(p + 6)], encoding: .ascii)?.trimmingCharacters(in: .controlCharacters) ?? ""
                    out.append(OTAElementaryStream(pid: (Int(body[p + 1] & 0x1F) << 8) | Int(body[p + 2]), streamType: Int(body[p]), language: lang))
                    p += 6
                }
                return out
            }
            pos += 2 + length
        }
        return []
    }
}
