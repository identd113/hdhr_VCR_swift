import Testing
import Foundation
@testable import hdhr_VCR

// MARK: - Which devices the UI lists
//
// An unreachable tuner nothing depends on must not be offered or shown (Watch Now's Tuner picker, the PiP
// picker, the menu header) — it used to linger for up to an hour (`staleDeviceForgetAfter`) as a dead choice.
// An unreachable tuner a show is still assigned to stays visible in the menu ("⚠ unavailable"), and is never
// offered as somewhere to watch or record now. A virtual FEED relay is never either.

@Suite("AppState.availableDevices / displayableDevices")
struct AppStateDisplayableDevicesTests {

    private func device(_ id: String, down: Bool = false, relay: Bool = false) -> HDHRDevice {
        var d = HDHRDevice.test(id: id, isVirtualRelay: relay)
        if down { d.missedProbes = 3 }
        return d
    }

    private func show(on deviceID: String) -> Show {
        var s = Show.testActive()
        s.hdhr_record = deviceID
        return s
    }

    @Test @MainActor func reachableDevice_isAvailableAndDisplayable() {
        let state = makeTestAppState(shows: [], devices: [device("AAAA0001")], lineups: [:])
        #expect(state.availableDevices.map(\.DeviceID) == ["AAAA0001"])
        #expect(state.displayableDevices.map(\.DeviceID) == ["AAAA0001"])
    }

    @Test @MainActor func unreachableDeviceWithNoShow_isHiddenEverywhere() {
        let state = makeTestAppState(shows: [], devices: [device("AAAA0001"), device("DEAD0001", down: true)], lineups: [:])
        #expect(state.availableDevices.map(\.DeviceID) == ["AAAA0001"])
        #expect(state.displayableDevices.map(\.DeviceID) == ["AAAA0001"])
    }

    @Test @MainActor func unreachableDeviceHoldingAShow_staysInTheMenuButIsNeverOffered() {
        let state = makeTestAppState(shows: [show(on: "DEAD0001")],
                                     devices: [device("AAAA0001"), device("DEAD0001", down: true)], lineups: [:])
        #expect(state.availableDevices.map(\.DeviceID) == ["AAAA0001"])
        #expect(Set(state.displayableDevices.map(\.DeviceID)) == ["AAAA0001", "DEAD0001"])
    }

    @Test @MainActor func virtualRelay_isNeverAvailableOrDisplayable() {
        let state = makeTestAppState(shows: [show(on: "FEED0001")],
                                     devices: [device("AAAA0001"), device("FEED0001", relay: true)], lineups: [:])
        #expect(state.availableDevices.map(\.DeviceID) == ["AAAA0001"])
        #expect(state.displayableDevices.map(\.DeviceID) == ["AAAA0001"])
    }
}
