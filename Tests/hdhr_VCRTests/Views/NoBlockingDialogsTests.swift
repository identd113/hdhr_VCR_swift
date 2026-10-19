import Foundation
import Testing

// `NSAlert.runModal()` / `NSSavePanel.runModal()` park the main thread in their own event loop, which
// stops every web-server handler, the idle loop and recording start/stop until someone answers
// (found 2026-10-14: a stray "No Tuner Available" froze `:1980`). All dialogs go through `Dialogs`
// (Views/Dialogs.swift). The only allowed `runModal()` is the launch-time "Move to Applications?"
// prompt (AppRelocator), which runs before the app has started anything.

@Suite("No blocking dialogs")
struct NoBlockingDialogsTests {

    @Test func runModalIsNotUsedOutsideTheLaunchPrompt() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()   // …/Tests/hdhr_VCRTests
            .deletingLastPathComponent().deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/hdhr_VCR")
        let allowed: Set<String> = ["AppRelocator.swift"]
        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        #expect(!files.isEmpty, "found no sources under \(sources.path)")
        for file in files where !allowed.contains(file.lastPathComponent) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
                if code.contains(".runModal(") { offenders.append("\(file.lastPathComponent):\(i + 1)") }
            }
        }
        #expect(offenders.isEmpty, "use Dialogs.show / Dialogs.present / Dialogs.choose (Views/Dialogs.swift), not runModal(): \(offenders)")
    }
}
