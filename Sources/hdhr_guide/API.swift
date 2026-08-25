import Foundation

// Mirrors the Encodable payload WebServer.swift's buildGuideJSON()/handleRecord() produce —
// see docs/WebServer.md's /api/guide.json and POST /api/record sections. Kept as local DTOs
// rather than importing the hdhr_VCR module: that target is an executable, not a library, and
// this is a thin two-endpoint JSON client — not worth splitting shared model types out for.

struct DeviceSummary: Decodable {
    let deviceId: String
    let active, total: Int
}

struct GuideEntryDTO: Decodable {
    let title: String
    let episodeTitle, episodeNumber, synopsis, seriesId, genre: String?
    let tags: [String]?
    let startTime, endTime: Int
    let isRecording, isScheduled: Bool
    let scheduledShowId: String?

    var startDate: Date { Date(timeIntervalSince1970: TimeInterval(startTime)) }
    var endDate: Date { Date(timeIntervalSince1970: TimeInterval(endTime)) }
}

struct GuideChannelDTO: Decodable {
    let guideNumber, guideName: String
    let hd, favorite: Bool
    let entries: [GuideEntryDTO]
}

struct GuidePayload: Decodable {
    let deviceId: String
    let winStart, winSec: Int
    let devices: [DeviceSummary]
    let channels: [GuideChannelDTO]
}

struct RecordResponse: Decodable {
    let ok: Bool
    let error: String?
    let title: String?
    let tunerFull: Bool?
    let recStarted: Bool?
}

struct DeleteResponse: Decodable {
    let ok: Bool
    let error: String?
    let title: String?
}

struct ToggleFavoriteResponse: Decodable {
    let ok: Bool
    let error: String?
    let isFavorite: Bool?
}

enum API {
    static let baseURL = "http://127.0.0.1:1980"

    static func fetchGuide(device: String?) -> GuidePayload? {
        var urlStr = baseURL + "/api/guide.json"
        if let device { urlStr += "/" + device }
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        guard let data = syncData(req) else { return nil }
        return try? JSONDecoder().decode(GuidePayload.self, from: data)
    }

    static func postRecord(deviceId: String, guideNumber: String, startTime: Int, showType: String, bonusTime: Bool = false) -> RecordResponse {
        let failure = RecordResponse(ok: false, error: "no response from web server", title: nil, tunerFull: nil, recStarted: nil)
        guard let url = URL(string: baseURL + "/api/record") else { return failure }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "deviceId": deviceId, "guideNumber": guideNumber,
            "startTime": startTime, "showType": showType, "bonusTime": bonusTime
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let data = syncData(req), let resp = try? JSONDecoder().decode(RecordResponse.self, from: data) else {
            return failure
        }
        return resp
    }

    static func postDelete(showId: String) -> DeleteResponse {
        let failure = DeleteResponse(ok: false, error: "no response from web server", title: nil)
        guard let url = URL(string: baseURL + "/api/delete") else { return failure }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["showId": showId])
        guard let data = syncData(req), let resp = try? JSONDecoder().decode(DeleteResponse.self, from: data) else {
            return failure
        }
        return resp
    }

    static func postToggleFavorite(deviceId: String, guideNumber: String) -> ToggleFavoriteResponse {
        let failure = ToggleFavoriteResponse(ok: false, error: "no response from web server", isFavorite: nil)
        guard let url = URL(string: baseURL + "/api/toggle-favorite") else { return failure }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["deviceId": deviceId, "guideNumber": guideNumber])
        guard let data = syncData(req), let resp = try? JSONDecoder().decode(ToggleFavoriteResponse.self, from: data) else {
            return failure
        }
        return resp
    }

    // {guideName.lowercased(): "good"|"fair"|"poor"|"noData"} for every channel with samples —
    // one bulk call rather than one /api/signal-stats/{guideName} round-trip per visible row.
    static func fetchSignal() -> [String: String]? {
        guard let url = URL(string: baseURL + "/api/signal") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        guard let data = syncData(req) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    // Blocking request — the TUI's own render loop only calls this from user-triggered actions
    // or its own periodic poll tick, never while awaiting other I/O, so a synchronous wait keeps
    // the whole client single-threaded with no async/await plumbing needed for a two-endpoint tool.
    private static func syncData(_ req: URLRequest) -> Data? {
        var result: Data?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, _, _ in
            result = data
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + req.timeoutInterval + 1)
        return result
    }
}
