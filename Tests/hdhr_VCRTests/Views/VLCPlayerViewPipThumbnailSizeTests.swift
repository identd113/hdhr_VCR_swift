import Testing
import CoreGraphics
@testable import hdhr_VCR

// Coverage for VLCPlayerView.pipThumbnailSize(nativePixelSize:targetWidth:) — added 2026-09-19 so
// the PiP thumbnail's own box matches the secondary stream's real aspect ratio instead of always
// assuming 16:9 (a 4:3 source used to letterbox/pillarbox inside a fixed 16:9 box). Falls back to
// 16:9 before libvlc has reported real dimensions (nativePixelSize nil, or before the first
// decoded frame).
//
// Redesigned 2026-09-29: rather than scaling to `targetWidth` exactly, the result now snaps to
// whichever `pipThumbnailDivisors` entry (4/8/16/32) divides the *native* size into a width closest
// to `targetWidth` — dividing both axes by the same integer, a clean binning ratio rather than an
// arbitrary scale factor, after a live report of slight moiré on some content at the old exact-width
// behavior. `targetWidth` is now a hint the snap aims for, not a guarantee.
@Suite("VLCPlayerView.pipThumbnailSize")
struct VLCPlayerViewPipThumbnailSizeTests {

    private let targetWidth: CGFloat = 192

    @Test func nilNativeSize_fallsBackTo16x9() {
        let size = VLCPlayerView.pipThumbnailSize(nativePixelSize: nil, targetWidth: targetWidth)
        #expect(size.width == targetWidth)
        #expect(size.height == (targetWidth * 9 / 16).rounded())
    }

    @Test func zeroWidthOrHeight_fallsBackTo16x9() {
        #expect(VLCPlayerView.pipThumbnailSize(nativePixelSize: CGSize(width: 0, height: 1080), targetWidth: targetWidth).height
                == (targetWidth * 9 / 16).rounded())
        #expect(VLCPlayerView.pipThumbnailSize(nativePixelSize: CGSize(width: 1920, height: 0), targetWidth: targetWidth).height
                == (targetWidth * 9 / 16).rounded())
    }

    @Test func negativeDimensions_fallBackTo16x9() {
        let size = VLCPlayerView.pipThumbnailSize(nativePixelSize: CGSize(width: -1, height: -1), targetWidth: targetWidth)
        #expect(size.height == (targetWidth * 9 / 16).rounded())
    }

    @Test func genuine16x9Source_snapsToClosestDivisor() {
        // 1920x1080 @ target 192: /10 (an exact extra divisor, 2026-10-03) lands on 192 exactly.
        let size = VLCPlayerView.pipThumbnailSize(nativePixelSize: CGSize(width: 1920, height: 1080), targetWidth: targetWidth)
        #expect(size.width == 192)
        #expect(size.height == 108)   // 1080/10, exact — same divisor applied to both axes
    }

    @Test func fourByThreeSource_isShapedFourByThree_notLetterboxed() {
        // 640x480 (4:3) @ target 192: candidates are /4=160, /8=80, /16=40, /32=20 — 160 is closest.
        let size = VLCPlayerView.pipThumbnailSize(nativePixelSize: CGSize(width: 640, height: 480), targetWidth: targetWidth)
        #expect(size.width == 160)
        #expect(size.height == 120)   // 480/4, exact 4:3 — never letterboxed into a 16:9 box
    }

    @Test func portraitSource_tallerThanWide() {
        // A vertical/portrait stream (e.g. 1080x1920) should produce a height greater than the width.
        let size = VLCPlayerView.pipThumbnailSize(nativePixelSize: CGSize(width: 1080, height: 1920), targetWidth: targetWidth)
        #expect(size.height > size.width)
    }

    @Test func result_isAlwaysAnExactDivisorOfNativeSize_neverAnArbitraryScale() {
        // The whole point of the redesign: whatever size comes out, both axes must be the native
        // size divided by the exact same integer from pipThumbnailDivisors — never independently
        // scaled/rounded, which is what would reintroduce the reported moiré.
        let native = CGSize(width: 1920, height: 1080)
        for target: CGFloat in [80, 140, 192, 240, 340, 500] {
            let size = VLCPlayerView.pipThumbnailSize(nativePixelSize: native, targetWidth: target)
            let divisor = native.width / size.width
            #expect([2, 3, 4, 5, 6, 8, 10, 12, 16, 32].contains(Int(divisor.rounded())), "target=\(target) produced non-clean divisor \(divisor)")
            #expect(size.height == (native.height / divisor).rounded(), "target=\(target) height must use the same divisor as width")
        }
    }

    @Test func neverExceedsNativeSize_evenForAWideTarget() {
        // Smallest divisor is 2, so the result can never upscale past 1/2 of native — no target,
        // however large, should produce a thumbnail bigger than that.
        let native = CGSize(width: 640, height: 480)
        let size = VLCPlayerView.pipThumbnailSize(nativePixelSize: native, targetWidth: 10_000)
        #expect(size.width == 320)   // 640/2 — the largest available clean fraction
        #expect(size.height == 240)
    }

    // MARK: - Cross-product: every common source shape × every target width this app actually uses

    // Checks the invariants that must hold for every combination: width/height are always the same
    // exact native-size divisor (never independently derived), and that divisor is always one of
    // pipThumbnailDivisors.
    private static let sourceShapes: [(name: String, size: CGSize)] = [
        ("16:9 HD",       CGSize(width: 1920, height: 1080)),
        ("16:9 SD",       CGSize(width: 1280, height: 720)),
        ("4:3 SD",        CGSize(width: 640, height: 480)),
        ("4:3 broadcast", CGSize(width: 720, height: 540)),
        ("21:9 ultrawide", CGSize(width: 2560, height: 1080)),
        ("portrait 9:16", CGSize(width: 1080, height: 1920)),
        ("square 1:1",    CGSize(width: 1000, height: 1000)),
    ]
    private static let targetWidths: [CGFloat] = [200, 240, 345, 640]

    @Test(arguments: sourceShapes, targetWidths)
    func everySourceShape_everyTargetWidth_usesOneCleanDivisorForBothAxes(_ shape: (name: String, size: CGSize), targetWidth: CGFloat) {
        let result = VLCPlayerView.pipThumbnailSize(nativePixelSize: shape.size, targetWidth: targetWidth)
        let divisor = shape.size.width / result.width
        #expect([2, 3, 4, 5, 6, 8, 10, 12, 16, 32].contains(Int(divisor.rounded())), "\(shape.name) @ target=\(targetWidth) → non-clean divisor \(divisor)")
        let expectedHeight = (shape.size.height / divisor).rounded()
        #expect(result.height == expectedHeight, "\(shape.name) @ target=\(targetWidth)")
    }
}

// Coverage for VLCPlayerView.pipThumbnailMaxWidth(containerWidth:) — added 2026-09-29 so the PiP
// thumbnail's *target* scales with the video pane's actual size (bigger window/screen → bigger
// thumbnail) instead of a single fixed pixel width that only looked right near the default
// ~1080pt window. This target then feeds pipThumbnailSize's divisor snap above — it's a hint, not
// the literal rendered width.
@Suite("VLCPlayerView.pipThumbnailMaxWidth")
struct VLCPlayerViewPipThumbnailMaxWidthTests {

    @Test func defaultWindowWidth_isTheProportionalTarget() {
        // 2026-10-03: bigger by explicit request — 32% of the pane at the ~1080pt default window.
        let width = VLCPlayerView.pipThumbnailMaxWidth(containerWidth: 1080)
        #expect(abs(width - 345.6) < 0.5)
    }

    @Test func verySmallContainer_clampsToMinimum() {
        #expect(VLCPlayerView.pipThumbnailMaxWidth(containerWidth: 300) == 200)
        #expect(VLCPlayerView.pipThumbnailMaxWidth(containerWidth: 0) == 200)
    }

    @Test func veryLargeContainer_clampsToMaximum() {
        // A window resized toward a 4K/5K native size shouldn't grow the thumbnail unbounded.
        #expect(VLCPlayerView.pipThumbnailMaxWidth(containerWidth: 3840) == 640)
        #expect(VLCPlayerView.pipThumbnailMaxWidth(containerWidth: 5120) == 640)
    }

    @Test func midRangeContainer_scalesProportionally() {
        let narrow = VLCPlayerView.pipThumbnailMaxWidth(containerWidth: 900)
        let wide = VLCPlayerView.pipThumbnailMaxWidth(containerWidth: 1600)
        #expect(wide > narrow, "a wider video pane should produce a wider (or equal, once clamped) thumbnail")
    }
}

// Coverage for VLCPlayerView.mustFreeTunerBeforeSwitch — added 2026-10-03: a live→live channel
// switch on a device with no free tuner must release our own stream first (else 805 All Tuners In Use).
@Suite("VLCPlayerView.mustFreeTunerBeforeSwitch")
struct VLCPlayerViewTunerSwitchTests {
    @Test func freeTunerAvailable_noWait() {
        #expect(!VLCPlayerView.mustFreeTunerBeforeSwitch(activeTuners: 1, tunerCount: 2))
        #expect(!VLCPlayerView.mustFreeTunerBeforeSwitch(activeTuners: 0, tunerCount: 2))
    }
    @Test func deviceFull_mustFreeOwnFirst() {
        #expect(VLCPlayerView.mustFreeTunerBeforeSwitch(activeTuners: 2, tunerCount: 2))
        #expect(VLCPlayerView.mustFreeTunerBeforeSwitch(activeTuners: 1, tunerCount: 1))
    }
    @Test func unknownTunerCount_neverWaits() {
        #expect(!VLCPlayerView.mustFreeTunerBeforeSwitch(activeTuners: 2, tunerCount: 0))
    }
}

// Coverage for the PiP drag-resize math — added 2026-10-03.
@Suite("VLCPlayerView.pipResize")
struct VLCPlayerViewPipResizeTests {
    @Test func bottomTrailing_dragUpLeft_grows() {
        let w = VLCPlayerView.pipResizedWidth(startWidth: 300, translation: CGSize(width: -40, height: -22.5),
                                              corner: .bottomTrailing, aspect: 16.0/9.0)
        #expect(w == 340)   // (40 + 22.5*16/9)/2 = 40
    }
    @Test func topLeading_dragDownRight_grows_andOppositeShrinks() {
        #expect(VLCPlayerView.pipResizedWidth(startWidth: 300, translation: CGSize(width: 30, height: 0),
                                              corner: .topLeading, aspect: 1) == 315)
        #expect(VLCPlayerView.pipResizedWidth(startWidth: 300, translation: CGSize(width: -30, height: 0),
                                              corner: .topLeading, aspect: 1) == 285)
    }
    @Test func clamp_minAndPaneFraction() {
        let pane = CGSize(width: 1000, height: 600)
        #expect(VLCPlayerView.pipClampedWidth(10, aspect: 16.0/9.0, containerSize: pane) == 120)
        // 0.8*600*16/9 = 853.3 < 0.8*1000 = 800? → width cap 800 wins
        #expect(VLCPlayerView.pipClampedWidth(5000, aspect: 16.0/9.0, containerSize: pane) == 800)
    }
    @Test func userSize_keepsNativeAspect_neverStretched() {
        let size = VLCPlayerView.pipUserThumbnailSize(nativePixelSize: CGSize(width: 640, height: 480),
                                                      containerSize: CGSize(width: 1200, height: 800), widthFraction: 0.3)
        #expect(size.width == 360)
        #expect(size.height == 270)   // 4:3
    }
    @Test func userSize_unknownNative_fallsBackTo16x9() {
        let size = VLCPlayerView.pipUserThumbnailSize(nativePixelSize: nil,
                                                      containerSize: CGSize(width: 1200, height: 800), widthFraction: 0.25)
        #expect(size.width == 300)
        #expect(size.height == (300 * 9 / 16.0).rounded())
    }
}

// Coverage for the player window's native-aspect resize lock — added 2026-10-03.
@Suite("VLCPlayerWindowManager.aspectLock")
struct VLCPlayerWindowAspectLockTests {
    private let hd = CGSize(width: 1920, height: 1080)   // 16:9
    private let current = CGSize(width: 1280, height: 720 + 44)

    @Test func unknownNative_leavesProposalAlone() {
        let p = CGSize(width: 900, height: 500)
        #expect(VLCPlayerWindowManager.aspectLockedContentSize(proposed: p, current: current, nativePixelSize: nil) == p)
    }
    @Test func widthDrag_drivesHeight() {
        let r = VLCPlayerWindowManager.aspectLockedContentSize(proposed: CGSize(width: 1600, height: 764),
                                                               current: current, nativePixelSize: hd)
        #expect(r.width == 1600)
        #expect(abs(r.height - 944) < 0.001)
    }
    @Test func heightDrag_drivesWidth() {
        let r = VLCPlayerWindowManager.aspectLockedContentSize(proposed: CGSize(width: 1280, height: 540 + 44),
                                                               current: current, nativePixelSize: hd)
        #expect(abs(r.height - 584) < 0.001)
        #expect(r.width == 960)
    }
    @Test func fourByThree_isHonoured() {
        let r = VLCPlayerWindowManager.aspectLockedContentSize(proposed: CGSize(width: 1200, height: 764),
                                                               current: current, nativePixelSize: CGSize(width: 640, height: 480))
        #expect(r.width == 1200)
        #expect(abs(r.height - 944) < 0.001)
    }
    @Test func clampsToMinimumWidth() {
        let r = VLCPlayerWindowManager.aspectLockedContentSize(proposed: CGSize(width: 300, height: 200),
                                                               current: current, nativePixelSize: hd)
        #expect(r.width == VLCPlayerWindowManager.playerMinContentWidth)
    }
    @Test func clampsToScreen() {
        let r = VLCPlayerWindowManager.aspectLockedContentSize(proposed: CGSize(width: 4000, height: 2300),
                                                               current: current, nativePixelSize: hd,
                                                               maxContent: CGSize(width: 1400, height: 800))
        #expect(r.width <= 1400)
        #expect(r.height <= 800)
        #expect(abs(r.width / (r.height - 44) - 16.0/9.0) < 0.01)
    }
}
