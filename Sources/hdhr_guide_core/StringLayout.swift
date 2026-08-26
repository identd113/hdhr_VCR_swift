// Pure fixed-width text layout helpers for the TUI grid/summary panel — no terminal I/O, no
// global state, moved here (out of the hdhr_guide executable target) specifically so they're
// unit-testable: a `main.swift`-based executable target can't be @testable imported, so none of
// this had any automated coverage before this split (see docs/TUIGuide.md's "Robustness fixes").

public func pad(_ s: String, _ width: Int) -> String {
    guard width > 0 else { return "" }
    if s.count >= width { return String(s.prefix(width)) }
    return s + String(repeating: " ", count: width - s.count)
}

// Truncation marker is a plain ASCII "." rather than "…" — the ellipsis glyph (like every
// box-drawing/marker glyph this app used to rely on) is Unicode "Ambiguous width": most terminals
// with a Western locale render it in 1 column, matching the 1-column budget this function assumes,
// but anything in the chain that renders ambiguous-width glyphs as 2 columns instead (confirmed:
// a web-terminal-in-the-middle setup — browser → Raspberry Pi → SSH → this Mac) silently adds an
// extra column per occurrence, which is exactly what kept causing lines to wrap even after the
// character-count math itself was verified correct. ASCII has no ambiguous-width case anywhere,
// on any terminal, so swapping every such glyph app-wide for an ASCII stand-in removes the whole
// bug class rather than chasing it terminal-by-terminal.
public func truncate(_ s: String, _ width: Int) -> String {
    guard width > 0 else { return "" }
    guard s.count > width else { return s }
    guard width > 1 else { return String(s.prefix(width)) }
    return String(s.prefix(width - 1)) + "."
}

// Greedy word-wrap for the summary screen's synopsis — a plain paragraph, not a truncated grid
// cell, so it gets real wrapping instead of an ellipsis.
public func wordWrap(_ text: String, width: Int) -> [String] {
    guard width > 0 else { return [text] }
    var lines: [String] = []
    var current = ""
    for word in text.split(separator: " ") {
        var remaining = Substring(word)
        // A single word longer than the wrap width by itself (a long URL, a hyphen-less compound
        // token — real synopsis data, not app-controlled) is hard-broken into width-sized chunks
        // rather than emitted whole — otherwise it produced a line wider than `width` regardless
        // of the width passed in, the same overflow-then-terminal-wraps bug class the rest of this
        // app's width handling exists to prevent (callers here truncate/clamp every other line to
        // `cols`, but never re-checked what this function handed back).
        while remaining.count > width {
            if !current.isEmpty { lines.append(current); current = "" }
            lines.append(String(remaining.prefix(width)))
            remaining = remaining.dropFirst(width)
        }
        let candidate = current.isEmpty ? String(remaining) : current + " " + remaining
        if candidate.count > width, !current.isEmpty {
            lines.append(current)
            current = String(remaining)
        } else {
            current = candidate
        }
    }
    if !current.isEmpty { lines.append(current) }
    return lines
}
