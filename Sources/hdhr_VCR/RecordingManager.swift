import Foundation

@MainActor
final class RecordingManager {
    private var pids:        [String: Int32]   = [:]   // caffeinate PID per show
    private var curlPids:    [String: Int32]   = [:]   // curl child PID (for explicit kill on manual stop)
    private var headerFiles: [String: String]  = [:]   // --dump-header file path per show

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
        // Dump response headers to a temp file so we can read X-HDHomeRun-Error on failure.
        let hdrPath = "/tmp/hdhrVCRplus-\(showId).headers"
        headerFiles[showId] = hdrPath
        curlArgs += ["--dump-header", hdrPath, streamURL, "-o", outputPath]

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
            // Kill caffeinate directly. Group kill (kill(-pid)) is unreliable because on macOS
            // caffeinate joins the curl child's process group, so PGID != caffeinate PID.
            kill(pid, SIGTERM)
            pids.removeValue(forKey: showId)
        }
        clearHeaderFile(showId: showId)
        glog("[Rec] Stopped \(showId)")
    }

    // MARK: - HDHomeRun error header

    /// Reads X-HDHomeRun-Resource from the curl dump-header file (e.g. "tuner0") without
    /// deleting the file — the error reader owns the delete when curl eventually exits.
    func readHDHRResource(showId: String) -> String? {
        guard let path = headerFiles[showId],
              let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in content.components(separatedBy: "\n") {
            guard line.lowercased().hasPrefix("x-hdhomerun-resource:") else { continue }
            let value = line.dropFirst("x-hdhomerun-resource:".count)
                           .trimmingCharacters(in: .whitespaces).lowercased()
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Reads X-HDHomeRun-Error from the curl dump-header file for a show, deletes the file,
    /// and returns a human-readable error string — or nil if no device-level error was reported.
    func readAndClearHDHRError(showId: String) -> String? {
        defer { clearHeaderFile(showId: showId) }
        guard let path = headerFiles[showId],
              let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in content.components(separatedBy: "\n") {
            let lower = line.lowercased()
            guard lower.hasPrefix("x-hdhomerun-error:") else { continue }
            let code = line.dropFirst("x-hdhomerun-error:".count)
                          .trimmingCharacters(in: .whitespaces)
            return hdhrErrorLabel(code)
        }
        return nil
    }

    private func clearHeaderFile(showId: String) {
        if let path = headerFiles.removeValue(forKey: showId) {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private func hdhrErrorLabel(_ code: String) -> String {
        switch code {
        case "804": return "Tuner In Use (804)"
        case "805": return "All Tuners In Use (805)"
        case "806": return "Tune Failed (806)"
        case "807": return "No Video Data (807)"
        case "808": return "DVR Failure (808)"
        case "809": return "Playback Connection Limit (809)"
        case "810": return "DVR Full (810)"
        case "811": return "Content Protection Required (811)"
        default:    return "Device error \(code)"
        }
    }

    // MARK: - Reattach (startup resume)

    /// Register an already-running caffeinate PID without launching a new process.
    func reattach(showId: String, pid: Int32) {
        pids[showId] = pid
        glog("[Rec] Reattached \(showId) caffeinate=\(pid)")
    }

    /// Register a curl PID found in ps during startup reattach. Called after reattach() so both
    /// halves of the pair are killable independently — the group kill is unreliable on macOS
    /// because caffeinate moves itself into the curl child's process group.
    func reattachCurlPid(showId: String, pid: Int32) {
        curlPids[showId] = pid
        glog("[Rec] Reattached \(showId) curl=\(pid)")
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
        // Rotate at 5 MB so the file doesn't grow unbounded across many verbose recordings.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int, size > 5 * 1024 * 1024 {
            try? "".write(toFile: path, atomically: false, encoding: .utf8)
        }
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
