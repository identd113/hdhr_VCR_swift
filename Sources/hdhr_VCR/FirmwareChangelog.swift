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

    /// Tooltip text: a heading per release, then its changes.
    static func tooltip(_ releases: [Release], maxLines: Int = 14) -> String? {
        guard !releases.isEmpty else { return nil }
        var lines: [String] = []
        for r in releases {
            lines.append("Release \(r.version)")
            lines += r.changes.map { "• " + $0 }
        }
        if lines.count > maxLines { lines = Array(lines.prefix(maxLines)) + ["…"] }
        return lines.joined(separator: "\n")
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
