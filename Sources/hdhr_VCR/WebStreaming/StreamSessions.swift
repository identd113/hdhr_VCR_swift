import Foundation

// Part of the web-streaming feature (docs/WebStreaming.md). One HLS session per recording that browsers are
// watching: starts an HLSFollower on first request, keeps it alive while playlists/segments are being fetched,
// and removes it (and its temp files) after a quiet period, when the feature is turned off, or at app quit.

/// What a session needs to know about a show: where its file is and whether it is still being written.
struct StreamSource: Sendable {
    let path: String
    let isRecording: Bool
}

/// The app-side facts the manager needs, fetched in one lookup: is streaming switched on, and the file of each asked-for show.
struct StreamSnapshot: Sendable {
    let enabled: Bool
    let sources: [String: StreamSource]
}

// An actor of its own, NOT the main actor: bookkeeping, file checks and the janitor never run on the main thread,
// and a stalled main thread cannot freeze streams (or the web server queue). The only contact with app state is
// `snapshot`, called with a short timeout; on a timeout the manager keeps what it already knows.
actor StreamSessions {
    /// Folder under Caches holding every session's files (one subfolder per show). Swept at launch.
    static var defaultRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("hdhrVCRplus/stream", isDirectory: true)
    }

    private final class Session {
        let directory: URL
        let growing = GrowingFlag(true)
        var task: Task<Void, Never>?
        var lastTouch = Date()
        init(directory: URL) { self.directory = directory }
    }

    /// Thread-safe "is the file still being written", read by the follower off the actor.
    final class GrowingFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool
        init(_ v: Bool) { value = v }
        var isOn: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
    }

    /// A viewer joining a recording that is still being written starts this far behind its end (the rest of the backlog is not converted).
    static let joinBehindLive = 120.0
    /// Segments kept per stream: 450 × 4 s = 30 minutes (about 0.9 GB at 4 Mb/s).
    static let keepSegments = 450

    private let root: URL
    private let snapshot: @Sendable ([String]) async -> StreamSnapshot
    private let idleSeconds: TimeInterval
    private let lookupTimeout: TimeInterval
    private let followerOptions: HLSFollower.Options
    private var sessions: [String: Session] = [:]
    private var janitor: Task<Void, Never>?
    private var enabledKnown = false   // last answer from the app; lets running sessions be served without any lookup

    init(root: URL = StreamSessions.defaultRoot,
         idleSeconds: TimeInterval = 30,
         lookupTimeout: TimeInterval = 2,
         followerOptions: HLSFollower.Options = HLSFollower.Options(startBehindLive: StreamSessions.joinBehindLive, keepSegments: StreamSessions.keepSegments),
         snapshot: @escaping @Sendable ([String]) async -> StreamSnapshot) {
        self.root = root
        self.idleSeconds = idleSeconds
        self.lookupTimeout = lookupTimeout
        self.followerOptions = followerOptions
        self.snapshot = snapshot
    }

    /// Show ids that may be used in a URL: letters, digits, `-` and `_` only (no path characters).
    nonisolated static func isValidShowId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// Deletes every session folder left behind by a previous run (a crash or force-quit). Call once at launch.
    func sweepLeftovers() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Is web streaming switched on right now? Asked of the app (with the usual timeout); on no answer, the last known value.
    func isEnabled() async -> Bool {
        if let snap = await lookup([]) { enabledKnown = snap.enabled }
        return enabledKnown
    }

    var activeCount: Int { sessions.count }
    func isActive(_ showId: String) -> Bool { sessions[showId] != nil }

    /// Asks the app for a snapshot, giving up after `lookupTimeout` (a busy or stalled main thread must not stall us).
    private func lookup(_ ids: [String]) async -> StreamSnapshot? {
        let provider = snapshot
        let timeout = lookupTimeout
        return await withTaskGroup(of: StreamSnapshot?.self) { group in
            group.addTask { await provider(ids) }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Marks the show as being watched, starting its session if needed. Returns the session folder,
    /// or nil when streaming is off, the id is not valid, the show has no file to stream, or the app did not answer in time.
    func touch(showId: String) async -> URL? {
        guard Self.isValidShowId(showId) else { return nil }
        if let existing = sessions[showId] {
            guard enabledKnown else { return nil }
            existing.lastTouch = Date()
            return existing.directory
        }
        guard let snap = await lookup([showId]) else { return nil }
        enabledKnown = snap.enabled
        guard snap.enabled, let src = snap.sources[showId], FileManager.default.fileExists(atPath: src.path) else { return nil }
        if let raced = sessions[showId] { raced.lastTouch = Date(); return raced.directory }   // another request won while we waited
        let dir = root.appendingPathComponent(showId, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)   // never serve a previous run's segments
        let session = Session(directory: dir)
        session.growing.set(src.isRecording)
        // A recording that is still being written is joined near its live end and kept as a rolling window; a finished one
        // is converted whole from the start, so every part can be reached.
        var options = followerOptions
        if !src.isRecording { options.startBehindLive = nil; options.keepSegments = nil }
        let follower = HLSFollower(input: URL(fileURLWithPath: src.path), outputDir: dir, options: options,
                                   isGrowing: { [growing = session.growing] in growing.isOn })
        session.task = Task.detached(priority: .utility) {
            do { _ = try await follower.run() } catch is CancellationError {} catch {
                // After a stop the folder is already gone and the follower may trip over that: not worth a warning.
                if !Task.isCancelled { glog("[Stream] \(showId) stopped: \(error.localizedDescription)", level: .warning) }
            }
        }
        sessions[showId] = session
        startJanitorIfNeeded()
        glog("[Stream] started web stream for show \(showId)")
        return dir
    }

    /// The file a browser asked for, if it is one we may serve and it exists. Counts as activity.
    func file(showId: String, name: String) async -> URL? {
        guard HLSPlaylist.isServableName(name), let dir = await touch(showId: showId) else { return nil }
        let url = dir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func stop(showId: String, reason: String) {
        guard let s = sessions.removeValue(forKey: showId) else { return }
        s.task?.cancel()
        try? FileManager.default.removeItem(at: s.directory)
        glog("[Stream] stopped web stream for show \(showId) (\(reason))")
    }

    func stopAll(reason: String) {
        for id in Array(sessions.keys) { stop(showId: id, reason: reason) }
        janitor?.cancel(); janitor = nil
    }

    /// One housekeeping pass: end sessions when streaming was switched off, when nobody has fetched anything for a
    /// while, or when the show vanished; tell the follower when its recording has ended so it can finish the stream.
    func tick(now: Date = Date()) async {
        for (id, s) in sessions where now.timeIntervalSince(s.lastTouch) > idleSeconds { stop(showId: id, reason: "no viewers") }
        guard !sessions.isEmpty else { janitor?.cancel(); janitor = nil; return }
        guard let snap = await lookup(Array(sessions.keys)) else { return }   // no answer: keep everything as it is
        enabledKnown = snap.enabled
        if !snap.enabled { stopAll(reason: "streaming turned off"); return }
        for (id, s) in sessions {
            if let src = snap.sources[id] { s.growing.set(src.isRecording) } else { s.growing.set(false) }
        }
    }

    private func startJanitorIfNeeded() {
        guard janitor == nil else { return }
        janitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self?.tick()
            }
        }
    }
}
