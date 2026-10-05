import Testing
import Foundation
@testable import hdhr_VCR

@Suite("LocalRelay URLs + GuideEntry.seriesTitle")
struct LocalRelayAndSeriesTitleTests {

    @Test func watchRecordingURL_roundTripsThroughClassifiers() {
        let url = LocalRelay.watchRecordingURL(port: 1980, showId: "abc", start: 42)
        #expect(url == "http://127.0.0.1:1980/api/watch-recording?show=abc&start=42")
        #expect(LocalRelay.isWatchRecording(url))
        #expect(LocalRelay.isRelay(url))
        #expect(!LocalRelay.isFeedLocalRelay(url))
    }

    @Test func feedLocalRelayURL_isRelayButNotWatchRecording() {
        let url = LocalRelay.feedLocalRelayURL(port: 2000, sessionId: "s1")
        #expect(url == "http://127.0.0.1:2000/api/feed-local-relay?session=s1")
        #expect(LocalRelay.isFeedLocalRelay(url))
        #expect(LocalRelay.isRelay(url))
        #expect(!LocalRelay.isWatchRecording(url))
    }

    @Test func realTunerURL_isNotARelay() {
        #expect(!LocalRelay.isRelay("http://192.168.1.50:5004/auto/v5.1"))
    }

    @Test func seriesTitle_usesStampWhenPresent_elseComputes() {
        var e = GuideEntry(StartTime: 0, EndTime: 1800, Title: "Show S01E02 Pilot")
        #expect(e.seriesTitle == "Show")                 // computed fallback
        e.cachedSeriesTitle = "Stamped"
        #expect(e.seriesTitle == "Stamped")              // stamp wins
    }
}

@Suite("Station logo fallback")
struct StationLogoFallbackTests {
    @Test func webFallbackPointsAtTheAppIconRoute_andOnErrorSwapsOnceThenHides() {
        #expect(WebServer.stationLogoFallbackPath == "/api/icon")
        let js = WebServer.stationLogoOnError
        #expect(js.contains("this.src='/api/icon'"))      // first failure → app icon
        #expect(js.contains("this.style.display='none'")) // the icon itself failing → hide (no infinite loop)
        #expect(!js.contains("\""))                       // safe inside a double-quoted HTML attribute
    }

    @Test func nativePlaceholderIsAlwaysAvailable_andSmall() {
        #expect(stationLogoPlaceholder.size.width <= 64 && stationLogoPlaceholder.size.height <= 64)
    }
}

@Suite("Lineup entry matching by stream URL")
struct LineupStreamURLMatchTests {
    private func entry(_ num: String, url: String?) -> LineupEntry {
        LineupEntry(GuideNumber: num, GuideName: "Ch \(num)", URL: url, HD: nil, Favorite: nil)
    }
    private var lineup: [LineupEntry] {
        [entry("5.1",  url: "http://10.0.0.2:5004/auto/v5.1"),
         entry("5.10", url: "http://10.0.0.2:5004/auto/v5.10"),
         entry("11.1", url: "http://10.0.0.2:5004/auto/v11.1"),
         entry("11.10", url: "http://10.0.0.2:5004/auto/v11.10"),
         entry("9.9",  url: nil),
         entry("9.8",  url: "")]
    }

    @Test func fiveDotOne_isNotFiveDotTen_inEitherOrder() {
        #expect(lineup.entry(matchingStreamURL: "http://10.0.0.2:5004/auto/v5.1")?.GuideNumber == "5.1")
        #expect(lineup.entry(matchingStreamURL: "http://10.0.0.2:5004/auto/v5.10")?.GuideNumber == "5.10")
        #expect(lineup.reversed().entry(matchingStreamURL: "http://10.0.0.2:5004/auto/v5.10")?.GuideNumber == "5.10")
        #expect(lineup.reversed().entry(matchingStreamURL: "http://10.0.0.2:5004/auto/v5.1")?.GuideNumber == "5.1")
        #expect(lineup.entry(matchingStreamURL: "http://10.0.0.2:5004/auto/v11.10")?.GuideNumber == "11.10")
        #expect(lineup.entry(matchingStreamURL: "http://10.0.0.2:5004/auto/v11.1")?.GuideNumber == "11.1")
    }

    @Test func transcodeQueryIsIgnored() {
        #expect(lineup.entry(matchingStreamURL: "http://10.0.0.2:5004/auto/v5.10?transcode=heavy")?.GuideNumber == "5.10")
    }

    @Test func unknownChannel_orPrefixOnlyURL_matchesNothing() {
        #expect(lineup.entry(matchingStreamURL: "http://10.0.0.2:5004/auto/v5") == nil)       // a prefix of 5.1 / 5.10
        #expect(lineup.entry(matchingStreamURL: "http://10.0.0.2:5004/auto/v5.100") == nil)   // 5.10 is a prefix of it
        #expect(lineup.entry(matchingStreamURL: "") == nil)
    }

    @Test func entriesWithEmptyOrMissingURL_neverMatch() {
        #expect(lineup.entry(matchingStreamURL: "http://10.0.0.2:5004/auto/v9.9") == nil)
        let onlyEmpty = [entry("9.9", url: nil), entry("9.8", url: "")]
        #expect(onlyEmpty.entry(matchingStreamURL: "http://anything") == nil)
    }
}
