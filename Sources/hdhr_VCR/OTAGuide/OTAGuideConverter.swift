import Foundation

// Part of the over-the-air guide (overtime/APP_PLAN.md): turns decoded PSIP into the app's own guide model, the same
// `[GuideChannel]` that the cloud guide and XMLTV sources produce, so GuideStore can index it unchanged.
// The air carries no SeriesID, genre tags, episode titles/numbers or images: those stay nil (series recording falls back on titles).

enum OTAGuideConverter {
    /// TV and audio services only (service type 2 and 3); data services are not channels. Channels are returned in
    /// number order, each with its schedule sorted by start time. A channel with no events still appears, with an empty guide.
    static func guideChannels(from results: [OTADecodeResult]) -> [GuideChannel] {
        var out: [GuideChannel] = []
        for result in results {
            let bySource = Dictionary(grouping: result.events, by: \.sourceId)
            for channel in result.channels where channel.serviceType == 2 || channel.serviceType == 3 {
                let entries = (bySource[channel.sourceId] ?? [])
                    .sorted { $0.start < $1.start }
                    .map { e in
                        GuideEntry(StartTime: Int(e.start.timeIntervalSince1970), EndTime: Int(e.end.timeIntervalSince1970),
                                   Title: e.title.isEmpty ? "(untitled)" : e.title,
                                   Synopsis: e.description.isEmpty ? nil : e.description)
                    }
                out.append(GuideChannel(GuideNumber: channel.number, GuideName: channel.name, Guide: entries))
            }
        }
        return out.sorted {
            let a = $0.GuideNumber.split(separator: ".").compactMap { Int($0) }, b = $1.GuideNumber.split(separator: ".").compactMap { Int($0) }
            return a.lexicographicallyPrecedes(b)
        }
    }
}
