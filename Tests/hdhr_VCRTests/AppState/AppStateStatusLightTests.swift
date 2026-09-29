import Testing
import Foundation
@testable import hdhr_VCR

// MARK: - AppState.statusLightCandidates — menu bar status light tier/priority logic
//
// Covers the tier design added 2026-09-06, live, per explicit user direction: `.recording` and
// `.feedAvailable` are equally "important" (tickStatusLight() cycles the light between both when
// both are true, each getting its own full blink cycle — see that function's own doc comment for
// the timing, not covered here since it depends on wall-clock Date() and isn't worth the
// complexity of injecting a clock just for this). `.upNext` is strictly subordinate — shown only
// when NEITHER of the other two is active, per the user's own example: "if a show was recording,
// there is a show on next up, and there is a feed available, we would not show the next up blink,
// just the red and blue."
//
// Tests statusLightCandidates directly (internal, not private, for exactly this reason) rather
// than the private tickStatusLight()/statusLightOn timer machinery, since the tier/priority
// decision is the part with real branching logic worth a regression guard — the cycling arithmetic
// once candidates are known is straightforward modulo math already reasoned through in review.

@Suite("AppState.statusLightCandidates — tier priority")
struct AppStateStatusLightTests {

    // rawViewers defaults to 1 — hasAvailableRemoteFeed requires a real viewer (raw + transcode
    // summed > 0), not just an existing relay (resolved 2026-09-29, see TODO.md's "FEED-available
    // status light" entry) — so a relay built by this helper reads as feedAvailable by default,
    // matching what most of these tests actually want to exercise (the tier/priority logic, not
    // the viewer-count gate itself — that gate gets its own dedicated test below).
    private func makeRemoteRelay(showTitle: String = "Remote Show", rawViewers: Int? = 1) -> (device: HDHRDevice, lineup: [String: [LineupEntry]]) {
        let device = HDHRDevice.test(id: "FEEDBEEF", isVirtualRelay: true)
        let entry = LineupEntry.test(number: "9.9", showTitle: showTitle, rawViewers: rawViewers)
        return (device, [device.DeviceID: [entry]])
    }

    @Test @MainActor func nothingActive_returnsEmpty() {
        let state = makeTestAppState(shows: [], devices: [], lineups: [:])
        #expect(state.statusLightCandidates.isEmpty)
    }

    @Test @MainActor func recordingOnly_returnsRecording() {
        let state = makeTestAppState(shows: [.testRecording()], devices: [], lineups: [:])
        #expect(state.statusLightCandidates == [.recording])
    }

    @Test @MainActor func feedAvailableOnly_returnsFeedAvailable() {
        let (device, lineups) = makeRemoteRelay()
        let state = makeTestAppState(shows: [], devices: [device], lineups: lineups)
        state.config.FEED_feature_enabled = true   // master hide switch — off by default, see its own doc comment
        #expect(state.statusLightCandidates == [.feedAvailable])
    }

    @Test @MainActor func upNextOnly_returnsUpNext() {
        var show = Show.testActive()
        show.show_next = Date().addingTimeInterval(15 * 60)   // 15 min out — inside the 1-hour window
        let state = makeTestAppState(shows: [show], devices: [], lineups: [:])
        #expect(state.statusLightCandidates == [.upNext(minutes: 15)])
    }

    @Test @MainActor func recordingAndFeedAvailable_returnsBothInOrder() {
        let (device, lineups) = makeRemoteRelay()
        let state = makeTestAppState(shows: [.testRecording()], devices: [device], lineups: lineups)
        state.config.FEED_feature_enabled = true   // master hide switch — off by default, see its own doc comment
        #expect(state.statusLightCandidates == [.recording, .feedAvailable])
    }

    // The exact scenario the user described: recording + a show up next + a FEED available must
    // show only [.recording, .feedAvailable] — up next never appended once tier 1 is non-empty.
    @Test @MainActor func recordingPlusUpNextPlusFeedAvailable_suppressesUpNext() {
        let (device, lineups) = makeRemoteRelay()
        var upNextShow = Show.testActive(title: "Something Later")
        upNextShow.show_next = Date().addingTimeInterval(10 * 60)
        let state = makeTestAppState(shows: [.testRecording(), upNextShow], devices: [device], lineups: lineups)
        state.config.FEED_feature_enabled = true   // master hide switch — off by default, see its own doc comment
        #expect(state.statusLightCandidates == [.recording, .feedAvailable])
    }

    @Test @MainActor func recordingPlusUpNext_suppressesUpNext() {
        var upNextShow = Show.testActive(title: "Something Later")
        upNextShow.show_next = Date().addingTimeInterval(10 * 60)
        let state = makeTestAppState(shows: [.testRecording(), upNextShow], devices: [], lineups: [:])
        #expect(state.statusLightCandidates == [.recording])
    }

    // Mirrors the fix from the same session: an unavailable relay must not surface as feedAvailable.
    @Test @MainActor func unavailableRemoteRelay_doesNotCountAsFeedAvailable() {
        var (device, lineups) = makeRemoteRelay()
        device.missedProbes = 3   // isAvailable == false
        let state = makeTestAppState(shows: [], devices: [device], lineups: lineups)
        state.config.FEED_feature_enabled = true   // isolate the isAvailable guard from the master hide switch (also off)
        #expect(state.statusLightCandidates.isEmpty)
    }

    // Resolved 2026-09-29 (TODO.md's "FEED-available status light" entry): a relay merely existing
    // is no longer enough — someone has to actually be watching it (raw + transcode viewer count
    // summed > 0). A relay with a show attached but zero of either must not light the blue dot.
    @Test @MainActor func remoteRelayWithNoViewers_doesNotCountAsFeedAvailable() {
        let (device, lineups) = makeRemoteRelay(rawViewers: nil)
        let state = makeTestAppState(shows: [], devices: [device], lineups: lineups)
        state.config.FEED_feature_enabled = true
        #expect(state.statusLightCandidates.isEmpty)
    }

    // Transcode viewers count the same as raw viewers — either alone is enough.
    @Test @MainActor func remoteRelayWithTranscodeViewerOnly_countsAsFeedAvailable() {
        let device = HDHRDevice.test(id: "FEEDBEEF", isVirtualRelay: true)
        let entry = LineupEntry.test(number: "9.9", showTitle: "Remote Show", rawViewers: nil, transcodeViewers: 1)
        let state = makeTestAppState(shows: [], devices: [device], lineups: [device.DeviceID: [entry]])
        state.config.FEED_feature_enabled = true
        #expect(state.statusLightCandidates == [.feedAvailable])
    }
}
