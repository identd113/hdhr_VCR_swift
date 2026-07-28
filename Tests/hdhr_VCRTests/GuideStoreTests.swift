import Testing
import Foundation
@testable import hdhr_VCR

// MARK: - Mock URLProtocol

final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Helpers

private func makeSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

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

    @Test func cloudDevice_usesCloudHostNotLocal() {
        let device = makeCloudDevice(auth: "abc")
        let url = GuideStore.guideURL(for: device)
        #expect(url?.host == "api.hdhomerun.com",
                "DeviceAuth present → must use cloud API host")
    }
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
