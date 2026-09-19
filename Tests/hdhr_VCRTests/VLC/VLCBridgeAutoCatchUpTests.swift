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

    // MARK: nextSpuFetchAttempts

    // Found in code review 2026-09-19: fetchTracks() used to only increment spuFetchAttempts
    // inside `let ptr = _spuDesc?(mp)`, so a genuinely caption-less stream — where libvlc
    // legitimately returns NULL every tick — never advanced the counter, and spuFetchHasBudget
    // kept returning true forever instead of exhausting after maxSpuFetchAttempts.
    @Test func attemptsAdvance_whenDescriptionIsNil() {
        #expect(VLCBridge.nextSpuFetchAttempts(current: 0, descriptionWasNil: true) == 1)
        #expect(VLCBridge.nextSpuFetchAttempts(current: 3, descriptionWasNil: true) == 4)
    }

    @Test func attemptsAdvance_whenDescriptionIsPresent() {
        #expect(VLCBridge.nextSpuFetchAttempts(current: 0, descriptionWasNil: false) == 1)
        #expect(VLCBridge.nextSpuFetchAttempts(current: 3, descriptionWasNil: false) == 4)
    }

    @Test func simulatedCaptionlessStream_exhaustsBudgetAfterMaxAttempts() {
        // End-to-end simulation of the exact bug: every tick, libvlc hands back NULL (no
        // captions), and the loop must still stop polling once budget runs out.
        var attempts = 0
        var stillPolling = true
        var ticks = 0
        while stillPolling && ticks < VLCBridge.maxSpuFetchAttempts + 10 {
            guard VLCBridge.spuFetchHasBudget(spuTracksIsEmpty: true, attempts: attempts) else {
                stillPolling = false
                break
            }
            attempts = VLCBridge.nextSpuFetchAttempts(current: attempts, descriptionWasNil: true)
            ticks += 1
        }
        #expect(ticks == VLCBridge.maxSpuFetchAttempts, "must exhaust after exactly maxSpuFetchAttempts ticks, not poll forever")
        #expect(VLCBridge.spuFetchHasBudget(spuTracksIsEmpty: true, attempts: attempts) == false)
    }
}
