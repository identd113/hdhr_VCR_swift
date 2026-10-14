// ax_query.swift — fast Accessibility queries for UI tests (native AXUIElement, not AppleScript).
//
//   ax_query windows                              window titles, one per line
//   ax_query find   WINDOW MATCH [--last] [--press]  first (or last) element under the window titled WINDOW (substring) that matches
//   ax_query count  WINDOW MATCH                  how many match (full walk — only for small windows)
//   ax_query text   WINDOW STRING                 exit 0 if any element's value / title / description equals STRING (early exit)
//
// MATCH is `id=VALUE` (AXIdentifier), `help^=PREFIX` (AXHelp starts with), `help$=SUFFIX` (AXHelp ends with), `role=AXButton`, `title=VALUE`, or several
// joined by `&`. WINDOW "" means every window.
//
// Why it exists: System Events reads each element with its own Apple event, so a recursive walk of a window with a few
// hundred rows (Watch Now / the PiP picker once a second device's lineup is listed) takes minutes. The same walk through
// AXUIElementCopyAttributeValue is ~100× quicker, and `find` stops at the first hit. Exit 0 = found, 1 = not found, 2 = usage.
// `find` prints "role|title|help|x,y,w,h|path" for the hit — `path` is the 1-based child-index path from the window
// ("3/1/4"), which the tests walk with `UI element N of …` to get a System Events reference to exactly that element
// without a slow System Events search; `--press` also performs AXPress on it.
//
// Compiled on demand (`swiftc -O tools/ax_query.swift -o <tmp>`), like ui_events.swift; needs the Accessibility permission
// the tests already require. Not part of the app or the SPM package.
import AppKit
import ApplicationServices

let bundleID = "com.hdhr.vcrplus"
let args = Array(CommandLine.arguments.dropFirst())

func fail(_ msg: String) -> Never { FileHandle.standardError.write((msg + "\n").data(using: .utf8)!); exit(2) }

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { fail("app not running") }
let root = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetMessagingTimeout(root, 3)

func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}
func str(_ el: AXUIElement, _ name: String) -> String { (attr(el, name) as? String) ?? "" }
func children(_ el: AXUIElement) -> [AXUIElement] { (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func windows() -> [AXUIElement] { (attr(root, kAXWindowsAttribute) as? [AXUIElement]) ?? [] }
func frame(_ el: AXUIElement) -> String {
    var p = CGPoint.zero, s = CGSize.zero
    if let pv = attr(el, kAXPositionAttribute), CFGetTypeID(pv) == AXValueGetTypeID() { AXValueGetValue(pv as! AXValue, .cgPoint, &p) }
    if let sv = attr(el, kAXSizeAttribute), CFGetTypeID(sv) == AXValueGetTypeID() { AXValueGetValue(sv as! AXValue, .cgSize, &s) }
    return "\(Int(p.x)),\(Int(p.y)),\(Int(s.width)),\(Int(s.height))"
}

typealias Pred = (AXUIElement) -> Bool
func parse(_ spec: String) -> Pred {
    let parts = spec.split(separator: "&").map(String.init)
    let preds: [Pred] = parts.map { p in
        if let r = p.range(of: "help$=") { let v = String(p[r.upperBound...]); return { str($0, kAXHelpAttribute).hasSuffix(v) } }
        if let r = p.range(of: "help^=") { let v = String(p[r.upperBound...]); return { str($0, kAXHelpAttribute).hasPrefix(v) } }
        if let r = p.range(of: "id=")    { let v = String(p[r.upperBound...]); return { str($0, "AXIdentifier") == v } }
        if let r = p.range(of: "role=")  { let v = String(p[r.upperBound...]); return { str($0, kAXRoleAttribute) == v } }
        if let r = p.range(of: "title=") { let v = String(p[r.upperBound...]); return { str($0, kAXTitleAttribute) == v || str($0, kAXDescriptionAttribute) == v } }
        fail("bad MATCH: \(p)")
    }
    return { el in preds.allSatisfy { $0(el) } }
}

func targetWindows(_ name: String) -> [AXUIElement] {
    name.isEmpty ? windows() : windows().filter { str($0, kAXTitleAttribute).contains(name) }
}
/// Depth-first search; `path` is the 1-based child-index path of `el` from the window (empty for the window itself).
func search(_ el: AXUIElement, _ pred: Pred, all: Bool, path: [Int] = [], hits: inout [(el: AXUIElement, path: [Int])]) -> Bool {
    for (i, k) in children(el).enumerated() {
        let kPath = path + [i + 1]
        if pred(k) { hits.append((k, kPath)); if !all { return true } }
        if search(k, pred, all: all, path: kPath, hits: &hits) && !all { return true }
    }
    return false
}

switch args.first {
case "windows":
    for w in windows() { print(str(w, kAXTitleAttribute)) }
case "find", "count":
    guard args.count >= 3 else { fail("usage: \(args[0]) WINDOW MATCH [--press]") }
    let pred = parse(args[2]); var hits: [(el: AXUIElement, path: [Int])] = []
    let wantLast = args.contains("--last")   // walk everything and take the final hit (e.g. the Live TV section's button)
    for w in targetWindows(args[1]) {
        _ = search(w, pred, all: args[0] == "count" || wantLast, hits: &hits)
        if args[0] == "find", !wantLast, !hits.isEmpty { break }
    }
    if args[0] == "count" { print(hits.count); exit(0) }
    guard let hit = wantLast ? hits.last : hits.first else { exit(1) }
    let h = hit.el
    print("\(str(h, kAXRoleAttribute))|\(str(h, kAXTitleAttribute))|\(str(h, kAXHelpAttribute))|\(frame(h))|\(hit.path.map(String.init).joined(separator: "/"))")
    if args.contains("--press") { AXUIElementPerformAction(h, kAXPressAction as CFString) }
case "text":
    guard args.count >= 3 else { fail("usage: text WINDOW STRING") }
    let want = args[2]
    // Any role: a section header can surface as a heading/group rather than a plain static text.
    let pred: Pred = { str($0, kAXValueAttribute) == want || str($0, kAXTitleAttribute) == want || str($0, kAXDescriptionAttribute) == want }
    var hits: [(el: AXUIElement, path: [Int])] = []
    for w in targetWindows(args[1]) { if search(w, pred, all: false, hits: &hits) { break } }
    exit(hits.isEmpty ? 1 : 0)
default:
    fail("usage: windows | find WINDOW MATCH [--press] | count WINDOW MATCH | text WINDOW STRING")
}
