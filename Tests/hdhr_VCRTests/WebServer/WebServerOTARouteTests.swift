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
}
