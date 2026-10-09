import AppKit

// Classic "you launched me from the DMG/Downloads instead of dragging me to Applications" check —
// see docs/Distribution.md's "First install" flow (step 3, drag to /Applications, is a manual step
// users routinely skip). Runs only in notarized release builds (#if !DEBUG) so ./deploy.sh's
// dev workflow, which always runs the app in place from the repo root, is never affected.
enum AppRelocator {

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

    /// If the running .app isn't inside an Applications folder (system or per-user), offers to
    /// copy it there, relaunch from the new location, and quit this instance.
    static func relocateToApplicationsIfNeeded() {
        #if DEBUG
        return
        #else
        let fm = FileManager.default
        let currentURL = URL(fileURLWithPath: Bundle.main.bundlePath).standardizedFileURL
        guard currentURL.pathExtension == "app" else { return }   // bare binary, no bundle — dev only

        let applicationsDirs = fm.urls(for: .applicationDirectory, in: .allDomainsMask)
            .map { $0.standardizedFileURL.path }
        let currentParent = currentURL.deletingLastPathComponent().path
        guard !applicationsDirs.contains(currentParent) else { return }   // already installed correctly
        guard !isInsideGitCheckout(currentURL) else { return }            // a developer's repo build — never offer to move/trash it

        let bundleName = currentURL.lastPathComponent
        let destURL = URL(fileURLWithPath: "/Applications").appendingPathComponent(bundleName)
        let displayName = bundleName.replacingOccurrences(of: ".app", with: "")

        let alert = NSAlert()
        alert.messageText = "Move to Applications Folder?"
        alert.informativeText = "\(displayName) is running from \(currentURL.deletingLastPathComponent().path), not your Applications folder. Move it to Applications and relaunch?"
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Don't Move")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            glog("AppRelocator: user declined move from \(currentURL.path)")
            return
        }

        // An install that's already running must not be swapped out from under its own process (and a
        // second instance would fight this one for port 1980): just bring it forward and quit this one.
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                            && $0.bundleURL?.standardizedFileURL == destURL.standardizedFileURL }) {
            glog("AppRelocator: \(destURL.path) is already running — activating it instead of replacing it")
            running.activate(options: [.activateIgnoringOtherApps])
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return
        }

        do {
            try install(currentURL, replacing: destURL)
        } catch {
            glog("AppRelocator: copy to \(destURL.path) failed: \(error)", level: .error)
            let failAlert = NSAlert()
            failAlert.alertStyle = .warning
            failAlert.messageText = "Couldn't Move to Applications"
            failAlert.informativeText = "\(error.localizedDescription)\n\nYou can manually drag \(bundleName) into Applications."
            failAlert.runModal()
            return
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

        glog("AppRelocator: moved to \(destURL.path), relaunching")
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destURL, configuration: config) { _, error in
            if let error {
                glog("AppRelocator: relaunch from \(destURL.path) failed: \(error)", level: .error)
            }
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
        #endif
    }
}
