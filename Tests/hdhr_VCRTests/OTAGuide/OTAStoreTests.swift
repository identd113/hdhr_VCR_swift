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
