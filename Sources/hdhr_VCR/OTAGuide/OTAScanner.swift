import Foundation

// Over-the-air guide (overtime/APP_PLAN.md). Sweeps the ATSC band of one HDHomeRun by raw frequency (`/tunerN/ch<Hz>`), feeds each
// multiplex's bytes to PSIPDecoder as they arrive (the raw stream is never stored), and returns what every multiplex announced.
//
// An actor, off the main thread. It talks to the app only through `Environment` closures, and it follows the tuner rules:
//  - only a tuner the hardware reports idle, never one it does not own, and never more tuners than are free after the app's own
//    recordings / viewers (`appBusyTuners`);
//  - it does not start a capture when a recording is about to start, and abandons one that is (`secondsUntilNextRecording`);
//  - cancelling the task closes the stream at once, which frees the tuner.

struct OTAScanEnvironment: Sendable {
    var host: String
    var tunerCount: Int
    /// Tuners this app is using for recordings / the in-app player, right now.
    var appBusyTuners: @Sendable () async -> Int
    /// Seconds until the next scheduled recording on this device starts, or nil if none is due.
    var secondsUntilNextRecording: @Sendable () async -> TimeInterval?
    /// How many tuners the user currently allows the scan (the window's pulldown). Read between channels: lowering it lets a running
    /// capture finish and then leaves that worker idle; raising it puts an idle worker back to work within a second.
    var tunerLimit: @Sendable () async -> Int = { Int.max }
    /// Called whenever the set of tuners ("tuner0"…) this scan is holding changes, so the app can tell its own use from the scan's.
    var onHeldChange: @Sendable (Set<String>) -> Void = { _ in }
    /// True while the app wants a tuner back right now (a live stream or recording is about to start): the scan drops its captures,
    /// takes no new tuner, and puts the interrupted channels back in the queue.
    var yieldRequested: @Sendable () async -> Bool = { false }
}

/// What the scan window shows, as it happens.
enum OTAScanEvent: Sendable {
    case queued(total: Int)
    case started(rf: Int)
    case update(rf: Int, result: OTADecodeResult)    // about once a second while a multiplex is being read
    case finished(rf: Int, result: OTADecodeResult)
    case skipped(rf: Int, why: String)
    case paused(rf: Int)                              // put back in the queue because a tuner was needed; read again later
}

struct OTAMultiplex: Sendable, Equatable {
    var rf: Int
    var frequencyHz: Int
    var result: OTADecodeResult
    var bytes: Int
}

struct OTAScanOutcome: Sendable {
    var multiplexes: [OTAMultiplex] = []
    /// RF channel → why nothing was kept ("no signal", "no guide tables", "tuner in use", "recording due"…).
    var skipped: [Int: String] = [:]
    var cancelled = false
}

actor OTAScanner {
    /// ATSC 1.0 plan, centre frequency of each 6 MHz channel (RF 37 is radio astronomy and is skipped).
    static func frequencyHz(rf: Int) -> Int? {
        switch rf {
        case 2...4:   return (54 + 6 * (rf - 2) + 3) * 1_000_000
        case 5...6:   return (76 + 6 * (rf - 5) + 3) * 1_000_000
        case 7...13:  return (174 + 6 * (rf - 7) + 3) * 1_000_000
        case 14...51: return (470 + 6 * (rf - 14) + 3) * 1_000_000
        default:      return nil
        }
    }
    static let allRFChannels: [Int] = Array(2...36) + Array(38...51)

    private var queue: [Int] = []
    private var claimed: Set<String> = []
    private var outcome = OTAScanOutcome()
    private var finished = 0
    private var total = 0
    private var events: @Sendable (OTAScanEvent) -> Void = { _ in }

    /// Scans `rfChannels` (default: the whole band), up to `env.tunerCount` at a time. `progress` gets short status lines.
    func scan(env: OTAScanEnvironment, rfChannels: [Int] = OTAScanner.allRFChannels, secondsPerChannel: TimeInterval = 90, lineupOnly: Bool = false,
              onEvent: @escaping @Sendable (OTAScanEvent) -> Void = { _ in },
              progress: @escaping @Sendable (String) -> Void) async -> OTAScanOutcome {
        queue = rfChannels.filter { Self.frequencyHz(rf: $0) != nil }
        outcome = OTAScanOutcome()
        claimed = []
        finished = 0
        total = queue.count
        events = onEvent
        onHeldChange = env.onHeldChange
        onEvent(.queued(total: total))
        let workers = max(1, env.tunerCount)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<workers {
                group.addTask { [self] in
                    while !Task.isCancelled, await self.hasWork() {
                        // Worker `index` only runs while the user's tuner limit is above it.
                        if index >= max(1, await env.tunerLimit()) { try? await Task.sleep(nanoseconds: 1_000_000_000); continue }
                        guard let rf = await self.nextChannel() else { break }
                        if let pause = await self.scanOne(rf: rf, env: env, seconds: secondsPerChannel, lineupOnly: lineupOnly, progress: progress) {
                            try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
                        }
                    }
                }
            }
        }
        outcome.cancelled = Task.isCancelled
        return outcome
    }

    private func hasWork() -> Bool { !queue.isEmpty }

    private func nextChannel() -> Int? { queue.isEmpty ? nil : queue.removeFirst() }

    /// Puts a channel back at the front of the queue (the scan paused instead of dropping it).
    private func requeue(_ rf: Int, why: String, progress: @Sendable (String) -> Void) {
        queue.insert(rf, at: 0)
        events(.paused(rf: rf))
        progress("RF \(rf): paused, \(why)")
    }

    private func record(rf: Int, multiplex: OTAMultiplex?, skipped: String?, progress: @Sendable (String) -> Void) {
        finished += 1
        if let multiplex {
            events(.finished(rf: rf, result: multiplex.result))
            outcome.multiplexes.append(multiplex)
            progress("RF \(rf): \(multiplex.result.channels.count) channels, \(multiplex.result.events.count) events (\(finished)/\(total))")
        } else if let skipped {
            events(.skipped(rf: rf, why: skipped))
            outcome.skipped[rf] = skipped
            progress("RF \(rf): \(skipped) (\(finished)/\(total))")
        }
    }

    /// Reads one RF channel. Returns nil when it finished (read or skipped for good), or how long the worker should wait when it
    /// paused instead (the channel is back in the queue).
    private func scanOne(rf: Int, env: OTAScanEnvironment, seconds: TimeInterval, lineupOnly: Bool, progress: @escaping @Sendable (String) -> Void) async -> TimeInterval? {
        guard let hz = Self.frequencyHz(rf: rf) else { return nil }
        // Wait (up to ~15 min) for a tuner that is free for real: idle in hardware, not ours already, and one the app does not need.
        guard let tuner = await claimTuner(env: env) else {
            record(rf: rf, multiplex: nil, skipped: Task.isCancelled ? "cancelled" : "no free tuner", progress: progress); return nil
        }
        defer { release(tuner) }
        if await env.yieldRequested() { requeue(rf, why: "a tuner is needed", progress: progress); return 2 }
        events(.started(rf: rf))
        let capture = await Self.capture(host: env.host, tuner: tuner, hz: hz, seconds: seconds, lineupOnly: lineupOnly,
                                      onUpdate: { [events] result in events(.update(rf: rf, result: result)) }) { [self] in await self.shouldYield(env: env) }
        switch capture {
        case .decoded(let result, let bytes):
            record(rf: rf, multiplex: OTAMultiplex(rf: rf, frequencyHz: hz, result: result, bytes: bytes), skipped: nil, progress: progress)
        case .skipped("tuner needed"):
            requeue(rf, why: "a tuner is needed", progress: progress); return 2
        case .skipped(let why):
            record(rf: rf, multiplex: nil, skipped: why, progress: progress)
        }
        return nil
    }

    // MARK: tuner claim

    private func claimTuner(env: OTAScanEnvironment) async -> String? {
        let deadline = Date().addingTimeInterval(15 * 60)
        while !Task.isCancelled, Date() < deadline {
            // The app is about to use a tuner (an explicit request, or a recording due in the next 20 s): take none, whichever tuner it is.
            if await env.yieldRequested() { try? await Task.sleep(nanoseconds: 1_000_000_000); continue }
            if let due = await env.secondsUntilNextRecording(), due < 20 { try? await Task.sleep(nanoseconds: 1_000_000_000); continue }
            let rows = await Self.statusRows(host: env.host)
            let appBusy = await env.appBusyTuners()
            // Tuners busy in hardware for anyone except us (our own claimed tuners show up there too).
            let externalBusy = rows.filter { $0.busy && !claimed.contains($0.resource) }.count
            let busy = max(externalBusy, appBusy)
            if let row = rows.first(where: { !$0.busy && !claimed.contains($0.resource) }), busy + claimed.count < env.tunerCount {
                claimed.insert(row.resource)
                env.onHeldChange(claimed)
                return row.resource
            }
            try? await Task.sleep(nanoseconds: 15_000_000_000)
        }
        return nil
    }

    private var onHeldChange: @Sendable (Set<String>) -> Void = { _ in }
    private func release(_ tuner: String) { claimed.remove(tuner); onHeldChange(claimed) }

    /// True when a recording is about to start, or the app has taken tuners so that it plus this scan no longer fit on the device.
    private func shouldYield(env: OTAScanEnvironment) async -> Bool {
        if await env.yieldRequested() { return true }
        if let due = await env.secondsUntilNextRecording(), due < 20 { return true }
        return await env.appBusyTuners() + claimed.count > env.tunerCount
    }

    struct StatusRow: Sendable { let resource: String; let busy: Bool }

    static func statusRows(host: String) async -> [StatusRow] {
        guard let url = URL(string: "http://\(host)/status.json"),
              let data = await LANFetch.data(from: url, label: "ota status"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return json.compactMap { row in
            guard let name = row["Resource"] as? String else { return nil }
            // A tuner in use reports a channel, a frequency or a target address; an idle one has only its name.
            let busy = row["VctNumber"] != nil || row["Frequency"] != nil || row["TargetIP"] != nil
            return StatusRow(resource: name, busy: busy)
        }
    }

    // MARK: one capture

    enum CaptureOutcome: Sendable { case decoded(OTADecodeResult, bytes: Int); case skipped(String) }

    /// Streams one multiplex into a decoder (`lineupOnly`: stops as soon as the channel list is read, a couple of seconds). Ends early when there is no signal (almost no bytes after 3 s), no guide tables after
    /// 12 s, a station that announces no guide at all (after 15 s), or when `shouldYield` says so (checked every 5 s).
    static func capture(host: String, tuner: String, hz: Int, seconds: TimeInterval, lineupOnly: Bool = false,
                        onUpdate: @escaping @Sendable (OTADecodeResult) -> Void = { _ in },
                        shouldYield: @escaping @Sendable () async -> Bool) async -> CaptureOutcome {
        guard let url = URL(string: "http://\(host):5004/\(tuner)/ch\(hz)") else { return .skipped("bad address") }
        let reader = StreamReader(url: url)
        let decoder = PSIPDecoder()
        let started = Date()
        var bytes = 0
        var lastYieldCheck = started
        var lastUpdate = started
        let outcome: CaptureOutcome = await withTaskCancellationHandler {
            for await event in reader.events {
                switch event {
                case .busy: return .skipped("no signal")   // the tuner answers 503 when a channel will not lock (we only claim idle tuners)
                case .failed(let why): return .skipped(why)
                case .data(let chunk):
                    bytes += chunk.count
                    decoder.ingest(chunk)
                }
                let elapsed = Date().timeIntervalSince(started)
                if elapsed >= 3, bytes < 100_000 { return .skipped("no signal") }
                if elapsed >= 12, !decoder.hasMasterGuide { return .skipped("no guide tables") }
                // result() copies every table, so look at it once a second, not once per 19 Mb/s chunk.
                if Date().timeIntervalSince(lastUpdate) >= 1, decoder.hasMasterGuide {
                    lastUpdate = Date()
                    let snapshot = decoder.result()
                    onUpdate(snapshot)
                    if elapsed >= 15, snapshot.announcedEITCount == 0 { break }   // names only: a guide is never coming
                    if lineupOnly, !snapshot.channels.isEmpty { break }           // the channel list repeats several times a second
                }
                if elapsed >= seconds { break }
                if Date().timeIntervalSince(lastYieldCheck) >= 1 {
                    lastYieldCheck = Date()
                    if await shouldYield() { return .skipped("tuner needed") }
                }
            }
            return .decoded(decoder.result(), bytes: bytes)
        } onCancel: { reader.cancel() }
        reader.cancel()   // closing the stream releases the tuner
        if case .decoded(let result, let n) = outcome, result.channels.isEmpty { return .skipped(n < 100_000 ? "no signal" : "no guide tables") }
        return outcome
    }
}

/// Delivers a long HTTP response a chunk at a time (URLSession's byte iterator is too slow for a 19 Mb/s stream).
private final class StreamReader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Event: Sendable { case data(Data), busy, failed(String) }
    let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private var session: URLSession?
    private var task: URLSessionDataTask?

    init(url: URL) {
        var cont: AsyncStream<Event>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        continuation = cont
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        task = session?.dataTask(with: request)
        task?.resume()
    }

    func cancel() {
        task?.cancel()
        session?.invalidateAndCancel()
        continuation.finish()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            // 503 = no tuner free (or the channel will not lock); anything else is an error page.
            continuation.yield(http.statusCode == 503 ? .busy : .failed("HTTP \(http.statusCode)"))
            continuation.finish()
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) { continuation.yield(.data(data)) }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, (error as NSError).code != NSURLErrorCancelled { continuation.yield(.failed(error.localizedDescription)) }
        continuation.finish()
    }
}
