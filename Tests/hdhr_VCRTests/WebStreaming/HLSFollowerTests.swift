import Foundation
import Testing
@testable import hdhr_VCR

// A growing file is simulated by appending the 6 s sample (Fixtures/) in uneven chunks while the follower runs.
@Suite("HLS follower (growing recording)", .serialized)
struct HLSFollowerTests {
    private var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/sample-mpeg2-ac3.ts")
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = true
        var isOn: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func off() { lock.lock(); value = false; lock.unlock() }
    }

    private func writeGrowing(_ data: Data, to url: URL, chunks: Int, gap: TimeInterval, flag: Flag) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try! FileHandle(forWritingTo: url)
        Thread.detachNewThread {
            let step = data.count / chunks + 1   // not a multiple of 188: chunks end mid-packet, like a real writer
            var offset = 0
            while offset < data.count {
                let end = min(data.count, offset + step)
                try? handle.write(contentsOf: data[offset..<end])
                offset = end
                Thread.sleep(forTimeInterval: gap)
            }
            try? handle.close()
            flag.off()
        }
    }

    @Test func followsAGrowingFileAndFinishesWhenItStopsGrowing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hls-follow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let growing = dir.appendingPathComponent("growing.ts")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let flag = Flag()
        writeGrowing(try Data(contentsOf: fixture), to: growing, chunks: 12, gap: 0.3, flag: flag)

        var opts = HLSFollower.Options()
        opts.convert.videoKbps = 800
        opts.convert.segmentSeconds = 1
        opts.passInterval = 0.4
        opts.holdBack = 0.5
        let out = dir.appendingPathComponent("out")
        let follower = HLSFollower(input: growing, outputDir: out, options: opts, isGrowing: { flag.isOn })

        // While it runs, a playlist without ENDLIST should appear (live/EVENT), then the final one has it.
        let sawLive = LiveWatch()
        let watcher = Task {
            while !Task.isCancelled {
                if let text = try? String(contentsOf: out.appendingPathComponent("index.m3u8"), encoding: .utf8),
                   text.contains("#EXTINF"), !text.contains("#EXT-X-ENDLIST") { sawLive.set() }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        let result = try await follower.run()
        watcher.cancel()

        #expect(sawLive.value, "an in-progress playlist (no ENDLIST) should be visible while the file grows")
        #expect(result.segments.count >= 3)
        #expect(abs(result.duration - 6) < 1.5, "followed duration \(result.duration) should be about the file's 6 s")
        let text = try String(contentsOf: result.playlistURL, encoding: .utf8)
        #expect(text.contains("#EXT-X-ENDLIST"))
        // continuity: no segment is wildly short or long (that would mean a seam or a stall)
        for s in result.segments.dropLast() { #expect(s.duration > 0.4 && s.duration < 2.6, "\(s.name) lasted \(s.duration)") }
    }

    @Test func cancellingStopsTheFollower() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hls-follow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let growing = dir.appendingPathComponent("growing.ts")
        FileManager.default.createFile(atPath: growing.path, contents: nil)
        let follower = HLSFollower(input: growing, outputDir: dir.appendingPathComponent("out"), isGrowing: { true })
        let task = Task { try await follower.run() }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        await #expect(throws: (any Error).self) { _ = try await task.value }
    }

    /// Opt-in (HLS_REAL_SOURCE=/path/to/recording.ts): writes ~2 MB/s of a real recording into a growing file for
    /// HLS_REAL_SECONDS (default 40) and follows it at live speed. Prints the lag between the last byte written and the
    /// finished stream, and leaves the output in HLS_REAL_OUT (if set) for ffprobe/browser checks.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HLS_REAL_SOURCE"] != nil))
    func realRecordingFollowedAtLiveSpeed() async throws {
        let env = ProcessInfo.processInfo.environment
        let source = URL(fileURLWithPath: env["HLS_REAL_SOURCE"]!)
        let seconds = Double(env["HLS_REAL_SECONDS"] ?? "40") ?? 40
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hls-real-\(UUID().uuidString)")
        defer { if env["HLS_REAL_OUT"] == nil { try? FileManager.default.removeItem(at: dir) } }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let growing = dir.appendingPathComponent("growing.ts")
        FileManager.default.createFile(atPath: growing.path, contents: nil)
        let flag = Flag()
        let wroteAt = LiveWatch()
        let src = try FileHandle(forReadingFrom: source)
        let dst = try FileHandle(forWritingTo: growing)
        let started = Date()
        Thread.detachNewThread {
            let tick = 0.125, perTick = 250_000
            while Date().timeIntervalSince(started) < seconds {
                if let chunk = try? src.read(upToCount: perTick) { try? dst.write(contentsOf: chunk) }
                Thread.sleep(forTimeInterval: tick)
            }
            try? dst.close(); wroteAt.set(); flag.off()
        }
        let out = env["HLS_REAL_OUT"].map { URL(fileURLWithPath: $0) } ?? dir.appendingPathComponent("out")
        let follower = HLSFollower(input: growing, outputDir: out, isGrowing: { flag.isOn })
        let result = try await follower.run()
        let lag = Date().timeIntervalSince(started) - seconds
        print("REAL FOLLOW: wrote \(seconds)s, finished \(String(format: "%.1f", lag))s after the last byte; \(result.segments.count) segments, \(String(format: "%.1f", result.duration))s of video")
        #expect(result.duration > seconds * 0.8)
        #expect(lag < 15)
    }

    private final class LiveWatch: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
        func set() { lock.lock(); flag = true; lock.unlock() }
    }
}
