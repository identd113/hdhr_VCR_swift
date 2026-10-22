import AppKit

// Classic "you launched me from the DMG/Downloads instead of dragging me to Applications" check —
// see docs/Distribution.md's "First install" flow (step 3, drag to /Applications, is a manual step
// users routinely skip). Runs only in notarized release builds (#if !DEBUG) so ./deploy.sh's
// dev workflow, which always runs the app in place from the repo root, is never affected.
enum AppRelocator {

    // The rest of the app's launch (`AppState.startup()`: config, recording reattach, discovery, the web server) must not run
    // underneath the "Move to Applications?" prompt — if the user then moves the app, a half-started instance would be
    // quit and a second one started on top of it. `startup()` waits for `waitForDecision`; the flag is set once this
    // instance is definitely staying (no move needed, declined, or the move failed). A move that succeeds quits this
    // instance, so it never sets it.
    private static let decisionLock = NSLock()
    private static var decisionMade = false

    static func markDecided() {
        decisionLock.lock(); decisionMade = true; decisionLock.unlock()
    }

    static var isDecided: Bool {
        decisionLock.lock(); defer { decisionLock.unlock() }
        return decisionMade
    }

    /// Returns once this instance is staying, or after `timeout` (an unanswered prompt must not stop a Mac from recording).
    static func waitForDecision(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !isDecided, Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
    }


    /// True when `url` sits inside a git checkout (a developer's repo build output, e.g. the
    /// `hdhrVCRplus.app` that `deploy_release.sh` opens from the repo root). Such a copy must never
    /// be offered a move — accepting would trash the build output.
    static func isInsideGitCheckout(_ url: URL, fileManager fm: FileManager = .default) -> Bool {
        var dir = url.deletingLastPathComponent()
        for _ in 0..<6 {
            if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) { return true }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return false
    }

    /// Installs a copy of `source` at `dest` without ever leaving the user with *less* than they
    /// started with: the copy goes to a temporary sibling first, and only a complete copy replaces
    /// an existing `dest` (atomic swap). A failed copy (disk full, permissions) leaves any existing
    /// install untouched — the old flow deleted it before copying.
    static func install(_ source: URL, replacing dest: URL, fileManager fm: FileManager = .default) throws {
        let temp = dest.deletingLastPathComponent()
            .appendingPathComponent(".\(dest.lastPathComponent).incoming-\(UUID().uuidString)")
        do {
            try fm.copyItem(at: source, to: temp)
            if fm.fileExists(atPath: dest.path) {
                _ = try fm.replaceItemAt(dest, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: dest)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    /// A failure that may just mean "macOS is asking the user for permission right now" (App Management, or access to the
    /// Applications folder): the system fails the file call at once with a no-permission error while its prompt is on screen,
    /// so the move has to be retried after the user answers instead of being abandoned. Checks the underlying error too.
    static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain,
           [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(ns.code) { return true }
        if ns.domain == NSPOSIXErrorDomain, [Int(EPERM), Int(EACCES)].contains(ns.code) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionError(underlying) }
        return false
    }

    /// Runs `attempt`; while it fails with a permission error, waits `interval` and tries again until `timeout` has passed
    /// (the user is answering macOS's permission prompt). Any other error, and the last permission error once time is up,
    /// is thrown. The sleep and clock are injectable so this is unit-tested without waiting.
    static func retryWhileAwaitingPermission(timeout: TimeInterval, interval: TimeInterval,
                                             sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                                             now: () -> Date = Date.init,
                                             onWaiting: () -> Void = {},
                                             attempt: () throws -> Void) throws {
        let deadline = now().addingTimeInterval(timeout)
        var announced = false
        while true {
            do { return try attempt() } catch {
                guard isPermissionError(error), now() < deadline else { throw error }
                if !announced { announced = true; onWaiting() }
                sleep(interval)
            }
        }
    }

    /// If the running .app isn't inside an Applications folder (system or per-user), offers to
    /// copy it there, relaunch from the new location, and quit this instance.
    static func relocateToApplicationsIfNeeded() {
        if runInPlaceOrRelocate() { markDecided() }
    }

    /// True when this instance stays and launches normally; false when it is being replaced by a relaunch from Applications.
    private static func runInPlaceOrRelocate() -> Bool {
        #if DEBUG
        return true
        #else
        let fm = FileManager.default
        let currentURL = URL(fileURLWithPath: Bundle.main.bundlePath).standardizedFileURL
        guard currentURL.pathExtension == "app" else { return true }   // bare binary, no bundle — dev only

        let applicationsDirs = fm.urls(for: .applicationDirectory, in: .allDomainsMask)
            .map { $0.standardizedFileURL.path }
        let currentParent = currentURL.deletingLastPathComponent().path
        guard !applicationsDirs.contains(currentParent) else { return true }   // already installed correctly
        guard !isInsideGitCheckout(currentURL) else { return true }            // a developer's repo build — never offer to move/trash it

        let bundleName = currentURL.lastPathComponent
        let destURL = URL(fileURLWithPath: "/Applications").appendingPathComponent(bundleName)
        let displayName = bundleName.replacingOccurrences(of: ".app", with: "")

        let alert = NSAlert()
        alert.messageText = "Move to Applications Folder?"
        alert.informativeText = "\(displayName) is running from \(currentURL.deletingLastPathComponent().path), not your Applications folder. Move it to Applications and relaunch?\n\nmacOS may ask your permission to do this — click Allow and the move will finish."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Don't Move")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            glog("AppRelocator: user declined move from \(currentURL.path)")
            return true
        }

        // 1. QUIT: an install that's already running must not be swapped out from under its own process (and a second
        // instance would fight this one for port 1980), so ask it to quit first and wait for it to go. If it won't (a
        // recording-in-progress prompt is open, say), leave it alone: bring it forward and quit this copy instead.
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                            && $0.bundleURL?.standardizedFileURL == destURL.standardizedFileURL }) {
            glog("AppRelocator: \(destURL.path) is running — asking it to quit before replacing it")
            running.terminate()
            let quitDeadline = Date().addingTimeInterval(15)
            while !running.isTerminated, Date() < quitDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
            if !running.isTerminated {
                glog("AppRelocator: \(destURL.path) did not quit — activating it instead of replacing it")
                running.activate(options: [.activateIgnoringOtherApps])
                DispatchQueue.main.async { NSApp.terminate(nil) }
                return false
            }
        }

        // 2. MOVE, and 3. WAIT for it to really finish.
        do {
            // macOS can answer the first attempt with "not permitted" while its own permission prompt is up; keep trying
            // for up to a minute so the move completes once the user clicks Allow, instead of giving up under the prompt.
            try retryWhileAwaitingPermission(timeout: 60, interval: 1.5,
                                             onWaiting: { glog("AppRelocator: waiting for permission to write \(destURL.path)…") }) {
                try install(currentURL, replacing: destURL)
            }
        } catch {
            glog("AppRelocator: copy to \(destURL.path) failed: \(error)", level: .error)
            let failAlert = NSAlert()
            failAlert.alertStyle = .warning
            failAlert.messageText = "Couldn't Move to Applications"
            failAlert.informativeText = "\(error.localizedDescription)\n\nIf macOS asked for permission, allow it (System Settings → Privacy & Security → App Management) and open \(displayName) again — or drag \(bundleName) into Applications yourself."
            failAlert.runModal()
            return true
        }

        // 3b. The move is only done once the new copy is really there; otherwise stay put rather than relaunch into nothing.
        let installedExecutable = destURL.appendingPathComponent("Contents/MacOS/\(Bundle.main.executableURL?.lastPathComponent ?? "hdhr_VCR")")
        guard fm.fileExists(atPath: installedExecutable.path) else {
            glog("AppRelocator: \(installedExecutable.path) is missing after the copy — not relaunching", level: .error)
            return true
        }

        // Best-effort cleanup of the source — never blocks the relaunch on failure. Skipped for a
        // Gatekeeper-translocated path (randomized /private/var/folders/.../AppTranslocation/...
        // mirror of a quarantined download): it's a virtual read-only view, not the user's real
        // download, so there's nothing meaningful there to trash.
        if !currentURL.path.contains("/AppTranslocation/") {
            do {
                try fm.trashItem(at: currentURL, resultingItemURL: nil)
            } catch {
                glog("AppRelocator: could not trash original at \(currentURL.path): \(error)")
            }
        }

        // 4. LAUNCH the moved copy, and quit this one once it has started.
        glog("AppRelocator: moved to \(destURL.path), relaunching")
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destURL, configuration: config) { _, error in
            if let error {
                // Keep this instance alive — quitting now would leave the user with no running app.
                glog("AppRelocator: relaunch from \(destURL.path) failed: \(error)", level: .error)
                return
            }
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
        return false
        #endif
    }
}
