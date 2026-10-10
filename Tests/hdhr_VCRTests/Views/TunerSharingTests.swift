import Testing
@testable import hdhr_VCR

@Suite("TunerSharing — the menu header's note for tuners this app doesn't hold")
struct TunerSharingTests {
    @Test func agreeingCountsOrNoPollYet_sayNothing() {
        #expect(TunerSharing.note(hardwareCount: 1, appCount: 1) == nil)
        #expect(TunerSharing.note(hardwareCount: 0, appCount: 0) == nil)
        #expect(TunerSharing.note(hardwareCount: nil, appCount: 2) == nil)
    }
    @Test func surplusHardwareTuners_areAnotherDevices() {
        #expect(TunerSharing.note(hardwareCount: 1, appCount: 0) == "in use by another device")
        #expect(TunerSharing.note(hardwareCount: 2, appCount: 1) == "in use by another device")
        #expect(TunerSharing.note(hardwareCount: 3, appCount: 0) == "in use by another device (3)")
    }
    @Test func hardwareBehindUs_isOurOwnStreamStarting() {
        #expect(TunerSharing.note(hardwareCount: 0, appCount: 1) == "starting…")
    }
}
