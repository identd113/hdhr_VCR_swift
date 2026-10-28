import Foundation
import Testing
@testable import hdhr_VCR

// The saved over-the-air guide: written by OTAStore after a scan, read back by GuideStore.loadOTA. Uses a temp folder, never the real one.
@MainActor
struct OTAStoreTests {
    static func outcome() throws -> OTAScanOutcome {
        let data = try Data(contentsOf: PSIPDecoderTests.fixture)
        let decoder = PSIPDecoder()
        decoder.ingest(data)
        var o = OTAScanOutcome()
        o.multiplexes = [OTAMultiplex(rf: 32, frequencyHz: 581_000_000, result: decoder.result(), bytes: data.count)]
        o.skipped = [25: "no guide tables"]
        return o
    }

    static func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ota-test-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func aScanIsSavedAsGuideLineupAndSummary() throws {
        let root = Self.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let summary = try #require(OTAStore.save(try Self.outcome(), deviceId: "TEST", root: root))
        #expect(summary.channels == 7)
        #expect(summary.events == 559)
        #expect(summary.skipped == ["RF 25": "no guide tables"])
        let dir = OTAStore.folder(deviceId: "TEST", root: root)
        for name in ["guide.json", "lineup.json", "scan.json", "mux.json"] { #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)) }
        #expect(OTAStore.loadSummary(deviceId: "TEST", root: root)?.channels == 7)
    }

    @Test func aChannelNumberCarriedByTwoMultiplexesAppearsOnce() throws {
        let root = Self.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = OTAStore.folder(deviceId: "DUP", root: root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func e(_ rf: Int, _ name: String) -> OTALineupEntry {
            OTALineupEntry(GuideNumber: "7.1", GuideName: name, RF: rf, Frequency: 500_000_000 + rf, ProgramNumber: 1, ServiceType: 2, Hidden: false, Protected: false)
        }
        try JSONEncoder().encode([e(20, "FIRST"), e(30, "SECOND")]).write(to: dir.appendingPathComponent("lineup.json"))
        #expect(try #require(OTAStore.savedLineup(deviceId: "DUP", root: root)).map(\.GuideNumber) == ["7.1"])
        #expect(try #require(OTAStore.lineupEntries(deviceId: "DUP", host: "10.0.0.5", root: root)).map(\.GuideNumber) == ["7.1"])
    }

    @Test func theLastCompletedScansAreReported() throws {
        let root = Self.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(OTAStore.lastCompletedScans(deviceId: "TEST", root: root).lineup == nil)
        #expect(OTAStore.lastCompletedScans(deviceId: "TEST", root: root).guide == nil)
        _ = OTAStore.save(try Self.outcome(), deviceId: "TEST", root: root)
        let done = OTAStore.lastCompletedScans(deviceId: "TEST", root: root)
        #expect(done.lineup != nil)
        #expect(done.guide != nil)
        // Removing the guide leaves the channel list's date alone.
        OTAStore.deleteSaved(deviceId: "TEST", guide: true, lineup: false, root: root)
        #expect(OTAStore.lastCompletedScans(deviceId: "TEST", root: root).guide == nil)
        #expect(OTAStore.lastCompletedScans(deviceId: "TEST", root: root).lineup != nil)
    }

    @Test func eachMultiplexIsUpdatedOnItsOwnAndItsDateIsKept() throws {
        let root = Self.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        _ = OTAStore.save(try Self.outcome(), deviceId: "TEST", root: root)                      // a full scan of RF 32
        let firstDate = try #require(OTAStore.muxRecords(deviceId: "TEST", root: root)[32]?.guideDate)
        let channelsOn32 = try #require(OTAStore.allSavedLineup(deviceId: "TEST", root: root)).count
        var other = try Self.outcome()
        other.multiplexes[0].rf = 19                                                                // a one-station refresh of RF 19
        other.skipped = [:]
        Thread.sleep(forTimeInterval: 1.1)   // dates are saved to the second
        _ = OTAStore.save(other, deviceId: "TEST", partial: true, root: root)
        let lineup = try #require(OTAStore.allSavedLineup(deviceId: "TEST", root: root))
        #expect(Set(lineup.map(\.RF)) == [19, 32])                                                  // RF 32 was kept, RF 19 added
        #expect(lineup.count == channelsOn32 * 2)
        let records = OTAStore.muxRecords(deviceId: "TEST", root: root)
        #expect(records[32]?.guideDate == firstDate)                                                // RF 32's date did not move
        #expect((records[19]?.guideDate ?? .distantPast) > firstDate)                               // RF 19 has its own, later date
        #expect(records[19]?.events ?? 0 > 0)
        // Refreshing RF 19 again replaces its listings instead of piling them up; a station that went silent is dropped.
        _ = OTAStore.save(other, deviceId: "TEST", partial: true, root: root)
        #expect(OTAStore.allSavedLineup(deviceId: "TEST", root: root)?.count == channelsOn32 * 2)
        var silent = OTAScanOutcome(); silent.skipped = [19: "no signal"]
        silent.multiplexes = try Self.outcome().multiplexes                                         // (RF 32 read again alongside)
        _ = OTAStore.save(silent, deviceId: "TEST", partial: true, root: root)
        // The first silent scan only counts a miss: RF 19 and its listings are still there.
        #expect(Set(try #require(OTAStore.allSavedLineup(deviceId: "TEST", root: root)).map(\.RF)) == [19, 32])
        #expect(OTAStore.muxRecords(deviceId: "TEST", root: root)[19]?.noSignalMisses == 1)
        _ = OTAStore.save(silent, deviceId: "TEST", partial: true, root: root)
        #expect(Set(try #require(OTAStore.allSavedLineup(deviceId: "TEST", root: root)).map(\.RF)) == [32])
        #expect(OTAStore.muxRecords(deviceId: "TEST", root: root)[19] == nil)
        // The "a full scan ran" record belongs to full scans only.
        #expect(OTAStore.loadSummary(deviceId: "TEST", root: root)?.multiplexes == 1)
    }

    @Test func aChannelListOnlyReadNeverReplacesListingsOrStampsAGuideDate() throws {
        let root = Self.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        _ = OTAStore.save(try Self.outcome(), deviceId: "TEST", root: root)
        let date = try #require(OTAStore.muxRecords(deviceId: "TEST", root: root)[32]?.guideDate)
        // The second pass of a full scan failed for RF 32: only its channel-list read is left, saved alongside a full read of another station.
        var again = try Self.outcome()
        again.multiplexes[0].guideRead = false
        again.multiplexes[0].result.events = []
        again.multiplexes[0].result.announcedEITCount = 0
        again.skipped = [:]
        Thread.sleep(forTimeInterval: 1.1)   // dates are saved to the second
        _ = OTAStore.save(again, deviceId: "TEST", root: root)
        let guide = try JSONDecoder().decode([GuideChannel].self, from: Data(contentsOf: OTAStore.guideFile(deviceId: "TEST", root: root)))
        #expect(guide.first?.Guide?.count == 105)                                                    // the listings survived
        #expect(OTAStore.muxRecords(deviceId: "TEST", root: root)[32]?.guideDate == date)            // and no new "guide read" date
    }

    @Test func aStationThatIsHeardAgainBetweenSilentScansKeepsItsStreak_reset() throws {
        let root = Self.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        _ = OTAStore.save(try Self.outcome(), deviceId: "TEST", root: root)                         // RF 32 saved
        var quiet = OTAScanOutcome(); quiet.skipped = [32: "no signal"]
        var other = try Self.outcome(); other.multiplexes[0].rf = 19; other.skipped = quiet.skipped  // RF 19 read, RF 32 silent
        _ = OTAStore.save(other, deviceId: "TEST", partial: true, root: root)
        #expect(OTAStore.muxRecords(deviceId: "TEST", root: root)[32]?.noSignalMisses == 1)
        var heard = try Self.outcome(); heard.skipped = [:]                                           // RF 32 heard again: the streak ends
        _ = OTAStore.save(heard, deviceId: "TEST", partial: true, root: root)
        #expect(OTAStore.muxRecords(deviceId: "TEST", root: root)[32]?.noSignalMisses == nil)
        _ = OTAStore.save(other, deviceId: "TEST", partial: true, root: root)                         // a new silent scan is miss 1 again, not 2
        #expect(OTAStore.muxRecords(deviceId: "TEST", root: root)[32] != nil)
    }

    @Test func aCancelledReadIsNotNoSignal() throws {
        let root = Self.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        _ = OTAStore.save(try Self.outcome(), deviceId: "TEST", root: root)
        var cut = try Self.outcome()
        cut.multiplexes = []; cut.skipped = [32: "cancelled"]; cut.cancelled = true
        _ = OTAStore.save(cut, deviceId: "TEST", root: root)   // nothing usable: nil, and nothing deleted
        #expect(OTAStore.allSavedLineup(deviceId: "TEST", root: root)?.count == 7)
        #expect(OTAStore.muxRecords(deviceId: "TEST", root: root)[32] != nil)
    }

    @Test func anEmptyScanNeverReplacesAnEarlierOne() throws {
        let root = Self.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        _ = OTAStore.save(try Self.outcome(), deviceId: "TEST", root: root)
        #expect(OTAStore.save(OTAScanOutcome(), deviceId: "TEST", root: root) == nil)
        #expect(OTAStore.loadSummary(deviceId: "TEST", root: root)?.channels == 7)
    }

    @Test func guideStoreLoadsTheSavedGuide() async throws {
        let root = Self.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        _ = OTAStore.save(try Self.outcome(), deviceId: "TEST", root: root)
        let store = GuideStore()
        #expect(await store.loadOTA(deviceId: "TEST", root: root))
        let channels = store.channels(deviceId: "TEST")
        #expect(channels.count == 7)
        #expect(channels.first?.GuideNumber == "4.1")
        #expect((channels.first?.Guide?.count ?? 0) == 105)
        #expect(store.needsRecovery(deviceId: "TEST") == false)
    }

    @Test func theGuideSourceIsNamedForTheTunerDropdown() async throws {
        let root = Self.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GuideStore()
        #expect(store.sourceLine(deviceId: "TEST").hasPrefix("Guide: not loaded"))
        _ = OTAStore.save(try Self.outcome(), deviceId: "TEST", root: root)
        #expect(await store.loadOTA(deviceId: "TEST", root: root))
        #expect(store.sourceByDevice["TEST"] == .ota)
        let line = store.sourceLine(deviceId: "TEST")
        #expect(line.hasPrefix("Guide: from the air, scanned "))
        #expect(line.hasSuffix("Lineup: the tuner"))
        store.invalidateAll()
        #expect(store.sourceByDevice["TEST"] == nil)
    }

    @Test func theSavedLineupBecomesTunableEntries() throws {
        let root = Self.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(OTAStore.lineupEntries(deviceId: "TEST", host: "10.0.0.5", root: root) == nil)
        _ = OTAStore.save(try Self.outcome(), deviceId: "TEST", root: root)
        let entries = try #require(OTAStore.lineupEntries(deviceId: "TEST", host: "10.0.0.5", root: root))
        #expect(!entries.isEmpty)
        let first = try #require(entries.first)
        #expect(first.GuideNumber == "4.1")
        // Frequency and program number, not the tuner's own channel number: tunes channels the tuner's lineup lacks.
        #expect(first.URL?.hasPrefix("http://10.0.0.5:5004/auto/ch") == true)
        #expect(first.URL?.contains("-") == true)
        #expect(first.Favorite == nil)
        OTAStore.deleteSaved(deviceId: "TEST", guide: false, lineup: true, root: root)
        #expect(OTAStore.lineupEntries(deviceId: "TEST", host: "10.0.0.5", root: root) == nil)
        #expect(OTAStore.hasFreshGuide(deviceId: "TEST", root: root))   // the lineup purge leaves the guide
        OTAStore.deleteSaved(deviceId: "TEST", guide: true, lineup: false, root: root)
        #expect(!OTAStore.hasFreshGuide(deviceId: "TEST", root: root))
    }

    @Test func aChannelSaysHowFarAheadItsGuideReaches() {
        let now = Date(timeIntervalSince1970: 1_792_519_200)
        var sub = OTASubChannelRow(sourceId: 1, number: "4.1", name: "WCCO", listings: 0, done: false)
        #expect(sub.reachText(now: now) == nil)                      // nothing listed
        sub.listings = 103
        sub.latestEnd = now.addingTimeInterval(66 * 3600)
        #expect(sub.reachText(now: now) == "2.8 days")
        sub.latestEnd = now.addingTimeInterval(14 * 3600)
        #expect(sub.reachText(now: now) == "14 h")
        sub.latestEnd = now.addingTimeInterval(-3600)               // already past: 0 h, never negative
        #expect(sub.reachText(now: now) == "0 h")
    }

    @Test func aStationsFactsAreWorkedOutFromWhatWasRead() throws {
        let now = Date(timeIntervalSince1970: 1_792_519_200)
        var info = OTAMuxInfo(frequencyMHz: 581)
        #expect(info.mbps == nil)                              // nothing read yet
        info.bytes = 61_000_000; info.seconds = 25
        #expect(abs((info.mbps ?? 0) - 19.52) < 0.01)
        #expect(info.guideHoursAhead(now: now) == nil)
        info.latestEnd = now.addingTimeInterval(66 * 3600)
        #expect(info.guideHoursAhead(now: now) == 66)
        info.latestEnd = now.addingTimeInterval(-3600)         // a guide that ended already reads as 0 h, not negative
        #expect(info.guideHoursAhead(now: now) == 0)
        info.broadcastTime = now.addingTimeInterval(-4)
        #expect(info.clockOffset(now: now) == -4)
        #expect(OTAScanView.hoursText(30) == "30 h")
        #expect(OTAScanView.hoursText(72) == "3.0 days")
        #expect(OTAScanView.mhz(581) == "581 MHz")
    }

    @Test func theDialRemembersWhichRFChannelsWereHeardAndWhichWereEmpty() throws {
        let progress = OTAScanProgress()
        progress.reset(lineupOnly: false)
        let data = try Data(contentsOf: PSIPDecoderTests.fixture)
        let decoder = PSIPDecoder(); decoder.ingest(data)
        progress.apply(.queued(total: 4))
        progress.apply(.skipped(rf: 5, why: "no signal"))
        progress.apply(.skipped(rf: 6, why: "tuner needed"))          // interrupted: goes back in the queue, not heard yet
        progress.apply(.started(rf: 32, tuner: "tuner0", expectedSeconds: 10))
        progress.apply(.finished(rf: 32, result: decoder.result(), bytes: 1_000_000, seconds: 10))
        #expect(progress.listenedRF == [5, 32])
        #expect(progress.emptyRF == [5])
        progress.reset(lineupOnly: false)
        #expect(progress.listenedRF.isEmpty && progress.emptyRF.isEmpty)
    }

    @Test func airOnlyChannelsAreThoseTheTunerLacks() {
        func air(_ n: String, hidden: Bool = false) -> OTALineupEntry {
            OTALineupEntry(GuideNumber: n, GuideName: "C\(n)", RF: 32, Frequency: 581_000_000, ProgramNumber: 1, ServiceType: 2, Hidden: hidden, Protected: false)
        }
        let tuner = [LineupEntry(GuideNumber: "4.1", GuideName: "A", URL: nil, HD: nil, Favorite: nil, VideoCodec: nil, AudioCodec: nil)]
        let only = OTAStore.airOnly(saved: [air("23.3"), air("4.1"), air("4.10"), air("4.2"), air("23.3")], tunerLineup: tuner)
        #expect(only.map(\.GuideNumber) == ["4.2", "4.10", "23.3"])      // not on the tuner, once each, in numeric order
    }

    @Test func savedListingsAreReadBackPerChannel() throws {
        let root = Self.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        _ = OTAStore.save(try Self.outcome(), deviceId: "TEST", root: root)
        let lineup = try #require(OTAStore.savedLineup(deviceId: "TEST", root: root))
        let some = try #require(lineup.first)
        let listings = OTAStore.savedListings(deviceId: "TEST", only: [some.GuideNumber], root: root)
        #expect(listings.keys.sorted() == [some.GuideNumber])
        #expect(listings[some.GuideNumber]?.isEmpty == false)
        #expect(zip(listings[some.GuideNumber]!, listings[some.GuideNumber]!.dropFirst()).allSatisfy { $0.StartTime <= $1.StartTime })
        #expect(OTAStore.savedListings(deviceId: "TEST", only: [], root: root).isEmpty)
    }

    @Test func theScanWindowFollowsTheStationBeingRead() throws {
        let progress = OTAScanProgress()
        progress.reset(lineupOnly: false)
        let data = try Data(contentsOf: PSIPDecoderTests.fixture)
        let decoder = PSIPDecoder(); decoder.ingest(data)
        let result = decoder.result()
        progress.apply(.started(rf: 31, tuner: "tuner0", expectedSeconds: 60))
        #expect(progress.currentRF == 31)
        progress.apply(.started(rf: 32, tuner: "tuner1", expectedSeconds: 60))
        #expect(progress.currentRF == 32)
        // An update from the other tuner's station must not move the selection (it made the tab flip back and forth).
        progress.apply(.update(rf: 31, result: result, bytes: 1_000_000, seconds: 1))
        #expect(progress.currentRF == 32)
        progress.apply(.update(rf: 32, result: result, bytes: 1_000_000, seconds: 1))
        progress.apply(.signal(rf: 32, strength: 88, quality: 98))
        let row = try #require(progress.rows.first { $0.rf == 32 })
        #expect(row.info.strength == 88 && row.info.quality == 98)
        #expect(row.info.majors == [4, 23])
        #expect(row.info.videoChannels == 7)
        #expect(row.info.episodes == result.events.count)
        #expect(row.info.latestEnd != nil)
        #expect(row.info.frequencyMHz == 581)
        #expect(row.subChannels.first?.latestEnd != nil)
        #expect(row.subChannels.allSatisfy { !$0.audioOnly })
    }

    @Test func aStationsRunningNumbersAreRedrawnEveryFewSeconds() throws {
        let progress = OTAScanProgress()
        progress.reset(lineupOnly: false)
        let decoder = PSIPDecoder(); decoder.ingest(try Data(contentsOf: PSIPDecoderTests.fixture))
        let result = decoder.result()
        progress.apply(.update(rf: 32, result: result, bytes: 1_000_000, seconds: 1))
        #expect(progress.rows.first?.info.bytes == 1_000_000)                  // the first reading is shown at once
        progress.apply(.update(rf: 32, result: result, bytes: 2_000_000, seconds: 2))
        #expect(progress.rows.first?.info.bytes == 1_000_000)                  // the next one, a second later, is held back
        progress.apply(.finished(rf: 32, result: result, bytes: 9_000_000, seconds: 9))
        #expect(progress.rows.first?.info.bytes == 9_000_000)                  // a finished read always shows
    }

    @Test func theScanWindowShowsWhatEachTunerIsDoing() throws {
        let progress = OTAScanProgress()
        progress.reset(lineupOnly: false)
        progress.apply(.queued(total: 10))
        let decoder = PSIPDecoder(); decoder.ingest(try Data(contentsOf: PSIPDecoderTests.fixture))
        let result = decoder.result()
        progress.apply(.started(rf: 31, tuner: "tuner0", expectedSeconds: 60))
        progress.apply(.started(rf: 32, tuner: "tuner1", expectedSeconds: 60))
        #expect(progress.lanes["tuner0"]?.rf == 31 && progress.lanes["tuner1"]?.rf == 32)
        let start = progress.lanes["tuner1"]!.startedAt
        #expect(progress.lanes["tuner1"]!.fraction(now: start.addingTimeInterval(30)) == 0.5)
        #expect(progress.lanes["tuner1"]!.fraction(now: start.addingTimeInterval(500)) == 1)    // never past full
        // The bar moves between whole stations: nothing finished, both reads half way, 2 of 10 stations' worth.
        #expect(abs(progress.fraction(now: start.addingTimeInterval(30)) - 0.1) < 0.01)
        progress.apply(.note("Waiting for a free tuner"))
        #expect(progress.note == "Waiting for a free tuner")
        progress.apply(.finished(rf: 31, result: result, bytes: 1, seconds: 60))
        #expect(progress.lanes["tuner0"] == nil && progress.lanes["tuner1"] != nil)          // finishing frees that tuner's lane
        progress.apply(.paused(rf: 32))
        #expect(progress.lanes.isEmpty)                                                      // a paused read frees its lane too
        progress.apply(.started(rf: 33, tuner: "tuner0", expectedSeconds: 60))
        #expect(progress.note == nil)                                                        // a tuner on a station clears the note
        #expect(OTAScanView.clock(372) == "6:12")
        #expect(OTAScanView.clock(3750) == "1:02:30")
    }

    @Test func theChannelListIsScannedOnceADayFromTheChosenHour() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        func at(_ day: Int, _ hour: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: 30))! }
        let due = { (now: Date, hour: Int, list: Date?, last: Date?) in AppState.lineupScanDue(now: now, hour: hour, lineupDate: list, lastAttempt: last, calendar: cal) }
        #expect(due(at(21, 3), 3, nil, nil))                    // no list yet, past 03:00: go
        #expect(!due(at(21, 2), 3, nil, nil))                   // before the chosen hour
        #expect(!due(at(21, 12), -1, nil, nil))                 // never
        #expect(due(at(21, 20), 3, at(20, 3), nil))             // yesterday's list is older than today's 03:00 mark
        #expect(!due(at(21, 20), 3, at(21, 4), nil))            // already scanned today
        #expect(!due(at(21, 4), 3, nil, at(21, 3)))             // tried today: once a day
        #expect(due(at(22, 4), 3, nil, at(21, 3)))              // tried yesterday: try again
    }


    @Test func ageTextReadsLikeAPerson() {
        #expect(GuideStore.ageText(20) == "just now")
        #expect(GuideStore.ageText(12 * 60) == "12 min ago")
        #expect(GuideStore.ageText(3 * 3600) == "3 h ago")
    }

    @Test func aSavedGuideIsFreshOnlyWithinThirtySixHours() throws {
        let root = Self.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(OTAStore.hasFreshGuide(deviceId: "TEST", root: root) == false)
        _ = OTAStore.save(try Self.outcome(), deviceId: "TEST", root: root)
        #expect(OTAStore.hasFreshGuide(deviceId: "TEST", root: root))
        let file = OTAStore.guideFile(deviceId: "TEST", root: root)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-48 * 3600)], ofItemAtPath: file.path)
        #expect(OTAStore.hasFreshGuide(deviceId: "TEST", root: root) == false)
    }

    @Test func aMissingOrStaleSavedGuideIsNotUsed() async throws {
        let root = Self.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GuideStore()
        #expect(await store.loadOTA(deviceId: "NOPE", root: root) == false)
        _ = OTAStore.save(try Self.outcome(), deviceId: "TEST", root: root)
        let file = OTAStore.guideFile(deviceId: "TEST", root: root)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-48 * 3600)], ofItemAtPath: file.path)
        #expect(await store.loadOTA(deviceId: "TEST", root: root) == false)
        #expect(store.channels(deviceId: "TEST").isEmpty)
    }

    @Test func scannerKnowsTheAtscFrequencyPlan() {
        #expect(OTAScanner.frequencyHz(rf: 2) == 57_000_000)
        #expect(OTAScanner.frequencyHz(rf: 5) == 79_000_000)
        #expect(OTAScanner.frequencyHz(rf: 9) == 189_000_000)
        #expect(OTAScanner.frequencyHz(rf: 14) == 473_000_000)
        #expect(OTAScanner.frequencyHz(rf: 32) == 581_000_000)
        #expect(OTAScanner.frequencyHz(rf: 51) == 695_000_000)
        #expect(OTAScanner.frequencyHz(rf: 1) == nil)
        #expect(OTAScanner.frequencyHz(rf: 52) == nil)
        #expect(OTAScanner.frequencyHz(rf: 37) == nil)   // radio astronomy, never scanned
        #expect(!OTAScanner.allRFChannels.contains(37))
    }
}
