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
