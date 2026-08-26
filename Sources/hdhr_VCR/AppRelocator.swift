import AppKit

// Classic "you launched me from the DMG/Downloads instead of dragging me to Applications" check —
// see docs/Distribution.md's "First install" flow (step 3, drag to /Applications, is a manual step
// users routinely skip). Runs only in notarized release builds (#if !DEBUG) so ./deploy.sh's
// dev workflow, which always runs the app in place from the repo root, is never affected.
enum AppRelocator {

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

        do {
            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)   // replace a stale prior install
            }
            try fm.copyItem(at: currentURL, to: destURL)
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
