import Foundation

/// M3U playlist + XMLTV guide of the channels currently being recorded, for apps that take those
/// instead of an HDHomeRun (Channels DVR custom channels, Jellyfin, TiviMate, VLC). Pure builders,
/// no state: WebServer gathers the inputs. Served only while `Other_apps_feed_enabled` is on.
enum FeedPlaylist {
    struct Channel {
        var id: String          // tvg-id, shared by the playlist and the guide
        var number: String
        var name: String
        var streamURL: String
        var logoURL: String?
        var programmes: [GuideEntry]
    }

    static let group = "Recording Now"

    static func channelID(number: String, deviceID: String) -> String { "hdhrvcr-\(deviceID)-\(number)" }

    static func m3u(_ channels: [Channel], guideURL: String?) -> String {
        var out = "#EXTM3U" + (guideURL.map { " x-tvg-url=\"\(attr($0))\"" } ?? "") + "\n"
        for ch in channels {
            var line = "#EXTINF:-1 tvg-id=\"\(attr(ch.id))\" tvg-chno=\"\(attr(ch.number))\" tvg-name=\"\(attr(ch.name))\""
            if let logo = ch.logoURL, !logo.isEmpty { line += " tvg-logo=\"\(attr(logo))\"" }
            line += " group-title=\"\(group)\",\(oneLine(ch.name))\n"
            out += line + ch.streamURL + "\n"
        }
        return out
    }

    static func xmltv(_ channels: [Channel]) -> String {
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<tv generator-info-name=\"hdhrVCRplus\">\n"
        for ch in channels {
            out += "<channel id=\"\(esc(ch.id))\"><display-name>\(esc(ch.name))</display-name>"
            out += "<display-name>\(esc(ch.number))</display-name>"
            if let logo = ch.logoURL, !logo.isEmpty { out += "<icon src=\"\(esc(logo))\"/>" }
            out += "</channel>\n"
        }
        for ch in channels {
            for e in ch.programmes {
                out += "<programme start=\"\(stamp(e.StartTime))\" stop=\"\(stamp(e.EndTime))\" channel=\"\(esc(ch.id))\">"
                out += "<title>\(esc(e.Title))</title>"
                if let s = e.EpisodeTitle, !s.isEmpty { out += "<sub-title>\(esc(s))</sub-title>" }
                if let d = e.Synopsis, !d.isEmpty { out += "<desc>\(esc(d))</desc>" }
                for g in e.Filter ?? [] { out += "<category>\(esc(g))</category>" }
                if let img = e.ImageURL, !img.isEmpty { out += "<icon src=\"\(esc(img))\"/>" }
                if let n = e.EpisodeNumber, !n.isEmpty { out += "<episode-num system=\"onscreen\">\(esc(n))</episode-num>" }
                out += "</programme>\n"
            }
        }
        return out + "</tv>\n"
    }

    /// XMLTV time, always UTC: "20261115193000 +0000".
    static func stamp(_ epoch: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMddHHmmss"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(epoch))) + " +0000"
    }

    private static func esc(_ s: String) -> String {
        var r = ""
        for u in s.unicodeScalars {
            switch u {
            case "&": r += "&amp;"
            case "<": r += "&lt;"
            case ">": r += "&gt;"
            case "\"": r += "&quot;"
            case "\u{9}", "\u{A}", "\u{D}": r += String(u)
            default: if u.value >= 0x20 { r.unicodeScalars.append(u) }   // XML 1.0 forbids other control characters
            }
        }
        return r
    }
    /// An M3U attribute value: no quotes or line breaks.
    private static func attr(_ s: String) -> String { oneLine(s).replacingOccurrences(of: "\"", with: "'") }
    private static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }
}
