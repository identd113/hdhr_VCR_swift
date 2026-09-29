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
        // 1920x1080 @ target 192: candidates are /4=480, /8=240, /16=120, /32=60 — 240 is closest.
        let size = VLCPlayerView.pipThumbnailSize(nativePixelSize: CGSize(width: 1920, height: 1080), targetWidth: targetWidth)
        #expect(size.width == 240)
        #expect(size.height == 135)   // 1080/8, exact — same divisor applied to both axes
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
            #expect([4, 8, 16, 32].contains(Int(divisor.rounded())), "target=\(target) produced non-clean divisor \(divisor)")
            #expect(size.height == (native.height / divisor).rounded(), "target=\(target) height must use the same divisor as width")
        }
    }

    @Test func neverExceedsNativeSize_evenForAWideTarget() {
        // Smallest divisor is 4, so the result can never upscale past 1/4 of native — no target,
        // however large, should produce a thumbnail bigger than that.
        let native = CGSize(width: 640, height: 480)
        let size = VLCPlayerView.pipThumbnailSize(nativePixelSize: native, targetWidth: 10_000)
        #expect(size.width == 160)   // 640/4 — the largest available clean fraction
        #expect(size.height == 120)
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
    private static let targetWidths: [CGFloat] = [140, 192, 240, 340]

    @Test(arguments: sourceShapes, targetWidths)
    func everySourceShape_everyTargetWidth_usesOneCleanDivisorForBothAxes(_ shape: (name: String, size: CGSize), targetWidth: CGFloat) {
        let result = VLCPlayerView.pipThumbnailSize(nativePixelSize: shape.size, targetWidth: targetWidth)
        let divisor = shape.size.width / result.width
        #expect([4, 8, 16, 32].contains(Int(divisor.rounded())), "\(shape.name) @ target=\(targetWidth) → non-clean divisor \(divisor)")
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

    @Test func defaultWindowWidth_closeToLegacyFixedValue() {
        // At the app's default ~1080pt window width, the proportional result should land close to
        // the old fixed 192pt constant so existing default-size windows don't visibly jump.
        let width = VLCPlayerView.pipThumbnailMaxWidth(containerWidth: 1080)
        #expect(abs(width - 194.4) < 0.5)
    }

    @Test func verySmallContainer_clampsToMinimum() {
        #expect(VLCPlayerView.pipThumbnailMaxWidth(containerWidth: 300) == 140)
        #expect(VLCPlayerView.pipThumbnailMaxWidth(containerWidth: 0) == 140)
    }

    @Test func veryLargeContainer_clampsToMaximum() {
        // A window resized toward a 4K/5K native size shouldn't grow the thumbnail unbounded.
        #expect(VLCPlayerView.pipThumbnailMaxWidth(containerWidth: 3840) == 340)
        #expect(VLCPlayerView.pipThumbnailMaxWidth(containerWidth: 5120) == 340)
    }

    @Test func midRangeContainer_scalesProportionally() {
        let narrow = VLCPlayerView.pipThumbnailMaxWidth(containerWidth: 900)
        let wide = VLCPlayerView.pipThumbnailMaxWidth(containerWidth: 1600)
        #expect(wide > narrow, "a wider video pane should produce a wider (or equal, once clamped) thumbnail")
    }
}
