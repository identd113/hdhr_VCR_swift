import Foundation
import Testing
@testable import hdhr_VCR

// "Scan OTA for Lineup and Guide" (Settings → Over the Air): the switch, the two sources, and the rule that keeps the air listings
// of the stations SiliconDust lacks from running dry.

@MainActor
struct OTAGapFillTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func hours(_ h: Double) -> TimeInterval { h * 3600 }

    // MARK: when a multiplex is read again

    @Test func aMultiplexWithLessThanSixHoursOfListingsIsDue_moreIsNot() {
        let due = OTAGapFill.dueMultiplexes(now: now, rfs: [19, 31], coverageEnd: [19: now + hours(3), 31: now + hours(7)], muxRecords: [:], lastAttempt: [:])
        #expect(due == [19])
    }

    @Test func aMultiplexNeverReadIsDue() {
        #expect(OTAGapFill.dueMultiplexes(now: now, rfs: [19], coverageEnd: [:], muxRecords: [:], lastAttempt: [:]) == [19])
    }

    @Test func aTryIsNotRepeatedWithinAnHour() {
        let recent = [19: now - 1800]
        #expect(OTAGapFill.dueMultiplexes(now: now, rfs: [19], coverageEnd: [19: now + hours(1)], muxRecords: [:], lastAttempt: recent).isEmpty)
        let older = [19: now - hours(2)]
        #expect(OTAGapFill.dueMultiplexes(now: now, rfs: [19], coverageEnd: [19: now + hours(1)], muxRecords: [:], lastAttempt: older) == [19])
    }

    @Test func aStationThatSendsNoGuideIsNotTriedAgainForADay() {
        let silent = OTAStore.MuxRecord(rf: 14, lineupDate: now, guideDate: now - hours(3), channels: 2, events: 0)
        #expect(OTAGapFill.dueMultiplexes(now: now, rfs: [14], coverageEnd: [:], muxRecords: [14: silent], lastAttempt: [14: now - hours(3)]).isEmpty)
        #expect(OTAGapFill.dueMultiplexes(now: now, rfs: [14], coverageEnd: [:], muxRecords: [14: silent], lastAttempt: [:]).isEmpty)   // nor after a relaunch
        let old = OTAStore.MuxRecord(rf: 14, lineupDate: now, guideDate: now - hours(25), channels: 2, events: 0)
        #expect(OTAGapFill.dueMultiplexes(now: now, rfs: [14], coverageEnd: [:], muxRecords: [14: old], lastAttempt: [14: now - hours(25)]) == [14])
    }

    // MARK: the saved listings' reach

    @Test func theSavedListingsReachIsTheLastEndOnTheWantedChannels() throws {
        let root = OTAStoreTests.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try #require(OTAStore.save(try OTAStoreTests.outcome(), deviceId: "COV", root: root))
        let numbers = Set((OTAStore.savedLineup(deviceId: "COV", root: root) ?? []).map(\.GuideNumber))
        let reach = OTAStore.listingCoverage(deviceId: "COV", numbers: numbers, root: root)
        #expect(reach.keys.sorted() == [32])
        #expect(reach[32]! > Date(timeIntervalSince1970: 0))
        #expect(OTAStore.listingCoverage(deviceId: "COV", numbers: ["99.9"], root: root).isEmpty)
        #expect(OTAStore.listingCoverage(deviceId: "NONE", numbers: numbers, root: root).isEmpty)
    }

    // MARK: the settings

    @Test func theAirIsOffByDefault_andFillingGapsIsTheDefaultOnceItIsOn() {
        var c = AppConfig()
        #expect(!c.OTA_enabled && !c.airFillsGaps && !c.airReplacesSiliconDust && !c.lineupFromAir && !c.guidePrefersAir)
        c.OTA_enabled = true
        #expect(c.airFillsGaps && !c.airReplacesSiliconDust && !c.lineupFromAir)
        c.OTA_fill_gaps = false
        #expect(!c.airFillsGaps && !c.airReplacesSiliconDust)
        c.OTA_always_use = true
        c.OTA_fill_gaps = true   // the gap option goes away when the air is the source
        #expect(c.airReplacesSiliconDust && c.lineupFromAir && c.guidePrefersAir && !c.airFillsGaps)
        c.OTA_enabled = false
        #expect(!c.airReplacesSiliconDust && !c.lineupFromAir && !c.guidePrefersAir)
    }

    @Test func anOldConfigWithoutTheNewKeysLoadsWithTheAirOff() throws {
        let c = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(!c.OTA_enabled && !c.OTA_always_use && c.OTA_fill_gaps)
        let on = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"OTA_enabled":true,"OTA_always_use":true,"OTA_fill_gaps":false}"#.utf8))
        #expect(on.OTA_enabled && on.OTA_always_use && !on.OTA_fill_gaps)
    }

    // MARK: with the switch off nothing happens over the air

    @Test func withTheSwitchOffNoScanStartsAndNothingIsScheduled() async {
        let state = makeTestAppState(devices: [.test(id: "DEV1")])
        #expect(!state.config.OTA_enabled)
        let status = state.startOTAScan(deviceId: "DEV1", rfChannels: [19], userInitiated: false, showWindow: false)
        #expect(status.contains("off"))
        #expect(state.otaScanTask == nil)
        state.startScheduledOTALineupRefreshIfDue()
        state.startScheduledOTAGapFillIfDue()
        #expect(state.otaScanTask == nil)
        #expect(!state.otaGapCheckInFlight)
        #expect(state.airOnlyChannels(deviceId: "DEV1").isEmpty)
    }
}
