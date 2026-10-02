import Testing
import Foundation
@testable import hdhr_VCR

// 2026-10-01 review finding #4 — EditShowView saves via Show.applyingEdits so a stale form copy
// can't overwrite runtime fields that changed after the form loaded.
@Suite("Show.applyingEdits — merge only form-edited fields onto the live show")
struct ShowApplyingEditsTests {
    @Test func staleFormCopy_keepsLiveRuntimeFields_appliesOnlyEdits() {
        var original = Show.blank(channel: "11.1", device: "105404BE")
        original.show_title = "MLB Baseball"
        original.show_end = Date(timeIntervalSince1970: 1_000)

        // Since the form loaded, the show started recording with a Bonus-Time-extended end.
        var live = original
        live.show_recording = true
        live.show_recording_path = "/tmp/MLB.ts"
        live.show_end = Date(timeIntervalSince1970: 9_000)
        live.discord_start_msg_id = "123"

        var edited = original
        edited.show_title = "MLB Baseball (Playoffs)"
        edited.show_bonus_time = true

        let merged = live.applyingEdits(from: original, to: edited)
        #expect(merged.show_title == "MLB Baseball (Playoffs)")
        #expect(merged.show_bonus_time == true)
        #expect(merged.show_recording == true)
        #expect(merged.show_recording_path == "/tmp/MLB.ts")
        #expect(merged.show_end == Date(timeIntervalSince1970: 9_000))
        #expect(merged.discord_start_msg_id == "123")
        #expect(merged.show_id == live.show_id)
    }

    @Test func noEdits_returnsLiveUnchanged() {
        var live = Show.blank(channel: "5.1", device: "X")
        live.show_recording = true
        var stale = live
        stale.show_recording = false
        #expect(live.applyingEdits(from: stale, to: stale) == live)
    }
}
