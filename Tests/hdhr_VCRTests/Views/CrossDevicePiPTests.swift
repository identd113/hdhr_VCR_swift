import Testing
import Foundation
@testable import hdhr_VCR

// MARK: - Primary on one HDHomeRun, picture-in-picture on another (opt-in, drives the real app)
//
// Plays a live channel on device A as the primary, then — from Watch Now with the *other* device's segment
// selected — adds a live channel on device B as the PiP, and checks every tuner count separately:
//   • each device's own hardware `status.json` (tuners with a channel locked),
//   • what the app believes for each device (the `"a"` field the web guide embeds per device).
// Each must go up by exactly one on its own device and the other device must not move; closing everything
// must return both to where they started (no leak, no cross-device phantom).
//
// Needs two reachable devices that each have a free tuner — e.g. the real tuner plus `tools/mock_tuner.py`
// run on ANOTHER Mac (see MultiDeviceTests's header for why another Mac and why port 80). Uses no recording.
// Skips LOUDLY (stderr) when the environment can't provide that — never silently.
//
//   RUN_WINDOW_NAV_TESTS=1 swift test --filter CrossDevicePiPTests

@Suite("Cross-device PiP (requires running app + Accessibility + 2 devices with a free tuner each)", .serialized)
struct CrossDevicePiPTests {

    private struct Counts: Equatable { var hw: Int; var app: Int; var total: Int }

    private func say(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

    private func fetch(_ url: String, timeout: Int = 6) -> String {
        let t = Process()
        t.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        t.arguments = ["-s", "-m", "\(timeout)", url]
        let p = Pipe(); t.standardOutput = p; t.standardError = Pipe()
        do { try t.run() } catch { return "" }
        let d = p.fileHandleForReading.readDataToEndOfFile(); t.waitUntilExit()
        return String(data: d, encoding: .utf8) ?? ""
    }

    /// Every device the web guide embeds a tuner object for, with its counts (nil = not reachable / no data).
    private func snapshot(_ page: String, _ id: String) -> Counts? {
        guard let r = page.range(of: "\"\(id)\":\\{[^}]*\\}", options: .regularExpression) else { return nil }
        let objText = String(page[r].dropFirst(id.count + 3))
        guard let obj = try? JSONSerialization.jsonObject(with: Data(objText.utf8)) as? [String: Any],
              let app = obj["a"] as? Int, let total = obj["t"] as? Int, total > 0,
              let surl = (obj["surl"] as? String)?.replacingOccurrences(of: "\\/", with: "/"),
              let data = fetch(surl, timeout: 4).data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        return Counts(hw: arr.filter { $0["VctNumber"] != nil || $0["Frequency"] != nil || $0["TargetIP"] != nil }.count, app: app, total: total)
    }

    private func deviceIDsInPage(_ page: String) -> [String] {
        var seen: [String] = []
        let re = try! NSRegularExpression(pattern: #""([0-9A-F]{8})":\{[^}]*"surl""#)   // key order inside the object isn't stable
        for m in re.matches(in: page, range: NSRange(page.startIndex..., in: page)) {
            if let r = Range(m.range(at: 1), in: page) {
                let id = String(page[r])
                if !seen.contains(id) { seen.append(id) }
            }
        }
        return seen
    }

    /// Titles of channels currently being recorded on a device (their plain "Watch" row would share the
    /// recording's tuner, so the test never picks them as its live primary).
    private func recordingTitles(on id: String) -> [String] {
        guard let data = fetch("http://localhost:1980/api/now.json", timeout: 8).data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.filter { ($0["deviceId"] as? String) == id && ($0["isRecording"] as? Bool) == true }
                  .compactMap { $0["title"] as? String }
    }

    private let handlers = #"""
    on playerWin()
        tell application "System Events" to tell process "hdhr_VCR"
            repeat with w in windows
                try
                    set n to name of w
                    if n is not "Watch Now" and n is not "Add PiP" and n is not "Support hdhrVCRplus" and n is not "Add Show" then return w
                end try
            end repeat
        end tell
        return missing value
    end playerWin

    on windowNamed(nm)
        tell application "System Events" to tell process "hdhr_VCR"
            repeat with w in windows
                try
                    if (name of w) is nm then return w
                end try
            end repeat
        end tell
        return missing value
    end windowNamed

    -- First plain live "Watch <title>" button (not the recording-relay buttons, not the PiP "alongside" ones,
    -- not a title in skipList).
    on findLiveWatch(el, skipList)
        tell application "System Events"
            try
                set kids to UI elements of el
            on error
                return missing value
            end try
            repeat with k in kids
                try
                    if role of k is "AXButton" then
                        set hlp to (help of k) as string
                        if hlp starts with "Watch " and hlp does not end with "alongside what's already open" and hlp is not in skipList then return k
                    end if
                end try
                set hit to my findLiveWatch(k, skipList)
                if hit is not missing value then return hit
            end repeat
        end tell
        return missing value
    end findLiveWatch

    -- The Watch Now Tuner picker's segment for a device (an AXRadioButton whose description is the device ID).
    on findSegment(el, devId)
        tell application "System Events"
            try
                set kids to UI elements of el
            on error
                return missing value
            end try
            repeat with k in kids
                try
                    if role of k is "AXRadioButton" and (description of k as string) is devId then return k
                end try
                set hit to my findSegment(k, devId)
                if hit is not missing value then return hit
            end repeat
        end tell
        return missing value
    end findSegment

    on hasPipThumb(win)
        return my hasId(win, "vlc-pip-thumbnail")
    end hasPipThumb

    on hasId(el, ident)
        tell application "System Events"
            try
                set kids to UI elements of el
            on error
                return false
            end try
            repeat with k in kids
                try
                    if ((value of attribute "AXIdentifier" of k) as string) is ident then return true
                end try
                if my hasId(k, ident) then return true
            end repeat
        end tell
        return false
    end hasId

    on closeAll()
        tell application "System Events" to tell process "hdhr_VCR"
            repeat 3 times
                repeat with w in windows
                    try
                        set n to name of w
                        if n is not "Support hdhrVCRplus" then click (first button of w whose description is "close button")
                    end try
                end repeat
                delay 0.4
            end repeat
        end tell
    end closeAll
    """#

    /// Plays a live channel on `a` in a new player, then adds a live PiP from `b`. Returns "OK" or a sentinel.
    private func openScript(primary a: String, pip b: String, skip: [String]) -> String {
        let skipList = "{" + skip.map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }.joined(separator: ", ") + "}"
        return """
        \(pipAXHandlers(uiEvents: ""))
        \(handlers)
        tell application "System Events" to tell process "hdhr_VCR"
            \(dismissDonationNagSnippet)
            click menu item "Watch Now…" of menu 1 of menu bar item 1 of menu bar 2
            set wn to missing value
            repeat 30 times
                delay 0.4
                set wn to my windowNamed("Watch Now")
                if wn is not missing value then exit repeat
            end repeat
            if wn is missing value then return "NO_WATCH_NOW"
            -- primary: device A's segment, first plain live channel
            set segA to missing value
            repeat 20 times
                set segA to my findSegment(wn, "\(a)")
                if segA is not missing value then exit repeat
                delay 0.4
            end repeat
            if segA is missing value then return "NO_SEGMENT_A"
            click segA
            delay 1.5
            set liveBtn to missing value
            repeat 20 times
                set liveBtn to my findLiveWatch(wn, \(skipList))
                if liveBtn is not missing value then exit repeat
                delay 0.5
            end repeat
            if liveBtn is missing value then
                my closeAll()
                return "NO_LIVE_WATCH_ON_A"
            end if
            click liveBtn
            set pw to missing value
            repeat 40 times
                delay 0.5
                set pw to my playerWin()
                if pw is not missing value then exit repeat
            end repeat
            if pw is missing value then
                my closeAll()
                return "NO_PLAYER_WINDOW"
            end if
            -- PiP: back to Watch Now, device B's segment, a row's "Watch alongside" button
            set wn to my windowNamed("Watch Now")
            if wn is missing value then
                click menu item "Watch Now…" of menu 1 of menu bar item 1 of menu bar 2
                repeat 30 times
                    delay 0.4
                    set wn to my windowNamed("Watch Now")
                    if wn is not missing value then exit repeat
                end repeat
            end if
            if wn is missing value then return "NO_WATCH_NOW_FOR_PIP"
            set segB to missing value
            repeat 20 times
                set segB to my findSegment(wn, "\(b)")
                if segB is not missing value then exit repeat
                delay 0.4
            end repeat
            if segB is missing value then return "NO_SEGMENT_B"
            click segB
            delay 2
            set rowBtn to missing value
            repeat 30 times
                set rowBtn to my findWhere(wn, "pipLive", "")
                if rowBtn is not missing value then exit repeat
                delay 0.5
            end repeat
            if rowBtn is missing value then return "NO_PIP_BUTTON_ON_B"
            click rowBtn
            repeat 40 times
                set pw to my playerWin()
                if pw is not missing value and my hasPipThumb(pw) then return "OK"
                delay 0.5
            end repeat
            return "NO_PIP_THUMBNAIL"
        end tell
        """
    }

    @Test func primaryOnOneDeviceAndPipOnAnother_countsStayPerDevice() throws {
        guard windowNavTestsOptedIn(), appRunning(), accessibilityTrusted() else { return }

        let page0 = fetch("http://localhost:1980/", timeout: 10)
        let ids = deviceIDsInPage(page0).filter { snapshot(page0, $0) != nil }
        let usable = ids.filter { id in snapshot(page0, id).map { $0.total - $0.hw >= 1 } ?? false }
        guard usable.count >= 2 else {
            say("CrossDevicePiPTests SKIPPED: need 2 reachable devices with a free tuner each; have \(usable) of \(ids)")
            return
        }
        let (a, b) = (usable[0], usable[1])
        guard let baseA = snapshot(page0, a), let baseB = snapshot(page0, b) else { return }
        say("cross-device: primary on \(a) (hw \(baseA.hw), app \(baseA.app) of \(baseA.total)), PiP on \(b) (hw \(baseB.hw), app \(baseB.app) of \(baseB.total))")
        defer { _ = runAppleScript(#"""
            \#(pipAXHandlers(uiEvents: ""))
            \#(handlers)
            my closeAll()
            """#) }

        guard let result = runAppleScript(openScript(primary: a, pip: b, skip: recordingTitles(on: a).map { "Watch \($0)" })) else {
            Issue.record("cross-device open script failed to run")
            return
        }
        #expect(result == "OK", "couldn't set up primary on \(a) + PiP on \(b): \(result)")
        guard result == "OK" else { return }

        // Both counts must settle at base+1 on their OWN device, with the app agreeing with the hardware.
        var trail: [String] = []
        var settled = false
        for i in 0..<40 {
            Thread.sleep(forTimeInterval: 1)
            let p = fetch("http://localhost:1980/", timeout: 8)
            guard let ca = snapshot(p, a), let cb = snapshot(p, b) else { continue }
            if i % 4 == 0 { trail.append("t+\(i + 1)s A hw/app \(ca.hw)/\(ca.app)  B hw/app \(cb.hw)/\(cb.app)") }
            if ca.hw == baseA.hw + 1, ca.app == baseA.app + 1, cb.hw == baseB.hw + 1, cb.app == baseB.app + 1 { settled = true; break }
        }
        say(trail.joined(separator: "\n"))
        #expect(settled, "tuner counts never settled at +1 on each device (A \(a) base \(baseA.hw)/\(baseA.app), B \(b) base \(baseB.hw)/\(baseB.app)); trail: \(trail)")

        // Close everything: both devices must return to where they started.
        _ = runAppleScript(#"""
            \#(pipAXHandlers(uiEvents: ""))
            \#(handlers)
            my closeAll()
            """#)
        var back = false
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 1)
            let p = fetch("http://localhost:1980/", timeout: 8)
            guard let ca = snapshot(p, a), let cb = snapshot(p, b) else { continue }
            if ca.hw == baseA.hw, ca.app == baseA.app, cb.hw == baseB.hw, cb.app == baseB.app { back = true; break }
        }
        #expect(back, "counts didn't return to base after closing — a tuner leaked or a phantom count stuck")
    }
}
