import Testing
@testable import hdhr_VCR

// Pure-arithmetic coverage for tickPrimary()'s two independent auto-catch-up triggers (matching
// VLCBridgeRateRampTests' own precedent of extracting pure decisions for unit testing — no real
// libvlc session needed).
//
// Corruption trigger (i_demux_corrupted delta) predates this session; sustained-stall trigger was
// added 2026-09-19 to close a real gap it found live: a connection that stalls with literally zero
// new bytes has nothing to corrupt, so the corruption trigger alone can never fire for it — a real
// "no new bytes either — network-side" STALL sat frozen indefinitely with no auto-recovery. The
// sustained-stall trigger is gated on the window being visible specifically to avoid reintroducing
// the false-positive risk that was the *reason* corruption (not raw stall detection) was chosen as
// the original trigger — a backgrounded window can look "stalled" on position alone while decode
// continues fine.
@Suite("VLCBridge auto-catch-up triggers")
struct VLCBridgeAutoCatchUpTests {

    // MARK: shouldCatchUpForCorruption

    @Test func corruption_belowThreshold_doesNotTrigger() {
        #expect(VLCBridge.shouldCatchUpForCorruption(corruptDelta: 15) == false)
        #expect(VLCBridge.shouldCatchUpForCorruption(corruptDelta: 0) == false)
    }

    @Test func corruption_aboveThreshold_triggers() {
        #expect(VLCBridge.shouldCatchUpForCorruption(corruptDelta: 16) == true)
        #expect(VLCBridge.shouldCatchUpForCorruption(corruptDelta: 1000) == true)
    }

    @Test func corruption_respectsCustomThreshold() {
        #expect(VLCBridge.shouldCatchUpForCorruption(corruptDelta: 5, threshold: 5) == false)
        #expect(VLCBridge.shouldCatchUpForCorruption(corruptDelta: 6, threshold: 5) == true)
    }

    // MARK: shouldCatchUpForSustainedStall

    @Test func sustainedStall_belowThreshold_neverTriggers_evenIfVisible() {
        #expect(VLCBridge.shouldCatchUpForSustainedStall(consecutiveStalledTicks: 0, windowVisible: true) == false)
        #expect(VLCBridge.shouldCatchUpForSustainedStall(consecutiveStalledTicks: 2, windowVisible: true) == false)
    }

    @Test func sustainedStall_atOrAboveThreshold_triggersOnlyWhenVisible() {
        #expect(VLCBridge.shouldCatchUpForSustainedStall(consecutiveStalledTicks: 3, windowVisible: true) == true)
        #expect(VLCBridge.shouldCatchUpForSustainedStall(consecutiveStalledTicks: 3, windowVisible: false) == false)
        #expect(VLCBridge.shouldCatchUpForSustainedStall(consecutiveStalledTicks: 100, windowVisible: false) == false,
                "a long stall in a backgrounded window must never auto-reconnect — the whole reason this trigger is window-gated")
    }

    @Test func sustainedStall_defaultThresholdMatchesConstant() {
        #expect(VLCBridge.sustainedStallThreshold == 3)
    }

    @Test func sustainedStall_respectsCustomThreshold() {
        #expect(VLCBridge.shouldCatchUpForSustainedStall(consecutiveStalledTicks: 1, windowVisible: true, threshold: 1) == true)
        #expect(VLCBridge.shouldCatchUpForSustainedStall(consecutiveStalledTicks: 0, windowVisible: true, threshold: 1) == false)
    }

    // MARK: spuFetchHasBudget

    @Test func spuFetch_emptyWithBudgetRemaining_hasBudget() {
        #expect(VLCBridge.spuFetchHasBudget(spuTracksIsEmpty: true, attempts: 0) == true)
        #expect(VLCBridge.spuFetchHasBudget(spuTracksIsEmpty: true, attempts: VLCBridge.maxSpuFetchAttempts - 1) == true)
    }

    @Test func spuFetch_budgetExhausted_noLongerRetries() {
        #expect(VLCBridge.spuFetchHasBudget(spuTracksIsEmpty: true, attempts: VLCBridge.maxSpuFetchAttempts) == false)
        #expect(VLCBridge.spuFetchHasBudget(spuTracksIsEmpty: true, attempts: VLCBridge.maxSpuFetchAttempts + 5) == false)
    }

    @Test func spuFetch_alreadyFound_stopsRetryingRegardlessOfBudget() {
        // Once spuTracks is non-empty, there's nothing left to poll for — must be false even on
        // attempt 0, so a stream that finds captions immediately doesn't keep re-querying forever.
        #expect(VLCBridge.spuFetchHasBudget(spuTracksIsEmpty: false, attempts: 0) == false)
    }

    @Test func spuFetch_respectsCustomMax() {
        #expect(VLCBridge.spuFetchHasBudget(spuTracksIsEmpty: true, attempts: 1, max: 2) == true)
        #expect(VLCBridge.spuFetchHasBudget(spuTracksIsEmpty: true, attempts: 2, max: 2) == false)
    }
}
