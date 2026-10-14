import Testing
@testable import hdhr_VCR

// T15: a stream's commit (state reset, timers) used to be matched by the slot play() started on, so a PiP swap
// while it was connecting dropped it. It is now matched by player object + URL.
@Suite("VLCBridge.owningSlot")
struct OwningSlotTests {
    private func owner(_ url: String, mp: Int, prefer: VLCBridge.PlayerSlot,
                       primary: (Int?, String?), secondary: (Int?, String?)) -> VLCBridge.PlayerSlot? {
        VLCBridge.owningSlot(of: url, on: mp, preferring: prefer, primary: primary, secondary: secondary)
    }

    @Test func unchanged_returnsTheSlotItStartedOn() {
        #expect(owner("u", mp: 1, prefer: .primary, primary: (1, "u"), secondary: (2, "x")) == .primary)
        #expect(owner("u", mp: 2, prefer: .secondary, primary: (1, "x"), secondary: (2, "u")) == .secondary)
    }

    @Test func swappedWhileConnecting_followsThePlayer() {
        // Started on the secondary (player 2, "u"); a swap moved player 2 and "u" to the primary.
        #expect(owner("u", mp: 2, prefer: .secondary, primary: (2, "u"), secondary: (1, "x")) == .primary)
    }

    @Test func supersededByAnotherURL_isNil() {
        #expect(owner("u", mp: 1, prefer: .primary, primary: (1, "newer"), secondary: (2, nil)) == nil)
    }

    @Test func playerReleasedOrReplaced_isNil() {
        #expect(owner("u", mp: 1, prefer: .primary, primary: (nil, "u"), secondary: (nil, nil)) == nil)
        #expect(owner("u", mp: 1, prefer: .primary, primary: (9, "u"), secondary: (2, nil)) == nil)
    }

    @Test func sameURLOnBothSlots_prefersTheStartingSlot() {
        #expect(owner("u", mp: 1, prefer: .primary, primary: (1, "u"), secondary: (1, "u")) == .primary)
    }
}
