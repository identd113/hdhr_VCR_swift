import Foundation
import Testing
@testable import hdhr_VCR

// `api/episodes` as extra candidates for SeriesID lookups: decode, mapping to a tuner's channels, merge with the guide (guide wins), and the
// guide-only behaviour when nothing was fetched.

@MainActor
struct EpisodeScheduleTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var t0: Int { Int(now.timeIntervalSince1970) }
    private func line(_ n: String) -> LineupEntry { LineupEntry(GuideNumber: n, GuideName: "ch\(n)", URL: "http://10.0.0.5:5004/auto/v\(n)", HD: 1, Favorite: nil, VideoCodec: nil, AudioCodec: nil) }
    private func airing(_ start: Int, ch: String = "5.1", title: String = "Show S01E01") -> EpisodeAiring {
        EpisodeAiring(startTime: start, endTime: start + 3600, title: title, channelNumber: ch)
    }

    @Test func decodesAFlatArray_dropsRowsWithoutTimesOrChannel() throws {
        let json = #"[{"StartTime":100,"EndTime":200,"Title":"A","ChannelNumber":"5.1","ProgramID":"EP1","SeriesID":"C1"},{"StartTime":300,"Title":"no end","ChannelNumber":"5.1"},{"StartTime":400,"EndTime":500,"Title":"no channel"}]"#
        let a = try #require(EpisodeSchedule.decode(Data(json.utf8)))
        #expect(a.count == 1 && a[0].programID == "EP1" && a[0].channelNumber == "5.1")
    }

    @Test func aLiteralNullIsAnEmptySchedule() {
        #expect(EpisodeSchedule.decode(Data("null".utf8)) == [])
    }

    @Test func aBodyThatIsNotAnArrayIsNil() {
        #expect(EpisodeSchedule.decode(Data(#"{"Episodes":[]}"#.utf8)) == nil)
        #expect(EpisodeSchedule.decode(Data("oops".utf8)) == nil)
    }

    @Test func onlyAiringsOnChannelsTheTunerHasAndInTheFutureAreKept() {
        let a = [airing(t0 + 100, ch: "5.1"), airing(t0 + 200, ch: "99.9"), airing(t0 - 100, ch: "5.1")]
        let m = EpisodeSchedule.matches(for: a, seriesID: "C1", after: now, devices: [(id: "DEV", lineup: [line("5.1")])])
        #expect(m.count == 1 && m[0].deviceId == "DEV" && m[0].channelNum == "5.1" && m[0].entry.SeriesID == "C1")
    }

    @Test func oneMatchPerDeviceThatCarriesTheChannel() {
        let m = EpisodeSchedule.matches(for: [airing(t0 + 100)], seriesID: "C1", after: now,
                                        devices: [(id: "A", lineup: [line("5.1")]), (id: "B", lineup: [line("5.1")]), (id: "C", lineup: [line("7.1")])])
        #expect(Set(m.map(\.deviceId)) == ["A", "B"])
    }

    @Test func dueTiming() {
        let ids = ["a", "b", "c", "d"]
        let due = EpisodeSchedule.dueSeriesIDs(ids, now: now,
            lastSuccess: ["a": now - 3600, "b": now - 4 * 3600],            // a: fresh; b: stale
            lastAttempt: ["b": now - 4 * 3600, "c": now - 600, "d": now - 3600]) // c: failed 10 min ago; d: failed an hour ago
        #expect(Set(due) == ["b", "d"])
    }

    @Test func staleAfterTwoRefreshIntervals() {
        #expect(!EpisodeSchedule.isStale(lastSuccess: nil, now: now))
        #expect(!EpisodeSchedule.isStale(lastSuccess: now - 5 * 3600, now: now))
        #expect(EpisodeSchedule.isStale(lastSuccess: now - 7 * 3600, now: now))
    }

    @Test func emptyAnswerParksADayPastTheGuide() {
        #expect(EpisodeSchedule.parkPad(nothingUpcoming: false) == 3600)
        #expect(EpisodeSchedule.parkPad(nothingUpcoming: true) == 24 * 3600)
    }

    @Test func parkedTimeWithoutAnEmptyAnswerIsAnHourPastTheGuide() {
        let state = makeTestAppState(guideStore: store(guideStarts: [t0 + 1000]))
        let lastEnd = Date(timeIntervalSince1970: TimeInterval(t0 + 1000 + 3600))
        // Not told "nothing upcoming" for this series (nor for no series at all): the one-hour pad.
        #expect(state.seriesParkedTime(deviceId: "DEV", seriesID: "C1", now: now) == lastEnd.addingTimeInterval(3600))
        #expect(state.seriesParkedTime(deviceId: "DEV", now: now) == lastEnd.addingTimeInterval(3600))
    }

    // MARK: merged into the guide store

    private func store(guideStarts: [Int]) -> GuideStore {
        let s = GuideStore()
        let entries = guideStarts.map { st -> GuideEntry in var e = GuideEntry(StartTime: st, EndTime: st + 3600, Title: "Show S01E01"); e.SeriesID = "C1"; e.Filter = ["Sports"]; return e }
        s.buildIndex(deviceId: "DEV", channels: [GuideChannel(GuideNumber: "5.1", GuideName: "KSTP", Guide: entries)])
        return s
    }
    private func episodes(_ starts: [Int]) -> [GuideStore.SeriesMatch] {
        EpisodeSchedule.matches(for: starts.map { airing($0) }, seriesID: "C1", after: now, devices: [(id: "DEV", lineup: [line("5.1")])])
    }

    @Test func withoutEpisodesTheGuideAloneAnswers() {
        let s = store(guideStarts: [t0 + 1000])
        #expect(s.nextEpisode(seriesID: "C1", after: now)?.entry.StartTime == t0 + 1000)
        #expect(s.nextEpisode(seriesID: "C1", after: Date(timeIntervalSince1970: TimeInterval(t0 + 2000))) == nil)   // past the guide: nothing
    }

    @Test func episodesExtendPastTheGuideWindow() {
        let s = store(guideStarts: [t0 + 1000])
        s.setEpisodeAirings(seriesID: "C1", matches: episodes([t0 + 5 * 86_400]))
        let next = s.nextEpisode(seriesID: "C1", after: Date(timeIntervalSince1970: TimeInterval(t0 + 2000)))
        #expect(next?.entry.StartTime == t0 + 5 * 86_400)
        #expect(next?.deviceId == "DEV" && next?.channelNum == "5.1")
    }

    @Test func aGuideEntryBeatsAnEpisodesEntryForTheSameAiring() {
        let s = store(guideStarts: [t0 + 1000])
        s.setEpisodeAirings(seriesID: "C1", matches: episodes([t0 + 1000]))
        let next = s.nextEpisode(seriesID: "C1", after: now)
        #expect(next?.entry.Filter == ["Sports"])             // the guide's, with its genre tags
        #expect(s.nextEpisodes(seriesID: "C1", after: now).count == 1)
    }

    @Test func episodesFillInAiringsTheGuideLacksNearTheEdge() {
        let s = store(guideStarts: [t0 + 9000])
        s.setEpisodeAirings(seriesID: "C1", matches: episodes([t0 + 1000]))
        #expect(s.nextEpisode(seriesID: "C1", after: now)?.entry.StartTime == t0 + 1000)
        #expect(s.nextEpisodes(seriesID: "C1", after: now).map(\.entry.StartTime) == [t0 + 1000, t0 + 9000])
    }

    @Test func clearingEpisodesRestoresGuideOnly() {
        let s = store(guideStarts: [t0 + 1000])
        s.setEpisodeAirings(seriesID: "C1", matches: episodes([t0 + 5000]))
        #expect(s.episodeAiringCount(seriesID: "C1") == 1)
        s.setEpisodeAirings(seriesID: "C1", matches: [])
        #expect(s.episodeAiringCount(seriesID: "C1") == 0)
        #expect(s.nextEpisodes(seriesID: "C1", after: now).count == 1)
    }

    @Test func theChannelAndDeviceFiltersStillApplyToEpisodes() {
        let s = store(guideStarts: [t0 + 1000])
        s.setEpisodeAirings(seriesID: "C1", matches: episodes([t0 + 5000]))
        let later = Date(timeIntervalSince1970: TimeInterval(t0 + 2000))
        #expect(s.nextEpisode(seriesID: "C1", channelNum: "5.1", deviceId: "DEV", after: later) != nil)
        #expect(s.nextEpisode(seriesID: "C1", channelNum: "9.9", after: later) == nil)
        #expect(s.nextEpisode(seriesID: "C1", deviceId: "OTHER", after: later) == nil)
    }
}

struct FeatureTrackerTests {
    @Test func countsUsesAndFallbacksWithTheLastReason() {
        let t = FeatureTracker()
        t.used("x"); t.used("x"); t.fellBack("x", "boom"); t.fellBack("y", "nope")
        let s = t.snapshot()
        #expect(s["x"]?.used == 2 && s["x"]?.fellBack == 1 && s["x"]?.lastReason == "boom" && s["x"]?.lastFallback != nil)
        #expect(s["y"]?.used == 0 && s["y"]?.fellBack == 1)
        let j = t.jsonObject()
        #expect((j["x"] as? [String: Any])?["used"] as? Int == 2)
    }
}
