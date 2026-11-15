import Testing
import Foundation
@testable import hdhr_VCR

@Suite("FeedPlaylist")
struct FeedPlaylistTests {
    private func entry(_ title: String, start: Int = 1_700_000_000, end: Int = 1_700_001_800) -> GuideEntry {
        GuideEntry(StartTime: start, EndTime: end, Title: title)
    }

    @Test func m3uHasOneEntryPerChannelWithGuideLink() {
        let ch = FeedPlaylist.Channel(id: "a-1", number: "4.1", name: "KARE \"11\"", streamURL: "http://h:1980/auto/v4.1?dev=X",
                                      logoURL: nil, programmes: [])
        let m = FeedPlaylist.m3u([ch], guideURL: "http://h:1980/feed.xml")
        #expect(m.hasPrefix("#EXTM3U x-tvg-url=\"http://h:1980/feed.xml\"\n"))
        #expect(m.contains("tvg-id=\"a-1\" tvg-chno=\"4.1\" tvg-name=\"KARE '11'\""))
        #expect(m.contains("group-title=\"Recording Now\""))
        #expect(m.hasSuffix("http://h:1980/auto/v4.1?dev=X\n"))
    }

    @Test func xmltvEscapesAndUsesUTC() {
        var e = entry("Law & Order <SVU>")
        e.EpisodeTitle = "Pilot"; e.Synopsis = "a \"b\""; e.Filter = ["Drama"]; e.EpisodeNumber = "S01E02"
        let ch = FeedPlaylist.Channel(id: "a-1", number: "4.1", name: "KARE", streamURL: "u", logoURL: nil, programmes: [e])
        let x = FeedPlaylist.xmltv([ch])
        #expect(x.contains("<title>Law &amp; Order &lt;SVU&gt;</title>"))
        #expect(x.contains("start=\"20231114221320 +0000\""))
        #expect(x.contains("<category>Drama</category>"))
        #expect(x.contains("<episode-num system=\"onscreen\">S01E02</episode-num>"))
    }

    @Test func controlCharactersAreDropped() {
        let ch = FeedPlaylist.Channel(id: "a", number: "1", name: "A\u{1}B", streamURL: "u", logoURL: nil, programmes: [])
        #expect(FeedPlaylist.xmltv([ch]).contains("<display-name>AB</display-name>"))
    }

    @MainActor @Test func routesAre404WhileOff() {
        let state = AppState()
        let server = WebServer()
        guard case .notFound = server.feedPlaylistResponse(path: "/feed.m3u", state: state) else {
            Issue.record("expected 404 while the feed is off"); return
        }
    }
}
