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

    @Test func allFalse_returnsNone() {
        let s = resolveGuideRingState(isRecording: false, isManaged: false, willSkip: false,
                                       isConflict: false, isOtherTunerInUse: false)
        #expect(s == .none)
    }

    @Test func recordingAlone_returnsRecording() {
        let s = resolveGuideRingState(isRecording: true, isManaged: false, willSkip: false,
                                       isConflict: false, isOtherTunerInUse: false)
        #expect(s == .recording)
    }

    @Test func managedAndWillSkip_returnsWillSkip() {
        let s = resolveGuideRingState(isRecording: false, isManaged: true, willSkip: true,
                                       isConflict: false, isOtherTunerInUse: false)
        #expect(s == .willSkip)
    }

    // willSkip alone (isManaged false) should never happen in practice — willSkip is only
    // computed when there's an owning show — but the function itself still requires isManaged
    // to be true to report .willSkip, matching the web guide's `isMgd && willSkip` guard exactly.
    @Test func willSkipWithoutManaged_doesNotReportWillSkip() {
        let s = resolveGuideRingState(isRecording: false, isManaged: false, willSkip: true,
                                       isConflict: false, isOtherTunerInUse: false)
        #expect(s != .willSkip)
    }

    @Test func conflictAlone_returnsConflict() {
        let s = resolveGuideRingState(isRecording: false, isManaged: false, willSkip: false,
                                       isConflict: true, isOtherTunerInUse: false)
        #expect(s == .conflict)
    }

    @Test func managedAlone_returnsScheduled() {
        let s = resolveGuideRingState(isRecording: false, isManaged: true, willSkip: false,
                                       isConflict: false, isOtherTunerInUse: false)
        #expect(s == .scheduled)
    }

    @Test func otherTunerAlone_returnsInUseOtherTuner() {
        let s = resolveGuideRingState(isRecording: false, isManaged: false, willSkip: false,
                                       isConflict: false, isOtherTunerInUse: true)
        #expect(s == .inUseOtherTuner)
    }

    // MARK: - Precedence: recording beats everything

    @Test func recording_beatsWillSkip() {
        let s = resolveGuideRingState(isRecording: true, isManaged: true, willSkip: true,
                                       isConflict: false, isOtherTunerInUse: false)
        #expect(s == .recording)
    }

    @Test func recording_beatsConflict() {
        let s = resolveGuideRingState(isRecording: true, isManaged: true, willSkip: false,
                                       isConflict: true, isOtherTunerInUse: false)
        #expect(s == .recording)
    }

    @Test func recording_beatsScheduled() {
        let s = resolveGuideRingState(isRecording: true, isManaged: true, willSkip: false,
                                       isConflict: false, isOtherTunerInUse: false)
        #expect(s == .recording)
    }

    @Test func recording_beatsOtherTuner() {
        let s = resolveGuideRingState(isRecording: true, isManaged: false, willSkip: false,
                                       isConflict: false, isOtherTunerInUse: true)
        #expect(s == .recording)
    }

    // MARK: - Precedence: will-skip beats conflict/scheduled/other-tuner

    @Test func willSkip_beatsConflict() {
        // Both true is not a realistic guide state (willSkip and isConflict are computed
        // exclusively of each other upstream), but the precedence must still hold if it happens.
        let s = resolveGuideRingState(isRecording: false, isManaged: true, willSkip: true,
                                       isConflict: true, isOtherTunerInUse: false)
        #expect(s == .willSkip)
    }

    @Test func willSkip_beatsOtherTuner() {
        let s = resolveGuideRingState(isRecording: false, isManaged: true, willSkip: true,
                                       isConflict: false, isOtherTunerInUse: true)
        #expect(s == .willSkip)
    }

    // MARK: - Precedence: conflict beats scheduled/other-tuner

    @Test func conflict_beatsScheduled() {
        // isManaged true + isConflict true, willSkip false — a managed show that's conflicting
        // must show conflict, not fall through to the plain "scheduled" state.
        let s = resolveGuideRingState(isRecording: false, isManaged: true, willSkip: false,
                                       isConflict: true, isOtherTunerInUse: false)
        #expect(s == .conflict)
    }

    @Test func conflict_beatsOtherTuner() {
        let s = resolveGuideRingState(isRecording: false, isManaged: false, willSkip: false,
                                       isConflict: true, isOtherTunerInUse: true)
        #expect(s == .conflict)
    }

    // MARK: - Precedence: scheduled beats other-tuner

    @Test func scheduled_beatsOtherTuner() {
        let s = resolveGuideRingState(isRecording: false, isManaged: true, willSkip: false,
                                       isConflict: false, isOtherTunerInUse: true)
        #expect(s == .scheduled)
    }
}
