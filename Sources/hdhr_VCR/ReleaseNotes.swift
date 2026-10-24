import Foundation

// The About tab's release notes: RELEASES.md (the short, user-facing notes) split into one entry per version, plus the headline of the
// newest one. RELEASES.md stays ordinary Markdown that GitHub renders as is; the only conventions are the headings:
//   ## v2.6.5 (2026-10-15)         a version (a title may follow the number, e.g. "## v2.0.0 — First Notarized Release (2026-08-08)")
//   ## Unreleased                  the version being built
//   ### The headline: <Title>      the big feature: the paragraph after it is the blurb, a paragraph starting "**Coming soon" is the beta note
// docs/SettingsView.md "About"; the release tool (tools/release_checklist.py) renames "Unreleased" when it stamps a version.

struct ReleaseNote: Identifiable, Equatable {
    /// "v2.6.5" or "Unreleased" — also the chip label.
    let id: String
    /// The rest of the heading ("2026-10-15", "First Notarized Release · 2026-08-08"), or "" for Unreleased.
    let subtitle: String
    /// Everything under the heading, up to the next version (the trailing rule removed).
    let body: String
}

struct ReleaseHeadline: Equatable {
    let title: String
    let blurb: String
    let comingSoon: String?
}

enum ReleaseNotes {
    /// The bundled RELEASES.md, newest first (the file's own order). Empty when it is missing.
    static let bundled: [ReleaseNote] = {
        guard let url = Bundle.main.url(forResource: "RELEASES", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text)
    }()

    static func parse(_ text: String) -> [ReleaseNote] {
        var notes: [ReleaseNote] = []
        var heading: String?
        var body: [String] = []
        func flush() {
            guard let heading else { return }
            let (id, subtitle) = idAndSubtitle(heading)
            var lines = body
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty || last.trimmingCharacters(in: .whitespaces) == "---" { lines.removeLast() }
            notes.append(ReleaseNote(id: id, subtitle: subtitle, body: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                flush()
                heading = String(line.dropFirst(3))
                body = []
            } else if heading != nil {
                body.append(line)
            }
        }
        flush()
        return notes
    }

    /// "v2.6.5 (2026-10-15)" -> ("v2.6.5", "2026-10-15"); "v2.0.0 — First Notarized Release (2026-08-08)" -> ("v2.0.0", "First Notarized Release · 2026-08-08");
    /// "Unreleased" -> ("Unreleased", "").
    static func idAndSubtitle(_ heading: String) -> (String, String) {
        let trimmed = heading.trimmingCharacters(in: .whitespaces)
        let id = String(trimmed.prefix { !$0.isWhitespace })
        var rest = String(trimmed.dropFirst(id.count)).trimmingCharacters(in: .whitespaces)
        var date = ""
        if rest.hasSuffix(")"), let open = rest.lastIndex(of: "(") {
            date = String(rest[rest.index(after: open)..<rest.index(before: rest.endIndex)])
            rest = String(rest[..<open]).trimmingCharacters(in: .whitespaces)
        }
        if rest.hasPrefix("—") { rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces) }
        return (id, [rest, date].filter { !$0.isEmpty }.joined(separator: " · "))
    }

    /// The "### The headline: <Title>" section of a release body: its title, the first paragraph after it, and a "**Coming soon" paragraph if any.
    static func headline(in body: String) -> ReleaseHeadline? {
        let lines = body.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("### The headline") }) else { return nil }
        var title = String(lines[start].dropFirst(4))   // "The headline: Title"
        if let colon = title.firstIndex(of: ":") { title = String(title[title.index(after: colon)...]) }
        title = title.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
        var paragraphs: [String] = []
        var current: [String] = []
        for line in lines[(start + 1)...] {
            if line.hasPrefix("### ") { break }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { paragraphs.append(current.joined(separator: " ")); current = [] }
            } else {
                current.append(line.trimmingCharacters(in: .whitespaces))
            }
        }
        if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
        guard !title.isEmpty, let blurb = paragraphs.first(where: { !$0.hasPrefix("**Coming soon") && !$0.hasPrefix("- ") }) else { return nil }
        return ReleaseHeadline(title: title, blurb: blurb, comingSoon: paragraphs.first { $0.hasPrefix("**Coming soon") })
    }

    /// A release body without its "### The headline" section (the About tab shows that in the big-feature card, so the list skips it).
    static func withoutHeadline(_ body: String) -> String {
        var kept: [String] = []
        var skipping = false
        for line in body.components(separatedBy: "\n") {
            if line.hasPrefix("### ") { skipping = line.hasPrefix("### The headline") }
            if !skipping { kept.append(line) }
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
