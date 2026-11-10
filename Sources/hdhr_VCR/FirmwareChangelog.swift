import Foundation

/// SiliconDust's firmware release notes (`firmware-changelog.html`: one `<h4>Release YYYYMMDD:</h4>` per release, newest first, each followed by
/// `<li>` lines). Read only when a tuner offers newer firmware, to show what the update brings as the menu item's tooltip.
enum FirmwareChangelog {
    static let url = URL(string: "https://www.silicondust.com/support/downloads/firmware-changelog.html")!

    struct Release: Equatable {
        var version: String
        var changes: [String]
    }

    /// Every release on the page, in page order. Only the main content is read (the site header and footer have `<li>`s of their own).
    static func parse(_ html: String) -> [Release] {
        var body = Substring(html)
        if let end = html.range(of: "</main>") { body = html[..<end.lowerBound] }
        guard let re = try? NSRegularExpression(pattern: #"<h4[^>]*>\s*Release\s+(\d+)[^<]*</h4>|<li[^>]*>(.*?)</li>"#,
                                                options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
        let text = String(body)
        let ns = text as NSString
        var out: [Release] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if m.range(at: 1).location != NSNotFound {
                out.append(Release(version: ns.substring(with: m.range(at: 1)), changes: []))
            } else if m.range(at: 2).location != NSNotFound, !out.isEmpty {
                let line = clean(ns.substring(with: m.range(at: 2)))
                if !line.isEmpty { out[out.count - 1].changes.append(line) }
            }
        }
        return out
    }

    /// The offered release only (the update the tuner is being offered, not the older ones it skips past), as a list for `tooltip`.
    static func releases(_ all: [Release], offered: String) -> [Release] {
        all.filter { $0.version == offered }
    }

    /// A line that starts with the models it is about ("ATSC3 models: …", "HDHR5-2DT/4DT: …") rather than applying to every tuner.
    static func isModelSpecific(_ line: String) -> Bool {
        guard let colon = line.firstIndex(of: ":") else { return false }
        return line.distance(from: line.startIndex, to: colon) <= 45
    }

    /// "20261107" as "Nov 7, 2026" (the version is the release date); the bare version when it is not a date.
    static func dateLabel(_ version: String) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd"
        guard let d = f.date(from: version) else { return version }
        f.dateFormat = "MMM d, yyyy"
        return f.string(from: d)
    }

    /// True when the models a line names include `model` ("HDTC-2US"): the part before the colon is split on "/", "," and spaces; a token matches
    /// the model exactly or as its family prefix ("HDTC" for "HDTC-2US", at least 4 characters), and a bare suffix ("4DT" in "HDHR5-2DT/4DT")
    /// inherits the family prefix of the token before it ("HDHR5-4DT").
    static func namesModel(_ line: String, model: String?) -> Bool {
        guard let model = model?.uppercased(), !model.isEmpty, isModelSpecific(line), let colon = line.firstIndex(of: ":") else { return false }
        let tokens = line[..<colon].uppercased().split(whereSeparator: { "/, ".contains($0) }).map(String.init)
        var family = ""   // "HDHR5-" once a token like "HDHR5-2DT" has been seen
        for t in tokens {
            if t == model || (t.count >= 4 && model.hasPrefix(t)) { return true }
            if !family.isEmpty, !t.contains("-"), family + t == model { return true }
            if let dash = t.firstIndex(of: "-") { family = String(t[...dash]) }
        }
        return false
    }

    /// Plain-text bold (mathematical sans-serif bold letters and digits): a tooltip has no rich text.
    static func bold(_ s: String) -> String {
        String(s.unicodeScalars.map { u -> Character in
            switch u.value {
            case 0x41...0x5A: return Character(Unicode.Scalar(0x1D5D4 + u.value - 0x41)!)
            case 0x61...0x7A: return Character(Unicode.Scalar(0x1D5EE + u.value - 0x61)!)
            case 0x30...0x39: return Character(Unicode.Scalar(0x1D7EC + u.value - 0x30)!)
            default: return Character(u)
            }
        })
    }

    /// `text` as a bullet wrapped at `width` characters (continuation lines indented under the text), so a tooltip never runs wider than the screen.
    static func bulletLines(_ text: String, width: Int = 56, bold makeBold: Bool = false) -> [String] {
        var lines: [String] = [], current = ""
        for word in text.split(separator: " ") {
            if !current.isEmpty, current.count + 1 + word.count > width { lines.append(current); current = String(word) }
            else { current += (current.isEmpty ? "" : " ") + word }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.enumerated().map { ($0.offset == 0 ? "• " : "   ") + (makeBold ? bold($0.element) : $0.element) }
    }

    /// Tooltip text, one block per release: the date, the changes for every tuner, then (when `model` is given) those that name this tuner's model in
    /// bold, then those for other models, with blank lines between blocks.
    static func tooltip(_ releases: [Release], model: String? = nil, maxLines: Int = 14) -> String? {
        guard !releases.isEmpty else { return nil }
        var blocks: [[String]] = []
        for r in releases {
            var lines = ["Firmware \(r.version) · \(dateLabel(r.version))"]
            let all = r.changes.filter { !isModelSpecific($0) }
            let mine = r.changes.filter { namesModel($0, model: model) }
            let others = r.changes.filter { isModelSpecific($0) && !namesModel($0, model: model) }
            lines += all.flatMap { bulletLines($0) }
            if !mine.isEmpty {
                lines.append("For your \(model ?? "tuner"):")
                lines += mine.flatMap { bulletLines($0, bold: true) }
            }
            if !others.isEmpty {
                if !all.isEmpty || !mine.isEmpty { lines.append("Only some models:") }
                lines += others.flatMap { bulletLines($0) }
            }
            blocks.append(lines)
        }
        var out: [String] = []
        for (i, b) in blocks.enumerated() {
            if i > 0 { out.append("") }
            out += b
        }
        if out.count > maxLines { out = Array(out.prefix(maxLines)) + ["…"] }
        return out.joined(separator: "\n")
    }

    /// nil when the page cannot be read or has no releases.
    static func fetch() async -> [Release]? {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 30
        guard let (data, resp) = try? await URLSession(configuration: c).data(from: url),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              let html = String(data: data, encoding: .utf8) else { return nil }
        let all = parse(html)
        return all.isEmpty ? nil : all
    }

    /// Strips tags and decodes the entities the page uses.
    private static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        if let re = try? NSRegularExpression(pattern: "&#(\\d+);") {
            let ns = t as NSString
            for m in re.matches(in: t, range: NSRange(location: 0, length: ns.length)).reversed() {
                if let code = UInt32(ns.substring(with: m.range(at: 1))), let u = Unicode.Scalar(code) {
                    t = (t as NSString).replacingCharacters(in: m.range, with: String(Character(u)))
                }
            }
        }
        for (e, r) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")] { t = t.replacingOccurrences(of: e, with: r) }
        return t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
