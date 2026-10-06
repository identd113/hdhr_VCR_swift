import Testing
import Foundation
import AppKit
@testable import hdhr_VCR

// MARK: - PiP / FEED / window churn — a tuner-state soak against the live app
//
// Purpose: *catch something happening*. A seeded random walk over the player window and its picture-in-
// picture — open on a recording or a FEED, add a live or FEED PiP, close it, swap, change either stream's
// channel, move the PiP between corners, move/resize the player window, close it — with a model of how many
// real tuners that state should be holding. After EVERY step it polls the two sources of tuner truth until
// they agree with the model (or a timeout expires):
//   • hardware: the HDHomeRun's own status.json (tuners with a channel locked), and
//   • the app's view: the `"a"` count the web guide embeds (= AppState.activeTunerCount).
// It also checks the UI geometry (PiP thumbnail present iff the model has a PiP, and inside the player
// window; the player window on-screen; no stray windows) and, at the end, scans the app log for errors.
//
// What it catches: a tuner still locked after its PiP/player closed (leak), a tuner counted that isn't
// held (phantom), a tuner not released within the device's slow-release window, a channel change that
// briefly needs a second tuner, FEED/recording-relay streams that wrongly cost a tuner, a PiP that
// disappears or detaches on a window move/resize, windows that pile up. Failures print the seed and the
// whole step trail, so a run can be replayed: HDHR_CHURN_SEED=… HDHR_CHURN_STEPS=….
//
// Opt-in like the rest of the live UI tests: RUN_WINDOW_NAV_TESTS=1, app running, Accessibility granted.
//   RUN_WINDOW_NAV_TESTS=1 swift test --filter PiPTunerChurnTests
// The FEED test additionally needs `ssh laptop` (key auth) with this repo + the app on the laptop, and makes
// the *laptop* the recording Mac — a shared tuner only ever has one Mac's FEED relay (first recorder wins).

// MARK: model

private enum Slot: String { case none, rec, live, feed }

private struct World {
    var player = false
    var primary = Slot.none
    var pip = Slot.none
    var liveCount: Int { (primary == .live ? 1 : 0) + (pip == .live ? 1 : 0) }
}

private enum Op: String, CaseIterable {
    case openOnRecording, openOnFeed, addLivePip, addFeedPip, closePip, swap
    case pipChannel, pipCorner, primaryToLive, primaryChannel, moveWindow, resizeWindow, closePlayer
}

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: shell + tuner probes

private func sh(_ exe: String, _ args: [String], timeout: TimeInterval = 60) -> (status: Int32, out: String) {
    let t = Process()
    t.executableURL = URL(fileURLWithPath: exe)
    t.arguments = args
    let pipe = Pipe()
    t.standardOutput = pipe
    t.standardError = pipe
    do { try t.run() } catch { return (-1, "\(error)") }
    let killer = DispatchWorkItem { if t.isRunning { t.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()   // returns when the process exits (or is killed)
    t.waitUntilExit()
    killer.cancel()
    return (t.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

private func curl(_ url: String, timeout: Int = 6) -> String {
    let t = Process()
    t.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    t.arguments = ["-s", "-m", "\(timeout)", url]
    let pipe = Pipe()
    t.standardOutput = pipe
    t.standardError = FileHandle.nullDevice
    do { try t.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    t.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

private struct Tuners: CustomStringConvertible {
    var app: Int?          // AppState.activeTunerCount, as embedded in the web guide
    var hw: Int?           // tuners with a channel locked, per the device's own status.json
    var total: Int?
    var description: String { "app=\(app.map(String.init) ?? "?") hw=\(hw.map(String.init) ?? "?") total=\(total.map(String.init) ?? "?")" }
}

private func discoverDeviceID() -> String? {
    let page = curl("http://127.0.0.1:1980/", timeout: 10)
    guard let r = page.range(of: #""([0-9A-F]{8})":\{"nt":"#, options: .regularExpression) ?? page.range(of: #""([0-9A-F]{8})":\{[^}]*"surl""#, options: .regularExpression)
    else { return nil }
    let ids = page[r].split(separator: "\"").map(String.init).filter { $0.count == 8 }
    return ids.first
}

private func tunerSnapshot(deviceID: String) -> Tuners {
    var out = Tuners()
    let page = curl("http://127.0.0.1:1980/", timeout: 10)
    guard let r = page.range(of: "\"\(deviceID)\":\\{[^}]*\\}", options: .regularExpression) else { return out }
    let objText = "{" + page[r].dropFirst(deviceID.count + 3)
    guard let obj = try? JSONSerialization.jsonObject(with: Data(objText.utf8)) as? [String: Any] else { return out }
    out.app = obj["a"] as? Int
    out.total = obj["t"] as? Int
    if let surl = (obj["surl"] as? String)?.replacingOccurrences(of: "\\/", with: "/"),
       let data = curl(surl, timeout: 4).data(using: .utf8),
       let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
        out.hw = arr.filter { $0["VctNumber"] != nil }.count
    }
    return out
}

// MARK: scripts

private let churnHandlers = #"""
on playerWin()
    tell application "System Events" to tell process "hdhr_VCR"
        repeat with w in windows
            set n to name of w
            if n is not "Watch Now" and n is not "Add Picture-in-Picture" and n is not "Support hdhrVCRplus" then return w
        end repeat
    end tell
    return missing value
end playerWin

-- "x,y,w,h" of an element, or "-" when it's missing.
on frameOf(el)
    if el is missing value then return "-"
    tell application "System Events"
        try
            set p to position of el
            set s to size of el
            return ((item 1 of p) as string) & "," & ((item 2 of p) as string) & "," & ((item 1 of s) as string) & "," & ((item 2 of s) as string)
        on error
            return "-"
        end try
    end tell
end frameOf

-- Waits until the player window has no "Connecting…/Starting…" status element (it is playing).
on waitPlaying(win)
    repeat 60 times
        if (my findById(win, "vlc-start-status")) is missing value then return true
        delay 0.5
    end repeat
    return false
end waitPlaying

on closeExtraWindows()
    tell application "System Events" to tell process "hdhr_VCR"
        repeat with nm in {"Add Picture-in-Picture", "Watch Now"}
            try
                click (first button of window (nm as string) whose description is "close button")
            end try
        end repeat
    end tell
end closeExtraWindows
"""#

private func wrap(_ uiEvents: String, _ body: String) -> String {
    """
    \(pipAXHandlers(uiEvents: uiEvents))
    \(churnHandlers)
    tell application "System Events"
        tell process "hdhr_VCR"
    \(body)
        end tell
    end tell
    """
}

private func script(for op: Op, uiEvents: String, rng: inout SplitMix64, world: World) -> String {
    switch op {
    case .openOnRecording:
        return wrap(uiEvents, #"""
        click menu item "Watch Now…" of menu 1 of menu bar item 1 of menu bar 2
        set watchBtn to missing value
        repeat 40 times
            delay 0.5
            if exists window "Watch Now" then
                set watchBtn to my findWhere(window "Watch Now", "recPrimary", "")
                if watchBtn is not missing value then exit repeat
            end if
        end repeat
        if watchBtn is missing value then return "NO_RECORDING_BUTTON"
        click watchBtn
        set pw to missing value
        repeat 40 times
            delay 0.25
            set pw to my playerWin()
            if pw is not missing value then exit repeat
        end repeat
        if pw is missing value then return "NO_PLAYER_WINDOW"
        if not my waitPlaying(pw) then return "NOT_PLAYING"
        my closeExtraWindows()
        return "OK"
        """#)
    case .openOnFeed:
        return wrap(uiEvents, #"""
        set mn to menu 1 of menu bar item 1 of menu bar 2
        set feedItem to missing value
        repeat 20 times
            repeat with mi in (every menu item of mn)
                try
                    set nm to name of mi
                    if nm starts with "Recording on " and nm contains " — " then
                        set feedItem to mi
                        exit repeat
                    end if
                end try
            end repeat
            if feedItem is not missing value then exit repeat
            delay 1
        end repeat
        if feedItem is missing value then return "NO_FEED_MENU_ITEM"
        set watchItem to missing value
        repeat with sub in (every menu item of menu 1 of feedItem)
            try
                set nm to name of sub
                if nm starts with "Watch" and nm does not contain "alongside" and watchItem is missing value then set watchItem to sub
            end try
        end repeat
        if watchItem is missing value then return "NO_FEED_WATCH_ITEM"
        click watchItem
        set pw to missing value
        repeat 40 times
            delay 0.25
            set pw to my playerWin()
            if pw is not missing value then exit repeat
        end repeat
        if pw is missing value then return "NO_PLAYER_WINDOW"
        if not my waitPlaying(pw) then return "NOT_PLAYING"
        return "OK"
        """#)
    case .addFeedPip:
        return wrap(uiEvents, #"""
        set mn to menu 1 of menu bar item 1 of menu bar 2
        set feedItem to missing value
        repeat with mi in (every menu item of mn)
            try
                set nm to name of mi
                if nm starts with "Recording on " and nm contains " — " then
                    set feedItem to mi
                    exit repeat
                end if
            end try
        end repeat
        if feedItem is missing value then return "NO_FEED_MENU_ITEM"
        set pipItem to missing value
        repeat with sub in (every menu item of menu 1 of feedItem)
            try
                if (name of sub) contains "alongside" then set pipItem to sub
            end try
        end repeat
        if pipItem is missing value then return "NO_FEED_PIP_ITEM"
        click pipItem
        set pw to my playerWin()
        repeat 30 times
            if my findById(pw, "vlc-pip-thumbnail") is not missing value then exit repeat
            delay 0.5
        end repeat
        return "OK"
        """#)
    case .addLivePip:
        return wrap(uiEvents, #"""
        click menu item "Watch Now…" of menu 1 of menu bar item 1 of menu bar 2
        set addBtn to missing value
        repeat 30 times
            delay 0.5
            if exists window "Watch Now" then
                set addBtn to my findWhere(window "Watch Now", "pipLive", "")
                if addBtn is not missing value then exit repeat
            end if
        end repeat
        if addBtn is missing value then return "NO_PIP_TARGET"
        click addBtn
        set pw to my playerWin()
        repeat 30 times
            if my findById(pw, "vlc-pip-thumbnail") is not missing value then exit repeat
            delay 0.5
        end repeat
        my closeExtraWindows()
        return "OK"
        """#)
    case .closePip:
        return wrap(uiEvents, #"""
        set pw to my playerWin()
        set cb to my findById(pw, "vlc-pip-close-button")
        if cb is missing value then
            -- the × is hover-revealed; the right-click menu's last item always closes it
            return my pipMenuKeys(pw, {125, 125, 125, 125, 125, 125, 36})
        end if
        click cb
        return "OK"
        """#)
    case .swap:
        return wrap(uiEvents, #"""
        set pw to my playerWin()
        set before to name of pw
        click (my findById(pw, "vlc-pip-thumbnail"))
        repeat 20 times
            delay 0.2
            if (name of pw) is not before then exit repeat
        end repeat
        return "OK"
        """#)
    case .pipChannel:
        let mode = Bool.random(using: &rng) ? "last" : "second"
        return wrap(uiEvents, "        return my pickPipChannel(my playerWin(), \"\(mode)\")")
    case .pipCorner:
        let idx = Int.random(in: 1...4, using: &rng)
        return wrap(uiEvents, "        return my moveToCorner(my playerWin(), \(idx))")
    case .primaryToLive, .primaryChannel:
        return wrap(uiEvents, #"""
        return my pickPrimaryChannel(my playerWin(), "")
        """#)
    case .moveWindow:
        let x = Int.random(in: 20...700, using: &rng), y = Int.random(in: 40...300, using: &rng)
        return wrap(uiEvents, "        set position of my playerWin() to {\(x), \(y)}\n        return \"OK\"")
    case .resizeWindow:
        let w = Int.random(in: 640...1400, using: &rng), h = Int.random(in: 420...800, using: &rng)
        return wrap(uiEvents, "        set size of my playerWin() to {\(w), \(h)}\n        return \"OK\"")
    case .closePlayer:
        return wrap(uiEvents, #"""
        set pw to my playerWin()
        click (first button of pw whose description is "close button")
        repeat 30 times
            delay 0.2
            if my playerWin() is missing value then exit repeat
        end repeat
        my closeExtraWindows()
        return "OK"
        """#)
    }
}

/// "winFrame|thumbFrame|windowNames" for the geometry checks.
private func geometryScript(uiEvents: String) -> String {
    wrap(uiEvents, #"""
    set pw to my playerWin()
    set names to ""
    repeat with w in windows
        set names to names & (name of w) & ";"
    end repeat
    if pw is missing value then return "-|-|" & names
    return (my frameOf(pw)) & "|" & (my frameOf(my findById(pw, "vlc-pip-thumbnail"))) & "|" & names
    """#)
}

// MARK: the walk

private struct Step { var n: Int; var op: Op; var result: String; var world: World; var settle: TimeInterval?; var tuners: Tuners; var note: String }

private func run(phase: String, feedPhase: Bool, deviceID: String, base: Int, uiEvents: String,
                 steps: Int, seed: UInt64, appLogOffset: UInt64) -> [String] {
    var rng = SplitMix64(state: seed)
    var world = World()
    var trail: [Step] = []
    var problems: [String] = []
    let total = tunerSnapshot(deviceID: deviceID).total ?? 2

    func expected() -> Int { base + world.liveCount }

    func allowed() -> [Op] {
        var ops: [Op] = []
        let free = expected() < total
        if !world.player {
            if !feedPhase { ops.append(.openOnRecording) } else { ops.append(.openOnFeed) }
            return ops
        }
        ops += [.moveWindow, .resizeWindow, .closePlayer]
        if world.pip == .none {
            if free { ops.append(.addLivePip) }
            if feedPhase && world.primary != .feed { ops.append(.addFeedPip) }
        } else {
            ops += [.closePip, .swap, .pipCorner]
            if world.pip == .live { ops.append(.pipChannel) }
        }
        if world.primary == .live { ops.append(.primaryChannel) }
        else if free { ops.append(.primaryToLive) }
        return ops
    }

    func apply(_ op: Op) {
        switch op {
        case .openOnRecording: world = World(player: true, primary: .rec, pip: .none)
        case .openOnFeed:      world = World(player: true, primary: .feed, pip: .none)
        case .addLivePip:      world.pip = .live
        case .addFeedPip:      world.pip = .feed
        case .closePip:        world.pip = .none
        case .swap:            (world.primary, world.pip) = (world.pip, world.primary)
        case .primaryToLive:   world.primary = .live
        case .closePlayer:     world = World()
        case .pipChannel, .pipCorner, .primaryChannel, .moveWindow, .resizeWindow: break
        }
    }

    // Scripted prefix so the key transitions always run, then the random walk.
    var prefix: [Op] = feedPhase
        ? [.openOnFeed, .addLivePip, .swap, .closePip, .closePlayer]
        : [.openOnRecording, .addLivePip, .pipCorner, .swap, .closePip, .closePlayer]
    var n = 0
    while n < steps && problems.isEmpty {
        n += 1
        let candidates = allowed()
        guard !candidates.isEmpty else { break }
        var op = candidates.randomElement(using: &rng)!
        if !prefix.isEmpty {
            let want = prefix.removeFirst()
            if candidates.contains(want) { op = want }
        }
        let t0 = Date()
        let result = runAppleScript(script(for: op, uiEvents: uiEvents, rng: &rng, world: world)) ?? "SCRIPT_FAILED"
        var note = ""
        if result != "OK" && !result.hasPrefix("OK:") {
            problems.append("step \(n) \(op.rawValue): the UI action did not complete — \(result)")
            trail.append(Step(n: n, op: op, result: result, world: world, settle: nil, tuners: Tuners(), note: ""))
            break
        }
        apply(op)

        // Poll both tuner sources until they agree with the model.
        let want = expected()
        var snap = Tuners()
        var settled: TimeInterval?
        let deadline = Date().addingTimeInterval(35)
        repeat {
            Thread.sleep(forTimeInterval: 1.0)
            snap = tunerSnapshot(deviceID: deviceID)
            if snap.hw == want && snap.app == want { settled = Date().timeIntervalSince(t0); break }
        } while Date() < deadline
        if settled == nil {
            problems.append("step \(n) \(op.rawValue): tuners never settled at the expected \(want) (base \(base) + \(world.liveCount) live) — \(snap)")
        } else if let s = settled, s > 25 {
            note += " slow-settle=\(Int(s))s"
        }

        // UI geometry.
        let geo = (runAppleScript(geometryScript(uiEvents: uiEvents)) ?? "?|?|?").components(separatedBy: "|")
        if geo.count == 3 {
            let (win, thumb, names) = (geo[0], geo[1], geo[2])
            if world.player && win == "-" { problems.append("step \(n) \(op.rawValue): player window missing") }
            if !world.player && win != "-" { problems.append("step \(n) \(op.rawValue): player window still open after close") }
            let hasThumb = thumb != "-"
            if world.pip != .none && !hasThumb { problems.append("step \(n) \(op.rawValue): model has a PiP but no thumbnail is on screen") }
            if world.pip == .none && hasThumb { problems.append("step \(n) \(op.rawValue): a PiP thumbnail is on screen but the model has none") }
            if hasThumb && win != "-" {
                let w = win.split(separator: ",").compactMap { Double($0) }, t = thumb.split(separator: ",").compactMap { Double($0) }
                if w.count == 4, t.count == 4 {
                    let slack = 3.0
                    if t[0] < w[0] - slack || t[1] < w[1] - slack || t[0] + t[2] > w[0] + w[2] + slack || t[1] + t[3] > w[1] + w[3] + slack {
                        problems.append("step \(n) \(op.rawValue): PiP thumbnail \(thumb) is outside the player window \(win)")
                    }
                }
            }
            if win != "-" {
                let w = win.split(separator: ",").compactMap { Double($0) }
                if w.count == 4, let screen = NSScreen.screens.first?.frame {
                    let onScreen = CGRect(x: w[0], y: w[1], width: w[2], height: w[3]).intersects(CGRect(x: 0, y: 0, width: screen.width, height: screen.height))
                    if !onScreen { problems.append("step \(n) \(op.rawValue): player window \(win) is entirely off-screen") }
                }
            }
            let extra = names.split(separator: ";").map(String.init).filter { !["Watch Now", "Add Picture-in-Picture", "Support hdhrVCRplus"].contains($0) }
            if extra.count > 1 { problems.append("step \(n) \(op.rawValue): \(extra.count) player windows open (\(extra))") }
            if names.contains("Add Picture-in-Picture") { problems.append("step \(n) \(op.rawValue): the PiP picker window was left open") }
        }
        trail.append(Step(n: n, op: op, result: result, world: world, settle: settled, tuners: snap, note: note))
    }

    // Always end closed, then the leak check: with nothing of ours open the hardware must be back at base.
    if world.player {
        _ = runAppleScript(script(for: .closePlayer, uiEvents: uiEvents, rng: &rng, world: world))
        world = World()
    }
    var finalSnap = Tuners()
    let leakDeadline = Date().addingTimeInterval(45)
    repeat {
        Thread.sleep(forTimeInterval: 1.5)
        finalSnap = tunerSnapshot(deviceID: deviceID)
        if finalSnap.hw == base && finalSnap.app == base { break }
    } while Date() < leakDeadline
    if finalSnap.hw != base || finalSnap.app != base {
        problems.append("after closing everything the tuners are \(finalSnap), expected \(base) — a tuner was leaked or a count is stale")
    }

    // The app's own log for the run.
    let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/hdhrVCRplus.log")
    if let h = try? FileHandle(forReadingFrom: logURL) {
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: appLogOffset <= size ? appLogOffset : 0)
        let text = String(data: (try? h.readToEnd()) ?? Data(), encoding: .utf8) ?? ""
        let errors = text.split(separator: "\n").filter { $0.contains("[ERROR]") }
        if !errors.isEmpty { problems.append("the app logged \(errors.count) [ERROR] line(s) during the run, e.g. \(errors.prefix(3).joined(separator: " ⏎ "))") }
        let tunerRefusals = text.split(separator: "\n").filter { $0.contains("All Tuners") || $0.contains("tuner refused") }
        if !tunerRefusals.isEmpty { problems.append("the device refused a stream (all tuners busy) \(tunerRefusals.count)× — \(tunerRefusals.first!)") }
    }

    // Always print the trail — it is the point of a soak run, pass or fail.
    var report = "\n=== \(phase): seed \(seed), \(trail.count) steps, base \(base) of \(total) tuners ===\n"
    for s in trail {
        report += String(format: "%3d  %-16@ → player=%@ primary=%@ pip=%@  want=%d  %@  settle=%@%@  [%@]\n",
                         s.n, s.op.rawValue as NSString, s.world.player ? "y" : "n" as NSString, s.world.primary.rawValue as NSString,
                         s.world.pip.rawValue as NSString, base + s.world.liveCount, s.tuners.description as NSString,
                         (s.settle.map { String(format: "%.0fs", $0) } ?? "never") as NSString, s.note as NSString, s.result as NSString)
    }
    report += "final: \(finalSnap)\n"
    FileHandle.standardError.write(report.data(using: .utf8)!)
    return problems.map { "[\(phase) seed \(seed)] \($0)" }
}

// MARK: tests

@Suite("PiP / FEED / window churn — tuner-state soak (live app, opt-in)", .serialized)
struct PiPTunerChurnTests {

    private func common() -> (uiEvents: String, seed: UInt64, steps: Int, repoRoot: URL, logOffset: UInt64)? {
        guard windowNavTestsOptedIn(), appRunning(), accessibilityTrusted() else { return nil }
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let bin = FileManager.default.temporaryDirectory.appendingPathComponent("hdhr_ui_events").path
        let compile = sh("/usr/bin/xcrun", ["swiftc", "-O", repoRoot.appendingPathComponent("tools/ui_events.swift").path, "-o", bin])
        guard compile.status == 0 else { Issue.record("could not compile tools/ui_events.swift"); return nil }
        let env = ProcessInfo.processInfo.environment
        let seed = env["HDHR_CHURN_SEED"].flatMap { UInt64($0) } ?? UInt64(Date().timeIntervalSince1970)
        let steps = env["HDHR_CHURN_STEPS"].flatMap { Int($0) } ?? 30
        let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/hdhrVCRplus.log")
        let off = (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? UInt64) ?? 0
        return (bin, seed, steps, repoRoot, off)
    }

    private func scenarioTool(_ root: URL) -> String { root.appendingPathComponent("tools/mock_scenario.py").path }

    /// The mini records (one tuner), and the walk opens/closes a recording-relay primary, live and FEED-less PiPs,
    /// swaps, channel changes, corner moves and window moves/resizes. The relay primary costs no tuner; every live
    /// stream costs exactly one.
    @Test func churnWhileTheMiniIsRecording() throws {
        guard let c = common() else { return }
        let tool = scenarioTool(c.repoRoot)
        _ = sh("/usr/bin/python3", [tool, "clean"])
        let started = sh("/usr/bin/python3", [tool, "start"])
        if started.status == 2 { return }            // nothing airing / no free tuner — environment skip
        guard started.status == 0 else { Issue.record("mock_scenario.py start failed (\(started.status))"); return }
        defer { _ = sh("/usr/bin/python3", [tool, "clean"]) }

        guard let dev = discoverDeviceID() else { Issue.record("could not find a tuner device in the web guide"); return }
        Thread.sleep(forTimeInterval: 4)
        let base = tunerSnapshot(deviceID: dev)
        guard let hw = base.hw, let app = base.app, hw == app else {
            Issue.record("baseline tuner state disagrees before any UI action: \(base)"); return
        }
        let problems = run(phase: "mini-recording", feedPhase: false, deviceID: dev, base: hw, uiEvents: c.uiEvents,
                           steps: c.steps, seed: c.seed, appLogOffset: c.logOffset)
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    /// The *laptop* records (it is the Mac whose FEED relay stays live for the shared tuner); the mini watches that
    /// FEED as primary and/or PiP and mixes in live PiPs. A FEED must never cost a tuner on either machine.
    @Test func feedFromTheLaptopCostsNoTuner() throws {
        guard let c = common() else { return }
        let reach = sh("/usr/bin/ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "laptop", "true"], timeout: 15)
        guard reach.status == 0 else { return }       // no laptop — environment skip
        let tool = scenarioTool(c.repoRoot)
        _ = sh("/usr/bin/python3", [tool, "clean"])   // the mini must NOT be recording, or its own relay wins
        let remote = "cd ~/GitHub/hdhr_VCR_swift && python3 tools/mock_scenario.py"
        _ = sh("/usr/bin/ssh", ["laptop", "\(remote) clean"], timeout: 60)
        let started = sh("/usr/bin/ssh", ["laptop", "\(remote) start"], timeout: 90)
        if started.status == 2 { return }
        guard started.status == 0 else { Issue.record("laptop mock_scenario.py start failed (\(started.status))"); return }
        defer { _ = sh("/usr/bin/ssh", ["laptop", "\(remote) clean"], timeout: 60) }

        guard let dev = discoverDeviceID() else { Issue.record("could not find a tuner device in the web guide"); return }
        Thread.sleep(forTimeInterval: 8)               // let the mini's next discovery pass see the laptop's relay
        let base = tunerSnapshot(deviceID: dev)
        guard let hw = base.hw, let app = base.app, hw == app else {
            Issue.record("baseline tuner state disagrees before any UI action: \(base)"); return
        }
        let problems = run(phase: "feed-from-laptop", feedPhase: true, deviceID: dev, base: hw, uiEvents: c.uiEvents,
                           steps: c.steps, seed: c.seed &+ 1, appLogOffset: c.logOffset)
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }
}
