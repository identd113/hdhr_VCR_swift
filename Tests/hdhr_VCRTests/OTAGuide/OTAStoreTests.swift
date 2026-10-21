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
        for name in ["guide.json", "lineup.json", "scan.json"] { #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)) }
        #expect(OTAStore.loadSummary(deviceId: "TEST", root: root)?.channels == 7)
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

    @Test func theScanWindowSaysEpisodesAndHowFarBackTheyStart() {
        let utc = TimeZone(identifier: "UTC")!, en = Locale(identifier: "en_US")
        // 2026-10-20 18:00 UTC is a Tuesday.
        let start = Date(timeIntervalSince1970: 1_792_519_200)
        #expect(OTASubChannelRow.episodeText(count: 0, earliest: start, locale: en, timeZone: utc) == nil)
        #expect(OTASubChannelRow.episodeText(count: 1, earliest: nil, locale: en, timeZone: utc) == "1 episode")
        let text = OTASubChannelRow.episodeText(count: 103, earliest: start, locale: en, timeZone: utc)
        #expect(text?.hasPrefix("103 episodes · from Tue") == true)
        #expect(text?.contains("6:00") == true)
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

    @Test func theScanWindowFollowsTheStationBeingRead() throws {
        let progress = OTAScanProgress()
        progress.reset(lineupOnly: false)
        let data = try Data(contentsOf: PSIPDecoderTests.fixture)
        let decoder = PSIPDecoder(); decoder.ingest(data)
        let result = decoder.result()
        progress.apply(.started(rf: 31))
        #expect(progress.currentRF == 31)
        progress.apply(.update(rf: 32, result: result, bytes: 1_000_000, seconds: 1))
        #expect(progress.currentRF == 32)
        progress.apply(.signal(rf: 32, strength: 88, quality: 98))
        let row = try #require(progress.rows.first { $0.rf == 32 })
        #expect(row.info.strength == 88 && row.info.quality == 98)
        #expect(row.info.majors == [4, 23])
        #expect(row.info.videoChannels == 7)
        #expect(row.info.episodes == result.events.count)
        #expect(row.info.earliest != nil && row.info.latestEnd != nil)
        #expect(row.info.frequencyMHz == 581)
        #expect(row.subChannels.first?.earliest != nil)
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
        #expect(!OTAScanner.allRFChannels.contains(37))
    }
}
