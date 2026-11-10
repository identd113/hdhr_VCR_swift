import Foundation
import Testing
@testable import hdhr_VCR

@Suite("Tuner firmware update offer")
struct FirmwareUpdateTests {
    private func device(_ json: String) throws -> HDHRDevice {
        try JSONDecoder().decode(HDHRDevice.self, from: Data(json.utf8))
    }

    @Test func discoverJsonUpgradeAvailableIsReadAndPointsAtTheTunersPage() throws {
        let d = try device(#"{"DeviceID":"105404BE","FirmwareVersion":"20260313","UpgradeAvailable":"20261107","BaseURL":"http://10.0.2.101"}"#)
        #expect(d.firmwareUpdate == "20261107")
        #expect(d.firmwarePageURL?.absoluteString == "http://hdhr-105404be.local/")
    }

    @Test func noOfferOrTheSameVersionIsNoUpdate() throws {
        #expect(try device(#"{"DeviceID":"A","FirmwareVersion":"1","BaseURL":"http://10.0.0.1"}"#).firmwareUpdate == nil)
        #expect(try device(#"{"DeviceID":"A","FirmwareVersion":"1","UpgradeAvailable":"1","BaseURL":"http://10.0.0.1"}"#).firmwareUpdate == nil)
    }

    @Test func aFullAnswerWithoutTheOfferClearsItButAUdpOnlyReplyKeepsIt() throws {
        let old = try device(#"{"DeviceID":"A","FirmwareVersion":"1","UpgradeAvailable":"2","BaseURL":"http://10.0.0.1"}"#)
        let upgraded = try device(#"{"DeviceID":"A","FirmwareVersion":"2","BaseURL":"http://10.0.0.1"}"#)
        let udpOnly = HDHRDevice(DeviceID: "A", LocalIP: "10.0.0.1", BaseURL: nil, TunerCount: nil, FirmwareVersion: nil, DeviceAuth: nil)
        #expect(old.mergingFresh(upgraded).firmwareUpdate == nil)
        #expect(old.mergingFresh(udpOnly).firmwareUpdate == "2")
    }
}
