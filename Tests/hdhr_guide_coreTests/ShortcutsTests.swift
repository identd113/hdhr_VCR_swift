import Testing
@testable import hdhr_guide_core

struct ShortcutsTests {
    @Test func boxFitsWidthAndListsEveryShortcut() {
        for w in [30, 60, 120] {
            let box = shortcutsBoxLines(maxWidth: w)
            #expect(box.allSatisfy { $0.count <= w })
            #expect(Set(box.map { $0.count }).count == 1)
        }
        let text = shortcutsBoxLines(maxWidth: 120).joined(separator: "\n")
        for s in tuiShortcuts { #expect(text.contains(s.description)) }
    }

    @Test func boxShrinksToShortTerminalKeepingFooterAndBorders() {
        for h in [8, 12, 19, 30] {
            let box = shortcutsBoxLines(maxWidth: 80, maxHeight: h)
            #expect(box.count <= max(h, 0) || h >= 19)
            #expect(box.last?.hasPrefix("+") == true)
            #expect(box.contains { $0.contains("Press any key") })
        }
    }

    @Test func overlayKeepsFrameSizeAndDimsBackground() {
        let frame = (0..<24).map { _ in "\u{1B}[32m" + String(repeating: "x", count: 80) + "\u{1B}[0m" }.joined(separator: "\n")
        let out = overlayShortcuts(onto: frame, cols: 80, rows: 24)
        let lines = out.components(separatedBy: "\n")
        #expect(lines.count == 24)
        #expect(lines.allSatisfy { stripANSI($0).count == 80 })
        #expect(out.contains("Keyboard Shortcuts"))
        #expect(lines[0].hasPrefix("\u{1B}[2m"))
    }
}
