import Testing
import AppKit
@testable import hdhr_VCR

// Coverage for VLCBridge.fill(container:with:) — the plain AppKit view-reparenting helper the PiP
// tap-to-swap fix (2026-09-19) is built on. Two earlier swap designs (live libvlc_media_player_
// set_nsobject retarget, then a nil-then-set retry) both failed to reliably move the picture:
// macOS's vout module doesn't consistently react to its drawable changing while already
// rendering. The fix stopped asking libvlc to retarget anything — swapSlots() instead moves the
// content NSView itself between two fixed containers via this helper, which is pure AppKit view
// manipulation with no libvlc/window/screen dependency, so it's fully testable headless.
@Suite("VLCBridge.fill(container:with:)")
struct VLCBridgeFillContainerTests {

    @Test @MainActor func insertsContentAsContainersSubview() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let content = NSView()

        VLCBridge.fill(container: container, with: content)

        #expect(content.superview === container)
        #expect(container.subviews == [content])
    }

    @Test @MainActor func sizesContentToContainersCurrentBounds() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 192, height: 108))
        let content = NSView()

        VLCBridge.fill(container: container, with: content)

        #expect(content.frame == container.bounds)
        #expect(content.autoresizingMask == [.width, .height])
    }

    @Test @MainActor func movingContentToNewContainerRemovesItFromTheOldOne() {
        // This is the actual swap operation: the same content view moves from one fixed container
        // (e.g. the thumbnail) to another (the big pane) — the old container must end up with zero
        // subviews, not a dangling reference to a view that's now elsewhere.
        let oldContainer = NSView(frame: NSRect(x: 0, y: 0, width: 192, height: 108))
        let newContainer = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
        let content = NSView()

        VLCBridge.fill(container: oldContainer, with: content)
        #expect(oldContainer.subviews == [content])

        VLCBridge.fill(container: newContainer, with: content)

        #expect(oldContainer.subviews.isEmpty, "old container must not still reference the moved view")
        #expect(newContainer.subviews == [content])
        #expect(content.superview === newContainer)
        #expect(content.frame == newContainer.bounds, "must be resized to the new container's bounds, not left at the old size")
    }

    @Test @MainActor func alreadyCorrectlyPlaced_isANoOp() {
        // The guard (content.superview !== container) exists so re-registering the same container
        // (e.g. setContainer() called again) doesn't redundantly remove-then-readd a view that's
        // already exactly where it should be.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let content = NSView()
        VLCBridge.fill(container: container, with: content)
        content.frame = NSRect(x: 10, y: 10, width: 50, height: 50)   // simulate a manual resize since

        VLCBridge.fill(container: container, with: content)   // same container again

        #expect(container.subviews == [content])
        // A real re-fill would have reset frame to container.bounds; the no-op guard means it
        // shouldn't have touched frame at all this second call.
        #expect(content.frame == NSRect(x: 10, y: 10, width: 50, height: 50))
    }

    @Test @MainActor func swappingTwoContentViewsBetweenTwoContainersLeavesEachWithExactlyOne() {
        // The actual shape swapSlots() uses: two containers, two content views, swap which content
        // is in which container. Neither container should ever transiently or permanently end up
        // with two subviews.
        let containerA = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
        let containerB = NSView(frame: NSRect(x: 0, y: 0, width: 192, height: 108))
        let contentA = NSView()
        let contentB = NSView()
        VLCBridge.fill(container: containerA, with: contentA)
        VLCBridge.fill(container: containerB, with: contentB)

        // Swap.
        VLCBridge.fill(container: containerA, with: contentB)
        VLCBridge.fill(container: containerB, with: contentA)

        #expect(containerA.subviews == [contentB])
        #expect(containerB.subviews == [contentA])
        #expect(contentA.frame == containerB.bounds)
        #expect(contentB.frame == containerA.bounds)
    }
}
