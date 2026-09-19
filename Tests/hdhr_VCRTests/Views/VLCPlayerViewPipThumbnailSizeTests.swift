import Testing
import CoreGraphics
@testable import hdhr_VCR

// Coverage for VLCPlayerView.pipThumbnailSize(nativePixelSize:maxWidth:) — added 2026-09-19 so the
// PiP thumbnail's own box matches the secondary stream's real aspect ratio instead of always
// assuming 16:9 (a 4:3 source used to letterbox/pillarbox inside a fixed 16:9 box). Falls back to
// 16:9 before libvlc has reported real dimensions (nativePixelSize nil, or before the first
// decoded frame).
@Suite("VLCPlayerView.pipThumbnailSize")
struct VLCPlayerViewPipThumbnailSizeTests {

    private let maxWidth: CGFloat = 192

    @Test func nilNativeSize_fallsBackTo16x9() {
        let size = VLCPlayerView.pipThumbnailSize(nativePixelSize: nil, maxWidth: maxWidth)
        #expect(size.width == maxWidth)
        #expect(size.height == (maxWidth * 9 / 16).rounded())
    }

    @Test func zeroWidthOrHeight_fallsBackTo16x9() {
        #expect(VLCPlayerView.pipThumbnailSize(nativePixelSize: CGSize(width: 0, height: 1080), maxWidth: maxWidth).height
                == (maxWidth * 9 / 16).rounded())
        #expect(VLCPlayerView.pipThumbnailSize(nativePixelSize: CGSize(width: 1920, height: 0), maxWidth: maxWidth).height
                == (maxWidth * 9 / 16).rounded())
    }

    @Test func negativeDimensions_fallBackTo16x9() {
        let size = VLCPlayerView.pipThumbnailSize(nativePixelSize: CGSize(width: -1, height: -1), maxWidth: maxWidth)
        #expect(size.height == (maxWidth * 9 / 16).rounded())
    }

    @Test func genuine16x9Source_matchesFallbackExactly() {
        let size = VLCPlayerView.pipThumbnailSize(nativePixelSize: CGSize(width: 1920, height: 1080), maxWidth: maxWidth)
        #expect(size.width == maxWidth)
        #expect(size.height == (maxWidth * 9 / 16).rounded())
    }

    @Test func fourByThreeSource_isShapedFourByThree_notLetterboxed() {
        // 640x480 (4:3) — height should be noticeably taller than the 16:9 fallback would give.
        let size = VLCPlayerView.pipThumbnailSize(nativePixelSize: CGSize(width: 640, height: 480), maxWidth: maxWidth)
        let expectedHeight = (maxWidth * 480 / 640).rounded()   // 144
        #expect(size.width == maxWidth)
        #expect(size.height == expectedHeight)
        #expect(size.height > (maxWidth * 9 / 16).rounded(), "4:3 must be taller than 16:9 at the same width")
    }

    @Test func portraitSource_tallerThanWide() {
        // A vertical/portrait stream (e.g. 1080x1920) should produce a height greater than the width.
        let size = VLCPlayerView.pipThumbnailSize(nativePixelSize: CGSize(width: 1080, height: 1920), maxWidth: maxWidth)
        #expect(size.height > size.width)
    }

    @Test func widthAlwaysFixedAtMaxWidth_regardlessOfSourceShape() {
        for native in [CGSize(width: 1920, height: 1080), CGSize(width: 640, height: 480),
                       CGSize(width: 720, height: 480), CGSize(width: 3840, height: 2160)] {
            #expect(VLCPlayerView.pipThumbnailSize(nativePixelSize: native, maxWidth: maxWidth).width == maxWidth)
        }
    }

    @Test func respectsCustomMaxWidth() {
        let size = VLCPlayerView.pipThumbnailSize(nativePixelSize: CGSize(width: 1920, height: 1080), maxWidth: 300)
        #expect(size.width == 300)
        #expect(size.height == (300 * 9 / 16).rounded())
    }

    // MARK: - Cross-product: every common source shape × every maxWidth this app actually uses

    // The individual tests above pin specific known values (16:9 fallback, 4:3, portrait); this
    // cross-products a broader set of real-world source aspect ratios against every maxWidth the
    // app passes (thumbnail corner sizes at different window scales) and checks the one invariant
    // that must hold for all of them: width is always pinned exactly to maxWidth, and height is
    // always exactly source-aspect-ratio-derived from it — never independently clamped/rounded in a
    // way that drifts from the source shape.
    private static let sourceShapes: [(name: String, size: CGSize)] = [
        ("16:9 HD",       CGSize(width: 1920, height: 1080)),
        ("16:9 SD",       CGSize(width: 1280, height: 720)),
        ("4:3 SD",        CGSize(width: 640, height: 480)),
        ("4:3 broadcast", CGSize(width: 720, height: 540)),
        ("21:9 ultrawide", CGSize(width: 2560, height: 1080)),
        ("portrait 9:16", CGSize(width: 1080, height: 1920)),
        ("square 1:1",    CGSize(width: 1000, height: 1000)),
    ]
    private static let maxWidths: [CGFloat] = [120, 192, 240, 320]

    @Test(arguments: sourceShapes, maxWidths)
    func everySourceShape_everyMaxWidth_heightMatchesAspectRatioExactly(_ shape: (name: String, size: CGSize), maxWidth: CGFloat) {
        let result = VLCPlayerView.pipThumbnailSize(nativePixelSize: shape.size, maxWidth: maxWidth)
        let expectedHeight = (maxWidth * shape.size.height / shape.size.width).rounded()
        #expect(result.width == maxWidth, "\(shape.name) @ maxWidth=\(maxWidth)")
        #expect(result.height == expectedHeight, "\(shape.name) @ maxWidth=\(maxWidth)")
    }
}
