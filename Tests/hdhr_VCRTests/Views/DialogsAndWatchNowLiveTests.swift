import AppKit
import Foundation
import Testing

// Live UI tests for the two things that broke the app in practice and had no coverage:
//   • Dialogs must never block the main thread (`Dialogs`, Views/Dialogs.swift): a modal alert froze the web server,
//     the guide and every FEED viewer until someone clicked OK (2026-10-14).
//   • Watch Now must show a recording's relay buttons the moment the recording starts, with the window already open
//     (rows move between `LazyVStack` sections; a stale row kept "scheduled to record" until a relaunch).
//
// Same opt-in as the rest of WindowNavigationTests (RUN_WINDOW_NAV_TESTS=1, running app, Accessibility). They live in an
// extension of that suite so they are `.serialized` with it — two tests driving the one app's windows must not overlap.
// Every lookup goes through `tools/ax_query.swift` (native AXUIElement, ~0.1 s) — never `entire contents`, which returns
// an empty list on this macOS build and would make a test pass without checking anything.

// MARK: - helpers (file-private)

/// Runs `ax_query <args>` and returns (exit status, stdout).
private func ax(_ args: [String]) -> (status: Int32, out: String) {
    guard !axQueryPath.isEmpty else { return (-1, "") }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: axQueryPath)
    task.arguments = args
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    guard (try? task.run()) != nil else { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return (task.terminationStatus, String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
}

private func axWindows() -> [String] { ax(["windows"]).out.split(separator: "\n").map(String.init) }
private func axHasText(_ s: String, window: String = "") -> Bool { ax(["text", window, s]).status == 0 }
private func axFound(_ match: String, window: String = "") -> Bool { ax(["find", window, match]).status == 0 }
@discardableResult private func axPress(_ match: String, window: String = "", last: Bool = false) -> Bool {
    ax(["find", window, match, "--press"] + (last ? ["--last"] : [])).status == 0
}

/// Human pace: a real person leaves a second or two between actions, and the app (recording teardown, Watch Now rows,
/// menu rebuilds) needs about that long to settle. Rushing straight from one step to the next races it.
private func humanPause(_ seconds: TimeInterval = 1.5) { Thread.sleep(forTimeInterval: seconds) }

/// After `MockRecording.clean()` / closing windows: wait (up to 15 s) until the app reports nothing recording, then pause
/// like a person would before the next action.
private func settleBeforeNextAction() {
    _ = waitFor(15) { !MockRecording.isRecording }
    humanPause(2)
}

/// The app's CPU once it has settled: reads up to `attempts` times (each reading itself averages ~6 s) and stops at the first one
/// under `limit`. A transient spike (recording stop/start, a teardown, a guide rebuild) passes on a later reading; a sustained
/// problem — a window that keeps rendering — stays high on every reading and still fails. Returns every reading.
private func settledCPU(below limit: Double, attempts: Int = 4) -> [Double]? {
    var readings: [Double] = []
    for _ in 0..<attempts {
        guard let cpu = appCPUPercent() else { return nil }
        readings.append(cpu)
        if cpu < limit { break }
    }
    return readings
}

/// The player window's height in points, read through System Events (nil when it can't be read).
private func playerWindowHeight(_ title: String) -> Double? {
    let escaped = title.replacingOccurrences(of: "\"", with: "\\\"")
    let out = runAppleScript("""
    tell application "System Events" to tell process "hdhr_VCR" to return (item 2 of (get size of window "\(escaped)")) as text
    """)
    return out.flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
}

/// Polls `condition` every 0.1 s; returns the seconds it took, or nil if it never became true within `timeout`.
private func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) -> TimeInterval? {
    let start = Date()
    while Date().timeIntervalSince(start) < timeout {
        if condition() { return Date().timeIntervalSince(start) }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return condition() ? Date().timeIntervalSince(start) : nil
}

/// Time for `GET /` on the app's own web server (a main-actor-dependent route), or nil if it didn't answer in `timeout`.
private func webLatency(timeout: TimeInterval = 5) -> TimeInterval? {
    guard let url = URL(string: "http://localhost:1980/") else { return nil }
    var request = URLRequest(url: url)
    request.timeoutInterval = timeout
    let done = DispatchSemaphore(value: 0)
    var ok = false
    let start = Date()
    URLSession.shared.dataTask(with: request) { _, response, _ in
        ok = (response as? HTTPURLResponse)?.statusCode == 200
        done.signal()
    }.resume()
    _ = done.wait(timeout: .now() + timeout + 1)
    return ok ? Date().timeIntervalSince(start) : nil
}

/// Clicks an item in the app's menu-bar menu.
private func clickAppMenuItem(_ name: String) {
    _ = runAppleScript("""
    tell application "System Events" to tell process "hdhr_VCR" to click menu item "\(name)" of menu 1 of menu bar item 1 of menu bar 2
    """)
}

/// Selects a Settings sidebar row by its label (Settings reopens on whichever tab was used last, so a test can't assume one).
private func selectSettingsTab(_ name: String) {
    _ = runAppleScript("""
    tell application "System Events" to tell process "hdhr_VCR"
        set rowRef to outline 1 of scroll area 1 of group 1 of splitter group 1 of group 1 of window 1
        repeat with i from 1 to (count of rows of rowRef)
            if (name of static text 1 of UI element 1 of row i of rowRef) is "\(name)" then
                set value of attribute "AXSelected" of row i of rowRef to true
                exit repeat
            end if
        end repeat
    end tell
    """)
}

/// The launch splash's full-screen window (layer 101, the pop-up-menu level). `onScreenOnly: false` also counts a window that
/// still exists but is ordered out — which after `LaunchSplashController.release()` must not be the case at all.
private func launchSplashWindow(pid: pid_t, onScreenOnly: Bool) -> Bool {
    let list = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
    return list.contains {
        guard ($0[kCGWindowOwnerPID as String] as? pid_t) == pid, ($0[kCGWindowLayer as String] as? Int) == 101 else { return false }
        return !onScreenOnly || ($0[kCGWindowIsOnscreen as String] as? Bool ?? (($0[kCGWindowIsOnscreen as String] as? Int) == 1))
    }
}

private func skip(_ why: String) { FileHandle.standardError.write("SKIP: \(why)\n".data(using: .utf8)!) }

// MARK: - tests

extension WindowNavigationTests {

    /// A recording that starts while Watch Now is already open must turn its row into "<title>, recording now" with the
    /// two relay buttons within a few seconds — no reopening, no relaunch. Regression for the stale-row bug
    /// (`WatchNowView.channelRow`'s `.id`): the parent computed `.recording`, the row kept rendering `.scheduled`.
    @Test func watchNowRowGainsRelayButtonsWhenARecordingStartsWithTheWindowOpen() throws {
        guard windowNavTestsOptedIn(), appRunning(), accessibilityTrusted() else { return }
        if let why = MockRecording.realRecordingConflict() { skip(why); return }
        MockRecording.clean()
        closeStrayWindows()
        settleBeforeNextAction()
        defer { MockRecording.clean(); closeStrayWindows() }

        clickAppMenuItem("Watch Now…")
        #expect(waitFor(8) { axWindows().contains("Watch Now") } != nil, "Watch Now never opened")
        humanPause()   // let the window finish its first render before looking for buttons
        let preFound = ax(["find", "Watch Now", "role=AXButton&help^=Play the in-progress recording"])
        #expect(preFound.status != 0,
                "relay buttons present before anything is recording — windows: \(axWindows()); found: \(preFound.out); mock recording: \(MockRecording.isRecording)")

        guard let started = MockRecording.ensure() else { skip("nothing airing / no free tuner"); return }
        let title = started.range(of: #"\[MOCK\] (.+?)_[0-9.]+_\d{8}_\d{4}\.ts"#, options: .regularExpression)
            .map { String(started[$0]).replacingOccurrences(of: "[MOCK] ", with: "")
                .replacingOccurrences(of: #"_[0-9.]+_\d{8}_\d{4}\.ts"#, with: "", options: .regularExpression) }

        let took = waitFor(15) { axFound("role=AXButton&help^=Play the in-progress recording", window: "Watch Now") }
        #expect(took != nil, "Watch Now never offered the relay buttons for the recording that started under it")
        if let took { #expect(took < 10, "relay buttons took \(took)s to appear") }
        if let title {
            #expect(axHasText("\(title), recording now", window: "Watch Now"),
                    "row for '\(title)' should read 'recording now' (not 'scheduled to record')")
            #expect(!axHasText("\(title), scheduled to record", window: "Watch Now"), "stale 'scheduled to record' row")
        }
    }

    /// The unsaved-changes prompt is a sheet on the Settings window: the window refuses to close, the web server keeps
    /// answering while it is up (a `runModal()` froze it), Cancel keeps the window and Discard closes it.
    @Test func unsavedSettingsPromptIsASheetAndTheWebServerKeepsAnswering() throws {
        guard windowNavTestsOptedIn(), appRunning(), accessibilityTrusted() else { return }
        closeStrayWindows()
        clickAppMenuItem("Settings…")
        guard waitFor(8, { !axWindows().isEmpty }) != nil else { Issue.record("Settings never opened"); return }
        selectSettingsTab("General")
        #expect(waitFor(5) { axFound("role=AXCheckBox") } != nil, "General tab has no switches to flip")
        // If an earlier session left a dirty draft, flipping a switch could clean it instead of dirtying it.
        if axHasText("Unsaved changes") { skip("Settings already has an unsaved draft"); closeStrayWindows(); return }
        defer {
            _ = axPress("role=AXButton&title=Discard", last: true)   // a sheet left up must not outlive the test
            closeStrayWindows()
        }

        #expect(axPress("role=AXCheckBox"), "no checkbox to flip in Settings")
        #expect(waitFor(3) { axHasText("Unsaved changes") } != nil, "flipping a switch should mark the draft dirty")
        let windowsBefore = axWindows()

        _ = runAppleScript("""
        tell application "System Events" to tell process "hdhr_VCR" to click (first button of window 1 whose description is "close button")
        """)
        #expect(waitFor(5) { axHasText("Unsaved Settings") } != nil, "closing a dirty Settings window should ask first")
        #expect(axWindows() == windowsBefore, "the window must stay open while the prompt is up")
        if let latency = webLatency() { #expect(latency < 1.0, "web server took \(latency)s while the prompt was up") }
        else { Issue.record("web server did not answer while the unsaved-changes prompt was up (a modal alert?)") }

        // Cancel keeps the window, dismisses only the sheet.
        #expect(axPress("role=AXButton&title=Cancel", last: true), "no Cancel button on the prompt")
        #expect(waitFor(3) { !axHasText("Unsaved Settings") } != nil, "Cancel should dismiss the prompt")
        #expect(axWindows() == windowsBefore, "Cancel must leave the Settings window open")

        // Put the switch back so nothing is left dirty, then close without a prompt.
        #expect(axPress("role=AXCheckBox"))
        #expect(waitFor(3) { !axHasText("Unsaved changes") } != nil, "flipping it back should clean the draft")
        _ = runAppleScript("""
        tell application "System Events" to tell process "hdhr_VCR" to click (first button of window 1 whose description is "close button")
        """)
        #expect(waitFor(5) { axWindows().isEmpty } != nil, "a clean Settings window should close straight away")
    }

    /// Quitting with a recording running asks first — in a window that does not block the main thread — "Go Back"
    /// cancels, a second click on Quit does not stack a second prompt, and the app and recording are untouched.
    @Test func quitPromptDoesNotBlockAndGoBackKeepsTheAppAndTheRecording() throws {
        guard windowNavTestsOptedIn(), appRunning(), accessibilityTrusted() else { return }
        if let why = MockRecording.realRecordingConflict() { skip(why); return }
        MockRecording.clean()
        closeStrayWindows()
        guard MockRecording.ensure() != nil else { skip("nothing airing / no free tuner"); return }
        defer {
            _ = axPress("role=AXButton&title=Go Back")
            MockRecording.clean()
            closeStrayWindows()
        }

        clickAppMenuItem("Quit hdhrVCRplus")
        #expect(waitFor(6) { axHasText("Recordings in progress") } != nil, "quitting during a recording should ask first")
        if let latency = webLatency() { #expect(latency < 1.0, "web server took \(latency)s while the quit prompt was up") }
        else { Issue.record("web server did not answer while the quit prompt was up (a modal alert?)") }

        clickAppMenuItem("Quit hdhrVCRplus")   // second click: must not stack another prompt
        Thread.sleep(forTimeInterval: 1)
        #expect(ax(["count", "", "role=AXButton&title=Go Back"]).out == "1", "a second Quit click stacked another prompt")

        #expect(axPress("role=AXButton&title=Go Back"), "no Go Back button")
        #expect(waitFor(4) { !axHasText("Recordings in progress") } != nil, "Go Back should dismiss the prompt")
        #expect(appRunning(), "Go Back must not quit the app")
        #expect(MockRecording.isRecording, "Go Back must not stop the recording")
    }

    /// Export Config… opens its save panel as a sheet: the web server keeps answering and Cancel dismisses it.
    @Test func exportConfigPanelIsASheetAndTheWebServerKeepsAnswering() throws {
        guard windowNavTestsOptedIn(), appRunning(), accessibilityTrusted() else { return }
        closeStrayWindows()
        clickAppMenuItem("Settings…")
        guard waitFor(8, { !axWindows().isEmpty }) != nil else { Issue.record("Settings never opened"); return }
        defer {
            _ = axPress("role=AXButton&title=Cancel", last: true)
            closeStrayWindows()
        }
        selectSettingsTab("Advanced")
        #expect(waitFor(5) { axFound("role=AXButton&title=Export Config…") } != nil, "Export Config… button not found on the Advanced tab")
        #expect(axPress("role=AXButton&title=Export Config…"))
        #expect(waitFor(5) { axFound("role=AXButton&title=Cancel") } != nil, "the save panel never appeared")
        if let latency = webLatency() { #expect(latency < 1.0, "web server took \(latency)s while the save panel was up") }
        else { Issue.record("web server did not answer while the save panel was up (a modal panel?)") }
        #expect(axPress("role=AXButton&title=Cancel", last: true))
        #expect(waitFor(4) { !axFound("role=AXButton&title=Cancel") } != nil, "Cancel should dismiss the save panel")
    }

    /// The main thread must stay responsive: a main-actor-dependent web route is probed every 100 ms for 20 s. A blocking
    /// dialog, a hung disk call or a long synchronous scan shows up as a multi-second gap (the idle tick's ~0.6 s
    /// stall every 10 s is the known baseline — see ISSUES.md; anything over 2.5 s is a regression).
    @Test func mainThreadStaysResponsive() throws {
        guard windowNavTestsOptedIn(), appRunning() else { return }
        var worst: TimeInterval = 0
        var failures = 0
        var samples = 0
        let end = Date().addingTimeInterval(20)
        while Date() < end {
            if let latency = webLatency(timeout: 6) { worst = max(worst, latency) } else { failures += 1 }
            samples += 1
            Thread.sleep(forTimeInterval: 0.1)
        }
        #expect(failures == 0, "\(failures) of \(samples) probes got no answer")
        #expect(worst < 2.5, "worst probe took \(worst)s — the main thread was blocked")
    }

    /// An idle app (nothing recording, no windows open) must be idle. The launch splash's `MosaicTiles` `TimelineView` kept
    /// rendering an invisible poster wall after the splash was dismissed — a dismissed `Window` scene is only ordered out,
    /// its view graph lives on — which cost ~21 % CPU at idle and a ~0.6 s main-thread stall every 10 s
    /// (found 2026-10-15 with `sample`; fixed by tearing the wall down in `LaunchSplashView.finish()`).
    /// Measured with `top -l 2` (the second sample is a real interval, not a lifetime average).
    @Test func idleAppUsesAlmostNoCPU() throws {
        guard windowNavTestsOptedIn(), appRunning() else { return }
        if let why = MockRecording.realRecordingConflict(leadMinutes: 1) { skip(why); return }
        MockRecording.clean()
        closeStrayWindows()
        Thread.sleep(forTimeInterval: 3)   // let anything the previous test did settle
        guard let cpu = appCPUPercent() else { Issue.record("could not read the app's CPU from top"); return }
        #expect(cpu < 5, "idle app at \(cpu)% CPU — something is rendering or polling while nothing is on screen")
    }

    /// Same promise while a recording runs with no window open: the hidden windows (Settings, Watch Now, Add Show…) must
    /// not re-render on every state change. Measured 0.4–2 % when this was written; the budget leaves room for the
    /// menu-bar icon's recording blink and the status polling.
    @Test func recordingAppWithNoWindowsUsesLittleCPU() throws {
        guard windowNavTestsOptedIn(), appRunning() else { return }
        if let why = MockRecording.realRecordingConflict() { skip(why); return }
        MockRecording.clean()
        closeStrayWindows()
        defer { MockRecording.clean() }
        settleBeforeNextAction()
        guard MockRecording.ensure() != nil else { skip("nothing airing / no free tuner"); return }
        // Recording start, Discord card and grid rebuilds spike the CPU for several seconds (50–80 % seen) and then it falls
        // to ~0. Give it up to ~30 s (each reading itself averages 6 s) and require the steady state to be low.
        Thread.sleep(forTimeInterval: 8)
        guard let readings = settledCPU(below: 10) else { Issue.record("could not read the app's CPU from top"); return }
        #expect(readings.last! < 10, "app still at \(readings.last!)% CPU with a recording and no windows after settling (readings \(readings)) — hidden windows are probably re-rendering")
    }
}

extension WindowNavigationTests {

    /// The launch splash (Settings → Maintenance → Preview Launch Splash) plays, ends, and leaves nothing running — twice.
    /// When it ends the window is destroyed (`LaunchSplashController.release()`), not merely ordered out, so the second play proves a
    /// replay builds a fresh one. Before that (a SwiftUI `Window` scene, which is never destroyed) the dismissed window kept animating invisibly: ~21 % idle CPU and a 0.6 s main-thread
    /// stall every 10 s. Uses the same button a user does; the splash window is found through CoreGraphics (layer 101, on screen).
    @Test func launchSplashPlaysEndsAndLeavesNothingRunning() throws {
        guard windowNavTestsOptedIn(), appRunning(), accessibilityTrusted() else { return }
        if let why = MockRecording.realRecordingConflict(leadMinutes: 1) { skip(why); return }
        MockRecording.clean()
        closeStrayWindows()
        settleBeforeNextAction()
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.hdhr.vcrplus" }) else { return }
        let pid = app.processIdentifier
        clickAppMenuItem("Settings…")
        guard waitFor(8, { !axWindows().isEmpty }) != nil else { Issue.record("Settings never opened"); return }
        defer { closeStrayWindows() }
        selectSettingsTab("Maintenance")
        guard waitFor(5, { axFound("text=Preview Launch Splash") }) != nil else { Issue.record("no Preview Launch Splash row in Maintenance"); return }

        Thread.sleep(forTimeInterval: 2)
        if let before = settledCPU(below: 5) { #expect(before.last! < 5, "app still at \(before.last!)% CPU before the splash (readings \(before))") }

        for play in 1...2 {
            #expect(ax(["row", "", "text=Preview Launch Splash", "role=AXButton&title=Run", "--press"]).status == 0, "could not press Run (play \(play))")
            #expect(waitFor(6) { launchSplashWindow(pid: pid, onScreenOnly: true) } != nil, "play \(play): the splash never appeared on screen")
            #expect(waitFor(30) { !launchSplashWindow(pid: pid, onScreenOnly: false) } != nil,
                    "play \(play): the splash window still exists after it finished — it should be destroyed, not just hidden")
            #expect(appRunning() && app.isTerminated == false, "play \(play): the app died during the splash")
            Thread.sleep(forTimeInterval: 2)   // let the teardown and the last frame settle
            if let after = settledCPU(below: 5, attempts: 3) {
                #expect(after.last! < 5, "play \(play): app at \(after.last!)% CPU after the splash ended (readings \(after)) — the poster wall is still rendering")
            } else { Issue.record("could not read the app's CPU from top") }
        }
    }
}

/// The app's CPU over a real 6 s interval (`top -l 2`; the second sample is a delta, not a lifetime average).
private func appCPUPercent() -> Double? {
    guard let pid = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.hdhr.vcrplus" })?.processIdentifier
    else { return nil }
    let top = Process()
    top.executableURL = URL(fileURLWithPath: "/usr/bin/top")
    top.arguments = ["-l", "2", "-s", "6", "-pid", "\(pid)", "-stats", "cpu"]
    let pipe = Pipe()
    top.standardOutput = pipe
    top.standardError = FileHandle.nullDevice
    guard (try? top.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    top.waitUntilExit()
    return (String(data: data, encoding: .utf8) ?? "").split(separator: "\n")
        .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }.last
}

extension WindowNavigationTests {

    /// The status bar toggle in the real player (docs/VLCPlayerView.md, "Status bar"): pressing it draws the bar under the
    /// video — its health line and next-show area are reachable — and grows the window by exactly the bar's 52 pt, so the
    /// video keeps its size; pressing again removes the bar and the window shrinks back. Uses a recording relay session
    /// (the always-available live session here), so the bar's source reads "From disk", not a tuner.
    @Test func statusBarToggleShowsTheBarAndResizesTheWindow() throws {
        guard windowNavTestsOptedIn(), appRunning(), accessibilityTrusted() else { return }
        if let why = MockRecording.realRecordingConflict() { skip(why); return }
        MockRecording.clean()
        closeStrayWindows()
        defer { MockRecording.clean(); closeStrayWindows() }
        guard MockRecording.ensure() != nil else { skip("nothing airing / no free tuner"); return }

        clickAppMenuItem("Watch Now…")
        #expect(waitFor(8) { axWindows().contains("Watch Now") } != nil, "Watch Now never opened")
        #expect(waitFor(15) { axPress("role=AXButton&help^=Play the in-progress recording", window: "Watch Now") } != nil,
                "Watch Now never offered the recording's relay button")
        var found: String?
        _ = waitFor(10) { found = axWindows().first { $0 != "Watch Now" }; return found != nil }
        guard let title = found else { Issue.record("the player window never opened"); return }
        Thread.sleep(forTimeInterval: 2)   // the toolbar's AX subtree fills in after the window itself

        let bar = "id=vlc-status-bar", toggle = "id=vlc-status-bar-toggle"
        // The choice is remembered across launches, so first bring it to a known "off".
        // A stream that just opened shows the bar briefly by itself; let that finish (a click during it would keep it).
        _ = waitFor(14) { !axFound(bar, window: title) }
        Thread.sleep(forTimeInterval: 1.5)
        if axFound(bar, window: title) {   // a saved "on": switch it off
            #expect(axPress(toggle, window: title), "could not press the status bar toggle to switch it off")
            #expect(waitFor(5) { !axFound(bar, window: title) } != nil, "the bar did not go away")
            Thread.sleep(forTimeInterval: 1.5)
        }
        guard let before = playerWindowHeight(title) else { Issue.record("could not read the player window's height"); return }

        #expect(axPress(toggle, window: title), "could not press the status bar toggle")
        #expect(waitFor(6) { axFound(bar, window: title) } != nil, "the status bar never appeared")
        #expect(waitFor(4) { axFound("id=vlc-status-title", window: title) } != nil, "the bar has no title block")
        Thread.sleep(forTimeInterval: 1)   // the window's resize animation
        if let grown = playerWindowHeight(title) {
            #expect(abs((grown - before) - 52) <= 3, "window grew by \(grown - before) pt, expected the bar's 52 pt")
        } else { Issue.record("could not read the window's height with the bar on") }

        #expect(axPress(toggle, window: title), "could not press the status bar toggle to switch it off again")
        #expect(waitFor(5) { !axFound(bar, window: title) } != nil, "the bar did not go away the second time")
        Thread.sleep(forTimeInterval: 1)
        if let after = playerWindowHeight(title) {
            #expect(abs(after - before) <= 3, "window did not shrink back (\(before) -> \(after))")
        }
    }
}

extension WindowNavigationTests {

    /// Regression (code review): the player window is recreated at its default size after being closed, while the window
    /// manager is a singleton. With the bar on, closing and reopening the player must give a window that is again the
    /// default size plus the bar's 52 pt, not one that thinks it already grew.
    @Test func statusBarStaysSizedAfterClosingAndReopeningThePlayer() throws {
        guard windowNavTestsOptedIn(), appRunning(), accessibilityTrusted() else { return }
        if let why = MockRecording.realRecordingConflict() { skip(why); return }
        MockRecording.clean()
        closeStrayWindows()
        defer { MockRecording.clean(); closeStrayWindows() }
        guard MockRecording.ensure() != nil else { skip("nothing airing / no free tuner"); return }

        func openPlayer() -> String? {
            clickAppMenuItem("Watch Now…")
            guard waitFor(8, { axWindows().contains("Watch Now") }) != nil,
                  waitFor(15, { axPress("role=AXButton&help^=Play the in-progress recording", window: "Watch Now") }) != nil else { return nil }
            var found: String?
            _ = waitFor(10) { found = axWindows().first { $0 != "Watch Now" }; return found != nil }
            Thread.sleep(forTimeInterval: 2)
            return found
        }
        let bar = "id=vlc-status-bar", toggle = "id=vlc-status-bar-toggle"

        guard let first = openPlayer() else { Issue.record("the player never opened"); return }
        _ = waitFor(14) { !axFound(bar, window: first) }   // the opening peek retracts by itself
        Thread.sleep(forTimeInterval: 1.5)
        if axFound(bar, window: first) { _ = axPress(toggle, window: first); _ = waitFor(5) { !axFound(bar, window: first) }; Thread.sleep(forTimeInterval: 1.5) }
        guard let base = playerWindowHeight(first) else { Issue.record("could not read the window height"); return }
        #expect(axPress(toggle, window: first), "could not switch the bar on")
        #expect(waitFor(6) { axFound(bar, window: first) } != nil, "the bar never appeared")
        Thread.sleep(forTimeInterval: 1)

        // Close the player (Watch Now stays open), then open a fresh one.
        closePlayerWindowOnly(first)
        guard waitFor(8, { !axWindows().contains(first) }) != nil else { Issue.record("the player window did not close"); return }
        guard let second = openPlayer() else { Issue.record("the player did not reopen"); return }
        #expect(waitFor(6) { axFound(bar, window: second) } != nil, "the remembered bar was not drawn in the reopened player")
        Thread.sleep(forTimeInterval: 1)
        if let height = playerWindowHeight(second) {
            #expect(abs(height - (base + 52)) <= 3, "reopened window is \(height) pt tall, expected the default \(base) + 52")
        } else { Issue.record("could not read the reopened window's height") }

        // Leave the preference off.
        _ = axPress(toggle, window: second)
        _ = waitFor(5) { !axFound(bar, window: second) }
    }
}

/// Closes just the named window, leaving Watch Now and others open.
private func closePlayerWindowOnly(_ title: String) {
    let escaped = title.replacingOccurrences(of: "\"", with: "\\\"")
    _ = runAppleScript("""
    tell application "System Events" to tell process "hdhr_VCR"
        try
            click (first button of window "\(escaped)" whose description is "close button")
        end try
    end tell
    """)
}

extension WindowNavigationTests {

    /// The player's Zoom (Window ▸ Zoom, same as Option-clicking the green button) snaps the window to the picture's native
    /// size and the next Zoom returns to the size it had — `VLCPlayerWindowManager.standardFrame`. Uses the mock
    /// recording relay, whose picture is smaller than the default window, so the zoomed window is visibly smaller.
    @Test func zoomTogglesBetweenNativeSizeAndTheEarlierSize() throws {
        guard windowNavTestsOptedIn(), appRunning(), accessibilityTrusted() else { return }
        if let why = MockRecording.realRecordingConflict() { skip(why); return }
        MockRecording.clean()
        closeStrayWindows()
        defer { MockRecording.clean(); closeStrayWindows() }
        guard MockRecording.ensure() != nil else { skip("nothing airing / no free tuner"); return }

        clickAppMenuItem("Watch Now…")
        #expect(waitFor(8) { axWindows().contains("Watch Now") } != nil, "Watch Now never opened")
        #expect(waitFor(15) { axPress("role=AXButton&help^=Play the in-progress recording", window: "Watch Now") } != nil,
                "Watch Now never offered the recording's relay button")
        var found: String?
        _ = waitFor(10) { found = axWindows().first { $0 != "Watch Now" }; return found != nil }
        guard let title = found else { Issue.record("the player window never opened"); return }
        Thread.sleep(forTimeInterval: 4)   // a decoded frame must exist before Zoom knows the native size

        func size() -> String {
            runAppleScript("tell application \"System Events\" to tell process \"hdhr_VCR\" to return (get size of window \"\(title)\") as text") ?? "?"
        }
        func zoom() {
            _ = runAppleScript("tell application \"System Events\" to tell process \"hdhr_VCR\" to click menu item \"Zoom\" of menu \"Window\" of menu bar item \"Window\" of menu bar 1")
            Thread.sleep(forTimeInterval: 2)   // the zoom animation
        }
        let before = size()
        zoom()
        let zoomed = size()
        #expect(zoomed != before, "Zoom did not resize the player window (\(before))")
        zoom()
        #expect(size() == before, "a second Zoom did not return to the earlier size: \(before) → \(zoomed) → \(size())")
    }
}

extension WindowNavigationTests {

    /// A stream that opens with the status bar off pops the bar down for about 5 s (the window grows by the bar's height),
    /// then it goes away on its own and the window returns to its first height.
    @Test func statusBarSlidesInBrieflyWhenAStreamOpens() throws {
        guard windowNavTestsOptedIn(), appRunning(), accessibilityTrusted() else { return }
        if let why = MockRecording.realRecordingConflict() { skip(why); return }
        MockRecording.clean()
        closeStrayWindows()
        defer { MockRecording.clean(); closeStrayWindows() }
        guard MockRecording.ensure() != nil else { skip("nothing airing / no free tuner"); return }
        // The persistent choice is remembered across launches; this test is about the bar being off.
        _ = runAppleScript("do shell script \"defaults write com.hdhr.vcrplus playerStatusBarVisible -bool false\"")

        clickAppMenuItem("Watch Now…")
        #expect(waitFor(8) { axWindows().contains("Watch Now") } != nil, "Watch Now never opened")
        #expect(waitFor(15) { axPress("role=AXButton&help^=Play the in-progress recording", window: "Watch Now") } != nil,
                "Watch Now never offered the recording's relay button")
        var found: String?
        _ = waitFor(10) { found = axWindows().first { $0 != "Watch Now" }; return found != nil }
        guard let title = found else { Issue.record("the player window never opened"); return }

        let bar = "id=vlc-status-bar"
        let before = playerWindowHeight(title) ?? 0
        #expect(waitFor(12) { axFound(bar, window: title) } != nil, "the status bar never popped down when the stream opened")
        Thread.sleep(forTimeInterval: 2.0)   // the pop-down (and any aspect re-fit for the stream's shape) has finished
        let open = playerWindowHeight(title) ?? 0
        #expect(open > before - 1, "the window did not grow for the bar")
        #expect(waitFor(14) { !axFound(bar, window: title) } != nil, "the status bar did not go away again")
        Thread.sleep(forTimeInterval: 1.5)
        let closed = playerWindowHeight(title) ?? 0
        // The bar's row is 52 pt; the window gives exactly that back.
        #expect(abs((open - closed) - 52) <= 2, "the window did not give back the bar's height (open \(open), closed \(closed))")
    }
}
