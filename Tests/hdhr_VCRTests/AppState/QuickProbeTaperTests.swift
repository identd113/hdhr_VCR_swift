import Testing
import Foundation
@testable import hdhr_VCR

@Suite("Device probe follow-up taper")
struct QuickProbeTaperTests {
    @Test func followUpsDoubleThenStopBeforeTheFiveMinuteCycle() {
        #expect(AppState.quickProbeDelay(step: 0) == 60)
        #expect(AppState.quickProbeDelay(step: 1) == 120)
        #expect(AppState.quickProbeDelay(step: 2) == 240)
        #expect(AppState.quickProbeDelay(step: 3) == nil)
        #expect(AppState.quickProbeDelay(step: 10) == nil)
    }
}
