import AVFoundation
import UniformTypeIdentifiers

// Part of the web-streaming feature (docs/WebStreaming.md). Reads a transport-stream recording with
// AVFoundation (MPEG-2/H.264 video, AC-3/AAC audio; interlaced video comes out progressive) and writes
// fragmented-MP4 HLS segments: hardware H.264 (VideoToolbox) plus stereo AAC. No VLC involved.

struct HLSConversionOptions {
    var videoKbps = 4000
    var audioKbps = 128
    /// Segment length. A live player needs three segments before it starts, so this sets the start-up time: 2 s = 6 s of picture.
    var segmentSeconds = 2.0
    /// Convert only this many seconds from the start of the file (nil = all of it).
    var maxSeconds: Double?
}

extension HLSConversionOptions {
    /// Video bitrate for a picture of this size: `videoKbps` is the 720p-and-up figure; smaller pictures get a
    /// share of it by pixel count (never below 1200 kb/s), so a 480p show is not stored at 720p's size.
    func videoKbps(width: Int, height: Int) -> Int {
        let scaled = Double(videoKbps) * Double(width * height) / Double(1280 * 720)
        return min(videoKbps, max(1200, Int(scaled)))
    }
}

extension HLSConverter {
    /// One place for the encoder/decoder settings, so the whole-file converter, the live follower and the audio-only twin cannot drift apart.
    static func videoInputSettings(width: Int, height: Int, options: HLSConversionOptions) -> [String: Any] {
        [AVVideoCodecKey: AVVideoCodecType.h264,
         AVVideoWidthKey: width, AVVideoHeightKey: height,
         AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: options.videoKbps(width: width, height: height) * 1000,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoMaxKeyFrameIntervalDurationKey: max(1, options.segmentSeconds / 2),   // a keyframe at least twice per segment so every segment starts on one
            AVVideoAllowFrameReorderingKey: true]]
    }
    static func aacInputSettings(options: HLSConversionOptions) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 2, AVSampleRateKey: 48000,
         AVEncoderBitRateKey: options.audioKbps * 1000]
    }
    static let nv12ReaderSettings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
    static let pcmReaderSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2]   // 5.1 is mixed down to stereo here
    /// A fragmented-MP4 HLS writer that hands its segments to `sink`.
    static func makeHLSWriter(start: CMTime, options: HLSConversionOptions, sink: SegmentSink) -> AVAssetWriter {
        let writer = AVAssetWriter(contentType: UTType(AVFileType.mp4.rawValue)!)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: options.segmentSeconds, preferredTimescale: 1)
        writer.initialSegmentStartTime = start
        writer.delegate = sink
        return writer
    }
}

struct HLSConversionResult {
    let segments: [HLSSegment]
    let duration: Double
    let playlistURL: URL
}

enum HLSConverterError: Error, Equatable {
    case noVideoTrack
    case cannotRead(String)
    case cannotWrite(String)
}

enum HLSConverter {
    /// Converts the whole file (or `options.maxSeconds` of it) into `outputDir`: `init.mp4`, `seg-00001.m4s`…, `index.m3u8`.
    static func convert(input: URL, outputDir: URL, options: HLSConversionOptions = HLSConversionOptions()) async throws -> HLSConversionResult {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let asset = AVURLAsset(url: input)
        let tracks = try await asset.load(.tracks)
        guard let videoTrack = tracks.first(where: { $0.mediaType == .video }) else { throw HLSConverterError.noVideoTrack }
        let audioTrack = tracks.first(where: { $0.mediaType == .audio })   // the first program; 5.1 is mixed down to stereo below

        let size = try await videoTrack.load(.naturalSize)
        let start = try await videoTrack.load(.timeRange).start
        let total = try await asset.load(.duration).seconds
        let length = min(total, options.maxSeconds ?? total)

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: start, duration: CMTime(seconds: length, preferredTimescale: 90000))
        let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nv12ReaderSettings)
        reader.add(videoOut)
        var audioOut: AVAssetReaderTrackOutput?
        if let audioTrack {
            let out = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: pcmReaderSettings)
            reader.add(out)
            audioOut = out
        }

        let sink = SegmentSink(directory: outputDir)
        let writer = makeHLSWriter(start: start, options: options, sink: sink)

        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoInputSettings(width: Int(size.width), height: Int(size.height), options: options))
        videoIn.expectsMediaDataInRealTime = false
        writer.add(videoIn)
        var audioIn: AVAssetWriterInput?
        if audioOut != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: aacInputSettings(options: options))
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioIn = input
        }

        guard reader.startReading() else { throw HLSConverterError.cannotRead(reader.error?.localizedDescription ?? "unknown") }
        guard writer.startWriting() else { throw HLSConverterError.cannotWrite(writer.error?.localizedDescription ?? "unknown") }
        writer.startSession(atSourceTime: start)

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await pump(videoOut, into: videoIn, label: "hls.video") }
            if let audioOut, let audioIn { group.addTask { await pump(audioOut, into: audioIn, label: "hls.audio") } }
        }
        if reader.status == .failed { writer.cancelWriting(); throw HLSConverterError.cannotRead(reader.error?.localizedDescription ?? "unknown") }
        await writer.finishWriting()
        guard writer.status == .completed else { throw HLSConverterError.cannotWrite(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)") }

        let segments = sink.segments
        let playlistURL = outputDir.appendingPathComponent("index.m3u8")
        try HLSPlaylist.render(segments: segments, finished: true).write(to: playlistURL, atomically: true, encoding: .utf8)
        return HLSConversionResult(segments: segments, duration: segments.reduce(0) { $0 + $1.duration }, playlistURL: playlistURL)
    }

    /// Feeds sample buffers from one reader output into one writer input until the reader runs dry.
    static func pump(_ output: AVAssetReaderTrackOutput, into input: AVAssetWriterInput, label: String) async {
        let box = PumpBox(output: output, input: input)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            box.input.requestMediaDataWhenReady(on: DispatchQueue(label: label)) {
                while box.input.isReadyForMoreMediaData {
                    guard let sample = box.output.copyNextSampleBuffer() else {
                        box.input.markAsFinished()
                        done.resume()
                        return
                    }
                    box.input.append(sample)
                }
            }
        }
    }

    // AVFoundation objects are used from one queue at a time here; the box only carries them into the closure.
    final class PumpBox: @unchecked Sendable {
        let output: AVAssetReaderTrackOutput
        let input: AVAssetWriterInput
        init(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput) { self.output = output; self.input = input }
    }

    /// Receives the writer's init segment and media segments and saves them as files.
    final class SegmentSink: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
        private let directory: URL
        private let lock = NSLock()
        private var items: [HLSSegment] = []
        private var count = 0
        private let keep: Int?
        private let prefix: String
        /// `keep`: most recent media segments to keep on disk and in the playlist (nil = all). Older files are deleted.
        /// `prefix`: put in front of every file name ("a-" for the audio-only twin of a stream).
        init(directory: URL, keep: Int? = nil, prefix: String = "") { self.directory = directory; self.keep = keep; self.prefix = prefix }

        var segments: [HLSSegment] { lock.lock(); defer { lock.unlock() }; return items }

        /// Called (on the writer's queue) after each media segment is saved, with all segments so far. Lets a live
        /// playlist appear while a long backlog is still being converted. Cleared with `stopPublishing()`.
        private var publish: (([HLSSegment]) -> Void)?
        func startPublishing(_ handler: @escaping ([HLSSegment]) -> Void) { lock.lock(); publish = handler; lock.unlock() }
        func stopPublishing() { lock.lock(); publish = nil; lock.unlock() }

        func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data, segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
            switch segmentType {
            case .initialization:
                try? segmentData.write(to: directory.appendingPathComponent(prefix + "init.mp4"))
            case .separable:
                lock.lock(); count += 1; let name = prefix + String(format: "seg-%05d.m4s", count); lock.unlock()
                try? segmentData.write(to: directory.appendingPathComponent(name))
                let reports = segmentReport?.trackReports ?? []
                let seconds = (reports.first(where: { $0.mediaType == .video }) ?? reports.first)?.duration.seconds ?? 4
                lock.lock(); items.append(HLSSegment(name: name, duration: seconds))
                var dropped: [HLSSegment] = []
                if let keep, items.count > keep { dropped = Array(items.prefix(items.count - keep)); items.removeFirst(dropped.count) }
                let all = items, handler = publish; lock.unlock()
                for old in dropped { try? FileManager.default.removeItem(at: directory.appendingPathComponent(old.name)) }
                handler?(all)
            @unknown default:
                break
            }
        }
    }
}
