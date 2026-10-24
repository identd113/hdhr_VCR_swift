import Testing
import Foundation
@testable import hdhr_VCR

// MARK: - Guide window
//
// GuideHours is no longer a setting (2026-10-24): the app always asks for the most the cloud guide.php API gives in one call (28 h; it
// silently truncates beyond ~29 h and guideURL adds +1, docs/GuideStore.md). A value in an old saved config — 48, 0, anything — is ignored,
// so it can neither truncate the fetch nor zero out the web guide's winSec.

@Suite("AppConfig GuideHours is fixed")
struct AppConfigGuideHoursClampTests {

    @Test(arguments: [#"{"GuideHours": 48}"#, #"{"GuideHours": 0}"#, #"{"GuideHours": -5}"#, "{}", #"{"GuideHours": 12}"#, #"{"GuideHours": 28}"#])
    func alwaysTwentyEight(_ json: String) throws {
        let cfg = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(cfg.GuideHours == 28)
    }
}

@Suite("AppConfig failure/retry decode clamps")
struct AppConfigRetryClampTests {
    @Test(arguments: [(#"{"Fail_count_setting": 0}"#, 1), (#"{"Fail_count_setting": -3}"#, 1),
                      ("{}", 3), (#"{"Fail_count_setting": 5}"#, 5)])
    func failCountAtLeastOne(_ row: (String, Int)) throws {
        let cfg = try JSONDecoder().decode(AppConfig.self, from: Data(row.0.utf8))
        #expect(cfg.Fail_count_setting == row.1)
    }
}
