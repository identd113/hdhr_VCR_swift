import AVFoundation
import UniformTypeIdentifiers

// Part of the web-streaming feature (docs/WebStreaming.md). Follows a transport-stream file that is still
// being written (a recording, or a spooled live tuner stream) and turns it into HLS as it grows.
//
// AVFoundation reads a file as a snapshot of what is on disk when it is opened, so each pass re-opens the
// file, reads only what is new, and appends it to ONE long-lived writer (continuous timestamps, no seams).
// The last `holdBack` seconds of each snapshot are left for the next pass so a half-written tail is never read.
// Verified in docs/WebStreaming.md: no frame lost or repeated across passes.

final class HLSFollower: @unchecked Sendable {
    struct Options {
        var convert = HLSConversionOptions()
        /// How often to look for new data.
        var passInterval = 1.0
        /// Seconds at the end of each snapshot left unread (the tail may be half-written).
        var holdBack = 1.0
        /// For a file that is still growing: begin this many seconds before its end instead of at its first frame,
        /// so a viewer joining a long recording is not made to wait for (or store) the whole backlog. nil = from the start.
        var startBehindLive: Double?
        /// Most recent segments kept on disk (older ones are deleted so a long show cannot fill the disk). nil = keep all.
        var keepSegments: Int?
    }

    /// Consecutive failed passes (about a minute at the default interval) before giving up.
    private static let maxFailedPasses = 20
    /// Consecutive passes with no readable picture (about two minutes at the default interval) before giving up.
    private static let maxPassesWithoutPicture = 40
    /// Longest a pass waits for the writer to take the next sample before leaving the rest for the next pass.
    private static let feedPatience = 1.5

    private var activeWriter: AVAssetWriter?
    /// The audio-only twin of the stream (same audio samples, no picture); nil when the file has no audio or it failed.
    private var audioOnlyWriter: AVAssetWriter?
    private var audioOnlyIn: AVAssetWriterInput?
    private var streamStart = 0.0
    private var frameDuration = 1.0 / 30

    private let input: URL
    private let outputDir: URL
    private let options: Options
    private let isGrowing: @Sendable () -> Bool

    /// `isGrowing` returns false once nothing more will be appended (the recording ended); the follower then
    /// reads the rest, finishes the stream and writes the final playlist.
    init(input: URL, outputDir: URL, options: Options = Options(), isGrowing: @escaping @Sendable () -> Bool) {
        self.input = input
        self.outputDir = outputDir
        self.options = options
        self.isGrowing = isGrowing
    }

    /// Runs until the file stops growing (then returns the finished result) or the task is cancelled
    /// (throws `CancellationError`, leaving the files for the caller to delete).
    func run() async throws -> HLSConversionResult {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let sink = HLSConverter.SegmentSink(directory: outputDir, keep: options.keepSegments)
        // Publish the live playlist as segments land, not only at the end of a pass: the first pass over an
        // already-long recording can take longer than a browser is willing to wait for index.m3u8.
        let playlistURL = outputDir.appendingPathComponent("index.m3u8")
        sink.startPublishing { segments in
            guard segments.count >= HLSPlaylist.minLiveSegments else { return }
            try? HLSPlaylist.render(segments: segments, finished: false).write(to: playlistURL, atomically: true, encoding: .utf8)
        }
        let audioSink = HLSConverter.SegmentSink(directory: outputDir, keep: options.keepSegments, prefix: "a-")
        let audioPlaylistURL = outputDir.appendingPathComponent(HLSPlaylist.audioPlaylistName)
        audioSink.startPublishing { segments in
            guard segments.count >= HLSPlaylist.minLiveSegments else { return }
            try? HLSPlaylist.render(segments: segments, initName: "a-init.mp4", finished: false).write(to: audioPlaylistURL, atomically: true, encoding: .utf8)
        }
        var writer: AVAssetWriter?
        var videoIn: AVAssetWriterInput?
        var audioIn: AVAssetWriterInput?
        var videoCursor = -Double.infinity   // latest timestamp sent, per track (not the end of the last sample)
        var audioCursor = -Double.infinity
        var startTime: CMTime = .zero
        var finalPass = false
        var audioFinished = false
        var failedPasses = 0   // consecutive passes that could not open/read the file
        var writerFailures = 0 // consecutive passes whose writer could not be set up (unsupported picture, encoder busy…)
        var passesWithoutPicture = 0   // consecutive passes that found no readable video track
        var finishedNormally = false
        // Any way out but a clean finish (a stop, a failure) must release the half-written output.
        defer {
            if !finishedNormally {
                if let w = writer, w.status == .writing { w.cancelWriting() }
                if let a = audioOnlyWriter, a.status == .writing { a.cancelWriting() }
            }
        }

        while true {
            try Task.checkCancellation()
            // Decide "final" BEFORE reading, so bytes appended between the check and the read are still caught.
            finalPass = !isGrowing()
            let hold = finalPass ? 0 : options.holdBack

            let asset = AVURLAsset(url: input)
            let tracks = (try? await asset.load(.tracks)) ?? []
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            if let vt = tracks.first(where: { $0.mediaType == .video }), duration.isFinite, duration > 0 {
                passesWithoutPicture = 0
                let at = tracks.first(where: { $0.mediaType == .audio })
                let joinAt = (options.startBehindLive != nil && !finalPass) ? max(0, duration - hold - options.startBehindLive!) : nil
                if writer == nil {
                    do {
                        let made = try await makeWriter(video: vt, hasAudio: at != nil, sink: sink, startOffset: joinAt)
                        writer = made.writer; activeWriter = made.writer; videoIn = made.video; audioIn = made.audio; startTime = made.start
                        if at != nil { makeAudioOnlyWriter(sink: audioSink, start: startTime) }
                        videoCursor = startTime.seconds - 1
                        audioCursor = startTime.seconds - 1
                        streamStart = startTime.seconds
                        let fps = (try? await vt.load(.nominalFrameRate)) ?? 0
                        frameDuration = fps > 1 ? 1 / Double(fps) : 1.0 / 30
                    } catch {
                        if error is CancellationError || Task.isCancelled { throw CancellationError() }
                        // Used to be swallowed: a picture the writer cannot take left this loop retrying silently forever.
                        writerFailures += 1
                        if writerFailures == 1 || writerFailures % 10 == 0 {
                            glog("[Stream] \(input.lastPathComponent): could not set up the writer (\(writerFailures) in a row): \(error.localizedDescription) [\(error)]", level: .warning)
                        }
                        if finalPass || writerFailures >= Self.maxFailedPasses { throw error }
                    }
                }
                let end = startTime.seconds + max(0, duration - hold)
                if writer != nil, let videoIn {
                    // A file that has only just started (or is mid-packet) may not parse yet: that is "try again next
                    // pass", not an error. Only a long run of failures, or a failure on the last pass, is reported.
                    do {
                        try await readPass(asset: asset, videoTrack: vt, audioTrack: at, videoIn: videoIn, audioIn: audioIn,
                                           videoCursor: &videoCursor, audioCursor: &audioCursor, end: end)
                        if finalPass {
                            // Nothing more will arrive: finish audio so the writer stops holding video back for
                            // interleaving, then hand over whatever video was left unsent.
                            audioIn?.markAsFinished()
                            audioOnlyIn?.markAsFinished()
                            audioFinished = true
                            try await readPass(asset: asset, videoTrack: vt, audioTrack: at, videoIn: videoIn, audioIn: audioIn,
                                               videoCursor: &videoCursor, audioCursor: &audioCursor, end: end, includeAudio: false)
                        }
                        failedPasses = 0
                        // A failed writer never becomes ready again, so every later pass would just wait: report it now.
                        if let w = writer, w.status == .failed {
                            throw HLSConverterError.cannotWrite(w.error.map { "\($0)" } ?? "writer failed")
                        }
                    } catch {
                        if error is CancellationError || Task.isCancelled { throw CancellationError() }   // a stop, not a failed pass
                        failedPasses += 1
                        if failedPasses == 1 || failedPasses % 10 == 0 {
                            glog("[Stream] \(input.lastPathComponent): read pass failed (\(failedPasses) in a row): \(error.localizedDescription)", level: .warning)
                        }
                        if finalPass || failedPasses >= Self.maxFailedPasses { throw error }
                    }
                }
            }
            else {
                // No readable picture yet. A new recording needs ~12 s; a source that never has one (radio, an unsupported
                // codec) used to be polled forever.
                passesWithoutPicture += 1
                if passesWithoutPicture >= Self.maxPassesWithoutPicture { throw HLSConverterError.noVideoTrack }
            }
            if finalPass { break }
            try await Task.sleep(nanoseconds: UInt64(options.passInterval * 1_000_000_000))
        }

        guard let writer else { throw HLSConverterError.noVideoTrack }
        finishedNormally = true
        videoIn?.markAsFinished()
        if !audioFinished { audioIn?.markAsFinished(); audioOnlyIn?.markAsFinished() }
        await writer.finishWriting()
        if let aw = audioOnlyWriter {
            await aw.finishWriting()
            audioSink.stopPublishing()
            if aw.status == .completed {
                try? HLSPlaylist.render(segments: audioSink.segments, initName: "a-init.mp4", finished: true).write(to: audioPlaylistURL, atomically: true, encoding: .utf8)
            }
        }
        sink.stopPublishing()   // the final VOD playlist below must not be overwritten by a late live one
        guard writer.status == .completed else { throw HLSConverterError.cannotWrite(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)") }
        let segments = sink.segments
        let url = try writePlaylist(sink: sink, finished: true)
        return HLSConversionResult(segments: segments, duration: segments.reduce(0) { $0 + $1.duration }, playlistURL: url)
    }

    @discardableResult
    private func writePlaylist(sink: HLSConverter.SegmentSink, finished: Bool) throws -> URL {
        let url = outputDir.appendingPathComponent("index.m3u8")
        try HLSPlaylist.render(segments: sink.segments, finished: finished).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A second, audio-only HLS writer fed with the same audio as the main one (for listening with the screen locked, at a
    /// fraction of the bandwidth). Optional: if it cannot be set up, the stream simply has no audio-only twin.
    private func makeAudioOnlyWriter(sink: HLSConverter.SegmentSink, start: CMTime) {
        let w = HLSConverter.makeHLSWriter(start: start, options: options.convert, sink: sink)
        let a = AVAssetWriterInput(mediaType: .audio, outputSettings: HLSConverter.aacInputSettings(options: options.convert))
        a.expectsMediaDataInRealTime = false
        guard w.canAdd(a) else { return }
        w.add(a)
        guard w.startWriting() else { glog("[Stream] audio-only twin unavailable: \(w.error?.localizedDescription ?? "unknown")", level: .warning); return }
        w.startSession(atSourceTime: start)
        audioOnlyWriter = w; audioOnlyIn = a
    }

    /// Hands one audio sample to the audio-only twin, waiting briefly if it is busy. Never throws: a problem here must not
    /// stop the picture stream, it just ends the twin.
    private func appendToAudioOnly(_ sample: CMSampleBuffer) async {
        guard let w = audioOnlyWriter, let a = audioOnlyIn else { return }
        if w.status == .failed { audioOnlyWriter = nil; audioOnlyIn = nil; return }
        var waited = 0.0
        while !a.isReadyForMoreMediaData, waited < Self.feedPatience {
            try? await Task.sleep(nanoseconds: 15_000_000); waited += 0.015
        }
        if a.isReadyForMoreMediaData { a.append(sample) }
    }

    private func makeWriter(video: AVAssetTrack, hasAudio: Bool, sink: HLSConverter.SegmentSink, startOffset: Double?) async throws
        -> (writer: AVAssetWriter, video: AVAssetWriterInput, audio: AVAssetWriterInput?, start: CMTime) {
        let size = try await video.load(.naturalSize)
        // A file still being recorded can refuse to report the track's range (-12990); finished files start at 0.
        let trackStart = (try? await video.load(.timeRange).start) ?? .zero
        let start = startOffset.map { CMTimeAdd(trackStart, CMTime(seconds: $0, preferredTimescale: 90000)) } ?? trackStart
        let writer = HLSConverter.makeHLSWriter(start: start, options: options.convert, sink: sink)
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: HLSConverter.videoInputSettings(width: Int(size.width), height: Int(size.height), options: options.convert))
        videoIn.expectsMediaDataInRealTime = false
        writer.add(videoIn)
        var audioIn: AVAssetWriterInput?
        if hasAudio {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: HLSConverter.aacInputSettings(options: options.convert))
            a.expectsMediaDataInRealTime = false
            writer.add(a)
            audioIn = a
        }
        guard writer.startWriting() else { throw HLSConverterError.cannotWrite(writer.error?.localizedDescription ?? "unknown") }
        writer.startSession(atSourceTime: start)
        return (writer, videoIn, audioIn, start)
    }

    /// Reads [cursor, end) of video and audio from this snapshot and appends it to the long-lived writer inputs.
    /// Video and audio each have their own cursor, so neither re-sends nor skips a sample at a pass boundary.
    private func readPass(asset: AVURLAsset, videoTrack: AVAssetTrack, audioTrack: AVAssetTrack?,
                          videoIn: AVAssetWriterInput, audioIn: AVAssetWriterInput?,
                          videoCursor: inout Double, audioCursor: inout Double, end: Double, includeAudio: Bool = true) async throws {
        var video: Stream?
        var audio: Stream?
        if end > videoCursor {
            let r = try AVAssetReader(asset: asset)
            r.timeRange = CMTimeRange(start: CMTime(seconds: max(videoCursor, streamStart), preferredTimescale: 90000), end: CMTime(seconds: end, preferredTimescale: 90000))
            let o = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: HLSConverter.nv12ReaderSettings)
            r.add(o)
            guard r.startReading() else { throw HLSConverterError.cannotRead(r.error?.localizedDescription ?? "unknown") }
            video = Stream(reader: r, output: o, input: videoIn, skipUpTo: videoCursor + frameDuration / 2)
        }
        if includeAudio, let audioTrack, let audioIn, end > audioCursor {
            let r = try AVAssetReader(asset: asset)
            r.timeRange = CMTimeRange(start: CMTime(seconds: max(audioCursor, streamStart), preferredTimescale: 90000), end: CMTime(seconds: end, preferredTimescale: 90000))
            let o = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: HLSConverter.pcmReaderSettings)
            r.add(o)
            guard r.startReading() else { throw HLSConverterError.cannotRead(r.error?.localizedDescription ?? "unknown") }
            audio = Stream(reader: r, output: o, input: audioIn, skipUpTo: audioCursor + 0.05)
        }
        try await feed(video: video, audio: audio)
        if let last = video?.maxPTS { videoCursor = last }
        if let last = audio?.maxPTS { audioCursor = last }
    }

    /// One reader output feeding one writer input, with its next sample already pulled.
    private final class Stream {
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        let input: AVAssetWriterInput
        /// Samples at or before this timestamp were already sent by an earlier pass.
        let skipUpTo: Double
        var next: CMSampleBuffer?
        /// Latest timestamp appended. Video comes out in decode order, so this is the MAX, not the last one.
        var maxPTS: Double?
        init(reader: AVAssetReader, output: AVAssetReaderTrackOutput, input: AVAssetWriterInput, skipUpTo: Double) {
            self.reader = reader; self.output = output; self.input = input; self.skipUpTo = skipUpTo
            pullNext()
        }
        var nextPTS: Double { next.map { CMSampleBufferGetPresentationTimeStamp($0).seconds } ?? .infinity }
        /// Takes the next sample that is new. A reader opened partway through a frame hands back that same frame
        /// again with its timestamp clamped to the start of the range (about 1 ms after the original): the
        /// half-frame margin in `skipUpTo` drops it, while the real next frame is a whole frame later.
        func pullNext() {
            while let sample = output.copyNextSampleBuffer() {
                if CMSampleBufferGetPresentationTimeStamp(sample).seconds > skipUpTo { next = sample; return }
            }
            next = nil
        }
    }

    /// Appends both streams, earliest timestamp first (the writer wants video and audio roughly interleaved), but always
    /// to whichever input the writer is READY to take. The writer holds one track back until the other has caught up, so
    /// insisting on the earlier track while the writer is waiting for the later one deadlocks: video stuck "not ready"
    /// waiting for audio that this loop would only offer after the video. Waits only when neither input is ready.
    /// `requestMediaDataWhenReady` is not usable here: AVFoundation allows it once per input, and these inputs live
    /// across many passes. Inputs are NOT finished here.
    private func feed(video: Stream?, audio: Stream?) async throws {
        var waited = 0.0
        while true {
            let pending = [video, audio].compactMap { $0 }.filter { $0.next != nil }.sorted { $0.nextPTS < $1.nextPTS }
            guard !pending.isEmpty else { return }
            guard let pick = pending.first(where: { $0.input.isReadyForMoreMediaData }), let sample = pick.next else {
                try Task.checkCancellation()
                if let w = activeWriter, w.status == .failed { throw HLSConverterError.cannotWrite(w.error.map { "\($0)" } ?? "writer failed") }
                // Neither input will take a sample right now. Give up the rest of this pass after a while: the unsent
                // samples stay put and the next pass (with fresher data) resumes from the cursors.
                if waited >= Self.feedPatience { return }
                try await Task.sleep(nanoseconds: 15_000_000)
                waited += 0.015
                continue
            }
            waited = 0
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard pick.input.append(sample) else { throw HLSConverterError.cannotWrite("writer refused a sample") }
            if pick === audio { await appendToAudioOnly(sample) }
            pick.maxPTS = max(pick.maxPTS ?? -.infinity, pts)
            pick.pullNext()
        }
    }
}
