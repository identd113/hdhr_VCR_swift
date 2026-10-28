import Foundation

// What to write to a terminal so it shows `next`, given what it already shows (`previous`; nil = unknown, so repaint all of it).
//
// A full repaint of a 200x50 guide is ~14 KB, but one arrow key changes about 11 of its 51 lines (the summary panel, the
// selection box's two borders, the rows next to them), so over a slow link (ssh, a VPN, Screen Sharing) sending only
// the lines that differ is about a tenth of the data. Any change counts as a changed line, so lines that merely moved
// (the box borders above and below the selection) are repainted like any other. Callers pass nil, and so get the full
// repaint, on the first frame, a resize, a resume after Ctrl-Z and the periodic refresh, so a garbled screen cannot stay garbled.
public func frameUpdate(previous: [String]?, next: [String]) -> String {
    let begin = "\u{1B}[?2026h", end = "\u{1B}[?2026l"   // synchronized output: the terminal paints it as one update
    guard let previous, !next.isEmpty, !previous.isEmpty else {
        // The same bytes the TUI has always sent for a whole frame: home, every line followed by erase-to-end-of-line,
        // then erase-to-end-of-screen.
        return begin + "\u{1B}[H" + next.joined(separator: "\u{1B}[K\n") + "\u{1B}[K\u{1B}[J" + end
    }
    var body = ""
    for (i, line) in next.enumerated() where i >= previous.count || previous[i] != line {
        body += "\u{1B}[\(i + 1);1H" + line + "\u{1B}[K"
    }
    if next.count < previous.count { body += "\u{1B}[\(next.count + 1);1H\u{1B}[J" }   // the frame got shorter: clear below it
    return body.isEmpty ? "" : begin + body + end
}
