import Testing
@testable import hdhr_VCR

// T25: the player used to pin whatever was the system default when its window opened and never followed it.
@Suite("VLCBridge.resolveAudioTarget")
struct AudioTargetResolutionTests {
    private let devices = ["speakers", "airpods", "usb"]

    @Test func following_usesTheSystemDefault() {
        let r = VLCBridge.resolveAudioTarget(followsSystemDefault: true, chosen: "usb", available: devices, systemDefault: "airpods")
        #expect(r.deviceId == "airpods" && r.follows)
    }

    @Test func following_trackstheDefaultWhenItChanges() {
        let before = VLCBridge.resolveAudioTarget(followsSystemDefault: true, chosen: nil, available: devices, systemDefault: "speakers")
        let after  = VLCBridge.resolveAudioTarget(followsSystemDefault: true, chosen: before.deviceId, available: devices, systemDefault: "airpods")
        #expect(before.deviceId == "speakers" && after.deviceId == "airpods")
    }

    @Test func pinned_staysOnTheChosenDevice_evenWhenTheDefaultChanges() {
        let r = VLCBridge.resolveAudioTarget(followsSystemDefault: false, chosen: "usb", available: devices, systemDefault: "airpods")
        #expect(r.deviceId == "usb" && !r.follows)
    }

    @Test func pinnedDeviceUnplugged_fallsBackToFollowingTheDefault() {
        let r = VLCBridge.resolveAudioTarget(followsSystemDefault: false, chosen: "usb", available: ["speakers", "airpods"], systemDefault: "speakers")
        #expect(r.deviceId == "speakers" && r.follows)
    }

    @Test func unknownDefault_fallsBackToTheFirstDevice_andNoDevicesGivesNil() {
        #expect(VLCBridge.resolveAudioTarget(followsSystemDefault: true, chosen: nil, available: devices, systemDefault: "gone").deviceId == "speakers")
        #expect(VLCBridge.resolveAudioTarget(followsSystemDefault: true, chosen: nil, available: [], systemDefault: nil).deviceId == nil)
    }
}
