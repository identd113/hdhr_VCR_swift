import Foundation
import Testing
@testable import hdhr_VCR

// The sound details the scan window shows: AC-3 frame headers, the TVCT's stream list, and the share of the stream each kind of packet takes.
struct OTAAudioTests {
    static let sample = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("WebStreaming/Fixtures/sample-mpeg2-ac3.ts")

    /// The AC-3 format at the start of the first PES packet on `pid` in a transport stream.
    static func firstFormat(pid: Int, in data: Data) -> OTAAudioFormat? {
        let b = [UInt8](data)
        var i = 0
        while i + 188 <= b.count {
            let p = (Int(b[i + 1] & 0x1F) << 8) | Int(b[i + 2])
            if b[i] == 0x47, p == pid, b[i + 1] & 0x40 != 0, b[i + 3] & 0x10 != 0 {
                var q = i + 4
                if b[i + 3] & 0x20 != 0 { q += 1 + Int(b[i + 4]) }
                if let f = OTAAudioFormat.sniffPES(b[q..<(i + 188)][...]) { return f }
            }
            i += 188
        }
        return nil
    }

    @Test func anAC3FrameHeaderIsRead() throws {
        // 0B 77, crc, 48 kHz / 384 kbit/s (frmsizecod 28), bsid 8 main audio, acmod 7 (3/2) with LFE, dialnorm 24.
        let f = try #require(OTAAudioFormat.parseAC3([0x0B, 0x77, 0, 0, 0x1C, 0x40, 0xE1, 0xC0, 0, 0, 0, 0]))
        #expect(f.sampleRate == 48_000 && f.kbps == 384)
        #expect(f.layout == "5.1" && f.channelCount == 6 && f.lfe)
        #expect(f.dialnorm == -24 && f.bsmod == 0)
        #expect(OTAAudioFormat.parseAC3([0x0B, 0x78, 0, 0, 0, 0, 0, 0]) == nil)       // not a sync word
    }

    @Test func aRealRecordingsAudioIsIdentified() throws {
        let f = try #require(Self.firstFormat(pid: 257, in: try Data(contentsOf: Self.sample)))
        #expect(f.sampleRate == 48_000)
        #expect(f.kbps >= 96 && f.kbps <= 640)
        #expect((-31 ... -1).contains(f.dialnorm))
    }

    @Test func theServiceLocationDescriptorListsTheStreams() {
        // tag 0xA1: PCR PID 0x31, 3 streams: MPEG-2 video 0x31, AC-3 0x34 "eng", AC-3 0x35 "spa".
        let d: [UInt8] = [0xA1, 21, 0xE0, 0x31, 3,
                          0x02, 0xE0, 0x31, 0, 0, 0,
                          0x81, 0xE0, 0x34, 0x65, 0x6E, 0x67,
                          0x81, 0xE0, 0x35, 0x73, 0x70, 0x61]
        let streams = OTAElementaryStream.serviceLocation(in: d)
        #expect(streams.count == 3)
        #expect(streams[0].isVideo && streams[0].pid == 0x31)
        #expect(streams[1].isAudio && streams[1].pid == 0x34 && streams[1].language == "eng" && streams[1].codec == "AC-3")
        #expect(streams[2].language == "spa")
        #expect(OTAElementaryStream.serviceLocation(in: [0x87, 1, 0]).isEmpty)
    }

    @Test func theDecoderCountsPacketsPerPID() throws {
        let decoder = PSIPDecoder()
        decoder.ingest(try Data(contentsOf: Self.sample))
        let result = decoder.result()
        #expect(result.pidPackets[256, default: 0] > 3000)
        #expect(result.pidPackets[257, default: 0] > 100)
    }

    @Test func theStreamBudgetSplitsTheRate() {
        var r = OTADecodeResult(broadcastTime: nil, gpsUTCOffset: 18, channels: [
            OTAChannel(name: "X", major: 5, minor: 1, program: 1, sourceId: 1, serviceType: 2, hidden: false, accessControlled: false,
                       streams: [OTAElementaryStream(pid: 0x31, streamType: 0x02, language: ""), OTAElementaryStream(pid: 0x34, streamType: 0x81, language: "eng")])],
                                events: [], announcedEITCount: 0)
        r.pidPackets = [0x31: 1000, 0x34: 100, 0x1FFB: 10, 0x1FFF: 500, 0: 5]
        r.psipPIDs = [0x1FFB]
        let b = OTAStreamBudget(result: r, seconds: 1)
        #expect(b != nil)
        #expect(abs((b?.video ?? 0) - 1.504) < 0.01)      // 1000 packets x 188 x 8 bit = 1.504 Mbit/s
        #expect(abs((b?.padding ?? 0) - 0.752) < 0.01)
        #expect((b?.audio ?? 0) > 0.14 && (b?.guide ?? 0) > 0.01 && (b?.other ?? 0) > 0)
        #expect(OTAStreamBudget(result: r, seconds: 0.2) == nil)
    }

    @Test func theProgramMapListsEveryProgram() throws {
        let decoder = PSIPDecoder()
        decoder.ingest(try Data(contentsOf: Self.sample))
        let programs = decoder.result().programs
        let p = try #require(programs.first)
        #expect(p.streams.contains { $0.pid == 256 && $0.isVideo })
        #expect(p.streams.contains { $0.pid == 257 && $0.isAudio })
        #expect(p.number > 0)
    }

    @MainActor
    @Test func aProgramNobodyNamedShowsAsUnlistedAndFlagsAreKept() {
        var r = OTADecodeResult(broadcastTime: nil, gpsUTCOffset: 18, channels: [
            OTAChannel(name: "OPEN", major: 11, minor: 7, program: 7, sourceId: 7, serviceType: 2, hidden: true, accessControlled: false),
            OTAChannel(name: "SCRAMBLED", major: 11, minor: 8, program: 8, sourceId: 8, serviceType: 2, hidden: false, accessControlled: true),
            OTAChannel(name: "WEATHER", major: 11, minor: 9, program: 9, sourceId: 9, serviceType: 4, hidden: false, accessControlled: false)],
                                events: [], announcedEITCount: 0)
        r.programs = [OTAProgram(number: 7, pcrPID: 0x31, streams: [OTAElementaryStream(pid: 0x31, streamType: 0x02, language: "")]),
                      OTAProgram(number: 12, pcrPID: 0x50, streams: [OTAElementaryStream(pid: 0x51, streamType: 0x81, language: "eng")])]
        let progress = OTAScanProgress()
        progress.reset(lineupOnly: true)
        progress.apply(.finished(rf: 31, result: r, bytes: 1_000_000, seconds: 5))
        let subs = progress.rows.first?.subChannels ?? []
        #expect(subs.count == 4)
        #expect(subs.first { $0.number == "11.7" }?.hidden == true)
        #expect(subs.first { $0.number == "11.8" }?.protected == true)
        #expect(subs.first { $0.number == "11.9" }?.isData == true)
        let extra = subs.first { $0.unlisted }
        #expect(extra?.name == "Program 12" && extra?.audioOnly == true)       // a sound-only program the channel table never mentions
    }
}
