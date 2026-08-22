import AppKit
import Foundation
import Network
import Compression

// NWListener-based LAN web server. Binds to all interfaces; the subnet guard
// in handleConnection cancels any connection whose source IP is outside the
// local interface subnets — no data is read or sent to non-LAN callers.
final class WebServer: @unchecked Sendable {

    private enum WebResponse {
        case ok(contentType: String, body: Data)
        // Like .ok, but the gzip encoding was already computed ahead of time (e.g. cachedHTMLGzip,
        // refreshed only when the guide reloads) — avoids paying the DEFLATE cost on every request
        // for a body that rarely changes.
        case okPrecompressed(contentType: String, raw: Data, gzip: Data)
        case notFound(String)
        case badRequest(String)
        case payloadTooLarge(String)
    }

    private var listener:      NWListener?
    private var stateCallback: ((String?) -> Void)?   // nil'd by stop() to silence spurious callbacks
    private var activePort: Int = 1980
    private let queue = DispatchQueue(label: "hdhrVCRplus.webserver", qos: .utility)
    // Every NWConnection is started with `queue` (see handleConnection), so it backs everything —
    // accepting connections, every other connection's request/response I/O, SSE keepalives — not
    // just requests. The Watch Now recording relay's disk reads (handleWatchRecording →
    // streamGrowingFile → pumpGrowingFile) are the one place this file does *blocking* synchronous
    // I/O (FileHandle open/seek/readData) against a real filesystem that can stall (a slow/
    // contended external or network-mounted recording volume) — routing that through `queue` would
    // freeze the entire web server for every other LAN client for as long as the stall lasts, not
    // just the one streaming connection. `fileIOQueue` isolates exactly that blocking work; actual
    // NWConnection sends still happen on `queue`, same as everywhere else in this file.
    private let fileIOQueue = DispatchQueue(label: "hdhrVCRplus.webserver.fileio", qos: .utility)
    private weak var appState: AppState?

    // SSE: open connections waiting for push events
    private var sseConns: [NWConnection] = []
    private let sseLock  = NSLock()

    // All accepted connections (SSE and normal alike) so stop() can close kept-alive connections
    // that would otherwise keep being served after the server is disabled. Each conn removes
    // itself here via its stateUpdateHandler when it reaches .cancelled/.failed.
    private var liveConns: [NWConnection] = []
    private let connLock  = NSLock()

    // Pre-built page HTML cache — rebuilt after guide refresh, served instantly on GET /.
    // Desktop and mobile share the same guide window size (see guideWindow(state:)) — one
    // cached copy serves every UA.
    private var cachedHTML: Data? = nil
    // gzip of cachedHTML, computed once alongside it instead of on every request — the page is
    // ~1.5MB raw, and libcompression's DEFLATE pass over that costs ~30-60ms; recomputing it per
    // GET / (this page is fetched far more often than the guide actually changes) is pure waste.
    private var cachedHTMLGzip: Data? = nil
    // The raw .gi innerHTML (buildGuideGridHTML's output) that fed the cache above — kept
    // separately so GET /api/guide-refresh can reuse it instead of paying for another full
    // buildGuideGridHTML pass on every hit; nil only before the first prebuildPageHTML ever runs,
    // same as cachedHTML's own live-build fallback below.
    private var cachedGridHTML: String? = nil

    // Separate cache for GET /vertical — identical grid/data, but with the vertical time-axis
    // <style> block included (see buildHTML(includeVerticalCSS:)) so portrait can transpose the
    // grid while landscape on that same route falls back to normal. GET / never includes that
    // stylesheet at all, in either cache pair, so it can never show the vertical layout no
    // matter how the phone is held — that's the whole reason there are two cache pairs instead
    // of one shared page toggled by a class/route.
    private var cachedVerticalHTML: Data? = nil
    private var cachedVerticalHTMLGzip: Data? = nil
    // /vertical only matters for portrait-orientation mobile browsers — a much smaller (often
    // zero) slice of traffic than GET /. Sticky for the process lifetime once true: set by the
    // /vertical route handler on its first hit, checked by prebuildPageHTML to decide whether
    // building/gzip'ing the vertical variant is worth doing on this and future rebuilds, instead
    // of paying that cost on every guide-changing event for installs that never see it requested.
    private var verticalRouteEverRequested = false

    // App icon rendered once as 72×72 PNG; reused on every /api/icon request.
    private lazy var cachedIconPNG: Data? = {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let img = NSImage(contentsOf: url) else { return nil }
        let out = NSImage(size: NSSize(width: 72, height: 72), flipped: false) { r in
            img.draw(in: r); return true
        }
        guard let tiff = out.tiffRepresentation,
              let bmp  = NSBitmapImageRep(data: tiff) else { return nil }
        return bmp.representation(using: .png, properties: [:])
    }()

    // Guide page CSS/JS/HTML-skeleton, loaded once and reused across every buildHTML() call —
    // these are real files under Resources/ (see templateURL(_:_:)) rather than Swift string
    // literals, so they get normal syntax highlighting/linting and don't need Swift-string
    // double-escaping for JS regex.
    private lazy var cachedGuideCSS: String?       = Self.loadTemplate("guide", "css")
    // Vertical time-axis mode's CSS, kept in its own file/cache/<style> block (not concatenated
    // into cachedGuideCSS) specifically so editing one can't accidentally touch the other —
    // every selector in it is scoped under @media (orientation:portrait), automatic and
    // toggle-free, so it's inert whenever the viewport is actually landscape.
    private lazy var cachedGuideVerticalCSS: String? = Self.loadTemplate("guide-vertical", "css")
    private lazy var cachedGuideJS: String?        = Self.loadTemplate("guide", "js")
    private lazy var cachedGuideShellHTML: String? = Self.loadTemplate("guide-shell", "html")

    private static func loadTemplate(_ name: String, _ ext: String) -> String? {
        guard let url = templateURL(name, ext) else { return nil }
        // Trim the trailing newline every text file ends with — the original Swift string
        // literal had none between the last content line and the closing tag on the next
        // source line, and the caller already supplies its own line breaks around each template.
        return (try? String(contentsOf: url, encoding: .utf8))?
            .trimmingCharacters(in: .newlines)
    }

    private static func templateURL(_ name: String, _ ext: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext) { return url }
        #if DEBUG
        // Dev convenience: running .build/debug/hdhr_VCR directly (not via deploy.sh) has no
        // Contents/Resources — fall back to the repo-root Resources/ dir relative to this source
        // file, so `swift build` + direct-run iteration still renders a working guide page.
        let repoResources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Sources/hdhr_VCR/
            .deletingLastPathComponent()   // Sources/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Resources").appendingPathComponent("\(name).\(ext)")
        return FileManager.default.fileExists(atPath: repoResources.path) ? repoResources : nil
        #else
        return nil
        #endif
    }

    // Substitutes {{TOKEN}} placeholders in a loaded template with their runtime values.
    // Single left-to-right pass over the ORIGINAL template — a substituted value is appended
    // straight into the result and never rescanned, so a value that happens to contain literal
    // "{{OTHER_TOKEN}}" text (e.g. a user-entered show title) can't get a second, corrupting
    // substitution the way a reduce-over-replacingOccurrences chain would.
    // Not private — same reasoning as jsEscapeForScript below (WebServerHelperTests exercises
    // this directly).
    func fillTemplate(_ template: String, _ tokens: [(String, String)]) -> String {
        let values = Dictionary(uniqueKeysWithValues: tokens)
        var result = ""
        var remainder = Substring(template)
        while let openRange = remainder.range(of: "{{") {
            result += remainder[remainder.startIndex..<openRange.lowerBound]
            let afterOpen = remainder[openRange.upperBound...]
            guard let closeRange = afterOpen.range(of: "}}") else {
                result += remainder[openRange.lowerBound...]
                remainder = Substring("")
                break
            }
            let tokenName = String(afterOpen[afterOpen.startIndex..<closeRange.lowerBound])
            // Unrecognized token text is left as literal "{{...}}" so a typo'd/renamed token
            // shows up visibly on the page instead of silently vanishing.
            result += values[tokenName] ?? "{{\(tokenName)}}"
            remainder = afterOpen[closeRange.upperBound...]
        }
        result += remainder
        return result
    }

    @MainActor
    func prebuildPageHTML(state: AppState, prebuiltGrid: String? = nil) {
        // Computed once (it's the expensive part — 1300+ program blocks) and reused for both
        // variants below, which differ only in their <head>/<style>, not the grid itself.
        let grid = prebuiltGrid ?? buildGuideGridHTML(state: state)
        cachedGridHTML = grid
        // These two still have to run serially — buildHTML reads MainActor-isolated `state`.
        let html = Data(buildHTML(state: state, prebuiltGrid: grid, includeVerticalCSS: false).utf8)
        // Skip building/caching the vertical variant on installs that have never actually hit
        // /vertical (see verticalRouteEverRequested) — no point paying for it on every rebuild
        // when nobody's asked for it. The route handler builds it live (and flips the flag) on
        // its own first hit.
        guard verticalRouteEverRequested else {
            cachedHTML = html
            cachedHTMLGzip = Self.gzip(html)
            cachedVerticalHTML = nil
            cachedVerticalHTMLGzip = nil
            let gzKB = (cachedHTMLGzip?.count ?? 0) / 1024
            glog("[WebServer] page HTML cached (\(html.count / 1024)KB, \(gzKB)KB gzip'd)")
            return
        }
        let vHtml = Data(buildHTML(state: state, prebuiltGrid: grid, includeVerticalCSS: true).utf8)
        // Self.gzip only touches plain Data, so — unlike the builds above — the two compressions
        // are independent and can run concurrently instead of doubling this function's blocking
        // time on @MainActor for every guide-changing broadcast (add/delete/pause/resume/edit/
        // favorite-toggle/recording start-stop). Each concurrentPerform iteration writes a
        // distinct, non-overlapping pointer slot, so this is safe despite the raw pointer not
        // itself being Sendable-checked — wrapped below to state that guarantee explicitly.
        struct UncheckedSendableBox<T>: @unchecked Sendable { let ptr: UnsafeMutablePointer<T> }
        let payloads = [html, vHtml]
        let rawResults = UnsafeMutablePointer<Data?>.allocate(capacity: 2)
        rawResults.initialize(repeating: nil, count: 2)
        defer { rawResults.deinitialize(count: 2); rawResults.deallocate() }
        let box = UncheckedSendableBox(ptr: rawResults)
        DispatchQueue.concurrentPerform(iterations: 2) { i in
            box.ptr[i] = Self.gzip(payloads[i])
        }
        cachedHTML             = html
        cachedHTMLGzip         = rawResults[0]
        cachedVerticalHTML     = vHtml
        cachedVerticalHTMLGzip = rawResults[1]
        let gzKB = (cachedHTMLGzip?.count ?? 0) / 1024
        glog("[WebServer] page HTML cached (\(html.count / 1024)KB, \(gzKB)KB gzip'd)")
    }

    // Kept as a distinctly-named entry point for the hourly guide refresh (its one caller) even
    // though broadcastGuideChangeEvent now does the same cachedHTML rebuild for every guide-change
    // event — the name documents that this specific call site's `state` reflects a freshly-loaded
    // guide window, not just a schedule tweak.
    @MainActor
    func refreshPageAndBroadcastGuideChange(type: String, state: AppState) {
        broadcastGuideChangeEvent(type: type, state: state)
    }

    // Static so the DateFormatter is allocated once, not on every GET /.
    private static let hourFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current)
        return f
    }()

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

        // noDelay=true disables Nagle's algorithm so response bytes are flushed immediately
        // instead of being held waiting for more data to coalesce (important for large HTML pages).
        let tcpOpts = NWProtocolTCP.Options()
        tcpOpts.noDelay = true
        let tcpParams = NWParameters(tls: nil, tcp: tcpOpts)
        guard let l = try? NWListener(using: tcpParams, on: nwPort) else {
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
                    DispatchQueue.main.async { [weak self] in self?.stateCallback?(ok ? nil : "Server started but did not respond to /api/ping") }
                }
            case .failed(let err):
                glog("[WebServer] Failed: \(err)", level: .error)
                DispatchQueue.main.async { [weak self] in self?.stateCallback?(err.localizedDescription) }
            case .cancelled:
                // Fires for both intentional stop() and OS-level teardown.
                // stop() nils stateCallback first, so intentional stops are silent here.
                glog("[WebServer] Listener cancelled")
                DispatchQueue.main.async { [weak self] in self?.stateCallback?("Listener stopped unexpectedly") }
            default:
                break
            }
        }

        l.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }

        // Advertise via mDNS so browsers on the LAN discover the server without knowing the IP.
        // NWListener owns the advertisement — listener?.cancel() in stop() withdraws it automatically.
        l.service = NWListener.Service(name: "hdhrVCRplus", type: "_http._tcp", domain: nil,
                                       txtRecord: NWTXTRecord(["path": "/"]))
        l.serviceRegistrationUpdateHandler = { change in
            switch change {
            case .add(let ep):    glog("[WebServer] mDNS registered: \(ep)")
            case .remove(let ep): glog("[WebServer] mDNS withdrawn: \(ep)")
            @unknown default:     break
            }
        }

        l.start(queue: queue)
        listener = l
    }

    func stop() {
        guard listener != nil else { return }
        stateCallback = nil   // prevent the .cancelled callback from surfacing as an error
        sseLock.lock()
        let dyingSSE = sseConns; sseConns.removeAll()
        sseLock.unlock()
        for c in dyingSSE { c.cancel() }
        // Close every live connection too — kept-alive connections outlive their response, so
        // without this a warm client keeps being served (including state-mutating POSTs) after
        // the server is "stopped". cancel() is idempotent, so double-cancelling an SSE conn is fine.
        connLock.lock()
        let dying = liveConns; liveConns.removeAll()
        connLock.unlock()
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

    // Push a recording state-change event with pre-built HTML fragments so connected clients
    // can update #sum-ph, the affected tuner's ▾ dropdown (#tdrop-{device}), and the guide
    // row recording dot without a full page fetch.
    // `prebuiltGrid` lets a caller that's already building the grid for a paired
    // broadcastGuideChangeEvent call (see broadcastRecordingStopped) hand it in here too, so the
    // cache-refresh below reuses it instead of paying for buildGuideGridHTML a second time.
    // `refreshPageCache` lets a caller that's about to immediately follow up with its own full
    // rebuild (deleteShow, via broadcastRecordingStopped's alsoRebuildGrid: false) skip this
    // cache refresh entirely, since the upcoming rebuild will already reflect the post-teardown
    // state — this event's fragment fields are still broadcast either way.
    @MainActor
    func broadcastRecordingEvent(type: String, channel: String, device: String, state: AppState,
                                  prebuiltGrid: String? = nil, refreshPageCache: Bool = true) {
        // activeTunerCount folds in the in-app VLC stream + externally-used tuners (status.json),
        // so the pushed badge matches the page render instead of undercounting to recordings alone.
        let active = state.activeTunerCount(for: device)
        let total  = state.devices.first(where: { $0.DeviceID == device })?.TunerCount ?? 0
        broadcastEvent([
            "type":     type,
            "channel":  channel,
            "device":   device,
            "tunerA":   active,
            "tunerT":   total,
            "sumPh":    buildSumPhHTML(state: state),
            "tdropDev": device,
            "tdrop":    buildTunerShowsHTML(state: state, deviceId: device)
        ])
        // Connected tabs get the class-toggle patch above without a grid rebuild, but the cached
        // full-page HTML (served to any *new* page load — a fresh tab, hard refresh, or reopening
        // the native Guide window) was previously only rebuilt on the hourly guide refresh, so a
        // just-started recording wouldn't show its marker until then. Keep it in sync here too.
        guard refreshPageCache else { return }
        prebuildPageHTML(state: state, prebuiltGrid: prebuiltGrid)
    }

    // Combines the fragment-patch broadcast above with the full-grid broadcastGuideChangeEvent
    // teardownRecordingState also needs (see its call site) — builds the grid once and shares it
    // between both instead of each independently calling buildGuideGridHTML, which used to cost
    // two full grid+gzip passes (1300+ program blocks each) for every recording stop.
    // `alsoRebuildGrid: false` (deleteShow's use, when the show being torn down is about to be
    // removed and re-broadcast anyway) skips the guide-change broadcast and its cache refresh
    // entirely — that imminent follow-up rebuild will already reflect the post-teardown state, so
    // this intermediate one would just be overwritten before any client could act on it.
    @MainActor
    func broadcastRecordingStopped(channel: String, device: String, state: AppState, alsoRebuildGrid: Bool = true) {
        guard alsoRebuildGrid else {
            broadcastRecordingEvent(type: "recording_stopped", channel: channel, device: device,
                                     state: state, refreshPageCache: false)
            return
        }
        let grid = buildGuideGridHTML(state: state)
        broadcastRecordingEvent(type: "recording_stopped", channel: channel, device: device,
                                 state: state, prebuiltGrid: grid)
        broadcastGuideChangeEvent(type: "recording_stopped",
                                   extra: ["channel": channel, "device": device],
                                   state: state, prebuiltGrid: grid)
    }

    // Full grid + summary + per-tuner dropdown fragments — same shape /api/guide-refresh
    // returns. Shared by that route and broadcastGuideChangeEvent so a rebuild triggered by
    // a state change happens once server-side, not once per fetch. `prebuiltGrid` lets a
    // caller that already built the grid for another purpose (see
    // refreshPageAndBroadcastGuideChange) reuse it instead of rebuilding it a second time.
    // Every device ID buildDevBarHTML renders a tuner box (and therefore a #tdrop-{id} dropdown
    // element) for: usable (discovered + reachable) devices, plus any device referenced by a
    // show's hdhr_record even when it's unusable or was never discovered at all — see CLAUDE.md's
    // "Web guide offline devices" invariant. guide.js's applyGuidePayload only updates a dropdown
    // whose device key is present in the pushed tdrop payload (never clears/flags a missing one),
    // so buildGuideRefreshPayload must cover this same set — not just usableDeviceIDs — or an
    // offline/undiscovered device's dropdown goes stale after an edit/delete/pause/resume and can
    // never self-heal (a never-discovered device has no "come back online" moment to trigger a
    // full rebuild).
    @MainActor
    func tdropDeviceIDs(state: AppState) -> Set<String> {
        state.usableDeviceIDs.union(state.shows.map(\.hdhr_record).filter { !$0.isEmpty })
    }

    @MainActor
    private func buildGuideRefreshPayload(state: AppState, prebuiltGrid: String? = nil) -> [String: Any] {
        let grid = prebuiltGrid ?? buildGuideGridHTML(state: state)
        let sumph = buildSumPhHTML(state: state)
        var tdropBodies: [String: String] = [:]
        for dev in tdropDeviceIDs(state: state) {
            tdropBodies[dev] = buildTunerShowsHTML(state: state, deviceId: dev)
        }
        return ["grid": grid, "sumph": sumph, "tdrop": tdropBodies]
    }

    // Push a state-change event with the grid/summary/tuner-dropdown HTML embedded, computed
    // once here instead of every connected tab independently re-fetching /api/guide-refresh
    // and rebuilding the same grid. Mirrors broadcastRecordingEvent's fragment-embedding pattern.
    // `extra` carries whatever identifying fields the caller used before (channel/device,
    // or device/guideNumber for favorite_toggled) — merged in verbatim.
    @MainActor
    func broadcastGuideChangeEvent(type: String, extra: [String: Any] = [:], state: AppState, prebuiltGrid: String? = nil) {
        let grid = prebuiltGrid ?? buildGuideGridHTML(state: state)
        var event = extra
        event["type"] = type
        for (k, v) in buildGuideRefreshPayload(state: state, prebuiltGrid: grid) { event[k] = v }
        broadcastEvent(event)
        // Keep the cached full-page HTML (served to any new page load) in sync with every
        // guide-changing event, not just the hourly refresh — see broadcastRecordingEvent for
        // the same reasoning on the recording-start/stop path.
        prebuildPageHTML(state: state, prebuiltGrid: grid)
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
            // Push fresh live tuner counts so the newly-connected client gets accurate
            // occupancy immediately instead of waiting for the next recording event or idle tick.
            Task { [weak self] in await self?.pushFreshTunerCounts() }
        }))
    }

    // Push a tuner_update SSE event so newly-connected clients get accurate occupancy immediately.
    // Uses activeTunerCount (same source as broadcastRecordingEvent) so the count includes the
    // in-app VLC stream + externally-used tuners, not recordings alone.
    @MainActor
    private func pushFreshTunerCounts() async {
        guard let state = appState else { return }
        var counts: [String: Any] = [:]
        for device in state.devices {
            let active = state.activeTunerCount(for: device.DeviceID)
            counts[device.DeviceID] = ["a": active, "t": device.TunerCount ?? 0]
        }
        guard !counts.isEmpty else { return }
        broadcastEvent(["type": "tuner_update", "counts": counts])
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

    // MARK: - Watch Now (recording playback relay)
    //
    // VLC's plain file:// access module snapshots a file's length when the media is opened and
    // won't read past that offset even though curl keeps appending to it — so pointing VLC directly
    // at an in-progress recording stalls/ends early once playback catches up to where it started.
    // Framing the recording as an open-ended HTTP response instead (no Content-Length, connection
    // held open, bytes drip-fed as they land on disk) mirrors exactly how the real HDHomeRun tuner
    // stream already works, which VLC already handles fine. show_recording_path never moves once
    // recording starts (AppState writes directly to the final output path — see docs/AppState.md).
    // `start` is an app-level byte offset (not an RFC 7233 Range header) computed by
    // AppState.seekRecording(_:) from an approximate bytes-per-second estimate — the recording
    // has no index, so this is an approximate scrub, not a frame-accurate seek.
    private func handleWatchRecording(showId: String, startOffset: Int, conn: NWConnection) {
        guard !showId.isEmpty, let state = appState else {
            send(.badRequest("missing show id"), on: conn); return
        }
        Task { @MainActor in
            // Only the show_id lookup and property read happen on the MainActor — both in-memory,
            // no I/O. The fileExists check and all of streamGrowingFile's disk I/O (FileHandle
            // open/seek) are dispatched to `fileIOQueue` below (not `queue`, which every other
            // client's request/response and SSE keepalive also runs on) so a slow/contended
            // recording volume can't stall the main thread — or the rest of the web server — on
            // every watch-recording connection (including every scrub-bar commit, which
            // reconnects through this same path).
            // show_recording gates this on top of the path check: show_recording_path is set once
            // when recording starts and is never cleared when it ends, so without this a finished
            // recording's show_id (visible in plain data-show-id attributes across the served guide
            // HTML) could be replayed to stream that file indefinitely to any LAN client, long after
            // the "Watch Now!" relay this route exists for was ever actually live.
            guard let show = state.shows.first(where: { $0.show_id == showId }),
                  show.show_recording, !show.show_recording_path.isEmpty else {
                self.send(.notFound("recording not found"), on: conn)
                return
            }
            let path = show.show_recording_path
            self.fileIOQueue.async {
                guard FileManager.default.fileExists(atPath: path) else {
                    self.queue.async { self.send(.notFound("recording not found"), on: conn) }
                    return
                }
                self.streamGrowingFile(path: path, showId: showId, startOffset: startOffset, conn: conn)
            }
        }
    }

    // Called on fileIOQueue (see handleWatchRecording) — FileHandle open/seek/attributesOfItem
    // can all block on a slow/contended volume, same reasoning as the read loop in
    // pumpGrowingFile below. Hops back to `queue` only for the actual NWConnection send.
    private func streamGrowingFile(path: String, showId: String, startOffset: Int, conn: NWConnection) {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            queue.async { self.send(.notFound("could not open recording file"), on: conn) }
            return
        }
        var initialBytes = 0
        if startOffset > 0 {
            // Clamp to the file's current size so a stale/racy offset (e.g. computed just before
            // the recording restarted) can't seek past EOF — it'll just enter the normal
            // wait-for-more-data poll below instead of erroring.
            let currentSize = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int
            let clamped = min(startOffset, currentSize ?? startOffset)
            handle.seek(toFileOffset: UInt64(max(0, clamped)))
            initialBytes = clamped
        }
        let header = "HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
        glog("[WebServer] watch-recording OPEN show=\(showId) path=\(path) startOffset=\(initialBytes)")
        queue.async { [weak self] in
            conn.send(content: Data(header.utf8), completion: .contentProcessed({ [weak self] err in
                guard let self, err == nil else {
                    self?.fileIOQueue.async { handle.closeFile() }
                    glog("[WebServer] watch-recording header send failed show=\(showId): \(String(describing: err))", level: .warning)
                    return
                }
                self.pumpGrowingFile(handle: handle, showId: showId, conn: conn,
                                      bytesSent: initialBytes, waitStreak: 0, waitStartedAt: nil)
            }))
        }
    }

    // 200 MPEG-TS packets (188 bytes each) per read — keeps TS packet alignment without
    // materially affecting latency.
    private static let watchRecordingChunkSize = 188 * 200

    // Runs on `queue` (called from streamGrowingFile's send completion, or its own recursive
    // re-entry points below — both always on `queue`). Only the conn.state check and orchestration
    // happen here; the actual blocking handle.readData(ofLength:) is dispatched to fileIOQueue via
    // handleGrowingFileChunk's continuation, so a stalled/contended recording volume only stalls
    // this one relay connection, never the whole web server. Recurses via fileIOQueue.async (read)
    // → queue.async (send) rather than looping in place, so each step yields back to both queues
    // between file reads and socket sends.
    private func pumpGrowingFile(handle: FileHandle, showId: String, conn: NWConnection,
                                  bytesSent: Int, waitStreak: Int, waitStartedAt: Date?) {
        // Checked once per recursion (covers both the "have data" and "waiting" paths below) —
        // without this, a connection cancelled while the loop is in its 0.5s wait-for-more-data
        // poll (the common state once caught up to the live edge) wouldn't be noticed until a
        // conn.send() was actually attempted, which only happens once new bytes arrive.
        switch conn.state {
        case .cancelled, .failed:
            glog("[WebServer] watch-recording show=\(showId) connection no longer alive at \(bytesSent) bytes — stopping")
            fileIOQueue.async { handle.closeFile() }
            return
        default:
            break
        }
        fileIOQueue.async { [weak self] in
            guard let self else { return }
            let chunk = handle.readData(ofLength: Self.watchRecordingChunkSize)
            self.queue.async {
                self.handleGrowingFileChunk(chunk, handle: handle, showId: showId, conn: conn,
                                             bytesSent: bytesSent, waitStreak: waitStreak, waitStartedAt: waitStartedAt)
            }
        }
    }

    // The continuation of pumpGrowingFile once a chunk (or an empty read, meaning "caught up to
    // EOF for now") comes back from fileIOQueue — always runs on `queue`, same as the rest of this
    // file's connection handling.
    private func handleGrowingFileChunk(_ chunk: Data, handle: FileHandle, showId: String, conn: NWConnection,
                                         bytesSent: Int, waitStreak: Int, waitStartedAt: Date?) {
        guard !chunk.isEmpty else {
            // Caught up to what curl has written so far — poll until either more data lands or
            // the recording finishes, instead of ending the stream the moment we hit today's EOF.
            Task { @MainActor [weak self] in
                guard let self else { return }
                let stillRecording = self.appState?.shows.first(where: { $0.show_id == showId })?.show_recording ?? false
                if stillRecording {
                    let startedAt = waitStartedAt ?? Date()
                    if waitStreak == 0 {
                        glog("[WebServer] watch-recording show=\(showId) caught up to live edge at \(bytesSent) bytes — waiting for more data")
                    }
                    self.queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.pumpGrowingFile(handle: handle, showId: showId, conn: conn,
                                               bytesSent: bytesSent, waitStreak: waitStreak + 1, waitStartedAt: startedAt)
                    }
                } else {
                    glog("[WebServer] watch-recording show=\(showId) recording finished, drained \(bytesSent) bytes — closing stream")
                    self.fileIOQueue.async { handle.closeFile() }
                    conn.cancel()
                }
            }
            return
        }
        if waitStreak > 0, let waitStartedAt {
            glog("[WebServer] watch-recording show=\(showId) resumed after \(String(format: "%.1f", Date().timeIntervalSince(waitStartedAt)))s wait (\(waitStreak) polls)")
        }
        let newTotal = bytesSent + chunk.count
        if newTotal / (5 * 1_048_576) > bytesSent / (5 * 1_048_576) {
            glog("[WebServer] watch-recording show=\(showId) sent \(newTotal / 1_048_576) MB so far")
        }
        conn.send(content: chunk, completion: .contentProcessed({ [weak self] err in
            guard let self, err == nil else {
                self?.fileIOQueue.async { handle.closeFile() }
                glog("[WebServer] watch-recording show=\(showId) client disconnected after \(newTotal) bytes: \(String(describing: err))")
                return
            }
            self.queue.async {
                self.pumpGrowingFile(handle: handle, showId: showId, conn: conn,
                                      bytesSent: newTotal, waitStreak: 0, waitStartedAt: nil)
            }
        }))
    }

    // MARK: - Connection handling
    //
    // HTTP/1.1 keep-alive: a connection stays open across multiple requests unless the client
    // sends "Connection: close". This matters far more on a real LAN client than it looks like on
    // localhost — every request without keep-alive pays a full TCP handshake (SYN/SYN-ACK/ACK)
    // before any HTTP bytes can move, and the guide page's initial load fires ~20 lazy /api/guide-
    // detail requests (see WebServer.md's Lazy heavy-data loading section) that would otherwise
    // each open a brand-new connection. idleCloseSeconds bounds every state where the server is
    // waiting on the client (initial connect, mid-request, and between kept-alive requests), so a
    // slow/silent/abandoned client can't pin a socket open forever.
    private static let idleCloseSeconds: Double = 30

    private func handleConnection(_ conn: NWConnection) {
        guard isLocalAddress(conn.endpoint) else {
            conn.cancel()
            glog("[WebServer] Rejected non-LAN connection from \(conn.endpoint)")
            return
        }
        connLock.lock(); liveConns.append(conn); connLock.unlock()
        // Deregister from liveConns exactly once, from whichever path cancels the connection
        // (idle timer, client disconnect, send-with-close, or stop()).
        conn.stateUpdateHandler = { [weak self] st in
            switch st {
            case .cancelled, .failed:
                self?.connLock.lock(); self?.liveConns.removeAll { $0 === conn }; self?.connLock.unlock()
            default: break
            }
        }
        conn.start(queue: queue)
        accumulate(conn: conn, buffer: Data())
    }

    // Read until we have the full HTTP request (headers + Content-Length body bytes).
    private static let maxRequestBytes = 1 << 17  // 128 KB — enough for any guide/record JSON; caps memory growth from slow/malicious LAN clients
    private static let httpSep = Data([0x0d, 0x0a, 0x0d, 0x0a])  // \r\n\r\n as a static constant so accumulate() doesn't allocate it on every callback
    private func accumulate(conn: NWConnection, buffer: Data) {
        // Arm an idle-close for THIS wait: if the client sends nothing more within
        // idleCloseSeconds, cancel the connection. Cancelled the instant real bytes arrive below,
        // then a fresh one is armed by the next accumulate() call — so every wait state (initial
        // connect, partial request, between kept-alive requests) is uniformly bounded.
        let idle = DispatchWorkItem { conn.cancel() }
        queue.asyncAfter(deadline: .now() + Self.idleCloseSeconds, execute: idle)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, _, _ in
            idle.cancel()
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

            // Parse Content-Length, Accept-Encoding, and Connection from headers
            let headerText    = String(data: headerSection, encoding: .utf8) ?? ""
            var contentLength = 0
            var acceptsGzip   = false
            var explicitClose = false
            for line in headerText.components(separatedBy: "\r\n").dropFirst() {
                let lower = line.lowercased()
                if lower.hasPrefix("content-length:") {
                    contentLength = Int(lower.dropFirst("content-length:".count)
                                           .trimmingCharacters(in: .whitespaces)) ?? 0
                } else if lower.hasPrefix("accept-encoding:"), lower.contains("gzip") {
                    acceptsGzip = true
                } else if lower.hasPrefix("connection:"), lower.contains("close") {
                    explicitClose = true
                }
            }

            // Early rejection on an oversized Content-Length prevents waiting to accumulate
            // the full body before discovering it exceeds the limit.
            if contentLength > Self.maxRequestBytes {
                self.send(.payloadTooLarge("Request body too large"), on: conn)
                return
            }
            // A negative Content-Length (client sent "-1", or a malformed value) would make the
            // dropFirst(contentLength) below trap and crash the app — reject it, and close (the
            // request framing is untrustworthy so the connection can't be safely reused).
            if contentLength < 0 {
                self.send(.badRequest("Invalid Content-Length"), on: conn)
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
            let httpVersion = parts.count >= 3 ? parts[2] : "HTTP/1.0"
            let cleanPath   = path.components(separatedBy: "?").first ?? path
            let body: Data? = contentLength > 0 ? Data(bodyBytes.prefix(contentLength)) : nil

            // Leftover bytes past this request's body (contentLength is guaranteed 0…bodyBytes.count
            // by the checks above, so dropFirst can't trap). Their presence means the client sent
            // more than one request in a single write, or a body we didn't frame (chunked, bad
            // Content-Length) — either way we don't safely reuse the connection below.
            let leftover = bodyBytes.dropFirst(contentLength)

            if cleanPath == "/api/events" && method == "GET" {
                self.registerSSE(conn); return
            }
            if cleanPath == "/api/watch-recording" && method == "GET" {
                let query = URLComponents(string: path)?.queryItems ?? []
                let showId = query.first(where: { $0.name == "show" })?.value ?? ""
                let startOffset = query.first(where: { $0.name == "start" }).flatMap { Int($0.value ?? "") } ?? 0
                self.handleWatchRecording(showId: showId, startOffset: max(0, startOffset), conn: conn); return
            }
            // Reuse the connection only when we fully understand the request's framing and the
            // response is safe to follow with another: HTTP/1.1, a method whose response body the
            // client expects (GET/POST — not HEAD), no unparsed leftover/pipelined bytes, and the
            // client didn't opt out. Anything else falls back to the pre-keep-alive default of
            // closing after the response — which is what makes HEAD, HTTP/1.0 EOF-framed clients,
            // pipelined requests, and mis-framed bodies safe instead of desyncing the socket.
            let keepAlive = !explicitClose
                && httpVersion == "HTTP/1.1"
                && (method == "GET" || method == "POST")
                && leftover.isEmpty
            Task {
                let response = await self.route(method: method, path: cleanPath, body: body)
                self.send(response, on: conn, acceptsGzip: acceptsGzip, keepAlive: keepAlive)
            }
        }
    }

    // MARK: - Routing

    private func route(method: String, path: String, body: Data?) async -> WebResponse {
        return await MainActor.run { routeOnMain(method: method, path: path, body: body) }
    }

    @MainActor
    private func routeOnMain(method: String, path: String, body: Data?) -> WebResponse {
        guard let state = appState else { return .notFound("App state unavailable") }

        // POST routes
        if method == "POST" {
            if path == "/api/record"           { return handleRecord(state: state, body: body) }
            if path == "/api/delete"           { return handleDelete(state: state, body: body) }
            if path == "/api/edit"             { return handleEdit(state: state, body: body) }
            if path == "/api/toggle-favorite"  { return handleToggleFavorite(state: state, body: body) }
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
            if let html = cachedHTML, let gz = cachedHTMLGzip {
                return .okPrecompressed(contentType: "text/html; charset=utf-8", raw: html, gzip: gz)
            }
            // Cache not warm yet (before the first guide load) — fall back to a live build; send()
            // gzips this one on the fly same as before.
            let body = Data(buildHTML(state: state, includeVerticalCSS: false).utf8)
            return .ok(contentType: "text/html; charset=utf-8", body: body)

        // Orientation-responsive: portrait transposes the grid, landscape looks identical to
        // "/". GET / never carries the vertical stylesheet at all (see buildHTML's
        // includeVerticalCSS), so it can't show the vertical layout no matter how the phone is
        // held — only this route can.
        case "/vertical":
            if let html = cachedVerticalHTML, let gz = cachedVerticalHTMLGzip {
                return .okPrecompressed(contentType: "text/html; charset=utf-8", raw: html, gzip: gz)
            }
            // Nothing cached — either the very first hit ever (prebuildPageHTML skips this
            // variant until verticalRouteEverRequested flips true) or a hit landing in the
            // window between that flip and the next rebuild. Build+gzip once here, cache it
            // immediately so subsequent hits before the next rebuild are also served from
            // cache, and flag that this route has real traffic.
            verticalRouteEverRequested = true
            let body = Data(buildHTML(state: state, includeVerticalCSS: true).utf8)
            let gz = Self.gzip(body)
            cachedVerticalHTML = body
            cachedVerticalHTMLGzip = gz
            if let gz {
                return .okPrecompressed(contentType: "text/html; charset=utf-8", raw: body, gzip: gz)
            }
            return .ok(contentType: "text/html; charset=utf-8", body: body)

        case "/api/ping":
            // "version" (the build stamp) is load-bearing — guide.js's checkFreshness() compares
            // it against the page's baked-in _ver to detect a redeploy and reload. "release"/
            // "buildNumber" are additive, read-only identity fields (only set by deploy_release.sh;
            // a dev deploy.sh build leaves them at whatever the last release left behind) — safe to
            // add without touching the field client code already keys off.
            let release = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
            let pingBody = Data("{\"ok\":true,\"version\":\"\(appVersion)\",\"release\":\"\(release)\",\"buildNumber\":\"\(buildNumber)\"}".utf8)
            return .ok(contentType: "application/json", body: pingBody)

        case "/api/guide-refresh":
            // Reuses the grid built by the most recent guide-changing broadcast (kept fresh by
            // prebuildPageHTML, called from every one of those) instead of paying for another
            // full buildGuideGridHTML pass here — this route is only ever a fallback for an SSE
            // event type that didn't already carry the grid inline (see guide.js's refreshGuide),
            // so nothing between that broadcast and this request could have changed it.
            return jsonResponse(buildGuideRefreshPayload(state: state, prebuiltGrid: cachedGridHTML))

        case "/api/now.json":
            let data = buildNowJSON(state: state)
            return .ok(contentType: "application/json", body: data)

        case "/api/signal":
            var out: [String: String] = [:]
            for (key, bucket) in ChannelSignalStore.shared.buckets { out[key] = bucket.rawValue }
            let data = (try? JSONSerialization.data(withJSONObject: out)) ?? Data("{}".utf8)
            return .ok(contentType: "application/json", body: data)

        case "/favicon.ico":
            if let url = Bundle.main.url(forResource: "favicon", withExtension: "ico"),
               let data = try? Data(contentsOf: url) {
                return .ok(contentType: "image/x-icon", body: data)
            }
            return .notFound("favicon not found")

        case "/api/icon":
            if let png = cachedIconPNG {
                return .ok(contentType: "image/png", body: png)
            }
            return .notFound("icon not found")

        default:
            if path.hasPrefix("/api/now-airing/") {
                // /api/now-airing/{devId}/{channelNum} — returns currently-airing guide entry as JSON
                let tail  = path.dropFirst("/api/now-airing/".count)
                let parts = tail.split(separator: "/", maxSplits: 1)
                guard parts.count == 2 else { return .notFound("bad params") }
                let devId = String(parts[0]).removingPercentEncoding ?? String(parts[0])
                let ch    = String(parts[1]).removingPercentEncoding ?? String(parts[1])
                let now   = Int(Date().timeIntervalSince1970)
                let airing = state.guideStore.entries(deviceId: devId, channelNum: ch,
                    after: Date(timeIntervalSince1970: TimeInterval(now - 7200)))
                    .first { $0.StartTime <= now && $0.EndTime > now }
                let result: [String: Any] = [
                    "title":   airing?.Title ?? "",
                    "epTitle": airing?.EpisodeTitle ?? "",
                    "poster":  airing?.ImageURL ?? "",
                    "endTime": airing.map { String($0.EndTime) } ?? ""
                ]
                return jsonResponse(result)
            }
            if path.hasPrefix("/api/airings/") {
                // /api/airings/{seriesId} — up to 4 upcoming episodes of a series across all
                // devices/channels, for the web Record modal's "Other Upcoming Airings" preview.
                // Mirrors the native otherAirings computed property in AddShowView.swift.
                let seriesId = String(path.dropFirst("/api/airings/".count)).removingPercentEncoding ?? ""
                let items: [[String: Any]] = state.upcomingGuideEpisodes(seriesID: seriesId).map { pair in
                    let chName = state.lineups[pair.entry.deviceId]?
                        .first(where: { $0.GuideNumber == pair.channel })?.GuideName
                    let logoURL = state.channelImageURLs["\(pair.entry.deviceId):\(pair.channel)"] ?? ""
                    return ["start": pair.entry.StartTime, "end": pair.entry.EndTime, "ch": pair.channel,
                            "chName": chName ?? "", "ep": pair.entry.episodeInfoLabel ?? "",
                            "device": pair.entry.deviceId, "genre": pair.entry.firstGenre ?? "",
                            "chLogo": logoURL, "title": pair.entry.Title]
                }
                return jsonResponse(["airings": items])
            }
            if path.hasPrefix("/api/guide-detail/") {
                // /api/guide-detail/{devId}/{channelNum}/{winStart}/{winSec} — heavy fields
                // (Synopsis/poster/episode/air date) for every entry currently in that channel's
                // guide window, batched per row. Lazily fetched by the client's IntersectionObserver
                // once a row scrolls into view — these fields are deliberately omitted from the
                // initial grid HTML (see buildGuideGridHTML). The trailing winStart/winSec segments
                // are the client's own _winStart/_winSec (the window its DOM was actually rendered
                // against) so a fetch long after page load answers for that window instead of
                // silently drifting with "now" and omitting entries that have since aged out —
                // falls back to the server's current window if those segments are missing/malformed.
                let tail  = path.dropFirst("/api/guide-detail/".count)
                let parts = tail.split(separator: "/")
                guard parts.count >= 2 else { return .notFound("bad params") }
                let devId = String(parts[0]).removingPercentEncoding ?? String(parts[0])
                let ch    = String(parts[1]).removingPercentEncoding ?? String(parts[1])
                let winStart: Int
                let winSec: Int
                // Clamp to sane ranges before use — a well-formed-but-absurd value (e.g. Int.max)
                // would overflow the winStart+winSec addition below and trap the whole process.
                let tenYears = 10 * 365 * 24 * 3600
                let nowTs = Int(Date().timeIntervalSince1970)
                if parts.count >= 4, let clientStart = Int(parts[2]), let clientSec = Int(parts[3]),
                   (nowTs - tenYears)...(nowTs + tenYears) ~= clientStart,
                   (1...(28 * 3600)) ~= clientSec {
                    (winStart, winSec) = (clientStart, clientSec)
                } else {
                    (winStart, winSec) = guideWindow(state: state)
                }
                let winEnd = winStart + winSec
                let entries = entriesInWindow(state: state, deviceId: devId, channelNum: ch,
                                               winStart: winStart, winEnd: winEnd)
                let items: [[String: Any]] = entries.map { e in
                    let synAttr  = String((e.Synopsis ?? "").replacingOccurrences(of: "\n", with: " ").prefix(220))
                    let dateAttr = e.OriginalAirdate.map {
                        origAirdateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval($0)))
                    } ?? ""
                    return ["start": e.StartTime, "syn": synAttr, "poster": e.ImageURL ?? "",
                            "ep": e.episodeInfoLabel ?? "", "date": dateAttr]
                }
                return jsonResponse(["entries": items])
            }
            if path.hasPrefix("/api/signal-stats/") {
                // /api/signal-stats/{guideName} — full signal stats for one channel, used by the
                // tuner popover to show recordability inline per active tuner. Empty {} if no samples.
                let name = String(path.dropFirst("/api/signal-stats/".count)).removingPercentEncoding ?? ""
                guard let s = ChannelSignalStore.shared.stats(guideName: name) else {
                    return .ok(contentType: "application/json", body: Data("{}".utf8))
                }
                return jsonResponse([
                    "bucket":  s.bucket.rawValue,
                    "last":    s.last,
                    "avg":     s.avg,
                    "min":     s.min,
                    "max":     s.max,
                    "checked": Int(s.lastSampled.timeIntervalSince1970),  // epoch — client renders relative
                    "n":       s.windowCount,
                    "total":   s.totalCount
                ])
            }
            return .notFound("Not found: \(path)")
        }
    }

    // Schedules a single-episode recording for the guide entry identified by
    // deviceId + guideNumber + startTime in the POST body JSON.
    private func jsonResponse(_ dict: [String: Any]) -> WebResponse {
        .ok(contentType: "application/json",
            body: (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8))
    }

    private func parseJSONBody(_ body: Data?) -> [String: Any]? {
        guard let body else { return nil }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    @MainActor
    private func handleRecord(state: AppState, body: Data?) -> WebResponse {
        let json = jsonResponse
        guard let obj       = parseJSONBody(body),
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

        let showType = showStateFromString(obj["showType"] as? String ?? "")
        let activeTuners = state.deviceTunerOccupancy[deviceId]?.filter({ $0.VctNumber != nil }).count ?? 0
        let total        = device.TunerCount ?? 0
        // tunersFull() counts both active recordings and the in-app VLC stream; raw
        // deviceTunerOccupancy only reflects hardware status and misses VLC.
        let tunerFull    = state.tunersFull(for: deviceId)
        let nowTs        = Int(Date().timeIntervalSince1970)
        let recStarted   = entry.StartTime <= nowTs && entry.EndTime > nowTs
        let newActive    = recStarted && !tunerFull ? activeTuners + 1 : activeTuners
        let airDays   = obj["airDays"]   as? [String]
        let transcode = obj["transcode"] as? String
        let bonusTime = obj["bonusTime"] as? Bool ?? false
        let title     = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        state.addShowFromGuide(entry: entry, type: showType, device: device, channel: ch, airDays: airDays, transcode: transcode, bonusTime: bonusTime, titleOverride: title)
        let effectiveTitle = (title?.isEmpty == false) ? title! : entry.Title
        return json(["ok": true, "title": effectiveTitle, "tunerFull": tunerFull,
                     "recStarted": recStarted, "tunerActive": newActive, "tunerTotal": total])
    }

    // Removes the show that owns the guide entry identified by deviceId + guideNumber + title.
    // Stops any active recording and saves config, same as the in-app Delete flow.
    @MainActor
    private func handleDelete(state: AppState, body: Data?) -> WebResponse {
        let json = jsonResponse
        guard let obj = parseJSONBody(body)
        else { return .badRequest("Missing or invalid JSON body") }

        let showId   = obj["showId"]      as? String ?? ""
        let deviceId = obj["deviceId"]    as? String ?? ""
        let guideNum = obj["guideNumber"] as? String ?? ""
        let title    = obj["title"]       as? String ?? ""

        guard !showId.isEmpty || (!deviceId.isEmpty && !guideNum.isEmpty)
        else { return .badRequest("Missing required field: showId or (deviceId + guideNumber)") }

        // Primary: showId (from edit modal). Fallback: active recording on device+channel, then title match.
        // Both fallbacks must include deviceId — a multi-tuner setup can legitimately have two
        // devices each scheduled to record an identically-titled show on the same channel number,
        // and a title-only match would delete/stop the wrong tuner's show.
        let show: Show? = !showId.isEmpty
            ? state.shows.first(where: { $0.show_id == showId })
            : state.recordingShows.first(where: {
                  $0.hdhr_record == deviceId && $0.show_channel == guideNum
              }) ?? state.shows.first(where: {
                  $0.show_active &&
                  $0.hdhr_record == deviceId &&
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
        // deleteShow() already broadcasts show_deleted (with grid/summary/tuner fragments) —
        // don't double-broadcast here.
        state.deleteShow(show)
        return json(["ok": true, "title": show.show_title])
    }

    // Updates show type and/or pause state by showId. Called from the web edit modal.
    @MainActor
    private func handleEdit(state: AppState, body: Data?) -> WebResponse {
        let json = jsonResponse
        guard let obj    = parseJSONBody(body),
              let showId = obj["showId"] as? String,
              let show   = state.shows.first(where: { $0.show_id == showId })
        else { return .badRequest("Missing required field: showId") }

        var updated = show
        let allDays = Show.weekdayNames

        if let typeStr = obj["showType"] as? String {
            switch showStateFromString(typeStr) {
            case .single:
                updated.show_is_series = false; updated.show_use_seriesid = false; updated.show_use_seriesid_all = false
            case .dateTime:
                updated.show_is_series = true; updated.show_use_seriesid = false; updated.show_use_seriesid_all = false
                if updated.show_air_date.isEmpty { updated.show_air_date = allDays }
            case .seriesChannel:
                updated.show_is_series = true; updated.show_use_seriesid = true; updated.show_use_seriesid_all = false
                updated.show_air_date = allDays
            case .seriesAll:
                updated.show_is_series = true; updated.show_use_seriesid = true; updated.show_use_seriesid_all = true
                updated.show_air_date = allDays
            }
        }

        if let paused = obj["paused"] as? Bool {
            updated.show_paused = paused
            if paused {
                updated.show_fail_reason = "Manually paused"
            } else {
                updated.clearFailures()
                // Re-arm the "Up Next"/"Recording Soon" pre-notifications and clear any live
                // retry cooldown — same fix as AppState.applyResume/reactivatePausedShows, a gap
                // in that fix since this edit path builds a standalone `updated` Show value
                // (committed via state.updateShow(_:) below) rather than mutating state.shows by
                // index, so it never routed through the shared helper. showRetryAfter lives on
                // AppState, not Show, so it's cleared directly here rather than via `updated`.
                updated.notify_upnext_time = nil
                updated.notify_recording_time = nil
                state.showRetryAfter.removeValue(forKey: updated.show_id)
            }
        }
        if let title = obj["title"] as? String, !title.isEmpty { updated.show_title = title }
        if let ch = obj["channel"] as? String, !ch.isEmpty {
            // Validate the channel exists in this device's lineup before storing — this endpoint has
            // no auth beyond LAN-subnet matching, and an unvalidated channel silently yields a
            // failing recording (matches handleRecord/handleToggleFavorite's lineup check).
            guard state.lineups[updated.hdhr_record]?.first(where: { $0.GuideNumber == ch }) != nil else {
                return .badRequest("channel not found in device lineup")
            }
            updated.show_channel = ch
        }
        if let len = obj["length"] as? Int, len > 0 {
            // Cap at 24h — reject absurd/hostile lengths on this unauthenticated endpoint.
            guard len <= 1440 else { return .badRequest("length exceeds 24h maximum") }
            updated.show_length = len
        }
        if let bonus = obj["bonusTime"] as? Bool { updated.show_bonus_time = bonus }
        if let transcode = obj["transcode"] as? String { updated.show_transcode = transcode }
        // Web-guide escape hatch for the "will skip — already on disk" state (see docs/WebServer.md's
        // "Duplicate-episode override" note) — mirrors the native Add/Edit dialog's
        // show_ignore_duplicate_once toggle so a duplicate flagged in the browser isn't a dead end.
        if let ignoreDup = obj["ignoreDuplicateOnce"] as? Bool { updated.show_ignore_duplicate_once = ignoreDup }
        // Recording output directory is deliberately NOT settable from the web UI. This endpoint has
        // no auth beyond LAN-subnet matching, so accepting an arbitrary write path from any LAN host
        // is a security risk (redirecting where recordings land). Directory changes require local app
        // access. Any `saveDir` in the request body is ignored.
        if let airDays = obj["airDays"] as? [String] { updated.show_air_date = airDays }
        if let reset = obj["resetFailures"] as? Bool, reset { updated.clearFailures(); updated.show_active = true }

        state.updateShow(updated) // broadcasts "show_updated" itself
        // If the show was just promoted to a seriesID type, search the guide immediately
        // so show_next is set before the next idle loop tick.
        if updated.show_use_seriesid && !show.show_use_seriesid {
            Task { await state.rescheduleAllSeries() }
        }
        return json(["ok": true, "title": updated.show_title])
    }

    @MainActor
    private func handleToggleFavorite(state: AppState, body: Data?) -> WebResponse {
        let json = jsonResponse
        guard let obj      = parseJSONBody(body),
              let deviceId = obj["deviceId"]    as? String,
              let guideNum = obj["guideNumber"] as? String
        else { return .badRequest("Missing required fields: deviceId, guideNumber") }

        guard let device = state.devices.first(where: { $0.DeviceID == deviceId }),
              let ch     = state.lineups[deviceId]?.first(where: { $0.GuideNumber == guideNum })
        else { return json(["ok": false, "error": "Device or channel not found"]) }

        let newFav = !ch.isFavorite   // ch is a struct copy; capture before toggleFavorite mutates lineups
        state.toggleFavorite(device: device, channel: ch)
        broadcastGuideChangeEvent(type: "favorite_toggled",
                                  extra: ["device": deviceId, "guideNumber": guideNum],
                                  state: state)
        return json(["ok": true, "isFavorite": newFav])
    }

    // Internal (not private) so WebServerHelperTests can round-trip these against ShowState
    // directly — same reasoning as jsEscapeForScript below.
    func showTypeStr(_ show: Show) -> String {
        switch show.state {
        case .single:        return "single"
        case .dateTime:      return "dateTime"
        case .seriesChannel: return "seriesChannel"
        case .seriesAll:     return "seriesAll"
        }
    }

    func showStateFromString(_ s: String) -> ShowState {
        switch s {
        case "dateTime":      return .dateTime
        case "seriesChannel": return .seriesChannel
        case "seriesAll":     return .seriesAll
        default:              return .single
        }
    }

    // MARK: - HTML / JSON generation

    // Per-tuner show list for one device's ▾ dropdown: that tuner's own
    // Recording / Up Next / Scheduled / Paused shows. Empty → a friendly note.
    @MainActor
    private func buildTunerShowsHTML(state: AppState, deviceId: String) -> String {
        // Common row builder — embeds all data needed by openEditShow() JS.
        // chDetail: optional suffix appended to the Ch line (e.g. a relative-time span).
        func showRow(_ s: Show, recording: Bool = false, prefix: String = "", chDetail: String = "") -> String {
            let t = showTypeStr(s)
            let ad = s.show_air_date.joined(separator: ",")
            let nextEpoch = s.show_next.map { Int($0.timeIntervalSince1970) } ?? 0
            let da = "data-dev=\"\(he(s.hdhr_record))\" data-id=\"\(he(s.show_id))\" data-title=\"\(he(s.show_title))\" data-ch=\"\(he(s.show_channel))\" data-type=\"\(t)\" data-paused=\"\(s.show_paused ? 1 : 0)\" data-recording=\"\(recording ? 1 : 0)\" data-next=\"\(nextEpoch)\" data-length=\"\(s.show_length)\" data-bonus=\"\(s.show_bonus_time ? 1 : 0)\" data-transcode=\"\(he(s.show_transcode))\" data-seriesid=\"\(he(s.show_seriesid))\" data-airdays=\"\(he(ad))\" data-failcount=\"\(s.show_fail_count)\" data-failreason=\"\(he(s.show_fail_reason))\" data-ignoredup=\"\(s.show_ignore_duplicate_once ? 1 : 0)\""
            let endDetail = recording ? s.show_end.map { " · Ends \(state.shortTime($0))" } ?? "" : ""
            let chLine = chDetail.isEmpty
                ? "Ch \(he(s.show_channel))\(endDetail)"
                : "Ch \(he(s.show_channel)) · \(chDetail)"
            return "<div class=\"sp-row\" \(da) onclick=\"openEditShow(this)\">"
                 + "<div class=\"sp-info\">"
                 + "<div class=\"sp-t\">\(prefix)\(he(s.show_title))</div>"
                 + "<div class=\"sp-ch\">\(chLine)</div>"
                 + "</div>"
                 + "<button class=\"sp-jump\" onclick=\"event.stopPropagation();jumpToGuide(this.closest('.sp-row'))\" title=\"Jump to guide\">→</button>"
                 + "</div>"
        }

        func mine(_ s: Show) -> Bool { s.hdhr_record == deviceId }

        var parts: [String] = []

        let recs = state.recordingShows.filter(mine)
        if !recs.isEmpty {
            let rows = recs.map { showRow($0, recording: true, prefix: "<span class=\"sp-rec\">●</span> ") }.joined()
            parts.append("<div class=\"sp-sec\"><div class=\"sp-hdr\">Recording</div>\(rows)</div>")
        }

        // Sort by next air time ascending; shows without a date sort to the end.
        let sortedActive = state.activeShows
            .filter(mine)
            .sorted { ($0.show_next?.timeIntervalSince1970 ?? .infinity) < ($1.show_next?.timeIntervalSince1970 ?? .infinity) }
        let upNext     = sortedActive.first(where: { $0.show_next != nil })
        let restActive = sortedActive.filter { $0.show_id != upNext?.show_id }

        if let next = upNext {
            if !parts.isEmpty { parts.append("<div class=\"sp-div\"></div>") }
            let detail = "<span style=\"color:var(--ac)\">at \(he(state.shortTime(next.show_next)))</span>"
            parts.append("<div class=\"sp-sec\"><div class=\"sp-hdr\">Up Next</div>\(showRow(next, chDetail: detail))</div>")
        }

        if !restActive.isEmpty {
            if !parts.isEmpty { parts.append("<div class=\"sp-div\"></div>") }
            let rows = restActive.map { showRow($0) }.joined()
            parts.append("<div class=\"sp-sec\"><div class=\"sp-hdr\">Scheduled</div>\(rows)</div>")
        }

        let paused = state.pausedShows.filter(mine)
        if !paused.isEmpty {
            if !parts.isEmpty { parts.append("<div class=\"sp-div\"></div>") }
            let rows = paused.map { showRow($0, prefix: "<span style=\"color:var(--t4)\">⏸</span> ") }.joined()
            parts.append("<div class=\"sp-sec\"><div class=\"sp-hdr\">Paused</div>\(rows)</div>")
        }

        return parts.isEmpty ? "<div class=\"sp-empty\">No shows on this tuner.</div>" : parts.joined()
    }

    // Per-device tuner counts (total slots vs. currently occupied). Shared by buildHTML (feeds
    // the client-side `tuners` JS var) and buildDevBarHTML (feeds the server-rendered dropdown
    // badge) so the two can never define "active" differently — they used to each compute this
    // independently and had already drifted (only one copy carried the diagnostic glog line).
    private struct DevTuners { let total: Int; let active: Int; var isFull: Bool { total > 0 && active >= total } }

    @MainActor
    private static func computeDevTuners(state: AppState, logDiagnostics: Bool = false) -> [String: DevTuners] {
        var devTuners: [String: DevTuners] = [:]
        for d in state.devices {
            let total = d.TunerCount ?? 0
            let occupancy = state.deviceTunerOccupancy[d.DeviceID]
            // Use activeTunerCount = max(hardware occupancy, this app's recordings + VLC stream) so
            // the dev-bar badge agrees with the SSE tuner_update push. A bare VctNumber count would
            // undercount an in-app VLC stream or a just-started recording not yet in status.json,
            // and a deviceOnline/deviceOffline dev-bar swap would then clobber the pushed count.
            let active = state.activeTunerCount(for: d.DeviceID)
            if logDiagnostics {
                let occStr = occupancy.map { "\($0.count)" } ?? "nil"
                let recCount = state.recordingShows.filter { $0.hdhr_record == d.DeviceID }.count
                glog("[WebServer] buildHTML tuners \(d.DeviceID): occupancy=\(occStr) active=\(active)/\(total) recordingShows=\(recCount)")
            }
            devTuners[d.DeviceID] = DevTuners(total: total, active: active)
        }
        return devTuners
    }

    // Inner content of #dev-bar (one tuner box per discovered device + any offline/absent
    // device referenced by a scheduled show) — no outer wrapping div, so callers can either
    // embed it in buildHTML's full page or push it standalone for an innerHTML swap over SSE.
    // Factored out of buildHTML so a deviceOnline/deviceOffline event can push a fresh copy
    // instead of only updating on the next full page load.
    @MainActor
    private func buildDevBarHTML(state: AppState, devTuners: [String: DevTuners]) -> String {
        // Occupancy count, rendered inline inside the .d-btn label rather than as its own
        // clickable element — a second click on the (already-active) name button opens the
        // same detail popover this used to open on its own (see handleDevClick in guide.js).
        // Always emits the #tun-{devId} span (even empty) so the three live-update sites in
        // guide.js (tuner_update SSE, recording_started/stopped SSE, record-summary POST
        // response) keep a stable target regardless of whether tuner data has loaded yet.
        func tunerCountSpan(_ devId: String, _ dt: DevTuners?) -> String {
            guard let dt, dt.total > 0 else {
                return "<span id=\"tun-\(he(devId))\" class=\"t-info-inline\"></span>"
            }
            let cls   = "t-info-inline" + (dt.isFull ? " t-info-full" : "")
            let label = "\(dt.active)/\(dt.total)\(dt.isFull ? " — FULL" : "")"
            return "<span id=\"tun-\(he(devId))\" class=\"\(cls)\">\(label)</span>"
        }

        let onlineIDs  = Set(state.devices.map { $0.DeviceID })
        let deviceIDsWithShows = Set(state.shows.map { $0.hdhr_record })
        let offlineIDs = deviceIDsWithShows.subtracting(onlineIDs).filter { !$0.isEmpty }
        let usableIDs  = state.usableDeviceIDs

        func tunerBox(_ devId: String, active: Bool, uiURL: String?) -> String {
            let label = he("HDHR-\(devId.uppercased())")
            var s = "<div class=\"tuner-box\(active ? "" : " tuner-off")\">"
            s += "<div class=\"tuner-row\">"
            if active {
                let countSpan = tunerCountSpan(devId, devTuners[devId])
                s += "<button class=\"d-btn\" data-dev=\"\(he(devId))\" onclick=\"handleDevClick(this.dataset.dev,this)\" aria-label=\"Switch guide to tuner \(label); click again to see tuner details\" title=\"Click to select this tuner; click again for tuner details\">\(label) \(countSpan)</button>"
            } else {
                s += "<span class=\"d-btn d-btn-off\" title=\"Not detected — recordings assigned here will fail until it returns\">\(label)</span>"
            }
            s += "<button class=\"tdrop-btn\" data-dev=\"\(he(devId))\" onclick=\"toggleTunerDrop(this.dataset.dev)\" aria-label=\"Shows on this tuner\" title=\"Shows on this tuner\">▾</button>"
            s += "</div>"
            s += "<div class=\"tdrop\" id=\"tdrop-\(he(devId))\" style=\"display:none\">"
            s += "<div class=\"tdrop-hdr\">"
            if !active { s += "<span id=\"tun-\(he(devId))\" class=\"t-info t-info-off\">offline</span>" }
            if let uiURL { s += "<a href=\"\(he(uiURL))\" target=\"_blank\" class=\"d-ui tdrop-ui\" title=\"Open \(label) web UI\">↗ Device web UI</a>" }
            s += "</div>"
            s += "<div class=\"tdrop-body\" id=\"tdrop-body-\(he(devId))\">\(buildTunerShowsHTML(state: state, deviceId: devId))</div>"
            s += "</div>"
            s += "</div>"
            return s
        }

        var bar = ""
        for d in state.devices {
            let isUsable = usableIDs.contains(d.DeviceID)
            // A previously-discovered device that's gone unavailable (isUsable == false) only
            // gets a box when something still depends on it — nothing to warn about otherwise,
            // and a permanently-dimmed empty tuner box is just clutter. offlineIDs below (a
            // device with a show but never discovered at all) is a distinct, always-shown case —
            // see the "Web guide offline devices" invariant in CLAUDE.md, unaffected by this.
            guard isUsable || deviceIDsWithShows.contains(d.DeviceID) else { continue }
            bar += tunerBox(d.DeviceID, active: isUsable, uiURL: "http://\(d.LocalIP)/")
        }
        for id in offlineIDs.sorted() { bar += tunerBox(id, active: false, uiURL: nil) }
        return bar
    }

    // Push a devbar-only update for a device coming online/offline or being newly discovered.
    // Previously deviceOnline/deviceOffline broadcast a bare {type,deviceId} with no HTML
    // payload; the client's SSE dispatcher had no branch for it and fell through to
    // refreshGuide(), whose payload never includes #dev-bar's HTML at all — so the tuner-box
    // online/offline state silently went stale until the next full page reload.
    @MainActor
    func broadcastDeviceBarEvent(type: String, deviceId: String, state: AppState) {
        broadcastEvent(["type": type, "deviceId": deviceId, "devbar": buildDevBarHTML(state: state, devTuners: Self.computeDevTuners(state: state))])
    }

    @MainActor
    private func buildSumPhHTML(state: AppState) -> String {
        let recording = state.recordingShows
        let phSorted = state.activeShows.sorted {
            ($0.show_next?.timeIntervalSince1970 ?? .infinity) < ($1.show_next?.timeIntervalSince1970 ?? .infinity)
        }
        func phLogo(_ deviceId: String, _ ch: String) -> String {
            guard let raw = state.channelImageURLs["\(deviceId):\(ch)"], !raw.isEmpty else { return "" }
            return "<img src=\"\(he(raw))\" loading=\"lazy\" onerror=\"this.style.display='none'\" style=\"width:36px;height:36px;object-fit:contain;border-radius:4px;flex-shrink:0;margin-right:12px;background:#ccc\">"
        }
        if let rec = recording.first {
            var sub = ""
            if let next = phSorted.first(where: { $0.show_next != nil && $0.show_id != rec.show_id }) {
                sub = "<div style=\"font-size:.7rem;color:var(--t4);margin-top:2px\"><span style=\"color:var(--ac)\">★</span> \(he(next.show_title)) · at \(he(state.shortTime(next.show_next)))</div>"
            }
            return "\(phLogo(rec.hdhr_record, rec.show_channel))<div><div style=\"font-size:.82rem;font-weight:600;color:var(--t0)\"><span style=\"color:#ff8080\">●</span> Recording: \(he(rec.show_title))</div>\(sub)</div>"
        } else if let next = phSorted.first(where: { $0.show_next != nil }) {
            return "\(phLogo(next.hdhr_record, next.show_channel))<div><div style=\"font-size:.82rem;font-weight:600;color:var(--t0)\"><span style=\"color:var(--ac)\">★</span> Up Next: \(he(next.show_title))</div><div style=\"font-size:.7rem;color:var(--t4);margin-top:2px\">at \(he(state.shortTime(next.show_next)))</div></div>"
        } else {
            return "<div style=\"font-size:.85rem;color:var(--t5)\">Select a show from the guide</div>"
        }
    }

    // Shared time-window formula for the guide grid, the page shell (_winStart JS literal /
    // guideMinWidth), and /api/guide-detail — keeps all three mathematically in agreement about
    // which entries are "in the visible window" at any given moment.
    @MainActor
    private func guideWindow(state: AppState) -> (start: Int, sec: Int) {
        let nowTs    = Int(Date().timeIntervalSince1970)
        let halfHour = 30 * 60
        let winSec   = state.config.GuideHours * 3600
        let winStart = (nowTs / halfHour) * halfHour - 3600
        return (winStart, winSec)
    }

    // Shared "entries visible in [winStart, winEnd)" lookup — used by both buildGuideGridHTML and
    // /api/guide-detail so the windowing/clamping semantics can't drift apart between the two.
    @MainActor
    private func entriesInWindow(state: AppState, deviceId: String, channelNum: String, winStart: Int, winEnd: Int) -> [GuideEntry] {
        state.guideStore.entries(deviceId: deviceId, channelNum: channelNum,
            after: Date(timeIntervalSince1970: TimeInterval(winStart)))
            .filter { $0.StartTime < winEnd }
    }

    // Builds the .gi innerHTML (g-hdr + per-channel rows) used by both buildHTML() and /api/guide-refresh.
    // Self-contained: all dependencies come from `state` or module-level globals (he, hourFmt, etc.).
    @MainActor
    private func buildGuideGridHTML(state: AppState) -> String {

        // ── Time window ────────────────────────────────────────────────────────
        let nowTs = Int(Date().timeIntervalSince1970)
        let (winStart, winSec) = guideWindow(state: state)
        let winEnd = winStart + winSec
        func pct(_ offset: Int) -> String {
            let n     = offset * 1_000_000 / winSec
            let whole = n / 10000
            let frac  = n % 10000
            return "\(whole).\(frac / 1000)\((frac / 100) % 10)\((frac / 10) % 10)\(frac % 10)"
        }
        let nowPct    = pct(nowTs - winStart)
        let firstHour = ((winStart + 3599) / 3600) * 3600
        let ticksHTML: String = stride(from: firstHour, through: winEnd, by: 3600).map { ts in
            let lbl = he(Self.hourFmt.string(from: Date(timeIntervalSince1970: TimeInterval(ts))))
            return "<div class=\"g-tick\" style=\"--gs:\(pct(ts - winStart))%\">\(lbl)</div>"
        }.joined() + "<div class=\"g-now-tick\" style=\"--gs:\(nowPct)%\"></div>"

        // ── New-episode detection anchors (computed once, reused per entry in the grid loop) ──
        let nowDate = Date()
        var _newUTCCal = Calendar(identifier: .gregorian)
        _newUTCCal.timeZone = TimeZone(identifier: "UTC")!
        let _newLocalCal       = Calendar.current
        let _newTodayComps     = _newLocalCal.dateComponents([.year, .month, .day], from: nowDate)
        let _newTomorrowStart  = _newLocalCal.startOfDay(for: _newLocalCal.date(byAdding: .day, value: 1, to: nowDate)!)
        let _newTomorrowComps  = _newLocalCal.dateComponents([.year, .month, .day], from: _newTomorrowStart)
        let _newTomorrowMidUTC = Int(_newTomorrowStart.timeIntervalSince1970)
        let _newTomorrowEnd    = Int(_newTomorrowStart.addingTimeInterval(5 * 3600).timeIntervalSince1970)

        // ── Managed show lookups ───────────────────────────────────────────────
        // AppState.activeRecordingChannels/pendingRecordingChannels — same shared definition
        // WatchNowView's Watch Now window uses, so the two surfaces can't drift apart.
        let recChannelsByDevice: [String: Set<String>] = Dictionary(
            uniqueKeysWithValues: state.devices.map { ($0.DeviceID, state.activeRecordingChannels(for: $0.DeviceID)) }
        )
        let pendingRecChannelsByDevice: [String: Set<String>] = Dictionary(
            uniqueKeysWithValues: state.devices.map { ($0.DeviceID, state.pendingRecordingChannels(for: $0.DeviceID)) }
        )
        // Channels a hardware tuner is actively locked to but this app didn't initiate — e.g. the
        // "app expects 1, hw shows 2" case (another machine running this app against the same
        // physical device, or someone just watching live via the HDHomeRun's own app). Excludes our
        // own recording channels so this never doubles up with .g-st-rec for the same block, and
        // excludes this instance's own in-app live Watch channel (state.vlcLiveChannel) — otherwise
        // clicking Watch on a live channel would immediately flag that same channel as "in use by
        // another tuner" for the person watching it.
        let hwOtherChannelsByDevice: [String: Set<String>] = Dictionary(
            uniqueKeysWithValues: state.devices.map { device in
                let hwChannels = Set((state.deviceTunerOccupancy[device.DeviceID] ?? []).compactMap { $0.VctNumber })
                var ours = recChannelsByDevice[device.DeviceID] ?? []
                if let liveCh = state.vlcLiveChannel(for: device.DeviceID) { ours.insert(liveCh) }
                return (device.DeviceID, hwChannels.subtracting(ours))
            }
        )
        let activeMgd    = state.shows.filter { $0.show_active && !$0.show_paused }
        let guideMatcher = ManagedGuideMatcher(activeManagedShows: activeMgd)
        // Skip-already-recorded: precompute each managed series' on-disk SxxExx tags ONCE (one dir
        // scan per series, off the per-block hot path) so a guide block whose episode we already
        // have can show a green "already recorded" corner flag instead of the gold "will record" one.
        let skipEnabled = state.config.Series_subfolder_enabled && state.config.Skip_recorded_episodes
        var recordedTagsByShow: [String: Set<String>] = [:]
        if skipEnabled {
            for s in activeMgd where s.isSeries {
                let safe = s.show_title.replacingOccurrences(of: "/", with: "-")
                recordedTagsByShow[s.show_id] = state.recordedEpisodeTags(forTitle: safe, baseDir: s.posixRecordDir,
                                                                            expectedMinutes: s.show_length)
            }
        }
        // ── Guide grid rows ────────────────────────────────────────────────────
        var rowParts: [String] = []

        for device in state.devices {
            // Recording outranks favorite — a channel already recording is a stronger claim on
            // the user's attention than a merely-favorited one, so it sorts (and buckets, below)
            // ahead of the ★ Favorites section rather than into it.
            let recSet = (recChannelsByDevice[device.DeviceID] ?? [])
                .union(pendingRecChannelsByDevice[device.DeviceID] ?? [])
            let sorted = (state.lineups[device.DeviceID] ?? [])
                .sorted {
                    let aRec = recSet.contains($0.GuideNumber), bRec = recSet.contains($1.GuideNumber)
                    if aRec != bRec { return aRec }
                    if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
                    return $0.GuideNumber.channelSortKey < $1.GuideNumber.channelSortKey
                }
            var seenInDevice = Set<String>()
            var recRows:   [String] = []
            var favRows:   [String] = []
            var otherRows: [String] = []
            for ch in sorted {
                guard seenInDevice.insert(ch.GuideNumber).inserted else { continue }
                let entries = entriesInWindow(state: state, deviceId: device.DeviceID, channelNum: ch.GuideNumber,
                                               winStart: winStart, winEnd: winEnd)
                guard !entries.isEmpty else { continue }

                // Use the external CDN URL directly — browser fetches and caches without a local proxy hop.
                let logoURL: String = state.channelImageURLs["\(device.DeviceID):\(ch.GuideNumber)"] ?? ""
                let isHD     = (ch.HD ?? 0) != 0
                let chLabel  = ch.GuideNumber + (isHD ? " HD" : "")
                let logoHTML = logoURL.isEmpty
                    ? ""
                    : "<img class=\"g-logo\" src=\"\(he(logoURL))\" loading=\"lazy\" onerror=\"this.style.display='none'\" alt=\"\" style=\"background:#ddd\">"
                let isRecCh  = (recChannelsByDevice[device.DeviceID]?.contains(ch.GuideNumber) ?? false)
                             || (pendingRecChannelsByDevice[device.DeviceID]?.contains(ch.GuideNumber) ?? false)
                let isOtherTunerCh = hwOtherChannelsByDevice[device.DeviceID]?.contains(ch.GuideNumber) ?? false

                var blockParts: [String] = ["<div class=\"g-now-bar\" style=\"--gs:\(nowPct)%\"></div>"]
                var cursor = winStart
                for e in entries {
                    let gapEnd = min(e.StartTime, winEnd)
                    if gapEnd > cursor {
                        blockParts.append("<div class=\"g-gap\" style=\"--gs:\(pct(cursor - winStart))%;--gw:\(pct(gapEnd - cursor))%\"></div>")
                    }
                    cursor = max(cursor, e.EndTime)
                }
                if cursor < winEnd {
                    blockParts.append("<div class=\"g-gap\" style=\"--gs:\(pct(cursor - winStart))%;--gw:\(pct(winEnd - cursor))%\"></div>")
                }
                for e in entries {
                    let cs = max(e.StartTime, winStart) - winStart
                    let ce = min(e.EndTime,   winEnd)   - winStart
                    guard ce > cs else { continue }

                    let isNow      = e.StartTime <= nowTs && e.EndTime > nowTs
                    let isEntryRec = isRecCh && isNow
                    // Owning show for a managed block (reused by showDA below and the skip check).
                    let owner = guideMatcher.owner(for: e)
                    let isMgd = owner != nil
                    // Will this managed airing be skipped because the episode is already on disk?
                    // Exclude the airing that is recording right now — its own in-progress file is on
                    // disk, so it would otherwise flag itself as a duplicate.
                    let willSkip: Bool = {
                        guard skipEnabled, !isEntryRec, let owner, !owner.show_ignore_duplicate_once,
                              let ep = e.EpisodeNumber,
                              ep.range(of: #"^S\d+E\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil
                        else { return false }
                        return recordedTagsByShow[owner.show_id]?.contains(ep.uppercased()) == true
                    }()
                    // Scheduled but can't get a tuner — see AppState.conflictingShowIDs (a
                    // per-device greedy tuner-slot simulation, not a live scan here).
                    // conflictingShowIDs is computed against a show's single show_next/hdhr_record,
                    // but owner(for:) matches ANY block sharing the show's SeriesID/title (by design,
                    // for seriesAll fan-out) — so guard on device + a 5-min window around show_next
                    // (same tolerance rebuildMenuEntries uses for its own guide-entry match) to avoid
                    // flagging every rerun/simulcast of a show whose *next* airing conflicts.
                    let isConflict = isMgd && !willSkip && !isEntryRec && (owner.map { s in
                        guard s.hdhr_record == device.DeviceID, let sNext = s.show_next else { return false }
                        return state.conflictingShowIDs.contains(s.show_id)
                            && abs(Double(e.StartTime) - sNext.timeIntervalSince1970) < 300
                    } ?? false)
                    // Lowest-priority marker — a hardware tuner is on this channel right now but not
                    // for any reason this app tracks (not our recording, not a scheduled/skip/conflict
                    // state). Yields to all four managed states above; see hwOtherChannelsByDevice.
                    let isOtherTunerNow = isOtherTunerCh && isNow && !isEntryRec
                    var cls = "g-prog"
                    if isEntryRec      { cls += " g-prog-rec"   }
                    else if isNow      { cls += " g-prog-now"   }
                    else if isMgd      { cls += " g-prog-sched" }
                    // Status ring + badge (independent of the background class above — genre
                    // colour stays untouched): recording > skip > conflict > scheduled > other-tuner.
                    cls += isEntryRec              ? " g-st-rec"
                         : (isMgd && willSkip)     ? " g-st-skip"
                         : isConflict              ? " g-st-conflict"
                         : isMgd                   ? " g-st-sched"
                         : isOtherTunerNow         ? " g-st-inuse" : ""
                    let ggSkip: Set<String>  = ["series","miniseries","mini-series","mini series","special"]
                    let ggAlias: [String: String] = [
                        "sitcom":"comedy","movies":"movie","kids":"children","sport":"sports",
                        "documentary":"doc","game show":"gameshow","animation":"children","animated":"children"
                    ]
                    let ggKnown: Set<String> = [
                        "drama","comedy","news","sports","reality","movie","talk","children",
                        "crime","romance","thriller","action","mystery","doc","science","nature",
                        "history","music","food","travel","gameshow","home","health","faith"
                    ]
                    var gg: [String] = []
                    for f in (e.Filter ?? []) {
                        let lo = f.lowercased()
                        if ggSkip.contains(lo) { continue }
                        let g = ggAlias[lo] ?? lo
                        if ggKnown.contains(g) && !gg.contains(g) { gg.append(g); if gg.count == 2 { break } }
                    }
                    var extraStyle = ""
                    if (e.Filter?.count ?? 0) > 1 && gg.count == 2 && !isEntryRec {
                        let sfx = (isNow || isMgd) ? "-now" : ""
                        extraStyle = ";background:linear-gradient(var(--gg-dir,to right),var(--gg-\(gg[0])\(sfx)),var(--gg-\(gg[1])\(sfx)))"
                        cls += " gg-\(gg[0])"
                    } else if let g = gg.first {
                        cls += " gg-\(g)"
                    }

                    let sub   = e.EpisodeTitle.flatMap { $0.isEmpty ? nil : $0 } ?? ""
                    // Explains the status ring/badge on hover — same precedence as the cls chain above.
                    let stateLabel: String = {
                        if isEntryRec { return "  — Recording now" }
                        if isMgd && willSkip { return "  — Already recorded · will skip" }
                        if isConflict {
                            if let owner, state.conflictBeatenByFavorite.contains(owner.show_id) {
                                return "  — Conflict: a favorited channel has priority for this tuner"
                            }
                            return "  — Conflict: all tuners busy at this time"
                        }
                        if isMgd { return "  — Scheduled to record" }
                        if isOtherTunerNow { return "  — In use on this device (not by this app)" }
                        return ""
                    }()
                    let tip   = (sub.isEmpty
                        ? "\(he(e.Title))  (\(he(guideTimeRange(e))))"
                        : "\(he(e.Title)) · \(he(sub))  (\(he(guideTimeRange(e))))") + stateLabel
                    let subH  = sub.isEmpty ? "" : "<span class=\"g-sub\">\(he(sub))</span>"

                    let filtersAttr = (e.Filter ?? []).joined(separator: ",")
                    let isNew: Bool = {
                        guard let oad = e.OriginalAirdate else { return false }
                        let oadC = _newUTCCal.dateComponents([.year, .month, .day],
                                       from: Date(timeIntervalSince1970: TimeInterval(oad)))
                        if oadC == _newTodayComps { return true }
                        if oadC == _newTomorrowComps &&
                           e.StartTime >= _newTomorrowMidUTC && e.StartTime < _newTomorrowEnd { return true }
                        return false
                    }()
                    let newAttr     = isNew ? " data-new=\"1\"" : ""
                    // Skip state is shown by a distinct corner flag (below), not a title pill.
                    let skipAttr    = willSkip ? " data-skip=\"1\"" : ""
                    let titleHTML   = isNew
                        ? "<div class=\"g-ti-row\"><span class=\"g-ti\">\(he(e.Title))</span><span class=\"g-new-tag\">NEW</span></div>"
                        : "<span class=\"g-ti\">\(he(e.Title))</span>"
                    // Heavy fields (Synopsis, poster, episode, air date) are deliberately omitted here —
                    // fetched lazily per-row via /api/guide-detail once the row scrolls into view (see
                    // the client-side IntersectionObserver in buildHTML's <script>).
                    let da = "data-title=\"\(he(e.Title))\" data-genre=\"\(he(e.firstGenre ?? ""))\" data-filters=\"\(he(filtersAttr))\" data-start=\"\(e.StartTime)\" data-end=\"\(e.EndTime)\" data-device=\"\(he(device.DeviceID))\" data-num=\"\(he(ch.GuideNumber))\" data-chname=\"\(he(ch.GuideName))\" data-logo=\"\(he(logoURL))\" data-series=\"\(he(e.SeriesID ?? ""))\" data-managed=\"\(isMgd ? 1 : 0)\" data-recording=\"\(isEntryRec ? 1 : 0)\""

                    let showDA: String = {
                        guard let s = owner else { return "" }
                        let ad = s.show_air_date.joined(separator: ",")
                        return " data-show-id=\"\(he(s.show_id))\" data-show-type=\"\(showTypeStr(s))\" data-show-paused=\"\(s.show_paused ? 1 : 0)\" data-show-length=\"\(s.show_length)\" data-show-bonus=\"\(s.show_bonus_time ? 1 : 0)\" data-show-transcode=\"\(he(s.show_transcode))\" data-show-seriesid=\"\(he(s.show_seriesid))\" data-show-airdays=\"\(he(ad))\" data-show-failcount=\"\(s.show_fail_count)\" data-show-failreason=\"\(he(s.show_fail_reason))\" data-show-recording=\"\(s.show_recording ? 1 : 0)\" data-show-ignoredup=\"\(s.show_ignore_duplicate_once ? 1 : 0)\""
                    }()
                    let infDA = e.isInfomercial ? " data-inf=\"1\"" : ""
                    // role/tabindex/aria-label/onkeydown: the grid has no other accessible way to reach
                    // or identify a show — these divs carry all the real interaction. aria-label reuses
                    // `tip` (already he()-escaped, already "Title · Episode (time) — status") rather than
                    // building a second description that could drift from the tooltip's wording.
                    blockParts.append("<div class=\"\(cls)\" style=\"--gs:\(pct(cs))%;--gw:\(pct(ce - cs))%\(extraStyle)\" title=\"\(tip)\" role=\"button\" tabindex=\"0\" aria-label=\"\(tip)\" \(da)\(showDA)\(infDA)\(newAttr)\(skipAttr) onclick=\"showInfo(this)\" ondblclick=\"recordFromDblClick(this)\" onkeydown=\"if(event.key==='Enter'||event.key===' '){event.preventDefault();showInfo(this);}\"><div class=\"g-pi\">\(titleHTML)\(subH)</div></div>")
                }

                let gnameAttr = ChannelSignalStore.key(for: ch.GuideName)
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
                let favAttr = ch.isFavorite ? " data-fav=\"1\"" : ""
                let favBtn  = ch.isFavorite
                    ? "<button class=\"g-fav-btn\" data-fav=\"1\" onclick=\"toggleFav(event,this)\" title=\"Remove from favorites\" aria-label=\"Remove from favorites\">★</button>"
                    : "<button class=\"g-fav-btn\" onclick=\"toggleFav(event,this)\" title=\"Add to favorites\" aria-label=\"Add to favorites\">☆</button>"
                let recAttr = isRecCh ? " data-rec=\"1\"" : ""
                let rowHTML = "<div class=\"g-row\" data-dev=\"\(he(device.DeviceID))\" data-ch=\"\(he(ch.GuideNumber))\" data-gname=\"\(he(gnameAttr))\"\(favAttr)\(recAttr)><div class=\"g-ch\">\(logoHTML)<div class=\"g-cl\"><span class=\"g-cn\">\(he(chLabel))\(sigHTML)</span><span class=\"g-cname\">\(he(ch.GuideName))</span></div>\(favBtn)</div><div class=\"g-tl\">\(blockParts.joined())</div></div>"
                // Recording bucket takes priority — a channel that's both recording and favorited
                // only appears once, up in the Recording section rather than duplicated below.
                if isRecCh { recRows.append(rowHTML) }
                else if ch.isFavorite { favRows.append(rowHTML) }
                else { otherRows.append(rowHTML) }
            }
            let devId = he(device.DeviceID)
            if !recRows.isEmpty {
                rowParts.append("<div class=\"g-rec-sep\" data-dev=\"\(devId)\"><div class=\"g-ch\"><span class=\"g-rec-sep-dot\">●</span><span class=\"g-rec-sep-txt\"> RECORDING</span></div><div class=\"g-tl\"></div></div>")
                rowParts.append(contentsOf: recRows)
            }
            if !favRows.isEmpty {
                rowParts.append("<div class=\"g-fav-sep\" data-dev=\"\(devId)\"><div class=\"g-ch\"><span class=\"g-fav-sep-star\">★</span><span class=\"g-fav-sep-txt\"> FAVORITES</span></div><div class=\"g-tl\"></div></div>")
                rowParts.append(contentsOf: favRows)
            }
            rowParts.append(contentsOf: otherRows)
        }
        let rowsHTML = rowParts.isEmpty
            ? "<div style=\"padding:24px;color:#555;text-align:center;font-size:.85rem\">No guide data — loading…</div>"
            : rowParts.joined()

        let hdr = "<div class=\"g-hdr\" data-winstart=\"\(winStart)\" data-winsec=\"\(winSec)\"><div class=\"g-hdr-ch\"><span class=\"g-hdr-ch-lbl\">Ch</span><div class=\"g-hdr-btns\"><button id=\"g-now-btn\" class=\"g-hdr-btn g-hdr-btn-now\" onclick=\"scrollToNow()\" title=\"Jump to now\">▶ Now</button><button class=\"g-hdr-btn\" onclick=\"refreshGuide()\" title=\"Refresh guide\">↺</button></div></div><div class=\"g-hdr-tl\">\(ticksHTML)</div></div>"
        return hdr + "\n        " + rowsHTML
    }

    @MainActor
    private func buildHTML(state: AppState, prebuiltGrid: String? = nil, includeVerticalCSS: Bool) -> String {
        let (winStart, winSec) = guideWindow(state: state)   // winStart needed for _winStart JS literal
        let halfHourSlots = winSec / 1800
        let guideMinWidth = max(1200, halfHourSlots * 100)
        // Vertical time-axis mode's per-column timeline height — same shape as guideMinWidth but
        // a smaller px/30min constant, since each column only needs to be tall enough for legible
        // stacked program blocks, not wide enough for side-by-side ones.
        let guideMinHeight = max(1600, halfHourSlots * 70)
        let gridInner   = prebuiltGrid ?? buildGuideGridHTML(state: state)
        // Capture recording shows once — used by recsByDevJS below.
        let recording   = state.recordingShows

        // ── Per-device tuner counts (total slots vs. currently occupied) ────────
        let devTuners = Self.computeDevTuners(state: state, logDiagnostics: true)
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
                    let liveWatchCh = state.vlcLiveChannel(for: d.DeviceID)
                    for info in occupancy {
                        let matchShow = recording.first {
                            guard $0.hdhr_record == d.DeviceID else { return false }
                            // prefer resource match; fall back to channel match when resource not yet captured
                            if !$0.show_tuner_resource.isEmpty {
                                return $0.show_tuner_resource.lowercased() == info.Resource.lowercased()
                            }
                            return $0.show_channel == (info.VctNumber ?? "")
                        }
                        // This instance's own in-app live Watch, not a recording — excluded from
                        // `external` below so it isn't mislabeled as "another tuner" in the popover
                        // for the very person watching it (mirrors hwOtherChannelsByDevice above).
                        let isOwnLiveWatch = matchShow == nil && info.VctNumber != nil && info.VctNumber == liveWatchCh
                        // Tuned to a channel but not one of our own recordings or live watch — same
                        // "app expects 1, hw shows 2" scenario the web guide's .g-st-inuse flags
                        // (another machine running this app against the same physical device, or
                        // someone watching live via the HDHomeRun's own app/web UI). Look up the
                        // real currently-airing entry for that device+channel instead of a generic
                        // placeholder, matching the detail already shown for our own shows.
                        let title: String = {
                            if let t = matchShow?.show_title, !t.isEmpty { return t }
                            if let ch = info.VctNumber {
                                let now = Int(Date().timeIntervalSince1970)
                                if let live = state.guideEntries(deviceId: d.DeviceID, channelNum: ch)
                                    .first(where: { $0.StartTime <= now && $0.EndTime > now }) {
                                    return live.Title
                                }
                                return "Ch \(ch) (unmanaged)"
                            }
                            return "Active stream"
                        }()
                        let ch       = matchShow?.show_channel ?? info.VctNumber ?? "?"
                        let ip       = matchShow == nil ? (info.TargetIP ?? "") : ""
                        let idle     = matchShow == nil && info.VctNumber == nil ? "1" : ""
                        let rec      = matchShow != nil ? "1" : ""
                        // Tuned (VctNumber present) but not matched to one of our own shows or live
                        // watch — distinct from `idle` (no VctNumber at all, nothing tuned) so the
                        // client can label this case explicitly instead of showing a bare title
                        // indistinguishable from an owned one save for the missing red dot.
                        let external = (matchShow == nil && info.VctNumber != nil && !isOwnLiveWatch) ? "1" : ""
                        let endTs    = matchShow?.show_end.map { String(Int($0.timeIntervalSince1970)) } ?? ""
                        entries.append(["tuner": info.Resource, "title": title, "ch": ch, "chname": chName(ch), "ip": ip, "idle": idle, "rec": rec, "external": external, "endTime": endTs])
                    }
                } else {
                    for show in recording.filter({ $0.hdhr_record == d.DeviceID }) {
                        entries.append([
                            "tuner":   show.show_tuner_resource.isEmpty ? "—" : show.show_tuner_resource,
                            "title":   show.show_title,
                            "ch":      show.show_channel,
                            "chname":  chName(show.show_channel),
                            "rec":     "1",
                            "endTime": show.show_end.map { String(Int($0.timeIntervalSince1970)) } ?? ""
                        ])
                    }
                }
                devMap[d.DeviceID] = entries
            }
            if let data = try? JSONSerialization.data(withJSONObject: devMap),
               let str  = String(data: data, encoding: .utf8) { return "var recsByDev=\(jsEscapeForScript(str));" }
            return "var recsByDev={};"
        }()

        // Default tuner for the initial guide view. With >1 tuner there is no combined view —
        // open on the first tuner that has both a lineup and loaded guide data (fall back to
        // first with a lineup, then ""). Single-device keeps "" (that one device's channels).
        let defaultDev: String = state.devices.count > 1
            ? (state.devices.first(where: { !(state.lineups[$0.DeviceID] ?? []).isEmpty && !state.guideStore.channels(deviceId: $0.DeviceID).isEmpty })?.DeviceID
               ?? state.devices.first(where: { !(state.lineups[$0.DeviceID] ?? []).isEmpty })?.DeviceID
               ?? "")
            : ""

        // Header is just the title now; every tuner (incl. offline) gets a box in the dev-bar.
        let headerHTML = "<h1 style=\"margin:0\">hdhrVCRplus Guide</h1>"
        let deviceBarHTML = "<div id=\"dev-bar\">" + buildDevBarHTML(state: state, devTuners: devTuners) + "</div>"

        // ── Summary placeholder: current recording or next scheduled show ────
        let sumPhHTML = buildSumPhHTML(state: state)

        // ── Schedule popover content ──────────────────────────────────────────

        // ── Assemble ──────────────────────────────────────────────────────────
        let cssFilled = fillTemplate(cachedGuideCSS ?? "/* guide.css failed to load */", [
            ("GUIDE_MIN_WIDTH", String(guideMinWidth)),
            ("GUIDE_MIN_HEIGHT", String(guideMinHeight))
        ])
        // Only computed/embedded for GET /vertical — GET / must never be ABLE to show the
        // vertical layout, in any orientation, so its page doesn't even carry this stylesheet.
        let verticalStyleBlock: String = {
            guard includeVerticalCSS else { return "" }
            let cssVerticalFilled = fillTemplate(cachedGuideVerticalCSS ?? "/* guide-vertical.css failed to load */", [
                ("GUIDE_MIN_HEIGHT", String(guideMinHeight))
            ])
            return "<style>\n\(cssVerticalFilled)\n</style>"
        }()
        let shellFilled = fillTemplate(cachedGuideShellHTML ?? "<p>guide-shell.html failed to load</p>", [
            ("APP_VERSION", appVersion),
            ("HEADER_HTML", headerHTML),
            ("DEVICE_BAR_HTML", deviceBarHTML),
            ("SUM_PH_HTML", sumPhHTML),
            ("SPORTS_PADDING_MINUTES", String(state.config.Sports_padding_minutes)),
            ("GRID_INNER", gridInner)
        ])
        let validTranscode = ["none", "heavy", "mobile", "internet720"].contains(state.config.Default_transcode)
            ? state.config.Default_transcode : "none"
        let verExpTs = Int(Date().addingTimeInterval(2 * 3600).timeIntervalSince1970) * 1000
        let jsFilled = fillTemplate(cachedGuideJS ?? "console.error('guide.js failed to load');", [
            ("TUNER_JS", tunerJS),
            ("RECS_BY_DEV_JS", recsByDevJS),
            ("SPORTS_PADDING_MINUTES", String(state.config.Sports_padding_minutes)),
            ("SPORTS_PADDING_ENABLED", String(state.config.Sports_padding_enabled)),
            ("SIGNAL_QUALITY_ENABLED", String(state.config.Signal_quality_enabled)),
            ("SKIP_DUP_ENABLED", String(state.config.Series_subfolder_enabled && state.config.Skip_recorded_episodes)),
            ("DEFAULT_TRANSCODE", validTranscode),
            ("DEFAULT_DEV", jsEscapeForScript(defaultDev)),
            ("WIN_START", String(winStart)),
            ("WIN_SEC", String(winSec)),
            ("APP_VERSION", appVersion),
            ("VER_EXP_TS", String(verExpTs)),
            // Also requires cachedGuideVerticalCSS to have actually loaded — includeVerticalCSS
            // alone just means "this is the /vertical route," not "the vertical stylesheet is
            // really embedded." If the template failed to load, verticalStyleBlock above falls
            // back to an empty comment with no @media(orientation:portrait) rules at all, so
            // guide.js's isVT() must stay false too — otherwise it'd compute transposed-layout
            // scroll/now-line math (chH(), swapped IntersectionObserver margin, syncHdrPin) against
            // a grid CSS never actually transposed, garbling the page instead of degrading to the
            // plain horizontal layout the missing stylesheet leaves it rendering as.
            ("VT_ELIGIBLE", (includeVerticalCSS && cachedGuideVerticalCSS != nil) ? "true" : "false")
        ])
        if cachedGuideCSS == nil { glog("[WebServer] guide.css template missing — check Resources/ deploy", level: .warning) }
        if includeVerticalCSS && cachedGuideVerticalCSS == nil { glog("[WebServer] guide-vertical.css template missing — check Resources/ deploy", level: .warning) }
        if cachedGuideShellHTML == nil { glog("[WebServer] guide-shell.html template missing — check Resources/ deploy", level: .warning) }
        if cachedGuideJS == nil { glog("[WebServer] guide.js template missing — check Resources/ deploy", level: .warning) }

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>hdhrVCRplus</title>
        <link rel="shortcut icon" type="image/x-icon" href="/favicon.ico">
        <script>(function(){try{var m=localStorage.getItem('theme')||'dark';if(m==='light'||(m==='auto'&&window.matchMedia('(prefers-color-scheme:light)').matches))document.documentElement.classList.add('lm');}catch(e){}})();</script>
        <style>
        \(cssFilled)
        </style>
        \(verticalStyleBlock)
        </head>
        <body>
        \(shellFilled)
        <script>
        \(jsFilled)
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

        // Same ManagedGuideMatcher the guide grid uses (buildGuideGridHTML) — previously this
        // endpoint maintained its own parallel isScheduled lookup (managedShowBySeriesID/
        // managedShowByTitle), which matched a seriesChannel show's SeriesID/title across ANY
        // channel on its device instead of just the one channel it's locked to. That let a
        // same-series rerun on a different channel (e.g. a syndicated rebroadcast) report
        // isScheduled: true here even after the guide grid itself was fixed to exclude it —
        // the two paths silently disagreeing despite docs/WebServer.md's "the same exclusion
        // applies... so the two paths agree" claim. Routing through the one shared matcher
        // instead removes the drift risk entirely. 2026-08-15, see issues_resolved.md.
        let activeMgd    = state.shows.filter { $0.show_active && !$0.show_paused }
        let guideMatcher = ManagedGuideMatcher(activeManagedShows: activeMgd)

        var entries: [NowEntry] = []
        for device in state.devices {
            for (ch, entry) in state.onAirNow(for: device) {
                let isRec = state.recordingShows.contains { $0.hdhr_record == device.DeviceID && $0.show_channel == ch.GuideNumber }
                let isSched = guideMatcher.isManaged(entry: entry)
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

    // Last dict actually published — lets updateTXTRecord() skip the NWListener.service
    // reassignment (and the mDNS re-announcement it triggers) when nothing changed since
    // the last idle-loop tick, rather than re-publishing unconditionally every tick.
    private var lastTXTDict: [String: String]? = nil

    // Refreshes the mDNS TXT record with current recording + schedule state.
    // Called from AppState.idleLoop() and immediately when the server first becomes ready.
    @MainActor
    func updateTXTRecord() {
        guard let state = appState, listener != nil else { return }
        let dict = buildTXTDict(state: state)
        guard dict != lastTXTDict else { return }
        lastTXTDict = dict
        listener?.service = NWListener.Service(name: "hdhrVCRplus", type: "_http._tcp", domain: nil,
                                               txtRecord: NWTXTRecord(dict))
    }

    @MainActor
    private func buildTXTDict(state: AppState) -> [String: String] {
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

        return dict
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

    private func send(_ response: WebResponse, on conn: NWConnection, acceptsGzip: Bool = false,
                       keepAlive: Bool = false) {
        func errorParts(_ statusLine: String, _ msg: String) -> (String, [(String, String)], Data) {
            let b = Data(msg.utf8)
            return (statusLine, [("Content-Type", "text/plain"), ("Content-Length", "\(b.count)")], b)
        }
        // Error responses always close: they're returned from framing failures (bad/oversized
        // Content-Length) where the receive buffer may hold unread bytes that would misparse the
        // next request, so reusing the connection is never safe regardless of the caller's flag.
        var keepAlive = keepAlive
        let (status, headers, body): (String, [(String, String)], Data)
        switch response {
        case .ok(let ct, let b):
            status = "200 OK"
            // Compress text responses when the client supports it.
            if acceptsGzip, b.count >= 1400, let gz = Self.gzip(b) {
                headers = [("Content-Type", ct), ("Content-Encoding", "gzip"),
                           ("Vary", "Accept-Encoding"), ("Content-Length", "\(gz.count)")]
                body    = gz
            } else {
                headers = [("Content-Type", ct), ("Content-Length", "\(b.count)")]
                body    = b
            }
        case .okPrecompressed(let ct, let raw, let gz):
            status = "200 OK"
            if acceptsGzip {
                headers = [("Content-Type", ct), ("Content-Encoding", "gzip"),
                           ("Vary", "Accept-Encoding"), ("Content-Length", "\(gz.count)")]
                body    = gz
            } else {
                headers = [("Content-Type", ct), ("Content-Length", "\(raw.count)")]
                body    = raw
            }
        case .notFound(let msg):      (status, headers, body) = errorParts("404 Not Found",         msg); keepAlive = false
        case .badRequest(let msg):    (status, headers, body) = errorParts("400 Bad Request",       msg); keepAlive = false
        case .payloadTooLarge(let msg):(status, headers, body) = errorParts("413 Content Too Large", msg); keepAlive = false
        }

        var raw = "HTTP/1.1 \(status)\r\n"
        if keepAlive {
            raw += "Connection: keep-alive\r\n"
            raw += "Keep-Alive: timeout=\(Int(Self.idleCloseSeconds))\r\n"
        } else {
            raw += "Connection: close\r\n"
        }
        raw += "Permissions-Policy: geolocation=(), camera=(), microphone=(), interest-cohort=()\r\n"
        for (k, v) in headers { raw += "\(k): \(v)\r\n" }
        raw += "\r\n"

        var packet = Data(raw.utf8)
        packet.append(body)

        conn.send(content: packet, isComplete: true, completion: .contentProcessed { [weak self] err in
            guard let self, keepAlive, err == nil else { conn.cancel(); return }
            // Go back to read the next request on this connection. accumulate() arms its own
            // idle-close timer for the wait, so a client that goes quiet after this response is
            // cleaned up within idleCloseSeconds. keepAlive is only ever true for a fully-framed
            // request with no leftover bytes, so starting from an empty buffer is correct.
            self.accumulate(conn: conn, buffer: Data())
        })
    }

    // MARK: - gzip

    // Wraps libcompression's raw DEFLATE output in a gzip container
    // (10-byte header + CRC-32 + input-size trailer). Returns nil if
    // compression fails or wouldn't shrink the payload.
    private static func gzip(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let dstCapacity = data.count + data.count / 16 + 128
        var dst = Data(count: dstCapacity)
        let compressedSize = dst.withUnsafeMutableBytes { (dstBuf: UnsafeMutableRawBufferPointer) in
            data.withUnsafeBytes { (srcBuf: UnsafeRawBufferPointer) in
                compression_encode_buffer(
                    dstBuf.bindMemory(to: UInt8.self).baseAddress!, dstCapacity,
                    srcBuf.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB)   // COMPRESSION_ZLIB = raw DEFLATE, no zlib header
            }
        }
        guard compressedSize > 0, compressedSize + 18 < data.count else { return nil }
        var out = Data([0x1F, 0x8B, 0x08, 0, 0, 0, 0, 0, 0, 0x03])  // gzip header (OS = Unix)
        out.append(dst.prefix(compressedSize))
        withUnsafeBytes(of: crc32(data).littleEndian) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(truncatingIfNeeded: data.count).littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    // MARK: - Helpers

    // Escapes a JSON string for safe embedding inside a <script>…</script> block.
    // JSONSerialization leaves `<`, `>`, and `&` as literal bytes; browsers tokenise
    // `</script>` as an end-tag even inside a JS string literal, so these must be
    // replaced with their \uXXXX equivalents before inserting JSON into HTML.
    // Internal (not private) so WebServerHelperTests can exercise this directly — it's the
    // </script>-breakout guard for every JSON literal embedded in the page (tuners, etc.).
    func jsEscapeForScript(_ s: String) -> String {
        s.replacingOccurrences(of: "<",  with: "\\u003c")
         .replacingOccurrences(of: ">",  with: "\\u003e")
         .replacingOccurrences(of: "&",  with: "\\u0026")
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
        // Exact-match, not hasPrefix — "::1" is loopback, but "::1234:5678"/"::123" (the
        // deprecated IPv4-compatible ::/96 space) merely begin with "::1" and are not loopback.
        if testIP == "127.0.0.1" || testIP == "::1" { return true }

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
