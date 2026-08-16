import XCTest
import Foundation
@testable import hdhr_VCR

// MARK: - XCTest performance metrics (time/memory/CPU)
//
// Separate from WebServerPerfTests.swift's Swift Testing suite, which asserts hand-measured
// wall-clock medians against hardcoded thresholds — that suite is the actual pass/fail gate and
// needs no baseline. This suite exists for what only XCTestCase's measure API provides: real
// per-run time/memory/CPU samples with min/max/average/stddev, viewable in Xcode's Report
// Navigator or a .xcresult bundle. There's no baseline comparison wired up here — XCTest baselines
// are normally set interactively in Xcode's UI (Editor > Set Baseline) and don't have a clean
// headless-CLI equivalent, so these tests can't fail on regression by themselves. Treat them as
// "run occasionally, eyeball the numbers" diagnostics, not a CI gate.
//
// Requires the app running on :1980 (./deploy.sh first) — each test calls XCTSkip if it's not
// reachable, same convention as WebServerPerfTests.

final class WebServerPerfMetricsTests: XCTestCase {

    /// Bridges an async URLSession call into a synchronous measure{} block. XCTestCase's measure
    /// APIs are synchronous-only (no async overload as of this Xcode version) — this blocks the
    /// calling thread on a semaphore rather than the test needing its own thread management.
    private func await_<T>(_ operation: @escaping () async throws -> T) -> T? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: T?
        Task {
            result = try? await operation()
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    private func requireServerAvailable() throws {
        let ok = await_ {
            guard let (_, response) = try? await URLSession.shared.data(
                for: URLRequest(url: URL(string: "http://127.0.0.1:1980/api/ping")!, timeoutInterval: 2)
            ) else { return false }
            return (response as? HTTPURLResponse)?.statusCode == 200
        } ?? false
        try XCTSkipUnless(ok, "app not running on :1980 — run ./deploy.sh first")
    }

    private func get(_ path: String) {
        _ = await_ {
            try await URLSession.shared.data(for: URLRequest(url: URL(string: "http://127.0.0.1:1980\(path)")!, timeoutInterval: 5))
        }
    }

    /// GET / — served from cachedHTML (see docs/WebServer.md's "HTML cache" section). Clock time
    /// should track WebServerPerfTests.pageLoad_underThreshold's ~1-5ms baseline; memory/CPU give
    /// a per-request cost picture that hand-rolled timing can't.
    func testPageLoadMetrics() throws {
        try requireServerAvailable()
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric(), XCTCPUMetric()]) {
            get("/")
        }
    }

    /// /api/guide-refresh rebuilds the full grid live on every call (not cached) — the most
    /// expensive route in normal operation, so the one most worth watching for CPU/memory drift
    /// as the grid-building logic changes.
    func testGuideRefreshMetrics() throws {
        try requireServerAvailable()
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric(), XCTCPUMetric()]) {
            get("/api/guide-refresh")
        }
    }
}
