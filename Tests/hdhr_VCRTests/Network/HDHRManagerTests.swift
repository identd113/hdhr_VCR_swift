import Testing
import Foundation
@testable import hdhr_VCR

// MARK: - HDHRManager
//
// 2026-08-11 coverage pass measured HDHRManager.swift at 1.81% — essentially untested despite
// being the device-discovery/lineup-fetch core. mDNS multicast and UDP broadcast discovery hit
// real system sockets (getifaddrs/socket/sendto/recvfrom) with no injection seam, and are left
// uncovered here — see TODO.md. The HTTP-reachable half (fetchDeviceInfo, fetchLineup,
// mDNSDiscover, cloudDiscover, knownHostsDiscover, setFavorite) now goes through an injectable
// URLSession (HDHRManager.init(session:dataSession:)), the same seam shape as DiscordNotifier's
// defaulted `session: URLSession = .shared` parameter — constructor injection here instead since
// HDHRManager already stored `session`/`dataSession` as instance properties rather than taking
// them per-call. supplementDeviceAuth is pure (no I/O) and tested directly, no mock needed.
//
// Own mock URLProtocol storage (not GuideStoreTests' MockURLProtocol or DiscordNotifierTests'
// DiscordMockURLProtocol) — `requestHandler` is shared global mutable state, so a dedicated type +
// `.serialized` suite avoids a cross-file race under Swift Testing's default parallel execution
// (same reasoning DiscordNotifierTests.swift documents for its own copy). Shared request-replay
// mechanics live in TestFixtures.swift's `MockURLProtocolBase`.

private final class HDHRMockURLProtocol: MockURLProtocolBase {
    private static var _handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { _handler }
        set { _handler = newValue }
    }
}

private func makeHDHRManager() -> HDHRManager {
    let session = makeMockSession(HDHRMockURLProtocol.self)
    return HDHRManager(session: session, dataSession: session)
}

private func hdhrOKResponse(for url: URL) -> HTTPURLResponse { mockOKResponse(for: url) }

private func makeDevice(id: String = "AABBCCDD", ip: String = "192.168.1.100", auth: String? = nil) -> HDHRDevice {
    HDHRDevice(DeviceID: id, LocalIP: ip, BaseURL: "http://\(ip)", TunerCount: 2,
               FirmwareVersion: nil, DeviceAuth: auth)
}

@Suite("HDHRManager", .serialized)
struct HDHRManagerTests {

    // MARK: - fetchDeviceInfo

    @Test func fetchDeviceInfo_success_decodesDevice() async throws {
        HDHRMockURLProtocol.requestHandler = { req in
            let json = """
            {"DeviceID":"1234ABCD","LocalIP":"192.168.1.50","TunerCount":2,"FirmwareVersion":"20230629"}
            """
            return (hdhrOKResponse(for: req.url!), Data(json.utf8))
        }
        let manager = makeHDHRManager()
        let device = try await manager.fetchDeviceInfo(ip: "192.168.1.50")
        #expect(device.DeviceID == "1234ABCD")
        #expect(device.LocalIP == "192.168.1.50")
        #expect(device.TunerCount == 2)
    }

    @Test func fetchDeviceInfo_malformedJSON_throws() async {
        HDHRMockURLProtocol.requestHandler = { req in
            (hdhrOKResponse(for: req.url!), Data("not json".utf8))
        }
        let manager = makeHDHRManager()
        await #expect(throws: (any Error).self) {
            _ = try await manager.fetchDeviceInfo(ip: "192.168.1.50")
        }
    }

    // Mirrors the "Local Network Privacy fetch failure" shape documented in TODO.md's "Accepted"
    // section — a request that never reaches the device (host unreachable / permission-blocked)
    // surfaces as a URLError, not a decode error.
    @Test func fetchDeviceInfo_networkError_throws() async {
        HDHRMockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
        let manager = makeHDHRManager()
        await #expect(throws: (any Error).self) {
            _ = try await manager.fetchDeviceInfo(ip: "192.168.1.50")
        }
    }

    // MARK: - fetchLineup

    @Test func fetchLineup_success_decodesEntries() async throws {
        HDHRMockURLProtocol.requestHandler = { req in
            let json = """
            [
                {"GuideNumber":"5.1","GuideName":"KVUE","URL":"http://192.168.1.50/auto/v5.1","HD":1,"Favorite":1},
                {"GuideNumber":"8.1","GuideName":"KXAN","URL":"http://192.168.1.50/auto/v8.1"}
            ]
            """
            return (hdhrOKResponse(for: req.url!), Data(json.utf8))
        }
        let manager = makeHDHRManager()
        let device = makeDevice(ip: "192.168.1.50")
        let lineup = try await manager.fetchLineup(for: device)
        #expect(lineup.count == 2)
        #expect(lineup[0].GuideNumber == "5.1")
        #expect(lineup[0].isFavorite == true)
        #expect(lineup[1].isFavorite == false)
    }

    @Test func fetchLineup_malformedJSON_throws() async {
        HDHRMockURLProtocol.requestHandler = { req in
            (hdhrOKResponse(for: req.url!), Data("<html>not json</html>".utf8))
        }
        let manager = makeHDHRManager()
        let device = makeDevice(ip: "192.168.1.50")
        await #expect(throws: (any Error).self) {
            _ = try await manager.fetchLineup(for: device)
        }
    }

    @Test func fetchLineup_usesDeviceLocalIP_notBaseURL() async throws {
        var capturedURL: URL?
        HDHRMockURLProtocol.requestHandler = { req in
            capturedURL = req.url
            return (hdhrOKResponse(for: req.url!), Data("[]".utf8))
        }
        let manager = makeHDHRManager()
        // BaseURL deliberately points elsewhere — lineupURL must always be built from LocalIP
        // (mDNS hostnames in LineupURL/BaseURL aren't reliably resolvable, per Models.swift's
        // lineupURL doc comment).
        let device = HDHRDevice(DeviceID: "X", LocalIP: "10.0.0.9", BaseURL: "http://hdhomerun.local",
                                 TunerCount: nil, FirmwareVersion: nil, DeviceAuth: nil)
        _ = try await manager.fetchLineup(for: device)
        #expect(capturedURL?.host == "10.0.0.9")
    }

    // MARK: - mDNSDiscover

    @Test func mDNSDiscover_arrayResponse_returnsAllDevices() async throws {
        HDHRMockURLProtocol.requestHandler = { req in
            let json = """
            [{"DeviceID":"11111111","LocalIP":"10.0.0.5"},{"DeviceID":"22222222","LocalIP":"10.0.0.6"}]
            """
            return (hdhrOKResponse(for: req.url!), Data(json.utf8))
        }
        let manager = makeHDHRManager()
        let devices = try await manager.mDNSDiscover()
        #expect(devices.count == 2)
    }

    @Test func mDNSDiscover_singleObjectResponse_returnsOneDevice() async throws {
        HDHRMockURLProtocol.requestHandler = { req in
            let json = """
            {"DeviceID":"33333333","LocalIP":"10.0.0.7"}
            """
            return (hdhrOKResponse(for: req.url!), Data(json.utf8))
        }
        let manager = makeHDHRManager()
        let devices = try await manager.mDNSDiscover()
        #expect(devices.count == 1)
        #expect(devices[0].DeviceID == "33333333")
    }

    // MARK: - cloudDiscover

    @Test func cloudDiscover_success_decodesDevices() async throws {
        HDHRMockURLProtocol.requestHandler = { req in
            let json = """
            [{"DeviceID":"AAAAAAAA","LocalIP":"10.0.0.2","DeviceAuth":"auth123"}]
            """
            return (hdhrOKResponse(for: req.url!), Data(json.utf8))
        }
        let manager = makeHDHRManager()
        let devices = try await manager.cloudDiscover()
        #expect(devices.count == 1)
        #expect(devices[0].DeviceAuth == "auth123")
    }

    // MARK: - knownHostsDiscover (concurrent fetch/merge)

    @Test func knownHostsDiscover_dedupesByDeviceID() async {
        // Both IPs are "the same device" reachable at two addresses — real-world scenario is a
        // stale saved IP alongside a fresh one after a DHCP lease change.
        HDHRMockURLProtocol.requestHandler = { req in
            let json = """
            {"DeviceID":"SAMEID01","LocalIP":"\(req.url!.host!)"}
            """
            return (hdhrOKResponse(for: req.url!), Data(json.utf8))
        }
        let manager = makeHDHRManager()
        let found = await manager.knownHostsDiscover(ips: ["10.0.0.10", "10.0.0.11"])
        #expect(found.count == 1)
        #expect(found[0].DeviceID == "SAMEID01")
    }

    @Test func knownHostsDiscover_emptyInput_noNetworkCall() async {
        HDHRMockURLProtocol.requestHandler = { _ in
            Issue.record("should not be called for empty ips")
            throw URLError(.badURL)
        }
        let manager = makeHDHRManager()
        let found = await manager.knownHostsDiscover(ips: [])
        #expect(found.isEmpty)
    }

    @Test func knownHostsDiscover_unreachableHost_isSkippedNotThrown() async {
        HDHRMockURLProtocol.requestHandler = { _ in throw URLError(.cannotConnectToHost) }
        let manager = makeHDHRManager()
        let found = await manager.knownHostsDiscover(ips: ["10.0.0.99"])
        #expect(found.isEmpty)
    }

    // MARK: - supplementDeviceAuth (pure function, no mock needed)

    @Test func supplementDeviceAuth_prefersLocalAuthOverCloud() {
        let manager = HDHRManager()
        let localWithAuth = makeDevice(id: "A", auth: "local-token")
        let localMissingAuth = makeDevice(id: "B", auth: nil)
        let cloud = [makeDevice(id: "B", auth: "cloud-token")]
        let result = manager.supplementDeviceAuth(local: [localWithAuth, localMissingAuth], cloud: cloud)
        let updatedB = result.first { $0.DeviceID == "B" }
        #expect(updatedB?.DeviceAuth == "local-token")
    }

    @Test func supplementDeviceAuth_fallsBackToCloudWhenNoLocalAuthExists() {
        let manager = HDHRManager()
        let localMissingAuth = makeDevice(id: "C", auth: nil)
        let cloud = [makeDevice(id: "C", auth: "cloud-token")]
        let result = manager.supplementDeviceAuth(local: [localMissingAuth], cloud: cloud)
        #expect(result.first?.DeviceAuth == "cloud-token")
    }

    @Test func supplementDeviceAuth_leavesExistingAuthUntouched() {
        let manager = HDHRManager()
        let local = [makeDevice(id: "D", auth: "already-has-one")]
        let cloud = [makeDevice(id: "D", auth: "should-not-be-used")]
        let result = manager.supplementDeviceAuth(local: local, cloud: cloud)
        #expect(result.first?.DeviceAuth == "already-has-one")
    }

    // MARK: - setFavorite

    // One (initial Favorite, setFavorite → expected query) table.
    @Test(arguments: [
        (initialFavorite: nil, setFavorite: true,  expectedQuery: "favorite=+5.1"),  // success_doesNotThrow
        (initialFavorite: 1,   setFavorite: false, expectedQuery: "favorite=-5.1"),  // unmark_usesMinusPrefix
    ] as [(initialFavorite: Int?, setFavorite: Bool, expectedQuery: String)])
    func setFavorite(_ row: (initialFavorite: Int?, setFavorite: Bool, expectedQuery: String)) async throws {
        var capturedURL: URL?
        HDHRMockURLProtocol.requestHandler = { req in
            capturedURL = req.url
            return (hdhrOKResponse(for: req.url!), Data())
        }
        let manager = makeHDHRManager()
        let device = makeDevice(ip: "192.168.1.50")
        let channel = LineupEntry(GuideNumber: "5.1", GuideName: "KVUE", URL: nil, HD: nil, Favorite: row.initialFavorite)
        try await manager.setFavorite(device: device, channel: channel, favorite: row.setFavorite)
        #expect(capturedURL?.query == row.expectedQuery)
    }

    @Test func setFavorite_httpErrorStatus_throws() async {
        HDHRMockURLProtocol.requestHandler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let manager = makeHDHRManager()
        let device = makeDevice(ip: "192.168.1.50")
        let channel = LineupEntry(GuideNumber: "5.1", GuideName: "KVUE", URL: nil, HD: nil, Favorite: nil)
        await #expect(throws: (any Error).self) {
            try await manager.setFavorite(device: device, channel: channel, favorite: true)
        }
    }

    // MARK: - default init still builds a working real session

    @Test func defaultInit_producesUsableManager() {
        // No mock — just confirms the nil-session default path (production behavior) still
        // constructs without crashing (short-timeout URLSessionConfiguration.default + .shared).
        let manager = HDHRManager()
        #expect(manager.streamURL(for: "5.1", lineup: [LineupEntry(GuideNumber: "5.1", GuideName: "KVUE", URL: "http://x", HD: nil, Favorite: nil)]) == "http://x")
    }
}
