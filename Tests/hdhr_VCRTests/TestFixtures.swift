import Foundation
@testable import hdhr_VCR

// MARK: - Shared Mock URLProtocol
//
// canInit/canonicalRequest/startLoading/stopLoading were identical, hand-copied boilerplate
// across HDHRManagerTests/DiscordNotifierTests/GuideStoreTests. What must NOT be shared is each
// file's `requestHandler` *storage* — it's global mutable state, and one shared slot across
// files would let suites running in parallel (Swift Testing's default) race on which handler
// serves which request. Each mocking test file instead subclasses this base with its own
// private `override class var requestHandler` backed by its own private static storage, and
// marks its network-mocked suite `.serialized` so tests *within* that one file's suite (which do
// share that one slot) don't race each other either. `recordRequest()` is an optional hook for a
// subclass that also wants a call counter (see DiscordNotifierTests).
class MockURLProtocolBase: URLProtocol {
    class var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { nil }
        set { _ = newValue }  // no-op unless a subclass overrides with real storage
    }
    class func recordRequest() {}

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.recordRequest()
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

func makeMockSession(_ protocolClass: MockURLProtocolBase.Type) -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [protocolClass]
    return URLSession(configuration: config)
}

func mockOKResponse(for url: URL, statusCode: Int = 200, headers: [String: String]? = nil) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: headers)!
}

// MARK: - Mock curl script
//
// Shared by RecordingManagerTests and AppStateRecordingEngineTests — both need to point
// RecordingManager.init(curlExecutablePath:) at a fake "curl" instead of the real binary.
// Formerly hand-copied into RecordingManagerTests.swift only; moved here 2026-08-15 when a
// second file needed the identical helper, same consolidation reasoning as MockURLProtocolBase
// above. Each call writes a uniquely-named script (UUID in the filename) with its behavior baked
// in as literal shell text — no shared env vars or global mutable state — so tests stay safe to
// run concurrently.

// Builds a curl test-double: on invocation it writes a minimal HTTP header block to whatever path
// follows --dump-header in its argv (same as curl -D would, but instant instead of waiting on
// real device I/O), then sleeps for `sleepSeconds` before exiting with `exitCode`.
// `argsLogPath`, when set, has the script dump its full argv there before doing anything else —
// lets a test assert on exactly what RecordingManager.start(...) invoked curl with (e.g. the
// `transcode=` value baked into the stream URL), same instant-instead-of-real-I/O tradeoff as the
// header-file write below.
func writeMockCurlScript(headerLines: [String] = [], sleepSeconds: Double = 30,
                          exitCode: Int32 = 0, argsLogPath: String? = nil) throws -> String {
    let path = NSTemporaryDirectory() + "hdhrVCRplus-mockcurl-\(UUID().uuidString).sh"
    var script = "#!/bin/bash\n"
    script += "hdr=\"\"\n"
    script += "args=(\"$@\")\n"
    if let argsLogPath {
        script += "printf '%s\\n' \"$@\" > \"\(argsLogPath)\"\n"
    }
    script += "for ((i=0; i<${#args[@]}; i++)); do\n"
    script += "  if [[ \"${args[$i]}\" == \"--dump-header\" ]]; then hdr=\"${args[$((i+1))]}\"; fi\n"
    script += "done\n"
    // printf '...\r\n' (not echo, which only appends \n) — a real HTTP response's headers are
    // CRLF-terminated, and curl's --dump-header writes them exactly as received off the wire.
    // RecordingManager's own header parsing was trimming with .whitespaces (which doesn't include
    // \r) instead of .whitespacesAndNewlines, silently leaving a trailing \r on every parsed value
    // — a real bug (show_tuner_resource ending up as "tuner0\r", never matching a clean "tuner0"
    // elsewhere) this echo-based \n-only mock could never have caught.
    script += "if [[ -n \"$hdr\" ]]; then\n"
    script += "  {\n    printf '%s\\r\\n' \"HTTP/1.1 200 OK\"\n"
    for line in headerLines {
        script += "    printf '%s\\r\\n' \"\(line)\"\n"
    }
    script += "  } > \"$hdr\"\n"
    script += "fi\n"
    script += "sleep \(sleepSeconds)\n"
    script += "exit \(exitCode)\n"
    try script.write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    return path
}

// Polls `condition` until it returns true or `timeout` elapses — the mock curl script runs as a
// real subprocess, so header-file writes and process-exit reaping aren't synchronous with
// start()/stop() returning.
func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
    }
}

// MARK: - HDHRDevice

extension HDHRDevice {
    // JSON-decoded so the custom Codable init handles field setup correctly.
    // modelNumber: nil (the default) mirrors a real device whose ModelNumber wasn't parsed — e.g.
    // UDP-only discovery — and so is conservatively supportsTranscode == false, same as production.
    static func test(id: String = "FFFFFFFF", ip: String = "192.168.1.100", tuners: Int = 4,
                      modelNumber: String? = nil, isVirtualRelay: Bool = false,
                      friendlyName: String? = nil) -> HDHRDevice {
        let modelJSON = modelNumber.map { ",\"ModelNumber\":\"\($0)\"" } ?? ""
        let relayJSON = isVirtualRelay ? ",\"HdhrVCRplusVirtualRelay\":true" : ""
        let friendlyJSON = friendlyName.map { ",\"FriendlyName\":\"\($0)\"" } ?? ""
        let json = """
        {"DeviceID":"\(id)","LocalIP":"\(ip)","TunerCount":\(tuners),"FirmwareVersion":"20240101"\(modelJSON)\(relayJSON)\(friendlyJSON)}
        """
        return try! JSONDecoder().decode(HDHRDevice.self, from: Data(json.utf8))
    }
}

// MARK: - LineupEntry

extension LineupEntry {
    static func test(number: String = "5.1", name: String = "KFOO", favorite: Bool = false,
                      showTitle: String? = nil) -> LineupEntry {
        LineupEntry(
            GuideNumber: number,
            GuideName: name,
            URL: "http://192.168.1.100:5004/auto/v\(number)",
            HD: 1,
            Favorite: favorite ? 1 : nil,
            virtualRelayShowTitle: showTitle
        )
    }
}

// MARK: - GuideChannel / GuideEntry

extension GuideChannel {
    // One channel with a single on-air (or arbitrary window) GuideEntry — enough to drive
    // AppState.onAirNow()/WatchNowView's ScrollView branch without a real guide.json fetch.
    static func test(number: String = "5.1", name: String = "KFOO", title: String = "Test Show",
                      start: Int, end: Int) -> GuideChannel {
        let json = """
        {"GuideNumber":"\(number)","GuideName":"\(name)","Guide":[
            {"StartTime":\(start),"EndTime":\(end),"Title":"\(title)"}
        ]}
        """
        return try! JSONDecoder().decode(GuideChannel.self, from: Data(json.utf8))
    }
}

extension GuideEntry {
    static func test(title: String = "Test Show", start: Int = Int(Date().timeIntervalSince1970) - 300,
                      end: Int = Int(Date().timeIntervalSince1970) + 1500) -> GuideEntry {
        GuideEntry(StartTime: start, EndTime: end, Title: title)
    }
}

// MARK: - Show

extension Show {
    static func testRecording(title: String = "The Tonight Show", channel: String = "5.1") -> Show {
        var s = Show.blank(channel: channel, device: "FFFFFFFF")
        s.show_title = title
        s.show_recording = true
        s.show_next = Date().addingTimeInterval(-300)
        s.show_end = Date().addingTimeInterval(1800)
        return s
    }

    static func testActive(title: String = "60 Minutes", channel: String = "3.1") -> Show {
        var s = Show.blank(channel: channel, device: "FFFFFFFF")
        s.show_title = title
        s.show_active = true
        s.show_next = Date().addingTimeInterval(3600)
        return s
    }

    static func testPaused(title: String = "Dateline NBC", channel: String = "4.1") -> Show {
        var s = Show.blank(channel: channel, device: "FFFFFFFF")
        s.show_title = title
        s.show_paused = true
        return s
    }

    static func testInactive(title: String = "Evening News") -> Show {
        var s = Show.blank(channel: "7.1", device: "FFFFFFFF")
        s.show_title = title
        s.show_active = false
        return s
    }
}

// MARK: - AppState

// Creates an AppState prepopulated with fake data for snapshot rendering.
// AppState.init() fires Task { await startup() } — that task is async and won't
// execute before ImageRenderer renders synchronously, so it's safe to overwrite
// properties immediately after init.
@MainActor
func makeTestAppState(
    shows: [Show] = [],
    devices: [HDHRDevice] = [],
    lineups: [String: [LineupEntry]] = [:],
    recordingManager: RecordingManager? = nil,
    guideStore: GuideStore? = nil
) -> AppState {
    // Unique per-call temp dir — any test that reaches saveConfig() (e.g. deleteShow) writes here
    // instead of the real ~/Library/Application Support/hdhrVCRplus/ config the deployed app uses.
    let tempConfigDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let s = AppState(configManager: ConfigManager(appSupportDir: tempConfigDir), recordingManager: recordingManager, guideStore: guideStore)
    // skipStartup must be set before any suspension point so startup()'s guard fires
    // before the Task runs on the main actor. Prevents idleLoop from spinning forever.
    s.skipStartup = true
    s.shows = shows
    s.devices = devices
    s.lineups = lineups
    s.isStartingUp = false
    s.statusMessage = "Ready"
    s.config.Web_server_enabled = false
    return s
}
