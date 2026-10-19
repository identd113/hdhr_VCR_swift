import Testing
import Foundation
import Network
import Darwin

// MARK: - hdhr_guide (the bundled terminal client) — smoke tests of the real binary
//
// `hdhr_guide_coreTests` covers the TUI's pure logic (layout, DTOs, grid math). The executable itself —
// startup checks, raw-mode terminal setup/restore, key handling, the HTTP calls it makes — had no coverage
// because a `main.swift` target can't be imported. These tests run the *built binary* (`hdhr_guide`, next to the
// test bundle) against a small stub guide server on a random port (`HDHR_GUIDE_PORT`), on a real pseudo-terminal
// where it needs a TTY, and assert what it prints, what it sends, and that it leaves the terminal restored.
//
// Hermetic: never touches the live app on :1980 or any real tuner. They skip (with a message) if the binary
// hasn't been built.

// MARK: stub server

private final class StubGuideServer: @unchecked Sendable {
    struct Request { var method: String; var path: String; var body: String }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "TUIStub")
    private let lock = NSLock()
    private var _requests: [Request] = []
    private(set) var port: UInt16 = 0
    var guideJSON: String

    init(guideJSON: String) { self.guideJSON = guideJSON }

    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return _requests }

    /// Waits for a request matching `method` + `path`, returning it (nil on timeout).
    func waitForRequest(_ method: String, _ path: String, timeout: TimeInterval = 6) -> Request? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let r = requests.first(where: { $0.method == method && $0.path == path }) { return r }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return nil
    }

    func start() throws {
        let l = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        l.newConnectionHandler = { [weak self] c in self?.serve(c) }
        l.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let p = l.port?.rawValue else { throw StubError.noPort }
        port = p
        listener = l
    }

    func stop() { listener?.cancel(); listener = nil }

    enum StubError: Error { case noPort }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        read(c, buffer: Data())
    }

    private func read(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isDone, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = Self.parse(buf) {
                self.lock.lock(); self._requests.append(req); self.lock.unlock()
                let (status, body) = self.respond(to: req)
                let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
                c.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in c.cancel() })
            } else if isDone || error != nil {
                c.cancel()
            } else {
                self.read(c, buffer: buf)
            }
        }
    }

    /// nil until the whole request (headers + Content-Length body) has arrived.
    private static func parse(_ data: Data) -> Request? {
        guard let text = String(data: data, encoding: .utf8), let split = text.range(of: "\r\n\r\n") else { return nil }
        let head = String(text[..<split.lowerBound])
        let body = String(text[split.upperBound...])
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let length = lines.dropFirst().compactMap { l -> Int? in
            let kv = l.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return kv.count == 2 && kv[0].lowercased() == "content-length" ? Int(kv[1]) : nil
        }.first ?? 0
        guard body.utf8.count >= length else { return nil }
        return Request(method: String(parts[0]), path: String(parts[1]), body: body)
    }

    private func respond(to req: Request) -> (String, String) {
        switch (req.method, req.path.split(separator: "?").first.map(String.init) ?? req.path) {
        case ("GET", let p) where p.hasPrefix("/api/guide.json"): return ("200 OK", guideJSON)
        case ("GET", "/api/signal"): return ("200 OK", "{}")
        case ("POST", "/api/toggle-favorite"): return ("200 OK", #"{"ok":true,"isFavorite":true}"#)
        case ("POST", "/api/record"): return ("200 OK", #"{"ok":true,"title":"Test Show","tunerFull":false,"recStarted":false}"#)
        case ("POST", "/api/delete"): return ("200 OK", #"{"ok":true,"title":"Test Show"}"#)
        default: return ("404 Not Found", "{}")
        }
    }
}

/// A two-channel guide whose first show is airing now. `terminalGuideEnabled` / `empty` flip the startup gates.
private func guideJSON(terminalGuideEnabled: Bool = true, empty: Bool = false) -> String {
    let winStart = Int(Date().timeIntervalSince1970) / 1800 * 1800
    let channels = empty ? "[]" : """
    [{"guideNumber":"5.1","guideName":"KFOO","hd":true,"favorite":false,"entries":[
        {"title":"Test Show","startTime":\(winStart),"endTime":\(winStart + 3600),"isRecording":false,"isScheduled":false},
        {"title":"Later Show","startTime":\(winStart + 3600),"endTime":\(winStart + 7200),"isRecording":false,"isScheduled":false}]},
     {"guideNumber":"7.1","guideName":"KBAR","hd":true,"favorite":false,"entries":[
        {"title":"Other Show","startTime":\(winStart),"endTime":\(winStart + 3600),"isRecording":false,"isScheduled":false}]}]
    """
    return """
    {"deviceId":\(empty ? "\"\"" : "\"AABBCCDD\""),"winStart":\(winStart),"winSec":86400,
     "devices":[{"deviceId":"AABBCCDD","active":0,"total":2}],"channels":\(channels),
     "sportsPaddingEnabled":true,"terminalGuideEnabled":\(terminalGuideEnabled)}
    """
}

/// A larger guide for navigation/search tests: `channels` channels ("CH00"…, numbers 4.1, 4.2 … 4.9, 5.1 …) with `entries`
/// one-hour shows each, starting at the top of the window. Generic titles are "Show cNN eKK" (NN = channel index, KK = entry
/// index) so a test can check that the selected show really belongs to the selected channel. A few catalogue titles repeat across
/// channels for search: "News at Six" (channels 0,5,10,… entry 2), "News at Ten" (same channels, entry 5), "Newsroom Weekly"
/// (channels 0,3,6,… that aren't news channels, entry 3), "Cooking Wizard" (channels 0,7,14,… entry 1).
private func bigGuideJSON(channels: Int = 25, entries: Int = 10) -> String {
    let winStart = Int(Date().timeIntervalSince1970) / 1800 * 1800
    func title(_ i: Int, _ k: Int) -> String {
        if i % 5 == 0 && k == 2 { return "News at Six" }
        if i % 5 == 0 && k == 5 { return "News at Ten" }
        if i % 3 == 0 && i % 5 != 0 && k == 3 { return "Newsroom Weekly" }
        if i % 7 == 0 && k == 1 { return "Cooking Wizard" }
        return String(format: "Show c%02d e%02d", i, k)
    }
    let chans = (0..<channels).map { i -> String in
        let number = "\(4 + i / 9).\(i % 9 + 1)"
        let es = (0..<entries).map { k in
            #"{"title":"\#(title(i, k))","startTime":\#(winStart + k * 3600),"endTime":\#(winStart + (k + 1) * 3600),"isRecording":false,"isScheduled":false}"#
        }.joined(separator: ",")
        return #"{"guideNumber":"\#(number)","guideName":"\#(String(format: "CH%02d", i))","hd":true,"favorite":false,"entries":[\#(es)]}"#
    }.joined(separator: ",")
    return """
    {"deviceId":"AABBCCDD","winStart":\(winStart),"winSec":86400,
     "devices":[{"deviceId":"AABBCCDD","active":0,"total":2}],"channels":[\(chans)],
     "sportsPaddingEnabled":true,"terminalGuideEnabled":true}
    """
}

// MARK: running the binary

private func binaryURL() -> URL? {
    var candidates: [URL] = []
    // The executables sit next to the test bundle(s) in the products directory…
    for bundle in Bundle.allBundles where bundle.bundleURL.pathExtension == "xctest" {
        candidates.append(bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("hdhr_guide"))
    }
    // …and `.build/debug` in the repo is the fallback.
    let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    candidates.append(repoRoot.appendingPathComponent(".build/debug/hdhr_guide"))
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
}

/// A missing binary is a failure, not a skip: a silent pass here would mean the TUI is untested without anyone knowing.
private func requireBinary() -> URL? {
    if let url = binaryURL() { return url }
    Issue.record("hdhr_guide binary not found — run `swift build` (the test target depends on it, so `swift test` should build it)")
    return nil
}

private func say(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

private func stripANSI(_ s: String) -> String {
    s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
}

/// Runs the binary with plain pipes (no TTY) until it exits — enough for the startup checks that run before raw mode.
private func runWithoutTTY(port: Int, timeout: TimeInterval = 15) -> (status: Int32, output: String)? {
    guard let exe = requireBinary() else { return nil }
    let p = Process()
    p.executableURL = exe
    p.environment = ["HDHR_GUIDE_PORT": String(port), "PATH": "/usr/bin:/bin"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    killer.cancel()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

/// The binary on a real pseudo-terminal (it needs a TTY for raw mode and its window size).
/// A background thread drains the terminal continuously: a pty's buffer is small, so a child that is writing a
/// frame while nobody reads blocks — and then never sees the next key.
private final class PTYSession: @unchecked Sendable {
    let process = Process()
    private let master: Int32
    private let lock = NSLock()
    private var _output = ""

    var output: String { lock.lock(); defer { lock.unlock() }; return _output }

    init?(port: UInt16, cols: UInt16 = 120, rows: UInt16 = 40) {
        guard let exe = requireBinary() else { return nil }
        var m: Int32 = 0, s: Int32 = 0
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&m, &s, nil, nil, &ws) == 0 else { return nil }
        master = m
        let slave = FileHandle(fileDescriptor: s, closeOnDealloc: false)
        process.executableURL = exe
        process.environment = ["HDHR_GUIDE_PORT": String(port), "TERM": "xterm-256color", "PATH": "/usr/bin:/bin"]
        process.standardInput = slave
        process.standardOutput = slave
        process.standardError = slave
        do { try process.run() } catch { close(m); close(s); return nil }
        close(s)   // the child has its own copy; closing ours lets the master see EOF when it exits
        let fd = m
        Thread.detachNewThread { [weak self] in
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { break }
                guard let self else { break }
                let chunk = String(decoding: buf[0..<n], as: UTF8.self)
                self.lock.lock(); self._output += chunk; self.lock.unlock()
            }
        }
    }

    deinit { if process.isRunning { process.terminate() }; close(master) }

    func send(_ s: String) {
        let bytes = Array(s.utf8)
        _ = bytes.withUnsafeBufferPointer { write(master, $0.baseAddress, $0.count) }
    }

    /// Waits until the (ANSI-stripped) output contains `text`.
    @discardableResult
    func waitFor(_ text: String, timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if stripANSI(output).contains(text) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return stripANSI(output).contains(text)
    }

    // MARK: screen model

    /// Lines of the most recent *complete* frame (ANSI stripped, blank lines dropped). Frames are written atomically between
    /// the synchronized-output markers (ESC[?2026h … ESC[?2026l), so a half-written frame is never returned.
    func lastFrame() -> [String] {
        let frames = output.components(separatedBy: "\u{1B}[?2026h").filter { $0.contains("\u{1B}[?2026l") }
        guard let f = frames.last else { return [] }
        return stripANSI(f).components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// The channel the grid's ">" gutter marker is on, e.g. ("5.3", "CH11").
    func selectedChannel() -> (number: String, name: String)? {
        for l in lastFrame() {
            if let m = l.range(of: #"^> (\d+\.\d+) (CH\d+)"#, options: .regularExpression) {
                let parts = l[m].dropFirst(2).split(separator: " ")
                return (String(parts[0]), String(parts[1]))
            }
        }
        return nil
    }

    /// The selected show's title from the summary header ("> <title>") in normal mode.
    func selectedTitle() -> String? {
        let f = lastFrame()
        guard f.count > 1, f[1].hasPrefix("> ") else { return nil }
        return String(f[1].dropFirst(2))
    }

    /// The footer hint line (search mode shows "/query_  ^v show 1/3  <> airing 1/5 …"), or the normal key hint.
    func footer() -> String { lastFrame().first { $0.hasPrefix("/") || $0.hasPrefix("^v channel") } ?? "" }

    /// Waits until `predicate` holds for the current frame (polling), returning whether it did.
    @discardableResult
    func waitForFrame(timeout: TimeInterval = 6, _ predicate: (PTYSession) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if predicate(self) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return predicate(self)
    }

    /// Waits until nothing new has been printed for `quiet` seconds (the child has consumed its input and redrawn).
    func waitIdle(quiet: TimeInterval = 0.45, timeout: TimeInterval = 8) {
        let deadline = Date().addingTimeInterval(timeout)
        var last = output.utf8.count
        var since = Date()
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            let now = output.utf8.count
            if now != last { last = now; since = Date() }
            else if Date().timeIntervalSince(since) >= quiet { return }
        }
    }

    /// Sends a long run of keys in small chunks (a pty's input buffer is small — a huge single write would block or drop).
    func sendKeys(_ keys: [String], perChunk: Int = 40, pause: TimeInterval = 0.06) {
        var i = 0
        while i < keys.count {
            send(keys[i..<min(keys.count, i + perChunk)].joined())
            i += perChunk
            Thread.sleep(forTimeInterval: pause)
        }
    }

    func waitForExit(timeout: TimeInterval = 6) -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        Thread.sleep(forTimeInterval: 0.15)   // let the reader thread pick up the last bytes (screen-restore sequences)
        return process.isRunning ? nil : process.terminationStatus
    }
}

// MARK: tests

@Suite("hdhr_guide — smoke tests of the real binary", .serialized)
struct TUIGuideSmokeTests {

    // Startup gates (run before raw mode, so no TTY needed)

    @Test func serverUnreachable_exitsWithAnActionableMessage() {
        guard let r = runWithoutTTY(port: 1) else { return }     // nothing listens on port 1
        #expect(r.status == 1)
        #expect(r.output.contains("can't reach the web server at 127.0.0.1:1."))   // names the port actually used
        #expect(r.output.contains("Enable Web LAN"))
    }

    @Test func terminalGuideSwitchedOff_exitsAndSaysSo() throws {
        let stub = StubGuideServer(guideJSON: guideJSON(terminalGuideEnabled: false))
        try stub.start(); defer { stub.stop() }
        guard let r = runWithoutTTY(port: Int(stub.port)) else { return }
        #expect(r.status == 1)
        #expect(r.output.contains("disabled"))
        #expect(r.output.contains("Terminal Guide"))
    }

    @Test func noTunerYet_exitsAndTellsTheUserToWait() throws {
        let stub = StubGuideServer(guideJSON: guideJSON(empty: true))
        try stub.start(); defer { stub.stop() }
        guard let r = runWithoutTTY(port: Int(stub.port)) else { return }
        #expect(r.status == 1)
        #expect(r.output.contains("no HDHomeRun tuner detected"))
    }

    // Running on a pseudo-terminal

    @Test func rendersTheGuide_andQuitsCleanlyOnQ_restoringTheTerminal() throws {
        let stub = StubGuideServer(guideJSON: guideJSON())
        try stub.start(); defer { stub.stop() }
        guard let tty = PTYSession(port: stub.port) else { return }

        #expect(tty.waitFor("KFOO"), "channel name never rendered; got: \(stripANSI(tty.output).prefix(300))")
        #expect(stripANSI(tty.output).contains("Test Show"))
        #expect(tty.output.contains("\u{1B}[?1049h"), "should enter the alternate screen")

        tty.send("q")
        #expect(tty.waitForExit() == 0, "q should quit with status 0")
        #expect(tty.output.contains("\u{1B}[?1049l"), "should leave the alternate screen")
        #expect(tty.output.contains("\u{1B}[?25h"), "should show the cursor again")
    }

    @Test func fKeyTogglesTheSelectedChannelsFavorite_overHTTP() throws {
        let stub = StubGuideServer(guideJSON: guideJSON())
        try stub.start(); defer { stub.stop() }
        guard let tty = PTYSession(port: stub.port) else { return }
        #expect(tty.waitFor("KFOO"))

        tty.send("f")
        let post = stub.waitForRequest("POST", "/api/toggle-favorite")
        #expect(post != nil, "no POST /api/toggle-favorite reached the server")
        #expect(tty.waitFor("\u{2713}"), "status line should confirm the toggle (✓), got: \(stripANSI(tty.output).suffix(200))")
        #expect(post?.body.contains("\"guideNumber\":\"5.1\"") == true)
        #expect(post?.body.contains("AABBCCDD") == true)
        tty.send("q"); _ = tty.waitForExit()
    }

    @Test func downArrowMovesTheSelection_soFTogglesTheOtherChannel() throws {
        let stub = StubGuideServer(guideJSON: guideJSON())
        try stub.start(); defer { stub.stop() }
        guard let tty = PTYSession(port: stub.port) else { return }
        #expect(tty.waitFor("KBAR"))

        tty.send("\u{1B}[B")          // down arrow
        Thread.sleep(forTimeInterval: 0.6)
        tty.send("f")
        let post = stub.waitForRequest("POST", "/api/toggle-favorite")
        #expect(post?.body.contains("\"guideNumber\":\"7.1\"") == true)
        #expect(tty.waitFor("\u{2713} Favorited: 7.1 KBAR"))
        tty.send("q"); _ = tty.waitForExit()
    }

    @Test func sigterm_restoresTheTerminalBeforeExiting() throws {
        let stub = StubGuideServer(guideJSON: guideJSON())
        try stub.start(); defer { stub.stop() }
        guard let tty = PTYSession(port: stub.port) else { return }
        #expect(tty.waitFor("KFOO"))

        tty.process.terminate()       // SIGTERM — the handler sets a flag; the loop must restore the screen on its way out
        #expect(tty.waitForExit() != nil, "should exit on SIGTERM")
        #expect(tty.output.contains("\u{1B}[?1049l"), "SIGTERM must still leave the alternate screen")
        #expect(tty.output.contains("\u{1B}[?25h"), "SIGTERM must still show the cursor")
    }

    @Test func requestsGoToTheConfiguredPort_notAHardcodedOne() throws {
        let stub = StubGuideServer(guideJSON: guideJSON())
        try stub.start(); defer { stub.stop() }
        guard let tty = PTYSession(port: stub.port) else { return }
        #expect(tty.waitFor("KFOO"))
        #expect(stub.requests.contains { $0.method == "GET" && $0.path.hasPrefix("/api/guide.json") })
        tty.send("q"); _ = tty.waitForExit()
    }

    // MARK: arrow-key navigation (a lot of it)

    private enum K {
        static let up = "\u{1B}[A", down = "\u{1B}[B", right = "\u{1B}[C", left = "\u{1B}[D"
    }

    /// "Show c07 e03" → (channel index 7, entry 3); nil for the catalogue titles.
    private func parseGeneric(_ title: String) -> (channel: Int, entry: Int)? {
        let parts = title.split(separator: " ")
        guard parts.count == 3, parts[0] == "Show", parts[1].hasPrefix("c"), parts[2].hasPrefix("e"),
              let c = Int(parts[1].dropFirst()), let e = Int(parts[2].dropFirst()) else { return nil }
        return (c, e)
    }

    private func launchBig(channels: Int = 25, entries: Int = 10) throws -> (StubGuideServer, PTYSession)? {
        let stub = StubGuideServer(guideJSON: bigGuideJSON(channels: channels, entries: entries))
        try stub.start()
        guard let tty = PTYSession(port: stub.port) else { stub.stop(); return nil }
        guard tty.waitFor("CH00") else { Issue.record("grid never rendered: \(tty.lastFrame().prefix(5))"); stub.stop(); return nil }
        return (stub, tty)
    }

    @Test func downThenUpArrow_walkEveryChannel_andClampAtBothEnds() throws {
        guard let (stub, tty) = try launchBig() else { return }
        defer { stub.stop() }
        #expect(tty.selectedChannel()?.name == "CH00")

        // One press at a time through the first dozen channels: each press moves exactly one row.
        for i in 1...12 {
            tty.send(K.down)
            let expected = String(format: "CH%02d", i)
            #expect(tty.waitForFrame { $0.selectedChannel()?.name == expected }, "down #\(i): expected \(expected), on \(String(describing: tty.selectedChannel()))")
        }
        // A burst well past the end must stop at the last channel (clamp, not wrap).
        tty.sendKeys(Array(repeating: K.down, count: 60))
        tty.waitIdle()
        #expect(tty.selectedChannel()?.name == "CH24")
        // …and the same back up past the top.
        tty.sendKeys(Array(repeating: K.up, count: 80))
        tty.waitIdle()
        #expect(tty.selectedChannel()?.name == "CH00")
        tty.send("q"); #expect(tty.waitForExit() == 0)
    }

    @Test func leftRightArrow_cycleAChannelsShows_thenKeepPagingTheTimelineAtTheEnds() throws {
        guard let (stub, tty) = try launchBig() else { return }
        defer { stub.stop() }
        // CH01 has only generic titles ("Show c01 eKK"); CH00 carries the search catalogue's repeated titles.
        tty.send(K.down)
        #expect(tty.waitForFrame { $0.selectedChannel()?.name == "CH01" })
        #expect(tty.waitForFrame { $0.selectedTitle().flatMap(self.parseGeneric)?.entry == 0 }, "should start on the first show")

        for k in 1...9 {
            tty.send(K.right)
            #expect(tty.waitForFrame { $0.selectedTitle().flatMap(self.parseGeneric)?.entry == k }, "right #\(k): on \(String(describing: tty.selectedTitle()))")
        }
        // Past the last show the timeline pages instead; the selection stays on the last show and nothing breaks.
        tty.sendKeys(Array(repeating: K.right, count: 25))
        tty.waitIdle()
        #expect(tty.selectedTitle().flatMap(parseGeneric)?.entry == 9)
        tty.sendKeys(Array(repeating: K.left, count: 40))
        tty.waitIdle()
        #expect(tty.selectedTitle().flatMap(parseGeneric)?.entry == 0)
        // The channel never changed while cycling shows.
        #expect(tty.selectedChannel()?.name == "CH01")
        tty.send("q"); #expect(tty.waitForExit() == 0)
    }

    @Test func aLongSeededWalkOfAllFourArrowsAndPaging_neverDesyncsTheSelectionOrCrashes() throws {
        guard let (stub, tty) = try launchBig() else { return }
        defer { stub.stop() }
        var rng = SystemRandomNumberGenerator()
        let seed = UInt64.random(in: 1...UInt64.max, using: &rng)
        var state = seed
        func next() -> Int { state = state &* 6364136223846793005 &+ 1442695040888963407; return Int(state >> 33) }
        let keys = [K.up, K.down, K.left, K.right, "[", "]"]
        let walk = (0..<480).map { _ in keys[next() % keys.count] }
        say("arrow walk seed \(seed)")

        var checked = 0
        var i = 0
        while i < walk.count {
            tty.sendKeys(Array(walk[i..<min(walk.count, i + 40)]))
            i += 40
            tty.waitIdle()
            #expect(tty.process.isRunning, "the TUI died after \(i) keys (seed \(seed))")
            guard let ch = tty.selectedChannel(), let channelIndex = Int(ch.name.dropFirst(2)) else {
                Issue.record("no selected channel in the frame after \(i) keys (seed \(seed)): \(tty.lastFrame().prefix(6))"); break
            }
            #expect((0..<25).contains(channelIndex))
            // The selected show must belong to the selected channel — a desync between the row and entry selection would break this.
            if let title = tty.selectedTitle(), let g = parseGeneric(title) {
                #expect(g.channel == channelIndex, "selected show '\(title)' is not on \(ch.name) (seed \(seed), after \(i) keys)")
                #expect((0..<10).contains(g.entry))
                checked += 1
            }
        }
        #expect(checked > 3, "too few generic-title checkpoints (\(checked)) to mean anything")
        tty.send("q"); #expect(tty.waitForExit() == 0)
    }

    // MARK: search

    @Test func slash_searchCyclesShowsWithUpDown_andAiringsWithLeftRight_clampingAtTheEnds() throws {
        guard let (stub, tty) = try launchBig() else { return }
        defer { stub.stop() }

        tty.send("/")
        #expect(tty.waitForFrame { $0.footer().hasPrefix("/_") })
        for c in "news" { tty.send(String(c)) }
        // 3 matching shows (sorted: News at Six, News at Ten, Newsroom Weekly); the first has 5 airings (channels 0,5,10,15,20).
        #expect(tty.waitForFrame { $0.footer().contains("show 1/3") }, "footer: \(tty.footer())")
        #expect(tty.footer().contains("airing 1/5"))
        #expect(tty.selectedChannel()?.name == "CH00", "first match should be focused")

        // ← / → cycle that show's airings: each moves the grid to the next channel airing it, clamping at both ends.
        for n in 2...5 {
            tty.send(K.right)
            #expect(tty.waitForFrame { $0.footer().contains("airing \(n)/5") }, "right → airing \(n): \(tty.footer())")
            #expect(tty.selectedChannel()?.name == String(format: "CH%02d", (n - 1) * 5))
        }
        tty.sendKeys(Array(repeating: K.right, count: 10)); tty.waitIdle()
        #expect(tty.footer().contains("airing 5/5"), "→ must clamp at the last airing: \(tty.footer())")
        tty.sendKeys(Array(repeating: K.left, count: 12)); tty.waitIdle()
        #expect(tty.footer().contains("airing 1/5"), "← must clamp at the first airing: \(tty.footer())")

        // ↑ / ↓ cycle the shows, clamping at both ends.
        tty.send(K.down)
        #expect(tty.waitForFrame { $0.footer().contains("show 2/3") }, "footer: \(tty.footer())")
        tty.sendKeys(Array(repeating: K.down, count: 6)); tty.waitIdle()
        #expect(tty.footer().contains("show 3/3"), "↓ must clamp at the last show: \(tty.footer())")
        tty.sendKeys(Array(repeating: K.up, count: 6)); tty.waitIdle()
        #expect(tty.footer().contains("show 1/3"), "↑ must clamp at the first show: \(tty.footer())")

        // Enter on a match opens the record screen for it; Esc returns to the grid.
        tty.send("\r")
        #expect(tty.waitFor("Schedule Recording"))
        #expect(tty.lastFrame().contains { $0.contains("News at Six") })
        tty.send("\u{1B}")
        #expect(tty.waitForFrame { $0.footer().hasPrefix("^v channel") }, "Esc should return to the normal grid: \(tty.footer())")
        tty.send("q"); #expect(tty.waitForExit() == 0)
    }

    @Test func searchResultsAreCappedAtEight_andDownStopsOnTheEighth() throws {
        guard let (stub, tty) = try launchBig() else { return }
        defer { stub.stop() }
        tty.send("/")
        for c in "show" { tty.send(String(c)) }       // matches ~250 distinct titles; the list is capped
        #expect(tty.waitForFrame { $0.footer().contains("show 1/8") }, "footer: \(tty.footer())")
        tty.sendKeys(Array(repeating: K.down, count: 40)); tty.waitIdle()
        #expect(tty.footer().contains("show 8/8"), "footer: \(tty.footer())")
        tty.send("\u{1B}")
        // Esc immediately followed by a key would read as one escape sequence (Alt-key) — wait for the grid first.
        #expect(tty.waitForFrame { $0.footer().hasPrefix("^v channel") }, "footer: \(tty.footer())")
        tty.send("q"); #expect(tty.waitForExit() == 0)
    }

    @Test func channelJump_hashQueryMovesTheSelectionLive() throws {
        guard let (stub, tty) = try launchBig() else { return }
        defer { stub.stop() }
        tty.send("/"); tty.send("#"); tty.send("5"); tty.send("."); tty.send("3")
        // Channel 5.3 is index 11 (numbers run 4.1…4.9, 5.1…5.9, 6.1…).
        #expect(tty.waitForFrame { $0.selectedChannel()?.number == "5.3" }, "on \(String(describing: tty.selectedChannel())); footer \(tty.footer())")
        #expect(tty.selectedChannel()?.name == "CH11")
        #expect(tty.footer().hasPrefix("/#5.3_"))
        tty.send("\r")                                // Enter confirms and closes
        #expect(tty.waitForFrame { $0.footer().hasPrefix("^v channel") })
        #expect(tty.selectedChannel()?.name == "CH11")
        tty.send("q"); #expect(tty.waitForExit() == 0)
    }

    @Test func insideSearch_qAndFAreJustText_andEscapeGivesTheCommandsBack() throws {
        guard let (stub, tty) = try launchBig() else { return }
        defer { stub.stop() }
        tty.send("/"); tty.send("q"); tty.send("f")
        #expect(tty.waitForFrame { $0.footer().hasPrefix("/qf_") }, "footer: \(tty.footer())")
        #expect(tty.process.isRunning, "q typed into a search must not quit")
        #expect(stub.requests.first { $0.method == "POST" } == nil, "f typed into a search must not toggle a favorite")

        tty.send("\u{1B}")
        #expect(tty.waitForFrame { $0.footer().hasPrefix("^v channel") })
        tty.send("f")                                   // back in normal mode, f is a command again
        #expect(stub.waitForRequest("POST", "/api/toggle-favorite") != nil)
        tty.send("q"); #expect(tty.waitForExit() == 0)
    }

    @Test func shortQueriesWaitForThreeCharacters_noMatchesSaysSo_andBackspaceUnwindsAndCancels() throws {
        guard let (stub, tty) = try launchBig() else { return }
        defer { stub.stop() }
        tty.send("/"); tty.send("n"); tty.send("e")
        #expect(tty.waitForFrame { $0.footer().contains("3+ to search") }, "footer: \(tty.footer())")

        tty.send("\u{7F}"); tty.send("\u{7F}")         // backspace ×2 empties the query…
        #expect(tty.waitForFrame { $0.footer().hasPrefix("/_") }, "footer: \(tty.footer())")
        tty.send("\u{7F}")                              // …one more on an empty query cancels the search
        #expect(tty.waitForFrame { $0.footer().hasPrefix("^v channel") }, "footer: \(tty.footer())")

        tty.send("/"); for c in "zzz" { tty.send(String(c)) }
        #expect(tty.waitForFrame { $0.footer().contains("No matches") }, "footer: \(tty.footer())")
        tty.send("\u{1B}")
        // Esc immediately followed by a key would read as one escape sequence (Alt-key) — wait for the grid first.
        #expect(tty.waitForFrame { $0.footer().hasPrefix("^v channel") }, "footer: \(tty.footer())")
        tty.send("q"); #expect(tty.waitForExit() == 0)
    }
}
