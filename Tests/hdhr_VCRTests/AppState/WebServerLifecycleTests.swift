import Testing
import Foundation
@testable import hdhr_VCR

// Regression coverage for AppState.reconcileWebServerState() — the single arbiter that replaced
// setupWebServer()/ensureWebServerRunning() each calling webServer.start() directly. The direct-call
// design let two independent triggers race a real NWListener bind on the same port when both fired
// back-to-back before the first's async .ready callback landed (their shared guard, `webServerRunning`,
// doesn't flip true until then) — reproduced live 2026-09-03 at launch whenever a show was already
// recording (reattachRecordings()'s virtual-tuner claim immediately followed by setupWebServer()'s
// own unconditional start), producing "Address already in use" and leaving the *entire* web server
// down, not just the virtual-tuner routes. See docs/VirtualTunerService.md's "A device visible but
// with no channels" section and docs/AppState.md's reconcileWebServerState() row for the full story.
//
// Uses a real ephemeral bind (like VirtualTunerLiveStreamTests' own real-socket tests) — dedicated
// port 19802, distinct from that suite's 19801, so the two never collide if run together.
@Suite("AppState web server lifecycle — reconcileWebServerState race regression", .serialized)
struct WebServerLifecycleTests {
    static let testPort = 19802

    @MainActor
    @Test func backToBackTriggers_atLaunch_doNotRaceASecondBind() async throws {
        let state = makeTestAppState()
        state.config.Web_server_port = Self.testPort
        defer { state.webServer.stop() }

        // Reproduces the exact launch race: an internal claim (e.g. the virtual-tuner relay's own
        // claim, fired from reattachRecordings()) kicks off a bind, then — in the same synchronous
        // launch sequence, before that bind's async .ready callback has any chance to land — Sharing
        // being on fires the second trigger. Before the fix, both called webServer.start() directly.
        state.ensureWebServerRunning()
        state.config.Web_server_enabled = true
        state.setupWebServer()

        for _ in 0..<100 where !state.webServerRunning && state.webServerError == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        #expect(state.webServerRunning == true)
        #expect(state.webServerError == nil)

        state.releaseInternalWebServer()
    }

    @MainActor
    @Test func disablingWhileAnInternalClaimIsActive_keepsServerRunning() async throws {
        let state = makeTestAppState()
        state.config.Web_server_port = Self.testPort
        defer { state.webServer.stop() }

        state.config.Web_server_enabled = true
        state.setupWebServer()
        for _ in 0..<100 where !state.webServerRunning && state.webServerError == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(state.webServerRunning == true)

        // An internal claim (guide window, Watch Now relay, virtual tuner) must keep the server up
        // even after Sharing is turned back off — releaseInternalWebServer's own count==0 gate is
        // what actually tears it down, not this toggle alone.
        state.ensureWebServerRunning()
        state.config.Web_server_enabled = false
        state.setupWebServer()

        #expect(state.webServerRunning == true)
        #expect(state.webServerError == nil)

        state.releaseInternalWebServer()
    }
}
