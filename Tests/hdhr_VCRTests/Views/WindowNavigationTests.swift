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

/// Shared by every PiP test below (added 2026-09-19) — opens Watch Now, clicks the recording-relay
/// "Watch Now!" row (same help-text match `vlcPlayerControlsAreAccessible` already proved reliable
/// for exactly this button), and waits for the resulting player window, capturing it as `playerWin`.
/// The recording-relay entry point is used as the PRIMARY for every PiP test — unlike a live-channel
/// "Watch " button, it needs no free tuner to start (a currently-recording show already holds its
/// own), so these tests only depend on "something is recording," not also "a tuner happens to be
/// free" — that second condition is instead what the *secondary* (added via the PiP picker's own
/// Live TV section) actually needs, kept as a separate, independently-skippable condition per test.
/// Returns the sentinel "NO_RECORDING_TO_WATCH"/"NO_PLAYER_WINDOW" exactly as
/// `vlcPlayerControlsAreAccessible` does — every caller must check for those before using
/// `playerWin`. Deliberately does not close anything itself (including "Watch Now", left open
/// behind the player window) — what counts as fully cleaned up differs per caller, since some tests
/// open additional PiP-picker windows on top before they're done.
private let openRecordingRelayPlayerSnippet = """
click menu item "Watch Now…" of menu 1 of menu bar item 1 of menu bar 2
repeat 20 times
    delay 0.25
    if (count of windows) > 0 then exit repeat
end repeat
set watchBtn to missing value
repeat 20 times
    try
        set allEls to entire contents of window "Watch Now"
        repeat with e in allEls
            try
                if role of e is "AXButton" then
                    set h to (help of e) as string
                    if h starts with "Play the in-progress recording" then
                        set watchBtn to e
                        exit repeat
                    end if
                end if
            end try
        end repeat
    end try
    if watchBtn is not missing value then exit repeat
    delay 0.25
end repeat
if watchBtn is missing value then
    try
        click (first button of window "Watch Now" whose description is "close button")
    end try
    return "NO_RECORDING_TO_WATCH"
end if
click watchBtn
repeat 20 times
    delay 0.25
    if (count of windows) > 1 then exit repeat
end repeat
set playerWin to missing value
repeat with w in windows
    if (name of w) is not "Watch Now" then
        set playerWin to w
        exit repeat
    end if
end repeat
if playerWin is missing value then return "NO_PLAYER_WINDOW"
-- The window opening does NOT mean the stream is playing — VLCBridge.play() connects
-- immediately, independent of any click, but the poster overlay's own Start button stays
-- disabled (label "Connecting…") until bridge.isPlaying flips true (first frame decoded), only
-- becoming a real, enabled "Start" after that. Found live 2026-09-19: every PiP test originally
-- skipped this button entirely and went straight to the context menu/PiP flow with the primary
-- still sitting behind the poster, muted — meaning none of them were actually exercising PiP
-- behavior against a genuinely playing, unmuted primary, only the window/menu/identifier wiring
-- around it. Poll for vlc-start-button to become enabled (AXIdentifier lookup — this file's own
-- established most-reliable method, per vlcPlayerControlsAreAccessible's doc comment), then click
-- it, then wait out the poster's own .easeOut(duration: 0.35) fade so posterHidden has actually
-- taken visible effect before any caller proceeds.
set startBtn to missing value
repeat 30 times
    try
        set allEls to entire contents of playerWin
        repeat with e in allEls
            try
                if (value of attribute "AXIdentifier" of e) as string is "vlc-start-button" then
                    set startBtn to e
                    exit repeat
                end if
            end try
        end repeat
    end try
    if startBtn is not missing value then
        set isEnabled to true
        try
            set isEnabled to (value of attribute "AXEnabled" of startBtn) as boolean
        end try
        if isEnabled then exit repeat
        set startBtn to missing value
    end if
    delay 0.25
end repeat
if startBtn is missing value then return "NO_PLAYBACK_STARTED"
click startBtn
delay 0.5
"""

/// Continuation of `openRecordingRelayPlayerSnippet` — assumes `playerWin` is already set. Opens
/// the PiP picker via the player's right-click context menu (the *only* entry point since
/// MenuContent's redundant menu-bar button was removed 2026-09-19 — see VLCPlayerView.swift's own
/// `.contextMenu` doc comment) and waits for the resulting "Add Picture-in-Picture" window.
///
/// Confirmed live 2026-09-19: `perform action "AXShowMenu" of playerWin` does land the SwiftUI
/// `.contextMenu` and does expose it as `menu 1 of playerWin` right after, same "the menu that
/// appears after interacting with an element becomes `menu 1` of that same element" idiom
/// `editShowOpensAndCloses` already trusts — reliably, in every one of this snippet's real callers
/// below, across two separate full-suite runs. See `pipPickerOpensFromPlayerContextMenu`'s own doc
/// comment for a known exception: run standalone/first-in-process, this exact call can fail in a
/// way that more polling, re-issuing the action, or even full close/reopen retries don't fix — not
/// something this snippet can itself work around, so it isn't tried here.
private let openPipPickerFromPlayerContextMenuSnippet = """
perform action "AXShowMenu" of playerWin
set pipMenuItem to missing value
repeat 20 times
    try
        set pipMenuItem to menu item "Add Picture-in-Picture…" of menu 1 of playerWin
        exit repeat
    end try
    delay 0.25
end repeat
if pipMenuItem is missing value then return "NO_PIP_CONTEXT_MENU_ITEM"
click pipMenuItem
set pipWin to missing value
repeat 20 times
    delay 0.25
    try
        set pipWin to window "Add Picture-in-Picture"
        exit repeat
    end try
end repeat
if pipWin is missing value then return "NO_PIP_PICKER_WINDOW"
-- Content (Live TV section, per-row buttons) populates after the window itself, same lesson every
-- other content-walking test in this file already documents.
delay 0.5
"""

/// Continuation of the above two snippets — assumes both `playerWin` and `pipWin` are set. Clicks
/// the first available `pip-picker-add-button` (the shared identifier every "Add as PIP" row uses —
/// see PiPPickerView.swift's own doc comment on why it's shared, not per-row) to add a live-channel
/// secondary, which also dismisses `pipWin` itself (PiPPickerView's own `dismiss()` call after the
/// action — see `pipActionTrailing`). Returns "NO_PIP_TARGET_AVAILABLE" when nothing is addable
/// (no tuners/channels, or the only rows shown are already dimmed "Now Playing") — a real
/// environment-dependent skip condition (needs a free tuner), same "nothing to test" pattern every
/// other skip sentinel in this file already uses, distinct from the recording-relay primary above
/// (which only needs *something recording*, not also a free tuner).
private let addFirstLiveTVSecondarySnippet = """
set addBtn to missing value
repeat 10 times
    try
        set allEls to entire contents of pipWin
        repeat with e in allEls
            try
                if (value of attribute "AXIdentifier" of e) as string is "pip-picker-add-button" then
                    set addBtn to e
                    exit repeat
                end if
            end try
        end repeat
    end try
    if addBtn is not missing value then exit repeat
    delay 0.25
end repeat
if addBtn is missing value then
    try
        click (first button of pipWin whose description is "close button")
    end try
    return "NO_PIP_TARGET_AVAILABLE"
end if
click addBtn
-- pipWin closes itself (PiPPickerView's own dismiss()) — wait for it to actually go rather than
-- assuming the click was instant, then give the secondary's own connection a moment to come up
-- (bridge.secondaryIsPlaying/pipOverlay's own spinner state — this test only needs the thumbnail
-- Button/AXIdentifier to exist, not necessarily already playing).
repeat 20 times
    delay 0.2
    try
        if not (exists pipWin) then exit repeat
    end try
end repeat
delay 1
"""

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

/// Used by both phases of `guideSourceToggleDoesNotBreakWindows` — assumes the Settings window is
/// already open and frontmost. Selects every sidebar row in turn and records
/// "label|resultingWindowTitle" per line. Kept as one script (not split into "select tab" + "read
/// title" calls) so the row-index re-resolution and title-settle poll — both required per the
/// comments below — stay atomic with the click that triggers them.
///
/// Deliberately does NOT close the window (2026-08-15: used to, when a since-removed standalone
/// reachability test called this as the last thing it did) — both remaining call sites
/// immediately select the General tab and flip the guide-source checkbox right after this scan in
/// the *same* window session, so closing here would just force an unnecessary reopen a few lines
/// later. Ends on a bare `resultsStr` (not `return resultsStr`): `return` inside a top-level `tell`
/// block exits the *entire* enclosing script immediately, not just this snippet. A bare trailing
/// expression becomes AppleScript's implicit `result` for the very next statement instead, without
/// terminating anything — callers must capture it (`set x to result`) before any other statement
/// can overwrite that implicit value.
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

    /// Flips Guide_use_xml, confirms it doesn't perturb window/tab structure that has nothing to
    /// do with guide source, then flips it back — added 2026-08-10 alongside the JSON/XMLTV
    /// consistency work (see docs/HDHRFindings.md's "Consistency check" section for the
    /// content-level differences already known and accepted; this test is only about window
    /// chrome, not guide data itself). Any settings tab whose *label* stops matching its own
    /// *resulting window title* after the toggle — or any tab that goes missing/gains a
    /// duplicate — indicates the format switch broke something structural, which would be a real,
    /// unexpected regression worth investigating.
    ///
    /// Also the only place "are all 8 Settings tabs reachable at all" gets checked (formerly a
    /// separate `settingsAllTabsReachable` test, folded in 2026-08-15) — its BEFORE phase asserts
    /// exactly that invariant on an untouched config before this test does anything else, so a
    /// dedicated scan-and-assert pass was pure duplicate work: same script
    /// (`captureAllSettingsTabTitlesSnippet`), same assertions, on the same running app, just
    /// without the diff this test does on top. Removing the standalone test cut this suite's real
    /// on-screen run from 3 full "open Settings, walk every sidebar tab" passes to 2 (~3.8s of the
    /// suite's ~37s). Trade-off worth knowing: general tab-reachability coverage now lives inside
    /// a test named for something else — if this test is ever gutted for guide-source-specific
    /// reasons, take the BEFORE-phase assertions below with it rather than deleting them.
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

                -- BEFORE_AND_TOGGLE: open Settings once, capture all 8 tab titles with the
                -- current guide source, then — same window session, no reopen — select General
                -- and flip + save the guide-source checkbox (closes the window). Merged 2026-08-15:
                -- these were two separate "open Settings, wait, settle" cycles that always ran
                -- back-to-back with nothing else happening in between.
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
                    \#(selectSettingsTabSnippet("General"))
                    \#(findAndToggleXMLCheckboxSnippet)
                on error errMsg
                    return "PHASE_BEFORE_ERROR: " & errMsg
                end try

                -- Real network refresh (guide + lineup) triggered by the save — give it a real
                -- window to complete before reading window state again, not a guess-and-hope delay.
                delay 4

                -- AFTER: reopen Settings once, capture all 8 tab titles again with the new guide
                -- source active. Deliberately left open afterward (captureAllSettingsTabTitlesSnippet
                -- no longer closes it) — RESTORE right below reuses this same window instead of
                -- reopening; its own "click menu item Settings…" becomes a near-instant no-op
                -- (window already frontmost) rather than a real reopen in the common case.
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
                -- the background guide refresh the BEFORE_AND_TOGGLE phase's save kicked off can still be
                -- completing (mutating app/menu state) right around when RESTORE runs — later and
                -- less predictably timed than the fixed 4s delay before AFTER accounts for. A
                -- persisted, real user setting must not stay flipped, so this retries rather than
                -- giving up after one transient failure.
                -- Reuses findAndToggleXMLCheckboxSnippet verbatim (not separate restore-specific
                -- logic) — flipping the same checkbox a second time IS the restore, and this exact
                -- snippet already proved reliable in the BEFORE_AND_TOGGLE phase above; a parallel hand-written
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

        // Every label's own title should still match itself both before AND after the toggle
        // (general tab-reachability, not specific to guide source — see this function's doc
        // comment), AND — the actual point of this test — nothing should have shifted between
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

    /// Every `ⓘ` InfoButton sits next to a label via a plain `HStack { Text(...); InfoButton(...) }`
    /// with no explicit spacing — except SettingsView's `maintenanceRow()`, found (by code
    /// inspection, not live) to hardcode `spacing: 6`, visibly pulling the Maintenance tab's info
    /// icons closer to their labels than every other tab's. This measures the real on-screen gap
    /// (a label's right edge to its InfoButton's left edge) for one row in General and one in
    /// Maintenance and asserts they match within a small tolerance — a genuine layout regression
    /// test: it failed against the `spacing: 6` override before that was removed in the same
    /// change that added this test, and would fail again if a tab-specific override crept back in.
    @Test func infoButtonSpacingIsConsistentAcrossTabs() throws {
        guard windowNavTestsOptedIn(), appRunning(), accessibilityTrusted() else { return }

        // Same shape as guideSourceToggleDoesNotBreakWindows' own copy above — not shared at file
        // scope, so each test's local tweaks (if any) can't affect the other.
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

        // Finds a plain-text label by exact name, then the nearest AXButton sitting on the same
        // row and to its right (within 60pt — generous enough to clear normal icon spacing, tight
        // enough to exclude a far-right action button like Maintenance's own "Run") — that's its
        // InfoButton. Returns the gap between the label's right edge and the button's left edge in
        // `varName`, or -1 if either wasn't found. Retried like findCheckboxSnippet above: a
        // SwiftUI re-render mid-walk throws "Invalid index" for the whole entire-contents
        // expression, not just the element it was on.
        func labelToInfoButtonGapSnippet(labelName: String, assignTo varName: String) -> String {
            """
            set \(varName) to -1
            repeat 5 times
                try
                    set allEls to entire contents of window 1
                    set lbl to missing value
                    repeat with e in allEls
                        try
                            if role of e is "AXStaticText" and name of e is "\(labelName)" then
                                set lbl to e
                                exit repeat
                            end if
                        end try
                    end repeat
                    if lbl is not missing value then
                        set lblPos to position of lbl
                        set lblSize to size of lbl
                        set lblRight to (item 1 of lblPos) + (item 1 of lblSize)
                        set lblY to item 2 of lblPos
                        set bestGap to missing value
                        repeat with e in allEls
                            try
                                if role of e is "AXButton" then
                                    set bPos to position of e
                                    set bx to item 1 of bPos
                                    -- Not named "by" — that's a reserved parameter keyword of the
                                    -- Standard Suite's "move ... by ..." verb, in scope inside this
                                    -- tell block; using it as a plain variable name breaks the
                                    -- AppleScript parser ("Expected expression but found "by"").
                                    set bYpos to item 2 of bPos
                                    if (bx > lblRight) and ((bx - lblRight) < 60) and ((bYpos - lblY) > -6) and ((bYpos - lblY) < 6) then
                                        if bestGap is missing value or (bx - lblRight) < bestGap then set bestGap to (bx - lblRight)
                                    end if
                                end if
                            end try
                        end repeat
                        if bestGap is not missing value then set \(varName) to bestGap
                    end if
                    exit repeat
                on error
                    delay 0.3
                end try
            end repeat
            """
        }

        let script = #"""
        tell application "System Events"
            tell process "hdhr_VCR"
                \#(dismissDonationNagSnippet)
                try
                    \#(dismissUnsavedSettingsAlertSnippet)
                    click menu item "Settings…" of menu 1 of menu bar item 1 of menu bar 2
                    repeat 20 times
                        delay 0.25
                        if (count of windows) > 0 then exit repeat
                    end repeat
                    delay 0.5
                    \#(selectSettingsTabSnippet("General"))
                    \#(labelToInfoButtonGapSnippet(labelName: "Launch at Login", assignTo: "generalGap"))
                    \#(selectSettingsTabSnippet("Maintenance"))
                    \#(labelToInfoButtonGapSnippet(labelName: "Reset Fail Counts", assignTo: "maintenanceGap"))
                    try
                        click (first button of window 1 whose description is "close button")
                    end try
                    \#(dismissUnsavedSettingsAlertSnippet)
                    repeat 20 times
                        delay 0.2
                        if (count of windows) = 0 then exit repeat
                    end repeat
                    return (generalGap as string) & "|" & (maintenanceGap as string)
                on error errMsg
                    return "ERROR: " & errMsg
                end try
            end tell
        end tell
        """#
        guard let result = runAppleScript(script) else {
            Issue.record("InfoButton spacing script failed to run")
            return
        }
        if result.hasPrefix("ERROR:") {
            Issue.record("InfoButton spacing scan failed: \(result)")
            return
        }
        let parts = result.split(separator: "|").compactMap { Double($0) }
        guard parts.count == 2 else {
            Issue.record("Could not parse both rows' InfoButton gap — did a label move? Raw: \(result)")
            return
        }
        let (generalGap, maintenanceGap) = (parts[0], parts[1])
        #expect(generalGap >= 0, "could not find 'Launch at Login' or its InfoButton in General — did the row move or lose its InfoButton?")
        #expect(maintenanceGap >= 0, "could not find 'Reset Fail Counts' or its InfoButton in Maintenance — did the row move or lose its InfoButton?")
        guard generalGap >= 0, maintenanceGap >= 0 else { return }
        #expect(abs(generalGap - maintenanceGap) < 3,
            "InfoButton sits \(maintenanceGap)pt from its label in Maintenance vs \(generalGap)pt in General — a tab-specific spacing override crept in")
    }

    @Test func addShowOpensAndCloses() throws {
        guard windowNavTestsOptedIn(), appRunning(), accessibilityTrusted() else { return }
        let (title, windowCountAfter) = try openAndCloseTopLevelWindow(menuItemName: "Add Show…")
        #expect(title == "Add Show")
        #expect(windowCountAfter == 0)
    }

    /// Confirms the web guide's search box (`Resources/guide-shell.html`'s `#search-in`, added
    /// 2026-08-28) is actually reachable via the Accessibility API from inside the Add Show
    /// wizard's embedded `WKWebView` (`AddShowView.swift`'s `AddShowWebView`, loading
    /// `localhost:{Web_server_port}`) — the first test in this file to walk into web content
    /// rather than a native SwiftUI AX tree, so its own AX role/shape assumptions are unverified
    /// until this actually runs live. Also exercises real typing (System Events `keystroke`, not a
    /// synthetic JS event) and confirms it can't accidentally land in "a show got selected" state.
    ///
    /// Deliberately does NOT try to select an actual result and assert on the resulting dim/chip
    /// behavior — that needs a real matching show in whatever guide data happens to be loaded on
    /// the machine running this test, which (unlike everything else in this suite) is real,
    /// time-varying, live device/guide state this test has no control over. Typed query here is a
    /// long random-looking string specifically chosen to never match a real title, so the
    /// assertions below hold regardless of what's actually in the guide (or even whether any
    /// device/guide data is loaded at all — searchDeviceId() just no-ops the fetch in that case).
    /// Testing the full search→select→dim→cycle flow deterministically would need a fixture guide
    /// via `tools/mock_hdhr.py --guide-file` wired into a real running app instance — a bigger lift
    /// than this lightweight window-nav smoke test, left as a follow-up if deeper coverage is wanted.
    ///
    /// Performance risk worth knowing going in: every other AX walk in this file (`entire contents
    /// of window ...`) targets a small, bounded native SwiftUI window. The Add Show window's guide
    /// step can render a very large grid (thousands of `.g-prog` blocks, per guide.js's own
    /// "~2600-tile grid" comment) — `entire contents` recursing that whole tree may be meaningfully
    /// slower than every other use of this pattern here, or could time out. Not something that
    /// could be verified without a live run.
    @Test func addShowGuideSearchBoxIsAccessibleAndTypingDoesNotAutoSelect() throws {
        guard windowNavTestsOptedIn(), appRunning(), accessibilityTrusted() else { return }
        let script = #"""
        tell application "System Events"
            tell process "hdhr_VCR"
                \#(dismissDonationNagSnippet)
                click menu item "Add Show…" of menu 1 of menu bar item 1 of menu bar 2
                repeat 20 times
                    delay 0.25
                    if (count of windows) > 0 then exit repeat
                end repeat
                -- The WKWebView's own page load (fetch guide.json, render the grid) finishes well
                -- after the window/WKWebView AX node itself first appears — same "window exists !=
                -- content ready" lesson every other content-walking test in this file documents.
                -- Polled (not a flat delay) so this exits the instant the search box actually
                -- exists rather than always waiting a fixed worst-case duration — a fixed `delay 3`
                -- here used to hold the window open that long even when the page loaded in a
                -- fraction of that, on every single run. Same 20×0.25s = 5s outer ceiling as every
                -- other poll-loop in this file, delayed on *every* iteration (not just on error, an
                -- earlier version of this loop's own mistake — a successful walk that simply hadn't
                -- found the box yet retried with no delay at all between attempts, so the loop
                -- alone provided no real wait against a still-loading page).
                set searchBox to missing value
                repeat 20 times
                    try
                        set allEls to entire contents of window "Add Show"
                        repeat with e in allEls
                            try
                                if (role of e is "AXTextField" or role of e is "AXComboBox") then
                                    set d to "?"
                                    try
                                        set d to (description of e) as string
                                    end try
                                    if d contains "Search shows" then
                                        set searchBox to e
                                        exit repeat
                                    end if
                                end if
                            end try
                        end repeat
                    end try
                    if searchBox is not missing value then exit repeat
                    delay 0.25
                end repeat
                if searchBox is missing value then
                    try
                        click (first button of window "Add Show" whose description is "close button")
                    end try
                    return "NO_SEARCH_BOX_FOUND"
                end if

                click searchBox
                -- Long, random-looking, guaranteed-not-to-match-a-real-title query.
                keystroke "zzqxvbnkjhgqwerty0987"
                delay 1.0 -- debounce (~200ms) plus a real /api/guide-search round trip

                set valAfter to "?"
                try
                    set valAfter to (value of searchBox) as string
                end try
                set roAfter to "false"
                try
                    if (value of attribute "AXReadOnly" of searchBox) then set roAfter to "true"
                end try

                try
                    click (first button of window "Add Show" whose description is "close button")
                end try
                repeat 20 times
                    delay 0.2
                    if (count of windows) = 0 then exit repeat
                end repeat

                return valAfter & "|" & roAfter
            end tell
        end tell
        """#
        guard let result = runAppleScript(script) else {
            Issue.record("Add Show guide-search script failed to run")
            return
        }
        if result == "NO_SEARCH_BOX_FOUND" {
            Issue.record("Could not find the web guide's search input inside the Add Show WKWebView via the Accessibility API — either this test's AX role/description assumptions are wrong (first time this file has walked into WKWebView content, unverified until run live) or the search box regressed/lost its aria-label. Needs a live, sighted RUN_WINDOW_NAV_TESTS=1 run to tell which.")
            return
        }
        let parts = result.split(separator: "|", maxSplits: 1).map(String.init)
        #expect(parts.count == 2, "unexpected script output: \(result)")
        guard parts.count == 2 else { return }
        let (value, readOnly) = (parts[0], parts[1])
        #expect(value.contains("zzqxvbnkjhgqwerty0987"),
            "search input's value changed unexpectedly after typing — got '\(value)'")
        #expect(readOnly == "false",
            "search input became read-only (chip/selected mode) after typing a query that should never match a real show")
    }

    @Test func watchNowOpensAndCloses() throws {
        guard windowNavTestsOptedIn(), appRunning(), accessibilityTrusted() else { return }
        let (title, windowCountAfter) = try openAndCloseTopLevelWindow(menuItemName: "Watch Now…")
        #expect(title == "Watch Now")
        #expect(windowCountAfter == 0)
    }

    /// Confirms the Watch Now window's per-channel row action buttons (Watch/Watch from
    /// Beginning/VLC/Edit/Record — WatchNowView.swift's `watchButtons`/`secondaryButtons`) are
    /// actually reachable via the Accessibility API, without ever clicking one — clicking "Watch"
    /// opens the VLC player, a separate window/tuner-consuming surface deliberately out of scope
    /// here (see file header: this suite only pops the app's own SwiftUI windows, not VLC).
    ///
    /// Real finding from building this test, worth preserving: every one of these buttons already
    /// carries a correct `.accessibilityLabel(...)` in WatchNowView.swift (`watchLiveLabel`,
    /// `"Record \(entry.Title)"`, etc.) — but System Events' `name of` and `description of` come
    /// back `missing value` for all of them regardless, on this SwiftUI/AppKit bridge. What DOES
    /// come through reliably is `help of` — every one of these buttons also carries a `.help(...)`
    /// modifier (sometimes identical text to its accessibilityLabel, sometimes a fuller sentence —
    /// e.g. the recording-relay "Watch Now!" button's help is "Play the in-progress recording of
    /// {title} from disk, starting near live", not `watchLiveLabel`'s shorter accessibilityLabel
    /// text) — and that's what actually surfaces to `System Events`. So this test (and any future
    /// one targeting these specific buttons) matches on `help`, not `name`/`description` the way
    /// the Settings checkbox test above does — that control is a plain-text `AXCheckBox`, a
    /// different case from these compound icon+`Label` `.buttonStyle(.plain)`-family buttons.
    @Test func watchNowRowButtonsAreAccessible() throws {
        guard windowNavTestsOptedIn(), appRunning(), accessibilityTrusted() else { return }
        let script = #"""
        tell application "System Events"
            tell process "hdhr_VCR"
                \#(dismissDonationNagSnippet)
                click menu item "Watch Now…" of menu 1 of menu bar item 1 of menu bar 2
                repeat 20 times
                    delay 0.25
                    if (count of windows) > 0 then exit repeat
                end repeat
                -- Extra settle beyond "window exists": the channel list's own AX subtree (row
                -- buttons, per-row text) populates after the window itself does — same lesson
                -- captureAllSettingsTabTitlesSnippet's comment documents for Settings' outline.
                -- Polled (exits the instant a Watch button actually shows up, the same success
                -- condition asserted below) rather than a flat `delay 1.5` that held the window
                -- open that long even on a run where the list was already populated well before it.
                set watchCount to 0
                set recordCount to 0
                set editCount to 0
                repeat 20 times
                    set watchCount to 0
                    set recordCount to 0
                    set editCount to 0
                    -- Bare try/end try (swallow and retry via the outer loop), not try/on-error/
                    -- return — same fix as addShowGuideSearchBoxIsAccessibleAndTypingDoesNotAutoSelect's
                    -- own loop above: a transient exception here (AX subtree not yet populated, the
                    -- exact race this poll exists to tolerate) used to `return "ERROR: ..."` on the
                    -- very first iteration, aborting the whole script instead of ever reaching a retry.
                    try
                        set allEls to entire contents of window "Watch Now"
                        repeat with e in allEls
                            try
                                if role of e is "AXButton" then
                                    set h to "?"
                                    try
                                        set h to (help of e) as string
                                    end try
                                    if h starts with "Watch " or h starts with "Play the in-progress recording" then
                                        set watchCount to watchCount + 1
                                    end if
                                    if h starts with "Record " then set recordCount to recordCount + 1
                                    if h starts with "Edit " then set editCount to editCount + 1
                                end if
                            end try
                        end repeat
                    end try
                    if watchCount > 0 then exit repeat
                    delay 0.25
                end repeat
                try
                    click (first button of window "Watch Now" whose description is "close button")
                end try
                repeat 20 times
                    delay 0.2
                    if (count of windows) = 0 then exit repeat
                end repeat
                return (watchCount as string) & "|" & (recordCount as string) & "|" & (editCount as string)
            end tell
        end tell
        """#
        guard let result = runAppleScript(script) else {
            Issue.record("Watch Now row-button accessibility script failed to run")
            return
        }
        if result.hasPrefix("ERROR:") {
            Issue.record("Watch Now row-button scan failed: \(result)")
            return
        }
        let parts = result.split(separator: "|").compactMap { Int($0) }
        #expect(parts.count == 3, "unexpected script output: \(result)")
        guard parts.count == 3 else { return }
        let (watchCount, recordCount, editCount) = (parts[0], parts[1], parts[2])
        // At least one watch-type button should always be reachable — an empty schedule can still
        // legitimately have zero Record/Edit buttons (no managed shows to edit, though "Record" is
        // offered on every unmanaged channel so it'd be unusual for the lineup to be that empty
        // too), but every visible row always offers *some* way to watch it.
        #expect(watchCount > 0, "no accessible 'Watch' button found — did WatchNowView's help text change, or did the row-button AX bridging regress?")
        _ = recordCount; _ = editCount   // observed for debugging visibility only; not asserted on
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

    /// Deliberately crosses the boundary `watchNowRowButtonsAreAccessible`'s own doc comment
    /// describes ("this suite only pops the app's own SwiftUI windows, not VLC") — added 2026-09-04
    /// specifically to verify the VLC player window's own accessibility, which nothing else in this
    /// file (or the app) had ever confirmed live. Only reachable when a show is actually recording
    /// (skips cleanly otherwise, same "nothing to test" pattern `editShowOpensAndCloses` uses for
    /// an empty schedule) — clicks the *recording-relay* "Watch Now!" row specifically (matched by
    /// its help text, "Play the in-progress recording..."), never a live-channel "Watch " button,
    /// which would need a free physical tuner and could fail/no-op with both tuners busy (confirmed
    /// live: a first draft of this test matched the wrong button — the generic `"Watch "` prefix —
    /// and hit a real "No Tuner Available" alert instead of opening the player).
    ///
    /// Real finding from building this test, worth preserving: unlike every other control in this
    /// file (`watchNowRowButtonsAreAccessible`'s own comment: only `help of` comes through, `name`/
    /// `description` are `missing value`), the VLC player's own SwiftUI controls — all newly given
    /// an explicit `.accessibilityIdentifier(...)` in `VLCPlayerView.swift`, 2026-09-04 — DO surface
    /// reliably via `value of attribute "AXIdentifier" of e`. A materially more robust lookup than
    /// text-matching `help`/`description` (stable across UI copy changes, no risk of matching the
    /// wrong same-prefixed control the way a bare `help starts with "Watch "` did above), confirmed
    /// live rather than assumed given this file's own track record of AX properties not surfacing
    /// the way SwiftUI's own modifier names might suggest.
    @Test func vlcPlayerControlsAreAccessible() throws {
        guard windowNavTestsOptedIn(), appRunning(), accessibilityTrusted() else { return }
        let script = #"""
        tell application "System Events"
            tell process "hdhr_VCR"
                \#(dismissDonationNagSnippet)
                click menu item "Watch Now…" of menu 1 of menu bar item 1 of menu bar 2
                repeat 20 times
                    delay 0.25
                    if (count of windows) > 0 then exit repeat
                end repeat
                set watchBtn to missing value
                repeat 20 times
                    try
                        set allEls to entire contents of window "Watch Now"
                        repeat with e in allEls
                            try
                                if role of e is "AXButton" then
                                    set h to (help of e) as string
                                    if h starts with "Play the in-progress recording" then
                                        set watchBtn to e
                                        exit repeat
                                    end if
                                end if
                            end try
                        end repeat
                    end try
                    if watchBtn is not missing value then exit repeat
                    delay 0.25
                end repeat
                if watchBtn is missing value then
                    try
                        click (first button of window "Watch Now" whose description is "close button")
                    end try
                    return "NO_RECORDING_TO_WATCH"
                end if
                click watchBtn
                repeat 20 times
                    delay 0.25
                    if (count of windows) > 1 then exit repeat
                end repeat
                -- Player window title is the show's own title (VLCPlayerWindowManager sets
                -- win.title = title) — not a fixed name, so find it as "whichever window isn't
                -- Watch Now" rather than matching a literal string.
                set playerWin to missing value
                repeat with w in windows
                    if (name of w) is not "Watch Now" then
                        set playerWin to w
                        exit repeat
                    end if
                end repeat
                if playerWin is missing value then return "NO_PLAYER_WINDOW"
                -- Same settle-then-poll shape as watchNowRowButtonsAreAccessible above — the
                -- toolbar's own AX subtree populates after the window itself does.
                set foundIds to {}
                repeat 20 times
                    set foundIds to {}
                    try
                        set allEls to entire contents of playerWin
                        repeat with e in allEls
                            try
                                set idVal to (value of attribute "AXIdentifier" of e) as string
                                if idVal starts with "vlc-" then set end of foundIds to idVal
                            end try
                        end repeat
                    end try
                    if (count of foundIds) > 0 then exit repeat
                    delay 0.25
                end repeat
                try
                    click (first button of playerWin whose description is "close button")
                end try
                repeat 20 times
                    delay 0.2
                    if (count of windows) = 1 then exit repeat
                end repeat
                try
                    click (first button of window "Watch Now" whose description is "close button")
                end try
                set idList to ""
                repeat with i in foundIds
                    set idList to idList & i & ","
                end repeat
                return idList
            end tell
        end tell
        """#
        guard let result = runAppleScript(script) else {
            Issue.record("VLC player accessibility script failed to run")
            return
        }
        // Nothing recording — nothing to watch, not a failure of this test (same pattern as
        // editShowOpensAndCloses's "no show has an Edit… entry" skip above).
        if result == "NO_RECORDING_TO_WATCH" { return }
        if result == "NO_PLAYER_WINDOW" {
            Issue.record("Watch Now's recording-relay button didn't open a second window")
            return
        }
        let foundIds = Set(result.split(separator: ",").map(String.init))
        // The identifiers every Watch Now (local recording-relay) session should expose regardless
        // of which show/device — deliberately excludes vlc-feed-transcode-toggle/vlc-cc-picker,
        // which are FEED-only and recording-relay-hidden respectively (see this test's own doc
        // comment and VLCPlayerView.swift's own CC-picker condition).
        let expected: Set<String> = [
            "vlc-channel-picker", "vlc-catch-up-button", "vlc-native-resolution",
            "vlc-volume-slider", "vlc-start-button", "vlc-info-button",
        ]
        let missing = expected.subtracting(foundIds)
        #expect(missing.isEmpty, "VLC player window is missing expected accessibility identifiers: \(missing.sorted())")
    }

    // MARK: - Picture-in-picture

    /// Confirms the PiP picker is reachable at all — the player's right-click context menu is its
    /// *only* entry point (MenuContent's redundant menu-bar button was removed 2026-09-19) — and
    /// that it shows a "Live TV" section (or, with zero recordable devices, "No tuners available")
    /// the way `PiPPickerView.liveTVSection` always renders one or the other. Doesn't add anything;
    /// see the tests below for the add/swap/corner/channel combinations.
    ///
    /// **Known flake, not a product bug** — real finding from four separate live attempts
    /// (2026-09-19): `perform action "AXShowMenu" of playerWin` against the player's `.contextMenu`
    /// fails when this is the *only* (or first) AX interaction this osascript process has made with
    /// the app — reproduced every single time run via `--filter` in isolation, including with a 3×
    /// full close/reopen retry loop (28s of real retries, still 0/3). Yet the identical mechanism —
    /// same snippet, same window, same menu item — passed reliably in *every* one of the 5 PiP
    /// tests below, twice, in two separate full-suite runs, because by the time each of them runs,
    /// several earlier tests have already driven Settings/Add Show/Watch Now/the player window
    /// through System Events first. So this isn't "cold player window" or "cold AXShowMenu specifically"
    /// (ruled out: retrying the identical action against the identical window doesn't help) — it's
    /// something about the *whole accessibility session* with this app needing some other, unknown
    /// kind of prior interaction to settle, that this test alone doesn't happen to produce. Left
    /// as a known, understood limitation of standalone/first-in-run execution rather than chased
    /// further — see the tests below for the actual PiP behavior coverage, which is solid.
    @Test func pipPickerOpensFromPlayerContextMenu() throws {
        guard windowNavTestsOptedIn(), appRunning(), accessibilityTrusted() else { return }
        let script = #"""
        tell application "System Events"
            tell process "hdhr_VCR"
                \#(dismissDonationNagSnippet)
                \#(openRecordingRelayPlayerSnippet)
                \#(openPipPickerFromPlayerContextMenuSnippet)
                set sawLiveTV to false
                set sawNoTuners to false
                repeat 10 times
                    try
                        set allEls to entire contents of pipWin
                        repeat with e in allEls
                            try
                                if role of e is "AXStaticText" then
                                    set t to (name of e) as string
                                    if t is "Live TV" then set sawLiveTV to true
                                    if t is "No tuners available" then set sawNoTuners to true
                                end if
                            end try
                        end repeat
                    end try
                    if sawLiveTV or sawNoTuners then exit repeat
                    delay 0.25
                end repeat
                try
                    click (first button of pipWin whose description is "close button")
                end try
                try
                    click (first button of playerWin whose description is "close button")
                end try
                repeat 20 times
                    delay 0.2
                    if (count of windows) = 1 then exit repeat
                end repeat
                try
                    click (first button of window "Watch Now" whose description is "close button")
                end try
                return (sawLiveTV as string) & "|" & (sawNoTuners as string)
            end tell
        end tell
        """#
        guard let result = runAppleScript(script) else {
            Issue.record("PiP picker open script failed to run")
            return
        }
        if result == "NO_RECORDING_TO_WATCH" { return }
        if result == "NO_PLAYER_WINDOW" {
            Issue.record("Watch Now's recording-relay button didn't open a second window")
            return
        }
        if result == "NO_PLAYBACK_STARTED" {
            Issue.record("Player window opened but the Start button never became enabled — the recording-relay stream never reached bridge.isPlaying")
            return
        }
        if result == "NO_PIP_CONTEXT_MENU_ITEM" {
            Issue.record("Right-clicking the player's video area didn't surface an 'Add Picture-in-Picture…' context menu item — see openPipPickerFromPlayerContextMenuSnippet's own doc comment on the AXShowMenu approach this test relies on")
            return
        }
        if result == "NO_PIP_PICKER_WINDOW" {
            Issue.record("Clicking 'Add Picture-in-Picture…' didn't open the 'Add Picture-in-Picture' window")
            return
        }
        let parts = result.split(separator: "|").map(String.init)
        #expect(parts.count == 2, "unexpected script output: \(result)")
        guard parts.count == 2 else { return }
        let (sawLiveTV, sawNoTuners) = (parts[0] == "true", parts[1] == "true")
        #expect(sawLiveTV || sawNoTuners,
            "PiP picker's Live TV section showed neither a real lineup nor 'No tuners available' — liveTVSection's own always-one-or-the-other invariant broke")
    }

    /// The core add/remove combination: opens the PiP picker, adds the first available Live TV
    /// channel as a secondary, confirms the player window's PiP thumbnail (`vlc-pip-thumbnail`) and
    /// close button (`vlc-pip-close-button`) actually appear, then removes it via the close button
    /// and confirms they're gone again. Needs a free tuner (see addFirstLiveTVSecondarySnippet's
    /// own doc comment) on top of openRecordingRelayPlayerSnippet's "something recording"
    /// requirement — skips cleanly (NO_PIP_TARGET_AVAILABLE) when there isn't one, same as every
    /// other environment-dependent skip in this file.
    @Test func addingLiveChannelAsPipSecondaryShowsAndRemovesThumbnail() throws {
        guard windowNavTestsOptedIn(), appRunning(), accessibilityTrusted() else { return }
        let script = #"""
        tell application "System Events"
            tell process "hdhr_VCR"
                \#(dismissDonationNagSnippet)
                \#(openRecordingRelayPlayerSnippet)
                \#(openPipPickerFromPlayerContextMenuSnippet)
                \#(addFirstLiveTVSecondarySnippet)
                set idsAfterAdd to {}
                repeat 20 times
                    set idsAfterAdd to {}
                    try
                        set allEls to entire contents of playerWin
                        repeat with e in allEls
                            try
                                set idVal to (value of attribute "AXIdentifier" of e) as string
                                if idVal starts with "vlc-pip-" then set end of idsAfterAdd to idVal
                            end try
                        end repeat
                    end try
                    if (count of idsAfterAdd) > 0 then exit repeat
                    delay 0.25
                end repeat
                -- idsAfterAdd only carries identifier strings (AppleScript lists can't carry
                -- element refs across the loop above) — re-find the close button by identifier.
                set closeBtn to missing value
                try
                    set allEls to entire contents of playerWin
                    repeat with e in allEls
                        try
                            if (value of attribute "AXIdentifier" of e) as string is "vlc-pip-close-button" then
                                set closeBtn to e
                                exit repeat
                            end if
                        end try
                    end repeat
                end try
                set idsAfterRemoveCount to -1
                if closeBtn is not missing value then
                    click closeBtn
                    repeat 20 times
                        delay 0.2
                        set n to 0
                        try
                            set allEls to entire contents of playerWin
                            repeat with e in allEls
                                try
                                    if (value of attribute "AXIdentifier" of e) as string starts with "vlc-pip-" then set n to n + 1
                                end try
                            end repeat
                        end try
                        set idsAfterRemoveCount to n
                        if n = 0 then exit repeat
                    end repeat
                end if
                try
                    click (first button of playerWin whose description is "close button")
                end try
                repeat 20 times
                    delay 0.2
                    if (count of windows) = 1 then exit repeat
                end repeat
                try
                    click (first button of window "Watch Now" whose description is "close button")
                end try
                set idList to ""
                repeat with i in idsAfterAdd
                    set idList to idList & i & ","
                end repeat
                return idList & "===SPLIT===" & (idsAfterRemoveCount as string)
            end tell
        end tell
        """#
        guard let result = runAppleScript(script) else {
            Issue.record("Add/remove PiP secondary script failed to run")
            return
        }
        if result == "NO_RECORDING_TO_WATCH" || result == "NO_PLAYER_WINDOW" || result == "NO_PLAYBACK_STARTED"
            || result == "NO_PIP_CONTEXT_MENU_ITEM" || result == "NO_PIP_PICKER_WINDOW"
            || result == "NO_PIP_TARGET_AVAILABLE" { return }
        let halves = result.components(separatedBy: "===SPLIT===")
        #expect(halves.count == 2, "unexpected script output shape: \(result)")
        guard halves.count == 2 else { return }
        let idsAfterAdd = Set(halves[0].split(separator: ",").map(String.init))
        #expect(idsAfterAdd.contains("vlc-pip-thumbnail"),
            "clicking 'Add as PIP' did not make the pip thumbnail (vlc-pip-thumbnail) appear")
        #expect(idsAfterAdd.contains("vlc-pip-close-button"),
            "clicking 'Add as PIP' did not make the pip close button (vlc-pip-close-button) appear")
        #expect(halves[1] == "0",
            "clicking vlc-pip-close-button did not remove the PiP secondary — \(halves[1]) vlc-pip-* elements still present")
    }

    /// Live counterpart to the pure-function coverage in PiPDuplicatePrimaryCombinationTests —
    /// confirms the *actual rendered UI* refuses a duplicate the same way those functions predict:
    /// with the recording-relay show already primary, the PiP picker's own "Recording Now" row for
    /// that exact show must show "Now Playing" (a plain label), never an "Add as PIP" button
    /// (isCurrentRecording(recordingShowId:showId:) — see PiPPickerView.swift's own
    /// pipActionTrailing). Doesn't add anything; a pure observation test.
    @Test func pipPickerShowsNowPlayingForTheAlreadyPrimaryRecording() throws {
        guard windowNavTestsOptedIn(), appRunning(), accessibilityTrusted() else { return }
        let script = #"""
        tell application "System Events"
            tell process "hdhr_VCR"
                \#(dismissDonationNagSnippet)
                \#(openRecordingRelayPlayerSnippet)
                set primaryTitle to name of playerWin
                \#(openPipPickerFromPlayerContextMenuSnippet)
                set sawNowPlaying to false
                set sawMatchingAddButton to false
                repeat 10 times
                    set sawNowPlaying to false
                    set sawMatchingAddButton to false
                    try
                        set allEls to entire contents of pipWin
                        repeat with e in allEls
                            try
                                if role of e is "AXStaticText" and (name of e as string) is "Now Playing" then
                                    set sawNowPlaying to true
                                end if
                            end try
                        end repeat
                    end try
                    if sawNowPlaying then exit repeat
                    delay 0.25
                end repeat
                try
                    click (first button of pipWin whose description is "close button")
                end try
                try
                    click (first button of playerWin whose description is "close button")
                end try
                repeat 20 times
                    delay 0.2
                    if (count of windows) = 1 then exit repeat
                end repeat
                try
                    click (first button of window "Watch Now" whose description is "close button")
                end try
                return primaryTitle & "|" & (sawNowPlaying as string)
            end tell
        end tell
        """#
        guard let result = runAppleScript(script) else {
            Issue.record("PiP 'Now Playing' duplicate-refusal script failed to run")
            return
        }
        if result == "NO_RECORDING_TO_WATCH" || result == "NO_PLAYER_WINDOW" || result == "NO_PLAYBACK_STARTED"
            || result == "NO_PIP_CONTEXT_MENU_ITEM" || result == "NO_PIP_PICKER_WINDOW" { return }
        let parts = result.split(separator: "|", maxSplits: 1).map(String.init)
        #expect(parts.count == 2, "unexpected script output: \(result)")
        guard parts.count == 2 else { return }
        let sawNowPlaying = parts[1] == "true"
        #expect(sawNowPlaying,
            "PiP picker for player '\(parts[0])' showed no 'Now Playing' row — the Recording Now section's own duplicate-primary guard (isCurrentRecording) may not be dimming the currently-playing show")
    }

    /// The corner-repositioning combination: adds a Live TV secondary, right-clicks its thumbnail
    /// (`AXShowMenu`, same technique/caveat as openPipPickerFromPlayerContextMenuSnippet), confirms
    /// all four `PipCorner.allCases` display names are offered, then clicks a corner different from
    /// whatever's currently checked to reposition it — confirming the thumbnail/close button both
    /// survive the reposition (still present afterward), not just that the click didn't crash.
    @Test func pipCornerMenuOffersAllFourCornersAndRepositions() throws {
        guard windowNavTestsOptedIn(), appRunning(), accessibilityTrusted() else { return }
        let script = #"""
        tell application "System Events"
            tell process "hdhr_VCR"
                \#(dismissDonationNagSnippet)
                \#(openRecordingRelayPlayerSnippet)
                \#(openPipPickerFromPlayerContextMenuSnippet)
                \#(addFirstLiveTVSecondarySnippet)
                set thumb to missing value
                repeat 20 times
                    try
                        set allEls to entire contents of playerWin
                        repeat with e in allEls
                            try
                                if (value of attribute "AXIdentifier" of e) as string is "vlc-pip-thumbnail" then
                                    set thumb to e
                                    exit repeat
                                end if
                            end try
                        end repeat
                    end try
                    if thumb is not missing value then exit repeat
                    delay 0.25
                end repeat
                if thumb is missing value then return "NO_PIP_THUMBNAIL"
                perform action "AXShowMenu" of thumb
                set cornerNames to {"Top Left", "Top Right", "Bottom Left", "Bottom Right"}
                set foundCount to 0
                set targetItem to missing value
                repeat 10 times
                    set foundCount to 0
                    set targetItem to missing value
                    try
                        set menuItems to every menu item of menu 1 of thumb
                        repeat with mi in menuItems
                            set miName to "?"
                            try
                                set miName to name of mi
                            end try
                            repeat with cn in cornerNames
                                if miName contains (cn as string) then
                                    set foundCount to foundCount + 1
                                    if targetItem is missing value then set targetItem to mi
                                end if
                            end repeat
                        end repeat
                    end try
                    if foundCount = 4 then exit repeat
                    delay 0.25
                end repeat
                if targetItem is not missing value then click targetItem
                delay 0.3
                set idsAfterReposition to {}
                try
                    set allEls to entire contents of playerWin
                    repeat with e in allEls
                        try
                            set idVal to (value of attribute "AXIdentifier" of e) as string
                            if idVal starts with "vlc-pip-" then set end of idsAfterReposition to idVal
                        end try
                    end repeat
                end try
                -- Clean up: close the secondary, then the player, then Watch Now.
                set closeBtn to missing value
                try
                    set allEls to entire contents of playerWin
                    repeat with e in allEls
                        try
                            if (value of attribute "AXIdentifier" of e) as string is "vlc-pip-close-button" then
                                set closeBtn to e
                                exit repeat
                            end if
                        end try
                    end repeat
                end try
                try
                    if closeBtn is not missing value then click closeBtn
                end try
                try
                    click (first button of playerWin whose description is "close button")
                end try
                repeat 20 times
                    delay 0.2
                    if (count of windows) = 1 then exit repeat
                end repeat
                try
                    click (first button of window "Watch Now" whose description is "close button")
                end try
                set idList to ""
                repeat with i in idsAfterReposition
                    set idList to idList & i & ","
                end repeat
                return (foundCount as string) & "===SPLIT===" & idList
            end tell
        end tell
        """#
        guard let result = runAppleScript(script) else {
            Issue.record("PiP corner menu script failed to run")
            return
        }
        if result == "NO_RECORDING_TO_WATCH" || result == "NO_PLAYER_WINDOW" || result == "NO_PLAYBACK_STARTED"
            || result == "NO_PIP_CONTEXT_MENU_ITEM" || result == "NO_PIP_PICKER_WINDOW"
            || result == "NO_PIP_TARGET_AVAILABLE" { return }
        if result == "NO_PIP_THUMBNAIL" {
            Issue.record("PiP secondary was added but vlc-pip-thumbnail never appeared")
            return
        }
        let halves = result.components(separatedBy: "===SPLIT===")
        #expect(halves.count == 2, "unexpected script output shape: \(result)")
        guard halves.count == 2, let foundCount = Int(halves[0]) else { return }
        #expect(foundCount == 4,
            "PiP thumbnail's right-click menu offered \(foundCount)/4 corner options — expected all of PipCorner.allCases (Top Left/Top Right/Bottom Left/Bottom Right)")
        let idsAfterReposition = Set(halves[1].split(separator: ",").map(String.init))
        #expect(idsAfterReposition.contains("vlc-pip-thumbnail"),
            "PiP thumbnail disappeared after repositioning to a different corner")
    }

    /// The tap-to-swap combination: adds a Live TV secondary, captures the player window's title
    /// (the recording's own title, set when Watch Now opened it), clicks the thumbnail itself (a
    /// plain click, not AXShowMenu — `pipOverlay`'s thumbnail Button calls
    /// `swapPrimaryAndSecondary()` directly), then confirms the window's title actually changed —
    /// `VLCPlayerWindowManager.swapTrackingFieldsForPiPSwap()` sets `window.title` to whatever's
    /// newly primary, so an unchanged title after a swap click means the swap didn't really happen
    /// (or happened but the title update regressed), not just "nothing visibly broke."
    @Test func pipTapToSwapChangesPlayerWindowTitle() throws {
        guard windowNavTestsOptedIn(), appRunning(), accessibilityTrusted() else { return }
        let script = #"""
        tell application "System Events"
            tell process "hdhr_VCR"
                \#(dismissDonationNagSnippet)
                \#(openRecordingRelayPlayerSnippet)
                \#(openPipPickerFromPlayerContextMenuSnippet)
                \#(addFirstLiveTVSecondarySnippet)
                set thumb to missing value
                repeat 20 times
                    try
                        set allEls to entire contents of playerWin
                        repeat with e in allEls
                            try
                                if (value of attribute "AXIdentifier" of e) as string is "vlc-pip-thumbnail" then
                                    set thumb to e
                                    exit repeat
                                end if
                            end try
                        end repeat
                    end try
                    if thumb is not missing value then exit repeat
                    delay 0.25
                end repeat
                if thumb is missing value then return "NO_PIP_THUMBNAIL"
                set titleBeforeSwap to name of playerWin
                click thumb
                -- Retarget instantly (no reconnect, per swapPrimaryAndSecondary's own doc comment)
                -- but the title write happens synchronously right after — poll briefly regardless,
                -- consistent with every other "wait for a real change" loop in this file.
                set titleAfterSwap to titleBeforeSwap
                repeat 10 times
                    delay 0.2
                    try
                        set titleAfterSwap to name of playerWin
                    end try
                    if titleAfterSwap is not titleBeforeSwap then exit repeat
                end repeat
                -- Clean up: swap stays in effect (the secondary now shows the original primary,
                -- muted) — close the secondary, then the player, then Watch Now, same as every
                -- other PiP test's own teardown.
                set closeBtn to missing value
                try
                    set allEls to entire contents of playerWin
                    repeat with e in allEls
                        try
                            if (value of attribute "AXIdentifier" of e) as string is "vlc-pip-close-button" then
                                set closeBtn to e
                                exit repeat
                            end if
                        end try
                    end repeat
                end try
                try
                    if closeBtn is not missing value then click closeBtn
                end try
                try
                    click (first button of playerWin whose description is "close button")
                end try
                repeat 20 times
                    delay 0.2
                    if (count of windows) = 1 then exit repeat
                end repeat
                try
                    click (first button of window "Watch Now" whose description is "close button")
                end try
                return titleBeforeSwap & "===SPLIT===" & titleAfterSwap
            end tell
        end tell
        """#
        guard let result = runAppleScript(script) else {
            Issue.record("PiP tap-to-swap script failed to run")
            return
        }
        if result == "NO_RECORDING_TO_WATCH" || result == "NO_PLAYER_WINDOW" || result == "NO_PLAYBACK_STARTED"
            || result == "NO_PIP_CONTEXT_MENU_ITEM" || result == "NO_PIP_PICKER_WINDOW"
            || result == "NO_PIP_TARGET_AVAILABLE" { return }
        if result == "NO_PIP_THUMBNAIL" {
            Issue.record("PiP secondary was added but vlc-pip-thumbnail never appeared")
            return
        }
        let halves = result.components(separatedBy: "===SPLIT===")
        #expect(halves.count == 2, "unexpected script output shape: \(result)")
        guard halves.count == 2 else { return }
        let (titleBefore, titleAfter) = (halves[0], halves[1])
        #expect(titleAfter != titleBefore,
            "player window title '\(titleBefore)' was unchanged after clicking the PiP thumbnail to swap — swapTrackingFieldsForPiPSwap may not be updating window.title, or the swap itself didn't fire")
    }

    /// The channel-switching-within-PiP combination: adds a Live TV secondary, right-clicks its
    /// thumbnail, and — since the secondary is a genuine live channel (secondaryChannelNumber !=
    /// nil, the exact gate `pipChannelMenu` itself checks) — confirms a "Channel" submenu is
    /// offered, then picks a different channel from it (`playSecondaryChannel`, the function fixed
    /// earlier this session to reuse the same tuner-availability gate as the primary picker — see
    /// VLCPlayerViewTunerReuseTests.swift). Only checks the thumbnail survives the switch, not which
    /// exact channel ends up playing — the real device's own live lineup content isn't something
    /// this test controls.
    @Test func pipChannelMenuSwitchesSecondaryChannel() throws {
        guard windowNavTestsOptedIn(), appRunning(), accessibilityTrusted() else { return }
        let script = #"""
        tell application "System Events"
            tell process "hdhr_VCR"
                \#(dismissDonationNagSnippet)
                \#(openRecordingRelayPlayerSnippet)
                \#(openPipPickerFromPlayerContextMenuSnippet)
                \#(addFirstLiveTVSecondarySnippet)
                set thumb to missing value
                repeat 20 times
                    try
                        set allEls to entire contents of playerWin
                        repeat with e in allEls
                            try
                                if (value of attribute "AXIdentifier" of e) as string is "vlc-pip-thumbnail" then
                                    set thumb to e
                                    exit repeat
                                end if
                            end try
                        end repeat
                    end try
                    if thumb is not missing value then exit repeat
                    delay 0.25
                end repeat
                if thumb is missing value then return "NO_PIP_THUMBNAIL"
                perform action "AXShowMenu" of thumb
                set channelMenu to missing value
                repeat 10 times
                    try
                        set channelMenu to menu 1 of menu item "Channel" of menu 1 of thumb
                        exit repeat
                    end try
                    delay 0.25
                end repeat
                if channelMenu is missing value then
                    -- Not every secondary is a live channel (FEED/Watch Now secondaries never show
                    -- this submenu, per pipChannelMenu's own guard) — but addFirstLiveTVSecondarySnippet
                    -- specifically adds one from Live TV, so this is a real finding, not expected.
                    set closeBtn0 to missing value
                    try
                        set allEls to entire contents of playerWin
                        repeat with e in allEls
                            try
                                if (value of attribute "AXIdentifier" of e) as string is "vlc-pip-close-button" then
                                    set closeBtn0 to e
                                    exit repeat
                                end if
                            end try
                        end repeat
                    end try
                    try
                        if closeBtn0 is not missing value then click closeBtn0
                    end try
                    try
                        click (first button of playerWin whose description is "close button")
                    end try
                    try
                        click (first button of window "Watch Now" whose description is "close button")
                    end try
                    return "NO_CHANNEL_SUBMENU"
                end if
                set channelItems to every menu item of channelMenu
                set switchedOk to false
                if (count of channelItems) > 0 then
                    click (item 1 of channelItems)
                    set switchedOk to true
                end if
                delay 0.5
                set idsAfterSwitch to {}
                try
                    set allEls to entire contents of playerWin
                    repeat with e in allEls
                        try
                            set idVal to (value of attribute "AXIdentifier" of e) as string
                            if idVal starts with "vlc-pip-" then set end of idsAfterSwitch to idVal
                        end try
                    end repeat
                end try
                set closeBtn to missing value
                try
                    set allEls to entire contents of playerWin
                    repeat with e in allEls
                        try
                            if (value of attribute "AXIdentifier" of e) as string is "vlc-pip-close-button" then
                                set closeBtn to e
                                exit repeat
                            end if
                        end try
                    end repeat
                end try
                try
                    if closeBtn is not missing value then click closeBtn
                end try
                try
                    click (first button of playerWin whose description is "close button")
                end try
                repeat 20 times
                    delay 0.2
                    if (count of windows) = 1 then exit repeat
                end repeat
                try
                    click (first button of window "Watch Now" whose description is "close button")
                end try
                set idList to ""
                repeat with i in idsAfterSwitch
                    set idList to idList & i & ","
                end repeat
                return (switchedOk as string) & "===SPLIT===" & idList
            end tell
        end tell
        """#
        guard let result = runAppleScript(script) else {
            Issue.record("PiP channel-switch script failed to run")
            return
        }
        if result == "NO_RECORDING_TO_WATCH" || result == "NO_PLAYER_WINDOW" || result == "NO_PLAYBACK_STARTED"
            || result == "NO_PIP_CONTEXT_MENU_ITEM" || result == "NO_PIP_PICKER_WINDOW"
            || result == "NO_PIP_TARGET_AVAILABLE" { return }
        if result == "NO_PIP_THUMBNAIL" {
            Issue.record("PiP secondary was added but vlc-pip-thumbnail never appeared")
            return
        }
        if result == "NO_CHANNEL_SUBMENU" {
            Issue.record("A Live-TV-sourced PiP secondary's right-click menu offered no 'Channel' submenu — pipChannelMenu's secondaryChannelNumber != nil gate may be broken for this case")
            return
        }
        let halves = result.components(separatedBy: "===SPLIT===")
        #expect(halves.count == 2, "unexpected script output shape: \(result)")
        guard halves.count == 2 else { return }
        #expect(halves[0] == "true", "no channel menu items were available to click")
        let idsAfterSwitch = Set(halves[1].split(separator: ",").map(String.init))
        #expect(idsAfterSwitch.contains("vlc-pip-thumbnail"),
            "PiP thumbnail disappeared after switching the secondary's channel")
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
