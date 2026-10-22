import Testing
import Foundation
@testable import hdhr_VCR

@Suite("Audit fixes: conflict sweep, version, config quarantine, signal merge, file names")
struct AuditFixesBatchTests {
    private func show(_ t: String, _ ch: String, start: Double, end: Double) -> Show {
        var s = Show.blank(channel: ch, device: "DEV1")
        s.show_title = t
        s.show_active = true
        let base = Date().addingTimeInterval(3600)
        s.show_next = base.addingTimeInterval(start * 3600)
        s.show_end = base.addingTimeInterval(end * 3600)
        return s
    }

    @Test func hasConflict_sequentialCompetitorsOnTwoTuners_isNotConflict() async {
        let a = show("A", "1.1", start: 8, end: 9)
        let b = show("B", "2.1", start: 9, end: 10)
        let c = show("C", "3.1", start: 8, end: 10)
        let state = await makeTestAppState(shows: [a, b, c], devices: [.test(id: "DEV1", tuners: 2)])
        #expect(await state.hasConflict(for: c) == false)
    }

    @Test func hasConflict_trulyConcurrentCompetitors_isConflict() async {
        let a = show("A", "1.1", start: 8, end: 10)
        let b = show("B", "2.1", start: 8, end: 10)
        let c = show("C", "3.1", start: 8, end: 10)
        let state = await makeTestAppState(shows: [a, b, c], devices: [.test(id: "DEV1", tuners: 2)])
        #expect(await state.hasConflict(for: c) == true)
    }

    @MainActor @Test func maxConcurrentOverlap_backToBackIsOne() {
        let t = Date()
        let r = AppState.maxConcurrentOverlap([(t, t.addingTimeInterval(10)), (t.addingTimeInterval(10), t.addingTimeInterval(20))])
        #expect(r == 1)
    }

    @Test func version_preReleaseSuffixKeepsNumber() {
        #expect(isVersion("2.0.5-beta", newerThan: "2.0.4"))
        #expect(!isVersion("2.0.5-beta", newerThan: "2.0.5"))
        #expect(isVersion("2.1", newerThan: "2.0.9+abc"))
    }

    @Test func save_keepsCorruptCopyOfUnreadableMainConfig() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hdhrCorrupt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let mgr = ConfigManager(appSupportDir: dir)
        try Data("{ not json".utf8).write(to: URL(fileURLWithPath: mgr.configPath))
        try mgr.save(ConfigFile(config: AppConfig(), shows: []))
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.contains { $0.contains(".corrupt-") })
        // A healthy file is not quarantined again.
        try mgr.save(ConfigFile(config: AppConfig(), shows: []))
        #expect(names.filter { $0.contains(".corrupt-") }.count == 1)
    }

    @Test func save_keepsCorruptCopyWhenShowsArrayFailedToDecode() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hdhrCorrupt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let mgr = ConfigManager(appSupportDir: dir)
        try Data(#"{"config": {"Config_version": "2"}, "shows": [{"show_id": 5}, 7]}"#.utf8)
            .write(to: URL(fileURLWithPath: mgr.configPath))
        #expect(mgr.quarantineIfUnreadable() != nil)
    }

    @Test func signalMerge_keepsLiveSamplesRecordedBeforeLoad() {
        let t = Date()
        let loaded = ["k": [ChannelSignalSample(ts: t.addingTimeInterval(-100), snq: 50)]]
        let live = ["k": [ChannelSignalSample(ts: t, snq: 90)], "j": [ChannelSignalSample(ts: t, snq: 10)]]
        let m = ChannelSignalStore.merged(loaded: loaded, live: live)
        #expect(m["k"]?.map(\.snq) == [50, 90])
        #expect(m["j"]?.count == 1)
    }

    @MainActor @Test func signalLoad_dropsOnlyBadSample() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("hdhrVCRplus")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ts = Date().timeIntervalSince1970
        try Data(#"{"k":[{"ts":\#(ts),"snq":70},{"ts":"bad"}]}"#.utf8)
            .write(to: folder.appendingPathComponent("channel_signal_history.json"))
        let store = ChannelSignalStore(appSupportDir: dir)
        await store.load()
        #expect(store.stats(guideName: "k")?.totalCount == 1)
    }

    @Test func outputPath_clampsLengthAndStripsLeadingDots() {
        var s = Show.blank(channel: "5.1", device: "DEV1")
        s.show_title = "..." + String(repeating: "é", count: 300)
        let name = (s.outputPath() as NSString).lastPathComponent
        #expect(name.utf8.count <= 255)
        #expect(!name.hasPrefix("."))
    }

    @Test func sanitizedTitle_stripsSeparatorsAndBidi() {
        #expect("A\u{2028}B\u{202E}C\u{200F}".sanitizedShowTitle == "ABC")
    }
}
