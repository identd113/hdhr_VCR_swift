import Testing
import Foundation
@testable import hdhr_VCR

// MARK: - Heads-up before a scheduled recording needs the tuner you're watching live on
//
// About 3 minutes before a scheduled recording that would be blocked only by this Mac's own live Watch
// Now, the app warns that live TV will stop (or switch to the recording, on the same channel). Nothing
// stops until the recording actually starts. The decision is `AppState.liveWatchWarningOutcome` — the
// pure core of `warnOfLiveWatchPreemptionIfNeeded`. What it must get right: warn only inside the lead
// window, once per airing, only when the viewer's own live stream is the *only* blocker, and never for a
// recording that won't happen anyway (skipped) or when another recording frees a tuner in time.

@Suite("AppState.liveWatchWarningOutcome")
struct LiveWatchPreemptWarningTests {

    private let epoch: TimeInterval = 1_800_000_000

    private func outcome(secondsUntilStart: TimeInterval = 120, warnedEpoch: TimeInterval? = nil,
                         blocked: Bool = true, skipped: Bool = false, freesUp: Bool = false,
                         probe: ((String) -> Void)? = nil) -> AppState.LiveWatchWarningOutcome {
        AppState.liveWatchWarningOutcome(
            secondsUntilStart: secondsUntilStart, warnedEpoch: warnedEpoch, epoch: epoch,
            blockedOnlyByOwnWatchNow: { probe?("blocked"); return blocked },
            willBeSkipped: { probe?("skipped"); return skipped },
            freesUpAnyway: { probe?("freesUp"); return freesUp })
    }

    @Test func leadTimeIsThreeMinutes() {
        #expect(AppState.liveWatchPreemptWarningLeadSeconds == 180)
    }

    @Test func warnsInsideTheWindow_andMarksTheAiring() {
        #expect(outcome() == .init(warn: true, markEvaluated: true))
        #expect(outcome(secondsUntilStart: 180) == .init(warn: true, markEvaluated: true))   // boundary included
        #expect(outcome(secondsUntilStart: 1) == .init(warn: true, markEvaluated: true))
    }

    @Test func doesNothingBeforeTheWindowOrOnceTheRecordingHasStarted() {
        #expect(outcome(secondsUntilStart: 181) == .init(warn: false, markEvaluated: false))
        #expect(outcome(secondsUntilStart: 3600) == .init(warn: false, markEvaluated: false))
        #expect(outcome(secondsUntilStart: 0) == .init(warn: false, markEvaluated: false))
        #expect(outcome(secondsUntilStart: -30) == .init(warn: false, markEvaluated: false))
    }

    @Test func warnsOncePerAiring_butAgainForTheNextAiring() {
        #expect(outcome(warnedEpoch: epoch) == .init(warn: false, markEvaluated: false))
        // A different airing (e.g. next week's episode) has a different epoch → warns again.
        #expect(outcome(warnedEpoch: epoch - 604_800) == .init(warn: true, markEvaluated: true))
    }

    @Test func notWhenSomethingOtherThanOwnLiveWatchIsTheBlocker() {
        // e.g. no live stream open, or the tuner is held by another machine — nothing for *this* player to warn about.
        #expect(outcome(blocked: false) == .init(warn: false, markEvaluated: false))
    }

    @Test func aRecordingThatWillBeSkippedAnyway_isNeverWarnedAbout_butIsMarkedSoItIsntRescanned() {
        #expect(outcome(skipped: true) == .init(warn: false, markEvaluated: true))
    }

    @Test func noWarningWhenAnotherRecordingFreesATunerByThenAnyway() {
        #expect(outcome(freesUp: true) == .init(warn: false, markEvaluated: true))
    }

    @Test func checksRunInOrder_andTheExpensiveOnesAreSkippedWhenAnEarlierCheckDecides() {
        var calls: [String] = []
        _ = outcome(secondsUntilStart: 900, probe: { calls.append($0) })      // outside window → nothing evaluated
        #expect(calls.isEmpty)

        calls = []
        _ = outcome(blocked: false, probe: { calls.append($0) })              // not blocked → stop before the disk scan
        #expect(calls == ["blocked"])

        calls = []
        _ = outcome(skipped: true, probe: { calls.append($0) })
        #expect(calls == ["blocked", "skipped"])

        calls = []
        _ = outcome(probe: { calls.append($0) })
        #expect(calls == ["blocked", "skipped", "freesUp"])

        calls = []
        _ = outcome(warnedEpoch: epoch, probe: { calls.append($0) })          // already warned → nothing evaluated
        #expect(calls.isEmpty)
    }
}
