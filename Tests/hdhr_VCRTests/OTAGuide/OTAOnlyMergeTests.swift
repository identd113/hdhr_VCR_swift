import Foundation
import Testing
@testable import hdhr_VCR

@Suite("OTA-only channels merged in as ordinary channels")
@MainActor
struct OTAOnlyMergeTests {
    private func entry(_ title: String, _ start: Int) -> GuideEntry {
        var e = GuideEntry(StartTime: start, EndTime: start + 3600, Title: title)
        e.Filter = [AppState.airOnlyGenre]
        return e
    }
    private let tuner = GuideChannel(GuideNumber: "5.1", GuideName: "KSTP", Guide: [GuideEntry(StartTime: 1_000, EndTime: 4_600, Title: "News")])
    private func air() -> GuideChannel {
        GuideChannel(GuideNumber: "19.1", GuideName: "KKTW-LD", Guide: [entry("Third Shift", 2_000)])
    }
    private let far = Date(timeIntervalSince1970: 0)

    @Test func aFrequencyAddressIsRecognisedAndATunerAddressIsNot() {
        func line(_ url: String) -> LineupEntry { LineupEntry(GuideNumber: "1.1", GuideName: "X", URL: url, HD: nil, Favorite: nil, VideoCodec: nil, AudioCodec: nil) }
        #expect(line("http://10.0.2.101:5004/auto/ch503000000-2").isAirTuned)
        #expect(!line("http://10.0.2.101:5004/auto/v5.1").isAirTuned)
        #expect(!LineupEntry(GuideNumber: "1.1", GuideName: "X", URL: nil, HD: nil, Favorite: nil, VideoCodec: nil, AudioCodec: nil).isAirTuned)
    }

    @Test func supplementedChannelsAreQueryableLikeAnyOther() {
        let store = GuideStore()
        store.buildIndex(deviceId: "DEV", channels: [tuner])
        store.setSupplement(deviceId: "DEV", channels: [air()])
        #expect(Set(store.channels(deviceId: "DEV").map(\.GuideNumber)) == ["5.1", "19.1"])
        let found = store.entries(deviceId: "DEV", channelNum: "19.1", after: far)
        #expect(found.map(\.Title) == ["Third Shift"])
        #expect(found.first?.firstGenre == "Over the Air")
        #expect(found.first?.deviceId == "DEV" && found.first?.channelNum == "19.1")
    }

    @Test func aGuideReloadKeepsTheSupplement() {
        let store = GuideStore()
        store.setSupplement(deviceId: "DEV", channels: [air()])     // set before any guide has loaded
        store.buildIndex(deviceId: "DEV", channels: [tuner])
        #expect(store.channels(deviceId: "DEV").map(\.GuideNumber).contains("19.1"))
        store.buildIndex(deviceId: "DEV", channels: [tuner])        // a later reload
        #expect(store.entries(deviceId: "DEV", channelNum: "19.1", after: far).count == 1)
    }

    @Test func clearingTheSupplementRemovesTheChannelsAndKeepsTheRest() {
        let store = GuideStore()
        store.buildIndex(deviceId: "DEV", channels: [tuner])
        store.setSupplement(deviceId: "DEV", channels: [air()])
        store.setSupplement(deviceId: "DEV", channels: [])
        #expect(store.channels(deviceId: "DEV").map(\.GuideNumber) == ["5.1"])
        #expect(store.entries(deviceId: "DEV", channelNum: "19.1", after: far).isEmpty)
        #expect(store.entries(deviceId: "DEV", channelNum: "5.1", after: far).count == 1)
    }

    @Test func aSupplementNeverReplacesAChannelTheGuideAlreadyHas() {
        let store = GuideStore()
        let clash = GuideChannel(GuideNumber: "5.1", GuideName: "Air copy", Guide: [entry("Imposter", 9_000)])
        store.setSupplement(deviceId: "DEV", channels: [clash])
        store.buildIndex(deviceId: "DEV", channels: [tuner])
        #expect(store.entries(deviceId: "DEV", channelNum: "5.1", after: far).map(\.Title) == ["News"])
    }
}
