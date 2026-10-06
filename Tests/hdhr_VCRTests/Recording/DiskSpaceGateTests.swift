import Testing
import Foundation
@testable import hdhr_VCR

// MARK: - AppState.diskOK(for:) — "Minimum free disk" is the only disk gate
//
// 7b4aa87 removed a hard-coded "refuse when the volume is ≥93% used" rule: a multi-terabyte array
// with hundreds of GB free was skipping scheduled recordings. `Min_disk_free_gb` alone decides now.
// diskOK reads the real filesystem under the show's record dir, so these use a temp dir (always on a
// real volume) and move the *threshold* around it instead of faking the volume: a tiny threshold must
// pass no matter how full the volume is, an impossible one must fail, and an unreadable path must
// not block a recording.

@Suite("AppState.diskOK — minimum-free-disk gate")
struct DiskSpaceGateTests {

    private func show(in dir: String) -> Show {
        var s = Show.testActive()
        s.show_dir = dir
        s.show_temp_dir = dir   // primary == fallback → posixRecordDir is exactly `dir`
        return s
    }

    private func tempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "hdhrVCRplus-disk-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test @MainActor func tinyThreshold_passes_regardlessOfHowFullTheVolumeIs() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let state = makeTestAppState()
        state.config.Min_disk_free_gb = 0.001
        #expect(state.diskOK(for: show(in: dir)) == true)
    }

    @Test @MainActor func thresholdLargerThanAnyVolume_fails() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let state = makeTestAppState()
        state.config.Min_disk_free_gb = 1_000_000_000   // ~1 exabyte — more than any volume has free
        #expect(state.diskOK(for: show(in: dir)) == false)
    }

    @Test @MainActor func thresholdSitsExactlyAtTheFreeSpaceBoundary() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let attrs = try FileManager.default.attributesOfFileSystem(forPath: dir)
        let freeGB = (attrs[.systemFreeSize] as! Double) / 1_073_741_824
        let state = makeTestAppState()
        // Comfortably below / above the live free space (it can drift by a few MB mid-test).
        state.config.Min_disk_free_gb = max(0, freeGB - 5)
        #expect(state.diskOK(for: show(in: dir)) == true)
        state.config.Min_disk_free_gb = freeGB + 5
        #expect(state.diskOK(for: show(in: dir)) == false)
    }

    @Test @MainActor func unreadableFilesystem_assumesOK_ratherThanBlockingTheRecording() {
        let state = makeTestAppState()
        state.config.Min_disk_free_gb = 1_000_000_000   // would fail if the stats were readable
        let missing = NSTemporaryDirectory() + "hdhrVCRplus-disk-missing-\(UUID().uuidString)/x"
        #expect(state.diskOK(for: show(in: missing)) == true)
    }

    @Test func minDiskFreeSetting_defaultsAndRoundTrips() throws {
        var cfg = AppConfig()
        #expect(cfg.Min_disk_free_gb > 0)
        cfg.Min_disk_free_gb = 12.5
        let back = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(cfg))
        #expect(back.Min_disk_free_gb == 12.5)
    }
}
