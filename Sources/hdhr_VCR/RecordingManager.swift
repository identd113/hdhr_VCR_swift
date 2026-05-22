import Foundation

@MainActor
final class RecordingManager {
    private var processes: [String: Process] = [:]
    private var pids:      [String: Int32]   = [:]   // caffeinate PID per show
    private var curlPids:  [String: Int32]   = [:]   // curl child PID (for explicit kill on manual stop)

    static let curlLogPath = NSHomeDirectory() + "/Library/Logs/hdhr_VCR_curl.log"

    // MARK: - Start

    func start(showId: String, url: String, outputPath: String,
               durationSeconds: Int, transcode: String, showEnd: Date,
               verbose: Bool = false) {
        guard processes[showId] == nil else { return }

        let profile      = transcode.lowercased().trimmingCharacters(in: .whitespaces)
        let streamURL    = "\(url)?duration=\(durationSeconds)&transcode=\(profile)"
        let showEndEpoch = String(Int(showEnd.timeIntervalSince1970))

        var curlArgs: [String] = [
            "--connect-timeout", "10",
            "--max-time", "\(durationSeconds + 120)",
            "-H", "show_id:\(showId)",
            "-H", "show_end:\(showEndEpoch)",
            "-H", "appname:hdhr_VCR_swift",
        ]
        if verbose { curlArgs.append("-v") }
        curlArgs += [streamURL, "-o", outputPath]

        let dir = (outputPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // caffeinate -i prevents idle sleep and wraps curl; creates 2 visible ps lines per show
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments     = ["-i", "/usr/bin/curl"] + curlArgs
        p.standardOutput = FileHandle.nullDevice

        if verbose, let fh = openCurlLog(showId: showId, curlArgs: curlArgs, outputPath: outputPath) {
            p.standardError = fh
        } else {
            p.standardError = FileHandle.nullDevice
        }

        do {
            try p.run()
            processes[showId] = p
            pids[showId]      = p.processIdentifier
            // Find curl's PID as a child of caffeinate so we can kill it directly on manual stop.
            // pgrep -P returns child PIDs; curl is caffeinate's only child in this usage.
            if let curlPid = findCurlChild(of: p.processIdentifier) {
                curlPids[showId] = curlPid
            }
            print("[Rec] Started \(showId) pid=\(p.processIdentifier) curl=\(curlPids[showId].map { "\($0)" } ?? "?") verbose=\(verbose): \(streamURL) → \(outputPath)")
        } catch {
            print("[Rec] Launch error for \(showId): \(error)")
        }
    }

    // MARK: - Stop

    func stop(showId: String) {
        if let p = processes[showId] {
            if p.isRunning { p.terminate() }
            processes.removeValue(forKey: showId)
        }
        // Kill curl directly first — caffeinate may ignore SIGTERM but curl will stop writing
        if let curlPid = curlPids[showId] {
            kill(curlPid, SIGTERM)
            curlPids.removeValue(forKey: showId)
        }
        if let pid = pids[showId] {
            // Kill the entire caffeinate process group to ensure no orphaned children remain
            kill(-pid, SIGTERM)
            pids.removeValue(forKey: showId)
        }
        print("[Rec] Stopped \(showId)")
    }

    // MARK: - Reattach (startup resume)

    /// Register an already-running caffeinate PID without launching a new process.
    /// Called at startup when a recording survived an app restart.
    func reattach(showId: String, pid: Int32) {
        pids[showId] = pid
        print("[Rec] Reattached \(showId) pid=\(pid)")
    }

    // MARK: - Status

    func isRunning(showId: String) -> Bool {
        guard let pid = pids[showId] else { return false }
        // kill -0 returns 0 if the process exists, errno ESRCH if it does not
        return kill(pid, 0) == 0
    }

    func stopAll() {
        for id in Array(processes.keys) { stop(showId: id) }
    }

    // MARK: - Curl child discovery

    /// Uses pgrep to find the PID of curl launched as a child of the caffeinate process.
    /// Returns nil if curl hasn't started yet or pgrep fails — the process-group kill in stop()
    /// will still clean it up in that case.
    private func findCurlChild(of parentPid: Int32) -> Int32? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-P", "\(parentPid)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError  = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            let data   = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let pid = Int32(output.components(separatedBy: "\n").first ?? "") {
                return pid
            }
        } catch {}
        return nil
    }

    // MARK: - Verbose log

    private func openCurlLog(showId: String, curlArgs: [String], outputPath: String) -> FileHandle? {
        let path = Self.curlLogPath
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) { fm.createFile(atPath: path, contents: nil) }
        guard let fh = FileHandle(forWritingAtPath: path) else { return nil }
        fh.seekToEndOfFile()
        let header = """

=== [\(Date())] showId=\(showId) ===
Output: \(outputPath)
/usr/bin/caffeinate -i /usr/bin/curl \(curlArgs.joined(separator: " "))

"""
        fh.write(header.data(using: .utf8) ?? Data())
        return fh
    }
}
