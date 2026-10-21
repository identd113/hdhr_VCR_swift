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

    /// Opt-in experiment: HLS_JOIN_SOURCE=/path/file.ts HLS_JOIN_OFFSETS=10,13.3,17 HLS_JOIN_OUT=/dir converts the file once per
    /// start-behind-live offset (as if it were a growing recording joined late) into /dir/j<offset>/.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HLS_JOIN_SOURCE"] != nil))
    func joinVariantsForBrowserChecks() async throws {
        let env = ProcessInfo.processInfo.environment
        let input = URL(fileURLWithPath: env["HLS_JOIN_SOURCE"]!)
        let out = URL(fileURLWithPath: env["HLS_JOIN_OUT"] ?? "/tmp/join-variants")
        for off in (env["HLS_JOIN_OFFSETS"] ?? "10").split(separator: ",").compactMap({ Double($0) }) {
            let flag = Flag()
            var opts = HLSFollower.Options(startBehindLive: off)
            opts.passInterval = 0.4
            let dir = out.appendingPathComponent("j\(off)")
            try? FileManager.default.removeItem(at: dir)
            Task { try? await Task.sleep(nanoseconds: 1_500_000_000); flag.off() }
            let result = try await HLSFollower(input: input, outputDir: dir, options: opts, isGrowing: { flag.isOn }).run()
            print("JOIN \(off): \(result.segments.count) segments, \(result.duration)s")
        }
    }

    @Test func joiningAGrowingFileStartsBehindLiveInsteadOfAtTheBeginning() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hls-join-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let input = dir.appendingPathComponent("recording.ts")
        try FileManager.default.copyItem(at: fixture, to: input)   // 6 s already on disk, "still recording"
        let flag = Flag()
        var opts = HLSFollower.Options(startBehindLive: 2)
        opts.convert.videoKbps = 800
        opts.convert.segmentSeconds = 1
        opts.passInterval = 0.4
        opts.holdBack = 0.5
        let follower = HLSFollower(input: input, outputDir: dir.appendingPathComponent("out"), options: opts, isGrowing: { flag.isOn })
        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); flag.off() }
        let result = try await follower.run()
        #expect(result.duration > 1.5)
        #expect(result.duration < 5.0, "joined \(result.duration)s of a 6 s recording; expected only the last couple of seconds")
    }

    @Test func aLivePlaylistIsNeverPublishedWithFewerThanThreeSegments() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hls-min-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let growing = dir.appendingPathComponent("growing.ts")
        let flag = Flag()
        writeGrowing(try Data(contentsOf: fixture), to: growing, chunks: 12, gap: 0.3, flag: flag)
        var opts = HLSFollower.Options()
        opts.convert.videoKbps = 800
        opts.convert.segmentSeconds = 1
        opts.passInterval = 0.2
        opts.holdBack = 0.5
        let out = dir.appendingPathComponent("out")
        let follower = HLSFollower(input: growing, outputDir: out, options: opts, isGrowing: { flag.isOn })
        let shortLive = LiveWatch()
        let watcher = Task {
            while !Task.isCancelled {
                if let text = try? String(contentsOf: out.appendingPathComponent("index.m3u8"), encoding: .utf8),
                   !text.contains("#EXT-X-ENDLIST"), text.components(separatedBy: "#EXTINF").count - 1 < HLSPlaylist.minLiveSegments { shortLive.set() }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        _ = try await follower.run()
        watcher.cancel()
        #expect(!shortLive.value, "a live playlist with fewer than 3 segments was visible")
    }

    @Test func onlyTheMostRecentSegmentsStayOnDisk() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hls-keep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let input = dir.appendingPathComponent("recording.ts")
        try FileManager.default.copyItem(at: fixture, to: input)
        var opts = HLSFollower.Options(keepSegments: 2)
        opts.convert.videoKbps = 800
        opts.convert.segmentSeconds = 1
        opts.passInterval = 0.3
        let out = dir.appendingPathComponent("out")
        let result = try await HLSFollower(input: input, outputDir: out, options: opts, isGrowing: { false }).run()
        // "seg-…" only: the audio-only twin keeps its own "a-seg-…" files in the same folder.
        let files = try FileManager.default.contentsOfDirectory(atPath: out.path).filter { $0.hasPrefix("seg-") && $0.hasSuffix(".m4s") }
        #expect(files.count == 2, "kept \(files.count) segment files")
        #expect(result.segments.count == 2)
        let playlist = try String(contentsOf: out.appendingPathComponent("index.m3u8"), encoding: .utf8)
        #expect(!playlist.contains("MEDIA-SEQUENCE:1\n"))
        for seg in result.segments { #expect(files.contains(seg.name)) }
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

    /// Regression: a recording whose audio ends well before its video (or whose audio lags) made the writer hold the
    /// video back for interleaving and the follower wait forever; the stream stalled mid-recording with no error.
    @Test func finishesWhenAudioEndsBeforeVideo() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hls-follow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let shortAudio = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/sample-short-audio.ts")
        var opts = HLSFollower.Options()
        opts.convert.videoKbps = 800
        opts.convert.segmentSeconds = 1
        opts.passInterval = 0.2
        opts.holdBack = 0.3
        let follower = HLSFollower(input: shortAudio, outputDir: dir, options: opts, isGrowing: { false })
        let result: HLSConversionResult? = await withTaskGroup(of: HLSConversionResult?.self) { group in
            group.addTask { try? await follower.run() }
            group.addTask { try? await Task.sleep(nanoseconds: 30_000_000_000); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        let finished = try #require(result, "the follower hung (the writer was holding video back waiting for audio)")
        #expect(finished.duration > 4.5, "all of the 6 s of video should come through, got \(finished.duration)")
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

    /// Opt-in (HLS_FOLLOW_PATH=/path/to/growing.ts): follows a file that something else is writing, for
    /// HLS_FOLLOW_SECONDS (default 60), then finishes. For checking behaviour on the real recordings volume.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HLS_FOLLOW_PATH"] != nil))
    func followsAFileInPlace() async throws {
        let env = ProcessInfo.processInfo.environment
        let seconds = Double(env["HLS_FOLLOW_SECONDS"] ?? "60") ?? 60
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("hls-inplace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        let flag = Flag()
        Task { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); flag.off() }
        let follower = HLSFollower(input: URL(fileURLWithPath: env["HLS_FOLLOW_PATH"]!), outputDir: out, isGrowing: { flag.isOn })
        let result = try await follower.run()
        print("IN-PLACE FOLLOW: \(result.segments.count) segments, \(String(format: "%.1f", result.duration))s of video in \(seconds)s")
    }

    private final class LiveWatch: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
        func set() { lock.lock(); flag = true; lock.unlock() }
    }

    /// A file that never yields a picture (radio, an unsupported or damaged source) used to be polled forever; now the follower gives up.
    @Test func aSourceWithNoPictureIsGivenUpOn() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hls-nopic-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let input = dir.appendingPathComponent("recording.ts")
        try Data(repeating: 0xAB, count: 200_000).write(to: input)   // not a transport stream
        var opts = HLSFollower.Options()
        opts.passInterval = 0.005
        let started = Date()
        await #expect(throws: HLSConverterError.noVideoTrack) {
            _ = try await HLSFollower(input: input, outputDir: dir.appendingPathComponent("out"), options: opts, isGrowing: { true }).run()
        }
        #expect(Date().timeIntervalSince(started) < 30)
    }
}
