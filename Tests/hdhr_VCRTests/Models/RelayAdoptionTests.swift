import Testing
import Foundation
@testable import hdhr_VCR

@Suite("HDHRDevice.adoptRelayIdentity — a relay first stored as an ordinary tuner")
struct RelayAdoptionTests {
    private func device(relay: Bool, name: String? = nil, started: TimeInterval? = nil) -> HDHRDevice {
        var d = HDHRDevice(DeviceID: "FEED04BE", LocalIP: "10.0.2.100", BaseURL: nil, TunerCount: nil,
                           FirmwareVersion: nil, DeviceAuth: nil)
        d.isVirtualRelay = relay
        d.FriendlyName = name
        d.recordingStartedAt = started
        return d
    }

    @Test func tunerThatTurnsOutToBeARelayFlipsAndTakesItsIdentity() {
        var known = device(relay: false)
        let flipped = known.adoptRelayIdentity(from: device(relay: true, name: "Mini-Relay", started: 1_000))
        #expect(flipped)
        #expect(known.isVirtualRelay)
        #expect(known.FriendlyName == "Mini-Relay")
        #expect(known.recordingStartedAt == 1_000)
    }

    @Test func knownRelayDoesNotReportAFlipButKeepsItsStartTimeCurrent() {
        var known = device(relay: true, name: "Mini-Relay", started: 1_000)
        let flipped = known.adoptRelayIdentity(from: device(relay: true, name: "Mini-Relay", started: 2_000))
        #expect(!flipped)
        #expect(known.recordingStartedAt == 2_000)
    }

    @Test func ordinaryTunerStaysUntouched() {
        var known = device(relay: false, name: "EXTEND")
        let flipped = known.adoptRelayIdentity(from: device(relay: false, name: "Other"))
        #expect(!flipped)
        #expect(!known.isVirtualRelay)
        #expect(known.FriendlyName == "EXTEND")
    }
}
