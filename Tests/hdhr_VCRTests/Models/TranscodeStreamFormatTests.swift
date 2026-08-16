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

    /// Parses a PAT+PMT byte blob. Returns whether it is a transport stream (sync bytes at each
    /// 188-byte boundary) and the first video elementary-stream type from the PMT.
    private func probe(_ b64: String) -> (isTransportStream: Bool, videoStreamType: UInt8?) {
        let data = [UInt8](Data(base64Encoded: b64)!)
        let isTS = data.count >= 189 && data[0] == 0x47 && data[188] == 0x47

        // Pass 1 — PAT (PID 0): collect the program's PMT PID(s).
        var pmtPIDs = Set<Int>()
        var idx = 0
        while idx + 188 <= data.count {
            let pkt = Array(data[idx..<idx+188]); idx += 188
            let pid = (Int(pkt[1] & 0x1f) << 8) | Int(pkt[2])
            guard pid == 0, pkt[1] & 0x40 != 0 else { continue }   // PID 0 + payload-unit-start
            let p = 4 + 1 + Int(pkt[4])                            // skip TS header + pointer field
            let sectionLen = (Int(pkt[p+1] & 0x0f) << 8) | Int(pkt[p+2])
            var i = p + 8                                          // first program entry
            let end = p + 3 + sectionLen - 4                       // minus CRC32
            while i + 4 <= end {
                let programNum = (Int(pkt[i]) << 8) | Int(pkt[i+1])
                let mapPID = (Int(pkt[i+2] & 0x1f) << 8) | Int(pkt[i+3])
                if programNum != 0 { pmtPIDs.insert(mapPID) }
                i += 4
            }
        }

        // Pass 2 — PMT: first video stream_type (MPEG-1/2 video, H.264, or HEVC).
        idx = 0
        while idx + 188 <= data.count {
            let pkt = Array(data[idx..<idx+188]); idx += 188
            let pid = (Int(pkt[1] & 0x1f) << 8) | Int(pkt[2])
            guard pmtPIDs.contains(pid), pkt[1] & 0x40 != 0 else { continue }
            let p = 4 + 1 + Int(pkt[4])
            let sectionLen = (Int(pkt[p+1] & 0x0f) << 8) | Int(pkt[p+2])
            let programInfoLen = (Int(pkt[p+10] & 0x0f) << 8) | Int(pkt[p+11])
            var q = p + 12 + programInfoLen                       // first ES entry
            let end = p + 3 + sectionLen - 4
            while q + 5 <= end {
                let streamType = pkt[q]
                let esInfoLen = (Int(pkt[q+3] & 0x0f) << 8) | Int(pkt[q+4])
                if [0x01, 0x02, 0x1b, 0x24].contains(streamType) {
                    return (isTS, streamType)
                }
                q += 5 + esInfoLen
            }
        }
        return (isTS, nil)
    }

    @Test func rawProfileIsMpeg2InsideTransportStream() {
        let r = probe(Self.noneFixture)
        #expect(r.isTransportStream)          // container = MPEG-TS
        #expect(r.videoStreamType == 0x02)    // MPEG-2 video
    }

    @Test func transcodedProfileIsH264InsideSameTransportStream() {
        let r = probe(Self.heavyFixture)
        #expect(r.isTransportStream)          // still MPEG-TS — the container never changes
        #expect(r.videoStreamType == 0x1b)    // only the video codec differs: H.264/AVC
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
}
