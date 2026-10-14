import Testing
import Foundation
@testable import hdhr_VCR

// MARK: - Multi-device representation (opt-in, drives the real running app)
//
// With two or more usable HDHomeRun devices the app must show *each* one — in the menu bar menu, in the web
// guide (a tuner box plus that device's own guide blocks), and in Watch Now's Tuner picker. Needs no free tuner,
// so it runs alongside real recordings. A second device is easiest to get with `tools/mock_tuner.py` run on
// ANOTHER Mac (it must have its own IP: the app keeps one UDP discovery reply per sender IP, and its own FEED
// relay already answers from this Mac's address) — `--mirror <real-ip> --no-auth --guide-file <guide.json>`, root
// for port 80 (the app fetches a device's guide from port 80 regardless of the advertised port). See
// docs/LiveUITests.md. With fewer than two usable devices every check says so on stderr and returns — it never
// passes silently.
//
//   RUN_WINDOW_NAV_TESTS=1 swift test --filter MultiDeviceTests

@Suite("Multi-device representation (requires running app + Accessibility + 2 devices)", .serialized)
struct MultiDeviceTests {

    /// Devices shown as usable in the menu bar menu: rows like "105404BE  2/2" (occupied/total). Excludes
    /// "— ⚠ unavailable" ghosts and the virtual FEED relay.
    private func usableMenuDeviceIDs() -> [String]? {
        let script = """
        tell application "System Events"
            tell process "hdhr_VCR"
                set out to {}
                repeat with mi in (menu items of menu 1 of menu bar item 1 of menu bar 2)
                    try
                        set n to name of mi
                        if n is not missing value then set end of out to n
                    end try
                end repeat
                set AppleScript's text item delimiters to "\\n"
                return out as text
            end tell
        end tell
        """
        guard let raw = runAppleScript(script) else { return nil }
        var ids: [String] = []
        for line in raw.split(separator: "\n") {
            let s = String(line)
            guard let m = s.range(of: #"^[0-9A-F]{8}\s+\d+/\d+"#, options: .regularExpression) else { continue }
            let id = String(s[m].prefix(8))
            if id.hasPrefix("FEED") || id.hasPrefix("FFFF") { continue }
            ids.append(id)
        }
        return ids
    }

    private func skipUnlessTwoDevices(_ ids: [String]?) -> [String]? {
        guard let ids else {
            Issue.record("could not read the menu bar menu")
            return nil
        }
        guard ids.count >= 2 else {
            FileHandle.standardError.write("MultiDeviceTests SKIPPED: only \(ids.count) usable device(s) in the menu (\(ids)); needs 2+ — see this file's header\n".data(using: .utf8)!)
            return nil
        }
        return ids
    }

    @Test func menuListsEveryUsableDevice() throws {
        guard windowNavTestsOptedIn(), appRunning(), accessibilityTrusted() else { return }
        guard let ids = skipUnlessTwoDevices(usableMenuDeviceIDs()) else { return }
        #expect(Set(ids).count == ids.count, "a device is listed twice in the menu: \(ids)")
    }

    @Test func webGuideRendersEachDeviceWithItsOwnGuide() throws {
        guard windowNavTestsOptedIn(), appRunning(), accessibilityTrusted() else { return }
        guard let ids = skipUnlessTwoDevices(usableMenuDeviceIDs()) else { return }
        guard let url = URL(string: "http://localhost:1980/"),
              let html = try? String(contentsOf: url, encoding: .utf8) else {
            Issue.record("could not load the web guide from localhost:1980")
            return
        }
        for id in ids {
            #expect(html.contains("id=\"tdrop-\(id)\""), "web guide has no tuner box for \(id)")
            let blocks = html.components(separatedBy: "data-dev=\"\(id)\"").count - 1
            #expect(blocks > 0, "web guide has no guide blocks for \(id) — its guide didn't load or isn't rendered")
        }
    }

    @Test func watchNowTunerPickerOffersEveryUsableDevice() throws {
        guard windowNavTestsOptedIn(), appRunning(), accessibilityTrusted() else { return }
        guard let ids = skipUnlessTwoDevices(usableMenuDeviceIDs()) else { return }
        // findWhere (PiPAXHelpers) locates the radio group natively via ax_query; a System Events walk of the
        // whole Watch Now window (every channel row) took minutes and `entire contents` returns nothing here.
        let script = """
        \(pipAXHandlers(uiEvents: ""))

        tell application "System Events"
            tell process "hdhr_VCR"
                \(dismissDonationNagSnippet)
                click menu item "Watch Now…" of menu 1 of menu bar item 1 of menu bar 2
                repeat 20 times
                    delay 0.25
                    if (count of windows) > 0 then exit repeat
                end repeat
                -- The Tuner picker is a segmented control: AX shows it as an AXRadioGroup whose
                -- AXRadioButton segments carry the device ID in their description.
                set names to "NO_PICKER"
                repeat 12 times
                    try
                        set rg to my findWhere(window "Watch Now", "role", "AXRadioGroup")
                        if rg is not missing value then
                            set found to {}
                            repeat with rb in (UI elements of rg)
                                set end of found to (description of rb as text)
                            end repeat
                            set AppleScript's text item delimiters to "|"
                            set names to found as text
                            set AppleScript's text item delimiters to ""
                        end if
                    end try
                    if names is not "NO_PICKER" then exit repeat
                    delay 0.25
                end repeat
                try
                    click (first button of window "Watch Now" whose description is "close button")
                end try
                return names
            end tell
        end tell
        """
        guard let result = runAppleScript(script) else {
            Issue.record("Watch Now tuner-picker script failed to run")
            return
        }
        if result == "NO_PICKER" {
            Issue.record("Watch Now has no Tuner picker although \(ids.count) devices are usable")
            return
        }
        for id in ids {
            #expect(result.contains(id), "Watch Now's Tuner picker (segmented control) doesn't offer \(id) (offers: \(result))")
        }
    }
}
