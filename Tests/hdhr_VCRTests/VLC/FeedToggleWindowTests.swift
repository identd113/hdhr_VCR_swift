import Foundation
import Testing
@testable import hdhr_VCR

// VLCPlayerView.feedToggleOutlivedWindow — decides whether a FEED session that finished starting
// (toggleFeedTranscode's 2–5 s startup wait) still has a live player window to belong to.
@Suite("FEED transcode toggle vs window lifetime")
struct FeedToggleWindowTests {
    @Test func windowOpenAndSameView_keepsSession() {
        let t = UUID()
        #expect(!VLCPlayerView.feedToggleOutlivedWindow(windowOpen: true, myToken: t, hostedToken: t))
    }

    @Test func windowClosed_releasesSession() {
        let t = UUID()
        #expect(VLCPlayerView.feedToggleOutlivedWindow(windowOpen: false, myToken: t, hostedToken: t))
    }

    @Test func viewSupersededByRebind_releasesSession() {
        #expect(VLCPlayerView.feedToggleOutlivedWindow(windowOpen: true, myToken: UUID(), hostedToken: UUID()))
    }

    @Test func noToken_onlyWindowStateMatters() {
        #expect(!VLCPlayerView.feedToggleOutlivedWindow(windowOpen: true, myToken: nil, hostedToken: UUID()))
    }
}
