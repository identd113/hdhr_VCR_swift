import Testing
import Foundation
@testable import hdhr_VCR

// MARK: - AppState.quickRecord(type:entry:device:channel:)
//
// The tuner-full check + addShowFromGuide call behind the Watch Now / VLCPlayerView "Record"
// pulldown (quickRecordMenu, GuideViewHelpers.swift). Extracted specifically so this logic —
// the part that can actually have bugs — is testable directly, without going through either
// caller's UI: the UI itself is a stock SwiftUI Menu, not app logic, and isn't reliably
// scriptable via AppleScript/System Events (NSMenu-tracking controls don't respond consistently
// to synthetic clicks the way plain buttons do). This is also the first coverage of
// addShowFromGuide itself, which had none before this pulldown existed.

@Suite("AppState.quickRecord")
struct QuickRecordTests {

    @Test @MainActor func addsShowAndReturnsTrue_whenTunerAvailable() {
        let device = HDHRDevice.test(id: "DEV1", tuners: 2)
        let channel = LineupEntry.test(number: "5.1", name: "KFOO")
        let entry = GuideEntry.test(title: "Evening News")
        let state = makeTestAppState(devices: [device], lineups: ["DEV1": [channel]])

        let recorded = state.quickRecord(type: .single, entry: entry, device: device, channel: channel)

        #expect(recorded == true)
        #expect(state.shows.count == 1)
        #expect(state.shows.first?.show_title == "Evening News")
        #expect(state.shows.first?.show_channel == "5.1")
        #expect(state.shows.first?.hdhr_record == "DEV1")
    }

    @Test @MainActor func returnsFalseAndAddsNothing_whenTunerFull() {
        let device = HDHRDevice.test(id: "DEV1", tuners: 1)
        let channel = LineupEntry.test(number: "5.1", name: "KFOO")
        let entry = GuideEntry.test(title: "Evening News")
        // One already-recording show on the device's only tuner — activeTunerCount == tunerCount.
        let recording = Show.testRecording(title: "Already Recording", channel: "9.9")
        var recordingOnDevice = recording
        recordingOnDevice.hdhr_record = "DEV1"
        let state = makeTestAppState(shows: [recordingOnDevice], devices: [device], lineups: ["DEV1": [channel]])

        let recorded = state.quickRecord(type: .single, entry: entry, device: device, channel: channel)

        #expect(recorded == false)
        // Only the pre-existing recording is present — quickRecord added nothing.
        #expect(state.shows.count == 1)
        #expect(state.shows.first?.show_title == "Already Recording")
    }

    @Test @MainActor func singleType_isNotASeriesAndUsesGuideWindow() throws {
        let device = HDHRDevice.test(id: "DEV1", tuners: 2)
        let channel = LineupEntry.test(number: "5.1", name: "KFOO")
        let entry = GuideEntry.test(title: "One-off Special", start: 1_800_000_000, end: 1_800_003_600)
        let state = makeTestAppState(devices: [device], lineups: ["DEV1": [channel]])

        state.quickRecord(type: .single, entry: entry, device: device, channel: channel)

        let show = try #require(state.shows.first)
        #expect(show.show_is_series == false)
        #expect(show.show_use_seriesid == false)
        #expect(show.show_use_seriesid_all == false)
        #expect(show.show_next == entry.startDate)
        #expect(show.show_end == entry.endDate)
    }

    @Test @MainActor func dateTimeType_isASeriesWithNoSeriesID() throws {
        let device = HDHRDevice.test(id: "DEV1", tuners: 2)
        let channel = LineupEntry.test(number: "5.1", name: "KFOO")
        let entry = GuideEntry.test(title: "Weeknight News")
        let state = makeTestAppState(devices: [device], lineups: ["DEV1": [channel]])

        state.quickRecord(type: .dateTime, entry: entry, device: device, channel: channel)

        let show = try #require(state.shows.first)
        #expect(show.show_is_series == true)
        #expect(show.show_use_seriesid == false)
        #expect(show.show_air_date.isEmpty == false)   // defaults to the entry's own weekday
    }

    @Test @MainActor func seriesChannelType_isPinnedToOneChannel() throws {
        let device = HDHRDevice.test(id: "DEV1", tuners: 2)
        let channel = LineupEntry.test(number: "5.1", name: "KFOO")
        let entry = GuideEntry.test(title: "Nightly Drama")
        let state = makeTestAppState(devices: [device], lineups: ["DEV1": [channel]])

        state.quickRecord(type: .seriesChannel, entry: entry, device: device, channel: channel)

        let show = try #require(state.shows.first)
        #expect(show.show_is_series == true)
        #expect(show.show_use_seriesid == true)
        #expect(show.show_use_seriesid_all == false)
        // No matching guide index in this test's empty GuideStore, so resolveSeriesAir finds no
        // candidate and leaves the entry's own channel/device in place — asserting that fallback
        // holds is itself useful coverage, not just an artifact of the test setup.
        #expect(show.show_channel == "5.1")
        #expect(show.hdhr_record == "DEV1")
    }

    @Test @MainActor func seriesAllType_followsAnyChannelOnTheSameDevice() throws {
        let device = HDHRDevice.test(id: "DEV1", tuners: 2)
        let channel = LineupEntry.test(number: "5.1", name: "KFOO")
        let entry = GuideEntry.test(title: "Syndicated Rerun")
        let state = makeTestAppState(devices: [device], lineups: ["DEV1": [channel]])

        state.quickRecord(type: .seriesAll, entry: entry, device: device, channel: channel)

        let show = try #require(state.shows.first)
        #expect(show.show_is_series == true)
        #expect(show.show_use_seriesid == true)
        #expect(show.show_use_seriesid_all == true)
        #expect(show.hdhr_record == "DEV1")
    }

    @Test @MainActor func addShowFromGuide_returnsTheCreatedShowsId() throws {
        let device = HDHRDevice.test(id: "DEV1", tuners: 2)
        let channel = LineupEntry.test(number: "5.1", name: "KFOO")
        let entry = GuideEntry.test(title: "Evening News")
        let state = makeTestAppState(devices: [device], lineups: ["DEV1": [channel]])

        let returnedId = state.addShowFromGuide(entry: entry, type: .single, device: device, channel: channel)

        let show = try #require(state.shows.first)
        #expect(returnedId == show.show_id)
    }
}

// MARK: - AppState.tunerBlockedOnlyByOwnWatchNow(for:)
//
// Backs the "Watch Now should yield its tuner to a new recording request" feature (TODO.md) —
// offers a confirm dialog instead of a hard "All Tuners Busy" block when the only thing occupying
// the last tuner is this instance's own live Watch Now stream. Like vlcOccupiesTuner itself (see
// TunerOccupancyTests.swift's own file-header note), the "true" branch can't be exercised here:
// VLCPlayerWindowManager.shared.currentDeviceID is a real singleton only ever set by actually
// opening a player window, which these tests never do — it stays nil, so vlcOccupiesTuner (and
// therefore this function) can only be verified false in this environment. These tests cover the
// two guard clauses that don't depend on it: "tuners aren't even full" and "full, but for a real
// reason" — both must stay false regardless of whatever vlcOccupiesTuner would ever say.
@Suite("AppState.tunerBlockedOnlyByOwnWatchNow")
struct TunerBlockedOnlyByOwnWatchNowTests {

    @Test @MainActor func falseWhenTunersAreNotFull() {
        let device = HDHRDevice.test(id: "DEV1", tuners: 2)
        let state = makeTestAppState(devices: [device])
        #expect(state.tunerBlockedOnlyByOwnWatchNow(for: "DEV1") == false)
    }

    @Test @MainActor func falseWhenFullDueToARealRecording_notVLC() {
        let device = HDHRDevice.test(id: "DEV1", tuners: 1)
        var recording = Show.testRecording(title: "Already Recording", channel: "9.9")
        recording.hdhr_record = "DEV1"
        let state = makeTestAppState(shows: [recording], devices: [device])
        // tunersFull(for:) is true here (1 recording, 1 tuner) but vlcOccupiesTuner is false (no
        // live VLC session in this test environment) — never offer to drop a real recording.
        #expect(state.tunerBlockedOnlyByOwnWatchNow(for: "DEV1") == false)
    }

    @Test @MainActor func falseForAnUnknownDevice() {
        let state = makeTestAppState()
        #expect(state.tunerBlockedOnlyByOwnWatchNow(for: "NOPE") == false)
    }
}
