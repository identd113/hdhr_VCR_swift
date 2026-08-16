import Testing
import Foundation
@testable import hdhr_VCR

// MARK: - AppConfig decode-time clamps
//
// GuideHours is clamped to 1...28 on decode (Models.swift) because the cloud guide.php API
// silently truncates single-call requests beyond ~29h, and guideURL adds +1 to the requested
// hours (docs/GuideStore.md) — an old saved config with 48 slipping through would silently
// fetch a truncated guide with no error signal, and 0/negative would zero out the web guide's
// winSec (division context in guide rendering). The Settings stepper already enforces 1...28
// in the UI; this decode clamp is the only guard for values written by older builds or by
// hand-editing the JSON, so it gets pinned here.

@Suite("AppConfig GuideHours decode clamp")
struct AppConfigGuideHoursClampTests {

    @Test(arguments: [
        // Pre-clamp builds allowed up to 48 in the UI — those configs still exist on disk.
        (json: #"{"GuideHours": 48}"#, expected: 28),
        (json: #"{"GuideHours": 0}"#,  expected: 1),
        (json: #"{"GuideHours": -5}"#, expected: 1),
        // Absent key falls back to the default, not a clamp boundary.
        (json: "{}",                   expected: 24),
        // In-range values (including both boundaries) pass through untouched.
        (json: #"{"GuideHours": 12}"#, expected: 12),
        (json: #"{"GuideHours": 1}"#,  expected: 1),
        (json: #"{"GuideHours": 28}"#, expected: 28),
    ])
    func decodeClampsTo1Through28(_ row: (json: String, expected: Int)) throws {
        let cfg = try JSONDecoder().decode(AppConfig.self, from: Data(row.json.utf8))
        #expect(cfg.GuideHours == row.expected)
    }
}
