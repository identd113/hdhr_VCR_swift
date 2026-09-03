import Testing
import Foundation
@testable import hdhr_VCR

// Pure encode/decode tests for VirtualTunerService's UDP wire format — no live socket, per the
// "Rebroadcast an in-progress recording" plan's own test scoping (live UDP/HTTP behavior is
// exercised manually, see that plan's Verification section and tools/mock_hdhr.py).
@Suite("VirtualTunerService UDP protocol")
struct VirtualTunerServiceTests {

    // Byte-for-byte match of HDHRManager.udpDiscoverSync's own outgoing request packet:
    // [0x00,0x02][0x00,0x06][0x01,0x04][0xFF,0xFF,0xFF,0xFF][crc32, little-endian].
    private func realDiscoverRequestBytes() -> [UInt8] {
        let payload: [UInt8] = [0x01, 0x04, 0xFF, 0xFF, 0xFF, 0xFF]
        var pkt: [UInt8] = [0x00, 0x02, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)] + payload
        let crc = crc32(pkt)
        pkt += withUnsafeBytes(of: crc.littleEndian) { Array($0) }
        return pkt
    }

    @Test func isDiscoverRequest_recognizesRealRequestFormat() {
        #expect(VirtualTunerService.isDiscoverRequest(realDiscoverRequestBytes()))
    }

    @Test func isDiscoverRequest_recognizesMinimalFourByteHeader() {
        // mock_hdhr.py's own reference server validates only the leading type field — no TLV/CRC
        // required on the request. A minimal 4-byte probe must still be accepted.
        #expect(VirtualTunerService.isDiscoverRequest([0x00, 0x02, 0x00, 0x00]))
    }

    @Test func isDiscoverRequest_rejectsWrongType() {
        // 0x0003 is DISCOVER_REPLY, not DISCOVER_REQUEST — must never trigger a reply-to-a-reply.
        #expect(!VirtualTunerService.isDiscoverRequest([0x00, 0x03, 0x00, 0x06]))
    }

    @Test func isDiscoverRequest_rejectsTooShort() {
        #expect(!VirtualTunerService.isDiscoverRequest([0x00, 0x02]))
        #expect(!VirtualTunerService.isDiscoverRequest([]))
    }

    // TLV layout (DeviceType, DeviceID, BaseURL, TunerCount, LineupURL) is ground truth live-
    // captured from a real EXTEND's actual DISCOVER_REPLY 2026-09-02 (see buildDiscoverReply's own
    // doc comment) — not the earlier DeviceID-only reply, which real third-party HDHomeRun clients
    // (Plex, Channels DVR, etc.) never actually recognized as a discoverable tuner.
    @Test func buildDiscoverReply_matchesDocumentedByteLayout() {
        let baseURL = "http://10.0.2.100:1980"
        let pkt = VirtualTunerService.buildDiscoverReply(deviceID: 0xFEED1234, baseURL: baseURL, tunerCount: 2)

        #expect(Array(pkt[0...1]) == [0x00, 0x03])   // type = DISCOVER_REPLY
        let payloadLen = Int(pkt[2]) << 8 | Int(pkt[3])
        #expect(pkt.count == 4 + payloadLen + 4)   // header + payload + trailing crc32

        var off = 4
        var tlvs: [(tag: UInt8, value: [UInt8])] = []
        while off + 2 <= 4 + payloadLen {
            let tag = pkt[off], len = Int(pkt[off + 1])
            off += 2
            tlvs.append((tag, Array(pkt[off..<off + len])))
            off += len
        }

        #expect(tlvs.first { $0.tag == 0x01 }?.value == [0x00, 0x00, 0x00, 0x01])   // DeviceType = tuner
        #expect(tlvs.first { $0.tag == 0x02 }?.value == [0xFE, 0xED, 0x12, 0x34])   // DeviceID, big-endian
        #expect(tlvs.first { $0.tag == 0x2A }?.value == Array(baseURL.utf8))         // BaseURL
        #expect(tlvs.first { $0.tag == 0x10 }?.value == [0x02])                      // TunerCount
        #expect(tlvs.first { $0.tag == 0x27 }?.value == Array("\(baseURL)/lineup.json".utf8))   // LineupURL

        // Trailing 4 bytes are crc32 of everything before them, little-endian — recompute
        // independently and compare, rather than hardcoding a magic constant that would silently
        // stop verifying anything if crc32(_:)'s implementation ever changed.
        let bodyEnd = 4 + payloadLen
        let expectedCRC = crc32(Array(pkt[0..<bodyEnd]))
        let actualCRC = Array(pkt[bodyEnd..<bodyEnd + 4]).withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
        #expect(actualCRC == expectedCRC)
    }

    @Test func buildDiscoverReply_differentDeviceIDsProduceDifferentReplies() {
        let a = VirtualTunerService.buildDiscoverReply(deviceID: 0xFEED0001, baseURL: "http://10.0.2.100:1980", tunerCount: 1)
        let b = VirtualTunerService.buildDiscoverReply(deviceID: 0xFEED0002, baseURL: "http://10.0.2.100:1980", tunerCount: 1)
        #expect(a != b)
    }

    @Test func buildDiscoverReply_differentTunerCountsProduceDifferentReplies() {
        let a = VirtualTunerService.buildDiscoverReply(deviceID: 0xFEED0001, baseURL: "http://10.0.2.100:1980", tunerCount: 1)
        let b = VirtualTunerService.buildDiscoverReply(deviceID: 0xFEED0001, baseURL: "http://10.0.2.100:1980", tunerCount: 2)
        #expect(a != b)
    }

    @Test func makeDeviceID_hasFEEDPrefixAndIsHexParseable() {
        let id = VirtualTunerService.makeDeviceID()
        #expect(id.hasPrefix("FEED"))
        #expect(id.count == 8)
        #expect(UInt32(id, radix: 16) != nil)
        // Never collides with the project's unrelated fake EXTEND test device sentinel.
        #expect(id != "FFFF0001")
    }

    @Test func start_invalidDeviceID_reportsBindFailureWithoutTouchingASocket() {
        // Covers the synchronous early-exit branch of start(deviceID:onBindResult:) — the part of
        // the bind-result callback plumbing (AppState.updateVirtualTunerPresence's own consumer)
        // reachable without a live socket bind, per this file's own "no live socket" test scoping.
        var reportedSuccess: Bool?
        VirtualTunerService().start(deviceID: "not-hex") { success in reportedSuccess = success }
        #expect(reportedSuccess == false)
    }

    @Test func makeDeviceID_isFreshOnEveryCall() {
        // Deliberately NOT deterministic — a fresh ID must be minted on every relay restart so a
        // client that cached an old ID from a since-ended recording can't confuse a later,
        // unrelated session for the one it already knows about (see makeDeviceID's own doc
        // comment). Collision probability across 100 calls with a 16-bit random component is
        // negligible enough not to flake in practice.
        let ids = Set((0..<100).map { _ in VirtualTunerService.makeDeviceID() })
        #expect(ids.count > 1)
    }
}
