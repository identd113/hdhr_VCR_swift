import Testing
@testable import hdhr_VCR

// Coverage for VLCBridge.applyCastItemAdded/applyCastItemDeleted — the pure list-bookkeeping
// functions extracted out of the renderer-discoverer event handlers (handleCastItemAdded/
// handleCastItemDeleted), which otherwise depend on live libvlc renderer-item pointers and can't
// be exercised headless. This is the entire automatable surface of Chromecast casting support —
// everything else (actual discovery, actual casting) requires a real Chromecast on the LAN and a
// human clicking through it (see docs/VLCBridge.md's "Chromecast / Renderer Discovery" section).
@Suite("VLCBridge cast device list")
struct VLCBridgeCastDeviceListTests {

    @Test func added_appendsNewDevice() {
        let result = VLCBridge.applyCastItemAdded(id: "1", name: "Living Room TV", to: [])

        #expect(result.map(\.id) == ["1"])
        #expect(result.map(\.name) == ["Living Room TV"])
    }

    @Test func added_appendsAfterExistingDevices() {
        let existing = [(id: "1", name: "Living Room TV")]

        let result = VLCBridge.applyCastItemAdded(id: "2", name: "Bedroom Speaker", to: existing)

        #expect(result.map(\.id) == ["1", "2"])
        #expect(result.map(\.name) == ["Living Room TV", "Bedroom Speaker"])
    }

    @Test func added_forAnAlreadyPresentID_renamesInPlaceRatherThanDuplicating() {
        // A rediscovery/rename of the same underlying device (same held-item id) must update the
        // existing row, not create a second entry for it.
        let existing = [(id: "1", name: "Living Room TV")]

        let result = VLCBridge.applyCastItemAdded(id: "1", name: "Living Room TV (renamed)", to: existing)

        #expect(result.count == 1)
        #expect(result[0].name == "Living Room TV (renamed)")
    }

    @Test func deleted_removesTheMatchingDevice() {
        let existing = [(id: "1", name: "Living Room TV"), (id: "2", name: "Bedroom Speaker")]

        let result = VLCBridge.applyCastItemDeleted(id: "1", from: existing)

        #expect(result.map(\.id) == ["2"])
    }

    @Test func deleted_forAnIDNotPresent_isANoOp() {
        let existing = [(id: "1", name: "Living Room TV")]

        let result = VLCBridge.applyCastItemDeleted(id: "999", from: existing)

        #expect(result.map(\.id) == ["1"])
    }

    @Test func deleted_lastDevice_leavesAnEmptyList() {
        let existing = [(id: "1", name: "Living Room TV")]

        let result = VLCBridge.applyCastItemDeleted(id: "1", from: existing)

        #expect(result.isEmpty)
    }
}
