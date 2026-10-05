import AppKit

// Full-resolution image — used in About tab.
let appIconImage: NSImage? = {
    guard let url = Bundle.main.url(forResource: "app", withExtension: "jpg") else { return nil }
    return NSImage(contentsOf: url)
}()

// Recording / up-next variants — same mark, only the built-in status light differs
// (dim → red / amber). Used by the menu bar only; the About tab always shows the idle mark.
private let appIconRecordingImage: NSImage? = {
    guard let url = Bundle.main.url(forResource: "app-recording", withExtension: "jpg") else { return nil }
    return NSImage(contentsOf: url)
}()
private let appIconUpNextImage: NSImage? = {
    guard let url = Bundle.main.url(forResource: "app-upnext", withExtension: "jpg") else { return nil }
    return NSImage(contentsOf: url)
}()
private let appIconFeedImage: NSImage? = {
    guard let url = Bundle.main.url(forResource: "app-feed", withExtension: "jpg") else { return nil }
    return NSImage(contentsOf: url)
}()

// Proportionally-scaled for the menu bar status label. Height tracks the actual menu bar
// thickness (2pt padding top+bottom); width preserves the source aspect ratio — no cropping.
// Pre-sized here because NSImage.size drives the render size in NSStatusItem; SwiftUI
// frame() modifiers on Image(nsImage:) are ignored in that context.
private func menuBarScaled(_ src: NSImage?) -> NSImage? {
    guard let src else { return nil }
    let h = max(16, NSStatusBar.system.thickness - 2)
    let w = h * (src.size.width / src.size.height)
    let dst = NSImage(size: NSSize(width: w, height: h))
    dst.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    src.draw(in: NSRect(origin: .zero, size: dst.size),
             from: .zero, operation: .copy, fraction: 1.0)
    dst.unlockFocus()
    return dst
}

let appIconMenuBar: NSImage? = menuBarScaled(appIconImage)
let appIconMenuBarRecording: NSImage? = menuBarScaled(appIconRecordingImage)
let appIconMenuBarUpNext: NSImage? = menuBarScaled(appIconUpNextImage)
let appIconMenuBarFeed: NSImage? = menuBarScaled(appIconFeedImage)

// Stand-in for a station logo the guide doesn't have (no ImageURL) or hasn't downloaded yet / that
// failed to download. Display-only: the channel's real URL stays in AppState.channelImageURLs, so
// ChannelIconCache keeps fetching it on its normal schedule (and a new URL from a guide refresh is
// fetched at once) and the real logo replaces this the moment it is cached. The same AppIcon.icns
// the web server serves at /api/icon, pre-drawn once at 64×64 (shown at 16–18 pt, so 2× retina).
let stationLogoPlaceholder: NSImage = {
    let size = NSSize(width: 64, height: 64)
    guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
          let src = NSImage(contentsOf: url) else {
        return NSImage(systemSymbolName: "tv", accessibilityDescription: nil) ?? NSImage(size: size)
    }
    // Rasterised ONCE into a real 128×128-pixel bitmap (64 pt @2x). An `NSImage(size:flipped:drawingHandler:)`
    // would look equivalent but re-runs its handler — a full draw of the multi-resolution .icns — every
    // time any view renders it (2026-10-05 review).
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return src }
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    src.draw(in: NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    let image = NSImage(size: size)
    image.addRepresentation(rep)
    return image
}()
