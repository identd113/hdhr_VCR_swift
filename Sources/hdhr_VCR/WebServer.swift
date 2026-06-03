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
                DispatchQueue.main.async { self.stateCallback?(nil) }
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
        listener?.cancel()
        listener = nil
        glog("[WebServer] Stopped")
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
            if path == "/api/record" { return handleRecord(state: state, body: body) }
            if path == "/api/delete" { return handleDelete(state: state, body: body) }
            return .notFound("Not found: \(path)")
        }

        // GET routes
        switch path {
        case "/", "/index.html":
            let html = buildHTML(state: state, isDesktop: isDesktopUA(userAgent))
            return .ok(contentType: "text/html; charset=utf-8", body: Data(html.utf8))

        case "/api/now.json":
            let data = buildNowJSON(state: state)
            return .ok(contentType: "application/json", body: data)

        case "/api/shows-html":
            let html = buildShowsSection(state: state)
            return .ok(contentType: "text/html; charset=utf-8", body: Data(html.utf8))

        default:
            return .notFound("Not found: \(path)")
        }
    }

    // Schedules a single-episode recording for the guide entry identified by
    // deviceId + guideNumber + startTime in the POST body JSON.
    @MainActor
    private func handleRecord(state: AppState, body: Data?) -> WebResponse {
        func json(_ dict: [String: Any]) -> WebResponse {
            .ok(contentType: "application/json",
                body: (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8))
        }
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
        let tunerFull = device.TunerCount.map { activeTuners >= $0 } ?? false
        state.addShowFromGuide(entry: entry, type: showType, device: device, channel: ch)
        return json(["ok": true, "title": entry.Title, "tunerFull": tunerFull])
    }

    // Removes the show that owns the guide entry identified by deviceId + guideNumber + title.
    // Stops any active recording and saves config, same as the in-app Delete flow.
    @MainActor
    private func handleDelete(state: AppState, body: Data?) -> WebResponse {
        func json(_ dict: [String: Any]) -> WebResponse {
            .ok(contentType: "application/json",
                body: (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8))
        }
        guard let body,
              let obj      = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let deviceId = obj["deviceId"]    as? String,
              let guideNum = obj["guideNumber"] as? String
        else { return .badRequest("Missing required fields") }

        let title = obj["title"] as? String ?? ""

        // Prefer an active recording on that exact device+channel, then fall back to title match.
        let show = state.recordingShows.first(where: {
                       $0.hdhr_record == deviceId && $0.show_channel == guideNum
                   }) ?? state.shows.first(where: {
                       $0.show_active &&
                       ($0.show_channel == guideNum || $0.isSeries) &&
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
        return json(["ok": true, "title": show.show_title])
    }

    // MARK: - HTML / JSON generation

    @MainActor
    private func buildShowsSection(state: AppState) -> String {
        func showRow(_ s: Show) -> String {
            "<tr><td>\(he(s.show_title))</td><td>\(he(s.show_channel))</td></tr>"
        }
        func showsTable(_ rows: String, _ label: String) -> String {
            guard !rows.isEmpty else { return "" }
            return "<details><summary>\(label)</summary><table><tr><th>Title</th><th>Channel</th></tr>\(rows)</table></details>"
        }
        return showsTable(state.recordingShows.map(showRow).joined(),  "● Recording")
             + showsTable(state.activeShows.map(showRow).joined(),     "★ Scheduled")
             + showsTable(state.pausedShows.map(showRow).joined(),     "⏸ Paused")
    }

    @MainActor
    private func buildHTML(state: AppState, isDesktop: Bool) -> String {

        // ── Time window: 1/2 of GuideHours for desktop, 1/4 for mobile ──────
        let nowTs    = Int(Date().timeIntervalSince1970)
        let halfHour = 30 * 60
        let winSec   = isDesktop ? state.config.GuideHours * 3600 / 2
                                 : state.config.GuideHours * 3600 / 4
        let winStart = (nowTs / halfHour) * halfHour
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
        let activeMgd = state.shows.filter { $0.show_active && !$0.show_paused }
        // SeriesID badge: only shows that are actually using SeriesID matching (seriesChannel/seriesAll).
        // dateTime shows store a seriesid from guide data but don't record by it — exclude them.
        // Combined single pass over the isSeries subset to build both mgdSID and mgdTitSeries.
        var mgdSID      = Set<String>()
        var mgdTitSeries = Set<String>()
        for s in activeMgd where s.isSeries {
            if !s.show_seriesid.isEmpty { mgdSID.insert(s.show_seriesid) }
            mgdTitSeries.insert(s.show_title)
        }
        // dateTime shows: only badge on their specific scheduled channel, not every airing everywhere.
        let mgdDateTimeCh = Set(activeMgd.filter { !$0.isSeries }
                                         .map { "\($0.show_title)|\($0.show_channel)" })
        // Shared managed-show predicate — used in both the guide grid and What's On Now cards.
        let checkMgd: (GuideEntry, LineupEntry) -> Bool = { e, ch in
            if let sid = e.SeriesID, !sid.isEmpty, mgdSID.contains(sid) { return true }
            if mgdTitSeries.contains(e.Title) { return true }
            return mgdDateTimeCh.contains("\(e.Title)|\(ch.GuideNumber)")
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
            return "<button class=\"\(cls)\" data-dev=\"\(he(devId))\" onclick=\"showTunerInfo(this.dataset.dev,this)\" title=\"Click to see active recordings\">\(label)</button>"
        }

        // ── Status toggle button — sits next to h1 in the header; reveals the status panel ──
        let statusBtn = "<button id=\"status-btn\" onclick=\"toggleStatus()\" title=\"What's On Now &amp; scheduled shows\" aria-expanded=\"false\" style=\"background:none;border:none;cursor:pointer;color:var(--t4);font-size:1.1rem;padding:2px 6px;line-height:1;border-radius:4px\">≡</button>"

        // ── Device bar (shown when >1 device; links to local HDHR web UI) ──────
        let headerHTML: String
        let deviceBarHTML: String
        if state.devices.count == 1, let d = state.devices.first {
            let uiURL = "http://\(d.LocalIP)/"
            let label = "HDHR-\(d.DeviceID.uppercased())"
            let dt    = devTuners[d.DeviceID]!
            headerHTML = "<div style=\"display:flex;align-items:center;gap:10px\"><h1 style=\"margin:0\">hdhrVCR+ · Guide</h1>\(statusBtn)\(tunerInfoBtn(d.DeviceID, dt))<a href=\"\(he(uiURL))\" target=\"_blank\" style=\"font-size:.75rem;color:#666;text-decoration:none\" title=\"Open \(he(label)) device web UI\">\(he(label)) ↗</a></div>"
            deviceBarHTML = ""
        } else if state.devices.count > 1 {
            headerHTML = "<div style=\"display:flex;align-items:center;gap:8px\"><h1 style=\"margin:0\">hdhrVCR+ · Guide</h1>\(statusBtn)</div>"
            var bar = "<div id=\"dev-bar\"><button class=\"d-btn d-sel\" data-dev=\"\" onclick=\"setDev('')\">All Tuners</button>"
            for d in state.devices {
                let uiURL = "http://\(d.LocalIP)/"
                let label = he("HDHR-\(d.DeviceID.uppercased())")
                let dt    = devTuners[d.DeviceID]!
                bar += "<button class=\"d-btn\" data-dev=\"\(he(d.DeviceID))\" onclick=\"setDev(this.dataset.dev)\">\(label)</button>"
                bar += "<a href=\"\(he(uiURL))\" target=\"_blank\" class=\"d-ui\" title=\"Open \(label) web UI\">↗</a>"
                bar += tunerInfoBtn(d.DeviceID, dt)
            }
            bar += "</div>"
            deviceBarHTML = bar
        } else {
            headerHTML = "<div style=\"display:flex;align-items:center;gap:8px\"><h1 style=\"margin:0\">hdhrVCR+ · Guide</h1>\(statusBtn)</div>"
            deviceBarHTML = ""
        }

        // ── Guide grid rows — one row per (device × channel); JS deduplicates the "All" view ──
        var rowParts: [String] = []
        // Collect on-air entries here so the Watch Now section can reuse them without a second
        // full lineup × guideStore walk (onAirNow internally does the same walk).
        var nowByDevice: [String: [(ch: LineupEntry, entry: GuideEntry)]] = [:]

        for device in state.devices {
            let sorted = (state.lineups[device.DeviceID] ?? [])
                .sorted {
                    if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
                    return $0.GuideNumber.channelSortKey < $1.GuideNumber.channelSortKey
                }
            var seenInDevice = Set<String>()   // dedup duplicate lineup entries within same device
            for ch in sorted {
                guard seenInDevice.insert(ch.GuideNumber).inserted else { continue }
                let entries = state.guideStore.entries(deviceId: device.DeviceID, channelNum: ch.GuideNumber)
                    .filter { $0.EndTime > winStart && $0.StartTime < winEnd }
                guard !entries.isEmpty else { continue }

                let logoURL  = state.channelImageURLs["\(device.DeviceID):\(ch.GuideNumber)"] ?? ""
                let isHD     = (ch.HD ?? 0) != 0
                let chLabel  = ch.GuideNumber + (isHD ? " HD" : "")
                let logoHTML = logoURL.isEmpty
                    ? "<div class=\"g-logo-ph\">\(he(String(ch.GuideName.prefix(1))))</div>"
                    : "<img class=\"g-logo\" src=\"\(he(logoURL))\" onerror=\"this.style.display='none'\" alt=\"\">"
                let isRecCh  = recChannelsByDevice[device.DeviceID]?.contains(ch.GuideNumber) ?? false

                var blockParts: [String] = ["<div class=\"g-now-bar\" style=\"left:\(nowPct)%\"></div>"]
                for e in entries {
                    let cs = max(e.StartTime, winStart) - winStart
                    let ce = min(e.EndTime,   winEnd)   - winStart
                    guard ce > cs else { continue }

                    let isNow      = e.StartTime <= nowTs && e.EndTime > nowTs
                    if isNow { nowByDevice[device.DeviceID, default: []].append((ch, e)) }
                    let isEntryRec = isRecCh && isNow
                    let isMgd      = checkMgd(e, ch)
                    var cls = "g-prog"
                    if isEntryRec      { cls += " g-prog-rec"   }
                    else if isNow      { cls += " g-prog-now"   }
                    else if isMgd      { cls += " g-prog-sched" }
                    else {
                        // Genre color (neutral blocks only; state classes take visual priority)
                        switch (e.firstGenre ?? "").lowercased() {
                        case "drama":    cls += " gg-drama"
                        case "comedy":   cls += " gg-comedy"
                        case "news":     cls += " gg-news"
                        case "sports":   cls += " gg-sports"
                        case "reality":  cls += " gg-reality"
                        case "movie":    cls += " gg-movie"
                        case "talk":     cls += " gg-talk"
                        case "children": cls += " gg-children"
                        default: break
                        }
                    }

                    let badge = isEntryRec ? "<b class=\"g-r\">●</b>"
                              : isMgd      ? "<b class=\"g-s\">★</b>" : ""
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

                    blockParts.append("<div class=\"\(cls)\" style=\"left:\(pct(cs))%;width:\(pct(ce - cs))%\" title=\"\(tip)\" \(da) onclick=\"showInfo(this)\"><div class=\"g-pi\">\(badge)<span class=\"g-ti\">\(he(e.Title))</span>\(subH)</div></div>")
                }

                rowParts.append("<div class=\"g-row\" data-dev=\"\(he(device.DeviceID))\" data-ch=\"\(he(ch.GuideNumber))\"><div class=\"g-ch\">\(logoHTML)<div class=\"g-cl\"><span class=\"g-cn\">\(he(chLabel))</span><span class=\"g-cname\">\(he(ch.GuideName))</span></div></div><div class=\"g-tl\">\(blockParts.joined())</div></div>")
            }
        }
        let rowsHTML = rowParts.isEmpty
            ? "<div style=\"padding:24px;color:#555;text-align:center;font-size:.85rem\">No guide data — loading…</div>"
            : rowParts.joined()

        // ── What's On Now cards (info only — no streaming; playback requires the Mac app) ──
        var cardParts: [String] = []
        for device in state.devices {
            for (ch, entry) in nowByDevice[device.DeviceID] ?? [] {
                let logoURL   = state.channelImageURLs["\(device.DeviceID):\(ch.GuideNumber)"] ?? ""
                let posterURL = entry.ImageURL ?? ""
                let isHD      = (ch.HD ?? 0) != 0
                let chLabel   = isHD ? "\(he(ch.GuideNumber))  \(he(ch.GuideName)) HD" : "\(he(ch.GuideNumber))  \(he(ch.GuideName))"
                let sub: String = {
                    if let ep = entry.EpisodeTitle, !ep.isEmpty { return he(ep) }
                    if let ts = entry.OriginalAirdate {
                        return he(origAirdateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(ts))))
                    }
                    return ""
                }()
                let isRec     = recording.contains { $0.hdhr_record == device.DeviceID && $0.show_channel == ch.GuideNumber }
                let isManaged = checkMgd(entry, ch)
                var badges = ""
                if isRec     { badges += "<span class=\"badge rec\">● Recording</span> " }
                if isManaged { badges += "<span class=\"badge sched\">★ Scheduled</span>" }
                let posterHTML = posterURL.isEmpty ? "" : "<img class=\"poster\" src=\"\(he(posterURL))\" onerror=\"this.style.display='none'\" alt=\"\">"
                let logoHTML   = logoURL.isEmpty   ? "" : "<img class=\"logo\" src=\"\(he(logoURL))\" onerror=\"this.style.display='none'\" alt=\"\">"
                cardParts.append("<div class=\"card\" data-dev=\"\(he(device.DeviceID))\">\(posterHTML)<div class=\"meta\">\(logoHTML)<span class=\"ch\">\(chLabel)</span><div class=\"title\">\(he(entry.Title))</div>\(sub.isEmpty ? "" : "<div class=\"sub\">\(sub)</div>")<div class=\"time\">\(he(guideTimeRange(entry))) · \(he(timeRemaining(until: entry.endDate)))</div><div class=\"badges\">\(badges)</div></div></div>")
            }
        }
        let cards = cardParts.isEmpty ? "<p class=\"empty\">No guide data — loading…</p>" : cardParts.joined()

        // ── Shows section ─────────────────────────────────────────────────────
        let showsSection = buildShowsSection(state: state)

        // ── Assemble ──────────────────────────────────────────────────────────
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="refresh" content="60">
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
        #theme-sw{display:flex;background:var(--s4);border:1px solid var(--b4);border-radius:6px;overflow:hidden;flex-shrink:0;margin-right:8px}
        #theme-sw button{background:none;border:none;border-right:1px solid var(--b4);padding:5px 9px;cursor:pointer;color:var(--t4);font-size:.8rem;line-height:1;transition:background .12s,color .12s}
        #theme-sw button:last-child{border-right:none}
        #theme-sw button:hover{background:var(--s3);color:var(--t0)}
        #theme-sw button.th-sel{background:var(--ac);color:#fff}
        /* ── Summary panel ── */
        .s-syn{overflow:hidden;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical}
        #sum{border-color:var(--b1)!important}
        #sum-ph{background:var(--s1)!important;color:var(--t5)!important}
        #sum-title{color:var(--t0)!important}
        #sum-ep,#sum-syn{color:var(--t0)!important}
        #sum-date{color:var(--t3)!important}
        #sum-ct{color:var(--t2)!important}
        #sum-del{background:var(--s4)!important;color:var(--t2)!important;border-color:var(--b4)!important}
        #sum-del.danger{background:#6a1010!important;color:#ffaaaa!important;border-color:#883030!important}
        html.lm #sum-del.danger{background:#fcd4d4!important;color:#8b0000!important;border-color:#cc3030!important}
        #sum button:not(#sum-btn):not(#sum-del){color:var(--t6)!important}
        html.lm #sum-genre{color:rgba(0,0,0,.65)!important;background:rgba(0,0,0,.1)!important}
        #sum-grad{background:linear-gradient(to right,rgba(0,0,0,.35),rgba(0,0,0,.05))}
        html.lm #sum-grad{background:linear-gradient(to right,rgba(0,0,0,.04),transparent)}
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
        .g-hdr-ch{width:130px;min-width:130px;position:sticky;left:0;z-index:11;background:var(--s2);border-right:1px solid var(--b2);padding:6px 8px;font-size:.65rem;color:var(--t4);text-transform:uppercase;letter-spacing:.07em}
        .g-hdr-tl{flex:1;position:relative;height:32px}
        .g-tick{position:absolute;top:50%;transform:translate(-50%,-50%);font-size:.68rem;color:var(--t4);white-space:nowrap;pointer-events:none}
        .g-now-tick{position:absolute;top:0;bottom:0;width:2px;background:rgba(255,90,90,.65);pointer-events:none}
        .g-row{display:flex;border-bottom:1px solid var(--b0)}
        .g-row:last-child{border-bottom:none}
        .g-ch{width:130px;min-width:130px;display:flex;align-items:center;gap:6px;padding:5px 8px;position:sticky;left:0;z-index:2;background:var(--s1);border-right:1px solid var(--b1)}
        .g-logo{width:24px;height:24px;object-fit:contain;flex-shrink:0}
        .g-logo-ph{width:24px;height:24px;border-radius:3px;background:var(--s4);display:flex;align-items:center;justify-content:center;font-size:.75rem;color:var(--t4);flex-shrink:0}
        .g-cl{overflow:hidden;flex:1}
        .g-cn{display:block;font-size:.68rem;color:var(--t3);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-weight:500}
        .g-cname{display:block;font-size:.72rem;color:var(--t1);font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
        /* 30-min gridlines */
        .g-tl{flex:1;position:relative;min-height:54px;background:repeating-linear-gradient(90deg,transparent,transparent calc(8.3333% - 1px),var(--b0) calc(8.3333% - 1px),var(--b0) 8.3333%)}
        .g-now-bar{position:absolute;top:0;bottom:0;width:2px;background:rgba(255,90,90,.75);z-index:1;pointer-events:none}
        .g-prog{position:absolute;top:4px;bottom:4px;border-radius:5px;overflow:hidden;background:var(--pg);border:1px solid var(--pgb);min-width:3px;cursor:pointer}
        .g-prog:hover{filter:brightness(1.1);border-color:var(--t5);z-index:3}
        .g-prog.g-sel{border-color:var(--t0)!important;box-shadow:0 0 0 1px rgba(128,128,128,.5);z-index:4}
        .g-prog-now  {background:#1c3820;border-color:#3a6a40}
        .g-prog-rec  {background:#3c1818;border-color:#c03030}
        .g-prog-sched{background:#1a1a40;border-color:#4848c8}
        html.lm .g-prog-now  {background:#c8edce;border-color:#3a7a44}
        html.lm .g-prog-rec  {background:#fcd4d4;border-color:#cc3030}
        html.lm .g-prog-sched{background:#d4d4f8;border-color:#5050cc}
        .gg-drama    {background:hsl(216,50%,26%)}
        .gg-comedy   {background:hsl(47,55%,26%)}
        .gg-news     {background:hsl(342,50%,24%)}
        .gg-sports   {background:hsl(119,55%,21%)}
        .gg-reality  {background:hsl(25,55%,24%)}
        .gg-movie    {background:hsl(270,45%,26%)}
        .gg-talk     {background:hsl(173,50%,21%)}
        .gg-children {background:hsl(202,45%,24%)}
        html.lm .gg-drama    {background:hsl(216,55%,88%)}
        html.lm .gg-comedy   {background:hsl(47,65%,88%)}
        html.lm .gg-news     {background:hsl(342,55%,88%)}
        html.lm .gg-sports   {background:hsl(119,60%,87%)}
        html.lm .gg-reality  {background:hsl(25,65%,88%)}
        html.lm .gg-movie    {background:hsl(270,50%,88%)}
        html.lm .gg-talk     {background:hsl(173,55%,87%)}
        html.lm .gg-children {background:hsl(202,55%,87%)}
        .g-pi{padding:3px 6px;height:100%;display:flex;flex-direction:column;justify-content:center;gap:1px;overflow:hidden}
        .g-ti{font-size:.78rem;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;color:var(--t0);line-height:1.25}
        .g-sub{font-size:.65rem;color:var(--t3);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;line-height:1.25}
        .g-r{font-style:normal;font-weight:700;color:#ff8080;font-size:.68rem;margin-right:2px}
        .g-s{font-style:normal;font-weight:700;color:#70e870;font-size:.68rem;margin-right:2px}
        html.lm .g-s{color:#2a8a2a}
        /* ── Watch Now / details ── */
        details{margin-top:8px}
        summary{cursor:pointer;font-size:.85rem;color:var(--t3);padding:6px 0;list-style:none;user-select:none}
        summary::-webkit-details-marker{display:none}
        summary::before{content:"▶  ";font-size:.62rem;color:var(--t5)}
        details[open] summary::before{content:"▼  "}
        .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(290px,1fr));gap:14px;margin-top:10px}
        .card{background:var(--s3);border:1px solid var(--b3);border-radius:10px;overflow:hidden;display:flex;flex-direction:column}
        .poster{width:100%;height:130px;object-fit:cover}
        .meta{padding:11px;flex:1;display:flex;flex-direction:column;gap:4px}
        .logo{width:22px;height:22px;object-fit:contain;vertical-align:middle;margin-right:5px}
        .ch{font-size:.78rem;color:var(--t3)}
        .title{font-weight:700;font-size:.95rem;line-height:1.2;color:var(--t0)}
        .sub{font-size:.8rem;color:var(--t2)}
        .time{font-size:.74rem;color:var(--t3)}
        .badges{font-size:.72rem;margin-top:3px}
        .badge{border-radius:4px;padding:2px 7px;font-weight:600}
        .rec{background:#4a1414;color:#ff9090;border:1px solid #7a2020}
        .sched{background:#184018;color:#80e880;border:1px solid #306030}
        html.lm .rec{background:#fce8e8;color:#8b0000;border-color:#cc3030}
        html.lm .sched{background:#e8f5e8;color:#1a5c1a;border-color:#3a8a3a}
        .empty{color:var(--t5);padding:20px;text-align:center;font-size:.85rem}
        table{width:100%;border-collapse:collapse;margin-top:8px;font-size:.82rem}
        th,td{text-align:left;padding:5px 8px;border-bottom:1px solid var(--b0)}
        th{color:var(--t3);font-weight:600}
        td{color:var(--t2)}
        .rm-lbl{display:flex;align-items:flex-start;gap:10px;cursor:pointer;padding:9px 11px;border-radius:7px;border:1px solid var(--b3);transition:border-color .15s}
        .rm-lbl:hover{border-color:var(--t4)}
        .rm-lbl input{margin-top:3px;flex-shrink:0;accent-color:#c0392b}
        </style>
        </head>
        <body>
        <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:14px">
          <div>\(headerHTML)</div>
          <div id="theme-sw">
            <button data-m="dark"  onclick="setTheme('dark')"  title="Dark">◗</button>
            <button data-m="auto"  onclick="setTheme('auto')"  title="Auto (system)">◐</button>
            <button data-m="light" onclick="setTheme('light')" title="Light">◖</button>
          </div>
        </div>
        \(deviceBarHTML)
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
          <div id="sum-ph" style="flex:1;display:flex;align-items:center;justify-content:center;color:#777;font-size:.85rem;background:#1a1a1a;padding:16px">Select a show from the guide</div>
          <div id="sum-c" style="display:none;flex:1;flex-direction:row">
            <img id="sum-poster" src="" alt="" style="width:120px;min-width:120px;object-fit:cover;display:none" onerror="this.style.display='none'">
            <div id="sum-grad" style="flex:1;padding:12px 14px;display:flex;flex-direction:column;gap:3px;overflow:hidden">
              <div id="sum-title" style="font-size:.92rem;font-weight:700;color:#fff;white-space:nowrap;overflow:hidden;text-overflow:ellipsis"></div>
              <div id="sum-genre" style="display:none;font-size:.6rem;font-weight:700;color:rgba(255,255,255,.85);background:rgba(255,255,255,.18);border-radius:3px;padding:2px 6px;align-self:flex-start;letter-spacing:.06em"></div>
              <div id="sum-ep"   style="display:none;font-size:.78rem;color:#ddd;white-space:nowrap;overflow:hidden;text-overflow:ellipsis"></div>
              <div id="sum-date" style="display:none;font-size:.68rem;color:rgba(255,255,255,.7)"></div>
              <div id="sum-syn"  class="s-syn" style="display:none;font-size:.76rem;color:#e0e0e0;line-height:1.35"></div>
              <div id="sum-actions" style="display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-top:6px">
                <span id="sum-note" style="display:none;font-size:.75rem;font-style:italic;color:rgba(255,255,255,.75)"></span>
                <button id="sum-btn" onclick="doRecord()" style="display:none;font-size:.75rem;padding:5px 14px;border-radius:5px;border:none;cursor:pointer;font-weight:600;background:#c0392b;color:#fff">Record</button>
                <button id="sum-del" onclick="doDelete()" style="display:none;font-size:.75rem;padding:5px 14px;border-radius:5px;cursor:pointer;font-weight:600">Delete</button>
              </div>
              <div style="flex:1"></div>
              <div style="display:flex;align-items:center;gap:10px;flex-wrap:wrap;margin-top:6px">
                <img id="sum-logo" src="" alt="" style="width:24px;height:24px;object-fit:contain;display:none" onerror="this.style.display='none'">
                <span id="sum-ct" style="font-size:.68rem;color:rgba(255,255,255,.8)"></span>
              </div>
            </div>
            <button onclick="closeSummary()" style="background:none;border:none;color:#666;font-size:.9rem;cursor:pointer;padding:6px 10px;align-self:flex-start;flex-shrink:0;margin-top:4px" title="Close">✕</button>
          </div>
        </div>
        <div id="rec-modal" onclick="if(event.target===this)cancelRecord()" style="display:none;position:fixed;inset:0;background:rgba(0,0,0,.8);z-index:100;align-items:center;justify-content:center">
          <div style="background:#1c1c1e;border:1px solid #383838;border-radius:12px;padding:20px 22px;width:340px;max-width:90vw;box-shadow:0 20px 60px rgba(0,0,0,.6)">
            <div style="margin-bottom:14px">
              <div id="rm-title" style="font-weight:700;font-size:.95rem;color:#fff;white-space:nowrap;overflow:hidden;text-overflow:ellipsis"></div>
              <div id="rm-ch" style="font-size:.7rem;color:#888;margin-top:2px"></div>
            </div>
            <div id="rm-opts" style="display:flex;flex-direction:column;gap:6px;margin-bottom:8px"></div>
            <div id="rm-sid" style="display:none;font-size:.68rem;color:#888;background:#111;border-radius:5px;padding:5px 10px;margin-bottom:10px">SeriesID: <span id="rm-sid-val" style="color:#bbb;font-family:monospace;word-break:break-all"></span></div>
            <div id="rm-tuner" style="display:none;font-size:.74rem;color:#ffcc66;background:#2a1e00;border:1px solid #7a5500;border-radius:6px;padding:7px 10px;margin-bottom:10px">⚠ All tuners are currently in use. This show will be queued and recorded as soon as a tuner is free.</div>
            <div style="display:flex;justify-content:flex-end;gap:8px">
              <button onclick="cancelRecord()" style="font-size:.78rem;padding:6px 16px;border-radius:6px;border:1px solid #444;background:transparent;color:#aaa;cursor:pointer">Cancel</button>
              <button onclick="confirmRecord()" style="font-size:.78rem;padding:6px 16px;border-radius:6px;border:none;background:#c0392b;color:#fff;font-weight:600;cursor:pointer">Schedule</button>
            </div>
          </div>
        </div>
        <div class="gw"><div class="gi">
        <div class="g-hdr"><div class="g-hdr-ch">Channel</div><div class="g-hdr-tl">\(ticksHTML)</div></div>
        \(rowsHTML)
        </div></div>
        <div id="status-panel" style="display:none;margin-bottom:16px">
        <details open><summary>What's On Now</summary>
        <div class="grid">\(cards)</div></details>
        <div id="shows-section">\(showsSection)</div>
        </div>
        <script>
        \(tunerJS)
        \(recsByDevJS)
        var _d='',_n='',_s=0,_e=0,_ser='';
        function hej(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');}
        // Theme: .lm class on <html> = light mode active
        var _mq=window.matchMedia('(prefers-color-scheme:light)');
        var _themeMode='dark';
        function applyLM(on){document.documentElement.classList.toggle('lm',on);document.querySelectorAll('#theme-sw button').forEach(function(b){b.classList.toggle('th-sel',b.dataset.m===_themeMode);});}
        function setTheme(m){_themeMode=m;try{localStorage.setItem('theme',m);}catch(e){}applyLM(m==='light'||(m==='auto'&&_mq.matches));}
        _mq.addEventListener('change',function(e){if(_themeMode==='auto')applyLM(e.matches);});
        (function(){try{_themeMode=localStorage.getItem('theme')||'dark';}catch(e){}applyLM(_themeMode==='light'||(_themeMode==='auto'&&_mq.matches));})();
        function isLM(){return document.documentElement.classList.contains('lm');}
        function gc(g){
          var dk={drama:'hsl(216,50%,26%)',comedy:'hsl(47,55%,26%)',news:'hsl(342,50%,24%)',sports:'hsl(119,55%,21%)',reality:'hsl(25,55%,24%)',movie:'hsl(270,45%,26%)',talk:'hsl(173,50%,21%)',children:'hsl(202,45%,24%)'};
          var lk={drama:'hsl(216,55%,88%)',comedy:'hsl(47,65%,88%)',news:'hsl(342,55%,88%)',sports:'hsl(119,60%,87%)',reality:'hsl(25,65%,88%)',movie:'hsl(270,50%,88%)',talk:'hsl(173,55%,87%)',children:'hsl(202,55%,87%)'};
          var m=isLM()?lk:dk;return m[(g||'').toLowerCase()]||(isLM()?'#f0f0f4':'#1e1e2a');
        }
        function ft(d){var h=d.getHours(),m=d.getMinutes(),ap=h>=12?'PM':'AM';h=h%12||12;return h+(m?':'+(m<10?'0':'')+m:'')+' '+ap;}
        function so(id,v){var e=document.getElementById(id);if(v){e.textContent=v;e.style.display='block';}else{e.style.display='none';}}
        function devFull(devId){var t=tuners[devId];return t&&t.t>0&&t.a>=t.t;}
        function showInfo(el){
          var d=el.dataset;
          _d=d.device;_n=d.num;_s=+d.start;_e=+d.end;_ser=d.series||'';
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
          btn.style.display='none';del.style.display='none';note.style.display='none';
          del.disabled=false;del.textContent='Delete';del.classList.remove('danger');del.style.background='';del.style.color='';
          if(+d.recording){
            note.textContent='● Recording now';note.style.color='#ff8080';note.style.display='inline';
            del.textContent='Stop & Delete';del.classList.add('danger');del.style.display='inline-block';
          } else if(+d.managed){
            note.textContent='★ Already scheduled';note.style.color='var(--t2)';note.style.display='inline';
            del.textContent='Remove';del.style.display='inline-block';
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
        }
        var recOpts=[
          {v:'single',        l:'Single episode',       d:'Record this airing only',               s:false},
          {v:'dateTime',      l:'Weekly repeat',         d:'Record at this time each week',         s:false},
          {v:'seriesChannel', l:'Series — this channel', d:'Record new episodes on this channel',   s:true},
          {v:'seriesAll',     l:'Series — any channel',  d:'Record new episodes on any channel',    s:true}
        ];
        function doRecord(){
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
          // Show tuner-full warning only when the show is live and that device has no free tuners
          var nowTs=Math.floor(Date.now()/1000);
          var isLive=(_s<=nowTs&&_e>nowTs);
          document.getElementById('rm-tuner').style.display=(isLive&&devFull(_d))?'block':'none';
          opts.onchange=function(){
            var v=(document.querySelector('input[name="rm-type"]:checked')||{}).value||'';
            var isSeries=v==='seriesChannel'||v==='seriesAll';
            var sid=document.getElementById('rm-sid');
            if(isSeries&&_ser){document.getElementById('rm-sid-val').textContent=_ser;sid.style.display='block';}
            else{sid.style.display='none';}
          };
          document.getElementById('rec-modal').style.display='flex';
        }
        function cancelRecord(){document.getElementById('rec-modal').style.display='none';}
        function confirmRecord(){
          var checked=document.querySelector('input[name="rm-type"]:checked');
          var type=checked?checked.value:'single';
          cancelRecord();
          var btn=document.getElementById('sum-btn');
          btn.disabled=true;btn.textContent='Scheduling…';
          fetch('/api/record',{method:'POST',headers:{'Content-Type':'application/json'},
            body:JSON.stringify({deviceId:_d,guideNumber:_n,startTime:_s,endTime:_e,showType:type})})
          .then(function(r){
            if(r.ok){
              return r.json().then(function(j){
                // Update guide block in place — no page reload needed
                var sel=document.querySelector('.g-prog.g-sel');
                if(sel){
                  sel.classList.remove('g-prog-now');sel.classList.add('g-prog-sched');sel.dataset.managed='1';
                  var pi=sel.querySelector('.g-pi');
                  if(pi&&!sel.querySelector('.g-s')){var b=document.createElement('b');b.className='g-s';b.textContent='★';pi.insertBefore(b,pi.firstChild);}
                }
                btn.style.display='none';
                var note=document.getElementById('sum-note');
                var del=document.getElementById('sum-del');
                note.textContent=j.tunerFull?'⚠ Queued — all tuners busy':'★ Scheduled';
                note.style.color=j.tunerFull?(isLM()?'#c07000':'#ffcc66'):'var(--t2)';
                note.style.display='inline';
                del.textContent='Remove';del.style.background='';del.style.color='';del.style.display='inline-block';del.disabled=false;
                refreshShowsSection();
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
        function refreshShowsSection(){
          fetch('/api/shows-html').then(function(r){return r.text();}).then(function(h){
            var s=document.getElementById('shows-section');if(s)s.innerHTML=h;
          }).catch(function(){});
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
                var badge=sel.querySelector('.g-r,.g-s');if(badge)badge.remove();
                var nowTs=Math.floor(Date.now()/1000);
                if(_s<=nowTs&&_e>nowTs){sel.classList.add('g-prog-now');}
              }
              del.style.display='none';
              note.textContent='✓ Deleted';note.style.color='var(--t3)';note.style.fontStyle='normal';note.style.display='inline';
              document.getElementById('sum-btn').textContent='Record';document.getElementById('sum-btn').style.background='#c0392b';
              document.getElementById('sum-btn').style.color='#fff';document.getElementById('sum-btn').style.display='inline-block';
              document.getElementById('sum-btn').disabled=false;
              refreshShowsSection();
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
        function toggleStatus(){
          var p=document.getElementById('status-panel');
          var btn=document.getElementById('status-btn');
          var open=p.style.display!=='none';
          p.style.display=open?'none':'block';
          btn.style.color=open?'var(--t4)':'var(--ac)';
          btn.setAttribute('aria-expanded',open?'false':'true');
        }
        var curDev='';
        var _rows=document.querySelectorAll('.g-row');
        var _cards=document.querySelectorAll('.card');
        function setDev(id){
          curDev=id;
          document.querySelectorAll('.d-btn').forEach(function(b){b.classList.toggle('d-sel',b.dataset.dev===id);});
          var seen={};
          _rows.forEach(function(r){
            if(id){r.style.display=r.dataset.dev===id?'':'none';}
            else{var ch=r.dataset.ch;if(!seen[ch]){r.style.display='';seen[ch]=true;}else{r.style.display='none';}}
          });
          _cards.forEach(function(c){
            c.style.display=(!id||c.dataset.dev===id)?'':'none';
          });
        }
        setDev('');
        // Auto-select the current-timeslot program on the first visible channel row
        (function(){
          var nowTs=Math.floor(Date.now()/1000);
          var first=Array.from(_rows).find(function(r){return r.style.display!=='none';});
          if(!first)return;
          var prog=Array.from(first.querySelectorAll('.g-prog')).find(function(el){return +el.dataset.start<=nowTs&&+el.dataset.end>nowTs;});
          if(prog)showInfo(prog);
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
    // Used to serve a wider guide time window (1/2 GuideHours) to desktop clients.
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
}
