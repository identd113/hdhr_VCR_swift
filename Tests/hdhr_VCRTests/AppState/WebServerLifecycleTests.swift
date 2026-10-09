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
    // Free ports found at test time instead of hard-coded numbers, so a leftover listener (or a
    // parallel `swift test`) can't collide. Failures seen under full-suite load were the *wait*
    // expiring (neither running nor error set after 2 s — a slow bind, not a port clash), so the
    // wait loops below also allow 10 s.
    static let testPort = freePort()
    // Distinct from testPort, not reused across both tests — found 2026-09-11: `.serialized` only
    // orders the two tests, it doesn't make the first test's `defer { state.webServer.stop() }`
    // finish the real async NWListener teardown before the second test starts (`stop()`'s own real
    // socket close completes via a callback; `defer` bodies can't `await` it). A real, reproducible
    // flake under full-suite load — the second test's own bind onto the still-closing first
    // listener's port could fail outright, not just run slow. Using a second port sidesteps the
    // teardown-timing race entirely rather than trying to win it.
    static let secondTestPort = freePort()

    private static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return Int.random(in: 20_000...40_000) }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { return Int.random(in: 20_000...40_000) }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return got == 0 ? Int(UInt16(bigEndian: addr.sin_port)) : Int.random(in: 20_000...40_000)
    }

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

        for _ in 0..<500 where !state.webServerRunning && state.webServerError == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        #expect(state.webServerRunning == true)
        #expect(state.webServerError == nil)

        state.releaseInternalWebServer()
    }

    @MainActor
    @Test func disablingWhileAnInternalClaimIsActive_keepsServerRunning() async throws {
        let state = makeTestAppState()
        state.config.Web_server_port = Self.secondTestPort
        defer { state.webServer.stop() }

        state.config.Web_server_enabled = true
        state.setupWebServer()
        for _ in 0..<500 where !state.webServerRunning && state.webServerError == nil {
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
