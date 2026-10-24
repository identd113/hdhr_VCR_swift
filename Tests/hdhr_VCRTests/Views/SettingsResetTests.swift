import Foundation
import Testing
@testable import hdhr_VCR

// "Reset This Tab to Defaults": the keys listed per tab must be real AppConfig fields, or resetting silently skips them.
struct SettingsResetTests {
    private func keys(of config: AppConfig) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
    }

    @Test func everyResetKeyIsARealConfigField() throws {
        let fields = try keys(of: AppConfig())
        for tab in SettingsCategory.allCases {
            for key in SettingsView.resetKeys(for: tab) ?? [] { #expect(fields[key] != nil, "\(tab.rawValue): '\(key)' is not an AppConfig field") }
        }
    }

    @Test func noFieldIsListedOnTwoTabs() {
        var seen = Set<String>()
        for tab in SettingsCategory.allCases {
            for key in SettingsView.resetKeys(for: tab) ?? [] { #expect(seen.insert(key).inserted, "'\(key)' is on more than one tab") }
        }
    }

    @Test func tabsWithNothingToResetHaveNoButton() {
        #expect(SettingsView.resetKeys(for: .maintenance) == nil)
        #expect(SettingsView.resetKeys(for: .about) == nil)
        #expect(SettingsView.resetKeys(for: .overTheAir)?.contains("OTA_enabled") == true)
    }
}
