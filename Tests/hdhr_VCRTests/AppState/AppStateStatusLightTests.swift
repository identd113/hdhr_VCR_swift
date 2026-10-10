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

    // Reversed 2026-10-10 per explicit user direction (it had been "someone must be watching" since
    // 2026-09-29): a relay merely being detected now lights the blue light — flashing — so you notice a
    // FEED is there to watch. Watching one (below) turns it solid.
    @Test @MainActor func remoteRelayWithNoViewers_nowCountsAsFeedAvailable() {
        let (device, lineups) = makeRemoteRelay(rawViewers: nil)
        let state = makeTestAppState(shows: [], devices: [device], lineups: lineups)
        state.config.FEED_feature_enabled = true
        #expect(state.statusLightCandidates == [.feedAvailable])
    }

    // Transcode viewers count the same as raw viewers — either alone is enough.
    @Test @MainActor func remoteRelayWithTranscodeViewerOnly_countsAsFeedAvailable() {
        let device = HDHRDevice.test(id: "FEEDBEEF", isVirtualRelay: true)
        let entry = LineupEntry.test(number: "9.9", showTitle: "Remote Show", rawViewers: nil, transcodeViewers: 1)
        let state = makeTestAppState(shows: [], devices: [device], lineups: [device.DeviceID: [entry]])
        state.config.FEED_feature_enabled = true
        #expect(state.statusLightCandidates == [.feedAvailable])
    }

    // MARK: - Watching a FEED → solid blue

    @Test @MainActor func playingAFeedStream_isFeedWatching_notFeedAvailable() {
        let (device, lineups) = makeRemoteRelay()
        let state = makeTestAppState(shows: [], devices: [device], lineups: lineups)
        state.config.FEED_feature_enabled = true
        state.playingStreamURLs = { ["http://127.0.0.1:1980\(LocalRelay.feedLocalRelayPath)?session=abc"] }
        #expect(state.isWatchingRemoteFeed)
        #expect(state.statusLightCandidates == [.feedWatching])
    }

    @Test @MainActor func playingSomethingElse_leavesTheFeedFlashing() {
        let (device, lineups) = makeRemoteRelay()
        let state = makeTestAppState(shows: [], devices: [device], lineups: lineups)
        state.config.FEED_feature_enabled = true
        state.playingStreamURLs = { ["http://10.0.2.101:5004/auto/v5.1"] }   // a live channel on a real tuner
        #expect(!state.isWatchingRemoteFeed)
        #expect(state.statusLightCandidates == [.feedAvailable])
    }

    @Test @MainActor func recordingWhileWatchingAFeed_showsBothInOrder() {
        let (device, lineups) = makeRemoteRelay()
        let state = makeTestAppState(shows: [.testRecording()], devices: [device], lineups: lineups)
        state.config.FEED_feature_enabled = true
        state.playingStreamURLs = { ["http://127.0.0.1:1980\(LocalRelay.feedLocalRelayPath)?session=abc"] }
        #expect(state.statusLightCandidates == [.recording, .feedWatching])
    }

    @Test func isFeedStream_recognisesTheLocalCacheAndARemoteRelayHost() {
        let hosts: Set<String> = ["10.0.2.100"]
        #expect(AppState.isFeedStream(urls: ["http://127.0.0.1:1980\(LocalRelay.feedLocalRelayPath)?session=x"], relayHosts: hosts))
        #expect(AppState.isFeedStream(urls: ["http://10.0.2.100:1980/auto/v4.1?transcode=heavy"], relayHosts: hosts))
        #expect(!AppState.isFeedStream(urls: ["http://10.0.2.101:5004/auto/v4.1"], relayHosts: hosts))
        #expect(!AppState.isFeedStream(urls: [], relayHosts: hosts))
    }

    // MARK: - Flash vs solid (AppState.statusLightState)

    private func at(_ seconds: Double) -> Date { Date(timeIntervalSinceReferenceDate: seconds) }

    @Test func aFeedThatIsMerelyAvailable_flashesEvenWithBlinkOff() throws {
        let lit = try #require(AppState.statusLightState(candidates: [.feedAvailable], blinkSetting: false, now: at(2)))
        let off = try #require(AppState.statusLightState(candidates: [.feedAvailable], blinkSetting: false, now: at(5.5)))
        #expect(lit.kind == .feedAvailable && lit.lit)
        #expect(off.kind == .feedAvailable && !off.lit, "off for the last second of the 6 s cycle")
    }

    @Test(arguments: [false, true])
    func watchingAFeed_isSolidWhateverTheBlinkSetting(_ blink: Bool) throws {
        for t in [0.5, 2, 5.5, 5.99] {
            let s = try #require(AppState.statusLightState(candidates: [.feedWatching], blinkSetting: blink, now: at(t)))
            #expect(s.kind == .feedWatching && s.lit, "solid at t=\(t)")
        }
    }

    @Test func recordingAlone_followsTheBlinkSetting() throws {
        #expect(try #require(AppState.statusLightState(candidates: [.recording], blinkSetting: false, now: at(5.5))).lit)
        #expect(!(try #require(AppState.statusLightState(candidates: [.recording], blinkSetting: true, now: at(5.5))).lit))
    }

    @Test func recordingAndAvailableFeed_takeTurns_theFeedFlashingEvenWithBlinkOff() throws {
        let c: [AppState.StatusLightKind] = [.recording, .feedAvailable]
        let red = try #require(AppState.statusLightState(candidates: c, blinkSetting: false, now: at(2)))
        let blue = try #require(AppState.statusLightState(candidates: c, blinkSetting: false, now: at(8)))
        let blueOff = try #require(AppState.statusLightState(candidates: c, blinkSetting: false, now: at(11.5)))
        #expect(red.kind == .recording && red.lit)
        #expect(blue.kind == .feedAvailable && blue.lit)
        #expect(blueOff.kind == .feedAvailable && !blueOff.lit)
        // …and the recording's own turn is solid, not flashing, because blink is off
        #expect(try #require(AppState.statusLightState(candidates: c, blinkSetting: false, now: at(5.5))).lit)
    }

    @Test func recordingWhileWatchingAFeed_blinkOff_showsTheFirstSteadily() throws {
        let c: [AppState.StatusLightKind] = [.recording, .feedWatching]
        for t in [2.0, 8.0] {
            let s = try #require(AppState.statusLightState(candidates: c, blinkSetting: false, now: at(t)))
            #expect(s.kind == .recording && s.lit, "nothing flashes, so the long-standing pick-first-steadily rule applies")
        }
    }

    @Test func recordingWhileWatchingAFeed_blinkOn_theFeedsTurnIsSolid() throws {
        let c: [AppState.StatusLightKind] = [.recording, .feedWatching]
        #expect(!(try #require(AppState.statusLightState(candidates: c, blinkSetting: true, now: at(5.5))).lit), "red flashes")
        let blue = try #require(AppState.statusLightState(candidates: c, blinkSetting: true, now: at(11.5)))
        #expect(blue.kind == .feedWatching && blue.lit, "blue's turn stays lit through the whole 6 s")
    }

    @Test func noCandidates_isIdle() {
        #expect(AppState.statusLightState(candidates: [], blinkSetting: true, now: at(1)) == nil)
    }

    // MARK: - Double-click on the menu bar icon

    @Test func iconDoubleClick_isAQuickOpenCloseWithThePointerStillOnTheIcon() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        let top: CGFloat = 1117   // a screen's maxY
        func dbl(_ dt: Double, from: CGPoint, to: CGPoint) -> Bool {
            AppState.isIconDoubleClick(began: t0, beganAt: from, ended: t0.addingTimeInterval(dt), endedAt: to, screenTopY: top)
        }
        let icon = CGPoint(x: 1500, y: top - 10)
        #expect(dbl(0.25, from: icon, to: icon))                                   // the real thing
        #expect(!dbl(0.9, from: icon, to: icon))                                   // slow: a normal open-then-dismiss
        #expect(!dbl(0.25, from: icon, to: CGPoint(x: 1500, y: top - 200)))        // ended down in the menu (picked an item)
        #expect(!dbl(0.25, from: icon, to: CGPoint(x: 1700, y: top - 10)))         // pointer moved off the icon
        #expect(!dbl(0.25, from: CGPoint(x: 600, y: 300), to: CGPoint(x: 600, y: 300)))   // a right-click menu in a window
    }
}
