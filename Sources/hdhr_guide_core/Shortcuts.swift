import Foundation

// The terminal guide's keyboard-shortcuts card ("?"). Pure list/format logic, kept here (not in the
// hdhr_guide executable) so it's unit-testable. A terminal can't do translucency, so the card is a
// bordered box spliced over the grid, with everything behind it dimmed (ANSI faint).

public struct TUIShortcut: Equatable {
    public let keys: String
    public let description: String
}

/// Every key `main.swift`'s `handle(_:)` acts on (normal mode first, then the search and schedule screens).
public let tuiShortcuts: [TUIShortcut] = [
    TUIShortcut(keys: "Up Down",     description: "Move between channels"),
    TUIShortcut(keys: "Left Right",  description: "Move between programs"),
    TUIShortcut(keys: "[  ]",        description: "Page back / forward in time"),
    TUIShortcut(keys: "Tab",         description: "Switch tuner"),
    TUIShortcut(keys: "f",           description: "Toggle favorite channel"),
    TUIShortcut(keys: "/",           description: "Search shows, or #5.1 to jump to a channel"),
    TUIShortcut(keys: "Enter",       description: "Schedule / manage the selected program"),
    TUIShortcut(keys: "1 - 4",       description: "Recording scope (schedule screen)"),
    TUIShortcut(keys: "n  u m t w h f s", description: "New Only / pick days (schedule screen)"),
    TUIShortcut(keys: "d",           description: "Remove a scheduled recording (schedule screen)"),
    TUIShortcut(keys: "Esc",         description: "Back / cancel"),
    TUIShortcut(keys: "?",           description: "Show this card"),
    TUIShortcut(keys: "q",           description: "Quit"),
]

/// Plain-text bordered box (no ANSI), at most `maxWidth` columns wide.
public func shortcutsBoxLines(maxWidth: Int, maxHeight: Int = Int.max) -> [String] {
    let keyW = (tuiShortcuts.map { $0.keys.count }.max() ?? 0)
    let descW = (tuiShortcuts.map { $0.description.count }.max() ?? 0)
    let inner = max(10, min(keyW + 2 + descW + 2, maxWidth - 2))
    func row(_ s: String) -> String { "|" + pad(truncate(s, inner), inner) + "|" }
    var lines = ["+" + String(repeating: "-", count: inner) + "+", row(" Keyboard Shortcuts"), row("")]
    for s in tuiShortcuts { lines.append(row(" " + pad(s.keys, keyW) + "  " + s.description)) }
    lines.append(row(""))
    lines.append(row(" Press any key to close"))
    lines.append("+" + String(repeating: "-", count: inner) + "+")
    // Too short for the full card: drop shortcut rows from the bottom of the list (keeping the title, the
    // footer and both borders) rather than clipping the footer/border off the end of the screen.
    if lines.count > maxHeight, maxHeight >= 6 {
        let drop = lines.count - maxHeight
        let keepTop = lines.count - 3 - drop      // index just past the last kept shortcut row
        lines = Array(lines[0..<keepTop]) + Array(lines[(lines.count - 3)...])
    }
    return lines
}

public func stripANSI(_ s: String) -> String {
    s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
}

/// Dims every line of `frame` and centres the shortcuts box over it. Lines are plain-stripped first so
/// the dim isn't cancelled by an embedded reset; the box is drawn bold on a clear background.
public func overlayShortcuts(onto frame: String, cols: Int, rows: Int) -> String {
    var lines = frame.components(separatedBy: "\n").map { stripANSI($0) }
    while lines.count < rows { lines.append("") }
    let box = shortcutsBoxLines(maxWidth: cols, maxHeight: rows)
    let boxW = box.first?.count ?? 0
    let top = max(0, (min(rows, lines.count) - box.count) / 2)
    let left = max(0, (cols - boxW) / 2)
    for (i, b) in box.enumerated() where top + i < lines.count {
        var base = Array(pad(truncate(lines[top + i], cols), cols))
        let rep = Array(b)
        for (j, ch) in rep.enumerated() where left + j < base.count { base[left + j] = ch }
        lines[top + i] = String(base)
    }
    let dim = "\u{1B}[2m", bold = "\u{1B}[0m\u{1B}[1m", reset = "\u{1B}[0m"
    return lines.enumerated().map { i, l in
        if i >= top, i < top + box.count {
            let chars = Array(l)
            let pre = String(chars[0..<min(left, chars.count)])
            let mid = String(chars[min(left, chars.count)..<min(left + boxW, chars.count)])
            let post = String(chars[min(left + boxW, chars.count)...])
            return dim + pre + bold + mid + reset + dim + post + reset
        }
        return dim + l + reset
    }.joined(separator: "\n")
}
