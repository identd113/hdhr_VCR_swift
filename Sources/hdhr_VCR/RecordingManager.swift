import Foundation
import IOKit.pwr_mgt

@MainActor
final class RecordingManager {
    private var pids:         [String: Int32]            = [:]   // curl PID per show
    private var headerFiles:  [String: String]           = [:]   // --dump-header file path per show
    private var assertionIds: [String: IOPMAssertionID]  = [:]   // IOKit assertion per show (+ "vlc")
    private var lastExitStatus: [String: Int32]           = [:]   // raw waitpid status, set when isRunning() reaps a dead curl

    static var curlLogPath: String { logFilePath }

    // MARK: - Start

    func start(showId: String, title: String, url: String, outputPath: String,
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
        if verbose { curlArgs += ["-v", "--no-progress-meter"] }
        let hdrPath = "\(NSTemporaryDirectory())hdhrVCRplus-\(showId).headers"
        headerFiles[showId] = hdrPath
        curlArgs += ["--dump-header", hdrPath, streamURL, "-o", outputPath]

        let dir = (outputPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        if verbose { writeCurlLogHeader(showId: showId, curlArgs: curlArgs, outputPath: outputPath) }
        let logPath: String? = verbose ? Self.curlLogPath : nil

        // Spawn curl directly in its own POSIX session — one PID per recording.
        // Sleep prevention is handled by a fire-and-forget IOKit assertion below.
        let pid = try spawnDetached(executablePath: "/usr/bin/curl",
                                    arguments: curlArgs,
                                    stderrPath: logPath)
        pids[showId] = pid

        // Prevent system sleep for the recording duration + 5-min buffer.
        preventSleep(id: showId, reason: "Recording: \(title)", duration: TimeInterval(durationSeconds + 300))

        glog("[Rec] Started \(showId) pid=\(pid) verbose=\(verbose): \(streamURL) → \(outputPath)")
    }

    // MARK: - Stop

    func stop(showId: String) {
        if let pid = pids[showId] {
            kill(pid, SIGKILL)
            pids.removeValue(forKey: showId)
            // Reap the zombie OFF the main actor. SIGKILL is normally reaped in microseconds, but it
            // can't be delivered while the target sits in an uninterruptible (D-state) syscall — e.g.
            // curl blocked writing to a stalled network mount, a perfectly valid recording target. A
            // blocking waitpid(pid, nil, 0) here (RecordingManager is @MainActor, and stopAll() loops
            // it over every recording) would freeze the menu-bar UI until the mount recovers. A
            // detached wait reaps the child whenever it finally dies without stalling the UI. Safe to
            // background: we've already cleared pids[showId], and isRunning() guards on pids, so the
            // only other waitpid site can never touch this pid again.
            DispatchQueue.global(qos: .utility).async { waitpid(pid, nil, 0) }
        }
        releaseAssertion(id: showId)
        clearHeaderFile(showId: showId)
        // Defensive, same as clearHeaderFile above: a stale exit status from this attempt must
        // never leak into a later, unrelated FAIL check for the same recurring show_id.
        lastExitStatus.removeValue(forKey: showId)
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

    /// Register an already-running curl PID after an app restart and re-arm the sleep assertion
    /// for the remaining show duration so the system doesn't sleep mid-recording.
    func reattach(showId: String, pid: Int32, title: String, endDate: Date) {
        pids[showId] = pid
        let remaining = max(60, endDate.timeIntervalSinceNow) + 300
        preventSleep(id: showId, reason: "Recording: \(title)", duration: remaining)
        glog("[Rec] Reattached \(showId) curl=\(pid)")
    }

    // MARK: - Status

    func isRunning(showId: String) -> Bool {
        guard let pid = pids[showId] else { return false }
        var status: Int32 = 0
        let wret = waitpid(pid, &status, WNOHANG)
        if wret == 0 { return true }   // our child, still running
        if wret > 0 {                  // our child exited — zombie reaped
            pids.removeValue(forKey: showId)
            lastExitStatus[showId] = status
            return false
        }
        // ECHILD: not our child — orphaned to launchd after an app restart.
        // launchd auto-reaps orphan zombies so kill(pid,0) is reliable here.
        if kill(pid, 0) == 0 { return true }
        pids.removeValue(forKey: showId); return false
    }

    /// Reads and clears the raw wait-status captured the last time `isRunning` reaped this
    /// show's curl process, decoded into a human-readable curl exit reason. Fills in the gap
    /// left when `readAndClearHDHRError` finds no X-HDHomeRun-Error header (e.g. curl itself
    /// timed out or couldn't connect, rather than the device reporting an error) — so failure
    /// messages still say *why* instead of falling back to a generic string.
    func readAndClearExitStatus(showId: String) -> String? {
        guard let status = lastExitStatus.removeValue(forKey: showId) else { return nil }
        guard status & 0x7f == 0 else { return "curl killed by signal \(status & 0x7f)" } // not WIFEXITED
        let code = (status >> 8) & 0xff // WEXITSTATUS
        guard code != 0 else { return nil } // clean exit isn't itself a failure reason
        return curlExitLabel(code)
    }

    private func curlExitLabel(_ code: Int32) -> String {
        switch code {
        case 2:  return "curl init failed (2)"
        case 5:  return "curl couldn't resolve proxy (5)"
        case 6:  return "curl couldn't resolve host (6)"
        case 7:  return "curl couldn't connect (7)"
        case 18: return "curl partial file (18)"
        case 23: return "curl write error (23)"
        case 28: return "curl timeout (28)"
        case 35: return "curl SSL connect error (35)"
        case 52: return "curl empty reply from server (52)"
        case 55: return "curl failed sending data (55)"
        case 56: return "curl failure receiving data (56)"
        default: return "curl exit \(code)"
        }
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

    // MARK: - Sleep prevention

    /// Creates a tracked IOKit sleep assertion keyed by `id`. The OS auto-releases it after
    /// `duration` seconds; we also release early via `releaseAssertion` / `releaseAllAssertions`.
    func preventSleep(id: String, reason: String, duration: TimeInterval) {
        releaseAssertion(id: id)   // drop any stale assertion for this key first
        var assertionId: IOPMAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
        let kret = IOPMAssertionCreateWithDescription(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            reason as CFString,
            nil, nil, nil,
            duration,
            kIOPMAssertionTimeoutActionRelease as CFString,
            &assertionId
        )
        guard kret == kIOReturnSuccess else {
            glog("[Rec] Sleep assertion failed (err=\(kret)) for \(id)", level: .warning)
            return
        }
        assertionIds[id] = assertionId
    }

    func releaseAssertion(id: String) {
        if let aid = assertionIds.removeValue(forKey: id) {
            IOPMAssertionRelease(aid)
        }
    }

    /// Releases all tracked sleep assertions. Called when the status check confirms no tuners
    /// are streaming — clears any assertions that outlived their recording due to a crash or delete.
    func releaseAllAssertions() {
        for aid in assertionIds.values { IOPMAssertionRelease(aid) }
        assertionIds.removeAll()
        glog("[Rec] All sleep assertions released")
    }

    // MARK: - Verbose log

    private func writeCurlLogHeader(showId: String, curlArgs: [String], outputPath: String) {
        let path = Self.curlLogPath
        // No size cap here — curlLogPath is logFilePath, and glog()'s RotatingLogFile already
        // caps that file centrally. An in-place truncate here previously raced with
        // RotatingLogFile's persistently-open FileHandle: truncating the file out from under it
        // left its internal byte counter out of sync with the file's real (now zero) size,
        // and the next glog() write would resume at RotatingLogFile's stale offset, leaving a
        // zero-filled gap. curl's own -v stderr also writes directly to this same path via a
        // raw posix_spawn fd (see spawnDetached's stderrPath), independent of both.
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let fh = FileHandle(forWritingAtPath: path) else { return }
        defer { try? fh.close() }
        fh.seekToEndOfFile()
        let header = "\n[CURL] \(showId) → \(outputPath) | \(curlArgs.joined(separator: " "))\n"
        fh.write(header.data(using: .utf8) ?? Data())
    }
}
