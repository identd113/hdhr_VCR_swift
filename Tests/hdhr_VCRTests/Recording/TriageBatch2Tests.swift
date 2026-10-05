import Testing
import Foundation
@testable import hdhr_VCR

// 2026-10-05 triage batch 2: T04 (loadConfig keeps inactive series), T05 (device merge), T06 (guide load
// coalescing), T09 (effective interface), T10 (addShow outcome), T11 (scheduleNextAir vs a starting recording).

final class TriageMockURLProtocol: MockURLProtocolBase {
    private static var _handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    private static var _count = 0
    override class var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { _handler }
        set { _handler = newValue }
    }
    static var requestCount: Int { get { _count } set { _count = newValue } }
    override class func recordRequest() { _count += 1 }
}

private func okResp(_ url: URL) -> HTTPURLResponse { HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)! }

@Suite("T05 HDHRDevice.mergingFresh")
struct DeviceMergeTests {
    private func degradedUDPHit(id: String, ip: String) -> HDHRDevice {
        // What a UDP-only discovery returns: no tuner count / model / firmware / auth.
        let json = "{\"DeviceID\":\"\(id)\",\"LocalIP\":\"\(ip)\"}"
        return try! JSONDecoder().decode(HDHRDevice.self, from: Data(json.utf8))
    }

    @Test func degradedHit_keepsTunerCountModelFirmwareAndAuth() {
        var known = HDHRDevice.test(id: "AABB", ip: "10.0.0.5", tuners: 4, modelNumber: "HDTC-2US")
        known.DeviceAuth = "auth-token"
        let merged = known.mergingFresh(degradedUDPHit(id: "AABB", ip: "10.0.0.5"))
        #expect(merged.TunerCount == 4)
        #expect(merged.ModelNumber == "HDTC-2US")
        #expect(merged.supportsTranscode)
        #expect(merged.FirmwareVersion == "20240101")
        #expect(merged.DeviceAuth == "auth-token")
    }

    @Test func freshValuesOverrideKnownOnes() {
        let known = HDHRDevice.test(id: "AABB", ip: "10.0.0.5", tuners: 2, modelNumber: "HDVR-4US")
        let fresh = HDHRDevice.test(id: "AABB", ip: "10.0.0.9", tuners: 4, modelNumber: "HDTC-2US")
        let merged = known.mergingFresh(fresh)
        #expect(merged.TunerCount == 4)
        #expect(merged.ModelNumber == "HDTC-2US")
        #expect(merged.LocalIP == "10.0.0.9")
    }

    @Test func numericAddressIsNeverTradedForAnMDNSHostname() {
        let known = HDHRDevice.test(id: "AABB", ip: "10.0.0.5")
        let merged = known.mergingFresh(degradedUDPHit(id: "AABB", ip: "hdhomerun-aabb.local"))
        #expect(merged.LocalIP == "10.0.0.5")
    }

    @Test func aRelayStaysARelay_andMissedProbesReset() {
        var known = HDHRDevice.test(id: "FEED", isVirtualRelay: true)
        known.missedProbes = 2
        let merged = known.mergingFresh(degradedUDPHit(id: "FEED", ip: "192.168.1.100"))
        #expect(merged.isVirtualRelay)
        #expect(merged.missedProbes == 0)
    }
}

@Suite("T04/T09/T10/T11 AppState", .serialized)
struct TriageAppStateTests {

    @Test @MainActor func addShow_reportsWhatHappened() {
        let device = HDHRDevice.test(id: "AABBCCDD")
        let relay = HDHRDevice.test(id: "FEEDFEED", isVirtualRelay: true)
        let state = makeTestAppState(devices: [device, relay])
        var s = Show.blank(channel: "5.1", device: "AABBCCDD"); s.show_title = "A"
        #expect(state.addShow(s) == .added)
        #expect(state.addShow(s) == .alreadyExists)                      // same show_id again
        var r = Show.blank(channel: "5.1", device: "FEEDFEED"); r.show_title = "R"
        #expect(state.addShow(r) == .watchOnlyTuner)
        #expect(state.shows.count == 1)
    }

    @Test @MainActor func effectiveNetworkInterface_fallsBackToAutoForADisconnectedInterface() {
        let state = makeTestAppState()
        state.config.Network_interface = ""
        #expect(state.effectiveNetworkInterface == "")
        state.config.Network_interface = "zz-not-a-real-nic9"
        #expect(state.effectiveNetworkInterface == "")                    // dead → Auto, but the saved value is untouched
        #expect(state.config.Network_interface == "zz-not-a-real-nic9")
        if let real = availableNetworkInterfaces().first {
            state.config.Network_interface = real.name
            #expect(state.effectiveNetworkInterface == real.name)
        }
    }

    @Test @MainActor func loadConfig_keepsInactiveSeriesShows_dropsInactiveOneTimeShows() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cm = ConfigManager(appSupportDir: dir)
        var fixMe = Show.blank(channel: "5.1", device: "AABBCCDD")            // .dateTime, deactivated "no air days"
        fixMe.show_title = "Fix Me"; fixMe.show_is_series = true
        fixMe.show_active = false; fixMe.show_fail_reason = "No air days configured"
        var doneSingle = Show.blank(channel: "6.1", device: "AABBCCDD")
        doneSingle.show_title = "Done One-Off"; doneSingle.show_active = false
        var active = Show.blank(channel: "7.1", device: "AABBCCDD")
        active.show_title = "Active"; active.show_active = true
        try cm.save(ConfigFile(config: AppConfig(), shows: [fixMe, doneSingle, active]))

        let state = AppState(configManager: cm)
        state.skipStartup = true
        state.loadConfig()

        let titles = Set(state.shows.map(\.show_title))
        #expect(titles == ["Fix Me", "Active"])
    }

    @Test @MainActor func guideLoad_concurrentCallersShareOneRequest_andBothSeeSuccess() async {
        TriageMockURLProtocol.requestCount = 0
        let json = """
        [{"GuideNumber":"5.1","GuideName":"KFOO","Guide":[{"StartTime":2000000000,"EndTime":2000003600,"Title":"X"}]}]
        """
        TriageMockURLProtocol.requestHandler = { req in
            Thread.sleep(forTimeInterval: 0.3)                            // keep the first load in flight
            return (okResp(req.url!), Data(json.utf8))
        }
        let store = GuideStore(session: makeMockSession(TriageMockURLProtocol.self))
        let device = HDHRDevice.test(id: "AABBCCDD")
        async let first  = store.load(for: device)
        try? await Task.sleep(nanoseconds: 100_000_000)
        async let second = store.load(for: device)                        // arrives while the first is in flight
        let (a, b) = await (first, second)
        #expect(a && b, "the joiner must get the real result, not a spurious failure")
        #expect(TriageMockURLProtocol.requestCount == 1)
        #expect(store.channels(deviceId: "AABBCCDD").count == 1)
    }

    @Test @MainActor func scheduleNextAir_recordingStartedDuringGuideReload_leavesTheShowAlone() async {
        let device = HDHRDevice.test(id: "AABBCCDD", tuners: 2)
        var show = Show.blank(channel: "5.1", device: device.DeviceID)
        show.show_title = "Series"; show.show_active = true
        show.show_is_series = true; show.show_use_seriesid = true; show.show_seriesid = "abc123"
        let originalNext = Date().addingTimeInterval(3600), originalEnd = Date().addingTimeInterval(7200)
        show.show_next = originalNext; show.show_end = originalEnd
        let store = GuideStore(session: makeMockSession(TriageMockURLProtocol.self))
        let state = makeTestAppState(shows: [show], devices: [device], guideStore: store)
        let futureStart = Int(Date().addingTimeInterval(900).timeIntervalSince1970)
        let json = """
        [{"GuideNumber":"5.1","GuideName":"KFOO","Guide":[{"StartTime":\(futureStart),"EndTime":\(futureStart + 1800),"Title":"Series","SeriesID":"abc123"}]}]
        """
        TriageMockURLProtocol.requestCount = 0
        TriageMockURLProtocol.requestHandler = { req in
            // The idle loop starts this show's recording while the guide reload is suspended.
            DispatchQueue.main.sync { state.shows[0].show_recording = true }
            return (okResp(req.url!), Data(json.utf8))
        }

        await state.scheduleNextAir(index: 0)

        #expect(abs(state.shows[0].show_next!.timeIntervalSince(originalNext)) < 1)
        #expect(abs(state.shows[0].show_end!.timeIntervalSince(originalEnd)) < 1)
    }
}
