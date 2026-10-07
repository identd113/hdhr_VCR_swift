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
}
