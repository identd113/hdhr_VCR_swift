import Testing
import Foundation
@testable import hdhr_VCR

// MARK: - Mock URLProtocol
//
// Own storage (see HDHRManagerTests/DiscordNotifierTests for why each mocking file needs its
// own `requestHandler` slot). Shared request-replay mechanics live in TestFixtures.swift's
// `MockURLProtocolBase`.

final class MockURLProtocol: MockURLProtocolBase {
    private static var _handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { _handler }
        set { _handler = newValue }
    }
}

// MARK: - Helpers

private func makeSession() -> URLSession { makeMockSession(MockURLProtocol.self) }

private func makeLocalDevice(ip: String = "192.168.1.100", id: String = "AABBCCDD") -> HDHRDevice {
    HDHRDevice(DeviceID: id, LocalIP: ip, BaseURL: "http://\(ip)", TunerCount: 2,
               FirmwareVersion: nil, DeviceAuth: nil)
}

private func makeCloudDevice(auth: String = "auth123", id: String = "11223344") -> HDHRDevice {
    HDHRDevice(DeviceID: id, LocalIP: "10.0.0.2", BaseURL: "http://10.0.0.2", TunerCount: 2,
               FirmwareVersion: nil, DeviceAuth: auth)
}

private func okResponse(for url: URL) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
}

// Two channels; "The Daily Show" (ds456) appears on both — tests series index across channels.
// StartTimes are year 2033 so they're always in the future relative to test execution.
private let sampleGuideJSON = """
[
    {
        "GuideNumber": "5.1",
        "GuideName": "KVUE",
        "Guide": [
            {
                "StartTime": 2000000000,
                "EndTime":   2000003600,
                "Title": "Local News",
                "Synopsis": "Evening headlines"
            },
            {
                "StartTime": 2000003600,
                "EndTime":   2000007200,
                "Title": "The Daily Show",
                "SeriesID": "ds456",
                "EpisodeTitle": "Episode A"
            }
        ]
    },
    {
        "GuideNumber": "8.1",
        "GuideName": "KXAN",
        "Guide": [
            {
                "StartTime": 2000001800,
                "EndTime":   2000005400,
                "Title": "The Daily Show",
                "SeriesID": "ds456",
                "EpisodeTitle": "Episode B"
            }
        ]
    }
]
"""

// Same device, only channel 5.1 (8.1 dropped from the lineup) — used to verify buildIndex prunes
// channelEntryIndex for a vanished channel, not just seriesIndex.
private let sampleGuideJSONChannelDropped = """
[
    {
        "GuideNumber": "5.1",
        "GuideName": "KVUE",
        "Guide": [
            {
                "StartTime": 2000000000,
                "EndTime":   2000003600,
                "Title": "Local News",
                "Synopsis": "Evening headlines"
            },
            {
                "StartTime": 2000003600,
                "EndTime":   2000007200,
                "Title": "The Daily Show",
                "SeriesID": "ds456",
                "EpisodeTitle": "Episode A"
            }
        ]
    }
]
"""

// MARK: - URL building (stateless — no MockURLProtocol, can run concurrently)

@Suite("GuideStore URL building")
struct GuideStoreURLTests {

    @Test func localDevice_defaultHours() {
        let device = makeLocalDevice(ip: "192.168.1.100")
        let url = GuideStore.guideURL(for: device)
        let comps = URLComponents(url: url!, resolvingAgainstBaseURL: false)!
        let items = Dictionary(uniqueKeysWithValues: comps.queryItems!.map { ($0.name, $0.value ?? "") })
        #expect(comps.host == "192.168.1.100")
        #expect(items["Duration"] == "13")   // hours+1 (lookback window)
        #expect(items["Start"] != nil)        // epoch-relative; just assert present
    }

    @Test func localDevice_customHours() {
        let device = makeLocalDevice(ip: "10.0.0.5")
        let url = GuideStore.guideURL(for: device, hours: 24)
        let comps = URLComponents(url: url!, resolvingAgainstBaseURL: false)!
        let items = Dictionary(uniqueKeysWithValues: comps.queryItems!.map { ($0.name, $0.value ?? "") })
        #expect(comps.host == "10.0.0.5")
        #expect(items["Duration"] == "25")
        #expect(items["Start"] != nil)
    }

    @Test func cloudDevice() {
        let device = makeCloudDevice(auth: "token99")
        let url = GuideStore.guideURL(for: device, hours: 12)
        let comps = URLComponents(url: url!, resolvingAgainstBaseURL: false)!
        let items = Dictionary(uniqueKeysWithValues: comps.queryItems!.map { ($0.name, $0.value ?? "") })
        #expect(comps.host == "api.hdhomerun.com")
        #expect(items["DeviceAuth"] == "token99")
        #expect(items["Duration"] == "13")
        #expect(items["Start"] != nil)
    }

    // Cloud host assertion (DeviceAuth present → api.hdhomerun.com) is already covered by
    // cloudDevice above — guideURL(for:hours:) has one code path, not a separate default-hours one.
}

// MARK: - MockURLProtocol-dependent suites (serialized to prevent handler collisions)
//
// MockURLProtocol.requestHandler is a static var shared across all tests. Swift Testing
// runs suites concurrently by default; without serialization, test B in suite Y can
// overwrite the handler set by test A in suite X before A's URLSession request fires.
// Wrapping all affected suites under a single .serialized parent prevents this race.

@Suite("GuideStore (mock-network)", .serialized)
struct GuideStoreMockNetworkTests {

    // MARK: - Load and populate

    @Suite("GuideStore load")
    struct GuideStoreLoadTests {

        @Test @MainActor func load_populatesChannelsByDevice() async {
            let store = GuideStore(session: makeSession())
            let device = makeLocalDevice()
            MockURLProtocol.requestHandler = { req in
                (okResponse(for: req.url!), sampleGuideJSON.data(using: .utf8)!)
            }
            await store.load(for: device)
            #expect(store.channels(deviceId: device.DeviceID).count == 2)
        }

        @Test @MainActor func load_marksTimestampFresh() async {
            let store = GuideStore(session: makeSession())
            let device = makeLocalDevice()
            #expect(!store.isFresh(deviceId: device.DeviceID))
            MockURLProtocol.requestHandler = { req in
                (okResponse(for: req.url!), sampleGuideJSON.data(using: .utf8)!)
            }
            await store.load(for: device)
            #expect(store.isFresh(deviceId: device.DeviceID))
        }

        @Test @MainActor func load_networkError_doesNotCrash() async {
            let store = GuideStore(session: makeSession())
            let device = makeLocalDevice()
            MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
            await store.load(for: device)
            #expect(store.channels(deviceId: device.DeviceID).isEmpty)
            #expect(!store.isFresh(deviceId: device.DeviceID))
        }

        @Test @MainActor func load_badJSON_doesNotCrash() async {
            let store = GuideStore(session: makeSession())
            let device = makeLocalDevice()
            MockURLProtocol.requestHandler = { req in
                (okResponse(for: req.url!), Data("not json".utf8))
            }
            await store.load(for: device)
            #expect(store.channels(deviceId: device.DeviceID).isEmpty)
        }
    }

    // MARK: - Channel entry index

    @Suite("GuideStore channel entries")
    struct GuideStoreEntryTests {

        @Test @MainActor func entries_allPresentBeforeCutoff() async {
            let store = GuideStore(session: makeSession())
            let device = makeLocalDevice()
            MockURLProtocol.requestHandler = { req in
                (okResponse(for: req.url!), sampleGuideJSON.data(using: .utf8)!)
            }
            await store.load(for: device)
            let before = Date(timeIntervalSince1970: 1_000_000_000)
            let entries = store.entries(deviceId: device.DeviceID, channelNum: "5.1", after: before)
            #expect(entries.count == 2)
        }

        @Test @MainActor func entries_noneAfterCutoff() async {
            let store = GuideStore(session: makeSession())
            let device = makeLocalDevice()
            MockURLProtocol.requestHandler = { req in
                (okResponse(for: req.url!), sampleGuideJSON.data(using: .utf8)!)
            }
            await store.load(for: device)
            let after = Date(timeIntervalSince1970: 2_001_000_000)
            let entries = store.entries(deviceId: device.DeviceID, channelNum: "5.1", after: after)
            #expect(entries.isEmpty)
        }

        @Test @MainActor func entries_sortedByStartTime() async {
            let store = GuideStore(session: makeSession())
            let device = makeLocalDevice()
            MockURLProtocol.requestHandler = { req in
                (okResponse(for: req.url!), sampleGuideJSON.data(using: .utf8)!)
            }
            await store.load(for: device)
            let before = Date(timeIntervalSince1970: 1_000_000_000)
            let entries = store.entries(deviceId: device.DeviceID, channelNum: "5.1", after: before)
            #expect(entries.first?.Title == "Local News")
            #expect(entries.last?.Title == "The Daily Show")
        }

        @Test @MainActor func entries_unknownChannel_isEmpty() async {
            let store = GuideStore(session: makeSession())
            let device = makeLocalDevice()
            MockURLProtocol.requestHandler = { req in
                (okResponse(for: req.url!), sampleGuideJSON.data(using: .utf8)!)
            }
            await store.load(for: device)
            let entries = store.entries(deviceId: device.DeviceID, channelNum: "99.9")
            #expect(entries.isEmpty)
        }

        // buildIndex must prune channelEntryIndex for a channel dropped from a device's lineup
        // between fetches, not just leave the stale entry sitting there — mirrors the existing
        // seriesIndex pruning. First load has 5.1+8.1; second (same device) has only 5.1.
        @Test @MainActor func entries_channelDroppedFromLineup_isPrunedNotStale() async {
            let store = GuideStore(session: makeSession())
            let device = makeLocalDevice()
            let before = Date(timeIntervalSince1970: 1_000_000_000)

            MockURLProtocol.requestHandler = { req in
                (okResponse(for: req.url!), sampleGuideJSON.data(using: .utf8)!)
            }
            await store.load(for: device)
            #expect(store.entries(deviceId: device.DeviceID, channelNum: "8.1", after: before).count == 1)

            MockURLProtocol.requestHandler = { req in
                (okResponse(for: req.url!), sampleGuideJSONChannelDropped.data(using: .utf8)!)
            }
            await store.load(for: device)
            #expect(store.entries(deviceId: device.DeviceID, channelNum: "8.1", after: before).isEmpty)
            // 5.1 (still in the lineup) must be unaffected by the prune.
            #expect(store.entries(deviceId: device.DeviceID, channelNum: "5.1", after: before).count == 2)
        }
    }

    // MARK: - Series index

    @Suite("GuideStore series lookup")
    struct GuideStoreSeriesTests {

        @Test @MainActor func nextEpisode_findsFirstMatch() async {
            let store = GuideStore(session: makeSession())
            let device = makeLocalDevice()
            MockURLProtocol.requestHandler = { req in
                (okResponse(for: req.url!), sampleGuideJSON.data(using: .utf8)!)
            }
            await store.load(for: device)
            let before = Date(timeIntervalSince1970: 1_000_000_000)
            let match = store.nextEpisode(seriesID: "ds456", after: before)
            #expect(match != nil)
            #expect(match?.entry.Title == "The Daily Show")
        }

        @Test @MainActor func nextEpisode_channelFilter_picks81() async {
            let store = GuideStore(session: makeSession())
            let device = makeLocalDevice()
            MockURLProtocol.requestHandler = { req in
                (okResponse(for: req.url!), sampleGuideJSON.data(using: .utf8)!)
            }
            await store.load(for: device)
            let before = Date(timeIntervalSince1970: 1_000_000_000)
            let match = store.nextEpisode(seriesID: "ds456", channelNum: "8.1", after: before)
            #expect(match?.entry.EpisodeTitle == "Episode B")
            #expect(match?.channelNum == "8.1")
        }

        @Test @MainActor func nextEpisode_channelFilter_noMatch() async {
            let store = GuideStore(session: makeSession())
            let device = makeLocalDevice()
            MockURLProtocol.requestHandler = { req in
                (okResponse(for: req.url!), sampleGuideJSON.data(using: .utf8)!)
            }
            await store.load(for: device)
            let before = Date(timeIntervalSince1970: 1_000_000_000)
            let match = store.nextEpisode(seriesID: "ds456", channelNum: "99.9", after: before)
            #expect(match == nil)
        }

        @Test @MainActor func nextEpisode_afterCutoff_returnsNil() async {
            let store = GuideStore(session: makeSession())
            let device = makeLocalDevice()
            MockURLProtocol.requestHandler = { req in
                (okResponse(for: req.url!), sampleGuideJSON.data(using: .utf8)!)
            }
            await store.load(for: device)
            let after = Date(timeIntervalSince1970: 2_001_000_000)
            let match = store.nextEpisode(seriesID: "ds456", after: after)
            #expect(match == nil)
        }

        @Test @MainActor func nextEpisode_unknownSeriesID_returnsNil() async {
            let store = GuideStore(session: makeSession())
            let device = makeLocalDevice()
            MockURLProtocol.requestHandler = { req in
                (okResponse(for: req.url!), sampleGuideJSON.data(using: .utf8)!)
            }
            await store.load(for: device)
            #expect(store.nextEpisode(seriesID: "does-not-exist") == nil)
        }
    }

    // MARK: - Favorite-channel tie-break

    @Suite("GuideStore favorite tie-break")
    struct GuideStoreFavoriteTieBreakTests {

        // Two channels air the identical SeriesID at the identical StartTime/EndTime — a genuine
        // tie, unlike sampleGuideJSON where "The Daily Show" airs at different times per channel.
        // 2.1 is listed first, so it's the incidental (insertion-order) winner with no preference.
        private static let simulcastJSON = """
        [
            {
                "GuideNumber": "2.1",
                "GuideName": "TPT 2",
                "Guide": [
                    {"StartTime": 2000000000, "EndTime": 2000003600, "Title": "Simulcast Show", "SeriesID": "sim789", "EpisodeTitle": "Ep1"}
                ]
            },
            {
                "GuideNumber": "2.4",
                "GuideName": "TPTKids",
                "Guide": [
                    {"StartTime": 2000000000, "EndTime": 2000003600, "Title": "Simulcast Show", "SeriesID": "sim789", "EpisodeTitle": "Ep1"}
                ]
            }
        ]
        """

        @Test @MainActor func nextEpisode_noPreference_picksInsertionOrderWinner() async {
            let store = GuideStore(session: makeSession())
            let device = makeLocalDevice()
            MockURLProtocol.requestHandler = { req in
                (okResponse(for: req.url!), Self.simulcastJSON.data(using: .utf8)!)
            }
            await store.load(for: device)
            let before = Date(timeIntervalSince1970: 1_000_000_000)
            let match = store.nextEpisode(seriesID: "sim789", after: before)
            #expect(match?.channelNum == "2.1")
        }

        @Test @MainActor func nextEpisode_preferFavorite_picksFavoritedChannel() async {
            let store = GuideStore(session: makeSession())
            let device = makeLocalDevice()
            MockURLProtocol.requestHandler = { req in
                (okResponse(for: req.url!), Self.simulcastJSON.data(using: .utf8)!)
            }
            await store.load(for: device)
            let before = Date(timeIntervalSince1970: 1_000_000_000)
            let match = store.nextEpisode(seriesID: "sim789", after: before,
                                          preferFavorite: { _, ch in ch == "2.4" })
            #expect(match?.channelNum == "2.4", "Should break the tie toward the favorited channel")
        }

        @Test @MainActor func nextEpisode_preferFavorite_noneFavorited_fallsBackToFirst() async {
            let store = GuideStore(session: makeSession())
            let device = makeLocalDevice()
            MockURLProtocol.requestHandler = { req in
                (okResponse(for: req.url!), Self.simulcastJSON.data(using: .utf8)!)
            }
            await store.load(for: device)
            let before = Date(timeIntervalSince1970: 1_000_000_000)
            let match = store.nextEpisode(seriesID: "sim789", after: before,
                                          preferFavorite: { _, _ in false })
            #expect(match?.channelNum == "2.1", "No favorite among tied candidates — keep the original winner")
        }

        @Test @MainActor func currentEpisode_preferFavorite_picksFavoritedChannel() async {
            let store = GuideStore(session: makeSession())
            let device = makeLocalDevice()
            MockURLProtocol.requestHandler = { req in
                (okResponse(for: req.url!), Self.simulcastJSON.data(using: .utf8)!)
            }
            await store.load(for: device)
            let at = Date(timeIntervalSince1970: 2_000_001_000)   // inside [StartTime, EndTime) for both
            let match = store.currentEpisode(seriesID: "sim789", at: at,
                                             preferFavorite: { _, ch in ch == "2.4" })
            #expect(match?.channelNum == "2.4")
        }

        @Test @MainActor func nextEpisode_preferFavorite_respectsChannelFilter() async {
            // A channel/device filter narrows candidates before the tie-break runs — the
            // favorited channel outside the filter must not be picked.
            let store = GuideStore(session: makeSession())
            let device = makeLocalDevice()
            MockURLProtocol.requestHandler = { req in
                (okResponse(for: req.url!), Self.simulcastJSON.data(using: .utf8)!)
            }
            await store.load(for: device)
            let before = Date(timeIntervalSince1970: 1_000_000_000)
            let match = store.nextEpisode(seriesID: "sim789", channelNum: "2.1", after: before,
                                          preferFavorite: { _, ch in ch == "2.4" })
            #expect(match?.channelNum == "2.1", "channelNum filter restricts to 2.1 regardless of favorite status")
        }

        // MARK: - preferUnrecorded tie-break (checked before preferFavorite)

        @Test @MainActor func nextEpisode_preferUnrecorded_picksTheUnrecordedCandidate() async {
            let store = GuideStore(session: makeSession())
            let device = makeLocalDevice()
            MockURLProtocol.requestHandler = { req in
                (okResponse(for: req.url!), Self.simulcastJSON.data(using: .utf8)!)
            }
            await store.load(for: device)
            let before = Date(timeIntervalSince1970: 1_000_000_000)
            // 2.1 is "already recorded", 2.4 is not — should pick 2.4 despite being the
            // insertion-order loser.
            let match = store.nextEpisode(seriesID: "sim789", after: before,
                                          preferUnrecorded: { $0.channelNum == "2.4" })
            #expect(match?.channelNum == "2.4")
        }

        @Test @MainActor func nextEpisode_preferUnrecorded_takesPriorityOverFavorite() async {
            let store = GuideStore(session: makeSession())
            let device = makeLocalDevice()
            MockURLProtocol.requestHandler = { req in
                (okResponse(for: req.url!), Self.simulcastJSON.data(using: .utf8)!)
            }
            await store.load(for: device)
            let before = Date(timeIntervalSince1970: 1_000_000_000)
            // 2.1 is both favorited AND already recorded; 2.4 is neither. Unrecorded must win —
            // a duplicate on a favorited channel is still a worse pick than a fresh episode
            // elsewhere.
            let match = store.nextEpisode(seriesID: "sim789", after: before,
                                          preferUnrecorded: { $0.channelNum == "2.4" },
                                          preferFavorite: { _, ch in ch == "2.1" })
            #expect(match?.channelNum == "2.4", "An unrecorded episode should outrank a favorited-but-duplicate one")
        }

        @Test @MainActor func nextEpisode_preferUnrecorded_bothRecorded_fallsThroughToFavorite() async {
            let store = GuideStore(session: makeSession())
            let device = makeLocalDevice()
            MockURLProtocol.requestHandler = { req in
                (okResponse(for: req.url!), Self.simulcastJSON.data(using: .utf8)!)
            }
            await store.load(for: device)
            let before = Date(timeIntervalSince1970: 1_000_000_000)
            // Both candidates "already recorded" — no distinguishing signal, so this falls
            // through to the favorite tie-break instead of picking arbitrarily.
            let match = store.nextEpisode(seriesID: "sim789", after: before,
                                          preferUnrecorded: { _ in false },
                                          preferFavorite: { _, ch in ch == "2.4" })
            #expect(match?.channelNum == "2.4", "Both tied on recorded-status — favorite should still decide")
        }

        @Test @MainActor func nextEpisode_preferUnrecorded_bothUnrecorded_fallsThroughToFavorite() async {
            let store = GuideStore(session: makeSession())
            let device = makeLocalDevice()
            MockURLProtocol.requestHandler = { req in
                (okResponse(for: req.url!), Self.simulcastJSON.data(using: .utf8)!)
            }
            await store.load(for: device)
            let before = Date(timeIntervalSince1970: 1_000_000_000)
            // Neither candidate is recorded — again no distinguishing signal, falls through.
            let match = store.nextEpisode(seriesID: "sim789", after: before,
                                          preferUnrecorded: { _ in true },
                                          preferFavorite: { _, ch in ch == "2.4" })
            #expect(match?.channelNum == "2.4", "Both tied on recorded-status — favorite should still decide")
        }

        @Test @MainActor func currentEpisode_preferUnrecorded_picksTheUnrecordedCandidate() async {
            let store = GuideStore(session: makeSession())
            let device = makeLocalDevice()
            MockURLProtocol.requestHandler = { req in
                (okResponse(for: req.url!), Self.simulcastJSON.data(using: .utf8)!)
            }
            await store.load(for: device)
            let at = Date(timeIntervalSince1970: 2_000_001_000)   // inside [StartTime, EndTime) for both
            let match = store.currentEpisode(seriesID: "sim789", at: at,
                                             preferUnrecorded: { $0.channelNum == "2.4" })
            #expect(match?.channelNum == "2.4")
        }

        // Regression for a real-world tight skip/reschedule loop: a single-channel series with its
        // sole on-air candidate already recorded used to fall back to `first` (the only candidate),
        // so scheduleNextAir kept re-picking the exact same duplicate every ~10s for the entire
        // broadcast window (observed: 360 duplicate-skip log/Discord entries in one hour for one
        // episode). Narrowing to channelNum "2.1" makes this a single-candidate lookup even though
        // the fixture has two channels airing the series. Both rows share identical setup and
        // differ only in whether the sole candidate counts as "recorded" — one table instead of
        // two near-identical bodies, same style as ShowTitleHelpersTests/AppConfigClampTests.
        @Test(arguments: [
            (isAlreadyRecorded: true,  expectedChannel: nil as String?),
            (isAlreadyRecorded: false, expectedChannel: "2.1"),
        ]) @MainActor func currentEpisode_preferUnrecorded_singleCandidate(_ row: (isAlreadyRecorded: Bool, expectedChannel: String?)) async {
            let store = GuideStore(session: makeSession())
            let device = makeLocalDevice()
            MockURLProtocol.requestHandler = { req in
                (okResponse(for: req.url!), Self.simulcastJSON.data(using: .utf8)!)
            }
            await store.load(for: device)
            let at = Date(timeIntervalSince1970: 2_000_001_000)   // inside [StartTime, EndTime)
            let match = store.currentEpisode(seriesID: "sim789", channelNum: "2.1", at: at,
                                             preferUnrecorded: { _ in !row.isAlreadyRecorded })
            #expect(match?.channelNum == row.expectedChannel,
                     row.isAlreadyRecorded
                        ? "The only on-air candidate is a known duplicate — must not be re-offered as the match"
                        : "A genuinely new on-air episode must still be returned")
        }

        // Three channels air the identical SeriesID at the identical StartTime/EndTime — a
        // 3-or-more-way simulcast, distinct from simulcastJSON's 2-way tie. 2.1 sorts first.
        private static let tripleSimulcastJSON = """
        [
            {
                "GuideNumber": "2.1",
                "GuideName": "TPT 2",
                "Guide": [
                    {"StartTime": 2000000000, "EndTime": 2000003600, "Title": "Simulcast Show", "SeriesID": "sim789", "EpisodeTitle": "Ep1"}
                ]
            },
            {
                "GuideNumber": "2.4",
                "GuideName": "TPTKids",
                "Guide": [
                    {"StartTime": 2000000000, "EndTime": 2000003600, "Title": "Simulcast Show", "SeriesID": "sim789", "EpisodeTitle": "Ep1"}
                ]
            },
            {
                "GuideNumber": "2.7",
                "GuideName": "TPT Create",
                "Guide": [
                    {"StartTime": 2000000000, "EndTime": 2000003600, "Title": "Simulcast Show", "SeriesID": "sim789", "EpisodeTitle": "Ep1"}
                ]
            }
        ]
        """

        // Regression: with 2+ unrecorded candidates among 3+ simulcast channels, the favorite
        // tie-break used to run over every candidate (recorded or not) and fall back to plain
        // `first` when nothing was favorited — silently handing back the recorded duplicate on
        // 2.1 even though 2.4 and 2.7 were genuinely unrecorded, reintroducing the same tight
        // reschedule loop for a 3-way simulcast that the single-candidate fix above closed for
        // the 1-candidate case. Both real callers always pass a non-nil preferFavorite, so this
        // exercises that exact shape rather than the (never-hit-in-practice) nil-preferFavorite path.
        @Test @MainActor func currentEpisode_preferUnrecorded_multipleUnrecordedAmongThreeCandidates_neverPicksTheDuplicate() async {
            let store = GuideStore(session: makeSession())
            let device = makeLocalDevice()
            MockURLProtocol.requestHandler = { req in
                (okResponse(for: req.url!), Self.tripleSimulcastJSON.data(using: .utf8)!)
            }
            await store.load(for: device)
            let at = Date(timeIntervalSince1970: 2_000_001_000)   // inside [StartTime, EndTime) for all three
            // 2.1 (sorts first) is the recorded duplicate; 2.4 and 2.7 are not; nothing is favorited.
            let match = store.currentEpisode(seriesID: "sim789", at: at,
                                             preferUnrecorded: { $0.channelNum != "2.1" },
                                             preferFavorite: { _, _ in false })
            #expect(match?.channelNum != "2.1", "Must not fall back to the recorded duplicate when unrecorded alternatives exist")
        }

    }

    // MARK: - Invalidation

    @Suite("GuideStore invalidation")
    struct GuideStoreInvalidationTests {

        @Test @MainActor func invalidateAll_clearsEverything() async {
            let store = GuideStore(session: makeSession())
            let d1 = makeLocalDevice(ip: "1.1.1.1", id: "DEV1")
            let d2 = makeLocalDevice(ip: "2.2.2.2", id: "DEV2")
            MockURLProtocol.requestHandler = { req in
                (okResponse(for: req.url!), sampleGuideJSON.data(using: .utf8)!)
            }
            await store.loadAll(devices: [d1, d2])
            #expect(store.channelsByDevice.count == 2)

            store.invalidateAll()
            #expect(store.channelsByDevice.isEmpty)
            #expect(!store.isFresh(deviceId: d1.DeviceID))
            #expect(!store.isFresh(deviceId: d2.DeviceID))
        }
    }

    // MARK: - loadAll

    @Suite("GuideStore loadAll")
    struct GuideStoreLoadAllTests {

        @Test @MainActor func loadAll_loadsMultipleDevices() async {
            let store = GuideStore(session: makeSession())
            let d1 = makeLocalDevice(ip: "1.1.1.1", id: "DEV1")
            let d2 = makeLocalDevice(ip: "2.2.2.2", id: "DEV2")
            MockURLProtocol.requestHandler = { req in
                (okResponse(for: req.url!), sampleGuideJSON.data(using: .utf8)!)
            }
            await store.loadAll(devices: [d1, d2])
            #expect(store.channelsByDevice.count == 2)
            #expect(store.isFresh(deviceId: d1.DeviceID))
            #expect(store.isFresh(deviceId: d2.DeviceID))
        }

        @Test @MainActor func loadAll_emptyList_isNoop() async {
            let store = GuideStore(session: makeSession())
            await store.loadAll(devices: [])
            #expect(store.channelsByDevice.isEmpty)
        }
    }

    // MARK: - Title-fallback tier (currentEntryByTitle / nextEntryByTitle)

    @Suite("GuideStore title fallback")
    struct GuideStoreTitleFallbackTests {

        // The fallback matching tier for series whose guide entries omit SeriesID (see the
        // docs comments on both methods). Three contracts pinned here, each with a real
        // regression behind it: (1) entry titles are stripped via Show.seriesTitle before
        // comparing, so a stored series title matches a suffixed per-airing title; (2) the
        // deviceId filter applies even when channelNum is nil — the SeriesID(All) shape —
        // instead of silently scanning every device; (3) nextEntryByTitle's cross-channel
        // scan takes min-by-StartTime, not dictionary-iteration-order .first.
        private static let titleFallbackJSON = """
        [
            {
                "GuideNumber": "5.1",
                "GuideName": "KVUE",
                "Guide": [
                    {"StartTime": 2000000000, "EndTime": 2000003600, "Title": "South Park S24E116 Trey Parker; Matt Stone"},
                    {"StartTime": 2000010000, "EndTime": 2000013600, "Title": "South Park S24E117 Guest Name"}
                ]
            },
            {
                "GuideNumber": "8.1",
                "GuideName": "KXAN",
                "Guide": [
                    {"StartTime": 2000006000, "EndTime": 2000009600, "Title": "South Park S24E120 Someone Else"},
                    {"StartTime": 2000006000, "EndTime": 2000009600, "Title": "Nightly News"}
                ]
            }
        ]
        """

        @MainActor private func loadedStore(devices: [HDHRDevice]) async -> GuideStore {
            let store = GuideStore(session: makeSession())
            MockURLProtocol.requestHandler = { req in
                (okResponse(for: req.url!), Self.titleFallbackJSON.data(using: .utf8)!)
            }
            for d in devices { await store.load(for: d) }
            return store
        }

        @Test @MainActor func current_matchesSuffixedEntryAgainstStrippedTitle() async {
            let store = await loadedStore(devices: [makeLocalDevice()])
            let during = Date(timeIntervalSince1970: 2_000_001_000)
            let match = store.currentEntryByTitle("South Park", at: during)
            #expect(match?.entry.EndTime == 2_000_003_600)
            #expect(match?.channelNum == "5.1")
        }

        @Test @MainActor func current_rawUnstrippedQueryTitle_doesNotMatch() async {
            // The stored title for a series show is already stripped; querying with a full
            // suffixed title must NOT match (both sides normalize to series-name-only form,
            // so a suffixed query normalizes differently than it reads).
            let store = await loadedStore(devices: [makeLocalDevice()])
            let during = Date(timeIntervalSince1970: 2_000_001_000)
            #expect(store.currentEntryByTitle("South Park S24E116 Trey Parker; Matt Stone", at: during) == nil)
        }

        @Test @MainActor func current_exactTitleWithoutSuffix_stillMatches() async {
            let store = await loadedStore(devices: [makeLocalDevice()])
            let during = Date(timeIntervalSince1970: 2_000_007_000)
            let match = store.currentEntryByTitle("Nightly News", at: during)
            #expect(match?.channelNum == "8.1")
        }

        // seriesChannel's shape: both channelNum and deviceId set, which used to take a separate
        // fast-path branch that returned the sole on-channel match unconditionally, ignoring
        // preferUnrecorded entirely (unlike this same function's own no-channel/multi-channel scan
        // below, and unlike currentEpisode's equivalent single-candidate check). Caught live
        // 2026-08-24: a seriesChannel show with no SeriesID in the guide (so it fell to this
        // title-fallback tier) got stuck re-selecting the same already-recorded on-air rerun every
        // ~10s for its whole broadcast window — scheduleNextAir calls this again immediately after
        // startRecording's duplicate skip, so returning the duplicate here every time meant
        // show_next never actually advanced, spamming a "Skipped — already recorded" Discord card
        // on every idle tick instead of falling through to nextEntryByTitle once, correctly.
        @Test @MainActor func current_singleChannelFastPath_excludesAlreadyRecordedDuplicate() async {
            let device = makeLocalDevice()
            let store = await loadedStore(devices: [device])
            let during = Date(timeIntervalSince1970: 2_000_001_000)
            let match = store.currentEntryByTitle("South Park", channelNum: "5.1", deviceId: device.DeviceID,
                                                   at: during, preferUnrecorded: { _ in false })
            #expect(match == nil)
        }

        @Test @MainActor func current_singleChannelFastPath_stillMatchesWhenNotADuplicate() async {
            // Companion to the above — confirms the fix didn't just make this branch always nil.
            let device = makeLocalDevice()
            let store = await loadedStore(devices: [device])
            let during = Date(timeIntervalSince1970: 2_000_001_000)
            let match = store.currentEntryByTitle("South Park", channelNum: "5.1", deviceId: device.DeviceID,
                                                   at: during, preferUnrecorded: { _ in true })
            #expect(match?.entry.EndTime == 2_000_003_600)
        }

        @Test @MainActor func current_deviceIdFilterAppliesWithNilChannel() async {
            // SeriesID(All) shape: fixed deviceId, nil channelNum. Both devices carry an
            // airing of the title at `during` — the match must come from the requested
            // device only, proving the filter isn't dropped when channelNum is nil.
            let d1 = makeLocalDevice(ip: "1.1.1.1", id: "DEV1")
            let d2 = makeLocalDevice(ip: "2.2.2.2", id: "DEV2")
            let store = await loadedStore(devices: [d1, d2])
            let during = Date(timeIntervalSince1970: 2_000_001_000)
            let match = store.currentEntryByTitle("South Park", deviceId: "DEV2", at: during)
            #expect(match?.deviceId == "DEV2")
        }

        @Test @MainActor func next_crossChannelScan_picksSoonestNotDictionaryOrder() async {
            // After 5.1's first airing ends, the next "South Park" airings are 8.1 @
            // 2000006000 and 5.1 @ 2000010000. The scan concatenates per-channel lists in
            // arbitrary dictionary order — min(by: StartTime) must pick 8.1 regardless.
            let store = await loadedStore(devices: [makeLocalDevice()])
            let after = Date(timeIntervalSince1970: 2_000_004_000)
            let match = store.nextEntryByTitle("South Park", after: after)
            #expect(match?.entry.StartTime == 2_000_006_000)
            #expect(match?.channelNum == "8.1")
        }

        @Test @MainActor func next_fastPathWithBothFilters_staysOnChannel() async {
            // Both channelNum and deviceId set takes the direct per-channel bucket — the
            // sooner airing on 8.1 must not leak into a 5.1-scoped query.
            let device = makeLocalDevice()
            let store = await loadedStore(devices: [device])
            let after = Date(timeIntervalSince1970: 2_000_004_000)
            let match = store.nextEntryByTitle("South Park", channelNum: "5.1",
                                               deviceId: device.DeviceID, after: after)
            #expect(match?.entry.StartTime == 2_000_010_000)
            #expect(match?.channelNum == "5.1")
        }

        @Test @MainActor func next_unknownTitle_returnsNil() async {
            let store = await loadedStore(devices: [makeLocalDevice()])
            #expect(store.nextEntryByTitle("No Such Show",
                                           after: Date(timeIntervalSince1970: 1_000_000_000)) == nil)
        }

        // MARK: - Multi-channel tie-break (no SeriesID — same shape as GuideStoreFavoriteTieBreakTests'
        // simulcastJSON, but title-only, since that's the case currentEntryByTitle/nextEntryByTitle
        // actually run for: a seriesAll show whose guide entries never carry a SeriesID tag).
        // Two channels air the identical title at the identical StartTime/EndTime; 2.1 is listed
        // first, so it's the deterministic (lineup-order) winner with no preference given.

        private static let titleSimulcastJSON = """
        [
            {
                "GuideNumber": "2.1",
                "GuideName": "TPT 2",
                "Guide": [
                    {"StartTime": 2000000000, "EndTime": 2000003600, "Title": "Local News"}
                ]
            },
            {
                "GuideNumber": "2.4",
                "GuideName": "TPTKids",
                "Guide": [
                    {"StartTime": 2000000000, "EndTime": 2000003600, "Title": "Local News"}
                ]
            }
        ]
        """

        @MainActor private func loadedSimulcastStore(devices: [HDHRDevice]) async -> GuideStore {
            let store = GuideStore(session: makeSession())
            MockURLProtocol.requestHandler = { req in
                (okResponse(for: req.url!), Self.titleSimulcastJSON.data(using: .utf8)!)
            }
            for d in devices { await store.load(for: d) }
            return store
        }

        @Test @MainActor func current_noPreference_picksLineupOrderWinner() async {
            let store = await loadedSimulcastStore(devices: [makeLocalDevice()])
            let at = Date(timeIntervalSince1970: 2_000_001_000)
            let match = store.currentEntryByTitle("Local News", at: at)
            #expect(match?.channelNum == "2.1")
        }

        @Test @MainActor func current_preferFavorite_picksFavoritedChannel() async {
            let store = await loadedSimulcastStore(devices: [makeLocalDevice()])
            let at = Date(timeIntervalSince1970: 2_000_001_000)
            let match = store.currentEntryByTitle("Local News", at: at,
                                                  preferFavorite: { _, ch in ch == "2.4" })
            #expect(match?.channelNum == "2.4", "Should break the tie toward the favorited channel")
        }

        @Test @MainActor func next_preferFavorite_picksFavoritedChannel() async {
            let store = await loadedSimulcastStore(devices: [makeLocalDevice()])
            let before = Date(timeIntervalSince1970: 1_000_000_000)
            let match = store.nextEntryByTitle("Local News", after: before,
                                               preferFavorite: { _, ch in ch == "2.4" })
            #expect(match?.channelNum == "2.4", "Should break the tie toward the favorited channel")
        }

        @Test @MainActor func next_noPreference_picksLineupOrderWinner() async {
            let store = await loadedSimulcastStore(devices: [makeLocalDevice()])
            let before = Date(timeIntervalSince1970: 1_000_000_000)
            let match = store.nextEntryByTitle("Local News", after: before)
            #expect(match?.channelNum == "2.1")
        }
    }

    // MARK: - isFresh

    @Suite("GuideStore freshness")
    struct GuideStoreFreshnessTests {

        @Test @MainActor func isFresh_defaultInterval() async {
            let store = GuideStore(session: makeSession())
            let device = makeLocalDevice()
            MockURLProtocol.requestHandler = { req in
                (okResponse(for: req.url!), sampleGuideJSON.data(using: .utf8)!)
            }
            await store.load(for: device)
            #expect(store.isFresh(deviceId: device.DeviceID), "Just loaded — must be fresh within 1h window")
            #expect(!store.isFresh(deviceId: device.DeviceID, within: 0), "0-second window — must not be fresh")
        }

        @Test @MainActor func isFresh_beforeLoad_isFalse() {
            let store = GuideStore(session: makeSession())
            #expect(!store.isFresh(deviceId: "NEVER-LOADED"))
        }
    }
}
