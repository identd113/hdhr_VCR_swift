import Foundation

@MainActor
final class RecordingManager {
    private var processes: [String: Process] = [:]
    private var pids:      [String: Int32]   = [:]   // caffeinate PID per show

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
            print("[Rec] Started \(showId) pid=\(p.processIdentifier) verbose=\(verbose): \(streamURL) → \(outputPath)")
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
        if let pid = pids[showId] {
            // Kill the caffeinate process group so curl child also dies
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
