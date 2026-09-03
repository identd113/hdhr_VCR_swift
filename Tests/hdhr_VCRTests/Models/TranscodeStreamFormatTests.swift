import Testing
import Foundation
@testable import hdhr_VCR

// Locks in what an HDHomeRun actually sends on port 5004 for the two recording profiles, and that
// our filename extension matches that reality. Ground truth captured live from device 105404BE,
// ch 4.1 (2026-07-18): `curl .../auto/v4.1?duration=2&transcode=<profile>`.
//
// Finding: BOTH profiles are MPEG-2 transport streams (188-byte packets, sync 0x47). Transcoding
// is a video-only re-encode INSIDE the same TS container — it does not switch to MP4/MKV:
//   transcode=none  → video stream_type 0x02 (MPEG-2), audio AC-3
//   transcode=heavy → video stream_type 0x1b (H.264),  audio AC-3
// Therefore every recording is written `.ts` (see Show.outputPath). If SiliconDust ever changes
// the wire format, or someone reverts the extension logic, these tests fail loudly.
@Suite struct TranscodeStreamFormatTests {

    // One PAT packet + one PMT packet (376 bytes) carved from each live capture, base64-encoded so
    // the fixture is self-contained (no test-resource plumbing). Trailing 0xFF are TS stuffing.
    static let noneFixture  = "R0AAHwAAsA0GMcEAAAAB4DA5+8Hh//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////9HQDAYAAKwSwABwQAA4DHwCBAGwL1iwAgAAuAx8AMGAQKB4DTwEgoEZW5nAIEK6CgF/w8Bv2VuZ4HgNfASCgRzcGEAgQroKAX/DwG/c3BhuzSBGv///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////w=="
    static let heavyFixture = "R0AAGwAAsA0GMcEAAAAB4DA5+8Hh//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////9HQDAQAAKwKQABwQAA4DHwABvgMfAAgeA08BIKBGVuZwCBCugoBf8PAb9lbmcd3CGw/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////w=="

    /// Base64-decodes a PAT+PMT fixture and probes it via the shared production parser
    /// (`mpegTSVideoStreamType(_:)`, `CompatibilityHelpers.swift`) — extracted there so the virtual-
    /// tuner relay's real-source-codec check (`WebServer.swift`) and this test's own ground-truth
    /// assertions can never drift apart into two different byte-offset interpretations.
    private func probe(_ b64: String) -> UInt8? {
        mpegTSVideoStreamType([UInt8](Data(base64Encoded: b64)!))
    }

    @Test func rawProfileIsMpeg2InsideTransportStream() {
        #expect(probe(Self.noneFixture) == 0x02)    // MPEG-2 video
    }

    @Test func transcodedProfileIsH264InsideSameTransportStream() {
        #expect(probe(Self.heavyFixture) == 0x1b)   // H.264/AVC
    }

    @Test func outputExtensionIsAlwaysTS() {
        var s = Show.blank(channel: "4.1", device: "105404BE")
        s.show_title = "Nova"
        for profile in ["none", "", "heavy", "mobile", "internet720"] {
            s.show_transcode = profile
            #expect(s.outputPath().hasSuffix(".ts"),
                    "transcode=\(profile) is still MPEG-TS on the wire → .ts")
        }
    }

    @Test func recordingFileRecognizesCurrentAndLegacyExtensions() {
        #expect(Show.isRecordingFile("Nova_4.1_20260101_2000.ts"))               // current
        #expect(Show.isRecordingFile("Nova_S02E04_4.1_20260101_2000.m2ts"))      // legacy (none)
        #expect(Show.isRecordingFile("Nova_4.1_20260101_2000.mkv"))              // legacy (transcoded)
        #expect(Show.isRecordingFile("Nova.TS"))                                 // case-insensitive
        #expect(!Show.isRecordingFile("Nova_4.1_20260101_2000.mp4"))             // never ours
        #expect(!Show.isRecordingFile("notes.txt"))
    }

    // MARK: - Virtual-tuner relay's "already a modern codec, skip re-encoding" check

    @Test func isAlreadyModernCodec_trueOnlyForH264AndHEVC() {
        #expect(MPEGVideoStreamType.isAlreadyModernCodec(MPEGVideoStreamType.h264))
        #expect(MPEGVideoStreamType.isAlreadyModernCodec(MPEGVideoStreamType.hevc))
        #expect(!MPEGVideoStreamType.isAlreadyModernCodec(MPEGVideoStreamType.mpeg2Video))
        #expect(!MPEGVideoStreamType.isAlreadyModernCodec(MPEGVideoStreamType.mpeg1Video))
    }

    // String-form overload — LineupEntry.VideoCodec's own live-confirmed values ("MPEG2"/"H264",
    // docs/HDHRFindings.md) are the fast, proactive check WebServer.handleVirtualTunerStream tries
    // before ever falling back to the byte-level PAT/PMT probe above.
    @Test func isAlreadyModernCodec_stringForm_matchesLineupsRealValues() {
        #expect(MPEGVideoStreamType.isAlreadyModernCodec("H264"))     // confirmed live, real device
        #expect(MPEGVideoStreamType.isAlreadyModernCodec("h264"))     // case-insensitive
        #expect(MPEGVideoStreamType.isAlreadyModernCodec("HEVC"))
        #expect(!MPEGVideoStreamType.isAlreadyModernCodec("MPEG2"))   // confirmed live, real device — the common case
        #expect(!MPEGVideoStreamType.isAlreadyModernCodec(""))
    }

    // LineupEntry decodes the real /lineup.json shape confirmed live 2026-09-02 (docs/HDHRFindings.md):
    // {"GuideNumber":"2.1","GuideName":"TPT 2","VideoCodec":"MPEG2","AudioCodec":"AC3","HD":1,"URL":"..."}
    @Test func lineupEntry_decodesRealVideoCodecAndAudioCodecFields() throws {
        let json = """
        {"GuideNumber":"21.2","GuideName":"Snapshp","VideoCodec":"H264","AudioCodec":"AC3","HD":0,
         "URL":"http://10.0.2.101:5004/auto/v21.2"}
        """
        let entry = try JSONDecoder().decode(LineupEntry.self, from: Data(json.utf8))
        #expect(entry.VideoCodec == "H264")
        #expect(entry.AudioCodec == "AC3")
        #expect(MPEGVideoStreamType.isAlreadyModernCodec(entry.VideoCodec ?? ""))
    }

    @Test func lineupEntry_videoCodecIsNilWhenAbsent() throws {
        // The virtual relay's own synthetic /lineup.json entries never set this — this is the case
        // WebServer.handleVirtualTunerStream falls back to the on-disk PAT/PMT probe for.
        let json = """
        {"GuideNumber":"5.1","GuideName":"Recording On Other Mac","URL":"http://127.0.0.1:1980/auto/v5.1"}
        """
        let entry = try JSONDecoder().decode(LineupEntry.self, from: Data(json.utf8))
        #expect(entry.VideoCodec == nil)
        #expect(entry.AudioCodec == nil)
    }

    // File-based wrapper — WebServer.handleVirtualTunerStream reads the on-disk recording, not an
    // in-memory buffer, so this covers the actual code path it calls (mpegTSVideoStreamType(inFileAt:)),
    // not just the pure byte-parser the tests above already exercise.
    @Test func fileBasedProbe_matchesTheSameGroundTruthFixtures() throws {
        let path = NSTemporaryDirectory() + "hdhrVCRplus-tsformat-\(UUID().uuidString).ts"
        try Data(base64Encoded: Self.heavyFixture)!.write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let streamType = mpegTSVideoStreamType(inFileAt: path)
        #expect(streamType == 0x1b)
        #expect(streamType.map(MPEGVideoStreamType.isAlreadyModernCodec) == true)
    }

    @Test func fileBasedProbe_returnsNilForAMissingFile() {
        #expect(mpegTSVideoStreamType(inFileAt: "/nonexistent/\(UUID().uuidString).ts") == nil)
    }
}
