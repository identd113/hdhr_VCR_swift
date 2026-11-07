import Foundation

/// `GET https://api.hdhomerun.com/api/episodes?DeviceAuth=…&SeriesID=…` (docs/HDHRFindings.md, "Cloud API — api/episodes"): every upcoming airing of one
/// series on every channel carrying it, a week to ~17 days ahead, far past the guide's 28 h. Its airings are fed to `GuideStore` as extra candidates
/// for the SeriesID lookups, so the existing channel/device/duplicate/favourite rules apply unchanged; a guide entry always beats an episodes entry
/// for the same device + channel + start (it carries the genre tags Bonus Time needs).
struct EpisodeAiring: Equatable {
    var startTime: Int
    var endTime: Int
    var title: String
    var channelNumber: String
    var channelName: String?
    var episodeTitle: String?
    var episodeNumber: String?
    var synopsis: String?
    var imageURL: String?
    var originalAirdate: Int?
    var programID: String?
}

enum EpisodeSchedule {
    /// A flat JSON array of airings (or `null` = none). Rows without times or a channel are dropped; optional text fields are nil-safe. nil when the body is not an array.
    static func decode(_ data: Data) -> [EpisodeAiring]? {
        // A series with nothing upcoming (off-season) comes back as a literal `null`: an empty schedule, not a failure.
        if let o = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]), o is NSNull { return [] }
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return rows.compactMap { r in
            guard let start = (r["StartTime"] as? NSNumber)?.intValue, let end = (r["EndTime"] as? NSNumber)?.intValue, end > start,
                  let channel = r["ChannelNumber"] as? String, !channel.isEmpty else { return nil }
            return EpisodeAiring(startTime: start, endTime: end, title: r["Title"] as? String ?? "", channelNumber: channel,
                                 channelName: r["ChannelName"] as? String, episodeTitle: r["EpisodeTitle"] as? String,
                                 episodeNumber: r["EpisodeNumber"] as? String, synopsis: r["Synopsis"] as? String,
                                 imageURL: r["ImageURL"] as? String, originalAirdate: (r["OriginalAirdate"] as? NSNumber)?.intValue,
                                 programID: r["ProgramID"] as? String)
        }
    }

    /// The airings that a recordable device can actually tune: one match per device whose lineup carries the airing's channel number
    /// (an airing on a channel the tuner does not have could never be recorded). Only airings starting after `after` are kept.
    static func matches(for airings: [EpisodeAiring], seriesID: String, after: Date,
                        devices: [(id: String, lineup: [LineupEntry])]) -> [GuideStore.SeriesMatch] {
        let cutoff = Int(after.timeIntervalSince1970)
        var out: [GuideStore.SeriesMatch] = []
        for device in devices {
            let have = Set(device.lineup.map(\.GuideNumber))
            for a in airings where a.startTime > cutoff && have.contains(a.channelNumber) {
                var e = GuideEntry(StartTime: a.startTime, EndTime: a.endTime, Title: a.title)
                e.EpisodeTitle = a.episodeTitle; e.EpisodeNumber = a.episodeNumber; e.Synopsis = a.synopsis
                e.SeriesID = seriesID; e.ImageURL = a.imageURL; e.OriginalAirdate = a.originalAirdate
                e.deviceId = device.id; e.channelNum = a.channelNumber
                e.cachedSeriesTitle = Show.seriesTitle(from: a.title)
                out.append(GuideStore.SeriesMatch(deviceId: device.id, channelNum: a.channelNumber, entry: e))
            }
        }
        return out
    }

    /// How long a fetched schedule is trusted, and how soon a failed fetch is tried again.
    static let refreshInterval: TimeInterval = 3 * 3600
    static let retryInterval: TimeInterval = 30 * 60

    /// Series whose schedule is due: not fetched within `refreshInterval`, or last tried more than `retryInterval` ago after a failure.
    static func dueSeriesIDs(_ ids: [String], now: Date, lastSuccess: [String: Date], lastAttempt: [String: Date]) -> [String] {
        ids.filter { id in
            if let ok = lastSuccess[id], now.timeIntervalSince(ok) < refreshInterval { return false }
            if let tried = lastAttempt[id], now.timeIntervalSince(tried) < retryInterval { return false }
            return true
        }
    }

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 30
        return URLSession(configuration: c)
    }()

    /// nil on any failure (no network, non-2xx, a body that is not a JSON array): the caller keeps using the guide alone.
    static func fetch(seriesID: String, deviceAuth: String) async -> (airings: [EpisodeAiring]?, reason: String?) {
        guard let url = URL(string: "https://api.hdhomerun.com/api/episodes?DeviceAuth=\(GuideStore.queryEncoded(deviceAuth))&SeriesID=\(GuideStore.queryEncoded(seriesID))") else { return (nil, "bad URL") }
        do {
            let (data, resp) = try await session.data(from: url)
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return (nil, "HTTP \(http.statusCode)") }
            guard let airings = decode(data) else { return (nil, "unexpected response body") }
            return (airings, nil)
        } catch {
            return (nil, (error as NSError).domain == NSURLErrorDomain ? "network error \((error as NSError).code)" : "request failed")
        }
    }
}
