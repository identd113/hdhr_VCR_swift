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

    /// The releases an update from `installed` (nil = unknown: just the offered one) up to `offered` brings, newest first.
    static func releases(_ all: [Release], after installed: String?, upTo offered: String) -> [Release] {
        guard let top = Int(offered) else { return [] }
        let low = installed.flatMap { Int($0) }
        return all.filter { r in
            guard let v = Int(r.version) else { return false }
            guard v <= top else { return false }
            if let low { return v > low }
            return v == top
        }
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

    /// Tooltip text, one block per release: the date, then the changes for every tuner, then those for particular models, with blank lines between blocks.
    static func tooltip(_ releases: [Release], maxLines: Int = 24) -> String? {
        guard !releases.isEmpty else { return nil }
        var blocks: [[String]] = []
        for r in releases {
            var lines = ["Firmware \(r.version) · \(dateLabel(r.version))"]
            let all = r.changes.filter { !isModelSpecific($0) }, some = r.changes.filter(isModelSpecific)
            lines += all.map { "• " + $0 }
            if !some.isEmpty {
                if !all.isEmpty { lines.append("Only some models:") }
                lines += some.map { "• " + $0 }
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
