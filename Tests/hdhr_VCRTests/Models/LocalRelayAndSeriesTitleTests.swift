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
