import Foundation
import Testing
@testable import hdhr_VCR

// Converts a small synthetic MPEG-2 + AC-3 transport stream (a test pattern and a tone, Fixtures/) with AVFoundation.
@Suite("HLS converter (AVFoundation, no VLC)")
struct HLSConverterTests {
    private var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/sample-mpeg2-ac3.ts")
    }

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("hls-test-\(UUID().uuidString)")
    }

    @Test func convertsMPEG2WithAC3IntoSegmentsAndAPlaylist() async throws {
        let out = tempDir()
        defer { try? FileManager.default.removeItem(at: out) }
        let result = try await HLSConverter.convert(input: fixture, outputDir: out, options: HLSConversionOptions(videoKbps: 800, segmentSeconds: 2))
        #expect(result.segments.count >= 2)
        #expect(abs(result.duration - 6) < 1.0)
        let files = try FileManager.default.contentsOfDirectory(atPath: out.path)
        #expect(files.contains("init.mp4"))
        #expect(files.contains("index.m3u8"))
        for s in result.segments { #expect(files.contains(s.name)); #expect(HLSPlaylist.isServableName(s.name)) }
        let playlist = try String(contentsOf: result.playlistURL, encoding: .utf8)
        #expect(playlist.contains("#EXT-X-ENDLIST"))
        #expect(playlist.components(separatedBy: "#EXTINF").count - 1 == result.segments.count)
    }

    @Test func maxSecondsLimitsHowMuchIsConverted() async throws {
        let out = tempDir()
        defer { try? FileManager.default.removeItem(at: out) }
        let result = try await HLSConverter.convert(input: fixture, outputDir: out, options: HLSConversionOptions(segmentSeconds: 1, maxSeconds: 2))
        #expect(result.duration < 3.5)
    }

    @Test func aFileWithoutVideoIsRejected() async throws {
        let out = tempDir()
        defer { try? FileManager.default.removeItem(at: out) }
        let junk = out.appendingPathExtension("ts")
        try Data(repeating: 0, count: 4096).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }
        await #expect(throws: (any Error).self) {
            _ = try await HLSConverter.convert(input: junk, outputDir: out)
        }
    }

    @Test func bitrateScalesDownForSmallPicturesAndNeverAboveTheConfiguredCeiling() {
        let o = HLSConversionOptions()
        #expect(o.videoKbps(width: 1280, height: 720) == 4000)
        #expect(o.videoKbps(width: 1920, height: 1080) == 4000)
        #expect(o.videoKbps(width: 704, height: 480) < 2000)
        #expect(o.videoKbps(width: 320, height: 240) == 1200)
    }
}
