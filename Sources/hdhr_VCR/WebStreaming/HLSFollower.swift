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
        var passInterval = 3.0
        /// Seconds at the end of each snapshot left unread (the tail may be half-written).
        var holdBack = 1.5
    }

    /// Consecutive failed passes (about a minute at the default interval) before giving up.
    private static let maxFailedPasses = 20
    /// Longest a pass waits for the writer to take the next sample before leaving the rest for the next pass.
    private static let feedPatience = 1.5

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
        let sink = HLSConverter.SegmentSink(directory: outputDir)
        var writer: AVAssetWriter?
        var videoIn: AVAssetWriterInput?
        var audioIn: AVAssetWriterInput?
        var videoCursor = -Double.infinity   // latest timestamp sent, per track (not the end of the last sample)
        var audioCursor = -Double.infinity
        var startTime: CMTime = .zero
        var finalPass = false
        var audioFinished = false
        var failedPasses = 0   // consecutive passes that could not open/read the file

        while true {
            try Task.checkCancellation()
            // Decide "final" BEFORE reading, so bytes appended between the check and the read are still caught.
            finalPass = !isGrowing()
            let hold = finalPass ? 0 : options.holdBack

            let asset = AVURLAsset(url: input)
            let tracks = (try? await asset.load(.tracks)) ?? []
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            if let vt = tracks.first(where: { $0.mediaType == .video }), duration.isFinite, duration > 0 {
                let at = tracks.first(where: { $0.mediaType == .audio })
                if writer == nil, let made = try? await makeWriter(video: vt, hasAudio: at != nil, sink: sink) {
                    writer = made.writer; videoIn = made.video; audioIn = made.audio; startTime = made.start
                    videoCursor = startTime.seconds - 1
                    audioCursor = startTime.seconds - 1
                    streamStart = startTime.seconds
                    frameDuration = vt.nominalFrameRate > 1 ? 1 / Double(vt.nominalFrameRate) : 1.0 / 30
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
                            audioFinished = true
                            try await readPass(asset: asset, videoTrack: vt, audioTrack: at, videoIn: videoIn, audioIn: audioIn,
                                               videoCursor: &videoCursor, audioCursor: &audioCursor, end: end, includeAudio: false)
                        }
                        failedPasses = 0
                    } catch {
                        failedPasses += 1
                        if finalPass || failedPasses >= Self.maxFailedPasses { throw error }
                    }
                }
            }
            if writer != nil { try writePlaylist(sink: sink, finished: false) }
            if finalPass { break }
            try await Task.sleep(nanoseconds: UInt64(options.passInterval * 1_000_000_000))
        }

        guard let writer else { throw HLSConverterError.noVideoTrack }
        videoIn?.markAsFinished()
        if !audioFinished { audioIn?.markAsFinished() }
        await writer.finishWriting()
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

    private func makeWriter(video: AVAssetTrack, hasAudio: Bool, sink: HLSConverter.SegmentSink) async throws
        -> (writer: AVAssetWriter, video: AVAssetWriterInput, audio: AVAssetWriterInput?, start: CMTime) {
        let size = try await video.load(.naturalSize)
        let start = try await video.load(.timeRange).start
        let writer = AVAssetWriter(contentType: UTType(AVFileType.mp4.rawValue)!)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: options.convert.segmentSeconds, preferredTimescale: 1)
        writer.initialSegmentStartTime = start
        writer.delegate = sink
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: options.convert.videoKbps * 1000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoAllowFrameReorderingKey: true]])
        videoIn.expectsMediaDataInRealTime = false
        writer.add(videoIn)
        var audioIn: AVAssetWriterInput?
        if hasAudio {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 2, AVSampleRateKey: 48000,
                AVEncoderBitRateKey: options.convert.audioKbps * 1000])
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
            let o = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
            r.add(o)
            guard r.startReading() else { throw HLSConverterError.cannotRead(r.error?.localizedDescription ?? "unknown") }
            video = Stream(reader: r, output: o, input: videoIn, skipUpTo: videoCursor + frameDuration / 2)
        }
        if includeAudio, let audioTrack, let audioIn, end > audioCursor {
            let r = try AVAssetReader(asset: asset)
            r.timeRange = CMTimeRange(start: CMTime(seconds: max(audioCursor, streamStart), preferredTimescale: 90000), end: CMTime(seconds: end, preferredTimescale: 90000))
            let o = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2])
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

    /// Appends both streams in timestamp order (the writer wants video and audio roughly interleaved), waiting
    /// whenever the writer is busy. `requestMediaDataWhenReady` is not usable here: AVFoundation allows it once
    /// per input, and these inputs live across many passes. Inputs are NOT finished here.
    private func feed(video: Stream?, audio: Stream?) async throws {
        while let pick = [video, audio].compactMap({ $0 }).filter({ $0.next != nil }).min(by: { $0.nextPTS < $1.nextPTS }),
              let sample = pick.next {
            var waited = 0.0
            while !pick.input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                // The writer holds one track back until the other has caught up (interleaving). If the other track has
                // nothing more in this snapshot it will never catch up during this pass, so give up the rest of the
                // pass: the unsent samples stay put and the next pass (with fresher data) resumes from the cursors.
                if waited >= Self.feedPatience { return }
                try await Task.sleep(nanoseconds: 3_000_000)
                waited += 0.003
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard pick.input.append(sample) else { throw HLSConverterError.cannotWrite("writer refused a sample") }
            pick.maxPTS = max(pick.maxPTS ?? -.infinity, pts)
            pick.pullNext()
        }
    }
}
