import Testing
import Foundation
@testable import hdhr_VCR

// WebServer.lastKeyframePacketOffset — the keyframe finder streamGrowingFile uses so a relay
// started mid-file (FEED live join, Watch Now start, scrub seeks) begins at decodable video
// instead of letting audio run ahead of a picture that's waiting for the next keyframe.
@Suite("Relay keyframe alignment")
struct KeyframeAlignmentTests {

    /// One 188-byte TS packet. `pes` (if given) is placed right after the header (and optional
    /// adaptation field) as the start of a PES packet with the given stream_id and ES bytes.
    private func packet(pusi: Bool = true, streamId: UInt8? = 0xE0, es: [UInt8] = [],
                        randomAccess: Bool = false) -> [UInt8] {
        var p: [UInt8] = [0x47, pusi ? 0x41 : 0x01, 0x00]
        if randomAccess {
            p.append(0x30)                 // adaptation + payload
            p += [0x01, 0x40]              // adaptation_field_length 1, random_access_indicator
        } else {
            p.append(0x10)                 // payload only
        }
        if let streamId {
            // PES: start code, stream_id, length 0, flags, PES header data length 0
            p += [0x00, 0x00, 0x01, streamId, 0x00, 0x00, 0x80, 0x00, 0x00] + es
        }
        p += [UInt8](repeating: 0xFF, count: 188 - p.count)
        return p
    }

    private func data(_ packets: [[UInt8]]) -> Data { Data(packets.flatMap { $0 }) }

    @Test func findsMPEG2SequenceHeader() {
        let d = data([packet(es: [0, 0, 1, 0x00]), packet(es: [0, 0, 1, 0xB3, 0x12]), packet(es: [0, 0, 1, 0x00])])
        #expect(WebServer.lastKeyframePacketOffset(in: d) == 188)
    }

    @Test func findsH264SPSAndIDR() {
        let sps = data([packet(es: [0, 0, 0, 1, 0x67, 0x64]), packet(es: [0, 0, 1, 0x41])])
        #expect(WebServer.lastKeyframePacketOffset(in: sps) == 0)
        let idr = data([packet(es: [0, 0, 1, 0x09, 0xF0, 0, 0, 1, 0x65])])   // AUD then IDR slice
        #expect(WebServer.lastKeyframePacketOffset(in: idr) == 0)
    }

    @Test func acceptsRandomAccessIndicator() {
        let d = data([packet(es: [0, 0, 1, 0x00], randomAccess: true), packet(es: [0, 0, 1, 0x00])])
        #expect(WebServer.lastKeyframePacketOffset(in: d) == 0)
    }

    @Test func returnsTheLastKeyframeNotTheFirst() {
        let d = data([packet(es: [0, 0, 1, 0xB3]), packet(es: [0, 0, 1, 0x00]), packet(es: [0, 0, 1, 0xB3]),
                      packet(pusi: false, streamId: nil)])
        #expect(WebServer.lastKeyframePacketOffset(in: d) == 376)
    }

    @Test func ignoresAudioNonKeyframesAndHEVCLookalikes() {
        let d = data([
            packet(streamId: 0xBD, es: [0, 0, 1, 0xB3]),      // AC-3 private stream, not video
            packet(es: [0, 0, 1, 0x41]),                      // H.264 non-IDR slice
            packet(es: [0, 0, 1, 0x26, 0x01]),                // H.264 SEI that looks like HEVC IDR
            packet(pusi: false, streamId: nil),               // continuation packet
        ])
        #expect(WebServer.lastKeyframePacketOffset(in: d) == nil)
    }

    @Test func emptyOrPartialDataIsNil() {
        #expect(WebServer.lastKeyframePacketOffset(in: Data()) == nil)
        #expect(WebServer.lastKeyframePacketOffset(in: Data(repeating: 0x47, count: 100)) == nil)
    }
}
