import Testing
@testable import hdhr_VCR

// What the user is told when the guide can't load. A certificate failure is on the guide service's
// side (2026-10-09: SiliconDust's cert expired) and must say so, not read as a generic API error.
@Suite("AppState.guideFailureMessage")
struct GuideFailureMessageTests {
    @Test func certificateProblem_getsItsOwnPlainExplanation() {
        let m = AppState.guideFailureMessage(.certificate("its certificate has expired or isn't valid yet"),
                                             deviceId: "105404BE", retryMinutes: 4)
        #expect(m.title == "Guide Service Certificate Problem")
        #expect(m.detail.contains("api.hdhomerun.com"))
        #expect(m.detail.contains("its certificate has expired"))
        #expect(m.detail.contains("SiliconDust's side"))
        #expect(m.detail.contains("105404BE"))
        #expect(m.detail.contains("recovers"), "promises a follow-up message")
    }

    @Test func httpFailure_namesTheStatus() {
        let m = AppState.guideFailureMessage(.http(503), deviceId: "D", retryMinutes: 2)
        #expect(m.title == "Guide Load Failed")
        #expect(m.detail.contains("503"))
    }

    @Test func anythingElse_keepsTheGenericWording() {
        for f: GuideStore.LoadFailure? in [nil, .network("offline"), .badResponse] {
            let m = AppState.guideFailureMessage(f, deviceId: "D", retryMinutes: 5)
            #expect(m.title == "Guide Load Failed")
            #expect(m.detail == "Device D — API error, retry in 5 min")
        }
    }
}
