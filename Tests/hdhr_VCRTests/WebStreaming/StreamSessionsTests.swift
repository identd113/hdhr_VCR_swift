import Foundation
import Testing
@testable import hdhr_VCR

@Suite("Stream sessions (web streaming manager)", .serialized)
struct StreamSessionsTests {
    private var fixture: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/sample-mpeg2-ac3.ts").path
    }

    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("streams-\(UUID().uuidString)") }

    private func options() -> HLSFollower.Options {
        var o = HLSFollower.Options()
        o.convert.videoKbps = 800
        o.convert.segmentSeconds = 1
        o.passInterval = 0.2
        return o
    }

    /// Answers every lookup the same way; `enabled` can be flipped from the test.
    private final class Answers: @unchecked Sendable {
        private let lock = NSLock()
        private var on: Bool
        let path: String?
        let isRecording: Bool
        init(enabled: Bool, path: String?, isRecording: Bool = false) { on = enabled; self.path = path; self.isRecording = isRecording }
        func setEnabled(_ v: Bool) { lock.lock(); on = v; lock.unlock() }
        func snapshot(_ ids: [String]) -> StreamSnapshot {
            lock.lock(); defer { lock.unlock() }
            var map: [String: StreamSource] = [:]
            if let path { for id in ids { map[id] = StreamSource(path: path, isRecording: isRecording) } }
            return StreamSnapshot(enabled: on, sources: map)
        }
    }

    private func make(_ answers: Answers, root: URL, idle: Double = 30, timeout: Double = 2) -> StreamSessions {
        StreamSessions(root: root, idleSeconds: idle, lookupTimeout: timeout, followerOptions: options(), snapshot: { answers.snapshot($0) })
    }

    private func waitForFile(_ sessions: StreamSessions, show: String, name: String, seconds: Double = 15) async -> URL? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let url = await sessions.file(showId: show, name: name) { return url }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    @Test func idsWithPathCharactersAreRejected() {
        #expect(StreamSessions.isValidShowId("1A2B-3c_4"))
        for bad in ["", "../x", "a/b", "a b", "a.b", "é", String(repeating: "a", count: 65)] { #expect(!StreamSessions.isValidShowId(bad)) }
    }

    @Test func nothingStartsWhenStreamingIsOffOrTheShowHasNoFile() async {
        let r = root()
        let off = make(Answers(enabled: false, path: fixture), root: r)
        #expect(await off.touch(showId: "show1") == nil)
        let none = make(Answers(enabled: true, path: nil), root: r)
        #expect(await none.touch(showId: "show1") == nil)
        let missing = make(Answers(enabled: true, path: "/nonexistent/file.ts", isRecording: true), root: r)
        #expect(await missing.touch(showId: "show1") == nil)
        #expect(await off.activeCount == 0)
        #expect(!FileManager.default.fileExists(atPath: r.path))
    }

    @Test func servesAPlaylistAndSegmentsAndOnlyThoseNames() async throws {
        let r = root(); defer { try? FileManager.default.removeItem(at: r) }
        let sessions = make(Answers(enabled: true, path: fixture), root: r)
        let playlist = try #require(await waitForFile(sessions, show: "show1", name: "index.m3u8"))
        #expect(try String(contentsOf: playlist, encoding: .utf8).contains("#EXTM3U"))
        #expect(await sessions.activeCount == 1)
        #expect(await sessions.file(showId: "show1", name: "../../etc/passwd") == nil)
        #expect(await sessions.file(showId: "show1", name: "seg-1.m4s") == nil)
        await sessions.stopAll(reason: "test")
    }

    @Test func quietSessionsAreRemovedWithTheirFiles() async throws {
        let r = root(); defer { try? FileManager.default.removeItem(at: r) }
        let sessions = make(Answers(enabled: true, path: fixture), root: r, idle: 5)
        _ = try #require(await waitForFile(sessions, show: "show1", name: "index.m3u8"))
        await sessions.tick(now: Date())                              // just touched: stays
        #expect(await sessions.isActive("show1"))
        await sessions.tick(now: Date().addingTimeInterval(60))      // a minute of silence: goes
        #expect(await !sessions.isActive("show1"))
        #expect(!FileManager.default.fileExists(atPath: r.appendingPathComponent("show1").path))
    }

    @Test func turningTheFlagOffStopsEverythingOnTheNextTick() async throws {
        let r = root(); defer { try? FileManager.default.removeItem(at: r) }
        let answers = Answers(enabled: true, path: fixture)
        let sessions = make(answers, root: r)
        _ = try #require(await waitForFile(sessions, show: "show1", name: "index.m3u8"))
        answers.setEnabled(false)
        await sessions.tick()
        #expect(await sessions.activeCount == 0)
        #expect(await sessions.touch(showId: "show1") == nil)
    }

    @Test func aStalledAppDoesNotStallTheManager() async throws {
        let r = root(); defer { try? FileManager.default.removeItem(at: r) }
        // The first lookup (starting the session) answers; every later one never returns, like a frozen main thread.
        let calls = CallCounter()
        let ans = Answers(enabled: true, path: fixture)
        let sessions = StreamSessions(root: r, lookupTimeout: 0.3, followerOptions: options(), snapshot: { ids in
            if calls.next() > 1 { try? await Task.sleep(nanoseconds: 60_000_000_000) }
            return ans.snapshot(ids)
        })
        let playlist = try #require(await waitForFile(sessions, show: "show1", name: "index.m3u8"))
        let started = Date()
        await sessions.tick()                                           // lookup hangs: gives up after ~0.3 s, keeps the session
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(await sessions.isActive("show1"))
        #expect(await sessions.file(showId: "show1", name: "index.m3u8") == playlist)   // running sessions are still served
        let fresh = Date()
        #expect(await sessions.touch(showId: "other") == nil)           // a NEW session cannot start without an answer…
        #expect(Date().timeIntervalSince(fresh) < 3)                    // …but it fails fast instead of hanging
        await sessions.stopAll(reason: "test")
    }

    @Test func sweepRemovesLeftoversFromAPreviousRun() async throws {
        let r = root()
        try FileManager.default.createDirectory(at: r.appendingPathComponent("old"), withIntermediateDirectories: true)
        try Data([1]).write(to: r.appendingPathComponent("old/seg-00001.m4s"))
        await make(Answers(enabled: true, path: nil), root: r).sweepLeftovers()
        #expect(!FileManager.default.fileExists(atPath: r.path))
    }

    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    }
}
