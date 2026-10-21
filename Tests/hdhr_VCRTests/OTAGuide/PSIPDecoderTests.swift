import Foundation
import Testing
@testable import hdhr_VCR

// Fixture: the guide tables (PSIP PIDs only) from about 45 s of WCCO's multiplex (RF 32), captured 2026-10-20 from an HDHomeRun
// EXTEND: 7 channels, 559 events. Values below were cross-checked against the Python decoder in overtime/psip.py.
struct PSIPDecoderTests {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/psip-rf32.ts")

    static func decode(chunk: Int) throws -> OTADecodeResult {
        let data = try Data(contentsOf: fixture)
        let decoder = PSIPDecoder()
        var i = 0
        while i < data.count { let n = min(chunk, data.count - i); decoder.ingest(data[i..<(i + n)]); i += n }
        return decoder.result()
    }

    @Test func readsTheChannelsAndTheirNumbers() throws {
        let r = try Self.decode(chunk: 4096)
        #expect(r.channels.map(\.number) == ["4.1", "4.2", "4.3", "4.4", "4.5", "23.3", "23.4"])
        let wcco = try #require(r.channels.first { $0.number == "4.1" })
        #expect(wcco.name == "WCCO-DT")
        #expect(wcco.program == 1)
        #expect(wcco.serviceType == 2)
        #expect(!wcco.hidden && !wcco.accessControlled)
        #expect(r.announcedEITCount == 24)
    }

    @Test func readsTheBroadcastClock() throws {
        let r = try Self.decode(chunk: 4096)
        #expect(r.gpsUTCOffset == 18)
        #expect(r.broadcastTime == ISO8601DateFormatter().date(from: "2026-10-20T07:26:52Z"))
    }

    @Test func readsTitlesTimesRatingsAndDescriptions() throws {
        let r = try Self.decode(chunk: 4096)
        let wcco = try #require(r.channels.first { $0.number == "4.1" })
        let events = r.events.filter { $0.sourceId == wcco.sourceId }
        #expect(events.count == 105)
        let first = try #require(events.first)
        #expect(first.title == "WCCO News at 10pm")
        #expect(first.start == ISO8601DateFormatter().date(from: "2026-10-20T05:37:00Z"))
        #expect(first.lengthSeconds == 32 * 60)
        #expect(first.description == "Local and regional news.")
        let comics = try #require(events.first { $0.title.hasPrefix("Comics Unleashed") })
        #expect(comics.rating == "TV-PG")
        #expect(comics.lengthSeconds == 1800)
        #expect(r.events.count == 559)
        #expect(r.events.filter { !$0.description.isEmpty }.count > 400)
    }

    @Test func theResultDoesNotDependOnHowTheBytesAreChunked() throws {
        let a = try Self.decode(chunk: 188)      // exactly packet-sized
        let b = try Self.decode(chunk: 7777)     // splits packets
        let c = try Self.decode(chunk: 1_000_000)
        #expect(a == b)
        #expect(b == c)
    }

    @Test func garbageAndTruncationNeverCrashAndCorruptSectionsAreDropped() throws {
        var rng = SystemRandomNumberGenerator()
        let noise = Data((0..<50_000).map { _ in UInt8.random(in: 0...255, using: &rng) })
        let d1 = PSIPDecoder(); d1.ingest(noise)
        #expect(d1.result().events.isEmpty)
        // Flip one byte in every packet's payload: every section's CRC fails, so nothing is accepted (and nothing crashes).
        var data = try Data(contentsOf: Self.fixture)
        for i in stride(from: 100, to: data.count, by: 188) { data[i] ^= 0xFF }
        let d2 = PSIPDecoder(); d2.ingest(data)
        #expect(d2.result().events.isEmpty)
        // Cut off mid-packet.
        let d3 = PSIPDecoder(); d3.ingest(try Data(contentsOf: Self.fixture).prefix(188 * 500 + 77))
        _ = d3.result()
    }

    @Test func multipleStringHandlesLatin1AndSkipsCompressedText() {
        // 1 string, "eng", 1 segment, uncompressed, mode 0, "Café" in Latin-1
        let latin: [UInt8] = [1, 0x65, 0x6E, 0x67, 1, 0, 0, 4, 0x43, 0x61, 0x66, 0xE9]
        #expect(PSIPDecoder.multipleString(latin) == "Café")
        let compressed: [UInt8] = [1, 0x65, 0x6E, 0x67, 1, 1, 0, 2, 0xAA, 0xBB]
        #expect(PSIPDecoder.multipleString(compressed) == "")
        #expect(PSIPDecoder.multipleString([]) == "")
    }

    @Test func convertsToTheAppsGuideModel() throws {
        let r = try Self.decode(chunk: 4096)
        let channels = OTAGuideConverter.guideChannels(from: [r])
        #expect(channels.map(\.GuideNumber) == ["4.1", "4.2", "4.3", "4.4", "4.5", "23.3", "23.4"])
        let wcco = try #require(channels.first)
        #expect(wcco.GuideName == "WCCO-DT")
        let guide = try #require(wcco.Guide)
        #expect(guide.count == 105)
        #expect(guide[0].Title == "WCCO News at 10pm")
        #expect(guide[0].EndTime - guide[0].StartTime == 32 * 60)
        #expect(guide[0].Synopsis == "Local and regional news.")
        #expect(guide[0].SeriesID == nil)
        #expect(guide.map(\.StartTime) == guide.map(\.StartTime).sorted())
    }

    /// Data that never lines up as transport-stream packets must be dropped as it arrives, not piled up and rescanned on every chunk
    /// (13 MB used to take 23 s), and the decoder must still find real packets afterwards.
    @Test func garbageIsDroppedQuicklyAndTheDecoderResyncs() throws {
        let decoder = PSIPDecoder()
        var junk = Data(count: 65536)
        for i in 0..<junk.count { junk[i] = UInt8((i * 31 + 7) % 251) }   // 251 is prime: 0x47 never repeats 188 bytes apart
        let start = Date()
        for _ in 0..<200 { decoder.ingest(junk) }
        #expect(Date().timeIntervalSince(start) < 3, "13 MB of junk was slow to ingest")
        decoder.ingest(try Data(contentsOf: Self.fixture))
        #expect(decoder.result().channels.count == 7)
    }
}
