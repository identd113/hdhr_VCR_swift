import AppKit

// Full-resolution image — used in About tab.
let appIconImage: NSImage? = {
    guard let url = Bundle.main.url(forResource: "app", withExtension: "jpg") else { return nil }
    return NSImage(contentsOf: url)
}()

// Proportionally-scaled image for the menu bar status label.
// Height tracks the actual menu bar thickness (2pt padding top+bottom).
// Width preserves the source aspect ratio — no cropping.
// Pre-sized here because NSImage.size drives the render size in NSStatusItem;
// SwiftUI frame() modifiers on Image(nsImage:) are ignored in that context.
let appIconMenuBar: NSImage? = {
    guard let src = appIconImage else { return nil }
    let h = max(16, NSStatusBar.system.thickness - 2)          // fill the bar with 1pt padding each side
    let w = h * (src.size.width / src.size.height)             // preserve source aspect ratio
    let dst = NSImage(size: NSSize(width: w, height: h))
    dst.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    src.draw(in: NSRect(origin: .zero, size: dst.size),
             from: .zero, operation: .copy, fraction: 1.0)
    dst.unlockFocus()
    return dst
}()
