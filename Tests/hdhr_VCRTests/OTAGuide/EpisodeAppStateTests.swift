import Foundation
import Testing
@testable import hdhr_VCR

// AppState's handling of `api/episodes` answers: mapping, re-mapping, empty answers, stale expiry, invalidation epoch, and the unknown-SeriesID gate.

@MainActor
struct EpisodeAppStateTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var t0: Int { Int(now.timeIntervalSince1970) }
    private func line(_ n: String) -> LineupEntry { LineupEntry(GuideNumber: n, GuideName: "ch\(n)", URL: "http://10.0.0.5:5004/auto/v\(n)", HD: 1, Favorite: nil, VideoCodec: nil, AudioCodec: nil) }
    private func airing(_ start: Int, ch: String = "5.1") -> EpisodeAiring { EpisodeAiring(startTime: start, endTime: start + 3600, title: "Show S01E01", channelNumber: ch) }
    private func device() -> HDHRDevice { HDHRDevice(DeviceID: "DEV", LocalIP: "10.0.0.5", BaseURL: nil, TunerCount: 2, FirmwareVersion: "1", DeviceAuth: "a") }
    private func state(lineup: [LineupEntry]) -> AppState {
        let s = makeTestAppState(devices: [device()], lineups: ["DEV": lineup])
        return s
    }
    private func apply(_ s: AppState, _ airings: [EpisodeAiring]?, at: Date? = nil, epoch: Int? = nil) -> Bool {
        s.applyEpisodeResult(seriesID: "C1", airings: airings, reason: airings == nil ? "boom" : nil, now: at ?? now,
                             devices: [(id: "DEV", lineup: s.lineups["DEV"] ?? [])], epoch: epoch ?? s.guideStore.invalidationEpoch)
    }
    private func held(_ s: AppState) -> Int { s.guideStore.episodeAiringCount(seriesID: "C1") }

    @Test func anAnswerIsMappedAndRemembered() {
        let s = state(lineup: [line("5.1")])
        #expect(apply(s, [airing(t0 + 3600), airing(t0 + 7200, ch: "9.9")]))
        #expect(held(s) == 1)
        #expect(s.episodeLastSuccess["C1"] == now)
        #expect(!s.episodeNothingUpcoming.contains("C1"))
    }

    @Test func anEmptyAnswerOrOneWithNothingInsideTheHorizonParksTheSeries() {
        let s = state(lineup: [line("5.1")])
        _ = apply(s, [])
        #expect(s.episodeNothingUpcoming.contains("C1") && held(s) == 0)
        _ = apply(s, [airing(t0 + Int(EpisodeSchedule.horizon) + 3600)])
        #expect(s.episodeNothingUpcoming.contains("C1") && held(s) == 0)
        _ = apply(s, [airing(t0 + 3600)])
        #expect(!s.episodeNothingUpcoming.contains("C1") && held(s) == 1)
    }

    @Test func aLineupThatArrivesLaterPicksUpTheStoredAnswer() {
        let s = state(lineup: [line("7.1")])
        _ = apply(s, [airing(t0 + 3600)])            // channel 5.1 is not on this tuner yet
        #expect(held(s) == 0)
        s.lineups["DEV"] = [line("7.1"), line("5.1")]
        s.remapEpisodeAirings(now: now)
        #expect(held(s) == 1)
    }

    @Test func aFailedRefreshKeepsTheLastAiringsUntilTheyAreStaleThenDropsThem() {
        let s = state(lineup: [line("5.1")])
        _ = apply(s, [airing(t0 + 3600)])
        #expect(!apply(s, nil, at: now + 3600) && held(s) == 1)                                // an hour on: still served
        #expect(apply(s, nil, at: now + EpisodeSchedule.staleAfter + 60) && held(s) == 0)      // past the limit: dropped
    }

    @Test func anAnswerFromBeforeAnInvalidationIsDiscarded() {
        let s = state(lineup: [line("5.1")])
        let old = s.guideStore.invalidationEpoch
        s.guideStore.invalidateAll()
        #expect(!apply(s, [airing(t0 + 3600)], epoch: old))
        #expect(held(s) == 0 && s.episodeLastSuccess["C1"] == nil)
    }

    @Test func aSeriesTheAppDoesNotKnowCostsNoCloudLookup() async {
        let s = state(lineup: [line("5.1")])
        await s.ensureEpisodeAirings(seriesID: "NOT-A-SERIES")
        await s.ensureEpisodeAirings(seriesID: "")
        #expect(s.episodeOnDemandTimes.isEmpty)
    }
}
