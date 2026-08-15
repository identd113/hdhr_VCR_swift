import Testing
import Foundation
@testable import hdhr_VCR

// MARK: - Tuner occupancy & conflict detection
//
// Covers AppState.activeTunerCount/tunersFull/hasConflict/conflictingShows — the logic behind
// CLAUDE.md's #1 invariant ("Tuner occupancy"): never count recordings alone, and always take
// max(hardware-polled count, local recordings + VLC). A regression here either double-books a
// tuner (recording fails) or blocks a legitimate recording that should have a free slot.
//
// Also covers activeRecordingChannels/pendingRecordingChannels — a different cut of the same
// occupancy data (channel-scoped, not count-scoped): "which channels on this device currently
// read as recording," shared by WebServer.swift's guide grid and WatchNowView's Watch Now window
// so the two rendering surfaces can't drift apart on the definition (see either function's own
// doc comment in AppState.swift for why this has to be channel-scoped rather than derived from a
// show's own show_recording flag).
//
// vlcOccupiesTuner(for:) reads VLCPlayerWindowManager.shared.currentDeviceID, a real singleton
// with a private(set) setter only touched by actually opening a player window — these tests never
// do that, so it stays nil and vlcOccupiesTuner is always false here. That's an intentional scope
// boundary: the hw/recordingShows branches below are where the actual business-logic risk lives;
// the VLC branch is a single `? 1 : 0` with nothing to get subtly wrong.

@Suite("AppState tuner occupancy")
struct TunerOccupancyTests {

    // MARK: activeTunerCount

    @Test func activeTunerCount_noData_isZero() async {
        let state = await makeTestAppState(devices: [.test(id: "DEV1", tuners: 2)])
        #expect(await state.activeTunerCount(for: "DEV1") == 0)
    }

    @Test func activeTunerCount_hardwareOnly() async {
        // Zero local recordings — max(hw, 0) must still honor a tuner locked by another
        // machine/app against the same physical device, not just this instance's own recordings.
        // Idle slot (VctNumber == nil) proves the hw count filters those out too.
        let state = await makeTestAppState(devices: [.test(id: "DEV1", tuners: 4)])
        await MainActor.run {
            state.deviceTunerOccupancy["DEV1"] = [
                DeviceTunerInfo(Resource: "tuner0", VctNumber: "5.1", TargetIP: nil, SignalQualityPercent: nil),
                DeviceTunerInfo(Resource: "tuner1", VctNumber: "7.1", TargetIP: nil, SignalQualityPercent: nil),
                DeviceTunerInfo(Resource: "tuner2", VctNumber: nil,   TargetIP: nil, SignalQualityPercent: nil), // idle slot
            ]
        }
        #expect(await state.activeTunerCount(for: "DEV1") == 2)
    }

    @Test func activeTunerCount_localRecordingsOnly_noHardwarePollYet() async {
        // Just-started recording: status.json hasn't caught up yet, so deviceTunerOccupancy is
        // empty/stale, but the local recordingShows array already knows about it.
        var show = Show.testRecording(title: "Live Now", channel: "5.1")
        show.hdhr_record = "DEV1"
        let state = await makeTestAppState(shows: [show], devices: [.test(id: "DEV1", tuners: 2)])
        #expect(await state.activeTunerCount(for: "DEV1") == 1)
    }

    @Test func activeTunerCount_takesMax_hardwareUndercounts() async {
        // Hardware poll only sees 1 locked tuner (stale ~1.5s window) but this instance has 2
        // local recordings — max() must not silently drop to the smaller hardware count.
        var s1 = Show.testRecording(title: "Show A", channel: "5.1"); s1.hdhr_record = "DEV1"
        var s2 = Show.testRecording(title: "Show B", channel: "7.1"); s2.hdhr_record = "DEV1"
        let state = await makeTestAppState(shows: [s1, s2], devices: [.test(id: "DEV1", tuners: 4)])
        await MainActor.run {
            state.deviceTunerOccupancy["DEV1"] = [
                DeviceTunerInfo(Resource: "tuner0", VctNumber: "5.1", TargetIP: nil, SignalQualityPercent: nil)
            ]
        }
        #expect(await state.activeTunerCount(for: "DEV1") == 2)
    }

    @Test func activeTunerCount_ignoresOtherDevicesRecordings() async {
        var show = Show.testRecording(title: "Other Device", channel: "5.1"); show.hdhr_record = "DEV2"
        let state = await makeTestAppState(shows: [show], devices: [.test(id: "DEV1", tuners: 2), .test(id: "DEV2", tuners: 2)])
        #expect(await state.activeTunerCount(for: "DEV1") == 0)
        #expect(await state.activeTunerCount(for: "DEV2") == 1)
    }

    @Test func activeTunerCount_excludesRecordingPastItsEndTime() async {
        // recordingShows filters on show_end > Date() — a show still flagged show_recording=true
        // but whose show_end already passed (stop hasn't landed yet) shouldn't inflate the count.
        var show = Show.testRecording(title: "Stale Flag", channel: "5.1")
        show.hdhr_record = "DEV1"
        show.show_end = Date().addingTimeInterval(-60)
        let state = await makeTestAppState(shows: [show], devices: [.test(id: "DEV1", tuners: 2)])
        #expect(await state.activeTunerCount(for: "DEV1") == 0)
    }

    // MARK: tunersFull

    @Test func tunersFull_unknownDevice_isFalse() async {
        let state = await makeTestAppState(devices: [.test(id: "DEV1", tuners: 2)])
        #expect(await state.tunersFull(for: "NOPE") == false)
    }

    @Test func tunersFull_zeroTunerCount_isFalse() async {
        let state = await makeTestAppState(devices: [.test(id: "DEV1", tuners: 0)])
        #expect(await state.tunersFull(for: "DEV1") == false)
    }

    @Test func tunersFull_belowCapacity_isFalse() async {
        var show = Show.testRecording(channel: "5.1"); show.hdhr_record = "DEV1"
        let state = await makeTestAppState(shows: [show], devices: [.test(id: "DEV1", tuners: 2)])
        #expect(await state.tunersFull(for: "DEV1") == false)
    }

    @Test func tunersFull_atCapacity_isTrue() async {
        var s1 = Show.testRecording(title: "A", channel: "5.1"); s1.hdhr_record = "DEV1"
        var s2 = Show.testRecording(title: "B", channel: "7.1"); s2.hdhr_record = "DEV1"
        let state = await makeTestAppState(shows: [s1, s2], devices: [.test(id: "DEV1", tuners: 2)])
        #expect(await state.tunersFull(for: "DEV1") == true)
    }

    // MARK: activeRecordingChannels

    @Test func activeRecordingChannels_returnsChannelsOfActiveRecordings() async {
        var show = Show.testRecording(title: "Live Now", channel: "5.1")
        show.hdhr_record = "DEV1"
        let state = await makeTestAppState(shows: [show], devices: [.test(id: "DEV1", tuners: 2)])
        #expect(await state.activeRecordingChannels(for: "DEV1") == ["5.1"])
    }

    @Test func activeRecordingChannels_noRecordings_isEmpty() async {
        let state = await makeTestAppState(devices: [.test(id: "DEV1", tuners: 2)])
        #expect(await state.activeRecordingChannels(for: "DEV1").isEmpty)
    }

    @Test func activeRecordingChannels_ignoresOtherDevices() async {
        var show = Show.testRecording(title: "Other Device", channel: "5.1"); show.hdhr_record = "DEV2"
        let state = await makeTestAppState(shows: [show], devices: [.test(id: "DEV1", tuners: 2), .test(id: "DEV2", tuners: 2)])
        #expect(await state.activeRecordingChannels(for: "DEV1").isEmpty)
        #expect(await state.activeRecordingChannels(for: "DEV2") == ["5.1"])
    }

    // MARK: pendingRecordingChannels
    //
    // The gap between a managed show's recording window opening (show_next <= now) and
    // show_recording actually flipping true — startup lag, or a missed-start retry backoff (see
    // ISSUES.md's open entry on this: a stuck retry keeps a channel reading as "recording" for
    // the whole backoff window, a known, not-yet-fixed tradeoff of this function's definition).

    @Test func pendingRecordingChannels_windowOpenNotYetRecording_isIncluded() async {
        var show = Show.testActive(title: "About To Start", channel: "5.1")
        show.hdhr_record = "DEV1"
        show.show_next = Date().addingTimeInterval(-30)   // window opened 30s ago
        show.show_end  = Date().addingTimeInterval(1770)
        let state = await makeTestAppState(shows: [show], devices: [.test(id: "DEV1", tuners: 2)])
        #expect(await state.pendingRecordingChannels(for: "DEV1") == ["5.1"])
    }

    @Test func pendingRecordingChannels_alreadyRecording_isExcluded() async {
        // show_recording == true shows up via activeRecordingChannels instead —
        // pendingRecordingChannels is specifically the gap before that flag flips, not a second
        // route to the same channel.
        var show = Show.testRecording(title: "Already Going", channel: "5.1")
        show.hdhr_record = "DEV1"
        let state = await makeTestAppState(shows: [show], devices: [.test(id: "DEV1", tuners: 2)])
        #expect(await state.pendingRecordingChannels(for: "DEV1").isEmpty)
    }

    @Test func pendingRecordingChannels_windowNotYetOpen_isExcluded() async {
        // testActive's default show_next is 1 hour in the future.
        var show = Show.testActive(title: "Later Today", channel: "5.1")
        show.hdhr_record = "DEV1"
        let state = await makeTestAppState(shows: [show], devices: [.test(id: "DEV1", tuners: 2)])
        #expect(await state.pendingRecordingChannels(for: "DEV1").isEmpty)
    }

    @Test func pendingRecordingChannels_windowAlreadyEnded_isExcluded() async {
        var show = Show.testActive(title: "Missed It", channel: "5.1")
        show.hdhr_record = "DEV1"
        show.show_next = Date().addingTimeInterval(-3600)
        show.show_end  = Date().addingTimeInterval(-60)
        let state = await makeTestAppState(shows: [show], devices: [.test(id: "DEV1", tuners: 2)])
        #expect(await state.pendingRecordingChannels(for: "DEV1").isEmpty)
    }

    @Test func pendingRecordingChannels_paused_isExcluded() async {
        var show = Show.testActive(title: "Paused Show", channel: "5.1")
        show.hdhr_record = "DEV1"
        show.show_next = Date().addingTimeInterval(-30)
        show.show_end  = Date().addingTimeInterval(1770)
        show.show_paused = true
        let state = await makeTestAppState(shows: [show], devices: [.test(id: "DEV1", tuners: 2)])
        #expect(await state.pendingRecordingChannels(for: "DEV1").isEmpty)
    }

    @Test func pendingRecordingChannels_ignoresOtherDevices() async {
        var show = Show.testActive(title: "Other Device", channel: "5.1")
        show.hdhr_record = "DEV2"
        show.show_next = Date().addingTimeInterval(-30)
        show.show_end  = Date().addingTimeInterval(1770)
        let state = await makeTestAppState(shows: [show], devices: [.test(id: "DEV1", tuners: 2), .test(id: "DEV2", tuners: 2)])
        #expect(await state.pendingRecordingChannels(for: "DEV1").isEmpty)
        #expect(await state.pendingRecordingChannels(for: "DEV2") == ["5.1"])
    }

    // MARK: hasConflict / conflictingShows

    private func overlappingShow(title: String, channel: String, device: String, offsetMinutes: Double = 0) -> Show {
        var s = Show.blank(channel: channel, device: device)
        s.show_title = title
        s.show_active = true
        s.show_next = Date().addingTimeInterval(offsetMinutes * 60)
        s.show_end  = s.show_next!.addingTimeInterval(3600)
        return s
    }

    @Test func hasConflict_noOverlap_isFalse() async {
        let a = overlappingShow(title: "A", channel: "5.1", device: "DEV1", offsetMinutes: 0)
        var b = overlappingShow(title: "B", channel: "7.1", device: "DEV1", offsetMinutes: 0)
        b.show_next = a.show_end!.addingTimeInterval(60)   // starts after A ends — no overlap
        b.show_end  = b.show_next!.addingTimeInterval(3600)
        let state = await makeTestAppState(shows: [a, b], devices: [.test(id: "DEV1", tuners: 1)])
        #expect(await state.hasConflict(for: a) == false)
    }

    @Test func hasConflict_overlapBelowTunerCount_isFalse() async {
        let a = overlappingShow(title: "A", channel: "5.1", device: "DEV1")
        let b = overlappingShow(title: "B", channel: "7.1", device: "DEV1")
        // 2 overlapping shows, 3 tuners — plenty of room.
        let state = await makeTestAppState(shows: [a, b], devices: [.test(id: "DEV1", tuners: 3)])
        #expect(await state.hasConflict(for: a) == false)
    }

    @Test func hasConflict_overlapAtTunerCapacity_isTrue() async {
        // `overlapping` excludes `a` itself, so a 2-tuner device needs 2 *other* competitors
        // (3 shows total, including a) before the >= boundary trips — 1 other competitor merely
        // fills both tuners without contention (see overlapBelowTunerCount_isFalse below).
        let a = overlappingShow(title: "A", channel: "5.1", device: "DEV1")
        let b = overlappingShow(title: "B", channel: "7.1", device: "DEV1")
        let c = overlappingShow(title: "C", channel: "9.1", device: "DEV1")
        let state = await makeTestAppState(shows: [a, b, c], devices: [.test(id: "DEV1", tuners: 2)])
        #expect(await state.hasConflict(for: a) == true)
    }

    @Test func hasConflict_pausedCompetitor_excluded() async {
        let a = overlappingShow(title: "A", channel: "5.1", device: "DEV1")
        var b = overlappingShow(title: "B", channel: "7.1", device: "DEV1")
        b.show_paused = true
        let state = await makeTestAppState(shows: [a, b], devices: [.test(id: "DEV1", tuners: 2)])
        #expect(await state.hasConflict(for: a) == false)
    }

    @Test func hasConflict_inactiveCompetitor_excluded() async {
        let a = overlappingShow(title: "A", channel: "5.1", device: "DEV1")
        var b = overlappingShow(title: "B", channel: "7.1", device: "DEV1")
        b.show_active = false
        let state = await makeTestAppState(shows: [a, b], devices: [.test(id: "DEV1", tuners: 2)])
        #expect(await state.hasConflict(for: a) == false)
    }

    @Test func hasConflict_differentDeviceCompetitor_excluded() async {
        let a = overlappingShow(title: "A", channel: "5.1", device: "DEV1")
        let b = overlappingShow(title: "B", channel: "5.1", device: "DEV2")
        let state = await makeTestAppState(shows: [a, b], devices: [.test(id: "DEV1", tuners: 1), .test(id: "DEV2", tuners: 1)])
        #expect(await state.hasConflict(for: a) == false)
    }

    @Test func conflictingShows_returnsOthersSortedByChannel() async {
        let a = overlappingShow(title: "A", channel: "5.1", device: "DEV1")
        let b = overlappingShow(title: "B", channel: "9.1", device: "DEV1")
        let c = overlappingShow(title: "C", channel: "3.1", device: "DEV1")
        let state = await makeTestAppState(shows: [a, b, c], devices: [.test(id: "DEV1", tuners: 4)])
        let others = await state.conflictingShows(for: a)
        #expect(others.map(\.show_title) == ["C", "B"])   // sorted by channel: 3.1 before 9.1
    }

    @Test func conflictingShows_excludesSelf() async {
        let a = overlappingShow(title: "A", channel: "5.1", device: "DEV1")
        let state = await makeTestAppState(shows: [a], devices: [.test(id: "DEV1", tuners: 1)])
        #expect(await state.conflictingShows(for: a).isEmpty)
    }
}
