import Testing
import Foundation
@testable import hdhr_VCR

// Scans of the air are started from the app only: the web server has no scan route, so a browser on the LAN can read the OTA data
// (status, Air Only rows, listings) but never ask for a scan. The embedded guide asks through the app's own bridge instead.

@Suite("Over-the-air scans are app-only")
struct WebServerOTARouteTests {

    @Test func theHelpPageListsNoScanRequest_butStillListsTheStatus() throws {
        let json = try #require(try JSONSerialization.jsonObject(with: APIDocs.helpJSON()) as? [String: Any])
        let paths = try #require(json["paths"] as? [String: Any])
        #expect(paths["/api/ota-scan"] == nil)
        #expect(paths["/api/ota-status"] != nil)
    }

    @Test func aSignalScanIsMarkedActiveUntilItEndsOrIsCancelled() async throws {
        let state = await makeTestAppState()   // nothing to measure: the scan ends at once
        await MainActor.run { state.startSignalScan(force: true) }
        for _ in 0..<40 where await state.signalScanActive { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(await !state.signalScanActive)
        await MainActor.run { state.cancelSignalScan() }
        #expect(await !state.signalScanActive)
    }
}
