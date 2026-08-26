import Foundation
import hdhr_guide_core

// DTOs (DeviceSummary, GuideEntryDTO, GuideChannelDTO, GuidePayload, RecordResponse,
// DeleteResponse, ToggleFavoriteResponse) moved to Sources/hdhr_guide_core/GuideDTOs.swift
// (imported above) so they're unit-testable — see that file's header comment. Mirrors the
// Encodable payload WebServer.swift's buildGuideJSON()/handleRecord() produce — see
// docs/WebServer.md's /api/guide.json and POST /api/record sections.

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
    //
    // Waited for in short slices, not one single blocking wait for the full timeout: Ctrl-C sets
    // `interrupted` (main.swift) from a signal handler, but nothing was checking it while a
    // request was in flight, so quitting during a slow/hung web server could take up to
    // `timeoutInterval + 1` seconds (up to 9s on the record/delete/favorite endpoints) with the
    // whole render loop frozen and no redraws. Slicing the wait into 100ms checks makes Ctrl-C
    // responsive within about that long even mid-request, without needing to restructure this
    // into full async/await.
    //
    // `result` is only read on the `.success` branch, never after `.timedOut` or an interrupted
    // early return — reading it in those cases would race the background completion handler's own
    // `result = data` write with no synchronization between the two threads (a genuine data race:
    // `sem.wait` returning `.timedOut` at the same instant the completion handler runs has no
    // happens-before relationship to that write). Only `.success` is guaranteed ordered after it,
    // since that's exactly what `sem.signal()`/`sem.wait()` synchronizes.
    private static func syncData(_ req: URLRequest) -> Data? {
        var result: Data?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, _, _ in
            result = data
            sem.signal()
        }.resume()
        let deadline = Date().addingTimeInterval(req.timeoutInterval + 1)
        while Date() < deadline {
            if interrupted { return nil }
            if sem.wait(timeout: .now() + 0.1) == .success { return result }
        }
        return nil
    }
}
