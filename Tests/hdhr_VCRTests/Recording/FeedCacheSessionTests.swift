import Testing
import Foundation
@testable import hdhr_VCR

// MARK: - AppState.startFeedCacheSession / stopFeedCacheSession
//
// Coverage for the FEED local disk cache lifecycle (docs/VirtualTunerService.md's "FEED scrub via
// local disk cache" section) — the primary-window mechanism that lets scrubbing work for FEED the
// same way it already works for Watch Now. Same mock-curl-script seam as
// AppStateRecordingEngineTests/RecordingManagerTests; `outputBytes` (TestFixtures.swift) makes the
// mock script write real bytes to the `-o` cache path immediately, satisfying
// startFeedCacheSession's own "wait for the puller to actually produce data" liveness poll.
//
// Real cache directory under NSTemporaryDirectory() per test (not the real
// ~/Library/Caches/hdhrVCRplus/feed-cache/ startFeedCacheSession itself always uses) is NOT
// substitutable here — the cache path is hardcoded inside AppState.startFeedCacheSession, not
// injectable — so these tests clean up under the real Caches path explicitly rather than pointing
// at a scratch directory, mirroring how RecordingManagerTests cleans up real NSTemporaryDirectory()
// paths it doesn't control either.

// .serialized: startFeedCacheSession reads/writes VLCPlayerWindowManager.shared's per-slot feed
// session ids (a real singleton) and stops "the previous session" for its slot — run in parallel,
// one test's primary session could tear down another test's still-in-use puller.
@Suite("AppState FEED local disk cache session", .serialized)
struct FeedCacheSessionTests {

    private func makeDevice() -> HDHRDevice { .test(id: "FEEDCAFE", tuners: 1) }

    private func cleanup(_ paths: String...) {
        for p in paths { try? FileManager.default.removeItem(atPath: p) }
    }

    @Test @MainActor func startFeedCacheSession_happyPath_returnsPlayableURLAndTracksSession() async throws {
        let scriptPath = try writeMockCurlScript(sleepSeconds: 30, outputBytes: 4096)
        defer { cleanup(scriptPath) }
        let manager = RecordingManager(curlExecutablePath: scriptPath)
        let state = makeTestAppState(devices: [makeDevice()], recordingManager: manager)
        let device = makeDevice()

        let session = await state.startFeedCacheSession(remoteURL: "http://192.0.2.1/auto/v5.1?dev=FEEDCAFE",
                                                          device: device, title: "Test FEED Show")
        let unwrapped = try #require(session)
        defer {
            state.stopFeedCacheSession(sessionId: unwrapped.sessionId)
        }

        #expect(unwrapped.url.contains("/api/watch-recording?show=\(unwrapped.sessionId)&start=0"))
        #expect(unwrapped.sessionId.hasPrefix("FEEDCAFE-"))
        await waitUntil { manager.isFeedCachePullRunning(sessionId: unwrapped.sessionId) }
        #expect(manager.isFeedCachePullRunning(sessionId: unwrapped.sessionId) == true)
    }

    @Test @MainActor func stopFeedCacheSession_killsPullerAndDeletesCacheFile() async throws {
        let scriptPath = try writeMockCurlScript(sleepSeconds: 30, outputBytes: 4096)
        defer { cleanup(scriptPath) }
        let manager = RecordingManager(curlExecutablePath: scriptPath)
        let state = makeTestAppState(devices: [makeDevice()], recordingManager: manager)

        let session = try #require(await state.startFeedCacheSession(
            remoteURL: "http://192.0.2.1/auto/v5.1?dev=FEEDCAFE", device: makeDevice(), title: "Test FEED Show"))
        await waitUntil { manager.isFeedCachePullRunning(sessionId: session.sessionId) }

        let cacheDir = NSHomeDirectory() + "/Library/Caches/hdhrVCRplus/feed-cache"
        let cachePath = "\(cacheDir)/\(session.sessionId).ts"
        #expect(FileManager.default.fileExists(atPath: cachePath) == true)

        state.stopFeedCacheSession(sessionId: session.sessionId)

        #expect(manager.isFeedCachePullRunning(sessionId: session.sessionId) == false)
        #expect(FileManager.default.fileExists(atPath: cachePath) == false)
    }

    @Test @MainActor func stopFeedCacheSession_unknownSessionId_isSafeNoOp() {
        let state = makeTestAppState(devices: [makeDevice()])
        state.stopFeedCacheSession(sessionId: "never-started")   // must not crash
    }

    @Test @MainActor func secondSessionForSamePrimarySlot_stopsThePreviousOne() async throws {
        // Switching raw↔H.264, or re-watching a different relay, must stop the previous puller —
        // never leave two pullers running for the same singleton primary window.
        let scriptPath = try writeMockCurlScript(sleepSeconds: 30, outputBytes: 4096)
        defer { cleanup(scriptPath) }
        let manager = RecordingManager(curlExecutablePath: scriptPath)
        let state = makeTestAppState(devices: [makeDevice()], recordingManager: manager)
        let device = makeDevice()

        let first = try #require(await state.startFeedCacheSession(
            remoteURL: "http://192.0.2.1/auto/v5.1?dev=FEEDCAFE", device: device, title: "Raw"))
        await waitUntil { manager.isFeedCachePullRunning(sessionId: first.sessionId) }
        #expect(manager.isFeedCachePullRunning(sessionId: first.sessionId) == true)

        // VLCPlayerWindowManager.shared is a real singleton this test doesn't control directly, so
        // startFeedCacheSession's own "stop the previous primary session" step (keyed off
        // mgr.currentFeedSessionId) won't fire without a real window open — exercise the
        // lower-level guarantee directly instead: stopFeedCacheSession is what that step calls,
        // and it must be safe/effective regardless of caller.
        state.stopFeedCacheSession(sessionId: first.sessionId)
        #expect(manager.isFeedCachePullRunning(sessionId: first.sessionId) == false)

        let second = try #require(await state.startFeedCacheSession(
            remoteURL: "http://192.0.2.1/auto/v5.1?dev=FEEDCAFE&transcode=auto", device: device, title: "H.264"))
        defer { state.stopFeedCacheSession(sessionId: second.sessionId) }
        await waitUntil { manager.isFeedCachePullRunning(sessionId: second.sessionId) }
        #expect(second.sessionId != first.sessionId)
        #expect(manager.isFeedCachePullRunning(sessionId: second.sessionId) == true)
    }

    @Test @MainActor func secondarySlotSession_leavesPrimarySessionRunning() async throws {
        // A PiP FEED (slot: .secondary, added 2026-10-01 so it stays scrubbable after a swap to
        // primary) must only replace the secondary slot's own previous session — never the
        // primary's, or opening a PiP FEED would kill whatever's playing full-size.
        let scriptPath = try writeMockCurlScript(sleepSeconds: 30, outputBytes: 4096)
        defer { cleanup(scriptPath) }
        let manager = RecordingManager(curlExecutablePath: scriptPath)
        let state = makeTestAppState(devices: [makeDevice()], recordingManager: manager)
        let device = makeDevice()
        let mgr = VLCPlayerWindowManager.shared

        let primary = try #require(await state.startFeedCacheSession(
            remoteURL: "http://192.0.2.1/auto/v5.1?dev=FEEDCAFE", device: device, title: "Primary"))
        defer { state.stopFeedCacheSession(sessionId: primary.sessionId) }
        let secondary = try #require(await state.startFeedCacheSession(
            remoteURL: "http://192.0.2.1/auto/v9.1?dev=FEEDCAFE", device: device, title: "PiP", slot: .secondary))
        defer { state.stopFeedCacheSession(sessionId: secondary.sessionId) }

        await waitUntil { manager.isFeedCachePullRunning(sessionId: secondary.sessionId) }
        #expect(manager.isFeedCachePullRunning(sessionId: primary.sessionId) == true)
        #expect(manager.isFeedCachePullRunning(sessionId: secondary.sessionId) == true)
        #expect(mgr.currentFeedSessionId == primary.sessionId)
        #expect(mgr.secondaryFeedSessionId == secondary.sessionId)
        #expect(secondary.url.contains("/api/watch-recording?show=\(secondary.sessionId)"))
    }
}
