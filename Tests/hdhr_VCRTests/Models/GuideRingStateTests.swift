import Testing
@testable import hdhr_VCR

// MARK: - resolveGuideRingState precedence
//
// Pins the exact precedence order (recording > will-skip > conflict > scheduled >
// in-use-by-other-tuner) that both WebServer.swift's HTML grid and WatchNowView's native ring
// share — this is the one place a drift between the two rendering surfaces would be silent and
// hard to notice (a block just showing the "wrong" color, not a crash or a test failure anywhere
// else). Exercises every state directly plus the pairwise combinations that exist specifically to
// prove one state wins over another.

@Suite("resolveGuideRingState precedence")
struct GuideRingStateTests {

    // One (5 bools → expected state) table instead of 15 near-identical bodies — every row calls
    // resolveGuideRingState with the same 5 named args and compares to one expected GuideRingState.
    // Row order mirrors the original grouping (base cases, then each precedence pairing) and each
    // row keeps its original test name as a comment so a failure is still easy to trace back.
    @Test(arguments: [
        // Base cases: each flag alone.
        (isRecording: false, isManaged: false, willSkip: false, isConflict: false, isOtherTunerInUse: false, expected: GuideRingState.none),               // allFalse_returnsNone
        (isRecording: true,  isManaged: false, willSkip: false, isConflict: false, isOtherTunerInUse: false, expected: GuideRingState.recording),           // recordingAlone_returnsRecording
        (isRecording: false, isManaged: true,  willSkip: true,  isConflict: false, isOtherTunerInUse: false, expected: GuideRingState.willSkip),            // managedAndWillSkip_returnsWillSkip
        // willSkip alone (isManaged false) should never happen in practice — willSkip is only
        // computed when there's an owning show — but the function itself still requires isManaged
        // to be true to report .willSkip, matching the web guide's `isMgd && willSkip` guard
        // exactly, so this falls all the way through to .none.
        (isRecording: false, isManaged: false, willSkip: true,  isConflict: false, isOtherTunerInUse: false, expected: GuideRingState.none),                // willSkipWithoutManaged_doesNotReportWillSkip
        (isRecording: false, isManaged: false, willSkip: false, isConflict: true,  isOtherTunerInUse: false, expected: GuideRingState.conflict),            // conflictAlone_returnsConflict
        (isRecording: false, isManaged: true,  willSkip: false, isConflict: false, isOtherTunerInUse: false, expected: GuideRingState.scheduled),           // managedAlone_returnsScheduled
        (isRecording: false, isManaged: false, willSkip: false, isConflict: false, isOtherTunerInUse: true,  expected: GuideRingState.inUseOtherTuner),     // otherTunerAlone_returnsInUseOtherTuner
        // Precedence: recording beats everything.
        (isRecording: true,  isManaged: true,  willSkip: true,  isConflict: false, isOtherTunerInUse: false, expected: GuideRingState.recording),           // recording_beatsWillSkip
        (isRecording: true,  isManaged: true,  willSkip: false, isConflict: true,  isOtherTunerInUse: false, expected: GuideRingState.recording),           // recording_beatsConflict
        (isRecording: true,  isManaged: true,  willSkip: false, isConflict: false, isOtherTunerInUse: false, expected: GuideRingState.recording),           // recording_beatsScheduled
        (isRecording: true,  isManaged: false, willSkip: false, isConflict: false, isOtherTunerInUse: true,  expected: GuideRingState.recording),           // recording_beatsOtherTuner
        // Precedence: will-skip beats conflict/scheduled/other-tuner. Both willSkip and isConflict
        // true is not a realistic guide state (they're computed exclusively of each other
        // upstream), but the precedence must still hold if it happens.
        (isRecording: false, isManaged: true,  willSkip: true,  isConflict: true,  isOtherTunerInUse: false, expected: GuideRingState.willSkip),            // willSkip_beatsConflict
        (isRecording: false, isManaged: true,  willSkip: true,  isConflict: false, isOtherTunerInUse: true,  expected: GuideRingState.willSkip),            // willSkip_beatsOtherTuner
        // Precedence: conflict beats scheduled/other-tuner. isManaged true + isConflict true,
        // willSkip false — a managed show that's conflicting must show conflict, not fall through
        // to the plain "scheduled" state.
        (isRecording: false, isManaged: true,  willSkip: false, isConflict: true,  isOtherTunerInUse: false, expected: GuideRingState.conflict),            // conflict_beatsScheduled
        (isRecording: false, isManaged: false, willSkip: false, isConflict: true,  isOtherTunerInUse: true,  expected: GuideRingState.conflict),            // conflict_beatsOtherTuner
        // Precedence: scheduled beats other-tuner.
        (isRecording: false, isManaged: true,  willSkip: false, isConflict: false, isOtherTunerInUse: true,  expected: GuideRingState.scheduled),           // scheduled_beatsOtherTuner
    ])
    func precedence(_ row: (isRecording: Bool, isManaged: Bool, willSkip: Bool, isConflict: Bool, isOtherTunerInUse: Bool, expected: GuideRingState)) {
        let s = resolveGuideRingState(isRecording: row.isRecording, isManaged: row.isManaged, willSkip: row.willSkip,
                                       isConflict: row.isConflict, isOtherTunerInUse: row.isOtherTunerInUse)
        #expect(s == row.expected)
    }
}
