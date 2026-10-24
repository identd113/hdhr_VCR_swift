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

    @Test func theAirIsOffByDefault_andFillingGapsIsWhatPermissionMeansWithSiliconDust() {
        var c = AppConfig()
        #expect(!c.OTA_enabled && !c.airFillsGaps && !c.airReplacesSiliconDust && !c.lineupFromAir && !c.guidePrefersAir)
        c.OTA_enabled = true
        #expect(c.airFillsGaps && !c.airReplacesSiliconDust && !c.lineupFromAir)
        c.OTA_always_use = true   // OTA chosen as the guide source: nothing is left to fill
        #expect(c.airReplacesSiliconDust && c.lineupFromAir && c.guidePrefersAir && !c.airFillsGaps)
        c.OTA_enabled = false
        #expect(!c.airReplacesSiliconDust && !c.lineupFromAir && !c.guidePrefersAir)
    }

    @Test func anOldConfigWithoutTheNewKeysLoadsWithTheAirOff() throws {
        let c = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(!c.OTA_enabled && !c.OTA_always_use)
        let on = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"OTA_enabled":true,"OTA_always_use":true}"#.utf8))
        #expect(on.OTA_enabled && on.OTA_always_use)
    }

    // MARK: the channel scan needs no permission, anything that reads guide listings does

    @Test func onlyTheChannelListScanRunsWithoutPermission() {
        let off = AppConfig()
        #expect(!off.OTA_enabled)
        #expect(AppState.scanAllowed(lineupOnly: true, config: off))
        #expect(!AppState.scanAllowed(lineupOnly: false, config: off))
        var on = AppConfig(); on.OTA_enabled = true
        #expect(AppState.scanAllowed(lineupOnly: false, config: on))
    }

    @Test func withoutPermissionAGuideScanIsRefusedAndNoGapFillStarts() async {
        let state = makeTestAppState(devices: [.test(id: "DEV1")])
        let status = state.startOTAScan(deviceId: "DEV1", rfChannels: [19], userInitiated: false, showWindow: false)
        #expect(status.contains("off"))
        #expect(state.otaScanTask == nil)
        state.startScheduledOTAGapFillIfDue()
        #expect(state.otaScanTask == nil)
        #expect(!state.otaGapCheckInFlight)
        #expect(state.airOnlyChannels(deviceId: "DEV1").isEmpty)   // nothing saved yet
    }

    @Test func theMissingMultiplexesAreTheRfChannelsOfTheChannelsSiliconDustLacks() {
        func e(_ n: String, _ rf: Int) -> OTALineupEntry {
            OTALineupEntry(GuideNumber: n, GuideName: "S\(n)", RF: rf, Frequency: 500_000_000 + rf, ProgramNumber: 1, ServiceType: 2, Hidden: false, Protected: false)
        }
        let tuner = [LineupEntry.test(number: "5.1"), LineupEntry.test(number: "5.2")]
        let missing = OTAStore.missingMultiplexes(airOnly: OTAStore.airOnly(saved: [e("5.1", 22), e("5.2", 22), e("19.1", 19), e("19.2", 19), e("23.1", 23)], tunerLineup: tuner))
        #expect(missing.map(\.rf) == [19, 23])            // RF 22 holds only channels SiliconDust has: complete, never scanned
        #expect(missing[0].channels.map(\.GuideNumber) == ["19.1", "19.2"])
    }
}
