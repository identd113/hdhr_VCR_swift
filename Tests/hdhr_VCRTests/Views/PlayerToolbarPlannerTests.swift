import Testing
import CoreGraphics
@testable import hdhr_VCR

@Suite("ToolbarOverflowPlanner")
struct PlayerToolbarPlannerTests {
    private typealias P = ToolbarOverflowPlanner
    private typealias I = PlayerToolbarItem

    /// The widest realistic row: Record, buffer pill, H.264 toggle all present.
    private var allItems: [P.ItemSpec] {
        I.specs(hasRecord: true, bufferEnabled: true, recordingRelay: false, hasH264: true)
    }
    private var labelItems: [P.ItemSpec] {   // no buffer: catch-up carries a label
        I.specs(hasRecord: true, bufferEnabled: false, recordingRelay: false, hasH264: true)
    }
    private func full(_ items: [P.ItemSpec]) -> CGFloat { P.requiredWidth(items, levels: [:]) }

    @Test func plentyOfRoom_keepsEverythingFull() {
        let plan = P.plan(items: allItems, available: 5000)
        #expect(plan.foldedIDs.isEmpty)
        #expect(allItems.allSatisfy { plan.level(of: $0.id) == .full })
        #expect(plan.fits)
    }

    @Test func exactFit_doesNotDegrade() {
        let plan = P.plan(items: allItems, available: full(allItems))
        #expect(plan.foldedIDs.isEmpty)
        let tooTight = P.plan(items: allItems, available: full(allItems) - 1)
        #expect(!tooTight.foldedIDs.isEmpty)
    }

    @Test func defaultWindowWidth_keepsTheLiveTestControlsOnTheBar() {
        // 1080x600 is the default window; the live tests need these four on the bar there, in the widest realistic state.
        for items in [allItems, labelItems,
                      I.specs(hasRecord: true, bufferEnabled: false, recordingRelay: true, hasH264: true)] {
            let plan = P.plan(items: items, available: 1080)
            for id in [I.picker, I.catchUp, I.volume, I.info] { #expect(!plan.isFolded(id)) }
            #expect(plan.foldedIDs.isEmpty)
        }
    }

    @Test func foldOrder_followsRank_asTheWindowNarrows() {
        // Shrink one point at a time: the order controls fold in must be clock, buffer, H.264, record, catch-up, volume, info.
        var seen: [String] = []
        var prev: P.Plan?
        var w = full(allItems)
        while w > 0 {
            let plan = P.plan(items: allItems, available: w, previous: nil)
            for id in plan.foldedIDs.reversed() where !seen.contains(id) { seen.append(id) }
            prev = plan
            w -= 1
        }
        #expect(prev != nil)
        #expect(seen == [I.clock, I.buffer, I.h264, I.record, I.catchUp, I.volume, I.info])
    }

    @Test func compactSteps_comeBeforeTheirFold() {
        // Catch-up (label) goes icon-only before it folds; the volume slider shrinks before it folds.
        var catchSeq: [P.Level] = [], volSeq: [P.Level] = []
        var w = full(labelItems)
        while w > 0 {
            let plan = P.plan(items: labelItems, available: w)
            if catchSeq.last != plan.level(of: I.catchUp) { catchSeq.append(plan.level(of: I.catchUp)) }
            if volSeq.last != plan.level(of: I.volume) { volSeq.append(plan.level(of: I.volume)) }
            w -= 1
        }
        #expect(catchSeq == [.full, .compact, .folded])
        #expect(volSeq == [.full, .compact, .folded])
    }

    @Test func neverFoldItems_surviveAnyWidth() {
        for w in [CGFloat(0), 1, 50, 199, 300] {
            let plan = P.plan(items: allItems, available: w)
            #expect(!plan.isFolded(I.picker))
            #expect(!plan.isFolded(I.more))
            #expect(plan.isCompact(I.picker))   // shrunk as far as it goes
        }
    }

    @Test func zeroWidth_foldsEverythingFoldable_andReportsNoFit() {
        let plan = P.plan(items: allItems, available: 0)
        #expect(!plan.fits)
        #expect(Set(plan.foldedIDs) == [I.record, I.buffer, I.catchUp, I.h264, I.info, I.clock, I.volume])
    }

    @Test func hugeAndInfiniteWidths_areFine() {
        #expect(P.plan(items: allItems, available: .greatestFiniteMagnitude).foldedIDs.isEmpty)
        #expect(P.plan(items: allItems, available: .infinity).foldedIDs.isEmpty)
    }

    @Test func emptyItemList_isAnEmptyPlan() {
        let plan = P.plan(items: [], available: 100)
        #expect(plan.foldedIDs.isEmpty)
        #expect(plan.levels.isEmpty)
    }

    @Test func foldedIDs_areMostRecentlyFoldedFirst() {
        let plan = P.plan(items: allItems, available: 0)
        #expect(plan.foldedIDs == [I.info, I.volume, I.catchUp, I.record, I.h264, I.buffer, I.clock])
    }

    @Test func promotion_returnsItemsByPriority_whenRoomAppears() {
        // Narrow, then widen with the plan in force: items come back last-folded-first, and the row is full again.
        var plan = P.plan(items: allItems, available: 300)
        let narrowFolded = plan.foldedIDs
        #expect(narrowFolded.count > 3)
        var w: CGFloat = 300
        var returned: [String] = []
        while w < 2000 {
            w += 1
            let next = P.plan(items: allItems, available: w, previous: plan)
            for id in narrowFolded where plan.isFolded(id) && !next.isFolded(id) { returned.append(id) }
            plan = next
        }
        #expect(plan.foldedIDs.isEmpty)
        #expect(returned == narrowFolded)   // highest rank (last to fold) returns first
    }

    @Test func hysteresis_stopsFlappingOnAThreshold() {
        // Find the width where the clock first folds, then wobble around it with the plan in force.
        var w: CGFloat = full(allItems)
        while !P.plan(items: allItems, available: w).isFolded(I.clock) { w -= 1 }
        let edge = w                                   // clock folded here, full at edge + 1
        var plan = P.plan(items: allItems, available: edge)
        #expect(plan.isFolded(I.clock))
        // Growing by less than the hysteresis does not bring it back ...
        plan = P.plan(items: allItems, available: edge + P.defaultHysteresis - 1, previous: plan)
        #expect(plan.isFolded(I.clock))
        // ... growing by the hysteresis does ...
        plan = P.plan(items: allItems, available: edge + P.defaultHysteresis + 1, previous: plan)
        #expect(!plan.isFolded(I.clock))
        // ... and once back, shrinking to just under the threshold folds it again (no extra slack on the way down).
        plan = P.plan(items: allItems, available: edge, previous: plan)
        #expect(plan.isFolded(I.clock))
    }

    @Test func stablePlan_isAFixedPoint() {
        for w in stride(from: CGFloat(150), through: 1000, by: 7) {
            let a = P.plan(items: allItems, available: w)
            let b = P.plan(items: allItems, available: w, previous: a)
            #expect(a == b)
        }
    }

    @Test func ties_breakTowardTheEarlierItem() {
        let items = [P.ItemSpec(id: "a", fullWidth: 100, foldRank: 5),
                     P.ItemSpec(id: "b", fullWidth: 100, foldRank: 5),
                     P.ItemSpec(id: "keep", fullWidth: 10, foldable: false)]
        let one = P.plan(items: items, available: 100 + 10 + 10 + 10 + P.horizontalPadding + P.slack, hysteresis: 0)
        #expect(one.foldedIDs == ["a"])   // folding "a" is enough, and it comes first in bar order
    }

    @Test func itemThatLostItsCompactForm_isClampedFromAPreviousPlan() {
        let withCompact = [P.ItemSpec(id: "x", fullWidth: 100, compactWidth: 40, compactRank: 1, foldRank: 2)]
        let narrow = P.plan(items: withCompact, available: 70 + P.horizontalPadding + P.slack, hysteresis: 0)
        #expect(narrow.isCompact("x"))
        let noCompact = [P.ItemSpec(id: "x", fullWidth: 100, foldRank: 2)]
        let again = P.plan(items: noCompact, available: 5000, previous: narrow)
        #expect(again.level(of: "x") == .full)
    }

    @Test func buffering_makesCatchUpIconOnly_andLabelsHaveFixedWidths() {
        let buf = I.specs(hasRecord: false, bufferEnabled: true, recordingRelay: false, hasH264: false)
        let spec = buf.first { $0.id == I.catchUp }!
        #expect(spec.fullWidth == 24 && spec.compactWidth == nil)
        let live = I.specs(hasRecord: false, bufferEnabled: false, recordingRelay: false, hasH264: false).first { $0.id == I.catchUp }!
        let rec = I.specs(hasRecord: false, bufferEnabled: false, recordingRelay: true, hasH264: false).first { $0.id == I.catchUp }!
        #expect(live.fullWidth == I.catchUpLabelWidth)
        #expect(rec.fullWidth == I.catchUpRecordingLabelWidth)
    }

    @Test func windowMinimum_isAboveWhatTheToolbarNeeds() {
        #expect(VLCPlayerWindowManager.playerMinContentWidth >= I.essentialWidth)
        // ... and at the minimum the bar still keeps catch-up, ⓘ and a compact volume slider (nothing it can't afford is lost).
        let plan = P.plan(items: labelItems, available: VLCPlayerWindowManager.playerMinContentWidth)
        #expect(!plan.isFolded(I.picker) && !plan.isFolded(I.info) && !plan.isFolded(I.catchUp))
        #expect(plan.fits)
    }
}
