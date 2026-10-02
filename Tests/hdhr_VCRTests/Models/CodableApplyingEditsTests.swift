import Testing
import Foundation
@testable import hdhr_VCR

// 2026-10-01 review #22 — SettingsView saves via codableApplyingEdits so a field changed elsewhere
// while Settings had unsaved edits (e.g. the donation unlock) isn't reverted.
@Suite("codableApplyingEdits — AppConfig merge for Settings save")
struct CodableApplyingEditsTests {
    @Test func settingsSave_keepsConcurrentChange_appliesEdit() throws {
        let baseline = AppConfig()
        var live = baseline
        live.Donation_unlocked = true          // unlocked from the nag window meanwhile
        var draft = baseline
        draft.GuideHours = baseline.GuideHours == 12 ? 14 : 12   // the user's actual edit
        let merged = try #require(codableApplyingEdits(live: live, original: baseline, edited: draft))
        #expect(merged.Donation_unlocked == true)
        #expect(merged.GuideHours == draft.GuideHours)
    }

    // The merge round-trips through Codable — every field must survive encode/decode unchanged,
    // or merging would silently reset it.
    @Test func appConfig_roundTripsThroughMergeUnchanged() throws {
        var cfg = AppConfig()
        cfg.Donation_unlocked = true
        cfg.Appearance_mode = "dark"
        cfg.Default_transcode = "heavy"
        let merged = try #require(codableApplyingEdits(live: cfg, original: cfg, edited: cfg))
        #expect(merged == cfg)
    }
}
