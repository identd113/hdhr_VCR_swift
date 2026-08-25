import Testing
import Foundation
@testable import hdhr_VCR

// MARK: - saveConfig() latency under real disk I/O pressure
//
// Live report 2026-08-24 (see ISSUES.md): the web guide feels laggy while the app is doing
// something "heavy." First guess was CPU/MainActor contention from repeated show-lifecycle
// events — WebServerPerfTests.swift's apiLatency_staysResponsive_duringGuideChangeBurst ruled
// that out (passed comfortably). Follow-up from the user narrowed it to concurrent heavy disk
// I/O instead (CrashPlan backup + a large file copy running at the time).
//
// AppState.saveConfig() -> ConfigManager.save(_:) does three synchronous, blocking filesystem
// calls directly on the @MainActor — remove the old backup, copy the current config to it, then
// an atomic write of the new one — and it's called from 26 sites in AppState.swift covering
// essentially every show mutation (add/edit/delete/pause/resume/idle-loop reschedule). Because
// AppState is @MainActor, and WebServer hops onto that same actor for nearly every request that
// touches AppState, a slow disk write here blocks the actor and therefore every other web
// request queued behind it — architecturally the same shape as this project's own past
// MainActor-blocking bugs (issues_resolved.md's "Blocking waitpid on the main actor can freeze
// the menu-bar UI"; ISSUES.md's VLC relay-seek deadlock).
//
// This measures saveConfig()'s own wall-clock latency directly — no web server involved, since
// the suspected mechanism lives in AppState/ConfigManager, not anything web-specific — while a
// background Task generates real, sustained disk-write pressure on the same volume as the test's
// scratch config directory, instead of trying to mock "CrashPlan is running." Deliberately no new
// test infrastructure: reuses makeTestAppState's existing temp-config-dir convention and a plain
// background Task, no subprocess, no new dependency.

@Suite("AppState saveConfig latency under disk pressure")
struct AppStateDiskIOLatencyTests {

    // Repeatedly writes a 20MB blob to a scratch file and forces it to physical disk (fsync) on
    // several concurrent writers until stopped — a crude but real stand-in for "something else is
    // hammering this disk," on the same volume saveConfig() itself writes to. The fsync matters:
    // a plain buffered write just lands in the page cache and returns almost instantly, which
    // undersells real contention — CrashPlan and a Finder file copy both eventually force data to
    // physical disk too, and that's the part actually competing with saveConfig()'s own write.
    private final class DiskPressure: @unchecked Sendable {
        private let dir: URL
        private var tasks: [Task<Void, Never>] = []
        init(dir: URL) { self.dir = dir }
        func start(writers: Int = 3) {
            let dir = self.dir
            for i in 0..<writers {
                let path = dir.appendingPathComponent("disk-pressure-\(i)-\(UUID().uuidString).bin").path
                tasks.append(Task.detached(priority: .utility) {
                    let blob = Data(count: 20 * 1_048_576)
                    let url = URL(fileURLWithPath: path)
                    while !Task.isCancelled {
                        try? blob.write(to: url, options: .atomic)
                        if let fh = try? FileHandle(forWritingTo: url) {
                            fh.synchronizeFile()
                            try? fh.close()
                        }
                    }
                    try? FileManager.default.removeItem(atPath: path)
                })
            }
        }
        func stop() {
            tasks.forEach { $0.cancel() }   // each task removes its own scratch file on exit
        }
    }

    @Test @MainActor func saveConfig_staysResponsive_underConcurrentDiskWrites() async throws {
        let state = makeTestAppState(shows: [Show.testActive(), Show.testPaused()])
        let configDir = URL(fileURLWithPath: state.configManager.configPath).deletingLastPathComponent()

        // Baseline: a handful of saves with no competing I/O.
        var baseline: [TimeInterval] = []
        for _ in 0..<5 {
            let start = Date()
            state.saveConfig()
            baseline.append(Date().timeIntervalSince(start))
        }

        let pressure = DiskPressure(dir: configDir)
        pressure.start()
        defer { pressure.stop() }
        // Let the pressure Task actually ramp up before measuring against it.
        try await Task.sleep(nanoseconds: 200_000_000)

        var underPressure: [TimeInterval] = []
        for _ in 0..<5 {
            let start = Date()
            state.saveConfig()
            underPressure.append(Date().timeIntervalSince(start))
        }

        baseline.sort(); underPressure.sort()
        let baselineMedian = baseline[baseline.count / 2]
        let pressureMedian = underPressure[underPressure.count / 2]
        let pressureMax    = underPressure.last ?? 0

        // Loose on purpose (this file's own convention — see WebServerPerfTests.swift): sized to
        // catch a real architectural regression (e.g. someone adding synchronous work to
        // saveConfig that's much more I/O-sensitive than today), not to enforce a specific
        // millisecond figure on a shared/loaded CI machine.
        #expect(pressureMedian < 0.5,
            "saveConfig() median \(Int(pressureMedian * 1000))ms under concurrent disk writes (baseline was \(Int(baselineMedian * 1000))ms, worst \(Int(pressureMax * 1000))ms) — ConfigManager.save's remove+copy+atomic-write runs synchronously on the MainActor, so a slow disk stalls every web request behind it")
    }
}
