import Testing
import Foundation
@testable import hdhr_VCR

// 2.6.5 review: "Watch from Beginning" anchored a show's scrub axis on the EARLIEST launch time among all running
// recordings, while the server joined at that show's own file start — with two recordings the later show's scrub axis
// was offset by the gap. Each lineup entry now carries its own file start, from the same clock as the byte offset.
@Suite("Per-show recording file start (lineup + FEED join)")
struct RecordingFileStartTests {

    private func tempRecording(createdAt: Date) throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("rfs-\(UUID().uuidString).ts").path
        FileManager.default.createFile(atPath: path, contents: Data(repeating: 0x47, count: 188))
        try FileManager.default.setAttributes([.creationDate: createdAt], ofItemAtPath: path)
        return path
    }

    @MainActor
    @Test func eachLineupEntryCarriesItsOwnFileStart_notTheEarliestOfAll() throws {
        let early = Date(timeIntervalSince1970: 1_800_000_000)
        let late  = early.addingTimeInterval(95)        // second recording started 95 s later
        var a = Show.testRecording(title: "Early Show", channel: "5.1"); a.hdhr_record = "AAAAAAAA"
        var b = Show.testRecording(title: "Late Show",  channel: "7.1"); b.hdhr_record = "AAAAAAAA"
        a.show_recording_path = try tempRecording(createdAt: early)
        b.show_recording_path = try tempRecording(createdAt: late)
        defer { [a, b].forEach { try? FileManager.default.removeItem(atPath: $0.show_recording_path) } }
        let state = makeTestAppState(shows: [a, b], devices: [.test(id: "AAAAAAAA")])

        let entries = WebServer().buildVirtualTunerLineupJSON(state: state)
        let startA = try #require(entries.first { $0["GuideNumber"] as? String == "5.1" }?[VirtualTunerService.fileStartedAtKey] as? Double)
        let startB = try #require(entries.first { $0["GuideNumber"] as? String == "7.1" }?[VirtualTunerService.fileStartedAtKey] as? Double)
        #expect(abs(startA - early.timeIntervalSince1970) < 1)
        #expect(abs(startB - late.timeIntervalSince1970) < 1, "the later show must not inherit the earlier show's start")
    }

    @Test func recordingFileStart_usesTheFileCreationDate_elseTheFallback() throws {
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let path = try tempRecording(createdAt: created)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let scheduled = created.addingTimeInterval(-600)
        #expect(WebServer.recordingFileStart(path: path, fallback: scheduled) == created)
        #expect(WebServer.recordingFileStart(path: "/nonexistent/\(UUID().uuidString).ts", fallback: scheduled) == scheduled)
        #expect(WebServer.recordingFileStart(path: "", fallback: nil) == nil)
    }

    @MainActor
    @Test func entryOmitsTheStartWhenNeitherTheFileNorASchedule_isKnown() {
        var s = Show.testRecording(title: "No Clock", channel: "5.1"); s.hdhr_record = "AAAAAAAA"
        s.show_recording_path = "/nonexistent/\(UUID().uuidString).ts"
        s.show_next = nil
        let state = makeTestAppState(shows: [s], devices: [.test(id: "AAAAAAAA")])
        let entry = WebServer().buildVirtualTunerLineupJSON(state: state).first
        #expect(entry?[VirtualTunerService.fileStartedAtKey] == nil)
    }

    @Test func lineupEntryDecodesThePerShowStart() throws {
        let json = #"{"GuideNumber":"5.1","GuideName":"KFOO","HdhrVCRplusFileStartedAt":1800000095.5}"#
        let e = try JSONDecoder().decode(LineupEntry.self, from: Data(json.utf8))
        #expect(e.virtualRelayFileStartedAt == 1_800_000_095.5)
        let old = try JSONDecoder().decode(LineupEntry.self, from: Data(#"{"GuideNumber":"5.1","GuideName":"KFOO"}"#.utf8))
        #expect(old.virtualRelayFileStartedAt == nil, "an older relay build publishes no per-show start")
    }
}

// 2.6.5 review: a picker bound to a tuner id that is no longer in its list shows nothing selected.
@Suite("pickerDeviceId")
struct PickerDeviceIdTests {
    @Test func prefersTheRequestedDeviceWhileItIsAvailable() {
        #expect(pickerDeviceId(preferred: "B", current: "A", available: ["A", "B"]) == "B")
    }
    @Test func fallsBackToTheCurrentOne_thenTheFirstAvailable() {
        #expect(pickerDeviceId(preferred: "GONE", current: "A", available: ["A", "B"]) == "A")
        #expect(pickerDeviceId(preferred: "GONE", current: "ALSOGONE", available: ["A", "B"]) == "A")
        #expect(pickerDeviceId(available: ["A"]) == "A")
    }
    @Test func emptyWhenNothingIsAvailable() {
        #expect(pickerDeviceId(preferred: "A", current: "A", available: []) == "")
    }
    @Test func aTunerThatDropsOutMovesTheSelection() {
        #expect(pickerDeviceId(current: "B", available: ["A"]) == "A")
    }
}
