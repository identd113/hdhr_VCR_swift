import Foundation

// Parses XMLTV data from the SiliconDust cloud endpoint into [GuideChannel].
// Output shape is identical to the JSON guide.php decoder output so all downstream
// code is unchanged when Guide_use_xml is true.
final class XmltvParser: NSObject, XMLParserDelegate {

    // Channel working state
    private var channelMeta: [String: ChannelMeta] = [:]
    private var currentChannelId = ""
    private var displayNames: [String] = []
    private var lcn: String? = nil
    private var channelIconSrc: String? = nil
    private var inChannel = false

    // Programme working state
    private var progsByChannelId: [String: [GuideEntry]] = [:]
    private var currentProg: ProgBuilder? = nil
    private var currentChars = ""
    private var currentEpisodeSystem = ""

    func parse(_ data: Data) -> [GuideChannel] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return channelMeta.compactMap { id, meta -> GuideChannel? in
            guard !meta.number.isEmpty else { return nil }
            var entries = progsByChannelId[id] ?? []
            entries.sort { $0.StartTime < $1.StartTime }
            return GuideChannel(
                GuideNumber: meta.number,
                GuideName: meta.name.isEmpty ? id : meta.name,
                Affiliate: meta.affiliate,
                ImageURL: meta.icon,
                Guide: entries
            )
        }.sorted { $0.GuideNumber < $1.GuideNumber }
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes: [String: String] = [:]) {
        currentChars = ""
        switch elementName {
        case "channel":
            inChannel = true
            currentChannelId = attributes["id"] ?? ""
            displayNames = []
            lcn = nil
            channelIconSrc = nil
        case "programme":
            let start = Self.parseDateTime(attributes["start"] ?? "") ?? 0
            let stop  = Self.parseDateTime(attributes["stop"]  ?? "") ?? 0
            currentProg = ProgBuilder(channelId: attributes["channel"] ?? "",
                                      start: start, stop: stop)
        case "episode-num":
            currentEpisodeSystem = attributes["system"] ?? ""
        case "icon":
            if let src = attributes["src"] {
                if currentProg != nil { currentProg?.icon = src }
                else if inChannel    { channelIconSrc = src }
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentChars += string
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        let chars = currentChars.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { currentChars = "" }

        switch elementName {
        case "channel":
            inChannel = false
            // Prefer <lcn>; fall back to any display-name that looks like a channel number
            let number = lcn
                ?? displayNames.first { $0.allSatisfy { $0.isNumber || $0 == "." } }
                ?? ""
            channelMeta[currentChannelId] = ChannelMeta(
                number: number,
                name: Self.extractGuideName(displayNames, lcn: number),
                affiliate: displayNames.last,
                icon: channelIconSrc
            )
        case "display-name":
            if !chars.isEmpty { displayNames.append(chars) }
        case "lcn":
            if !chars.isEmpty { lcn = chars }
        case "title":
            currentProg?.title = chars
        case "sub-title":
            if !chars.isEmpty { currentProg?.subtitle = chars }
        case "desc":
            if !chars.isEmpty { currentProg?.desc = chars }
        case "category":
            if !chars.isEmpty { currentProg?.categories.append(chars) }
        case "date":
            currentProg?.date = Self.parseDate(chars)
        case "series-id":
            if !chars.isEmpty { currentProg?.seriesId = chars }
        case "episode-num":
            if currentEpisodeSystem == "onscreen", !chars.isEmpty {
                currentProg?.episodeOnscreen = chars
            }
        case "programme":
            guard let prog = currentProg,
                  prog.start > 0, prog.stop > 0, !prog.title.isEmpty else {
                currentProg = nil; break
            }
            let entry = GuideEntry(
                StartTime:      prog.start,
                EndTime:        prog.stop,
                Title:          prog.title,
                EpisodeTitle:   prog.subtitle,
                EpisodeNumber:  prog.episodeOnscreen,
                Synopsis:       prog.desc,
                SeriesID:       prog.seriesId,
                ImageURL:       prog.icon,
                OriginalAirdate: prog.date,
                Filter:         prog.categories.isEmpty ? nil : prog.categories
            )
            progsByChannelId[prog.channelId, default: []].append(entry)
            currentProg = nil
        default: break
        }
    }

    // MARK: - Static helpers

    // "20260618060000 +0000" — space before timezone offset is part of the format
    static func parseDateTime(_ s: String) -> Int? {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMddHHmmss Z"
        return fmt.date(from: s).map { Int($0.timeIntervalSince1970) }
    }

    // "19940202" (YYYYMMDD) → Unix epoch at midnight UTC
    static func parseDate(_ s: String) -> Int? {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "yyyyMMdd"
        return fmt.date(from: s).map { Int($0.timeIntervalSince1970) }
    }

    // Strips the last display-name (affiliate/network), then finds the one that begins
    // with the channel number (e.g. "11.1 KARE-HD" → "KARE-HD"). Falls back to first name.
    static func extractGuideName(_ names: [String], lcn: String?) -> String {
        let candidates = names.count > 1 ? Array(names.dropLast()) : names
        if let lcn, !lcn.isEmpty {
            let prefix = lcn + " "
            if let match = candidates.first(where: { $0.hasPrefix(prefix) }) {
                return String(match.dropFirst(prefix.count))
            }
        }
        return candidates.first ?? ""
    }
}

// MARK: - Private types

private struct ChannelMeta {
    var number:    String
    var name:      String
    var affiliate: String?
    var icon:      String?
}

private struct ProgBuilder {
    var channelId:       String
    var start:           Int
    var stop:            Int
    var title:           String  = ""
    var subtitle:        String? = nil
    var desc:            String? = nil
    var seriesId:        String? = nil
    var episodeOnscreen: String? = nil
    var icon:            String? = nil
    var categories:      [String] = []
    var date:            Int?   = nil
}
