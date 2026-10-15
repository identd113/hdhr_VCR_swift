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
        defer { MockRecording.clean(); closeStrayWindows() }

        clickAppMenuItem("Watch Now…")
        #expect(waitFor(8) { axWindows().contains("Watch Now") } != nil, "Watch Now never opened")
        #expect(!axFound("role=AXButton&help^=Play the in-progress recording", window: "Watch Now"),
                "relay buttons present before anything is recording")

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
}
