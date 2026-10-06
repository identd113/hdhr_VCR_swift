import Testing
import Foundation
@testable import hdhr_VCR

// MARK: - Menu bar: "Unavailable Tuner" grouping and the "Watching" line
//
// Two menu behaviors that were broken before 2026-10-01 / 2026-09-26:
//  • Shows assigned to a tuner that is offline — or was never discovered at all — used to vanish from
//    the menu once there was more than one tuner. They now group under "Unavailable Tuner".
//  • "Watching" must show whenever anything is playing — including a PiP-only state with no primary.
// The SwiftUI menu itself isn't instantiable in a unit test; both decisions live in plain functions
// (`AppState.unavailableDeviceIDs/unavailableDeviceShows`, `MenuContent.watchingDisplay`).

@Suite("Menu bar — unavailable tuner grouping")
struct MenuBarUnavailableTunerTests {

    private func offline(_ id: String) -> HDHRDevice {
        var d = HDHRDevice.test(id: id)
        d.missedProbes = 3          // isAvailable == missedProbes < 3
        return d
    }

    private func show(on device: String, title: String = "Show", active: Bool = true) -> Show {
        var s = Show.testActive(title: title)
        s.hdhr_record = device
        s.show_active = active
        return s
    }

    @MainActor @Test func aDiscoveredButUnreachableTuner_isUnavailable_andItsShowsAreListed() {
        let state = makeTestAppState(shows: [show(on: "DEAD0001", title: "Lost Show")],
                                     devices: [offline("DEAD0001"), .test(id: "LIVE0002")])
        #expect(state.unavailableDeviceIDs == ["DEAD0001"])
        #expect(state.unavailableDeviceShows.map(\.show_title) == ["Lost Show"])
    }

    @MainActor @Test func aTunerNeverDiscoveredAtAll_isUnavailable_onceStartupHasFinished() {
        let state = makeTestAppState(shows: [show(on: "NEVER001")], devices: [.test(id: "LIVE0002")])
        state.isStartingUp = false
        #expect(state.unavailableDeviceIDs == ["NEVER001"])
        #expect(state.unavailableDeviceShows.count == 1)   // used to vanish with >1 tuner
    }

    @MainActor @Test func duringStartup_aNotYetDiscoveredTuner_isNotFlaggedUnavailable() {
        let state = makeTestAppState(shows: [show(on: "NEVER001")], devices: [.test(id: "LIVE0002")])
        state.isStartingUp = true      // first discovery pass hasn't finished — don't flash everything into "Unavailable"
        #expect(state.unavailableDeviceIDs.isEmpty)
        #expect(state.unavailableDeviceShows.isEmpty)
    }

    @MainActor @Test func availableTuners_andShowsWithNoDeviceAssigned_areNeverUnavailable() {
        let state = makeTestAppState(shows: [show(on: "LIVE0002"), show(on: "")], devices: [.test(id: "LIVE0002")])
        state.isStartingUp = false
        #expect(state.unavailableDeviceIDs.isEmpty)
        #expect(state.unavailableDeviceShows.isEmpty)
    }

    @MainActor @Test func inactiveShowsOnAnUnavailableTuner_areNotListed() {
        let state = makeTestAppState(shows: [show(on: "DEAD0001", title: "Old", active: false),
                                              show(on: "DEAD0001", title: "Current")],
                                     devices: [offline("DEAD0001")])
        #expect(state.unavailableDeviceShows.map(\.show_title) == ["Current"])
    }

    @MainActor @Test func severalUnavailableTuners_eachGetTheirOwnID() {
        let state = makeTestAppState(shows: [show(on: "DEAD0001"), show(on: "NEVER002")],
                                     devices: [offline("DEAD0001"), .test(id: "LIVE0003")])
        state.isStartingUp = false
        #expect(state.unavailableDeviceIDs == ["DEAD0001", "NEVER002"])
    }
}

@Suite("Menu bar — Watching line")
struct MenuBarWatchingDisplayTests {

    private func info(title: String? = "Evening News", relay: Bool = false, relayTitle: String? = nil)
        -> (device: HDHRDevice, channel: LineupEntry, entry: GuideEntry?) {
        let device = HDHRDevice.test(id: relay ? "FEED0001" : "LIVE0001", isVirtualRelay: relay)
        let channel = LineupEntry.test(number: "5.1", name: "KFOO", showTitle: relayTitle)
        return (device, channel, title.map { GuideEntry.test(title: $0) })
    }

    private func display(info: (device: HDHRDevice, channel: LineupEntry, entry: GuideEntry?)? = nil,
                         primaryDevice: String? = nil, primaryTitle: String? = nil,
                         pipDevice: String? = nil, pipTitle: String? = nil) -> (deviceId: String, title: String, isPiPOnly: Bool)? {
        MenuContent.watchingDisplay(info: info, currentDeviceID: primaryDevice, currentTitle: primaryTitle,
                                    secondaryDeviceID: pipDevice, secondaryTitle: pipTitle)
    }

    @Test func aResolvedPrimaryStream_showsChannelAndShowName() throws {
        let d = try #require(display(info: info(), primaryDevice: "LIVE0001"))
        #expect(d.title == "Ch 5.1  KFOO · Evening News")
        #expect(d.deviceId == "LIVE0001")
        #expect(d.isPiPOnly == false)
    }

    @Test func aFEEDPrimary_withNoGuideEntry_fallsBackToTheRelaysShowTitle() throws {
        let d = try #require(display(info: info(title: nil, relay: true, relayTitle: "The Big Game"), primaryDevice: "FEED0001"))
        #expect(d.title == "Ch 5.1  KFOO · The Big Game")
    }

    @Test func aRealChannelWithNoGuideEntry_showsJustTheChannel() throws {
        let d = try #require(display(info: info(title: nil), primaryDevice: "LIVE0001"))
        #expect(d.title == "Ch 5.1  KFOO")
    }

    @Test func anUnresolvablePrimary_fallsBackToTheWindowTitle() throws {
        // e.g. watching your own in-progress recording through the relay — no lineup match.
        let d = try #require(display(primaryDevice: "LIVE0001", primaryTitle: "The Tonight Show"))
        #expect(d.title == "The Tonight Show")
        #expect(d.isPiPOnly == false)
    }

    @Test func onlyAPiPPlaying_stillShowsWatching_markedPiPOnly() throws {
        let d = try #require(display(pipDevice: "LIVE0001", pipTitle: "News at Ten"))
        #expect(d.title == "News at Ten")
        #expect(d.deviceId == "LIVE0001")
        #expect(d.isPiPOnly == true)
    }

    @Test func aPrimary_winsOverThePiP() throws {
        let d = try #require(display(primaryDevice: "LIVE0001", primaryTitle: "Main", pipDevice: "LIVE0002", pipTitle: "Corner"))
        #expect(d.title == "Main")
        #expect(d.isPiPOnly == false)
    }

    @Test func nothingPlaying_hidesTheSection() {
        #expect(display() == nil)
        // a device with no title (or a title with no device) isn't enough to claim something is playing
        #expect(display(primaryDevice: "LIVE0001") == nil)
        #expect(display(pipTitle: "Orphan") == nil)
    }
}
