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
// References live next to this file at Tests/hdhr_VCRTests/Views/__Snapshots__/<name>.png

@MainActor
func assertSnapshot<V: View>(
    _ view: V,
    named name: String,
    size: CGSize = CGSize(width: 320, height: 500),
    tolerance: Double = 0.02,
    // ScrollView/List content renders entirely blank under plain ImageRenderer — it never performs
    // the live NSScrollView/hosting-window layout pass those containers expect (a documented
    // ImageRenderer limitation, confirmed by hand against WatchNowView's ScrollView branch: same
    // pixels as an empty view regardless of row count). Views containing one need the real
    // NSHostingView + off-screen NSWindow capture path instead — see renderViaHostingWindow below.
    usesScrollView: Bool = false,
    sourceFile: StaticString = #filePath
) {
    let snapshotDir = URL(fileURLWithPath: "\(sourceFile)")
        .deletingLastPathComponent()
        .appendingPathComponent("__Snapshots__")
    let refPath = snapshotDir.appendingPathComponent("\(name).png")

    let cgImageOrNil = usesScrollView ? renderViaHostingWindow(view, size: size) : render(view, size: size)
    guard let cgImage = cgImageOrNil else {
        Issue.record("\(usesScrollView ? "renderViaHostingWindow" : "ImageRenderer") produced no output for '\(name)'")
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

// ImageRenderer alone (see above) never performs the live layout pass ScrollView/List need — hand
// verified: forcing a layout pass on a *separate* off-screen NSHostingView/NSWindow first, then
// still rendering through a plain `ImageRenderer(content:)`, produced the exact same blank result
// (only the toolbar/divider above the ScrollView painted — confirmed by inspecting the saved PNG).
// ImageRenderer builds its own independent view graph internally, so layout work done on a
// different NSHostingView instance never carries over to it. So this bypasses ImageRenderer
// entirely for ScrollView-containing views: render straight from the real, laid-out NSHostingView
// via -cacheDisplay(in:to:), the same mechanism AppKit uses to rasterize any live view hierarchy.
//
// The window is positioned far off in negative screen coordinates rather than made zero-alpha,
// since orderFront() below is required either way (see comment on it) — parking a real,
// order-fronted window off in space keeps it out of any visible display without needing a second
// mechanism to hide it.
//
// Capture goes through -bitmapImageRepForCachingDisplay:/-cacheDisplay(in:to:) — the same
// mechanism AppKit uses to rasterize any live view hierarchy — rather than manually rendering the
// view's CALayer into a CGContext at an explicit scale: that alternative was tried and produced a
// flipped, content-less image (CALayer.render(in:) needs the context pre-flipped to match AppKit's
// coordinate space, and even flipped it didn't reliably capture the hosted SwiftUI subtree).
// -cacheDisplay(in:to:) resolves at the window's backingScaleFactor, which is tied to whatever
// screen the window ends up associated with — 1x in this sandbox (confirmed via
// NSScreen.main?.backingScaleFactor), so this snapshot's reference may render at a lower pixel
// density than the other, ImageRenderer-based ones (which fix scale=2.0 in software); harmless,
// since pixelDifference() resamples both images to a common canvas size before comparing.
@MainActor
private func renderViaHostingWindow<V: View>(_ view: V, size: CGSize) -> CGImage? {
    let hostingView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    hostingView.setFrameSize(size)

    let window = NSWindow(
        contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    // Force light appearance so text/materials render the same way ImageRenderer's other snapshot
    // targets do (they default to light regardless of system setting) — without this, an
    // off-screen NSWindow inherits the *system's* current appearance, which produced near-white
    // text on a light background when first tried (confirmed by inspecting the saved PNG).
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = hostingView
    // orderFront (not just setting contentView) is what actually drives SwiftUI's layout engine
    // to run — a window that's never ordered leaves the hosting view's SwiftUI-side geometry
    // uncomputed even though its AppKit frame is set, and ScrollView content stays unlaid-out.
    window.orderFront(nil)
    hostingView.layoutSubtreeIfNeeded()
    defer { window.orderOut(nil); window.close() }

    guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else { return nil }
    hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
    return rep.cgImage
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
