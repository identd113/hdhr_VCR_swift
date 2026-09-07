import Testing
import Foundation
@testable import hdhr_VCR

// Coverage for WatchURLRequest.parse — the pure parser behind the hdhrvcrplus://watch URL scheme
// (hdhr_VCRApp.swift's AppDelegate.application(_:open:)), added 2026-09-07 so a FEED "Watch"
// action can be triggered non-interactively (`open 'hdhrvcrplus://...'`) for cross-machine
// testing. No AppState/NSApplication needed — pure URL-in, struct-out.
@Suite("WatchURLRequest.parse")
struct WatchURLRequestTests {

    @Test func validURL_parsesDeviceAndChannel() throws {
        let url = try #require(URL(string: "hdhrvcrplus://watch?dev=FEED04BE&channel=2.4"))
        let request = try #require(WatchURLRequest.parse(url))
        #expect(request.deviceId == "FEED04BE")
        #expect(request.channel == "2.4")
        #expect(request.wantsTranscode == false)
    }

    @Test func transcodeFlag_setsWantsTranscode() throws {
        let url = try #require(URL(string: "hdhrvcrplus://watch?dev=FEED04BE&channel=2.4&transcode=1"))
        let request = try #require(WatchURLRequest.parse(url))
        #expect(request.wantsTranscode == true)
    }

    @Test func transcodeFlag_anyOtherValueIsFalse() throws {
        let url = try #require(URL(string: "hdhrvcrplus://watch?dev=FEED04BE&channel=2.4&transcode=yes"))
        let request = try #require(WatchURLRequest.parse(url))
        #expect(request.wantsTranscode == false)
    }

    @Test func wrongScheme_returnsNil() throws {
        let url = try #require(URL(string: "https://watch?dev=FEED04BE&channel=2.4"))
        #expect(WatchURLRequest.parse(url) == nil)
    }

    @Test func wrongHost_returnsNil() throws {
        let url = try #require(URL(string: "hdhrvcrplus://record?dev=FEED04BE&channel=2.4"))
        #expect(WatchURLRequest.parse(url) == nil)
    }

    @Test func missingDev_returnsNil() throws {
        let url = try #require(URL(string: "hdhrvcrplus://watch?channel=2.4"))
        #expect(WatchURLRequest.parse(url) == nil)
    }

    @Test func missingChannel_returnsNil() throws {
        let url = try #require(URL(string: "hdhrvcrplus://watch?dev=FEED04BE"))
        #expect(WatchURLRequest.parse(url) == nil)
    }

    @Test func emptyDevValue_returnsNil() throws {
        let url = try #require(URL(string: "hdhrvcrplus://watch?dev=&channel=2.4"))
        #expect(WatchURLRequest.parse(url) == nil)
    }

    @Test func noQueryItemsAtAll_returnsNil() throws {
        let url = try #require(URL(string: "hdhrvcrplus://watch"))
        #expect(WatchURLRequest.parse(url) == nil)
    }
}
