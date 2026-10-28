// Usage: swiftc -o read_samples read_samples.swift && ./read_samples file.ts
// Reads the video track of a file with AVAssetReader (NV12 output) over the first 5 seconds and over the last 10 seconds
// of the asset's reported duration, and prints how many frames came back. A 59.94 fps stream has about 300 per 5 s.
import AVFoundation

let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
let done = DispatchSemaphore(value: 0)
Task {
    do {
        let tracks = try await asset.load(.tracks)
        guard let video = tracks.first(where: { $0.mediaType == .video }) else { print("no video track"); exit(1) }
        let duration = try await asset.load(.duration).seconds
        print("asset duration \(duration) s")
        do { _ = try await video.load(.timeRange); print("track timeRange: ok") }
        catch { print("track timeRange: FAILED \(error)") }
        for start in [0.0, max(0, duration - 10)] {
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 90000), duration: CMTime(seconds: 5, preferredTimescale: 90000))
            let output = AVAssetReaderTrackOutput(track: video, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
            reader.add(output)
            guard reader.startReading() else { print("startReading failed: \(String(describing: reader.error))"); continue }
            var count = 0
            while output.copyNextSampleBuffer() != nil { count += 1 }
            print("frames read from \(start) s for 5 s: \(count)   reader status \(reader.status.rawValue) error \(String(describing: reader.error))")
        }
    } catch { print("error: \(error)") }
    done.signal()
}
done.wait()
