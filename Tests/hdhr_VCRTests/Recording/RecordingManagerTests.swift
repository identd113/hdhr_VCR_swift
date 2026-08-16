import Testing
import Foundation
@testable import hdhr_VCR

// MARK: - RecordingManager
//
// 2026-08-11 coverage pass measured RecordingManager.swift at 7.04% — start()/stop()/isRunning()
// wrap `curl` via posix_spawn with no injection point, so almost none of the lifecycle logic
// (pid bookkeeping, header-file parsing, exit-status decoding, sleep-assertion timing) had ever
// run under test. `curlExecutablePath` (init parameter, defaults to the real "/usr/bin/curl") is
// the seam: tests point it at a tiny generated shell script that mimics curl's relevant behavior
// (writes the --dump-header file, sleeps, exits with a controlled code) instead of a fake process
// object — spawnDetached/posix_spawn itself is completely untouched, only the executable path
// argument passed into it changes. This exercises the REAL spawn → real pid → real waitpid/kill
// path end to end, at the cost of being an integration-style test (real subprocess, real timing)
// rather than a pure unit test.
//
// Each test generates its own uniquely-named script with hardcoded behavior baked in (no shared
// env vars or global mutable state), so tests are safe to run concurrently — no .serialized needed.

@Suite("RecordingManager")
struct RecordingManagerTests {

    // writeMockCurlScript/waitUntil moved to TestFixtures.swift 2026-08-15 when
    // AppStateRecordingEngineTests needed the identical pair — see that file's own MARK comment.

    private func cleanup(_ paths: String...) {
        for p in paths { try? FileManager.default.removeItem(atPath: p) }
    }

    // MARK: - start / isRunning / stop lifecycle

    @Test @MainActor func start_thenIsRunning_true_thenStop_makesItFalse() async throws {
        let scriptPath = try writeMockCurlScript(sleepSeconds: 30)
        defer { cleanup(scriptPath) }
        let manager = RecordingManager(curlExecutablePath: scriptPath)
        let outputPath = NSTemporaryDirectory() + "hdhrVCRplus-test-\(UUID().uuidString).ts"
        defer { cleanup(outputPath) }
        let showId = "test-\(UUID().uuidString)"

        try manager.start(showId: showId, title: "Test Show", url: "http://192.0.2.1/auto/v5.1",
                           outputPath: outputPath, durationSeconds: 60, transcode: "none",
                           showEnd: Date().addingTimeInterval(60))

        await waitUntil { manager.isRunning(showId: showId) }
        #expect(manager.isRunning(showId: showId) == true)

        manager.stop(showId: showId)
        // stop() clears the pid bookkeeping synchronously — isRunning() must reflect that
        // immediately, without needing to wait for the OS to actually reap the killed process.
        #expect(manager.isRunning(showId: showId) == false)
    }

    @Test @MainActor func start_isIdempotent_secondCallForSameShowIdNoOps() async throws {
        let scriptPath = try writeMockCurlScript(sleepSeconds: 30)
        defer { cleanup(scriptPath) }
        let manager = RecordingManager(curlExecutablePath: scriptPath)
        let outputPath1 = NSTemporaryDirectory() + "hdhrVCRplus-test-\(UUID().uuidString).ts"
        let outputPath2 = NSTemporaryDirectory() + "hdhrVCRplus-test-\(UUID().uuidString).ts"
        defer { cleanup(outputPath1, outputPath2) }
        let showId = "test-\(UUID().uuidString)"

        try manager.start(showId: showId, title: "A", url: "http://192.0.2.1/auto/v5.1",
                           outputPath: outputPath1, durationSeconds: 60, transcode: "none",
                           showEnd: Date().addingTimeInterval(60))
        await waitUntil { manager.isRunning(showId: showId) }

        // guard pids[showId] == nil in start() means a second call for the same showId is a no-op —
        // confirmed by the fact it doesn't throw and the recording keeps running.
        try manager.start(showId: showId, title: "B", url: "http://192.0.2.1/auto/v9.1",
                           outputPath: outputPath2, durationSeconds: 60, transcode: "none",
                           showEnd: Date().addingTimeInterval(60))
        #expect(manager.isRunning(showId: showId) == true)

        manager.stop(showId: showId)
    }

    @Test @MainActor func isRunning_unknownShowId_returnsFalse() {
        let manager = RecordingManager()
        #expect(manager.isRunning(showId: "never-started") == false)
    }

    @Test @MainActor func stopAll_stopsEveryTrackedRecording() async throws {
        let scriptPath = try writeMockCurlScript(sleepSeconds: 30)
        defer { cleanup(scriptPath) }
        let manager = RecordingManager(curlExecutablePath: scriptPath)
        let showIds = (0..<3).map { _ in "test-\(UUID().uuidString)" }
        var outputPaths: [String] = []
        defer { cleanup(contentsOf: outputPaths) }
        for id in showIds {
            let out = NSTemporaryDirectory() + "hdhrVCRplus-test-\(UUID().uuidString).ts"
            outputPaths.append(out)
            try manager.start(showId: id, title: id, url: "http://192.0.2.1/auto/v5.1",
                               outputPath: out, durationSeconds: 60, transcode: "none",
                               showEnd: Date().addingTimeInterval(60))
        }
        for id in showIds { await waitUntil { manager.isRunning(showId: id) } }
        #expect(showIds.allSatisfy { manager.isRunning(showId: $0) })

        manager.stopAll()

        #expect(showIds.allSatisfy { manager.isRunning(showId: $0) == false })
    }

    // MARK: - HDHomeRun error header parsing (readHDHRResource / readAndClearHDHRError)

    @Test @MainActor func readHDHRResource_parsesHeaderWithoutDeletingFile() async throws {
        let scriptPath = try writeMockCurlScript(headerLines: ["X-HDHomeRun-Resource: tuner0"], sleepSeconds: 30)
        defer { cleanup(scriptPath) }
        let manager = RecordingManager(curlExecutablePath: scriptPath)
        let outputPath = NSTemporaryDirectory() + "hdhrVCRplus-test-\(UUID().uuidString).ts"
        defer { cleanup(outputPath) }
        let showId = "test-\(UUID().uuidString)"

        try manager.start(showId: showId, title: "Test", url: "http://192.0.2.1/auto/v5.1",
                           outputPath: outputPath, durationSeconds: 60, transcode: "none",
                           showEnd: Date().addingTimeInterval(60))

        await waitUntil { manager.readHDHRResource(showId: showId) != nil }
        #expect(manager.readHDHRResource(showId: showId) == "tuner0")
        // Reading again still works — readHDHRResource doesn't delete the header file (only the
        // error reader owns cleanup, per its own doc comment).
        #expect(manager.readHDHRResource(showId: showId) == "tuner0")

        manager.stop(showId: showId)
    }

    @Test @MainActor func readAndClearHDHRError_mapsKnownCodeAndDeletesFile() async throws {
        // Both headers written together: readHDHRResource (non-destructive) is used purely as a
        // "has the mock script finished writing the header file yet" readiness signal — calling
        // readAndClearHDHRError itself would consume/delete the file on the very first (empty) read
        // per its own defer-clearHeaderFile contract, so it must only be called once.
        let scriptPath = try writeMockCurlScript(
            headerLines: ["X-HDHomeRun-Resource: tuner0", "X-HDHomeRun-Error: 805"], sleepSeconds: 30)
        defer { cleanup(scriptPath) }
        let manager = RecordingManager(curlExecutablePath: scriptPath)
        let outputPath = NSTemporaryDirectory() + "hdhrVCRplus-test-\(UUID().uuidString).ts"
        defer { cleanup(outputPath) }
        let showId = "test-\(UUID().uuidString)"

        try manager.start(showId: showId, title: "Test", url: "http://192.0.2.1/auto/v5.1",
                           outputPath: outputPath, durationSeconds: 60, transcode: "none",
                           showEnd: Date().addingTimeInterval(60))

        await waitUntil { manager.readHDHRResource(showId: showId) != nil }
        #expect(manager.readAndClearHDHRError(showId: showId) == "All Tuners In Use (805)")
        // Second read after clearing returns nil — the header file/tracking entry is gone.
        #expect(manager.readAndClearHDHRError(showId: showId) == nil)

        manager.stop(showId: showId)
    }

    @Test @MainActor func readHDHRResource_unknownShowId_returnsNil() {
        let manager = RecordingManager()
        #expect(manager.readHDHRResource(showId: "never-started") == nil)
        #expect(manager.readAndClearHDHRError(showId: "never-started") == nil)
    }

    // MARK: - curl exit-status decoding (readAndClearExitStatus)

    @Test @MainActor func readAndClearExitStatus_decodesKnownCurlExitCode() async throws {
        // exit 6 = "curl couldn't resolve host" — a real, documented curl exit code.
        let scriptPath = try writeMockCurlScript(sleepSeconds: 0, exitCode: 6)
        defer { cleanup(scriptPath) }
        let manager = RecordingManager(curlExecutablePath: scriptPath)
        let outputPath = NSTemporaryDirectory() + "hdhrVCRplus-test-\(UUID().uuidString).ts"
        defer { cleanup(outputPath) }
        let showId = "test-\(UUID().uuidString)"

        try manager.start(showId: showId, title: "Test", url: "http://192.0.2.1/auto/v5.1",
                           outputPath: outputPath, durationSeconds: 60, transcode: "none",
                           showEnd: Date().addingTimeInterval(60))

        // isRunning() is what reaps the exited child and stashes lastExitStatus — poll until it
        // flips to false (process already exited immediately given sleepSeconds: 0).
        await waitUntil { manager.isRunning(showId: showId) == false }
        #expect(manager.isRunning(showId: showId) == false)
        #expect(manager.readAndClearExitStatus(showId: showId) == "curl couldn't resolve host (6)")
        // Cleared after reading — a stale status must never leak into a later unrelated check.
        #expect(manager.readAndClearExitStatus(showId: showId) == nil)
    }

    @Test @MainActor func readAndClearExitStatus_cleanExit_returnsNil() async throws {
        let scriptPath = try writeMockCurlScript(sleepSeconds: 0, exitCode: 0)
        defer { cleanup(scriptPath) }
        let manager = RecordingManager(curlExecutablePath: scriptPath)
        let outputPath = NSTemporaryDirectory() + "hdhrVCRplus-test-\(UUID().uuidString).ts"
        defer { cleanup(outputPath) }
        let showId = "test-\(UUID().uuidString)"

        try manager.start(showId: showId, title: "Test", url: "http://192.0.2.1/auto/v5.1",
                           outputPath: outputPath, durationSeconds: 60, transcode: "none",
                           showEnd: Date().addingTimeInterval(60))

        await waitUntil { manager.isRunning(showId: showId) == false }
        #expect(manager.readAndClearExitStatus(showId: showId) == nil)
    }

    @Test @MainActor func readAndClearExitStatus_unknownShowId_returnsNil() {
        let manager = RecordingManager()
        #expect(manager.readAndClearExitStatus(showId: "never-started") == nil)
    }

    // MARK: - reattach (startup resume)

    @Test @MainActor func reattach_registersPidAndMakesIsRunningTrue() throws {
        let manager = RecordingManager()
        let showId = "test-\(UUID().uuidString)"
        // Any real, currently-running process works here — reattach only needs a live pid,
        // it doesn't spawn one itself. This process's own pid is guaranteed alive for the test's
        // duration.
        let selfPid = getpid()
        manager.reattach(showId: showId, pid: selfPid, title: "Resumed Show",
                          endDate: Date().addingTimeInterval(120))
        #expect(manager.isRunning(showId: showId) == true)
        // Clean up the sleep assertion this creates without killing our own test process.
        manager.releaseAssertion(id: showId)
    }

    // MARK: - sleep assertions

    @Test @MainActor func preventSleep_thenReleaseAssertion_doesNotCrash() {
        let manager = RecordingManager()
        manager.preventSleep(id: "assertion-test", reason: "unit test", duration: 5)
        manager.releaseAssertion(id: "assertion-test")
        // Releasing twice must be a safe no-op (removeValue(forKey:) returns nil the second time).
        manager.releaseAssertion(id: "assertion-test")
    }

    @Test @MainActor func releaseAllAssertions_clearsMultiple() {
        let manager = RecordingManager()
        manager.preventSleep(id: "a", reason: "unit test", duration: 5)
        manager.preventSleep(id: "b", reason: "unit test", duration: 5)
        manager.releaseAllAssertions()
        // No public getter for assertionIds — this just confirms no crash across repeated release.
        manager.releaseAllAssertions()
    }
}

private extension RecordingManagerTests {
    func cleanup(contentsOf paths: [String]) {
        for p in paths { try? FileManager.default.removeItem(atPath: p) }
    }
}
