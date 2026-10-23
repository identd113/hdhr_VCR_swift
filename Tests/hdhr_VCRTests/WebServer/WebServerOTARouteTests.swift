import Testing
import Foundation
@testable import hdhr_VCR

// POST /api/ota-scan (WebServer.handleOTAScan): the request is checked before any tuner is touched, so a typo in an
// rf list is an error the caller sees instead of a scan of the wrong channels (or of every channel).

@Suite("POST /api/ota-scan validation")
struct WebServerOTARouteTests {

    private func post(_ json: String, state: AppState) async -> WebServer.WebResponse {
        await MainActor.run { WebServer().handleOTAScan(state: state, body: Data(json.utf8)) }
    }

    private func isBadRequest(_ r: WebServer.WebResponse) -> Bool {
        if case .badRequest = r { return true }
        return false
    }

    @Test(arguments: [#"{"rf":"31"}"#, #"{"rf":31}"#, #"{"rf":[31,"32"]}"#, #"{"rf":[3.5]}"#])
    func anRfThatIsNotAListOfNumbersIsRejected(json: String) async {
        let state = await makeTestAppState(devices: [.test(id: "DEV1")])
        #expect(isBadRequest(await post(json, state: state)))
    }

    @Test(arguments: [#"{"rf":[]}"#, #"{"rf":[1]}"#, #"{"rf":[37]}"#, #"{"rf":[52,99,-4]}"#])
    func anRfListWithNoValidChannelIsRejected_notTreatedAsScanEverything(json: String) async {
        let state = await makeTestAppState(devices: [.test(id: "DEV1")])
        #expect(isBadRequest(await post(json, state: state)))
        #expect(await state.otaScanTask == nil)
    }

    @Test func cancelIsAcceptedWithNothingRunning() async {
        let state = await makeTestAppState(devices: [.test(id: "DEV1")])
        let r = await post(#"{"cancel":true}"#, state: state)
        #expect(!isBadRequest(r))
    }

    @Test func aTunerAllowanceWithNoScanRunningIsNotAnError() async {
        let state = await makeTestAppState(devices: [.test(id: "DEV1")])
        let r = await post(#"{"tuners":1}"#, state: state)
        #expect(!isBadRequest(r))
        #expect(await state.otaScanTask == nil)
    }

    @Test func aMalformedBodyFallsBackToDefaultsRatherThanCrashing() async {
        let state = await makeTestAppState()   // no tuner: the scan itself reports that, the request is still well-formed
        let r = await post("not json", state: state)
        #expect(!isBadRequest(r))
    }

    private func isConflict(_ r: WebServer.WebResponse) -> Bool { if case .conflict = r { return true }; return false }
    private func isUnavailable(_ r: WebServer.WebResponse) -> Bool { if case .serviceUnavailable = r { return true }; return false }

    @Test func aScanThatIsRunningIsNeverRestarted_409() async {
        let state = await makeTestAppState(devices: [.test(id: "DEV1")])
        await MainActor.run { state.otaScanTask = Task { try? await Task.sleep(nanoseconds: 5_000_000_000) } }
        let r = await post(#"{"rf":[31]}"#, state: state)
        #expect(isConflict(r))
        await MainActor.run { state.otaScanTask?.cancel(); state.otaScanTask = nil }
    }

    @Test func noTunerToScanWith_503() async {
        let state = await makeTestAppState()   // no devices
        #expect(isUnavailable(await post(#"{"rf":[31]}"#, state: state)))
        let other = await makeTestAppState(devices: [.test(id: "DEV1")])
        #expect(isUnavailable(await post(#"{"deviceId":"NOPE"}"#, state: other)))
    }

    @Test func everyTunerBusy_503() async {
        let state = await makeTestAppState(devices: [.test(id: "DEV1", tuners: 1)])
        await MainActor.run {
            state.deviceTunerOccupancy["DEV1"] = [DeviceTunerInfo(Resource: "tuner0", VctNumber: "7.1", TargetIP: nil, SignalQualityPercent: nil)]
        }
        #expect(isUnavailable(await post(#"{"rf":[31]}"#, state: state)))
        #expect(await state.otaScanTask == nil)
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
