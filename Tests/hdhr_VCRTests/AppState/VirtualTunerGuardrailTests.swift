import Testing
import Foundation
@testable import hdhr_VCR

// Guardrail regression tests for the "Rebroadcast an in-progress recording" virtual-tuner feature:
// (1) this instance must never discover its own virtual tuner, and (2) any relay device — this
// instance's own or another instance's — must never be schedulable as a recording target. See
// docs/VirtualTunerService.md and the approved plan's Guardrails section.
@Suite("Virtual tuner guardrails")
struct VirtualTunerGuardrailTests {

    // MARK: - Self-exclusion (excludingOwnVirtualTuner)

    @Test func excludingOwnVirtualTuner_dropsDeviceMatchingOwnActiveID() async {
        let state = await makeTestAppState()
        await MainActor.run { state.activeVirtualTunerDeviceID = "FEEDABCD" }
        let discovered = [HDHRDevice.test(id: "FEEDABCD"), HDHRDevice.test(id: "1010ABCD")]
        let filtered = await MainActor.run { state.excludingOwnVirtualTuner(discovered) }
        #expect(filtered.map { $0.DeviceID } == ["1010ABCD"])
    }

    @Test func excludingOwnVirtualTuner_keepsAnotherInstancesRelay() async {
        let state = await makeTestAppState()
        // Own relay not currently active (activeVirtualTunerDeviceID is nil) — a different
        // instance's relay, discovered normally, must pass through untouched.
        let remoteRelay = HDHRDevice.test(id: "FEED9999", isVirtualRelay: true)
        let filtered = await MainActor.run { state.excludingOwnVirtualTuner([remoteRelay]) }
        #expect(filtered.map { $0.DeviceID } == ["FEED9999"])
    }

    @Test func excludingOwnVirtualTuner_noopWhenNotRecording() async {
        let state = await makeTestAppState()
        // activeVirtualTunerDeviceID defaults to nil (not recording) — nothing should be dropped.
        let discovered = [HDHRDevice.test(id: "FFFFFFFF"), HDHRDevice.test(id: "1010ABCD")]
        let filtered = await MainActor.run { state.excludingOwnVirtualTuner(discovered) }
        #expect(filtered.count == 2)
    }

    // MARK: - Recording refusal (addShow / updateShow)

    @Test func addShow_refusesShowTargetingAVirtualRelayDevice() async {
        let relay = HDHRDevice.test(id: "FEED1111", isVirtualRelay: true)
        let state = await makeTestAppState(devices: [relay])
        var show = Show.testActive(title: "Should Not Record")
        show.hdhr_record = "FEED1111"
        await state.addShow(show)
        let shows = await MainActor.run { state.shows }
        #expect(shows.isEmpty)
    }

    @Test func addShow_allowsShowTargetingANormalDevice() async {
        let real = HDHRDevice.test(id: "FFFFFFFF", isVirtualRelay: false)
        let state = await makeTestAppState(devices: [real])
        var show = Show.testActive(title: "Fine To Record")
        show.hdhr_record = "FFFFFFFF"
        await state.addShow(show)
        let shows = await MainActor.run { state.shows }
        #expect(shows.map { $0.show_title } == ["Fine To Record"])
    }

    @Test func updateShow_refusesEditThatRetargetsToAVirtualRelayDevice() async {
        let relay = HDHRDevice.test(id: "FEED2222", isVirtualRelay: true)
        var original = Show.testActive(title: "Series Show")
        original.hdhr_record = "FFFFFFFF"
        let state = await makeTestAppState(shows: [original], devices: [relay, HDHRDevice.test(id: "FFFFFFFF")])
        var edited = original
        edited.hdhr_record = "FEED2222"   // e.g. a seriesChannel reassignment gone wrong
        await state.updateShow(edited)
        let stored = await MainActor.run { state.shows.first }
        #expect(stored?.hdhr_record == "FFFFFFFF")   // unchanged — edit was refused
    }

    // MARK: - Settings toggle (Virtual_tuner_relay_enabled) gates the relay

    @Test func updateVirtualTunerPresence_disabledSetting_neverStartsTheRelayEvenWhileRecording() async {
        // Deliberately does not exercise the "enabled" branch here — that path calls through to a
        // real VirtualTunerService.start(), a live UDP bind, which this test file's own
        // conventions (see VirtualTunerServiceTests.swift) keep out of the unit-test suite.
        let show = Show.testRecording(title: "Live Now")
        let state = await makeTestAppState(shows: [show])
        await MainActor.run { state.config.Virtual_tuner_relay_enabled = false }
        await state.updateVirtualTunerPresence()
        let id = await MainActor.run { state.activeVirtualTunerDeviceID }
        #expect(id == nil)
    }

    // MARK: - vlcOccupiesTuner never counts a virtual relay

    @Test func vlcOccupiesTuner_falseForAVirtualRelayDevice() async {
        // No live VLC session exists in this test environment (VLCBridge.shared.isAvailable is
        // false without the real dlopen'd framework), so VLCPlayerWindowManager.currentDeviceID
        // can never be made to equal the relay's DeviceID here — this only exercises the guard's
        // short-circuit itself, not the "would otherwise read as occupied" case it exists to
        // prevent (see AppState.vlcOccupiesTuner's own doc comment for that reasoning).
        let relay = HDHRDevice.test(id: "FEED4444", isVirtualRelay: true)
        let state = await makeTestAppState(devices: [relay])
        #expect(await state.vlcOccupiesTuner(for: "FEED4444") == false)
    }

    // MARK: - Relay raw viewer count

    @Test func relayRawViewerCount_connectAndDisconnectTrackCorrectly() async {
        // Exercises the counter itself, not WebServer.handleVirtualTunerStream's live-NWConnection
        // call sites (kept out of the unit-test suite for the same reason as the "enabled" branch
        // above) — connected()/disconnected() are the whole surface those call sites actually touch.
        let state = await makeTestAppState()
        #expect(await state.relayRawViewerCount == 0)
        await MainActor.run { state.relayRawViewerConnected() }
        await MainActor.run { state.relayRawViewerConnected() }
        #expect(await state.relayRawViewerCount == 2)
        await MainActor.run { state.relayRawViewerDisconnected() }
        #expect(await state.relayRawViewerCount == 1)
    }

    @Test func relayRawViewerCount_disconnectNeverGoesNegative() async {
        // A stray extra disconnect (e.g. both a real send-error path and a timeout racing to fire
        // for the same connection, however unlikely given sendWithTimeout's own single-fire guard)
        // must clamp at 0, not underflow into a negative count that would then need two connects to
        // recover from.
        let state = await makeTestAppState()
        await MainActor.run { state.relayRawViewerDisconnected() }
        #expect(await state.relayRawViewerCount == 0)
    }
}
