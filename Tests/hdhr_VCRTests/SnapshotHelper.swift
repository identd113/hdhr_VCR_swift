import SwiftUI
import AppKit
import Testing

// Renders a SwiftUI view to a PNG and compares it against a stored reference.
//
// First run (no reference file): saves the PNG and records a test issue —
// commit the new file under __Snapshots__/ then re-run.
//
// To regenerate all references: RECORD_SNAPSHOTS=1 swift test
//
// References live next to this file at Tests/hdhr_VCRTests/__Snapshots__/<name>.png

@MainActor
func assertSnapshot<V: View>(
    _ view: V,
    named name: String,
    size: CGSize = CGSize(width: 320, height: 500),
    tolerance: Double = 0.02,
    sourceFile: StaticString = #filePath
) {
    let snapshotDir = URL(fileURLWithPath: "\(sourceFile)")
        .deletingLastPathComponent()
        .appendingPathComponent("__Snapshots__")
    let refPath = snapshotDir.appendingPathComponent("\(name).png")

    guard let cgImage = render(view, size: size) else {
        Issue.record("ImageRenderer produced no output for '\(name)'")
        return
    }

    let shouldRecord = ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] == "1"
    let exists = FileManager.default.fileExists(atPath: refPath.path)

    if shouldRecord || !exists {
        try? FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
        save(cgImage, to: refPath)
        if !exists {
            Issue.record("""
            No reference snapshot for '\(name)'.
            A new reference was saved to __Snapshots__/\(name).png — commit it and re-run.
            """)
        }
        return
    }

    guard let refImage = load(refPath) else {
        Issue.record("Could not load reference image for '\(name)' at \(refPath.path)")
        return
    }

    let diff = pixelDifference(cgImage, refImage)
    #expect(diff <= tolerance,
            "'\(name)' has \(String(format: "%.2f", diff * 100))% changed pixels (limit \(String(format: "%.0f", tolerance * 100))%)")
}

// MARK: - Private helpers

@MainActor
private func render<V: View>(_ view: V, size: CGSize) -> CGImage? {
    let renderer = ImageRenderer(
        content: view
            .frame(width: size.width, height: size.height)
    )
    renderer.scale = 2.0
    return renderer.cgImage
}

private func save(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: url)
}

private func load(_ url: URL) -> CGImage? {
    guard let data = try? Data(contentsOf: url),
          let src = CGImageSourceCreateWithData(data as CFData, nil)
    else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

// Returns the fraction of pixels that differ beyond the per-channel threshold.
// A threshold of 8/255 tolerates minor subpixel antialiasing variance.
private func pixelDifference(_ a: CGImage, _ b: CGImage) -> Double {
    let w = min(a.width, b.width)
    let h = min(a.height, b.height)
    guard w > 0, h > 0 else { return 1.0 }

    let bpp = 4
    let bpr = w * bpp
    let space = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

    var da = [UInt8](repeating: 0, count: h * bpr)
    var db = [UInt8](repeating: 0, count: h * bpr)

    guard let ca = CGContext(data: &da, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: bpr, space: space, bitmapInfo: bitmapInfo.rawValue),
          let cb = CGContext(data: &db, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: bpr, space: space, bitmapInfo: bitmapInfo.rawValue)
    else { return 1.0 }

    ca.draw(a, in: CGRect(x: 0, y: 0, width: w, height: h))
    cb.draw(b, in: CGRect(x: 0, y: 0, width: w, height: h))

    let channelThreshold = 8
    var diffPixels = 0
    for i in stride(from: 0, to: h * bpr, by: bpp) {
        if abs(Int(da[i])   - Int(db[i]))   > channelThreshold ||
           abs(Int(da[i+1]) - Int(db[i+1])) > channelThreshold ||
           abs(Int(da[i+2]) - Int(db[i+2])) > channelThreshold {
            diffPixels += 1
        }
    }
    return Double(diffPixels) / Double(w * h)
}
