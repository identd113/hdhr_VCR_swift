import Darwin
import Foundation

enum Key: Equatable {
    case up, down, left, right
    case enter, escape, tab, backspace
    case char(Character)
}

// Raw-mode terminal I/O — no ncurses dependency, hand-rolled ANSI + termios, matching the
// scope call in the approved plan (the grid is small enough that a full-frame redraw per tick
// doesn't need a curses-style diffing renderer).
enum Terminal {
    private static var saved = termios()
    private static var rawModeActive = false

    static func enterRawScreen() {
        tcgetattr(STDIN_FILENO, &saved)
        var raw = saved
        // ISIG stays enabled — Ctrl-C still generates SIGINT, and the installed handler restores
        // the terminal before exiting, so a panicked Ctrl-C never leaves the shell echo-less.
        raw.c_lflag &= ~UInt(ICANON | ECHO)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        rawModeActive = true
        write("\u{1B}[?1049h\u{1B}[?25l")   // alternate screen buffer, hide cursor
    }

    static func leaveRawScreen() {
        guard rawModeActive else { return }
        write("\u{1B}[?25h\u{1B}[?1049l")   // show cursor, restore normal screen buffer
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved)
        rawModeActive = false
    }

    static func write(_ s: String) {
        let bytes = Array(s.utf8)
        bytes.withUnsafeBufferPointer { buf in
            _ = Darwin.write(STDOUT_FILENO, buf.baseAddress, buf.count)
        }
    }

    // Flicker-free redraw: home the cursor and overwrite in place instead of clearing the whole
    // screen first (`\u{1B}[2J`) then repainting — a full clear blanks every cell immediately,
    // so on a real terminal there's a visible flash between the blank frame and the redraw,
    // especially once redraws happen on every keypress. `\u{1B}[K` after each line erases any
    // leftover tail from a longer previous frame; the trailing `\u{1B}[J` clears anything left
    // over below the last line (e.g. after a terminal resize made this frame shorter).
    //
    // `\u{1B}[?2026h`/`l` (the "synchronized output" DEC private mode, widely supported by modern
    // terminal emulators — iTerm2, Kitty, WezTerm, Windows Terminal, ghostty) tells the terminal
    // to buffer everything between the two and paint it as one atomic update. A full frame is a
    // few KB of ANSI once colored — comfortably past what a single `write()` is guaranteed to
    // deliver to the far end in one piece — so without this, a terminal that repaints as bytes
    // arrive can flash a partial frame (e.g. just the header line) before the rest lands. A
    // terminal that doesn't recognize the mode just ignores it — safe to send unconditionally.
    static func writeFrame(_ body: String) {
        let cleared = body.replacingOccurrences(of: "\n", with: "\u{1B}[K\n")
        write("\u{1B}[?2026h\u{1B}[H" + cleared + "\u{1B}[K\u{1B}[J\u{1B}[?2026l")
    }

    static func size() -> (cols: Int, rows: Int) {
        var w = winsize()
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &w) == 0, w.ws_col > 0, w.ws_row > 0 {
            return (Int(w.ws_col), Int(w.ws_row))
        }
        return (80, 24)   // reasonable fallback if the ioctl fails (e.g. output piped)
    }

    // true once stdin has bytes ready within `timeoutMs`, false on timeout — lets the caller's
    // loop wake up periodically (for the guide-data poll tick) without a busy-spin.
    static func pollStdin(timeoutMs: Int32) -> Bool {
        var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pfd, 1, timeoutMs)
        return ready > 0 && (pfd.revents & Int16(POLLIN)) != 0
    }

    // Reads one logical key. Disambiguates a bare Escape from an arrow-key escape sequence by
    // giving a follow-up byte a short window (this is the standard technique — a real arrow
    // sequence's second/third bytes arrive effectively instantly after the ESC, a human pressing
    // Escape alone does not send anything more).
    static func readKey() -> Key? {
        var byte: UInt8 = 0
        guard read(STDIN_FILENO, &byte, 1) == 1 else { return nil }

        if byte == 0x1B {
            guard pollStdin(timeoutMs: 10) else { return .escape }
            var b2: UInt8 = 0
            guard read(STDIN_FILENO, &b2, 1) == 1, b2 == UInt8(ascii: "[") else { return .escape }
            var b3: UInt8 = 0
            guard read(STDIN_FILENO, &b3, 1) == 1 else { return .escape }
            switch b3 {
            case UInt8(ascii: "A"): return .up
            case UInt8(ascii: "B"): return .down
            case UInt8(ascii: "C"): return .right
            case UInt8(ascii: "D"): return .left
            default: return .escape
            }
        }
        if byte == 0x0D || byte == 0x0A { return .enter }
        if byte == 0x09 { return .tab }
        if byte == 0x7F { return .backspace }
        return .char(Character(UnicodeScalar(byte)))
    }
}

func pad(_ s: String, _ width: Int) -> String {
    guard width > 0 else { return "" }
    if s.count >= width { return String(s.prefix(width)) }
    return s + String(repeating: " ", count: width - s.count)
}

// Greedy word-wrap for the summary screen's synopsis — a plain paragraph, not a truncated grid
// cell, so it gets real wrapping instead of an ellipsis.
func wordWrap(_ text: String, width: Int) -> [String] {
    guard width > 0 else { return [text] }
    var lines: [String] = []
    var current = ""
    for word in text.split(separator: " ") {
        let candidate = current.isEmpty ? String(word) : current + " " + word
        if candidate.count > width, !current.isEmpty {
            lines.append(current)
            current = String(word)
        } else {
            current = candidate
        }
    }
    if !current.isEmpty { lines.append(current) }
    return lines
}

func truncate(_ s: String, _ width: Int) -> String {
    guard width > 0 else { return "" }
    guard s.count > width else { return s }
    guard width > 1 else { return String(s.prefix(width)) }
    return String(s.prefix(width - 1)) + "…"
}
