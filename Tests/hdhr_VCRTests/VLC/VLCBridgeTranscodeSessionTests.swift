import Foundation
import Testing
@testable import hdhr_VCR

// Regression coverage for the 2026-09-04 transcodeViewerCount double-decrement bug: WebServer's
// beginTranscodeRelay/pumpTranscodeProxy cleanup paths were calling
// AppState.transcodeViewerDisconnected() unconditionally after VLCBridge.stopTranscodeSession,
// even when that show's session had already been force-cleared elsewhere (stopAllTranscodeSessions,
// on recording stop) — silently no-op'ing on the VLCBridge side while still decrementing the
// separate app-wide aggregate counter, under-counting a *different*, still-actively-transcoding
// show. The fix makes stopTranscodeSession/stopAllTranscodeSessions report whether they actually
// released anything, so a caller mirroring the count elsewhere can gate its own decrement on it.
// These two "nothing was running" cases don't need a real libvlc session (no VLC install
// required) — they exercise exactly the call shape that caused the bug: stopping a show that was
// never started, or was already cleared.
@Suite("VLCBridge transcode session — stop-without-a-running-session contract")
struct VLCBridgeTranscodeSessionTests {

    @MainActor
    @Test func stopTranscodeSession_returnsFalse_whenNoSessionIsRunning() {
        let showId = "nonexistent-show-\(UUID().uuidString)"
        #expect(VLCBridge.shared.stopTranscodeSession(showId: showId) == false)
    }

    @MainActor
    @Test func stopAllTranscodeSessions_returnsZero_whenNoSessionIsRunning() {
        let showId = "nonexistent-show-\(UUID().uuidString)"
        #expect(VLCBridge.shared.stopAllTranscodeSessions(showId: showId) == 0)
    }
}
