import Testing
import AppKit
@testable import hdhr_VCR

@Suite("LaunchSplashPlan — gate, timing and checklist")
struct LaunchSplashPlanTests {
    @Test func shownOnEveryLaunchForAnyoneWhoWantsItWithMotion_aFirstRunIncluded() {
        #expect(LaunchSplashPlan.shouldShow(enabled: true, underTests: false, reduceMotion: false))
        #expect(!LaunchSplashPlan.shouldShow(enabled: false, underTests: false, reduceMotion: false))
        #expect(!LaunchSplashPlan.shouldShow(enabled: true, underTests: true, reduceMotion: false))
        #expect(!LaunchSplashPlan.shouldShow(enabled: true, underTests: false, reduceMotion: true))
    }

    @Test func waitsForStartup_butNeverUnderTheMinimumOrPastTheCap() {
        #expect(!LaunchSplashPlan.shouldFinish(elapsed: 0.5, startupDone: true))        // too quick to read
        #expect(LaunchSplashPlan.shouldFinish(elapsed: LaunchSplashPlan.minimumSeconds, startupDone: true))
        #expect(!LaunchSplashPlan.shouldFinish(elapsed: 4, startupDone: false))         // still starting
        #expect(LaunchSplashPlan.shouldFinish(elapsed: LaunchSplashPlan.capSeconds, startupDone: false))
    }

    @Test func checklistFlipsAsStartupProgresses() {
        let none = LaunchSplashPlan.stages(tunerName: nil, tunerCount: 0, channelCount: 0, guideLoaded: false, startupDone: false)
        #expect(none.map(\.done) == [false, false, false])
        #expect(none[0].label == "Looking for your tuner…")
        let all = LaunchSplashPlan.stages(tunerName: "HDHR-1", tunerCount: 2, channelCount: 112, guideLoaded: true, startupDone: true)
        #expect(all.map(\.done) == [true, true, true])
        #expect(all[0].label == "HDHR-1 · 2 tuners")
        #expect(all[1].label == "112 channels")
        let missing = LaunchSplashPlan.stages(tunerName: nil, tunerCount: 0, channelCount: 0, guideLoaded: false, startupDone: true)
        #expect(missing[0].label == "No tuner found")
    }
}
