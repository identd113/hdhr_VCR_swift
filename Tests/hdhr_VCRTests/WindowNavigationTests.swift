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
    let errPipe = Pipe()
    task.standardOutput = outPipe
    task.standardError = errPipe
    do {
        try task.run()
    } catch {
        return nil
    }
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else {
        // A failed script returns nil (every caller already reports its own Issue for that), but
        // AppleScript's actual error text is worth surfacing on stderr rather than discarding —
        // the difference between "script failed" and "here's the exact AX path that broke" is the
        // difference between a one-line grep and re-deriving it by hand (see this file's git
        // history for how long that took while first building guideSourceToggleDoesNotBreakWindows).
        FileHandle.standardError.write("osascript error: \(String(data: errData, encoding: .utf8) ?? "?")\n".data(using: .utf8)!)
        return nil
    }
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

/// Prepended inside every test's `tell process "hdhr_VCR"` block. The donation nag
/// (`DonationNagView.swift`) opens automatically on every fresh app launch (unless already
/// unlocked) via a forced silent menu open+close in `hdhr_VCRApp.swift` — and being `.floating`
/// level, it sits on top as "window 1", which would otherwise break every other test's assumption
/// that the window it just opened is frontmost. Idempotent (uses `exists`/`try`) so it's a no-op
/// once the nag has already been dismissed earlier in the same run.
private let dismissDonationNagSnippet = """
try
    click (first button of window "Support hdhrVCRplus" whose description is "close button")
end try
repeat 20 times
    delay 0.1
    if not (exists window "Support hdhrVCRplus") then exit repeat
end repeat
"""

/// Real, reproducible finding from building `guideSourceToggleDoesNotBreakWindows`, not a test
/// artifact: `SettingsView`'s `WindowCloseInterceptor.windowShouldClose` shows an app-modal
/// "Unsaved Settings" NSAlert (Save/Discard/Cancel) whenever `isDirty` is true when the window
/// tries to close (`GuideViewHelpers.swift`'s `promptUnsavedChanges`). Repeatedly opening Settings,
/// clicking through every sidebar tab (touching no form field), and closing was enough to trigger
/// this at least once per run while building this test — `isDirty` includes `draftSaveDirectory`/
/// `draftLaunchAtLogin` alongside `draft != state.config`, and at least one of those apparently
/// doesn't always stay in sync with reality across a close/reopen with nothing actually edited.
/// Not chased to a root cause here (out of scope for a window-navigation test to fix); logged as a
/// real product finding in ISSUES.md. This snippet exists so the test survives the alert rather
/// than mistaking it for the Settings window and crashing on AX paths that don't apply to it — an
/// app-modal NSAlert greys out the menu bar, so a later phase's `click menu item "Settings…"` is a
/// no-op while it's showing, and `count of windows` is already satisfied by the alert itself.
private let dismissUnsavedSettingsAlertSnippet = """
try
    if exists (button "Discard" of window 1) then click button "Discard" of window 1
end try
"""

/// Shared by `settingsAllTabsReachable` and `guideSourceToggleDoesNotBreakWindows` — assumes the
/// Settings window is already open and frontmost. Selects every sidebar row in turn and records
/// "label|resultingWindowTitle" per line, then closes the window. Kept as one script (not split
/// into "select tab" + "read title" calls) so the row-index re-resolution and title-settle poll —
/// both required per the comments below — stay atomic with the click that triggers them.
///
/// Deliberately ends on a bare `resultsStr` (not `return resultsStr`): `return` inside a top-level
/// `tell` block exits the *entire* enclosing script immediately, not just this snippet — fine for
/// settingsAllTabsReachable (which only ever runs this once, as the last thing the script does),
/// fatal for guideSourceToggleDoesNotBreakWindows (which needs to run it twice with more script
/// after each). A bare trailing expression becomes AppleScript's implicit `result` for the very
/// next statement instead, without terminating anything — callers that need it right away must
/// capture it (`set x to result`) before any other statement can overwrite that implicit value.
private let captureAllSettingsTabTitlesSnippet = """
set resultsStr to ""
set rowCount to count of rows of outline 1 of scroll area 1 of group 1 of splitter group 1 of group 1 of window 1
repeat with i from 1 to rowCount
    -- Re-resolved every iteration, not cached: selecting a row rebuilds the
    -- SwiftUI List's AX tree, which invalidates any reference captured before
    -- the selection changed.
    set r to row i of outline 1 of scroll area 1 of group 1 of splitter group 1 of group 1 of window 1
    set lbl to name of static text 1 of UI element 1 of r
    set value of attribute "AXSelected" of r to true
    -- Poll until the window title (which tracks the selected tab's own
    -- navigationTitle) settles on two consecutive reads, rather than a blind
    -- delay — a slower machine just polls a few more times instead of racing
    -- a fixed guess (see TODO.md's note on load-related flakiness elsewhere).
    set actualTitle to "?"
    set previousTitle to "?!"
    repeat 10 times
        delay 0.1
        set actualTitle to "?"
        try
            set actualTitle to name of window 1
        end try
        if actualTitle is previousTitle then exit repeat
        set previousTitle to actualTitle
    end repeat
    set resultsStr to resultsStr & lbl & "|" & actualTitle & linefeed
end repeat
try
    click (first button of window 1 whose description is "close button")
end try
resultsStr
"""

@Suite("Window navigation smoke test (requires running app + Accessibility permission — invoke via --filter, not part of default swift test)", .serialized)
struct WindowNavigationTests {

    /// Declared first (and this suite runs `.serialized`) so it gets the one-per-launch donation
    /// nag before every other test's `dismissDonationNagSnippet` clears it. If the nag isn't
    /// present — already unlocked on this install, or an earlier run in this same launch already
    /// dismissed it — that's not a failure of this test, just nothing to verify this pass; every
    /// other test's own dismiss snippet is what actually guarantees a clean slate for them.
    @Test func donationNagReachableAndCloses() throws {
        guard windowNavTestsOptedIn(), appRunning(), accessibilityTrusted() else { return }
        let script = #"""
        tell application "System Events"
            tell process "hdhr_VCR"
                if not (exists window "Support hdhrVCRplus") then return "NOT_PRESENT"
                set titleBefore to name of window "Support hdhrVCRplus"
                try
                    click (first button of window "Support hdhrVCRplus" whose description is "close button")
                end try
                set closedOk to false
                repeat 20 times
                    delay 0.1
                    if not (exists window "Support hdhrVCRplus") then
                        set closedOk to true
                        exit repeat
                    end if
                end repeat
                return titleBefore & "|" & closedOk
            end tell
        end tell
        """#
        guard let result = runAppleScript(script) else {
            Issue.record("Donation nag script failed to run")
            return
        }
        if result == "NOT_PRESENT" { return }
        let parts = result.split(separator: "|", maxSplits: 1).map(String.init)
        #expect(parts.count == 2, "unexpected script output: \(result)")
        guard parts.count == 2 else { return }
        #expect(parts[0] == "Support hdhrVCRplus", "opened window titled \(parts[0])")
        #expect(parts[1] == "true", "donation nag window did not close cleanly")
    }

    @Test func settingsAllTabsReachable() throws {
        guard windowNavTestsOptedIn(), appRunning(), accessibilityTrusted() else { return }
        let script = #"""
        tell application "System Events"
            tell process "hdhr_VCR"
                \#(dismissDonationNagSnippet)
                click menu item "Settings…" of menu 1 of menu bar item 1 of menu bar 2
                repeat 20 times
                    delay 0.25
                    if (count of windows) > 0 then exit repeat
                end repeat
                \#(captureAllSettingsTabTitlesSnippet)
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

    /// Flips Guide_use_xml, confirms it doesn't perturb window/tab structure that has nothing to
    /// do with guide source, then flips it back — added 2026-08-10 alongside the JSON/XMLTV
    /// consistency work (see docs/HDHRFindings.md's "Consistency check" section for the
    /// content-level differences already known and accepted; this test is only about window
    /// chrome, not guide data itself). Any settings tab whose *label* stops matching its own
    /// *resulting window title* after the toggle — or any tab that goes missing/gains a
    /// duplicate — indicates the format switch broke something structural, which would be a real,
    /// unexpected regression worth investigating; a tab's title tracking its own label is the same
    /// invariant settingsAllTabsReachable checks, just diffed before vs. after the toggle here
    /// instead of asserted once.
    @Test func guideSourceToggleDoesNotBreakWindows() throws {
        guard windowNavTestsOptedIn(), appRunning(), accessibilityTrusted() else { return }

        // Selects a sidebar row by name and *polls the window title until it actually changes*
        // instead of a flat delay. Selecting a row rebuilds the SwiftUI List's AX tree (same fact
        // captureAllSettingsTabTitlesSnippet's own comment documents) — a flat delay can race that
        // rebuild and the next AX access (finding the checkbox via `entire contents`, in this
        // test's case) throws "Can't get group 1 of window 1 ... Invalid index (-1719)". Reproduced
        // this exact failure via manual osascript while debugging a first draft that used a flat
        // `delay 0.3` here instead of this poll.
        func selectSettingsTabSnippet(_ tabName: String) -> String {
            """
            set rowCount to count of rows of outline 1 of scroll area 1 of group 1 of splitter group 1 of group 1 of window 1
            repeat with i from 1 to rowCount
                set r to row i of outline 1 of scroll area 1 of group 1 of splitter group 1 of group 1 of window 1
                if (name of static text 1 of UI element 1 of r) is "\(tabName)" then
                    set value of attribute "AXSelected" of r to true
                    exit repeat
                end if
            end repeat
            repeat 20 times
                delay 0.1
                set curTitle to "?"
                try
                    set curTitle to name of window 1
                end try
                if curTitle is "\(tabName)" then exit repeat
            end repeat
            """
        }

        // Finds the checkbox by role+name-substring via `entire contents` rather than a guessed
        // AX path — SwiftUI Form/Section nesting under .formStyle(.grouped) doesn't expose a
        // stable shallow path the way the sidebar outline does (proven necessary via manual
        // osascript probing while building this test: a direct `checkbox "..." of window 1` path
        // came back empty, `entire contents` filtered by role found it reliably).
        //
        // The whole walk is retried (not just individual element property reads) because
        // `entire contents` recurses the *entire* window tree in one call — if a SwiftUI re-render
        // lands mid-walk (observed in practice: the background guide refresh the toggle's own save
        // kicks off can still be mutating state well after it, especially by the time RESTORE below
        // runs), System Events throws "Can't get ... Invalid index (-1719)" for the whole
        // expression, not just the element it was on. A shallow, single-level lookup wouldn't need
        // this, but no such path was found for this checkbox (see above).
        func findCheckboxSnippet(assignTo varName: String) -> String {
            """
            set \(varName) to missing value
            repeat 5 times
                try
                    set allEls to entire contents of window 1
                    repeat with e in allEls
                        try
                            if role of e is "AXCheckBox" and name of e contains "XMLTV" then
                                set \(varName) to e
                                exit repeat
                            end if
                        end try
                    end repeat
                    exit repeat
                on error
                    delay 0.3
                end try
            end repeat
            """
        }

        let findAndToggleXMLCheckboxSnippet = """
        \(findCheckboxSnippet(assignTo: "xmlCheckbox"))
        if xmlCheckbox is missing value then return "NO_TOGGLE_FOUND"
        set originalValue to value of xmlCheckbox
        click xmlCheckbox
        try
            click button "Save & Close" of window 1
        end try
        repeat 20 times
            delay 0.2
            if (count of windows) = 0 then exit repeat
        end repeat
        """

        // One script start-to-finish (not split into separate runAppleScript calls) so the
        // restore-to-original-value step at the end always runs regardless of what the before/after
        // comparison finds — a test that changes a real, persisted user setting must not leave it
        // flipped if an assertion later fails.
        let script = #"""
        tell application "System Events"
            tell process "hdhr_VCR"
                \#(dismissDonationNagSnippet)

                -- BEFORE: capture all 8 tab titles with the current guide source
                try
                    \#(dismissUnsavedSettingsAlertSnippet)
                    click menu item "Settings…" of menu 1 of menu bar item 1 of menu bar 2
                    repeat 20 times
                        delay 0.25
                        if (count of windows) > 0 then exit repeat
                    end repeat
                    -- Extra settle: window existing (count>0) doesn't guarantee its SwiftUI
                    -- content's AX subtree has finished populating yet (see debugging notes above).
                    delay 0.5
                    \#(captureAllSettingsTabTitlesSnippet)
                    set beforeResults to result
                on error errMsg
                    return "PHASE_BEFORE_ERROR: " & errMsg
                end try

                -- TOGGLE: reopen Settings, select General, flip + save (closes the window)
                try
                    \#(dismissUnsavedSettingsAlertSnippet)
                    click menu item "Settings…" of menu 1 of menu bar item 1 of menu bar 2
                    repeat 20 times
                        delay 0.25
                        if (count of windows) > 0 then exit repeat
                    end repeat
                    -- Extra settle: window existing (count>0) doesn't guarantee its SwiftUI
                    -- content's AX subtree has finished populating yet (see debugging notes above).
                    delay 0.5
                    \#(selectSettingsTabSnippet("General"))
                    \#(findAndToggleXMLCheckboxSnippet)
                on error errMsg
                    return "PHASE_TOGGLE_ERROR: " & errMsg
                end try

                -- Real network refresh (guide + lineup) triggered by the save — give it a real
                -- window to complete before reading window state again, not a guess-and-hope delay.
                delay 4

                -- AFTER: capture all 8 tab titles again with the new guide source active
                try
                    \#(dismissUnsavedSettingsAlertSnippet)
                    click menu item "Settings…" of menu 1 of menu bar item 1 of menu bar 2
                    repeat 20 times
                        delay 0.25
                        if (count of windows) > 0 then exit repeat
                    end repeat
                    -- Extra settle: window existing (count>0) doesn't guarantee its SwiftUI
                    -- content's AX subtree has finished populating yet (see debugging notes above).
                    delay 0.5
                    \#(captureAllSettingsTabTitlesSnippet)
                    set afterResults to result
                on error errMsg
                    return "PHASE_AFTER_ERROR: " & errMsg
                end try

                -- RESTORE: flip back to the original value regardless of what was observed above.
                -- Retried up to 3x — reliably reproduced (while building this test) as the one
                -- phase that hits a transient AX "Invalid index" (-1719) that the same settle-poll
                -- protecting every other phase here doesn't fully eliminate, most likely because
                -- the background guide refresh the TOGGLE phase's save kicked off can still be
                -- completing (mutating app/menu state) right around when RESTORE runs — later and
                -- less predictably timed than the fixed 4s delay before AFTER accounts for. A
                -- persisted, real user setting must not stay flipped, so this retries rather than
                -- giving up after one transient failure.
                -- Reuses findAndToggleXMLCheckboxSnippet verbatim (not separate restore-specific
                -- logic) — flipping the same checkbox a second time IS the restore, and this exact
                -- snippet already proved reliable in the TOGGLE phase above; a parallel hand-written
                -- copy here was the actual source of the flakiness this comment block used to
                -- describe (kept failing on its own separately-written click/save sequence even
                -- after the AX-tree-walk and alert-dismissal fixes above stopped the earlier
                -- failures) — so it's deleted in favor of just calling the proven path again.
                set restoreOk to false
                repeat 3 times
                    try
                        \#(dismissUnsavedSettingsAlertSnippet)
                        click menu item "Settings…" of menu 1 of menu bar item 1 of menu bar 2
                        repeat 20 times
                            delay 0.25
                            if (count of windows) > 0 then exit repeat
                        end repeat
                        delay 0.5
                        \#(selectSettingsTabSnippet("General"))
                        \#(findAndToggleXMLCheckboxSnippet)
                        set restoreOk to true
                        exit repeat
                    on error restoreErrMsg
                        set lastRestoreErr to restoreErrMsg
                        try
                            \#(dismissUnsavedSettingsAlertSnippet)
                            click (first button of window 1 whose description is "close button")
                        end try
                        delay 1
                    end try
                end repeat
                if not restoreOk then return "PHASE_RESTORE_ERROR: gave up after 3 attempts, last error: " & lastRestoreErr

                -- Final safety net: observed once (a passing run, config correctly restored) that a
                -- Settings window can still be left open here despite findAndToggleXMLCheckboxSnippet's
                -- own "wait for windows=0" loop reporting no error — belt-and-suspenders close so this
                -- test never leaves a stray window behind for whatever runs after it.
                try
                    if (count of windows) > 0 then
                        \#(dismissUnsavedSettingsAlertSnippet)
                        click (first button of window 1 whose description is "close button")
                    end if
                end try

                return beforeResults & "===SPLIT===" & afterResults
            end tell
        end tell
        """#

        guard let result = runAppleScript(script), !result.isEmpty else {
            Issue.record("Guide source toggle script failed to run")
            return
        }
        if result == "NO_TOGGLE_FOUND" {
            Issue.record("Could not find the 'Use XMLTV guide format' checkbox in General — did it move again?")
            return
        }
        let halves = result.components(separatedBy: "===SPLIT===")
        #expect(halves.count == 2, "unexpected script output shape: \(result)")
        guard halves.count == 2 else { return }

        func parsed(_ raw: String) -> [String: String] {
            var m: [String: String] = [:]
            for line in raw.split(separator: "\n") {
                let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                m[parts[0]] = parts[1]
            }
            return m
        }
        let before = parsed(halves[0])
        let after  = parsed(halves[1])

        #expect(before.count == 8, "expected 8 tabs before toggling, saw \(before.count): \(halves[0])")
        #expect(after.count == 8,  "expected 8 tabs after toggling, saw \(after.count): \(halves[1])")

        // Every label's own title should still match itself post-toggle (settingsAllTabsReachable's
        // invariant), AND — the actual point of this test — nothing should have shifted between
        // the before and after pass just because the guide source changed underneath it.
        for (label, beforeTitle) in before {
            #expect(beforeTitle == label,
                "BEFORE toggle: tab '\(label)' resolved to window title '\(beforeTitle)' — mismatch unrelated to the toggle")
            guard let afterTitle = after[label] else {
                Issue.record("Tab '\(label)' was reachable before the guide-source toggle but not after — unexpected window change")
                continue
            }
            #expect(afterTitle == label,
                "AFTER toggle: tab '\(label)' resolved to window title '\(afterTitle)' — the guide-source switch changed this tab's window title, which should be unrelated")
        }
        for label in after.keys where before[label] == nil {
            Issue.record("Tab '\(label)' appeared only after the guide-source toggle — unexpected new/renamed tab")
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
                \#(dismissDonationNagSnippet)
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
                \(dismissDonationNagSnippet)
                click menu item "\(menuItemName)" of menu 1 of menu bar item 1 of menu bar 2
                repeat 20 times
                    delay 0.25
                    if (count of windows) > 0 then exit repeat
                end repeat
                set titleBefore to "?"
                try
                    set titleBefore to name of window 1
                end try
                try
                    click (first button of window 1 whose description is "close button")
                end try
                repeat 20 times
                    delay 0.2
                    if (count of windows) = 0 then exit repeat
                end repeat
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
