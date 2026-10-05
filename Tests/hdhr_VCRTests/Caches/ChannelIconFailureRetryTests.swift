import Testing
import Foundation
@testable import hdhr_VCR

// ChannelIconCache failure-retry policy (permanent 24 h vs transient 10 min) and the [LAN] log throttle.

final class IconMockURLProtocol: MockURLProtocolBase {
    private static var _handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    private static var _count = 0
    override class var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { _handler }
        set { _handler = newValue }
    }
    static var requestCount: Int { get { _count } set { _count = newValue } }
    override class func recordRequest() { _count += 1 }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
}

@Suite("ChannelIconCache failure retry", .serialized)
struct ChannelIconFailureRetryTests {
    private func makeCache(clock: Clock) -> ChannelIconCache {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return ChannelIconCache(cacheDir: base, session: makeMockSession(IconMockURLProtocol.self), now: { clock.now })
    }
    private func respond(_ status: Int) {
        IconMockURLProtocol.requestCount = 0
        IconMockURLProtocol.requestHandler = { req in (mockOKResponse(for: req.url!, statusCode: status), Data("nope".utf8)) }
    }

    @Test func classification() {
        #expect(ChannelIconCache.isPermanentFailure(statusCode: 404, gotImageData: false))
        #expect(ChannelIconCache.isPermanentFailure(statusCode: 403, gotImageData: false))
        #expect(ChannelIconCache.isPermanentFailure(statusCode: 410, gotImageData: false))
        #expect(ChannelIconCache.isPermanentFailure(statusCode: 200, gotImageData: false))   // 200 but not an image
        #expect(!ChannelIconCache.isPermanentFailure(statusCode: 500, gotImageData: false))
        #expect(!ChannelIconCache.isPermanentFailure(statusCode: 503, gotImageData: false))
        #expect(!ChannelIconCache.isPermanentFailure(statusCode: nil, gotImageData: false))  // no response at all
    }

    @Test func notFound_isNotRetriedOrRecountedAfterTenMinutes_butIsAfterADay() async {
        let clock = Clock(); let cache = makeCache(clock: clock)
        let url = "https://cdn.example/dead.png"
        respond(404)
        #expect(await cache.image(for: url) == nil)
        #expect(IconMockURLProtocol.requestCount == 1)

        clock.advance(11 * 60)
        #expect(await cache.image(for: url) == nil)
        #expect(IconMockURLProtocol.requestCount == 1)            // no second request
        #expect(await cache.countMissing(in: [url]) == 0)         // and not re-counted as "missing"

        clock.advance(24 * 3600)
        #expect(await cache.image(for: url) == nil)
        #expect(IconMockURLProtocol.requestCount == 2)            // retried after the day
    }

    @Test func serverError_isRetriedAfterTenMinutes() async {
        let clock = Clock(); let cache = makeCache(clock: clock)
        let url = "https://cdn.example/flaky.png"
        respond(503)
        #expect(await cache.image(for: url) == nil)
        clock.advance(5 * 60)
        #expect(await cache.image(for: url) == nil)
        #expect(IconMockURLProtocol.requestCount == 1)            // still inside the window
        clock.advance(6 * 60)
        #expect(await cache.image(for: url) == nil)
        #expect(IconMockURLProtocol.requestCount == 2)
    }

    @Test func networkError_isTransient() async {
        let clock = Clock(); let cache = makeCache(clock: clock)
        let url = "https://cdn.example/offline.png"
        IconMockURLProtocol.requestCount = 0
        IconMockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
        #expect(await cache.image(for: url) == nil)
        clock.advance(11 * 60)
        #expect(await cache.image(for: url) == nil)
        #expect(IconMockURLProtocol.requestCount == 2)
    }
}

@Suite("LANLogThrottle")
struct LANLogThrottleTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func firstFailureLogs_thenSuppressedUntilInterval() {
        var th = LANLogThrottle()
        #expect(th.recordFailure("fail:dev", at: t0) == 0)                       // logged, nothing suppressed yet
        #expect(th.recordFailure("fail:dev", at: t0.addingTimeInterval(5)) == nil)
        #expect(th.recordFailure("fail:dev", at: t0.addingTimeInterval(10)) == nil)
        #expect(th.recordFailure("fail:dev", at: t0.addingTimeInterval(LANLogThrottle.interval)) == 2)   // reports the 2 skipped
        #expect(th.recordFailure("fail:dev", at: t0.addingTimeInterval(LANLogThrottle.interval + 1)) == nil)
    }

    @Test func hostsAreIndependent() {
        var th = LANLogThrottle()
        #expect(th.recordFailure("fail:a", at: t0) == 0)
        #expect(th.recordFailure("fail:b", at: t0) == 0)
    }

    @Test func recovery_reportsOnceAndResetsTheStreak() {
        var th = LANLogThrottle()
        _ = th.recordFailure("fail:dev", at: t0)
        _ = th.recordFailure("fail:dev", at: t0.addingTimeInterval(1))
        #expect(th.recordSuccess("fail:dev") == 1)
        #expect(th.recordSuccess("fail:dev") == nil)                              // not failing any more
        #expect(th.recordFailure("fail:dev", at: t0.addingTimeInterval(2)) == 0)  // a new streak logs immediately
    }

    @Test func successWithoutPriorFailure_isSilent() {
        var th = LANLogThrottle()
        #expect(th.recordSuccess("fail:dev") == nil)
    }
}
