import Testing
@testable import hdhr_VCR

// Coverage for AppState.isWatchingRecordingOrRelay(recordingShowId:currentFeedRemoteURL:
// secondaryFeedRemoteURL:secondaryURL:) — the decision maintainVLCSleepAssertionIfNeeded uses each
// idleLoop() tick to decide whether to keep the Mac awake. Extracted 2026-09-19 after a code review
// found this exact bug class live: the function's inline `||` chain had no case at all for a PiP
// *secondary* playing a local Watch-Now recording relay (VLCBridge.recordingShowId is strictly
// primary-only, so watchRecordingInAppAsSecondary left no signal this check could see), meaning the
// Mac could fall asleep mid-playback in that specific combination — the exact failure class this
// function exists to prevent for the analogous FEED case (see its own 2026-09-13 doc comment).
@Suite("AppState.isWatchingRecordingOrRelay")
struct AppStateSleepAssertionTests {

    @Test func nothingActive_doesNotKeepAwake() {
        #expect(AppState.isWatchingRecordingOrRelay(
            recordingShowId: nil, currentFeedRemoteURL: nil, secondaryFeedRemoteURL: nil, secondaryURL: nil) == false)
    }

    @Test func primaryRecordingRelay_keepsAwake() {
        #expect(AppState.isWatchingRecordingOrRelay(
            recordingShowId: "show-123", currentFeedRemoteURL: nil, secondaryFeedRemoteURL: nil, secondaryURL: nil) == true)
    }

    @Test func primaryFeedRelay_keepsAwake() {
        #expect(AppState.isWatchingRecordingOrRelay(
            recordingShowId: nil, currentFeedRemoteURL: "http://mac-mini.local:5004/auto/v2.1",
            secondaryFeedRemoteURL: nil, secondaryURL: nil) == true)
    }

    @Test func secondaryFeedRelay_keepsAwake() {
        #expect(AppState.isWatchingRecordingOrRelay(
            recordingShowId: nil, currentFeedRemoteURL: nil,
            secondaryFeedRemoteURL: "http://mac-mini.local:5004/auto/v2.1", secondaryURL: nil) == true)
    }

    // The exact bug found in code review 2026-09-19 — a PiP secondary playing a local Watch-Now
    // recording relay, detectable only by secondaryURL's own shape (recordingShowId never covers
    // the secondary slot).
    @Test func secondaryWatchNowRecordingRelay_keepsAwake() {
        #expect(AppState.isWatchingRecordingOrRelay(
            recordingShowId: nil, currentFeedRemoteURL: nil, secondaryFeedRemoteURL: nil,
            secondaryURL: "http://127.0.0.1:1980/api/watch-recording?show=show-123&start=0") == true)
    }

    @Test func secondaryURLNotARecordingRelay_doesNotKeepAwake() {
        // A secondary playing an ordinary live channel — the secondaryURL check must not false-
        // positive on every non-nil secondaryURL, only ones that actually look like the local
        // recording-relay route.
        #expect(AppState.isWatchingRecordingOrRelay(
            recordingShowId: nil, currentFeedRemoteURL: nil, secondaryFeedRemoteURL: nil,
            secondaryURL: "http://1.2.3.4:5004/auto/v5.1") == false)
    }

    @Test func multipleSignalsAtOnce_stillKeepsAwake() {
        #expect(AppState.isWatchingRecordingOrRelay(
            recordingShowId: "show-123", currentFeedRemoteURL: "http://mac-mini.local:5004/auto/v2.1",
            secondaryFeedRemoteURL: "http://other-mac.local:5004/auto/v9.1",
            secondaryURL: "http://127.0.0.1:1980/api/watch-recording?show=show-999") == true)
    }
}
