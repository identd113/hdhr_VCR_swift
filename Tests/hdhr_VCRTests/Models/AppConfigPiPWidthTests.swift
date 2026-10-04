import Testing
import Foundation
@testable import hdhr_VCR

// AppConfig.PiP_width_fraction (2026-10-03) — the user-dragged PiP size lives in the config file so
// it survives quits and reinstalls.
@Suite("AppConfig.PiP_width_fraction")
struct AppConfigPiPWidthTests {
    @Test func missingKey_defaultsToAutomatic() throws {
        let cfg = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(cfg.PiP_width_fraction == 0)
    }

    @Test func roundTrips() throws {
        var cfg = AppConfig()
        cfg.PiP_width_fraction = 0.37
        let data = try JSONEncoder().encode(cfg)
        let back = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(back.PiP_width_fraction == 0.37)
    }
}
