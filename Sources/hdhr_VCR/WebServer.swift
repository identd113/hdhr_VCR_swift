import Foundation
import Network

// NWListener-based LAN web server. Binds to all interfaces; the subnet guard
// in handleConnection cancels any connection whose source IP is outside the
// local interface subnets — no data is read or sent to non-LAN callers.
final class WebServer {

    private enum WebResponse {
        case ok(contentType: String, body: Data)
        case notFound(String)
        case badRequest(String)
        case payloadTooLarge(String)
    }

    private var listener:      NWListener?
    private var stateCallback: ((String?) -> Void)?   // nil'd by stop() to silence spurious callbacks
    private var activePort: Int = 1980
    private let queue = DispatchQueue(label: "hdhrVCRplus.webserver", qos: .utility)
    private weak var appState: AppState?

    // SSE: open connections waiting for push events
    private var sseConns: [NWConnection] = []
    private let sseLock  = NSLock()

    // MARK: - Lifecycle

    func start(port: Int, appState: AppState, onState: @escaping (String?) -> Void) {
        stop()
        self.appState     = appState
        self.stateCallback = onState

        let clamped = max(1025, min(65534, port))
        activePort = clamped
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamped)) else {
            DispatchQueue.main.async { onState("Invalid port \(clamped)") }
            return
        }

        guard let l = try? NWListener(using: .tcp, on: nwPort) else {
            glog("[WebServer] Failed to create listener on port \(clamped)", level: .error)
            DispatchQueue.main.async { onState("Port \(clamped) unavailable") }
            return
        }

        l.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                glog("[WebServer] Listening on port \(clamped)")
                // Self-ping to confirm end-to-end HTTP is working (not just port binding).
                Task { [weak self] in
                    guard let self else { return }
                    let ok = await self.selfPing(port: clamped)
                    if !ok { glog("[WebServer] Self-ping failed — port bound but not responding", level: .warning) }
                    DispatchQueue.main.async { self.stateCallback?(ok ? nil : "Server started but did not respond to /api/ping") }
                }
            case .failed(let err):
                glog("[WebServer] Failed: \(err)", level: .error)
                DispatchQueue.main.async { self.stateCallback?(err.localizedDescription) }
            case .cancelled:
                // Fires for both intentional stop() and OS-level teardown.
                // stop() nils stateCallback first, so intentional stops are silent here.
                glog("[WebServer] Listener cancelled")
                DispatchQueue.main.async { self.stateCallback?("Listener stopped unexpectedly") }
            default:
                break
            }
        }

        l.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }

        // Advertise via mDNS so browsers on the LAN discover the server without knowing the IP.
        // NWListener owns the advertisement — listener?.cancel() in stop() withdraws it automatically.
        l.service = NWListener.Service(name: "hdhrVCR+", type: "_http._tcp", domain: nil,
                                       txtRecord: NWTXTRecord(["path": "/"]))
        l.serviceRegistrationUpdateHandler = { change in
            switch change {
            case .add(let ep):    glog("[WebServer] mDNS registered: \(ep)")
            case .remove(let ep): glog("[WebServer] mDNS withdrawn: \(ep)")
            }
        }

        l.start(queue: queue)
        listener = l
    }

    func stop() {
        guard listener != nil else { return }
        stateCallback = nil   // prevent the .cancelled callback from surfacing as an error
        sseLock.lock()
        let dying = sseConns; sseConns.removeAll()
        sseLock.unlock()
        for c in dying { c.cancel() }
        listener?.cancel()
        listener = nil
        glog("[WebServer] Stopped")
    }

    // Push a JSON event to all open SSE clients.
    func broadcastEvent(_ event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let json = String(data: data, encoding: .utf8) else { return }
        let bytes = Data("data: \(json)\n\n".utf8)
        sseLock.lock()
        let conns = sseConns
        sseLock.unlock()
        for conn in conns {
            conn.send(content: bytes, completion: .contentProcessed({ [weak self] err in
                if err != nil { self?.removeSSE(conn) }
            }))
        }
    }

    private func removeSSE(_ conn: NWConnection) {
        sseLock.lock()
        sseConns.removeAll { $0 === conn }
        sseLock.unlock()
    }

    private func registerSSE(_ conn: NWConnection) {
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
        conn.send(content: Data(header.utf8), completion: .contentProcessed({ [weak self] err in
            guard let self, err == nil else { conn.cancel(); return }
            self.sseLock.lock()
            self.sseConns.append(conn)
            self.sseLock.unlock()
            self.sseKeepalive(conn)
        }))
    }

    private func sseKeepalive(_ conn: NWConnection) {
        // Comments every 25s keep the connection alive through proxies; EventSource auto-reconnects if it drops.
        queue.asyncAfter(deadline: .now() + 25) { [weak self] in
            guard let self else { return }
            self.sseLock.lock()
            let alive = self.sseConns.contains { $0 === conn }
            self.sseLock.unlock()
            guard alive else { return }
            conn.send(content: Data(": ping\n\n".utf8), completion: .contentProcessed({ [weak self] err in
                if err != nil { self?.removeSSE(conn) }
                else { self?.sseKeepalive(conn) }
            }))
        }
    }

    // MARK: - Connection handling

    private func handleConnection(_ conn: NWConnection) {
        guard isLocalAddress(conn.endpoint) else {
            conn.cancel()
            glog("[WebServer] Rejected non-LAN connection from \(conn.endpoint)")
            return
        }
        conn.start(queue: queue)
        accumulate(conn: conn, buffer: Data())
    }

    // Read until we have the full HTTP request (headers + Content-Length body bytes).
    private static let maxRequestBytes = 1 << 17  // 128 KB — enough for any guide/record JSON; caps memory growth from slow/malicious LAN clients
    private static let httpSep = Data([0x0d, 0x0a, 0x0d, 0x0a])  // \r\n\r\n as a static constant so accumulate() doesn't allocate it on every callback
    private func accumulate(conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, _, _ in
            guard let self, let chunk else { conn.cancel(); return }
            // append() reuses existing buffer capacity; `buffer + chunk` would allocate a full copy
            var data = buffer
            data.append(chunk)

            // Reject before buffering further — prevents a client that never sends \r\n\r\n from
            // growing the buffer without bound.
            if data.count > Self.maxRequestBytes {
                self.send(.payloadTooLarge("Request too large"), on: conn)
                return
            }

            // Locate the header/body separator
            guard let sepRange = data.range(of: Self.httpSep) else {
                // Headers not complete yet — keep reading
                self.accumulate(conn: conn, buffer: data)
                return
            }

            let headerSection = data[..<sepRange.lowerBound]
            let bodyBytes     = data[sepRange.upperBound...]

            // Parse Content-Length and User-Agent from headers
            let headerText    = String(data: headerSection, encoding: .utf8) ?? ""
            var contentLength = 0
            var userAgent     = ""
            for line in headerText.components(separatedBy: "\r\n").dropFirst() {
                let lower = line.lowercased()
                if lower.hasPrefix("content-length:") {
                    contentLength = Int(lower.dropFirst("content-length:".count)
                                           .trimmingCharacters(in: .whitespaces)) ?? 0
                } else if lower.hasPrefix("user-agent:") {
                    userAgent = String(line.dropFirst("user-agent:".count)
                                          .trimmingCharacters(in: .whitespaces))
                }
                if contentLength > 0, !userAgent.isEmpty { break }
            }

            // Early rejection on an oversized Content-Length prevents waiting to accumulate
            // the full body before discovering it exceeds the limit.
            if contentLength > Self.maxRequestBytes {
                self.send(.payloadTooLarge("Request body too large"), on: conn)
                return
            }

            if bodyBytes.count < contentLength {
                // Body not fully received yet — keep reading
                self.accumulate(conn: conn, buffer: data)
                return
            }

            // Full request assembled — parse and route
            let requestLine = headerText.components(separatedBy: "\r\n").first ?? ""
            let parts       = requestLine.components(separatedBy: " ")
            let method      = parts.count >= 1 ? parts[0] : "GET"
            let path        = parts.count >= 2 ? parts[1] : "/"
            let cleanPath   = path.components(separatedBy: "?").first ?? path
            let body: Data? = contentLength > 0 ? Data(bodyBytes.prefix(contentLength)) : nil

            if cleanPath == "/api/events" && method == "GET" {
                self.registerSSE(conn); return
            }
            Task {
                let response = await self.route(method: method, path: cleanPath, body: body, userAgent: userAgent)
                self.send(response, on: conn)
            }
        }
    }

    // MARK: - Routing

    private func route(method: String, path: String, body: Data?, userAgent: String) async -> WebResponse {
        // Refresh tuner occupancy from each device's status.json before serving the HTML page
        // so the counts are always live rather than waiting for the next idle-loop tick.
        if method == "GET", path == "/" || path == "/index.html" {
            await refreshTunerOccupancy()
        }
        return await MainActor.run { routeOnMain(method: method, path: path, body: body, userAgent: userAgent) }
    }

    private func refreshTunerOccupancy() async {
        let devices = await MainActor.run { appState?.devices ?? [] }
        glog("[WebServer] refreshTunerOccupancy: \(devices.count) device(s)")
        await withTaskGroup(of: Void.self) { group in
            for device in devices {
                group.addTask { [weak self] in
                    guard let url = URL(string: device.statusURL) else {
                        glog("[WebServer] refreshTunerOccupancy: bad statusURL for \(device.DeviceID)", level: .warning)
                        return
                    }
                    // Ignore the URL cache — status.json must always reflect current device state.
                    var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
                    req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                    guard let (data, resp) = try? await URLSession.shared.data(for: req) else {
                        glog("[WebServer] refreshTunerOccupancy: fetch failed for \(device.DeviceID) \(url)", level: .warning)
                        return
                    }
                    let http = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    guard let tuners = try? JSONDecoder().decode([DeviceTunerInfo].self, from: data) else {
                        let raw = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
                        glog("[WebServer] refreshTunerOccupancy: decode failed for \(device.DeviceID) HTTP \(http) body=\(raw)", level: .warning)
                        return
                    }
                    let activeTuners = tuners.filter { $0.VctNumber != nil }
                    glog("[WebServer] refreshTunerOccupancy: \(device.DeviceID) HTTP \(http) → \(tuners.count) slot(s) total, \(activeTuners.count) active: \(activeTuners.map { "\($0.Resource) ch\($0.VctNumber ?? "?")" }.joined(separator: ", "))")
                    await MainActor.run { self?.appState?.deviceTunerOccupancy[device.DeviceID] = tuners }
                }
            }
        }
        // Log final occupancy used for page render
        let summary = await MainActor.run {
            (appState?.devices ?? []).map { d in
                let occ = appState?.deviceTunerOccupancy[d.DeviceID]
                let total = d.TunerCount ?? 0
                return "\(d.DeviceID): occ=\(occ.map { "\($0.count)" } ?? "nil")/\(total)"
            }.joined(separator: ", ")
        }
        glog("[WebServer] tunerOccupancy after refresh: \(summary)")
    }

    @MainActor
    private func routeOnMain(method: String, path: String, body: Data?, userAgent: String) -> WebResponse {
        guard let state = appState else { return .notFound("App state unavailable") }

        // POST routes
        if method == "POST" {
            if path == "/api/record"       { return handleRecord(state: state, body: body) }
            if path == "/api/delete"       { return handleDelete(state: state, body: body) }
            if path == "/api/edit"         { return handleEdit(state: state, body: body) }
            if path == "/api/signal-scan"  {
                let force = (try? JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any])?["force"] as? Bool ?? false
                state.startSignalScan(force: force)
                return jsonResponse(["status": "started", "force": force])
            }
            return .notFound("Not found: \(path)")
        }

        // GET routes
        switch path {
        case "/", "/index.html":
            let html = buildHTML(state: state, isDesktop: isDesktopUA(userAgent))
            return .ok(contentType: "text/html; charset=utf-8", body: Data(html.utf8))

        case "/api/ping":
            return .ok(contentType: "application/json", body: Data(#"{"ok":true}"#.utf8))

        case "/api/now.json":
            let data = buildNowJSON(state: state)
            return .ok(contentType: "application/json", body: data)

        case "/api/shows-html":
            let html = buildSchedPopHTML(state: state)
            return .ok(contentType: "text/html; charset=utf-8", body: Data(html.utf8))

        case "/api/signal":
            var out: [String: String] = [:]
            for (key, bucket) in ChannelSignalStore.shared.buckets { out[key] = bucket.rawValue }
            let data = (try? JSONSerialization.data(withJSONObject: out)) ?? Data("{}".utf8)
            return .ok(contentType: "application/json", body: data)

        default:
            return .notFound("Not found: \(path)")
        }
    }

    // Schedules a single-episode recording for the guide entry identified by
    // deviceId + guideNumber + startTime in the POST body JSON.
    private func jsonResponse(_ dict: [String: Any]) -> WebResponse {
        .ok(contentType: "application/json",
            body: (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8))
    }

    @MainActor
    private func handleRecord(state: AppState, body: Data?) -> WebResponse {
        let json = jsonResponse
        guard let body,
              let obj       = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let deviceId  = obj["deviceId"]    as? String,
              let guideNum  = obj["guideNumber"] as? String,
              let startTime = obj["startTime"]   as? Int
        else { return .badRequest("Missing required fields: deviceId, guideNumber, startTime") }

        guard let device = state.devices.first(where: { $0.DeviceID == deviceId }),
              let ch     = state.lineups[deviceId]?.first(where: { $0.GuideNumber == guideNum })
        else { return json(["ok": false, "error": "Device or channel not found"]) }

        // distantPast so currently-airing shows (StartTime < now) are also matchable
        guard let entry = state.guideStore
                .entries(deviceId: deviceId, channelNum: guideNum, after: .distantPast)
                .first(where: { $0.StartTime == startTime })
        else { return json(["ok": false, "error": "Guide entry not found"]) }

        let showType: ShowState = {
            switch obj["showType"] as? String ?? "" {
            case "dateTime":      return .dateTime
            case "seriesChannel": return .seriesChannel
            case "seriesAll":     return .seriesAll
            default:              return .single
            }
        }()
        let activeTuners = state.deviceTunerOccupancy[deviceId]?.filter({ $0.VctNumber != nil }).count ?? 0
        let total        = device.TunerCount ?? 0
        let tunerFull    = total > 0 && activeTuners >= total
        let nowTs        = Int(Date().timeIntervalSince1970)
        let recStarted   = entry.StartTime <= nowTs && entry.EndTime > nowTs
        let newActive    = recStarted && !tunerFull ? activeTuners + 1 : activeTuners
        let airDays   = obj["airDays"]   as? [String]
        let transcode = obj["transcode"] as? String
        let bonusTime = obj["bonusTime"] as? Bool ?? false
        state.addShowFromGuide(entry: entry, type: showType, device: device, channel: ch, airDays: airDays, transcode: transcode, bonusTime: bonusTime)
        return json(["ok": true, "title": entry.Title, "tunerFull": tunerFull,
                     "recStarted": recStarted, "tunerActive": newActive, "tunerTotal": total])
    }

    // Removes the show that owns the guide entry identified by deviceId + guideNumber + title.
    // Stops any active recording and saves config, same as the in-app Delete flow.
    @MainActor
    private func handleDelete(state: AppState, body: Data?) -> WebResponse {
        let json = jsonResponse
        guard let body,
              let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return .badRequest("Missing or invalid JSON body") }

        let showId   = obj["showId"]      as? String ?? ""
        let deviceId = obj["deviceId"]    as? String ?? ""
        let guideNum = obj["guideNumber"] as? String ?? ""
        let title    = obj["title"]       as? String ?? ""

        guard !showId.isEmpty || (!deviceId.isEmpty && !guideNum.isEmpty)
        else { return .badRequest("Missing required field: showId or (deviceId + guideNumber)") }

        // Primary: showId (from edit modal). Fallback: active recording on device+channel, then title match.
        let show: Show? = !showId.isEmpty
            ? state.shows.first(where: { $0.show_id == showId })
            : state.recordingShows.first(where: {
                  $0.hdhr_record == deviceId && $0.show_channel == guideNum
              }) ?? state.shows.first(where: {
                  $0.show_active &&
                  $0.show_channel == guideNum &&
                  $0.show_title == title
              })
        guard let show else { return json(["ok": false, "error": "Show not found"]) }

        // Edit the Discord "Recording Started" embed before clearing state — show is a struct
        // copy so show.show_recording / discord_start_msg_id still reflect the original values.
        state.discordWebDelete(show)
        // Clear url/recording on the live copy so nothing re-queues while deleteShow runs;
        // deleteShow() owns the stop() call and uses the original show copy's URL for VLC close.
        if let idx = state.shows.firstIndex(where: { $0.show_id == show.show_id }) {
            state.shows[idx].show_url       = ""
            state.shows[idx].show_recording = false
        }
        state.deleteShow(show)
        broadcastEvent(["type": "show_deleted", "channel": show.show_channel, "device": show.hdhr_record])
        return json(["ok": true, "title": show.show_title])
    }

    // Updates show type and/or pause state by showId. Called from the web edit modal.
    @MainActor
    private func handleEdit(state: AppState, body: Data?) -> WebResponse {
        let json = jsonResponse
        guard let body,
              let obj    = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let showId = obj["showId"] as? String,
              let show   = state.shows.first(where: { $0.show_id == showId })
        else { return .badRequest("Missing required field: showId") }

        var updated = show
        let allDays = ["Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"]

        if let typeStr = obj["showType"] as? String {
            switch typeStr {
            case "single":
                updated.show_is_series = false; updated.show_use_seriesid = false; updated.show_use_seriesid_all = false
            case "dateTime":
                updated.show_is_series = true; updated.show_use_seriesid = false; updated.show_use_seriesid_all = false
                if updated.show_air_date.isEmpty { updated.show_air_date = allDays }
            case "seriesChannel":
                updated.show_is_series = true; updated.show_use_seriesid = true; updated.show_use_seriesid_all = false
                updated.show_air_date = allDays
            case "seriesAll":
                updated.show_is_series = true; updated.show_use_seriesid = true; updated.show_use_seriesid_all = true
                updated.show_air_date = allDays
            default: break
            }
        }

        if let paused = obj["paused"] as? Bool {
            updated.show_paused = paused
            if paused { updated.show_fail_reason = "Manually paused" } else { updated.clearFailures() }
        }
        if let title = obj["title"] as? String, !title.isEmpty { updated.show_title = title }
        if let ch = obj["channel"] as? String, !ch.isEmpty { updated.show_channel = ch }
        if let len = obj["length"] as? Int, len > 0 { updated.show_length = len }
        if let bonus = obj["bonusTime"] as? Bool { updated.show_bonus_time = bonus }
        if let transcode = obj["transcode"] as? String { updated.show_transcode = transcode }
        if let saveDir = obj["saveDir"] as? String, !saveDir.isEmpty {
            updated.show_dir = saveDir
            updated.show_temp_dir = saveDir
        }
        if let airDays = obj["airDays"] as? [String] { updated.show_air_date = airDays }
        if let reset = obj["resetFailures"] as? Bool, reset { updated.clearFailures(); updated.show_active = true }

        state.updateShow(updated)
        broadcastEvent(["type": "show_updated", "channel": updated.show_channel, "device": updated.hdhr_record])
        // If the show was just promoted to a seriesID type, search the guide immediately
        // so show_next is set before the next idle loop tick.
        if updated.show_use_seriesid && !show.show_use_seriesid {
            Task { await state.rescheduleAllSeries() }
        }
        return json(["ok": true, "title": updated.show_title])
    }

    private func showTypeStr(_ show: Show) -> String {
        switch show.state {
        case .single:        return "single"
        case .dateTime:      return "dateTime"
        case .seriesChannel: return "seriesChannel"
        case .seriesAll:     return "seriesAll"
        }
    }

    // MARK: - HTML / JSON generation

    @MainActor
    private func buildSchedPopHTML(state: AppState) -> String {
        // Common row builder — embeds all data needed by openEditShow() JS.
        func showRow(_ s: Show, recording: Bool = false, prefix: String = "") -> String {
            let t = showTypeStr(s)
            let ad = s.show_air_date.joined(separator: ",")
            let da = "data-id=\"\(he(s.show_id))\" data-title=\"\(he(s.show_title))\" data-ch=\"\(he(s.show_channel))\" data-type=\"\(t)\" data-paused=\"\(s.show_paused ? 1 : 0)\" data-recording=\"\(recording ? 1 : 0)\" data-length=\"\(s.show_length)\" data-bonus=\"\(s.show_bonus_time ? 1 : 0)\" data-dir=\"\(he(s.show_dir))\" data-transcode=\"\(he(s.show_transcode))\" data-seriesid=\"\(he(s.show_seriesid))\" data-airdays=\"\(he(ad))\" data-failcount=\"\(s.show_fail_count)\" data-failreason=\"\(he(s.show_fail_reason))\""
            let endDetail = recording ? s.show_end.map { " · Ends \(state.shortTime($0))" } ?? "" : ""
            return "<div class=\"sp-row\" \(da) onclick=\"openEditShow(this)\">"
                 + "<div class=\"sp-t\">\(prefix)\(he(s.show_title))</div>"
                 + "<div class=\"sp-ch\">Ch \(he(s.show_channel))\(endDetail)</div>"
                 + "</div>"
        }

        var parts: [String] = []

        if !state.recordingShows.isEmpty {
            let rows = state.recordingShows.map { showRow($0, recording: true, prefix: "<span class=\"sp-rec\">●</span> ") }.joined()
            parts.append("<div class=\"sp-sec\"><div class=\"sp-hdr\">Recording</div>\(rows)</div>")
        }

        // Sort by next air time ascending; shows without a date sort to the end.
        let sortedActive = state.activeShows.sorted {
            ($0.show_next?.timeIntervalSince1970 ?? .infinity) < ($1.show_next?.timeIntervalSince1970 ?? .infinity)
        }
        let upNext     = sortedActive.first(where: { $0.show_next != nil })
        let restActive = sortedActive.filter { $0.show_id != upNext?.show_id }

        if let next = upNext {
            if !parts.isEmpty { parts.append("<div class=\"sp-div\"></div>") }
            let rel = txtRelativeTime(next.show_next!)
            let t   = showTypeStr(next)
            let nad = next.show_air_date.joined(separator: ",")
            let da  = "data-id=\"\(he(next.show_id))\" data-title=\"\(he(next.show_title))\" data-ch=\"\(he(next.show_channel))\" data-type=\"\(t)\" data-paused=\"0\" data-recording=\"0\" data-length=\"\(next.show_length)\" data-bonus=\"\(next.show_bonus_time ? 1 : 0)\" data-dir=\"\(he(next.show_dir))\" data-transcode=\"\(he(next.show_transcode))\" data-seriesid=\"\(he(next.show_seriesid))\" data-airdays=\"\(he(nad))\" data-failcount=\"\(next.show_fail_count)\" data-failreason=\"\(he(next.show_fail_reason))\""
            parts.append("<div class=\"sp-sec\"><div class=\"sp-hdr\">Up Next</div><div class=\"sp-row\" \(da) onclick=\"openEditShow(this)\"><div class=\"sp-t\">\(he(next.show_title))</div><div class=\"sp-ch\">Ch \(he(next.show_channel)) · <span style=\"color:var(--ac)\">\(he(rel))</span></div></div></div>")
        }

        if !restActive.isEmpty {
            if !parts.isEmpty { parts.append("<div class=\"sp-div\"></div>") }
            let rows = restActive.map { showRow($0) }.joined()
            parts.append("<div class=\"sp-sec\"><div class=\"sp-hdr\">Scheduled</div>\(rows)</div>")
        }

        if !state.pausedShows.isEmpty {
            if !parts.isEmpty { parts.append("<div class=\"sp-div\"></div>") }
            let rows = state.pausedShows.map { showRow($0, prefix: "<span style=\"color:var(--t4)\">⏸</span> ") }.joined()
            parts.append("<div class=\"sp-sec\"><div class=\"sp-hdr\">Paused</div>\(rows)</div>")
        }

        return parts.isEmpty ? "<div class=\"sp-empty\">No shows scheduled.</div>" : parts.joined()
    }

    @MainActor
    private func buildHTML(state: AppState, isDesktop: Bool) -> String {

        // ── Time window: full GuideHours for desktop, 1/2 for mobile ──────
        let nowTs    = Int(Date().timeIntervalSince1970)
        let halfHour = 30 * 60
        let winSec   = isDesktop ? state.config.GuideHours * 3600
                                 : state.config.GuideHours * 3600 / 2
        // One half-hour slot lookback — GuideStore fetches from now-3600 so this is always covered.
        let winStart = (nowTs / halfHour) * halfHour - halfHour
        let winEnd   = winStart + winSec
        // Integer-only percentage formatter — avoids ~1500 String(format:) calls per full guide render.
        // Computes offset/winSec*100 to 4 decimal places using only integer arithmetic.
        func pct(_ offset: Int) -> String {
            let n     = offset * 1_000_000 / winSec
            let whole = n / 10000
            let frac  = n % 10000
            return "\(whole).\(frac / 1000)\((frac / 100) % 10)\((frac / 10) % 10)\(frac % 10)"
        }
        let nowPct = pct(nowTs - winStart)
        // Grid min-width: 100px per 30-min slot so text stays readable at any window size.
        let guideMinWidth = max(1200, winSec / 1800 * 100)

        // ── Time tick labels: 7 marks evenly spaced across the window ────────
        // Interval = winSec/6 → 1h steps for 6h window, 2h steps for 12h window, etc.
        let ticksHTML: String = (0...6).map { i in
            let ts  = winStart + i * (winSec / 6)
            let lbl = he(timeRangeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(ts))))
            return "<div class=\"g-tick\" style=\"left:\(pct(i * winSec / 6))%\">\(lbl)</div>"
        }.joined() + "<div class=\"g-now-tick\" style=\"left:\(nowPct)%\"></div>"

        // ── Managed show lookup (device-agnostic for badge coloring) ─────────
        // Capture computed property once — each access re-filters the full shows array.
        let recording = state.recordingShows
        // Per-device recording channel sets — device-scoped so a recording on device A doesn't
        // falsely badge the same channel on device B as Recording in a multi-device guide view.
        let recChannelsByDevice: [String: Set<String>] = Dictionary(
            grouping: recording, by: { $0.hdhr_record }
        ).mapValues { Set($0.map { $0.show_channel }) }
        let activeMgd    = state.shows.filter { $0.show_active && !$0.show_paused }
        let guideMatcher = ManagedGuideMatcher(activeManagedShows: activeMgd)
        // Pre-built O(1) indexes for findManagedShow — avoids O(n) scans per guide block.
        let activeMgdBySeries = Dictionary(
            activeMgd.filter { $0.isSeries && !$0.show_seriesid.isEmpty }.map { ($0.show_seriesid, $0) },
            uniquingKeysWith: { a, _ in a })
        let activeMgdByTitle  = Dictionary(
            activeMgd.filter { $0.isSeries }.map { ($0.show_title, $0) },
            uniquingKeysWith: { a, _ in a })
        // Returns the managed Show matching a guide entry — used to embed show data attrs on
        // managed blocks so the web edit modal can be opened directly from the guide.
        let findManagedShow: (GuideEntry, LineupEntry) -> Show? = { e, ch in
            if let sid = e.SeriesID, !sid.isEmpty, let s = activeMgdBySeries[sid] { return s }
            if let s = activeMgdByTitle[e.Title] { return s }
            return activeMgd.first(where: { $0.show_title == e.Title && $0.show_channel == ch.GuideNumber })
        }

        // ── Per-device tuner counts (total slots vs. currently occupied) ────────
        // active = live status.json snapshot; falls back to scheduled recording count.
        struct DevTuners { let total: Int; let active: Int; var isFull: Bool { total > 0 && active >= total } }
        var devTuners: [String: DevTuners] = [:]
        for d in state.devices {
            let total  = d.TunerCount ?? 0
            // Active = VctNumber present; idle slots appear in status.json with only "Resource" set.
            let occupancy  = state.deviceTunerOccupancy[d.DeviceID]
            let active     = occupancy?.filter({ $0.VctNumber != nil }).count ?? 0
            let occStr     = occupancy.map { "\($0.count)" } ?? "nil"
            // recCount is diagnostic only — active (from status.json) drives isFull, not recCount.
            glog("[WebServer] buildHTML tuners \(d.DeviceID): occupancy=\(occStr) active=\(active)/\(total) recordingShows=\(recording.filter { $0.hdhr_record == d.DeviceID }.count)")
            devTuners[d.DeviceID] = DevTuners(total: total, active: active)
        }
        // Embed tuner counts + per-device active-recording list as JS literals.
        // Build via JSONSerialization so DeviceID and LocalIP values are properly JSON-encoded;
        // raw string interpolation into JS string literals would allow injection if a device
        // ever had special characters in its ID or IP.
        let tunerJS: String = {
            var dict: [String: Any] = [:]
            for d in state.devices {
                guard let dt = devTuners[d.DeviceID] else { continue }
                dict[d.DeviceID] = ["t": dt.total, "a": dt.active, "surl": "http://\(d.LocalIP)/status.json"]
            }
            guard let data = try? JSONSerialization.data(withJSONObject: dict),
                  let str  = String(data: data, encoding: .utf8) else { return "var tuners={};" }
            return "var tuners=\(jsEscapeForScript(str));"
        }()
        // Pre-compute channel-number → name lookup per device (captured by the closure below).
        let channelNameLookup: [String: [String: String]] = Dictionary(
            uniqueKeysWithValues: state.devices.map { d in
                let map = Dictionary(
                    (state.lineups[d.DeviceID] ?? []).map { ($0.GuideNumber, $0.GuideName) },
                    uniquingKeysWith: { first, _ in first })
                return (d.DeviceID, map)
            })

        let recsByDevJS: String = {
            var devMap: [String: [[String: String]]] = [:]
            for d in state.devices {
                var entries: [[String: String]] = []
                func chName(_ num: String) -> String { channelNameLookup[d.DeviceID]?[num] ?? "" }
                if let occupancy = state.deviceTunerOccupancy[d.DeviceID], !occupancy.isEmpty {
                    for info in occupancy {
                        let matchShow = recording.first {
                            $0.hdhr_record == d.DeviceID && $0.show_tuner_resource == info.Resource
                        }
                        let title: String = {
                            if let t = matchShow?.show_title, !t.isEmpty { return t }
                            if let ch = info.VctNumber { return "Live stream ch \(ch)" }
                            return "Active stream"
                        }()
                        let ch = matchShow?.show_channel ?? info.VctNumber ?? "?"
                        entries.append(["tuner": info.Resource, "title": title, "ch": ch, "chname": chName(ch)])
                    }
                } else {
                    for show in recording.filter({ $0.hdhr_record == d.DeviceID }) {
                        entries.append([
                            "tuner":   show.show_tuner_resource.isEmpty ? "—" : show.show_tuner_resource,
                            "title":   show.show_title,
                            "ch":      show.show_channel,
                            "chname":  chName(show.show_channel)
                        ])
                    }
                }
                devMap[d.DeviceID] = entries
            }
            if let data = try? JSONSerialization.data(withJSONObject: devMap),
               let str  = String(data: data, encoding: .utf8) { return "var recsByDev=\(jsEscapeForScript(str));" }
            return "var recsByDev={};"
        }()

        // ── Helper: tuner-info button HTML ───────────────────────────────────────
        func tunerInfoBtn(_ devId: String, _ dt: DevTuners) -> String {
            guard dt.total > 0 else { return "" }
            let cls   = "t-info" + (dt.isFull ? " t-info-full" : "")
            let label = "\(dt.active)/\(dt.total)\(dt.isFull ? " — FULL" : "")"
            // data-dev carries the already-he()-escaped DeviceID; onclick reads it via dataset
            // so no DeviceID value ever touches a JS string literal.
            return "<button id=\"tun-\(he(devId))\" class=\"\(cls)\" data-dev=\"\(he(devId))\" onclick=\"showTunerInfo(this.dataset.dev,this)\" title=\"Click to see active recordings\">\(label)</button>"
        }

        // ── Status toggle button — sits next to h1 in the header; reveals the status panel ──
        let statusBtn = "<button id=\"status-btn\" onclick=\"openSchedPop(this)\" title=\"Schedule &amp; recordings\" aria-expanded=\"false\" style=\"background:none;border:none;cursor:pointer;color:var(--t4);font-size:1.1rem;padding:2px 6px;line-height:1;border-radius:4px\">≡</button>"

        // ── Device bar (shown when >1 device; links to local HDHR web UI) ──────
        let headerHTML: String
        let deviceBarHTML: String
        if state.devices.count == 1, let d = state.devices.first {
            let uiURL = "http://\(d.LocalIP)/"
            let label = "HDHR-\(d.DeviceID.uppercased())"
            let dt    = devTuners[d.DeviceID]!
            headerHTML = "<div style=\"display:flex;align-items:flex-start;gap:10px\">\(statusBtn)<div><h1 style=\"margin:0\">hdhrVCR+ Guide</h1><div style=\"display:flex;align-items:center;gap:6px;margin-top:4px\">\(tunerInfoBtn(d.DeviceID, dt))<a href=\"\(he(uiURL))\" target=\"_blank\" style=\"font-size:.75rem;color:#666;text-decoration:none\" title=\"Open \(he(label)) device web UI\">\(he(label)) ↗</a></div></div></div>"
            deviceBarHTML = ""
        } else if state.devices.count > 1 {
            headerHTML = "<div style=\"display:flex;align-items:center;gap:8px\">\(statusBtn)<h1 style=\"margin:0\">hdhrVCR+ Guide</h1></div>"
            var bar = "<div id=\"dev-bar\" style=\"flex-direction:column;align-items:flex-start;gap:4px\">"
            for d in state.devices {
                let uiURL = "http://\(d.LocalIP)/"
                let label = he("HDHR-\(d.DeviceID.uppercased())")
                let dt    = devTuners[d.DeviceID]!
                bar += "<div style=\"display:flex;align-items:center;gap:6px\">"
                bar += "<button class=\"d-btn\" data-dev=\"\(he(d.DeviceID))\" onclick=\"setDev(this.dataset.dev)\">\(label)</button>"
                bar += "<a href=\"\(he(uiURL))\" target=\"_blank\" class=\"d-ui\" title=\"Open \(label) web UI\">↗</a>"
                bar += tunerInfoBtn(d.DeviceID, dt)
                bar += "</div>"
            }
            bar += "</div>"
            deviceBarHTML = bar
        } else {
            headerHTML = "<div style=\"display:flex;align-items:center;gap:8px\">\(statusBtn)<h1 style=\"margin:0\">hdhrVCR+ Guide</h1></div>"
            deviceBarHTML = ""
        }

        // ── Guide grid rows — one row per (device × channel); JS deduplicates the "All" view ──
        var rowParts: [String] = []

        for device in state.devices {
            let sorted = (state.lineups[device.DeviceID] ?? [])
                .sorted {
                    if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
                    return $0.GuideNumber.channelSortKey < $1.GuideNumber.channelSortKey
                }
            var seenInDevice = Set<String>()   // dedup duplicate lineup entries within same device
            for ch in sorted {
                guard seenInDevice.insert(ch.GuideNumber).inserted else { continue }
                // Pass winStart as `after:` so shows that ended before now but within the lookback
                // window aren't silently dropped by the default after:Date() filter.
                let entries = state.guideStore.entries(deviceId: device.DeviceID, channelNum: ch.GuideNumber,
                                                       after: Date(timeIntervalSince1970: TimeInterval(winStart)))
                    .filter { $0.StartTime < winEnd }
                guard !entries.isEmpty else { continue }

                let logoURL  = state.channelImageURLs["\(device.DeviceID):\(ch.GuideNumber)"] ?? ""
                let isHD     = (ch.HD ?? 0) != 0
                let chLabel  = ch.GuideNumber + (isHD ? " HD" : "")
                let logoHTML = logoURL.isEmpty
                    ? "<div class=\"g-logo-ph\">\(he(String(ch.GuideName.prefix(1))))</div>"
                    : "<img class=\"g-logo\" src=\"\(he(logoURL))\" onerror=\"this.style.display='none'\" alt=\"\">"
                let isRecCh  = recChannelsByDevice[device.DeviceID]?.contains(ch.GuideNumber) ?? false

                var blockParts: [String] = ["<div class=\"g-now-bar\" style=\"left:\(nowPct)%\"></div>"]
                // Fill gaps so the striped .g-tl background never shows through.
                // cursor tracks the right edge of the last processed show, starting at winStart.
                var cursor = winStart
                for e in entries {
                    let gapEnd = min(e.StartTime, winEnd)
                    if gapEnd > cursor {
                        blockParts.append("<div class=\"g-gap\" style=\"left:\(pct(cursor - winStart))%;width:\(pct(gapEnd - cursor))%\"></div>")
                    }
                    cursor = max(cursor, e.EndTime)
                }
                if cursor < winEnd {
                    blockParts.append("<div class=\"g-gap\" style=\"left:\(pct(cursor - winStart))%;width:\(pct(winEnd - cursor))%\"></div>")
                }
                for e in entries {
                    let cs = max(e.StartTime, winStart) - winStart
                    let ce = min(e.EndTime,   winEnd)   - winStart
                    guard ce > cs else { continue }

                    let isNow      = e.StartTime <= nowTs && e.EndTime > nowTs
                    let isEntryRec = isRecCh && isNow
                    let isMgd      = guideMatcher.isManaged(entry: e)
                    var cls = "g-prog"
                    if isEntryRec      { cls += " g-prog-rec"   }
                    else if isNow      { cls += " g-prog-now"   }
                    else if isMgd      { cls += " g-prog-sched" }
                    // Genre applied to all blocks; .g-prog-now.gg-* compounds handle the lighter airing variant
                    switch (e.firstGenre ?? "").lowercased() {
                    case "drama":    cls += " gg-drama"
                    case "comedy":   cls += " gg-comedy"
                    case "news":     cls += " gg-news"
                    case "sports":   cls += " gg-sports"
                    case "reality":  cls += " gg-reality"
                    case "movie":    cls += " gg-movie"
                    case "talk":     cls += " gg-talk"
                    case "children", "kids": cls += " gg-children"
                    default: break
                    }

                    let sub   = e.EpisodeTitle.flatMap { $0.isEmpty ? nil : $0 } ?? ""
                    let tip   = sub.isEmpty
                        ? "\(he(e.Title))  (\(he(guideTimeRange(e))))"
                        : "\(he(e.Title)) · \(he(sub))  (\(he(guideTimeRange(e))))"
                    let subH  = sub.isEmpty ? "" : "<span class=\"g-sub\">\(he(sub))</span>"

                    // Data attributes for the JS summary panel; synopsis capped to keep HTML size sane
                    let synAttr  = String((e.Synopsis ?? "")
                        .replacingOccurrences(of: "\n", with: " ").prefix(220))
                    let dateAttr = e.OriginalAirdate.map {
                        origAirdateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval($0)))
                    } ?? ""
                    let da = "data-title=\"\(he(e.Title))\" data-syn=\"\(he(synAttr))\" data-poster=\"\(he(e.ImageURL ?? ""))\" data-ep=\"\(he(e.episodeInfoLabel ?? ""))\" data-date=\"\(he(dateAttr))\" data-genre=\"\(he(e.firstGenre ?? ""))\" data-start=\"\(e.StartTime)\" data-end=\"\(e.EndTime)\" data-device=\"\(he(device.DeviceID))\" data-num=\"\(he(ch.GuideNumber))\" data-chname=\"\(he(ch.GuideName))\" data-logo=\"\(he(logoURL))\" data-series=\"\(he(e.SeriesID ?? ""))\" data-managed=\"\(isMgd ? 1 : 0)\" data-recording=\"\(isEntryRec ? 1 : 0)\""

                    let flagHTML = isEntryRec ? "<div class=\"g-flag-rec\"></div>"
                                 : isMgd      ? "<div class=\"g-flag\"></div>" : ""
                    let showDA: String = isMgd ? {
                        let s = findManagedShow(e, ch)
                        guard let s else { return "" }
                        let ad = s.show_air_date.joined(separator: ",")
                        return " data-show-id=\"\(he(s.show_id))\" data-show-type=\"\(showTypeStr(s))\" data-show-paused=\"\(s.show_paused ? 1 : 0)\" data-show-length=\"\(s.show_length)\" data-show-bonus=\"\(s.show_bonus_time ? 1 : 0)\" data-show-transcode=\"\(he(s.show_transcode))\" data-show-seriesid=\"\(he(s.show_seriesid))\" data-show-airdays=\"\(he(ad))\" data-show-failcount=\"\(s.show_fail_count)\" data-show-failreason=\"\(he(s.show_fail_reason))\" data-show-recording=\"\(s.show_recording ? 1 : 0)\""
                    }() : ""
                    blockParts.append("<div class=\"\(cls)\" style=\"left:\(pct(cs))%;width:\(pct(ce - cs))%\" title=\"\(tip)\" \(da)\(showDA) onclick=\"showInfo(this)\"><div class=\"g-pi\"><span class=\"g-ti\">\(he(e.Title))</span>\(subH)</div>\(flagHTML)</div>")
                }

                let gnameAttr = ch.GuideName.lowercased()
                let sigBucket = ChannelSignalStore.shared.buckets[gnameAttr] ?? .noData
                let sigHTML: String = {
                    guard sigBucket != .noData else { return "" }
                    let color = sigBucket == .poor ? "#e53935" : sigBucket == .fair ? "#fbc02d" : "#43a047"
                    let b2Color = sigBucket != .poor ? color : "#555"
                    let b3Color = sigBucket == .good ? color : "#555"
                    return "<svg class=\"g-sig\" viewBox=\"0 0 11 10\" width=\"11\" height=\"10\" title=\"Signal: \(sigBucket.rawValue)\">"
                        + "<rect x=\"0\" y=\"6\" width=\"3\" height=\"4\" fill=\"\(color)\"/>"
                        + "<rect x=\"4\" y=\"3\" width=\"3\" height=\"7\" fill=\"\(b2Color)\"/>"
                        + "<rect x=\"8\" y=\"0\" width=\"3\" height=\"10\" fill=\"\(b3Color)\"/>"
                        + "</svg>"
                }()
                rowParts.append("<div class=\"g-row\" data-dev=\"\(he(device.DeviceID))\" data-ch=\"\(he(ch.GuideNumber))\" data-gname=\"\(he(gnameAttr))\"><div class=\"g-ch\">\(logoHTML)<div class=\"g-cl\"><span class=\"g-cn\">\(he(chLabel))</span><span class=\"g-cname\">\(he(ch.GuideName))</span></div>\(sigHTML)</div><div class=\"g-tl\">\(blockParts.joined())</div></div>")
            }
        }
        let rowsHTML = rowParts.isEmpty
            ? "<div style=\"padding:24px;color:#555;text-align:center;font-size:.85rem\">No guide data — loading…</div>"
            : rowParts.joined()

        // ── Summary placeholder: current recording or next scheduled show ────
        let phSorted = state.activeShows.sorted {
            ($0.show_next?.timeIntervalSince1970 ?? .infinity) < ($1.show_next?.timeIntervalSince1970 ?? .infinity)
        }
        func phLogo(_ deviceId: String, _ ch: String) -> String {
            let url = state.channelImageURLs["\(deviceId):\(ch)"] ?? ""
            guard !url.isEmpty else { return "" }
            return "<img src=\"\(he(url))\" onerror=\"this.style.display='none'\" style=\"width:36px;height:36px;object-fit:contain;border-radius:4px;flex-shrink:0;margin-right:12px\">"
        }
        let sumPhHTML: String
        if let rec = recording.first {
            var sub = ""
            if let next = phSorted.first(where: { $0.show_next != nil && $0.show_id != rec.show_id }) {
                sub = "<div style=\"font-size:.7rem;color:var(--t4);margin-top:2px\"><span style=\"color:var(--ac)\">★</span> \(he(next.show_title)) · \(he(txtRelativeTime(next.show_next!)))</div>"
            }
            sumPhHTML = "\(phLogo(rec.hdhr_record, rec.show_channel))<div><div style=\"font-size:.82rem;font-weight:600;color:var(--t0)\"><span style=\"color:#ff8080\">●</span> Recording: \(he(rec.show_title))</div>\(sub)</div>"
        } else if let next = phSorted.first(where: { $0.show_next != nil }) {
            sumPhHTML = "\(phLogo(next.hdhr_record, next.show_channel))<div><div style=\"font-size:.82rem;font-weight:600;color:var(--t0)\"><span style=\"color:var(--ac)\">★</span> Up Next: \(he(next.show_title))</div><div style=\"font-size:.7rem;color:var(--t4);margin-top:2px\">\(he(txtRelativeTime(next.show_next!)))</div></div>"
        } else {
            sumPhHTML = "<div style=\"font-size:.85rem;color:var(--t5)\">Select a show from the guide</div>"
        }

        // ── Schedule popover content ──────────────────────────────────────────
        let schedPopHTML = buildSchedPopHTML(state: state)

        // ── Assemble ──────────────────────────────────────────────────────────
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>hdhrVCR+</title>
        <script>(function(){try{var m=localStorage.getItem('theme')||'dark';if(m==='light'||(m==='auto'&&window.matchMedia('(prefers-color-scheme:light)').matches))document.documentElement.classList.add('lm');}catch(e){}})();</script>
        <style>
        *{box-sizing:border-box;margin:0;padding:0}
        /* ── Theme variables: dark default (.lm = light mode active) ── */
        :root{
          --bg:#141414;--s1:#1a1a1a;--s2:#1c1c1c;--s3:#1e1e1e;--s4:#222222;
          --b0:#252525;--b1:#333333;--b2:#383838;--b3:#3a3a3a;--b4:#444444;--b5:#484848;
          --t0:#f0f0f0;--t1:#e8e8e8;--t2:#d0d0d0;--t3:#aaaaaa;--t4:#888888;--t5:#777777;--t6:#666666;
          --pg:#2c2c2c;--pgb:#484848;--ac:#5aacff;--acb:#0e1f35;
        }
        html.lm{
          --bg:#f0f2f5;--s1:#f4f5f7;--s2:#f8f8fa;--s3:#ffffff;--s4:#eeeeee;
          --b0:#e4e4e4;--b1:#d8d8d8;--b2:#c8c8c8;--b3:#d0d0d0;--b4:#bbbbbb;--b5:#b8b8b8;
          --t0:#111111;--t1:#222222;--t2:#444444;--t3:#666666;--t4:#888888;--t5:#888888;--t6:#999999;
          --pg:#e0e0e8;--pgb:#ababbb;--ac:#0069cc;--acb:#e0eeff;
        }
        body{background:var(--bg);color:var(--t0);font-family:-apple-system,sans-serif;padding:16px}
        h1{font-size:1.15rem;color:var(--t2);margin-bottom:0}
        a[target="_blank"]{color:var(--t6)!important;text-decoration:none}
        /* ── Device switcher bar ── */
        #dev-bar{display:flex;gap:6px;align-items:center;margin-bottom:16px;flex-wrap:wrap}
        .d-btn{background:var(--s4);border:1px solid var(--b4);color:var(--t3);border-radius:5px;padding:5px 12px;font-size:.78rem;cursor:pointer;transition:border-color .15s,color .15s,background .15s}
        .d-btn:hover{border-color:var(--b5);color:var(--t0);background:var(--s3)}
        .d-btn.d-sel{border-color:var(--ac);color:var(--ac);background:var(--acb)}
        .d-btn.d-full{border-color:#c03030;color:#ff8080;background:#2a1010}
        .d-btn.d-full:hover{border-color:#e04040;color:#ffaaaa}
        .d-btn.d-full.d-sel{border-color:#ff8080;color:#ff8080;background:#3a1010}
        html.lm .d-btn.d-full{border-color:#cc3030;color:#8b0000;background:#fce8e8}
        html.lm .d-btn.d-full:hover{border-color:#aa2020;color:#660000}
        html.lm .d-btn.d-full.d-sel{border-color:#cc3030;color:#8b0000;background:#fcd4d4}
        .d-ui{color:var(--t6);font-size:.85rem;text-decoration:none;padding:0 2px;line-height:1}
        .d-ui:hover{color:var(--ac)}
        .t-info{background:var(--s4);border:1px solid var(--b4);color:var(--t3);border-radius:4px;padding:2px 8px;font-size:.72rem;cursor:pointer;transition:border-color .15s,color .15s}
        .t-info:hover{border-color:var(--b5);color:var(--t0)}
        .t-info-full{background:#2a1010;border-color:#883030;color:#ff9090}
        .t-info-full:hover{border-color:#cc4444;color:#ffbbbb}
        html.lm .t-info-full{background:#fce8e8;border-color:#cc3030;color:#8b0000}
        html.lm .t-info-full:hover{border-color:#aa2020;color:#660000}
        /* ── Theme switcher (3-dot segmented control) ── */
        .t-ctrl-btn{background:var(--s4);border:1px solid var(--b4);color:var(--t3);border-radius:5px;padding:5px 10px;font-size:.78rem;cursor:pointer;transition:border-color .15s,color .15s,background .15s;white-space:nowrap}
        .t-ctrl-btn:hover{border-color:var(--b5);color:var(--t0);background:var(--s3)}
        html.lm .t-ctrl-btn{background:#f0f0f0;border-color:#ccc;color:#444}
        html.lm .t-ctrl-btn:hover{background:#e0e0e0;border-color:#aaa;color:#111}
        .genre-sel{background:var(--s4);border:1px solid var(--b4);color:var(--t2);border-radius:5px;padding:4px 8px;font-size:.78rem;cursor:pointer}
        html.lm .genre-sel{background:#f0f0f0;border-color:#ccc;color:#333}
        #theme-sw{display:flex;background:var(--s4);border:1px solid var(--b4);border-radius:6px;overflow:hidden;flex-shrink:0;margin-right:8px}
        #theme-sw button{background:none;border:none;border-right:1px solid var(--b4);padding:5px 9px;cursor:pointer;color:var(--t4);font-size:.8rem;line-height:1;transition:background .12s,color .12s}
        #theme-sw button:last-child{border-right:none}
        #theme-sw button:hover{background:var(--s3);color:var(--t0)}
        #theme-sw button.th-sel{background:var(--ac);color:#fff}
        /* ── Summary panel ── */
        .s-syn{overflow:hidden;display:-webkit-box;-webkit-line-clamp:1;-webkit-box-orient:vertical}
        #sum{border-color:var(--b1)!important}
        #sum-ph{background:var(--s1)!important;color:var(--t5)!important}
        #sum-title{color:var(--t0)!important}
        #sum-ep,#sum-syn{color:var(--t0)!important}
        #sum-date{color:var(--t3)!important}
        #sum-ct{color:var(--t2)!important}
        #sum-edit{background:var(--s4)!important;color:var(--t2)!important;border-color:var(--b4)!important}
        #sum-del{background:var(--s4)!important;color:var(--t2)!important;border-color:var(--b4)!important}
        #sum-del.danger{background:#6a1010!important;color:#ffaaaa!important;border-color:#883030!important}
        html.lm #sum-del.danger{background:#fcd4d4!important;color:#8b0000!important;border-color:#cc3030!important}
        #sum button:not(#sum-btn):not(#sum-del){color:var(--t6)!important}
        html.lm #sum-genre{color:rgba(0,0,0,.65)!important;background:rgba(0,0,0,.1)!important}
        #sum-grad{background:linear-gradient(to right,rgba(0,0,0,.35),rgba(0,0,0,.05));padding:8px 10px!important;gap:1px!important}
        html.lm #sum-grad{background:linear-gradient(to right,rgba(0,0,0,.04),transparent)}
        #sum-poster{width:72px!important;min-width:72px!important;object-fit:contain!important;background:var(--bg)}
        #sum-actions{margin-top:3px!important}
        @media(max-width:600px){
          #sum-date{display:none!important}
          #sum-syn{display:none!important}
          #sum-grad{padding:6px 8px!important}
        }
        @media(min-width:601px)and(max-width:960px){
          #sum-poster{width:56px!important;min-width:56px!important}
          #sum-syn{display:none!important}
        }
        /* ── Tuner popover ── */
        #t-pop-c{background:var(--s3)!important;border-color:var(--b5)!important}
        #t-pop-hdr{color:var(--t0)!important}
        #t-pop-c button{color:var(--t6)!important}
        #t-pop-status{color:var(--ac)!important;border-color:var(--b0)!important}
        /* ── Record modal ── */
        #rec-modal>div{background:var(--s2)!important;border-color:var(--b2)!important}
        #rm-title{color:var(--t0)!important}
        #rm-ch{color:var(--t4)!important}
        #rm-sid{background:var(--bg)!important;color:var(--t4)!important}
        #rm-sid-val{color:var(--t3)!important}
        #rec-modal button:first-child{border-color:var(--b4)!important;color:var(--t3)!important;background:transparent!important}
        .rm-opt-l{font-size:.82rem;font-weight:500;color:var(--t1)}
        .rm-opt-d{font-size:.7rem;color:var(--t4);margin-top:1px}
        html.lm #rm-tuner{color:#7a3c00;background:#fff8e8;border-color:#d09020}
        /* ── Guide grid ── */
        .gw{overflow:auto;max-height:60vh;border:1px solid var(--b1);border-radius:8px;margin-bottom:20px;background:var(--bg)}
        .gi{min-width:\(guideMinWidth)px}
        #status-btn:hover{color:var(--t0)!important}
        .g-hdr{display:flex;position:sticky;top:0;z-index:10;background:var(--s2);border-bottom:1px solid var(--b2)}
        .g-hdr-ch{width:105px;min-width:105px;position:sticky;left:0;z-index:11;background:var(--s2);border-right:1px solid var(--b2);padding:6px 8px;font-size:.65rem;color:var(--t4);text-transform:uppercase;letter-spacing:.07em}
        .g-hdr-tl{flex:1;position:relative;height:32px}
        .g-tick{position:absolute;top:50%;transform:translate(-50%,-50%);font-size:.68rem;color:var(--t4);white-space:nowrap;pointer-events:none}
        .g-now-tick{position:absolute;top:0;bottom:0;width:2px;background:rgba(255,90,90,.65);pointer-events:none}
        .g-row{display:flex;border-bottom:1px solid var(--b0)}
        .g-row:last-child{border-bottom:none}
        .g-ch{width:105px;min-width:105px;display:flex;align-items:center;gap:4px;padding:4px 6px;position:sticky;left:0;z-index:2;background:var(--s1);border-right:1px solid var(--b1)}
        .g-logo{width:24px;height:24px;object-fit:contain;flex-shrink:0}
        .g-logo-ph{width:24px;height:24px;border-radius:3px;background:var(--s4);display:flex;align-items:center;justify-content:center;font-size:.75rem;color:var(--t4);flex-shrink:0}
        .g-cl{overflow:hidden;flex:1}
        .g-cn{display:block;font-size:.68rem;color:var(--t3);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-weight:500}
        .g-cname{display:block;font-size:.72rem;color:var(--t1);font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
        .g-sig{flex-shrink:0;align-self:center}
        /* 30-min gridlines */
        .g-tl{flex:1;position:relative;min-height:54px;background:repeating-linear-gradient(90deg,transparent,transparent calc(8.3333% - 1px),var(--b0) calc(8.3333% - 1px),var(--b0) 8.3333%)}
        .g-now-bar{position:absolute;top:0;bottom:0;width:2px;background:rgba(255,90,90,.75);z-index:1;pointer-events:none}
        .g-gap{position:absolute;top:0;bottom:0;background:var(--bg);pointer-events:none}
        .g-prog{position:absolute;top:4px;bottom:4px;border-radius:5px;overflow:hidden;background:var(--pg);border:1px solid var(--pgb);min-width:3px;cursor:pointer}
        .g-prog:hover{filter:brightness(1.1);border-color:var(--t5);z-index:3}
        .g-prog.g-sel{border-color:var(--t0)!important;box-shadow:0 0 0 1px rgba(128,128,128,.5);z-index:4}
        .gg-drama    {background:hsl(216,48%,36%)}
        .gg-comedy   {background:hsl(47,48%,36%)}
        .gg-news     {background:hsl(342,43%,36%)}
        .gg-sports   {background:hsl(119,48%,33%)}
        .gg-reality  {background:hsl(25,48%,36%)}
        .gg-movie    {background:hsl(270,58%,38%)}
        .gg-talk     {background:hsl(173,43%,34%)}
        .gg-children {background:hsl(315,43%,35%)}
        html.lm .gg-drama    {background:hsl(216,52%,82%)}
        html.lm .gg-comedy   {background:hsl(47,58%,82%)}
        html.lm .gg-news     {background:hsl(342,52%,82%)}
        html.lm .gg-sports   {background:hsl(119,57%,80%)}
        html.lm .gg-reality  {background:hsl(25,58%,82%)}
        html.lm .gg-movie    {background:hsl(270,62%,84%)}
        html.lm .gg-talk     {background:hsl(173,52%,80%)}
        html.lm .gg-children {background:hsl(315,55%,85%)}
        .g-prog-now.gg-drama    {background:hsl(216,52%,44%);border-color:hsl(216,57%,62%)}
        .g-prog-now.gg-comedy   {background:hsl(47,52%,44%);border-color:hsl(47,57%,62%)}
        .g-prog-now.gg-news     {background:hsl(342,47%,44%);border-color:hsl(342,52%,62%)}
        .g-prog-now.gg-sports   {background:hsl(119,52%,41%);border-color:hsl(119,57%,58%)}
        .g-prog-now.gg-reality  {background:hsl(25,52%,44%);border-color:hsl(25,57%,62%)}
        .g-prog-now.gg-movie    {background:hsl(270,62%,46%);border-color:hsl(270,68%,64%)}
        .g-prog-now.gg-talk     {background:hsl(173,47%,42%);border-color:hsl(173,52%,60%)}
        .g-prog-now.gg-children {background:hsl(315,47%,43%);border-color:hsl(315,52%,61%)}
        html.lm .g-prog-now.gg-drama    {background:hsl(216,57%,90%);border-color:hsl(216,52%,64%)}
        html.lm .g-prog-now.gg-comedy   {background:hsl(47,65%,90%);border-color:hsl(47,57%,64%)}
        html.lm .g-prog-now.gg-news     {background:hsl(342,57%,90%);border-color:hsl(342,52%,64%)}
        html.lm .g-prog-now.gg-sports   {background:hsl(119,62%,89%);border-color:hsl(119,57%,62%)}
        html.lm .g-prog-now.gg-reality  {background:hsl(25,67%,90%);border-color:hsl(25,57%,64%)}
        html.lm .g-prog-now.gg-movie    {background:hsl(270,68%,92%);border-color:hsl(270,58%,66%)}
        html.lm .g-prog-now.gg-talk     {background:hsl(173,57%,89%);border-color:hsl(173,52%,62%)}
        html.lm .g-prog-now.gg-children {background:hsl(315,62%,90%);border-color:hsl(315,57%,64%)}
        .g-prog-now  {background:#424242;border-color:#787878}
        .g-prog-rec  {background:#3c1818;border-color:#c03030}
        .g-prog-sched{background:#1a1a40;border-color:#4848c8}
        html.lm .g-prog-now  {background:#d8d8d8;border-color:#909090}
        html.lm .g-prog-rec  {background:#fcd4d4;border-color:#cc3030}
        html.lm .g-prog-sched{background:#d4d4f8;border-color:#5050cc}
        .g-pi{padding:3px 6px;height:100%;display:flex;flex-direction:column;justify-content:center;gap:1px;overflow:hidden}
        .g-ti{font-size:.78rem;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;color:var(--t0);line-height:1.25}
        .g-sub{font-size:.65rem;color:var(--t3);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;line-height:1.25}
        .g-flag,.g-flag-rec{position:absolute;top:0;right:0;width:0;height:0;border-style:solid;border-width:0 18px 18px 0;pointer-events:none}
        .g-flag{border-color:transparent #ffd700 transparent transparent}
        .g-flag-rec{border-color:transparent #ff6060 transparent transparent}
        /* ── Starburst bonus badge ── */
        @keyframes sbPop{0%{transform:scale(0) rotate(-240deg);opacity:0}55%{transform:scale(1.28) rotate(12deg);opacity:1}75%{transform:scale(.84) rotate(-3deg)}90%{transform:scale(1.04)}100%{transform:scale(1) rotate(0deg)}}
        @keyframes sbPulse{0%,100%{transform:scale(1) rotate(0deg)}50%{transform:scale(1.07) rotate(5deg)}}
        .sb-web{display:inline-flex;align-items:center;justify-content:center;width:28px;height:28px;flex-shrink:0;clip-path:polygon(50% 0%,57.1% 23.4%,75% 6.7%,69.4% 30.6%,93.3% 25%,76.6% 42.9%,100% 50%,76.6% 57.1%,93.3% 75%,69.4% 69.4%,75% 93.3%,57.1% 76.6%,50% 100%,42.9% 76.6%,25% 93.3%,30.6% 69.4%,6.7% 75%,23.4% 57.1%,0% 50%,23.4% 42.9%,6.7% 25%,30.6% 30.6%,25% 6.7%,42.9% 23.4%);background:#e86e00;font-size:.5rem;font-weight:800;color:#fff;line-height:1;text-align:center}
        .sb-web-lg{position:absolute;top:8px;right:10px;width:110px;height:110px;font-size:.72rem;pointer-events:none;z-index:2}
        .sb-anim{animation:sbPop .55s cubic-bezier(.22,1,.36,1) both,sbPulse 2.4s ease-in-out .6s infinite}
        /* ── Schedule popover ── */
        #sched-pop-c{background:var(--s3)!important;border-color:var(--b5)!important}
        .sp-sec{padding:10px 14px}
        .sp-hdr{font-size:.68rem;font-weight:700;color:var(--t4);text-transform:uppercase;letter-spacing:.07em;margin-bottom:6px}
        .sp-row{padding:5px 0;border-bottom:1px solid var(--b0);cursor:pointer}
        .sp-row:last-child{border-bottom:none}
        .sp-row:hover .sp-t{color:var(--ac)}
        .sp-t{font-size:.82rem;color:var(--t0);font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;transition:color .12s}
        .sp-ch{font-size:.7rem;color:var(--t4);margin-top:1px}
        .sp-rec{color:#ff8080}
        html.lm .sp-rec{color:#cc2020}
        .sp-div{height:1px;background:var(--b1);margin:2px 0}
        .sp-empty{font-size:.8rem;color:var(--t5);padding:12px 14px;text-align:center}
        /* ── Record / Edit modals ── */
        #rec-modal>div,#edit-modal>div{background:var(--s2)!important;border-color:var(--b2)!important}
        #em-rec-warn{color:#ff9090!important;background:#3c1818!important;border-color:#883030!important}
        html.lm #em-rec-warn{color:#8b0000!important;background:#fce8e8!important;border-color:#cc3030!important}
        .rm-lbl{display:flex;align-items:flex-start;gap:10px;cursor:pointer;padding:9px 11px;border-radius:7px;border:1px solid var(--b3);transition:border-color .15s}
        .rm-lbl:hover{border-color:var(--t4)}
        .rm-lbl input{margin-top:3px;flex-shrink:0;accent-color:#c0392b}
        .em-row{display:flex;flex-direction:column;gap:3px;margin-bottom:8px}
        .em-lbl{font-size:.68rem;color:var(--t4);font-weight:600;text-transform:uppercase;letter-spacing:.06em}
        .em-input{background:var(--bg);border:1px solid var(--b3);border-radius:5px;padding:5px 8px;font-size:.82rem;color:var(--t0);width:100%;outline:none;font-family:inherit}
        .em-input:focus{border-color:var(--ac)}
        select.em-input{cursor:pointer}
        .em-input-sm{width:84px}
        .em-fail{font-size:.75rem;color:#ff9090;padding:5px 8px;background:#3c1818;border:1px solid #883030;border-radius:5px;margin-bottom:8px;display:flex;align-items:center;justify-content:space-between;gap:8px}
        html.lm .em-fail{color:#8b0000;background:#fce8e8;border-color:#cc3030}
        .day-btn{background:var(--s4);border:1px solid var(--b3);color:var(--t3);border-radius:4px;padding:4px 7px;font-size:.72rem;cursor:pointer;transition:background .12s,border-color .12s,color .12s}
        .day-btn.sel{background:var(--ac);border-color:var(--ac);color:#fff}
        .em-days{display:flex;gap:4px;flex-wrap:wrap}
        .em-check{display:flex;align-items:center;gap:7px;font-size:.82rem;color:var(--t1);cursor:pointer;margin-bottom:8px}
        .em-check input{accent-color:var(--ac)}
        .em-sid{font-size:.72rem;color:var(--t4);font-family:monospace;word-break:break-all;margin-top:2px}
        </style>
        </head>
        <body>
        <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:14px">
          <div>\(headerHTML)</div>
          <div style="display:flex;align-items:center;gap:6px">
            <button class="t-ctrl-btn" onclick="scrollToNow()" title="Jump to current time">⊙ Now</button>
            <button class="t-ctrl-btn" onclick="location.reload()" title="Refresh guide">↺ Refresh</button>
            <div id="theme-sw">
              <button data-m="dark"  onclick="setTheme('dark')"  title="Dark">◗</button>
              <button data-m="auto"  onclick="setTheme('auto')"  title="Auto (system)">◐</button>
              <button data-m="light" onclick="setTheme('light')" title="Light">◖</button>
            </div>
          </div>
        </div>
        \(deviceBarHTML)
        <div id="genre-bar" style="display:none;margin-bottom:10px">
          <select id="genre-sel" onchange="filterGenre(this.value)" class="genre-sel"><option value="">All genres</option></select>
        </div>
        <div id="t-pop" onclick="if(event.target===this)closeTunerPop()" style="display:none;position:fixed;inset:0;z-index:200">
          <div id="t-pop-c" style="position:absolute;background:#1e1e1e;border:1px solid #484848;border-radius:10px;padding:14px 16px;min-width:240px;max-width:340px;box-shadow:0 8px 32px rgba(0,0,0,.75)">
            <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:10px">
              <span id="t-pop-hdr" style="font-size:.82rem;font-weight:600;color:#e0e0e0"></span>
              <button onclick="closeTunerPop()" style="background:none;border:none;color:#666;font-size:.9rem;cursor:pointer;padding:0 0 0 12px;line-height:1">✕</button>
            </div>
            <div id="t-pop-list" style="display:flex;flex-direction:column;gap:1px"></div>
            <a id="t-pop-status" href="#" target="_blank" style="display:none;margin-top:10px;font-size:.72rem;color:#5aacff;text-decoration:none;border-top:1px solid #2e2e2e;padding-top:8px">status.json ↗</a>
          </div>
        </div>
        <div id="sum" style="border:1px solid #333;border-radius:8px;margin-bottom:16px;display:flex;align-items:stretch;overflow:hidden;min-height:44px">
          <div id="sum-ph" style="flex:1;display:flex;align-items:center;padding:12px 16px;background:#1a1a1a">\(sumPhHTML)</div>
          <div id="sum-c" style="display:none;flex:1;flex-direction:row;position:relative">
            <img id="sum-poster" src="" alt="" style="width:72px;min-width:72px;object-fit:contain;display:none" onerror="this.style.display='none'">
            <div id="sum-grad" style="flex:1;padding:8px 10px;display:flex;flex-direction:column;gap:1px;overflow:hidden">
              <div id="sum-title" style="font-size:.92rem;font-weight:700;color:#fff;white-space:nowrap;overflow:hidden;text-overflow:ellipsis"></div>
              <div id="sum-genre" style="display:none;font-size:.6rem;font-weight:700;color:rgba(255,255,255,.85);background:rgba(255,255,255,.18);border-radius:3px;padding:2px 6px;align-self:flex-start;letter-spacing:.06em"></div>
              <div id="sum-ep"   style="display:none;font-size:.78rem;color:#ddd;white-space:nowrap;overflow:hidden;text-overflow:ellipsis"></div>
              <div id="sum-date" style="display:none;font-size:.68rem;color:rgba(255,255,255,.7)"></div>
              <div id="sum-syn"  class="s-syn" style="display:none;font-size:.76rem;color:#e0e0e0;line-height:1.35"></div>
              <div id="sum-actions" style="display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-top:3px">
                <span id="sum-note" style="display:none;font-size:.75rem;font-style:italic;color:rgba(255,255,255,.75)"></span>
                <button id="sum-btn" onclick="doRecord()" style="display:none;font-size:.75rem;padding:4px 12px;border-radius:5px;border:none;cursor:pointer;font-weight:600;background:#c0392b;color:#fff">Record</button>
                <button id="sum-edit" onclick="doEditFromGuide()" style="display:none;font-size:.75rem;padding:4px 12px;border-radius:5px;cursor:pointer;font-weight:600">Edit</button>
                <button id="sum-del" onclick="doDelete()" style="display:none;font-size:.75rem;padding:4px 12px;border-radius:5px;cursor:pointer;font-weight:600">Delete</button>
              </div>
              <div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-top:3px">
                <img id="sum-logo" src="" alt="" style="width:24px;height:24px;object-fit:contain;display:none" onerror="this.style.display='none'">
                <span id="sum-ct" style="font-size:.68rem;color:rgba(255,255,255,.8)"></span>
              </div>
            </div>
            <span id="sum-bonus-star" class="sb-web sb-web-lg" style="display:none"></span>
            <button onclick="closeSummary()" style="background:none;border:none;color:#666;font-size:.9rem;cursor:pointer;padding:6px 10px;align-self:flex-start;flex-shrink:0;margin-top:4px" title="Close">✕</button>
          </div>
        </div>
        <div id="rec-modal" onclick="if(event.target===this)cancelRecord()" style="display:none;position:fixed;inset:0;background:rgba(0,0,0,.8);z-index:100;align-items:center;justify-content:center;padding:20px">
          <div style="background:#1c1c1e;border:1px solid #383838;border-radius:12px;padding:20px 22px;width:400px;max-width:calc(100vw - 32px);max-height:calc(100vh - 40px);overflow-y:auto;box-shadow:0 20px 60px rgba(0,0,0,.6);position:relative">
            <span id="rm-bonus-star" class="sb-web sb-web-lg" style="display:none"></span>
            <div style="font-weight:700;font-size:.88rem;color:var(--t0);margin-bottom:14px;padding-bottom:10px;border-bottom:1px solid var(--b2)">Record Show</div>
            <div class="em-row">
              <div class="em-lbl">Show</div>
              <div id="rm-title" style="font-size:.88rem;color:var(--t0);font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis"></div>
              <div id="rm-ch" style="font-size:.72rem;color:var(--t4);margin-top:1px"></div>
            </div>
            <div class="em-row"><div class="em-lbl">Type</div><div id="rm-opts" style="display:flex;flex-direction:column;gap:5px;margin-top:2px"></div></div>
            <div id="rm-sid" class="em-row" style="display:none"><div class="em-lbl">SeriesID</div><div id="rm-sid-val" class="em-sid"></div></div>
            <div id="rm-days-row" class="em-row" style="display:none"><div class="em-lbl">Days</div><div class="em-days" id="rm-days"></div></div>
            <div class="em-row"><div class="em-lbl">Transcode</div><select id="rm-transcode" class="em-input"><option value="none">None (copy stream)</option><option value="heavy">Heavy (H.264 CRF 18)</option><option value="mobile">Mobile (480p H.264)</option><option value="internet720">Internet 720 (720p H.264)</option></select></div>
            <div id="rm-bonus-row" style="margin-bottom:8px;display:flex;align-items:center;gap:8px"><label class="em-check"><input type="checkbox" id="rm-bonus" onchange="toggleRmBonusStar()"> Bonus Time (extend recording past guide end)</label></div>
            <div id="rm-tuner" style="display:none;font-size:.74rem;color:#ffcc66;background:#2a1e00;border:1px solid #7a5500;border-radius:6px;padding:7px 10px;margin-bottom:10px">⚠ All tuners are currently in use. This show will be queued and recorded as soon as a tuner is free.</div>
            <div style="display:flex;justify-content:flex-end;gap:8px;margin-top:12px;padding-top:10px;border-top:1px solid var(--b2)">
              <button onclick="cancelRecord()" style="font-size:.78rem;padding:6px 16px;border-radius:6px;border:1px solid #444;background:transparent;color:#aaa;cursor:pointer">Cancel</button>
              <button onclick="confirmRecord()" style="font-size:.78rem;padding:6px 16px;border-radius:6px;border:none;background:#c0392b;color:#fff;font-weight:600;cursor:pointer">Schedule</button>
            </div>
          </div>
        </div>
        <div id="edit-modal" onclick="if(event.target===this)closeEditShow()" style="display:none;position:fixed;inset:0;background:rgba(0,0,0,.8);z-index:201;align-items:center;justify-content:center;padding:20px">
          <div style="background:#1c1c1e;border:1px solid #383838;border-radius:12px;padding:20px 22px;width:400px;max-width:calc(100vw - 32px);max-height:calc(100vh - 40px);overflow-y:auto;box-shadow:0 20px 60px rgba(0,0,0,.6);position:relative">
            <span id="em-bonus-star" class="sb-web sb-web-lg" style="display:none"></span>
            <div style="font-weight:700;font-size:.88rem;color:var(--t0);margin-bottom:14px;padding-bottom:10px;border-bottom:1px solid var(--b2)">Edit Show</div>
            <div class="em-row"><div class="em-lbl">Title</div><input id="em-title-in" class="em-input" type="text" placeholder="Show title"></div>
            <div style="display:flex;gap:8px;margin-bottom:8px">
              <div class="em-row" style="margin-bottom:0;flex:0 0 auto"><div class="em-lbl">Channel</div><input id="em-ch-in" class="em-input em-input-sm" type="text" placeholder="e.g. 5.4"></div>
              <div class="em-row" style="margin-bottom:0;flex:0 0 auto"><div class="em-lbl">Length (min)</div><input id="em-len-in" class="em-input em-input-sm" type="number" min="1" max="1440" placeholder="60"></div>
            </div>
            <div class="em-row"><div class="em-lbl">Type</div><div id="em-type-opts" style="display:flex;flex-direction:column;gap:5px;margin-top:2px"></div></div>
            <div id="em-days-row" class="em-row" style="display:none"><div class="em-lbl">Days</div><div class="em-days" id="em-days"></div></div>
            <div id="em-bonus-row" style="margin-bottom:8px;display:flex;align-items:center;gap:8px"><label class="em-check"><input type="checkbox" id="em-bonus" onchange="toggleBonusStar()"> Bonus Time (extend recording past guide end)</label></div>
            <div class="em-row"><div class="em-lbl">Transcode</div><select id="em-transcode" class="em-input"><option value="none">None (copy stream)</option><option value="heavy">Heavy (H.264 CRF 18)</option><option value="mobile">Mobile (480p H.264)</option><option value="internet720">Internet 720 (720p H.264)</option></select></div>
            <div id="em-sid-row" style="display:none;margin-bottom:8px"><div class="em-lbl">SeriesID</div><div id="em-sid" class="em-sid"></div></div>
            <div id="em-fail-row" style="display:none" class="em-fail"><span id="em-fail-txt"></span><button id="em-reset" onclick="doEditReset()" style="font-size:.72rem;padding:3px 8px;border-radius:4px;border:1px solid currentColor;background:transparent;color:inherit;cursor:pointer;flex-shrink:0;white-space:nowrap">Reset</button></div>
            <div id="em-rec-warn" style="display:none;font-size:.74rem;color:#ff9090;background:#3c1818;border:1px solid #883030;border-radius:6px;padding:7px 10px;margin-bottom:10px">● Recording now — delete will stop the active recording.</div>
            <div style="display:flex;justify-content:space-between;align-items:center;gap:8px;margin-top:12px;padding-top:10px;border-top:1px solid var(--b2)">
              <button id="em-del" onclick="doEditDelete()" style="font-size:.78rem;padding:6px 14px;border-radius:6px;border:1px solid #883030;background:#3c1010;color:#ff9090;font-weight:600;cursor:pointer">Delete</button>
              <div style="display:flex;gap:8px">
                <button id="em-pause" onclick="doEditPause()" style="display:none;font-size:.78rem;padding:6px 14px;border-radius:6px;border:1px solid #444;background:transparent;color:#aaa;cursor:pointer"></button>
                <button onclick="closeEditShow()" style="font-size:.78rem;padding:6px 16px;border-radius:6px;border:1px solid #444;background:transparent;color:#aaa;cursor:pointer">Cancel</button>
                <button id="em-save" onclick="confirmEdit()" style="font-size:.78rem;padding:6px 16px;border-radius:6px;border:none;background:#1a5abf;color:#fff;font-weight:600;cursor:pointer">Save</button>
              </div>
            </div>
          </div>
        </div>
        <div id="sched-pop" onclick="if(event.target===this)closeSchedPop()" style="display:none;position:fixed;inset:0;z-index:150">
          <div id="sched-pop-c" style="position:absolute;min-width:260px;max-width:340px;max-height:70vh;overflow-y:auto;background:#1e1e1e;border:1px solid #484848;border-radius:10px;box-shadow:0 8px 32px rgba(0,0,0,.75)">
            <div style="display:flex;justify-content:space-between;align-items:center;padding:10px 14px;border-bottom:1px solid var(--b1);position:sticky;top:0;background:inherit">
              <span style="font-size:.82rem;font-weight:600;color:var(--t0)">Schedule</span>
              <button onclick="closeSchedPop()" style="background:none;border:none;color:var(--t5);font-size:.9rem;cursor:pointer;padding:0 0 0 12px;line-height:1">✕</button>
            </div>
            <div id="sched-pop-body">\(schedPopHTML)</div>
          </div>
        </div>
        <div class="gw"><div class="gi">
        <div class="g-hdr"><div class="g-hdr-ch">Channel</div><div class="g-hdr-tl">\(ticksHTML)</div></div>
        \(rowsHTML)
        </div></div>
        <script>
        \(tunerJS)
        \(recsByDevJS)
        var _d='',_n='',_s=0,_e=0,_ser='',_genre='',_title='',_poster='',_logo='',_chname='';
        function hej(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');}
        // Theme: .lm class on <html> = light mode active
        var _mq=window.matchMedia('(prefers-color-scheme:light)');
        var _themeMode='dark';
        function applyLM(on){document.documentElement.classList.toggle('lm',on);document.querySelectorAll('#theme-sw button').forEach(function(b){b.classList.toggle('th-sel',b.dataset.m===_themeMode);});}
        function refreshSumTheme(){var sel=document.querySelector('.g-prog.g-sel');if(sel)showInfo(sel);}
        function setTheme(m){_themeMode=m;try{localStorage.setItem('theme',m);}catch(e){}applyLM(m==='light'||(m==='auto'&&_mq.matches));refreshSumTheme();}
        _mq.addEventListener('change',function(e){if(_themeMode==='auto'){applyLM(e.matches);refreshSumTheme();}});
        (function(){try{_themeMode=localStorage.getItem('theme')||'dark';}catch(e){}applyLM(_themeMode==='light'||(_themeMode==='auto'&&_mq.matches));})();
        function isLM(){return document.documentElement.classList.contains('lm');}
        var _gcDk={drama:'hsl(216,48%,35%)',comedy:'hsl(47,48%,35%)',news:'hsl(342,43%,35%)',sports:'hsl(119,48%,31%)',reality:'hsl(25,48%,35%)',movie:'hsl(270,58%,38%)',talk:'hsl(173,43%,34%)',children:'hsl(315,43%,35%)'};
        var _gcLk={drama:'hsl(216,55%,88%)',comedy:'hsl(47,65%,88%)',news:'hsl(342,55%,88%)',sports:'hsl(119,60%,87%)',reality:'hsl(25,65%,88%)',movie:'hsl(270,62%,90%)',talk:'hsl(173,55%,87%)',children:'hsl(315,60%,88%)'};
        function gc(g){var m=isLM()?_gcLk:_gcDk;return m[(g||'').toLowerCase()]||(isLM()?'#d8d8d8':'#424242');}
        var _bonusMins=\(state.config.Sports_padding_minutes);
        function triggerSb(id){var el=document.getElementById(id);if(!el)return;el.classList.remove('sb-anim');void el.offsetWidth;el.classList.add('sb-anim');}
        function toggleBonusStar(){var chk=document.getElementById('em-bonus');var star=document.getElementById('em-bonus-star');if(chk.checked){star.textContent='+'+_bonusMins+'m';star.style.display='inline-flex';triggerSb('em-bonus-star');}else{star.style.display='none';star.classList.remove('sb-anim');}}
        function ft(d){var h=d.getHours(),m=d.getMinutes(),ap=h>=12?'PM':'AM';h=h%12||12;return h+(m?':'+(m<10?'0':'')+m:'')+' '+ap;}
        function so(id,v){var e=document.getElementById(id);if(v){e.textContent=v;e.style.display='block';}else{e.style.display='none';}}
        function devFull(devId){var t=tuners[devId];return t&&t.t>0&&t.a>=t.t;}
        function showInfo(el){
          var d=el.dataset;
          _d=d.device;_n=d.num;_s=+d.start;_e=+d.end;_ser=d.series||'';_genre=d.genre||'';_title=d.title||'';_poster=d.poster||'';_logo=d.logo||'';_chname=d.chname||'';
          document.getElementById('sum-ph').style.display='none';
          var sc=document.getElementById('sum-c');sc.style.display='flex';sc.style.background=gc(d.genre);
          var pi=document.getElementById('sum-poster');
          if(d.poster){pi.src=d.poster;pi.style.display='block';}else{pi.style.display='none';}
          var li=document.getElementById('sum-logo');
          if(d.logo){li.src=d.logo;li.style.display='inline';}else{li.style.display='none';}
          document.getElementById('sum-title').textContent=d.title||'';
          var gi=document.getElementById('sum-genre'),g=d.genre||'';
          if(g&&g.toLowerCase()!=='series'){gi.textContent=g.toUpperCase();gi.style.display='inline-block';}else{gi.style.display='none';}
          so('sum-ep',d.ep||'');
          so('sum-date',d.date?'Orig. '+d.date:'');
          var sy=document.getElementById('sum-syn');
          if(d.syn){sy.textContent=d.syn;sy.style.display='block';}else{sy.style.display='none';}
          document.getElementById('sum-ct').textContent='Ch '+d.num+' · '+d.chname+' · '+ft(new Date(+d.start*1000))+' – '+ft(new Date(+d.end*1000));
          var btn=document.getElementById('sum-btn');
          var del=document.getElementById('sum-del');
          var note=document.getElementById('sum-note');
          // Reset all action elements first
          var edit=document.getElementById('sum-edit');
          btn.style.display='none';edit.style.display='none';del.style.display='none';note.style.display='none';
          del.disabled=false;del.textContent='Delete';del.classList.remove('danger');del.style.background='';del.style.color='';
          var bstar=document.getElementById('sum-bonus-star');
          bstar.style.display='none';bstar.classList.remove('sb-anim');
          if(+d.recording){
            note.textContent='● Recording now';note.style.color=isLM()?'#cc2020':'#ff8080';note.style.display='inline';
            del.textContent='Stop & Delete';del.classList.add('danger');del.style.display='inline-block';
          } else if(+d.managed){
            note.textContent='★ Scheduled';note.style.color='var(--t2)';note.style.display='inline';
            del.textContent='Remove';del.style.display='inline-block';
            if(d.showId)edit.style.display='inline-block';
            if(d.showBonus==='1'){bstar.textContent='+'+_bonusMins+'m';bstar.style.display='inline-flex';triggerSb('sum-bonus-star');}
          } else {
            var nowTs=Math.floor(Date.now()/1000);
            var isLive=(_s<=nowTs&&_e>nowTs);
            if(isLive&&devFull(_d)){
              btn.textContent='⚠ Record (tuner full)';btn.style.background=isLM()?'#e08000':'#7a4a00';btn.style.color=isLM()?'#fff':'#ffcc66';
              btn.title='All tuners busy — show will be queued when a tuner is free';
            } else {
              btn.textContent='Record';btn.style.background='#c0392b';btn.style.color='#fff';btn.title='';
            }
            btn.style.display='inline-block';btn.disabled=false;
          }
          document.querySelectorAll('.g-prog.g-sel').forEach(function(b){b.classList.remove('g-sel');});
          el.classList.add('g-sel');
        }
        function closeSummary(){
          document.getElementById('sum-c').style.display='none';
          document.getElementById('sum-ph').style.display='flex';
          document.querySelectorAll('.g-prog.g-sel').forEach(function(b){b.classList.remove('g-sel');});
          var bstar=document.getElementById('sum-bonus-star');bstar.style.display='none';bstar.classList.remove('sb-anim');
        }
        var recOpts=[
          {v:'single',        l:'Single episode',       d:'Record this airing only',               s:false},
          {v:'dateTime',      l:'Weekly repeat',         d:'Record at this time each week',         s:false},
          {v:'seriesChannel', l:'Series — this channel', d:'Record new episodes on this channel',   s:true},
          {v:'seriesAll',     l:'Series — any channel',  d:'Record new episodes on any channel',    s:true}
        ];
        function doRecord(){
          // In-app WKWebView (AddShowView wizard): send entry data to Swift instead of showing the record modal.
          // Swift intercepts this, calls applyWebGuideEntry(), and advances to the Details step.
          if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.record){
            window.webkit.messageHandlers.record.postMessage({deviceId:_d,guideNumber:_n,startTime:_s,endTime:_e,title:_title,seriesId:_ser,genre:_genre,imageURL:_poster});
            return;
          }
          document.getElementById('rm-title').textContent=document.getElementById('sum-title').textContent||'';
          document.getElementById('rm-ch').textContent=document.getElementById('sum-ct').textContent||'';
          var opts=document.getElementById('rm-opts');opts.innerHTML='';var first=true;
          recOpts.forEach(function(o){
            var lbl=document.createElement('label');lbl.className='rm-lbl';
            var inp=document.createElement('input');inp.type='radio';inp.name='rm-type';inp.value=o.v;
            if(first){inp.checked=true;first=false;}
            var info=document.createElement('div');
            info.innerHTML='<div class="rm-opt-l">'+o.l+'</div><div class="rm-opt-d">'+o.d+'</div>';
            lbl.appendChild(inp);lbl.appendChild(info);opts.appendChild(lbl);
          });
          document.getElementById('rm-sid').style.display='none';
          // Build day buttons — pre-check the day-of-week matching the guide entry
          var entryDow=new Date(_s*1000).getDay();
          var rmDaysEl=document.getElementById('rm-days');rmDaysEl.innerHTML='';
          _dayNames.forEach(function(day,i){
            var btn=document.createElement('button');
            btn.type='button';btn.className='day-btn'+(i===entryDow?' sel':'');
            btn.textContent=_dayShort[i];btn.dataset.day=day;
            btn.onclick=function(){
              if(this.classList.contains('sel')&&document.querySelectorAll('#rm-days .day-btn.sel').length<=1)return;
              this.classList.toggle('sel');
            };
            rmDaysEl.appendChild(btn);
          });
          document.getElementById('rm-days-row').style.display='none';
          document.getElementById('rm-transcode').value='none';
          var _isSports=_genre.toLowerCase().indexOf('sports')>=0;
          document.getElementById('rm-bonus').checked=_isSports;
          var rbstar=document.getElementById('rm-bonus-star');rbstar.textContent='+'+_bonusMins+'m';if(_isSports){rbstar.style.display='inline-flex';triggerSb('rm-bonus-star');}else{rbstar.style.display='none';rbstar.classList.remove('sb-anim');}
          // Show tuner-full warning only when the show is live and that device has no free tuners
          var nowTs=Math.floor(Date.now()/1000);
          var isLive=(_s<=nowTs&&_e>nowTs);
          document.getElementById('rm-tuner').style.display=(isLive&&devFull(_d))?'block':'none';
          opts.onchange=function(){
            var v=(document.querySelector('input[name="rm-type"]:checked')||{}).value||'';
            var isSeries=v==='seriesChannel'||v==='seriesAll';
            var sid=document.getElementById('rm-sid');
            if(isSeries&&_ser){document.getElementById('rm-sid-val').textContent=_ser;sid.style.display='flex';}
            else{sid.style.display='none';}
            document.getElementById('rm-days-row').style.display=(v==='dateTime')?'flex':'none';
          };
          document.getElementById('rec-modal').style.display='flex';
        }
        function cancelRecord(){document.getElementById('rec-modal').style.display='none';var rbstar=document.getElementById('rm-bonus-star');rbstar.style.display='none';rbstar.classList.remove('sb-anim');}
        function toggleRmBonusStar(){var chk=document.getElementById('rm-bonus');var star=document.getElementById('rm-bonus-star');if(chk.checked){star.textContent='+'+_bonusMins+'m';star.style.display='inline-flex';triggerSb('rm-bonus-star');}else{star.style.display='none';star.classList.remove('sb-anim');}}
        function confirmRecord(){
          var checked=document.querySelector('input[name="rm-type"]:checked');
          var type=checked?checked.value:'single';
          var airDays=Array.from(document.querySelectorAll('#rm-days .day-btn.sel')).map(function(b){return b.dataset.day;});
          var transcode=document.getElementById('rm-transcode').value;
          cancelRecord();
          var btn=document.getElementById('sum-btn');
          btn.disabled=true;btn.textContent='Scheduling…';
          fetch('/api/record',{method:'POST',headers:{'Content-Type':'application/json'},
            body:JSON.stringify({deviceId:_d,guideNumber:_n,startTime:_s,endTime:_e,showType:type,airDays:airDays,transcode:transcode,bonusTime:document.getElementById('rm-bonus').checked})})
          .then(function(r){
            if(r.ok){
              return r.json().then(function(j){
                // Update guide block in place — no page reload needed
                var sel=document.querySelector('.g-prog.g-sel');
                if(sel){
                  sel.classList.remove('g-prog-now');
                  if(j.recStarted){
                    sel.classList.add('g-prog-rec');sel.dataset.recording='1';
                    if(!sel.querySelector('.g-flag-rec')){var f=document.createElement('div');f.className='g-flag-rec';sel.appendChild(f);}
                  } else {
                    sel.classList.add('g-prog-sched');sel.dataset.managed='1';
                    if(!sel.querySelector('.g-flag')){var f=document.createElement('div');f.className='g-flag';sel.appendChild(f);}
                  }
                }
                // Refresh tuner count button
                var tb=document.getElementById('tun-'+_d);
                if(tb&&j.tunerTotal>0){
                  tb.textContent=j.tunerActive+'/'+j.tunerTotal+(j.tunerFull?' — FULL':'');
                  if(j.tunerFull)tb.classList.add('t-info-full');else tb.classList.remove('t-info-full');
                }
                btn.style.display='none';
                var note=document.getElementById('sum-note');
                var del=document.getElementById('sum-del');
                note.textContent=j.recStarted?'● Recording now':j.tunerFull?'⚠ Queued — all tuners busy':'★ Scheduled';
                note.style.color=j.recStarted?(isLM()?'#cc2020':'#ff8080'):j.tunerFull?(isLM()?'#c07000':'#ffcc66'):'var(--t2)';
                note.style.display='inline';
                del.textContent='Remove';del.style.background='';del.style.color='';del.style.display='inline-block';del.disabled=false;
                refreshGuide();
              });
            } else {
              return r.text().then(function(t){
                var msg;try{var j=JSON.parse(t);msg='Error: '+(j.error||t);}catch(x){msg='Error: '+t;}
                btn.textContent=msg;btn.style.background=isLM()?'#fce8e8':'#4a1010';btn.style.color=isLM()?'#8b0000':'#ff6b6b';btn.disabled=false;
                var note=document.getElementById('sum-note');note.textContent=msg;note.style.color=isLM()?'#cc2020':'#ff8080';note.style.display='inline';
              }).catch(function(){
                btn.textContent='Error ('+r.status+')';btn.disabled=false;
                var note=document.getElementById('sum-note');note.textContent='Error ('+r.status+')';note.style.color=isLM()?'#cc2020':'#ff8080';note.style.display='inline';
              });
            }
          })
          .catch(function(e){
            var msg='Error: '+(e.message||'network');
            btn.textContent=msg;btn.style.background=isLM()?'#fce8e8':'#4a1010';btn.style.color=isLM()?'#8b0000':'#ff6b6b';btn.disabled=false;
            var note=document.getElementById('sum-note');note.textContent=msg;note.style.color=isLM()?'#cc2020':'#ff8080';note.style.display='inline';
          });
        }
        function refreshGuide(){
          var gw=document.querySelector('.gw');
          var sl=gw?gw.scrollLeft:0,st=gw?gw.scrollTop:0;
          var prev=document.querySelector('.g-prog.g-sel');
          var prevStart=prev?prev.dataset.start:null,prevNum=prev?prev.dataset.num:null,prevDev=prev?prev.dataset.device:null;
          fetch('/').then(function(r){return r.text();}).then(function(html){
            var doc=new DOMParser().parseFromString(html,'text/html');
            var newGi=doc.querySelector('.gi'),oldGi=document.querySelector('.gi');
            if(newGi&&oldGi)oldGi.innerHTML=newGi.innerHTML;
            var newPh=doc.getElementById('sum-ph'),oldPh=document.getElementById('sum-ph');
            if(newPh&&oldPh)oldPh.innerHTML=newPh.innerHTML;
            var newSb=doc.getElementById('sched-pop-body'),oldSb=document.getElementById('sched-pop-body');
            if(newSb&&oldSb)oldSb.innerHTML=newSb.innerHTML;
            _rows=document.querySelectorAll('.g-row');
            setDev(curDev);
            if(gw){gw.scrollLeft=sl;gw.scrollTop=st;}
            if(prevStart){
              var match=Array.from(document.querySelectorAll('.g-prog')).find(function(el){
                return el.dataset.start===prevStart&&el.dataset.num===prevNum&&el.dataset.device===prevDev;
              });
              if(match)showInfo(match);
            }
          }).catch(function(){});
        }
        function doEditFromGuide(){
          var sel=document.querySelector('.g-prog.g-sel');
          if(!sel||!sel.dataset.showId)return;
          var sd=sel.dataset;
          openEditShow({dataset:{
            id:sd.showId, title:sd.title, ch:sd.num,
            type:sd.showType||'single', paused:sd.showPaused||'0',
            recording:sd.showRecording||'0', length:sd.showLength||'60',
            bonus:sd.showBonus||'0', transcode:sd.showTranscode||'none',
            seriesid:sd.showSeriesid||'', airdays:sd.showAirdays||'',
            failcount:sd.showFailcount||'0', failreason:sd.showFailreason||''
          }});
        }
        function doDelete(){
          var del=document.getElementById('sum-del');
          var _delLabel=del.textContent;
          del.disabled=true;del.textContent='Deleting…';
          var title=document.getElementById('sum-title').textContent||'';
          fetch('/api/delete',{method:'POST',headers:{'Content-Type':'application/json'},
            body:JSON.stringify({deviceId:_d,guideNumber:_n,startTime:_s,title:title})})
          .then(function(r){return r.json();})
          .then(function(j){
            var note=document.getElementById('sum-note');
            if(j.ok){
              // Update guide tile in place — restore g-prog-now if the show is still airing
              var sel=document.querySelector('.g-prog.g-sel');
              if(sel){
                sel.classList.remove('g-prog-rec','g-prog-sched','g-prog-now');sel.dataset.managed='0';sel.dataset.recording='0';
                var flag=sel.querySelector('.g-flag,.g-flag-rec');if(flag)flag.remove();
                var nowTs=Math.floor(Date.now()/1000);
                if(_s<=nowTs&&_e>nowTs){sel.classList.add('g-prog-now');}
              }
              del.style.display='none';
              note.textContent='✓ Deleted';note.style.color='var(--t3)';note.style.fontStyle='normal';note.style.display='inline';
              document.getElementById('sum-btn').textContent='Record';document.getElementById('sum-btn').style.background='#c0392b';
              document.getElementById('sum-btn').style.color='#fff';document.getElementById('sum-btn').style.display='inline-block';
              document.getElementById('sum-btn').disabled=false;
              refreshGuide();
            } else {
              del.textContent=_delLabel;del.disabled=false;
              note.textContent='Error: '+(j.error||'Delete failed');note.style.color='#ff8080';note.style.fontStyle='normal';note.style.display='inline';
            }
          })
          .catch(function(e){
            var del=document.getElementById('sum-del');del.textContent=_delLabel;del.disabled=false;
            var note=document.getElementById('sum-note');
            note.textContent='Error: '+(e.message||'network');note.style.color='#ff8080';note.style.fontStyle='normal';note.style.display='inline';
          });
        }
        function showTunerInfo(devId,anchor){
          var recs=recsByDev[devId]||[];
          var dt=tuners[devId]||{t:0,a:0};
          var full=dt.t>0&&dt.a>=dt.t;
          document.getElementById('t-pop-hdr').textContent=(dt.t>0?dt.a+'/'+dt.t+' tuners':'Tuners')+(full?' — FULL':'');
          var list=document.getElementById('t-pop-list');
          if(recs.length===0){
            list.innerHTML='<div style="color:var(--t4);font-size:.8rem;padding:4px 0">No active recordings</div>';
          } else {
            list.innerHTML=recs.map(function(r){
              var chLabel=hej(r.ch)+(r.chname?' · '+hej(r.chname):'');
              return '<div style="display:flex;flex-direction:column;gap:2px;padding:6px 0;border-bottom:1px solid var(--b0)">'
                +'<div style="display:flex;align-items:center;gap:8px">'
                  +'<span style="font-size:.67rem;color:var(--t4);min-width:48px;flex-shrink:0">'+hej(r.tuner)+'</span>'
                  +'<span style="font-size:.78rem;font-weight:600;color:var(--ac);white-space:nowrap">'+chLabel+'</span>'
                +'</div>'
                +'<div style="font-size:.82rem;color:var(--t0);padding-left:56px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">'+hej(r.title)+'</div>'
                +'</div>';
            }).join('');
          }
          var statusLink=document.getElementById('t-pop-status');
          if(dt&&dt.surl){statusLink.href=dt.surl;statusLink.style.display='block';}else{statusLink.style.display='none';}
          var pop=document.getElementById('t-pop-c');
          var rect=anchor.getBoundingClientRect();
          var left=Math.min(rect.left,window.innerWidth-360);
          pop.style.left=Math.max(8,left)+'px';
          pop.style.top=(rect.bottom+8)+'px';
          document.getElementById('t-pop').style.display='block';
        }
        function closeTunerPop(){document.getElementById('t-pop').style.display='none';}
        function openSchedPop(anchor){
          var pop=document.getElementById('sched-pop');
          if(pop.style.display!=='none'){closeSchedPop();return;}
          var c=document.getElementById('sched-pop-c');
          var rect=anchor.getBoundingClientRect();
          c.style.left=Math.max(8,Math.min(rect.left,window.innerWidth-360))+'px';
          c.style.top=(rect.bottom+8)+'px';
          pop.style.display='block';
          anchor.style.color='var(--ac)';anchor.setAttribute('aria-expanded','true');
        }
        function closeSchedPop(){
          document.getElementById('sched-pop').style.display='none';
          var btn=document.getElementById('status-btn');
          if(btn){btn.style.color='var(--t4)';btn.setAttribute('aria-expanded','false');}
        }
        // ── Edit show modal ──
        var _editId='',_editPaused=false,_editRec=false,_editType='single';
        var _dayNames=['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'];
        var _dayShort=['Su','M','Tu','W','Th','F','Sa'];
        function updateDaysVisibility(){
          document.getElementById('em-days-row').style.display=(_editType==='dateTime')?'flex':'none';
        }
        function toggleDay(btn){
          if(btn.classList.contains('sel')&&document.querySelectorAll('#em-days .day-btn.sel').length<=1)return;
          btn.classList.toggle('sel');
        }
        function openEditShow(el){
          var d=el.dataset;
          _editId=d.id;_editPaused=d.paused==='1';_editRec=d.recording==='1';_editType=d.type||'single';
          document.getElementById('em-title-in').value=d.title||'';
          document.getElementById('em-ch-in').value=d.ch||'';
          document.getElementById('em-len-in').value=d.length||'60';
          var opts=document.getElementById('em-type-opts');opts.innerHTML='';
          recOpts.forEach(function(o){
            var lbl=document.createElement('label');lbl.className='rm-lbl';
            var inp=document.createElement('input');inp.type='radio';inp.name='em-type';inp.value=o.v;
            if(o.v===_editType)inp.checked=true;
            inp.onchange=function(){_editType=this.value;updateDaysVisibility();};
            var info=document.createElement('div');
            info.innerHTML='<div class="rm-opt-l">'+o.l+'</div><div class="rm-opt-d">'+o.d+'</div>';
            lbl.appendChild(inp);lbl.appendChild(info);opts.appendChild(lbl);
          });
          var selDays=(d.airdays||'').split(',').filter(Boolean);
          var daysEl=document.getElementById('em-days');daysEl.innerHTML='';
          _dayNames.forEach(function(day,i){
            var btn=document.createElement('button');
            btn.type='button';btn.className='day-btn'+(selDays.indexOf(day)>=0?' sel':'');
            btn.textContent=_dayShort[i];btn.dataset.day=day;
            btn.onclick=function(){toggleDay(this);};
            daysEl.appendChild(btn);
          });
          updateDaysVisibility();
          document.getElementById('em-bonus').checked=d.bonus==='1';
          var ebstar=document.getElementById('em-bonus-star');ebstar.textContent='+'+_bonusMins+'m';
          if(d.bonus==='1'){ebstar.style.display='inline-flex';triggerSb('em-bonus-star');}else{ebstar.style.display='none';ebstar.classList.remove('sb-anim');}
          document.getElementById('em-bonus-row').style.display=_editRec?'none':'flex';
          document.getElementById('em-transcode').value=d.transcode||'none';
          var sid=d.seriesid||'';
          var sidRow=document.getElementById('em-sid-row');
          if(sid){document.getElementById('em-sid').textContent=sid;sidRow.style.display='block';}
          else{sidRow.style.display='none';}
          var fc=parseInt(d.failcount)||0;
          var failRow=document.getElementById('em-fail-row');
          if(fc>0){document.getElementById('em-fail-txt').textContent=fc+' failure'+(fc>1?'s':'')+' — '+(d.failreason||'');failRow.style.display='flex';}
          else{failRow.style.display='none';}
          document.getElementById('em-rec-warn').style.display=_editRec?'block':'none';
          var pb=document.getElementById('em-pause');
          pb.textContent=_editPaused?'Resume':'Pause';pb.style.display=_editRec?'none':'inline-block';
          document.getElementById('em-del').textContent=_editRec?'Stop & Delete':'Delete';
          document.getElementById('edit-modal').style.display='flex';
        }
        function closeEditShow(){document.getElementById('edit-modal').style.display='none';var ebstar=document.getElementById('em-bonus-star');ebstar.style.display='none';ebstar.classList.remove('sb-anim');}
        function doEditPause(){
          var pb=document.getElementById('em-pause');
          pb.disabled=true;pb.textContent='…';
          var np=!_editPaused;
          fetch('/api/edit',{method:'POST',headers:{'Content-Type':'application/json'},
            body:JSON.stringify({showId:_editId,paused:np})})
          .then(function(r){return r.json();})
          .then(function(j){
            pb.disabled=false;
            if(j.ok){_editPaused=np;pb.textContent=_editPaused?'Resume':'Pause';refreshGuide();}
            else{pb.textContent=_editPaused?'Resume':'Pause';}
          }).catch(function(){pb.disabled=false;pb.textContent=_editPaused?'Resume':'Pause';});
        }
        function doEditReset(){
          var btn=document.getElementById('em-reset');btn.disabled=true;btn.textContent='…';
          fetch('/api/edit',{method:'POST',headers:{'Content-Type':'application/json'},
            body:JSON.stringify({showId:_editId,resetFailures:true})})
          .then(function(r){return r.json();})
          .then(function(j){
            btn.disabled=false;btn.textContent='Reset';
            if(j.ok){document.getElementById('em-fail-row').style.display='none';}
          }).catch(function(){btn.disabled=false;btn.textContent='Reset';});
        }
        function confirmEdit(){
          var ck=document.querySelector('input[name="em-type"]:checked');if(!ck)return;
          var btn=document.getElementById('em-save');btn.disabled=true;btn.textContent='Saving…';
          var selDays=Array.from(document.querySelectorAll('#em-days .day-btn.sel')).map(function(b){return b.dataset.day;});
          var payload={
            showId:_editId,showType:ck.value,
            title:document.getElementById('em-title-in').value.trim(),
            channel:document.getElementById('em-ch-in').value.trim(),
            length:parseInt(document.getElementById('em-len-in').value)||60,
            bonusTime:document.getElementById('em-bonus').checked,
            transcode:document.getElementById('em-transcode').value,
            airDays:selDays
          };
          fetch('/api/edit',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)})
          .then(function(r){return r.json();})
          .then(function(j){
            btn.disabled=false;btn.textContent='Save';
            if(j.ok){closeEditShow();refreshGuide();}
            else{btn.style.background='#6a1010';btn.textContent='Error: '+(j.error||'failed');}
          }).catch(function(){btn.disabled=false;btn.textContent='Save';});
        }
        function doEditDelete(){
          var btn=document.getElementById('em-del');
          var lbl=btn.textContent;
          btn.disabled=true;btn.textContent='Deleting…';
          fetch('/api/delete',{method:'POST',headers:{'Content-Type':'application/json'},
            body:JSON.stringify({showId:_editId})})
          .then(function(r){return r.json();})
          .then(function(j){
            btn.disabled=false;btn.textContent=lbl;
            if(j.ok){closeEditShow();refreshGuide();}
          }).catch(function(){btn.disabled=false;btn.textContent=lbl;});
        }
        var curDev='';
        var _genreFilter='';
        var _rows=document.querySelectorAll('.g-row');
        function rowMatchesGenre(r){
          if(!_genreFilter)return true;
          return Array.from(r.querySelectorAll('.g-prog')).some(function(p){return(p.dataset.genre||'').toLowerCase()===_genreFilter.toLowerCase();});
        }
        function setDev(id){
          curDev=id;
          document.querySelectorAll('.d-btn').forEach(function(b){b.classList.toggle('d-sel',b.dataset.dev===id);});
          var seen={};
          _rows.forEach(function(r){
            var ok=rowMatchesGenre(r);
            if(id){r.style.display=(r.dataset.dev===id&&ok)?'':'none';}
            else{var ch=r.dataset.ch;if(!seen[ch]&&ok){r.style.display='';seen[ch]=true;}else{r.style.display='none';}}
          });
        }
        function filterGenre(g){_genreFilter=g;setDev(curDev);}
        setDev('');
        // Build genre filter from unique genres in the guide
        (function(){
          var gs=new Set();
          document.querySelectorAll('.g-prog[data-genre]').forEach(function(p){var g=p.dataset.genre;if(g)gs.add(g);});
          if(gs.size<2)return;
          var sel=document.getElementById('genre-sel');
          if(!sel)return;
          Array.from(gs).sort().forEach(function(g){var o=document.createElement('option');o.value=g;o.textContent=g;sel.appendChild(o);});
          document.getElementById('genre-bar').style.display='';
        })();
        // Auto-select the current-timeslot program on the first visible channel row
        (function(){
          var nowTs=Math.floor(Date.now()/1000);
          var first=Array.from(_rows).find(function(r){return r.style.display!=='none';});
          if(!first)return;
          var prog=Array.from(first.querySelectorAll('.g-prog')).find(function(el){return +el.dataset.start<=nowTs&&+el.dataset.end>nowTs;});
          if(prog)showInfo(prog);
        })();
        // scrollToNow: scroll guide so the now-line sits ~25% from the left of the viewport
        var _nowPct=\(nowPct);
        function scrollToNow(){var gw=document.querySelector('.gw');var gi=document.querySelector('.gi');if(!gw||!gi)return;var nowPx=gi.scrollWidth*(_nowPct/100);gw.scrollLeft=Math.max(0,nowPx-gw.clientWidth*0.25);}
        scrollToNow();
        // SSE: receive push events and refresh guide content in place (scroll + selection preserved)
        (function(){
          if(!window.EventSource)return;
          var es=new EventSource('/api/events');
          es.onmessage=function(e){
            try{
              var d=JSON.parse(e.data);
              if(!d||!d.type)return;
              if(d.type==='signal_update'&&d.gname&&d.bucket){
                // Inline DOM update — no full reload needed
                var bColors={poor:'#e53935',fair:'#fbc02d',good:'#43a047'};
                var bc=bColors[d.bucket]||null;
                document.querySelectorAll('.g-row[data-gname="'+d.gname+'"]').forEach(function(row){
                  var sig=row.querySelector('.g-sig');
                  if(!bc){if(sig)sig.remove();return;}
                  var svgStr='<svg class="g-sig" viewBox="0 0 11 10" width="11" height="10">'
                    +'<rect x="0" y="6" width="3" height="4" fill="'+bc+'"/>'
                    +'<rect x="4" y="3" width="3" height="7" fill="'+(d.bucket!=='poor'?bc:'#555')+'"/>'
                    +'<rect x="8" y="0" width="3" height="10" fill="'+(d.bucket==='good'?bc:'#555')+'"/>'
                    +'</svg>';
                  var tmp=document.createElement('div');tmp.innerHTML=svgStr;
                  if(sig){sig.replaceWith(tmp.firstChild);}
                  else{var cl=row.querySelector('.g-ch');if(cl)cl.appendChild(tmp.firstChild);}
                });
              } else {
                refreshGuide();
              }
            }catch(x){}
          };
        })();
        </script>
        </body>
        </html>
        """
    }

    @MainActor
    private func buildNowJSON(state: AppState) -> Data {
        struct NowEntry: Encodable {
            var deviceId, guideNumber, guideName, title: String
            var hd: Bool
            var episodeTitle: String?
            var startTime, endTime: Int
            var imageURL, channelLogoURL: String?
            var isRecording, isScheduled: Bool
        }

        var entries: [NowEntry] = []
        for device in state.devices {
            for (ch, entry) in state.onAirNow(for: device) {
                let isRec = state.recordingShows.contains { $0.hdhr_record == device.DeviceID && $0.show_channel == ch.GuideNumber }
                let isSched: Bool = {
                    // Match seriesID only for shows that actually record by SeriesID (isSeries).
                    // dateTime shows store a seriesid from guide data but don't use it for
                    // matching — including them would badge every airing of a series on any channel.
                    // Exclude paused shows to match buildHTML's activeMgd filter (!show_paused).
                    if let sid = entry.SeriesID, !sid.isEmpty,
                       let s = state.managedShowBySeriesID[sid], s.isSeries, !s.show_paused { return true }
                    return state.managedShowByTitle[entry.Title]?.first {
                        !$0.show_paused && ($0.isSeries || ($0.hdhr_record == device.DeviceID && $0.show_channel == ch.GuideNumber))
                    } != nil
                }()
                entries.append(NowEntry(
                    deviceId: device.DeviceID,
                    guideNumber: ch.GuideNumber,
                    guideName: ch.GuideName,
                    title: entry.Title,
                    hd: (ch.HD ?? 0) != 0,
                    episodeTitle: entry.EpisodeTitle,
                    startTime: entry.StartTime,
                    endTime: entry.EndTime,
                    imageURL: entry.ImageURL,
                    channelLogoURL: state.channelImageURLs["\(device.DeviceID):\(ch.GuideNumber)"],
                    isRecording: isRec,
                    isScheduled: isSched
                ))
            }
        }

        let enc = JSONEncoder()
        enc.outputFormatting = .prettyPrinted
        return (try? enc.encode(entries)) ?? Data("[]".utf8)
    }

    // MARK: - mDNS TXT update

    // Refreshes the mDNS TXT record with current recording + schedule state.
    // Called from AppState.idleLoop() and immediately when the server first becomes ready.
    @MainActor
    func updateTXTRecord() {
        guard let state = appState, listener != nil else { return }
        listener?.service = NWListener.Service(name: "hdhrVCR+", type: "_http._tcp", domain: nil,
                                               txtRecord: buildTXTRecord(state: state))
    }

    @MainActor
    private func buildTXTRecord(state: AppState) -> NWTXTRecord {
        var dict: [String: String] = ["path": "/", "port": "\(activePort)"]

        // All current recordings — rec, rec2, rec3, … (one key per show)
        // Format: "Title · Channel · DeviceID [· tunerN]"
        for (i, show) in state.recordingShows.enumerated() {
            let key  = i == 0 ? "rec" : "rec\(i + 1)"
            let slot = show.show_tuner_resource.isEmpty
                ? show.hdhr_record
                : "\(show.hdhr_record) · \(show.show_tuner_resource)"
            dict[key] = String("\(show.show_title) · \(show.show_channel) · \(slot)".prefix(120))
        }

        // Next upcoming show — "next" only; TXT records don't benefit from next2/next3
        // Format: "Title · Channel · DeviceID · in Xh Ym"
        if let next = state.activeShows.first(where: { $0.show_next != nil }) {
            dict["next"] = String("\(next.show_title) · \(next.show_channel) · \(next.hdhr_record) · \(txtRelativeTime(next.show_next!))".prefix(120))
        }

        return NWTXTRecord(dict)
    }

    private func txtRelativeTime(_ date: Date) -> String {
        let secs = max(0, Int(date.timeIntervalSinceNow))
        if secs < 60 { return "now" }
        let mins = secs / 60
        if mins < 60 { return "in \(mins)m" }
        let h = mins / 60, m = mins % 60
        return m == 0 ? "in \(h)h" : "in \(h)h \(m)m"
    }

    // MARK: - Send

    private func send(_ response: WebResponse, on conn: NWConnection) {
        let (status, headers, body): (String, [(String, String)], Data)
        switch response {
        case .ok(let ct, let b):
            status  = "200 OK"
            headers = [("Content-Type", ct), ("Content-Length", "\(b.count)")]
            body    = b

        case .notFound(let msg):
            let b = Data(msg.utf8)
            status  = "404 Not Found"
            headers = [("Content-Type", "text/plain"), ("Content-Length", "\(b.count)")]
            body    = b

        case .badRequest(let msg):
            let b = Data(msg.utf8)
            status  = "400 Bad Request"
            headers = [("Content-Type", "text/plain"), ("Content-Length", "\(b.count)")]
            body    = b

        case .payloadTooLarge(let msg):
            let b = Data(msg.utf8)
            status  = "413 Content Too Large"
            headers = [("Content-Type", "text/plain"), ("Content-Length", "\(b.count)")]
            body    = b
        }

        var raw = "HTTP/1.1 \(status)\r\n"
        raw += "Connection: close\r\n"
        for (k, v) in headers { raw += "\(k): \(v)\r\n" }
        raw += "\r\n"

        var packet = Data(raw.utf8)
        packet.append(body)

        conn.send(content: packet, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - Helpers

    // Escapes a JSON string for safe embedding inside a <script>…</script> block.
    // JSONSerialization leaves `<`, `>`, and `&` as literal bytes; browsers tokenise
    // `</script>` as an end-tag even inside a JS string literal, so these must be
    // replaced with their \uXXXX equivalents before inserting JSON into HTML.
    private func jsEscapeForScript(_ s: String) -> String {
        s.replacingOccurrences(of: "<",  with: "\\u003c")
         .replacingOccurrences(of: ">",  with: "\\u003e")
         .replacingOccurrences(of: "&",  with: "\\u0026")
    }

    // MARK: - User-Agent helpers

    // Returns true for desktop browser UAs (macOS/Windows/Linux without mobile tokens).
    // Used to serve a wider guide time window (full GuideHours) to desktop clients.
    private func isDesktopUA(_ ua: String) -> Bool {
        let l = ua.lowercased()
        if l.contains("mobile") || l.contains("iphone") || l.contains("ipad") || l.contains("android") { return false }
        return l.contains("macintosh") || l.contains("windows") || l.contains("linux")
    }

    // MARK: - Subnet guard

    // Returns true only for loopback and IPs in the same subnet as a local interface.
    // Handles both IPv4 and IPv6 (including link-local fe80:: addresses).
    private func isLocalAddress(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        let remoteIP: String
        let isIPv6: Bool
        switch host {
        case .ipv4(let addr): remoteIP = "\(addr)";  isIPv6 = false
        case .ipv6(let addr): remoteIP = "\(addr)";  isIPv6 = true
        case .name(let s, _): remoteIP = s;           isIPv6 = s.contains(":")
        @unknown default:     return false
        }
        // Strip the IPv4-mapped prefix (::ffff:x.x.x.x → x.x.x.x) so the loopback check
        // handles both native IPv4 and IPv4-in-IPv6 connections from localhost.
        let testIP = remoteIP.hasPrefix("::ffff:") ? String(remoteIP.dropFirst(7)) : remoteIP
        if testIP == "127.0.0.1" || testIP.hasPrefix("::1") { return true }

        var ptr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ptr) == 0, let base = ptr else { return false }
        defer { freeifaddrs(base) }

        if isIPv6 && remoteIP.hasPrefix("::ffff:") {
            let ipv4 = String(remoteIP.dropFirst(7))
            var cur2: UnsafeMutablePointer<ifaddrs>? = base
            while let iface = cur2 {
                defer { cur2 = iface.pointee.ifa_next }
                guard let sa = iface.pointee.ifa_addr,
                      sa.pointee.sa_family == sa_family_t(AF_INET),
                      let ma = iface.pointee.ifa_netmask else { continue }
                var remoteAddr = in_addr()
                let localAddr  = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                let maskAddr   = ma.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                guard inet_pton(AF_INET, ipv4, &remoteAddr) == 1 else { continue }
                if (localAddr.s_addr & maskAddr.s_addr) == (remoteAddr.s_addr & maskAddr.s_addr) { return true }
            }
            return false
        }

        if isIPv6 {
            // Strip zone ID suffix (e.g. "fe80::1%en0" → "fe80::1") before parsing.
            let cleanIP = remoteIP.components(separatedBy: "%").first ?? remoteIP
            var remoteAddr = in6_addr()
            guard inet_pton(AF_INET6, cleanIP, &remoteAddr) == 1 else { return false }
            var cur: UnsafeMutablePointer<ifaddrs>? = base
            while let iface = cur {
                defer { cur = iface.pointee.ifa_next }
                guard let sa = iface.pointee.ifa_addr,
                      sa.pointee.sa_family == sa_family_t(AF_INET6),
                      let ma = iface.pointee.ifa_netmask else { continue }
                let localAddr = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                let maskAddr  = ma.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                let inSubnet  = withUnsafeBytes(of: localAddr) { lb in
                    withUnsafeBytes(of: maskAddr)  { mb in
                        withUnsafeBytes(of: remoteAddr) { rb in
                            (0..<16).allSatisfy { i in (lb[i] & mb[i]) == (rb[i] & mb[i]) }
                        }
                    }
                }
                if inSubnet { return true }
            }
        } else {
            var remote = in_addr()
            guard inet_pton(AF_INET, remoteIP, &remote) == 1 else { return false }
            var cur: UnsafeMutablePointer<ifaddrs>? = base
            while let iface = cur {
                defer { cur = iface.pointee.ifa_next }
                guard let sa = iface.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
                      let ma = iface.pointee.ifa_netmask else { continue }
                let local = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                let mask  = ma.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                if (local & mask) == (remote.s_addr & mask) { return true }
            }
        }
        return false
    }

    // MARK: - Self-ping

    // GETs /api/ping on loopback to confirm end-to-end HTTP routing is working after bind.
    private func selfPing(port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/ping") else { return false }
        let req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }
}
