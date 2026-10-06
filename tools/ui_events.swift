// ui_events.swift — synthetic input for UI tests that Accessibility can't reach.
//
//   ui_events rightclick X Y     right-click at a screen point (global coordinates, top-left origin)
//   ui_events keys CODE [CODE…]  tap virtual key codes, delivered straight to the app's own process
//
// Why it exists: the PiP thumbnail's context menu is a native NSMenu popped at click time
// (`NativeContextMenuHost`). `AXShowMenu` doesn't reach it and a popped NSMenu isn't in the AX tree,
// so the only way to drive it is a real right-click plus keyboard navigation. Keys are posted with
// `CGEventPostToPid` — the app runs as an accessory process and is never frontmost, so a plain
// HID-level key event would land in whatever terminal is running the test instead.
//
// Compiled on demand by `WindowNavigationTests` (`swiftc -O tools/ui_events.swift -o <tmp>`); not
// part of the app or the SPM package. Needs the same Accessibility permission the tests already do.
import AppKit
import CoreGraphics

let bundleID = "com.hdhr.vcrplus"
let args = Array(CommandLine.arguments.dropFirst())

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

switch args.first {
case "rightclick":
    guard args.count == 3, let x = Double(args[1]), let y = Double(args[2]) else { fail("usage: rightclick X Y") }
    let pt = CGPoint(x: x, y: y)
    func post(_ type: CGEventType) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: pt, mouseButton: .right)?
            .post(tap: .cghidEventTap)
    }
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    usleep(300_000)
    post(.rightMouseDown)
    usleep(100_000)
    post(.rightMouseUp)
case "keys":
    guard args.count >= 2 else { fail("usage: keys CODE [CODE…]") }
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
        fail("app not running")
    }
    for arg in args.dropFirst() {
        guard let code = UInt16(arg) else { fail("bad key code \(arg)") }
        for down in [true, false] {
            let ev = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            ev?.postToPid(app.processIdentifier)
            usleep(50_000)
        }
        usleep(150_000)
    }
default:
    fail("usage: ui_events rightclick X Y | keys CODE…")
}
