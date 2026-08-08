import Testing
import Foundation
import AppKit
@testable import hdhr_VCR

// MARK: - Window navigation smoke test
//
// Drives the actual running app's real windows via the macOS Accessibility API (same mechanism
// AppleScript/System Events uses) to confirm every reachable window still opens, navigates, and
// closes cleanly. Unlike every other test in this target, this one has real on-screen side
// effects — it pops the app's own windows open and closed on whatever screen the app happens to
// be running on — so unlike WebServerPerfTests (which only makes invisible HTTP calls and is
// safe to leave in a plain `swift test` run), this suite requires an explicit opt-in and does
// nothing under a bare `swift test`, even though the app is normally running throughout a dev
// session (an `appRunning()` guard alone would NOT prevent that — it'd actually run every time).
// Invoke it with:
//   RUN_WINDOW_NAV_TESTS=1 swift test --filter WindowNavigationTests
// Every test also guards with `appRunning()`/`accessibilityTrusted()` so a run against a stopped
// app, or a machine that hasn't granted Accessibility permission to whatever's running
// `swift test` (System Settings → Privacy & Security → Accessibility), skips cleanly instead of
// failing noisily.
//
// Implementation note: this shells out to `osascript` (AppleScript/System Events) via Process
// rather than calling the AXUIElement C API directly from Swift. Both need the same Accessibility
// permission, but osascript reuses whatever's already granted to Terminal/the shell running
// `swift test` — calling AXUIElement directly from the xctest process itself would need a
// *separate* first-time grant for that specific binary. Same "shell out to a real OS mechanism
// rather than reimplement it" pragmatism WebServerPerfTests applies via URLSession/HTTP, just for
// GUI automation instead of the network.
//
// A "Cable Guide" window (`Window("Cable Guide", id: "cable-guide")`) used to exist in
// hdhr_VCRApp.swift but had no remaining trigger anywhere in the app — a leftover from before
// AddShowView's guide step grew to embed the full-size web guide directly, which made popping it
// out into a second window redundant. Removed rather than covered here.
//
// Hard-won lesson (found writing this suite): a per-show submenu's `name of every menu item`
// output is NOT safe to split on commas or address by a manually-counted index — items like
// "11:37 PM · 60 min, tuner 105404BE" contain their own embedded comma, and the submenu's shape
// (Skip vs Pause, presence of "Show Recording in Finder") differs between a recording/scheduled/
// paused show. A first attempt at the Edit Show test, addressed by a manually-counted index,
// actually clicked "Delete…" on a real, live, currently-recording show and got as far as its
// confirmation dialog before being caught and cancelled — nothing was deleted, but it's why
// `editShowOpensAndCloses` below only ever matches submenu items by exact name ("Edit…"), never
// by position, and why it searches for whichever show's submenu happens to contain that item
// rather than assuming a fixed menu index for "the first show".

/// Runs `script` via `osascript -e`, returning trimmed stdout (empty string if the script itself
/// returned nothing) or nil if osascript exited non-zero.
private func runAppleScript(_ script: String) -> String? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", script]
    let outPipe = Pipe()
    task.standardOutput = outPipe
    task.standardError = Pipe()   // discarded — failures are reported via the nil return
    do {
        try task.run()
    } catch {
        return nil
    }
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func appRunning() -> Bool {
    NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.hdhr.vcrplus" }
}

/// Accessibility automation silently returns empty/failed results (rather than a clear error)
/// when the calling process isn't trusted — this gives tests a clean skip instead of a confusing
/// false failure. AXIsProcessTrusted() reflects whatever's running the test binary (Terminal,
/// typically), matching the permission `osascript` itself reuses (see file header).
private func accessibilityTrusted() -> Bool {
    AXIsProcessTrusted()
}

/// The actual enforcement behind "not part of a bare swift test" — appRunning() alone can't do
/// this, since the app is normally running throughout a dev session. Must be set explicitly:
///   RUN_WINDOW_NAV_TESTS=1 swift test --filter WindowNavigationTests
private func windowNavTestsOptedIn() -> Bool {
    ProcessInfo.processInfo.environment["RUN_WINDOW_NAV_TESTS"] == "1"
}

@Suite("Window navigation smoke test (requires running app + Accessibility permission — invoke via --filter, not part of default swift test)", .serialized)
struct WindowNavigationTests {

    @Test func settingsAllTabsReachable() throws {
        guard windowNavTestsOptedIn(), appRunning(), accessibilityTrusted() else { return }
        let script = #"""
        tell application "System Events"
            tell process "hdhr_VCR"
                click menu item "Settings…" of menu 1 of menu bar item 1 of menu bar 2
                delay 0.6
                set resultsStr to ""
                set rowCount to count of rows of outline 1 of scroll area 1 of group 1 of splitter group 1 of group 1 of window 1
                repeat with i from 1 to rowCount
                    -- Re-resolved every iteration, not cached: selecting a row rebuilds the
                    -- SwiftUI List's AX tree, which invalidates any reference captured before
                    -- the selection changed.
                    set r to row i of outline 1 of scroll area 1 of group 1 of splitter group 1 of group 1 of window 1
                    set lbl to name of static text 1 of UI element 1 of r
                    set value of attribute "AXSelected" of r to true
                    delay 0.5
                    set actualTitle to "?"
                    try
                        set actualTitle to name of window 1
                    end try
                    set resultsStr to resultsStr & lbl & "|" & actualTitle & linefeed
                end repeat
                try
                    click (first button of window 1 whose description is "close button")
                end try
                return resultsStr
            end tell
        end tell
        """#
        guard let result = runAppleScript(script), !result.isEmpty else {
            Issue.record("Settings navigation script produced no output — app running but automation failed?")
            return
        }
        let lines = result.split(separator: "\n")
        #expect(lines.count == 8, "expected 8 sidebar tabs, saw \(lines.count): \(result)")
        for line in lines {
            let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
            #expect(parts.count == 2 && parts[0] == parts[1],
                "tab label and resulting window title should match — got \(line)")
        }
    }

    @Test func addShowOpensAndCloses() throws {
        guard windowNavTestsOptedIn(), appRunning(), accessibilityTrusted() else { return }
        let (title, windowCountAfter) = try openAndCloseTopLevelWindow(menuItemName: "Add Show…")
        #expect(title == "Add Show")
        #expect(windowCountAfter == 0)
    }

    @Test func watchNowOpensAndCloses() throws {
        guard windowNavTestsOptedIn(), appRunning(), accessibilityTrusted() else { return }
        let (title, windowCountAfter) = try openAndCloseTopLevelWindow(menuItemName: "Watch Now…")
        #expect(title == "Watch Now")
        #expect(windowCountAfter == 0)
    }

    /// See the file header's "Hard-won lesson" — every lookup here matches by exact item name,
    /// never by position, after an index-based first draft nearly triggered a real delete on a
    /// live recording.
    @Test func editShowOpensAndCloses() throws {
        guard windowNavTestsOptedIn(), appRunning(), accessibilityTrusted() else { return }
        let script = #"""
        tell application "System Events"
            tell process "hdhr_VCR"
                set menuEl to menu 1 of menu bar item 1 of menu bar 2
                set n to count of menu items of menuEl
                set targetShow to missing value
                repeat with i from 1 to n
                    set mi to menu item i of menuEl
                    try
                        set subN to count of menu items of menu 1 of mi
                        set hasEdit to false
                        repeat with j from 1 to subN
                            set subNm to "?"
                            try
                                set subNm to name of menu item j of menu 1 of mi
                            end try
                            if subNm is "Edit…" then
                                set hasEdit to true
                                exit repeat
                            end if
                        end repeat
                        if hasEdit then
                            set targetShow to mi
                            exit repeat
                        end if
                    end try
                end repeat
                if targetShow is missing value then return "NO_SHOW_FOUND"
                click targetShow
                delay 0.4
                set subMenu to menu 1 of targetShow
                set subN to count of menu items of subMenu
                set editItem to missing value
                repeat with j from 1 to subN
                    set subNm to "?"
                    try
                        set subNm to name of menu item j of subMenu
                    end try
                    if subNm is "Edit…" then
                        set editItem to menu item j of subMenu
                        exit repeat
                    end if
                end repeat
                if editItem is missing value then
                    key code 53
                    return "NO_EDIT_FOUND"
                end if
                click editItem
                set winReady to false
                repeat 20 times
                    delay 0.25
                    if (count of windows) > 0 then
                        set winReady to true
                        exit repeat
                    end if
                end repeat
                delay 0.5
                set titleBefore to "?"
                if winReady then
                    try
                        set titleBefore to name of window 1
                    end try
                end if
                try
                    click (first button of window 1 whose description is "close button")
                end try
                set closedOk to false
                repeat 20 times
                    delay 0.2
                    if (count of windows) = 0 then
                        set closedOk to true
                        exit repeat
                    end if
                end repeat
                return titleBefore & "|" & closedOk
            end tell
        end tell
        """#
        guard let result = runAppleScript(script) else {
            Issue.record("Edit Show script failed to run")
            return
        }
        // No show currently on the menu has an Edit… entry (e.g. a totally empty schedule) —
        // nothing to navigate to, not a failure of this test.
        if result == "NO_SHOW_FOUND" { return }
        let parts = result.split(separator: "|", maxSplits: 1).map(String.init)
        #expect(parts.count == 2, "unexpected script output: \(result)")
        guard parts.count == 2 else { return }
        #expect(parts[0] == "Edit Show", "opened window titled \(parts[0]), expected 'Edit Show'")
        #expect(parts[1] == "true", "Edit Show window did not close cleanly")
    }

    /// Shared helper for the simple single-instance windows (Add Show, Watch Now) that open
    /// directly from a flat top-level menu item with no per-show submenu to navigate.
    private func openAndCloseTopLevelWindow(menuItemName: String) throws -> (title: String, windowCountAfter: Int) {
        let script = """
        tell application "System Events"
            tell process "hdhr_VCR"
                click menu item "\(menuItemName)" of menu 1 of menu bar item 1 of menu bar 2
                delay 0.7
                set titleBefore to "?"
                try
                    set titleBefore to name of window 1
                end try
                try
                    click (first button of window 1 whose description is "close button")
                end try
                delay 0.3
                set winCountAfter to count of windows
                return titleBefore & "|" & winCountAfter
            end tell
        end tell
        """
        guard let result = runAppleScript(script) else {
            Issue.record("\(menuItemName) script failed to run")
            return ("", -1)
        }
        let parts = result.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let count = Int(parts[1]) else {
            Issue.record("unexpected script output for \(menuItemName): \(result)")
            return ("", -1)
        }
        return (parts[0], count)
    }
}
