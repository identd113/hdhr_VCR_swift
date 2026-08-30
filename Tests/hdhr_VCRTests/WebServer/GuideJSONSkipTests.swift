import Testing
import Foundation
@testable import hdhr_VCR

// Regression coverage for /api/guide.json's isSkipped field — added so hdhr_guide (the bundled
// terminal client, which has no on-disk access of its own) can show the same "already recorded,
// will skip" indicator the web guide's slate .g-st-skip ring/badge shows, without a second scan
// endpoint. Mirrors buildGuideGridHTML's own willSkip gating (Series subfolders + Skip
// already-recorded episodes both on, episode tag matches an on-disk SxxExx file, and the airing
// isn't the one currently recording).

private final class GuideJSONSkipMockURLProtocol: MockURLProtocolBase {
    private static var _handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { _handler }
        set { _handler = newValue }
    }
}

@Suite("buildGuideJSON — isSkipped mirrors the web guide's skip-already-recorded indicator")
struct GuideJSONSkipTests {

    private func writeFile(_ dir: String, _ name: String, bytes: Int = 10_000_000) throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent(name)
        try Data(count: bytes).write(to: URL(fileURLWithPath: path))
    }

    private func tempBase() -> String {
        (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("hdhrGuideJSONSkipTest-\(UUID().uuidString)")
    }

    @MainActor
    private func fetchEntry(base: String, skipEnabled: Bool, subfolderEnabled: Bool = true,
                             ignoreDuplicateOnce: Bool = false) async throws -> [String: Any] {
        let device = HDHRDevice(DeviceID: "AABBCCDD", LocalIP: "192.168.1.50",
                                 BaseURL: "http://192.168.1.50", TunerCount: 2,
                                 FirmwareVersion: nil, DeviceAuth: nil)
        let lineup = [LineupEntry(GuideNumber: "5.1", GuideName: "KVUE", URL: nil, HD: 1, Favorite: nil)]

        let now = Int(Date().timeIntervalSince1970)
        let start = now + 3600, end = now + 5400
        let guideJSON = """
        [{"GuideNumber":"5.1","GuideName":"KVUE","Guide":[
            {"StartTime":\(start),"EndTime":\(end),"Title":"The Office","EpisodeNumber":"S01E01"}
        ]}]
        """
        let session = makeMockSession(GuideJSONSkipMockURLProtocol.self)
        GuideJSONSkipMockURLProtocol.requestHandler = { req in
            (HTTPResponse(url: req.url!), guideJSON.data(using: .utf8)!)
        }
        let guideStore = GuideStore(session: session)
        await guideStore.load(for: device)

        var show = Show.blank(channel: "5.1", device: "AABBCCDD")
        show.show_title = "The Office"
        show.show_active = true
        show.show_is_series = true
        show.show_use_seriesid = true   // seriesChannel
        show.show_dir = base
        show.show_temp_dir = base
        show.show_ignore_duplicate_once = ignoreDuplicateOnce
        // Keeps recordedEpisodeTags' expectedMinutes-scaled duration floor small enough for a
        // fast, tiny fixture file to clear it (see RecordedEpisodeTagsTests' own expectedMinutes:1
        // fixtures for the same reasoning) — Show.blank()'s real default (60) would need a
        // multi-hundred-MB file to pass.
        show.show_length = 1

        let state = makeTestAppState(shows: [show], devices: [device],
                                      lineups: ["AABBCCDD": lineup], guideStore: guideStore)
        state.config.Series_subfolder_enabled = subfolderEnabled
        state.config.Skip_recorded_episodes = skipEnabled

        let data = WebServer().buildGuideJSON(state: state, deviceId: "AABBCCDD")
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let channels = try #require(payload["channels"] as? [[String: Any]])
        let entries = try #require(channels.first?["entries"] as? [[String: Any]])
        return try #require(entries.first)
    }

    @MainActor
    @Test func managedEpisodeAlreadyOnDiskIsFlaggedSkipped() async throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(atPath: base) }
        try writeFile("\(base)/The Office/Season 01", "The Office_S01E01_5.1_20260101_2000.ts")

        let entry = try await fetchEntry(base: base, skipEnabled: true)
        #expect(entry["isScheduled"] as? Bool == true)
        #expect(entry["isSkipped"] as? Bool == true)
    }

    @MainActor
    @Test func skipRecordedEpisodesDisabledNeverFlagsEvenWithMatchOnDisk() async throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(atPath: base) }
        try writeFile("\(base)/The Office/Season 01", "The Office_S01E01_5.1_20260101_2000.ts")

        let entry = try await fetchEntry(base: base, skipEnabled: false)
        #expect(entry["isScheduled"] as? Bool == true)
        #expect(entry["isSkipped"] as? Bool == false)
    }

    @MainActor
    @Test func ignoreDuplicateOnceSuppressesTheFlagDespiteMatchOnDisk() async throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(atPath: base) }
        try writeFile("\(base)/The Office/Season 01", "The Office_S01E01_5.1_20260101_2000.ts")

        let entry = try await fetchEntry(base: base, skipEnabled: true, ignoreDuplicateOnce: true)
        #expect(entry["isSkipped"] as? Bool == false)
    }

    @MainActor
    @Test func noMatchingFileOnDiskIsNotFlagged() async throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(atPath: base) }
        // No file written at all — nothing on disk for this episode.

        let entry = try await fetchEntry(base: base, skipEnabled: true)
        #expect(entry["isSkipped"] as? Bool == false)
    }
}

private func HTTPResponse(url: URL) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
}
