import Foundation

@MainActor
final class RecordingManager {
    private var pids:     [String: Int32] = [:]   // caffeinate PID per show
    private var curlPids: [String: Int32] = [:]   // curl child PID (for explicit kill on manual stop)

    static let curlLogPath = NSHomeDirectory() + "/Library/Logs/hdhrVCRplus.log"

    // MARK: - Start

    func start(showId: String, url: String, outputPath: String,
               durationSeconds: Int, transcode: String, showEnd: Date,
               verbose: Bool = false, networkInterface: String = "") throws {
        guard pids[showId] == nil else { return }

        let profile      = transcode.lowercased().trimmingCharacters(in: .whitespaces)
        let streamURL    = "\(url)?duration=\(durationSeconds)&transcode=\(profile)"
        let showEndEpoch = String(Int(showEnd.timeIntervalSince1970))

        var curlArgs: [String] = [
            "--connect-timeout", "10",
            "--max-time", "\(durationSeconds + 120)",
            "-H", "show_id:\(showId)",
            "-H", "show_end:\(showEndEpoch)",
            "-H", "appname:hdhrVCRplus",
        ]
        if !networkInterface.isEmpty { curlArgs += ["--interface", networkInterface] }
        if verbose { curlArgs.append("-v") }
        curlArgs += [streamURL, "-o", outputPath]

        let dir = (outputPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Write the header to the log file before spawning so the child just appends.
        if verbose { writeCurlLogHeader(showId: showId, curlArgs: curlArgs, outputPath: outputPath) }
        let logPath: String? = verbose ? Self.curlLogPath : nil

        // caffeinate -i prevents idle sleep and wraps curl; POSIX_SPAWN_SETSID puts the
        // process in its own session so a force-quit of the app does not kill the recording.
        let pid = try spawnDetached(executablePath: "/usr/bin/caffeinate",
                                    arguments: ["-i", "/usr/bin/curl"] + curlArgs,
                                    stderrPath: logPath)
        pids[showId] = pid
        // Find curl child off the main actor — pgrep blocks; curlPids is only used for stop() SIGTERM
        let showIdCopy = showId
        Task.detached(priority: .utility) { [weak self] in
            if let curlPid = self?.findCurlChild(of: pid) {
                await MainActor.run { [weak self] in self?.curlPids[showIdCopy] = curlPid }
            }
        }
        glog("[Rec] Started \(showId) pid=\(pid) verbose=\(verbose): \(streamURL) → \(outputPath)")
    }

    // MARK: - Stop

    func stop(showId: String) {
        // Kill curl directly first — caffeinate may ignore SIGTERM but curl will stop writing
        if let curlPid = curlPids[showId] {
            kill(curlPid, SIGTERM)
            curlPids.removeValue(forKey: showId)
        }
        if let pid = pids[showId] {
            // Kill the entire caffeinate process group (caffeinate + curl child)
            kill(-pid, SIGTERM)
            pids.removeValue(forKey: showId)
        }
        glog("[Rec] Stopped \(showId)")
    }

    // MARK: - Reattach (startup resume)

    /// Register an already-running caffeinate PID without launching a new process.
    func reattach(showId: String, pid: Int32) {
        pids[showId] = pid
        let showIdCopy = showId
        Task.detached(priority: .utility) { [weak self] in
            if let curlPid = self?.findCurlChild(of: pid) {
                await MainActor.run { [weak self] in self?.curlPids[showIdCopy] = curlPid }
            }
        }
        glog("[Rec] Reattached \(showId) pid=\(pid)")
    }

    // MARK: - Status

    func isRunning(showId: String) -> Bool {
        guard let pid = pids[showId] else { return false }
        return kill(pid, 0) == 0
    }

    func stopAll() {
        for id in Array(pids.keys) { stop(showId: id) }
    }

    // MARK: - Detached spawn

    /// Launch an executable in its own POSIX session (POSIX_SPAWN_SETSID) so the process
    /// survives a force-quit of the parent app. stdin/stdout go to /dev/null; stderr goes to
    /// stderrPath (appended) or /dev/null if nil.
    private func spawnDetached(executablePath: String, arguments: [String],
                                stderrPath: String?) throws -> pid_t {
        var fa: posix_spawn_file_actions_t?
        var sa: posix_spawnattr_t?

        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawnattr_init(&sa)
        defer { posix_spawnattr_destroy(&sa) }

        // New session: decouples from the app's process group and session.
        posix_spawnattr_setflags(&sa, Int16(POSIX_SPAWN_SETSID))

        "/dev/null".withCString { devNull in
            posix_spawn_file_actions_addopen(&fa, STDIN_FILENO,  devNull, O_RDONLY, 0)
            posix_spawn_file_actions_addopen(&fa, STDOUT_FILENO, devNull, O_WRONLY, 0)
        }
        let errTarget = stderrPath ?? "/dev/null"
        _ = errTarget.withCString { path in
            posix_spawn_file_actions_addopen(&fa, STDERR_FILENO, path,
                                             O_WRONLY | O_CREAT | O_APPEND, 0o644)
        }

        // Build null-terminated argv (first element must be the executable path).
        let argv: [UnsafeMutablePointer<CChar>?] = ([executablePath] + arguments).map { strdup($0) } + [nil]
        defer { argv.compactMap { $0 }.forEach { free($0) } }

        var pid: pid_t = 0
        var rc: Int32 = 0
        argv.withUnsafeBufferPointer { argvBuf in
            executablePath.withCString { exec in
                rc = posix_spawn(&pid, exec, &fa, &sa,
                                 UnsafeMutablePointer(mutating: argvBuf.baseAddress), environ)
            }
        }

        guard rc == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(rc),
                          userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(rc))])
        }
        return pid
    }

    // MARK: - Curl child discovery

    /// Uses pgrep to find curl's PID as a child of caffeinate.
    nonisolated private func findCurlChild(of parentPid: Int32) -> Int32? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-P", "\(parentPid)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError  = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                                encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Int32(output.components(separatedBy: "\n").first ?? "")
        } catch { return nil }
    }

    // MARK: - Verbose log

    private func writeCurlLogHeader(showId: String, curlArgs: [String], outputPath: String) {
        let path = Self.curlLogPath
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let fh = FileHandle(forWritingAtPath: path) else { return }
        defer { try? fh.close() }
        fh.seekToEndOfFile()
        let header = """

=== [\(Date())] showId=\(showId) ===
Output: \(outputPath)
/usr/bin/caffeinate -i /usr/bin/curl \(curlArgs.joined(separator: " "))

"""
        fh.write(header.data(using: .utf8) ?? Data())
    }
}
