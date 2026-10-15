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

    // The first-run hand-off: the logo glides to the wizard's header icon, which sits `inset` from the wizard window's
    // top-left. Screen coordinates are y-up, the splash canvas y-down from its own top-left.
    @Test func wizardIconTarget_convertsScreenCoordinatesToTheSplashCanvas() {
        // Splash canvas = the whole 1440×900 screen at the origin; wizard 460×628 at (490, 136) (bottom-left origin).
        let wizard = NSRect(x: 490, y: 136, width: 460, height: 628)
        let t = LaunchSplashPlan.wizardIconTarget(wizardFrame: wizard, inset: CGPoint(x: 46, y: 44),
                                                  splashOrigin: .zero, splashHeight: 900)
        // x: 490 + 46. y: the wizard's top edge is at y=764 on screen and the icon 44 below it → 180 from the screen top.
        #expect(t == CGPoint(x: 536, y: 180))
    }

    @Test func wizardIconTarget_accountsForASplashWindowNotAtTheScreenOrigin() {
        let wizard = NSRect(x: 2000, y: 500, width: 460, height: 600)        // on a second display to the right
        let t = LaunchSplashPlan.wizardIconTarget(wizardFrame: wizard, inset: CGPoint(x: 46, y: 44),
                                                  splashOrigin: CGPoint(x: 1440, y: 100), splashHeight: 900)
        #expect(t == CGPoint(x: 606, y: 900 - ((1100 - 44) - 100)))
    }
}
