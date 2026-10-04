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

// AppState.freeSpaceIsLow — the FEED cache's start/stop disk guard (thresholds are fixed constants,
// deliberately not the recordings volume's Min_disk_free_gb).
@Suite("AppState.freeSpaceIsLow")
struct FeedCacheFreeSpaceTests {
    private let gb = 1_073_741_824.0

    @Test func belowThreshold_isLow() {
        #expect(AppState.freeSpaceIsLow(freeBytes: 9 * gb, minFreeGB: AppState.feedCacheStartMinFreeGB))
        #expect(AppState.freeSpaceIsLow(freeBytes: 2 * gb, minFreeGB: AppState.feedCacheStopMinFreeGB))
    }
    @Test func aboveThreshold_isNotLow() {
        #expect(!AppState.freeSpaceIsLow(freeBytes: 11 * gb, minFreeGB: AppState.feedCacheStartMinFreeGB))
        #expect(!AppState.freeSpaceIsLow(freeBytes: 4 * gb, minFreeGB: AppState.feedCacheStopMinFreeGB))
    }
    @Test func startThresholdIsHigherThanStop_forHysteresis() {
        #expect(AppState.feedCacheStartMinFreeGB > AppState.feedCacheStopMinFreeGB)
        // A disk with 5 GB free can't START a session but also isn't stopped while running.
        #expect(AppState.freeSpaceIsLow(freeBytes: 5 * gb, minFreeGB: AppState.feedCacheStartMinFreeGB))
        #expect(!AppState.freeSpaceIsLow(freeBytes: 5 * gb, minFreeGB: AppState.feedCacheStopMinFreeGB))
    }
}
