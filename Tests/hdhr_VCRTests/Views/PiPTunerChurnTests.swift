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
// The FEED test additionally needs `ssh laptop` (key auth) with Accessibility granted to its sshd session and
// the app running there. The *mini* records and feeds (its Recording FEED relay), and the walk drives the
// *laptop's* UI over ssh: the laptop watches that FEED as a primary and/or PiP, mixed with live PiPs. A FEED must
// never cost a tuner on either machine, and both apps must agree with the shared hardware count throughout.

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

// MARK: target machine (where the UI under test lives)

/// The machine whose player we drive. Local = the mini; remote = the laptop, over ssh (osascript via stdin).
private struct Target {
    var name: String
    var run: (String) -> String?        // run an AppleScript on that machine
    var uiEvents: String                // path of the compiled tools/ui_events binary ON that machine
    var fetchPage: () -> String         // that machine's own web guide page (its app's tuner counts)
    var logOffset: () -> UInt64
    var logSince: (UInt64) -> String
    var screen: (w: Int, h: Int)
}

private func screenSize(run: (String) -> String?) -> (w: Int, h: Int) {
    let out = run(#"tell application "Finder" to get bounds of window of desktop"#) ?? ""
    let n = out.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    return n.count == 4 ? (n[2], n[3]) : (1440, 900)
}

private func readLog(at url: URL, from offset: UInt64) -> String {
    guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
    defer { try? h.close() }
    let size = (try? h.seekToEnd()) ?? 0
    try? h.seek(toOffset: offset <= size ? offset : 0)
    return String(data: (try? h.readToEnd()) ?? Data(), encoding: .utf8) ?? ""
}

private func localTarget(uiEvents: String) -> Target {
    let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/hdhrVCRplus.log")
    return Target(name: "mini",
                  run: { runAppleScript($0) },
                  uiEvents: uiEvents,
                  fetchPage: { curl("http://127.0.0.1:1980/", timeout: 10) },
                  logOffset: { (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? UInt64) ?? 0 },
                  logSince: { readLog(at: logURL, from: $0) },
                  screen: screenSize(run: { runAppleScript($0) }))
}

/// `osascript -` does not read stdin as UTF-8, so a literal "—" (the FEED menu item's separator) or "…" ("Watch Now…")
/// arrives mangled and never matches. Every string literal containing a non-ASCII character is rewritten to
/// `("ab" & (character id 8212) & "cd")` — local runs (`osascript -e`) don't need this, ssh stdin does.
private func asciiSafe(_ script: String) -> String {
    guard let re = try? NSRegularExpression(pattern: #""[^"\n]*""#) else { return script }
    var out = ""
    var last = script.startIndex
    for m in re.matches(in: script, range: NSRange(script.startIndex..., in: script)) {
        guard let r = Range(m.range, in: script) else { continue }
        out += script[last..<r.lowerBound]
        let lit = String(script[r].dropFirst().dropLast())
        if lit.unicodeScalars.allSatisfy({ $0.isASCII }) {
            out += script[r]
        } else {
            var parts: [String] = []
            var cur = ""
            for u in lit.unicodeScalars {
                if u.isASCII { cur.unicodeScalars.append(u) }
                else { parts.append("\"\(cur)\""); cur = ""; parts.append("(character id \(u.value))") }
            }
            parts.append("\"\(cur)\"")
            out += "(" + parts.joined(separator: " & ") + ")"
        }
        last = r.upperBound
    }
    out += script[last...]
    return out
}

/// Runs `osascript -` on the laptop with the script on stdin (avoids shell-quoting a multi-KB script).
private func remoteOsascript(_ script: String, timeout: TimeInterval = 150) -> String? {
    let script = asciiSafe(script)
    let t = Process()
    t.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    t.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "laptop", "osascript", "-"]
    let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
    t.standardInput = inPipe; t.standardOutput = outPipe; t.standardError = errPipe
    do { try t.run() } catch { return nil }
    inPipe.fileHandleForWriting.write(Data(script.utf8))
    try? inPipe.fileHandleForWriting.close()
    let killer = DispatchWorkItem { if t.isRunning { t.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    let err = errPipe.fileHandleForReading.readDataToEndOfFile()
    t.waitUntilExit()
    killer.cancel()
    guard t.terminationStatus == 0 else {
        FileHandle.standardError.write("laptop osascript error: \(String(data: err, encoding: .utf8) ?? "?")\n".data(using: .utf8)!)
        return nil
    }
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func laptopTarget(uiEvents: String) -> Target {
    return Target(name: "laptop",
                  run: { remoteOsascript($0) },
                  uiEvents: uiEvents,
                  fetchPage: { sh("/usr/bin/ssh", ["-o", "BatchMode=yes", "laptop", "curl -s -m 10 http://127.0.0.1:1980/"], timeout: 25).out },
                  logOffset: { UInt64(sh("/usr/bin/ssh", ["laptop", "stat -f %z ~/Library/Logs/hdhrVCRplus.log"], timeout: 20).out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 },
                  logSince: { off in sh("/usr/bin/ssh", ["laptop", "tail -c +\(off + 1) ~/Library/Logs/hdhrVCRplus.log"], timeout: 30).out },
                  screen: screenSize(run: { remoteOsascript($0) }))
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
    var peer: Int?         // the *other* Mac's app count (the recorder), when a recorder target is given
    var description: String {
        "app=\(app.map(String.init) ?? "?") hw=\(hw.map(String.init) ?? "?") total=\(total.map(String.init) ?? "?")"
            + (peer.map { " peer=\($0)" } ?? "")
    }
    func matches(_ want: Int, hasPeer: Bool) -> Bool { hw == want && app == want && (!hasPeer || peer == want) }
}

/// "(dev X ch 4.1)" in mock_scenario.py start's output → "4.1".
private func recordedChannel(_ startOutput: String) -> String {
    guard let r = startOutput.range(of: #"ch (\S+)\)"#, options: .regularExpression) else { return "" }
    return String(startOutput[r].dropFirst(3).dropLast())
}

private func discoverDeviceID() -> String? {
    let page = curl("http://127.0.0.1:1980/", timeout: 10)
    guard let r = page.range(of: #""([0-9A-F]{8})":\{"nt":"#, options: .regularExpression) ?? page.range(of: #""([0-9A-F]{8})":\{[^}]*"surl""#, options: .regularExpression)
    else { return nil }
    let ids = page[r].split(separator: "\"").map(String.init).filter { $0.count == 8 }
    return ids.first
}

private func tunerSnapshot(deviceID: String, page: String) -> Tuners {
    var out = Tuners()
    guard let r = page.range(of: "\"\(deviceID)\":\\{[^}]*\\}", options: .regularExpression) else { return out }
    let objText = String(page[r].dropFirst(deviceID.count + 3))   // skips `"ID":`, leaving the `{…}` object
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

private func script(for op: Op, uiEvents: String, rng: inout SplitMix64, world: World, skip: String, screen: (w: Int, h: Int)) -> String {
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
        repeat 90 times
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
        set titleBeforeSwap to name of pw
        click (my findById(pw, "vlc-pip-thumbnail"))
        repeat 20 times
            delay 0.2
            if (name of pw) is not titleBeforeSwap then exit repeat
        end repeat
        return "OK"
        """#)
    case .pipChannel:
        let mode = Bool.random(using: &rng) ? "last" : "second"
        return wrap(uiEvents, "        return my pickPipChannel(my playerWin(), \"\(mode)\", \"\(skip)\")")
    case .pipCorner:
        let idx = Int.random(in: 1...4, using: &rng)
        return wrap(uiEvents, "        return my moveToCorner(my playerWin(), \(idx))")
    case .primaryToLive, .primaryChannel:
        // The recorded channel is skipped: the app plays it from disk (no tuner), which would break the model.
        return wrap(uiEvents, """
        return my pickPrimaryChannel(my playerWin(), "\(skip)")
        """)
    case .moveWindow:
        let x = Int.random(in: 20...max(40, screen.w - 760), using: &rng), y = Int.random(in: 40...max(60, screen.h - 520), using: &rng)
        return wrap(uiEvents, "        set pw to my playerWin()\n        set position of pw to {\(x), \(y)}\n        return \"OK\"")
    case .resizeWindow:
        let w = Int.random(in: 640...max(700, min(1400, screen.w - 120)), using: &rng), h = Int.random(in: 420...max(480, min(800, screen.h - 140)), using: &rng)
        return wrap(uiEvents, "        set pw to my playerWin()\n        set size of pw to {\(w), \(h)}\n        return \"OK\"")
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
private func geometryScript(uiEvents: String, expectThumb: Bool) -> String {
    wrap(uiEvents, (expectThumb ? """
    -- the AX tree can lag the UI by a few seconds; a PiP the model says exists gets time to appear
    set pwWait to my playerWin()
    repeat 12 times
        if pwWait is not missing value then
            if my findById(pwWait, "vlc-pip-thumbnail") is not missing value then exit repeat
        end if
        delay 0.5
        set pwWait to my playerWin()
    end repeat

    """ : "") + #"""
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

private func run(phase: String, feedPhase: Bool, deviceID: String, base: Int, target: Target, recorder: Target?,
                 steps: Int, seed: UInt64, appLogOffset: UInt64, recorderLogOffset: UInt64 = 0, recordedChannel: String) -> [String] {
    let uiEvents = target.uiEvents
    var rng = SplitMix64(state: seed)
    var world = World()
    var trail: [Step] = []
    var problems: [String] = []
    let total = tunerSnapshot(deviceID: deviceID, page: target.fetchPage()).total ?? 2

    func snapshot() -> Tuners {
        var t = tunerSnapshot(deviceID: deviceID, page: target.fetchPage())
        if let recorder { t.peer = tunerSnapshot(deviceID: deviceID, page: recorder.fetchPage()).app }
        return t
    }
    let hasPeer = recorder != nil
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
        let result = target.run(script(for: op, uiEvents: uiEvents, rng: &rng, world: world, skip: recordedChannel, screen: target.screen)) ?? "SCRIPT_FAILED"
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
        var samples: [String] = []
        repeat {
            Thread.sleep(forTimeInterval: 1.0)
            snap = snapshot()
            samples.append("\(Int(Date().timeIntervalSince(t0)))s:\(snap.app.map(String.init) ?? "?")/\(snap.hw.map(String.init) ?? "?")")
            if snap.matches(want, hasPeer: hasPeer) { settled = Date().timeIntervalSince(t0); break }
        } while Date() < deadline
        if settled == nil || samples.count > 6 { note += " samples(app/hw)=" + samples.joined(separator: " ") }
        if settled == nil {
            problems.append("step \(n) \(op.rawValue): tuners never settled at the expected \(want) (base \(base) + \(world.liveCount) live) — \(snap)")
        } else if let s = settled, s > 25 {
            note += " slow-settle=\(Int(s))s"
        }

        // UI geometry.
        let geo = (target.run(geometryScript(uiEvents: uiEvents, expectThumb: world.pip != .none)) ?? "?|?|?").components(separatedBy: "|")
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
        _ = target.run(script(for: .closePlayer, uiEvents: uiEvents, rng: &rng, world: world, skip: recordedChannel, screen: target.screen))
        world = World()
    }
    var finalSnap = Tuners()
    let leakDeadline = Date().addingTimeInterval(45)
    repeat {
        Thread.sleep(forTimeInterval: 1.5)
        finalSnap = snapshot()
        if finalSnap.matches(base, hasPeer: hasPeer) { break }
    } while Date() < leakDeadline
    if !finalSnap.matches(base, hasPeer: hasPeer) {
        problems.append("after closing everything the tuners are \(finalSnap), expected \(base) — a tuner was leaked or a count is stale")
    }

    // The apps' own logs for the run (the viewer, and the recorder if it is a different Mac).
    for (label, text) in [(target.name, target.logSince(appLogOffset))] + (recorder.map { [($0.name, $0.logSince(recorderLogOffset))] } ?? []) {
        let errors = text.split(separator: "\n").filter { $0.contains("[ERROR]") }
        if !errors.isEmpty { problems.append("the \(label) app logged \(errors.count) [ERROR] line(s) during the run, e.g. \(errors.prefix(3).joined(separator: " ⏎ "))") }
        let tunerRefusals = text.split(separator: "\n").filter { $0.contains("All Tuners") || $0.contains("tuner refused") }
        if !tunerRefusals.isEmpty { problems.append("the device refused a stream on the \(label) (all tuners busy) \(tunerRefusals.count)× — \(tunerRefusals.first!)") }
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

    private struct Env { var seed: UInt64; var steps: Int; var repoRoot: URL }

    private func env() -> Env {
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let e = ProcessInfo.processInfo.environment
        return Env(seed: e["HDHR_CHURN_SEED"].flatMap { UInt64($0) } ?? UInt64(Date().timeIntervalSince1970),
                   steps: e["HDHR_CHURN_STEPS"].flatMap { Int($0) } ?? 30,
                   repoRoot: repoRoot)
    }

    private func scenarioTool(_ root: URL) -> String { root.appendingPathComponent("tools/mock_scenario.py").path }

    private func say(_ msg: String) { FileHandle.standardError.write((msg + "\n").data(using: .utf8)!) }

    private func compileLocalHelper(_ root: URL) -> String? {
        let bin = FileManager.default.temporaryDirectory.appendingPathComponent("hdhr_ui_events").path
        let r = sh("/usr/bin/xcrun", ["swiftc", "-O", root.appendingPathComponent("tools/ui_events.swift").path, "-o", bin])
        if r.status != 0 { Issue.record("could not compile tools/ui_events.swift: \(r.out)"); return nil }
        return bin
    }

    private func compileLaptopHelper(_ root: URL) -> String? {
        let src = root.appendingPathComponent("tools/ui_events.swift").path
        guard sh("/usr/bin/scp", ["-q", "-o", "BatchMode=yes", src, "laptop:/tmp/hdhr_ui_events.swift"], timeout: 30).status == 0 else {
            Issue.record("could not copy tools/ui_events.swift to the laptop"); return nil
        }
        let r = sh("/usr/bin/ssh", ["laptop", "xcrun swiftc -O /tmp/hdhr_ui_events.swift -o /tmp/hdhr_ui_events"], timeout: 180)
        if r.status != 0 { Issue.record("could not compile ui_events on the laptop: \(r.out)"); return nil }
        return "/tmp/hdhr_ui_events"
    }

    /// True when this Mac's config has the Recording FEED relay switched on (Settings → Sharing → Recording FEED).
    private func miniRelayEnabled() -> Bool {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/hdhrVCRplus")
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("hdhr_VCR-") && $0.pathExtension == "json" }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        guard let f = files.first, let data = try? Data(contentsOf: f),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let cfg = (obj["config"] as? [String: Any]) ?? obj
        return cfg["Virtual_tuner_relay_enabled"] as? Bool == true
    }

    /// The mini records (one tuner) and its own player is driven: a recording-relay primary costs no tuner, every live
    /// stream (primary or PiP) costs exactly one; swaps, channel changes, corner moves and window moves/resizes must
    /// never change that.
    @Test func churnWhileTheMiniIsRecording() throws {
        guard windowNavTestsOptedIn(), appRunning(), accessibilityTrusted() else { return }
        let e = env()
        guard let bin = compileLocalHelper(e.repoRoot) else { return }
        let tool = scenarioTool(e.repoRoot)
        _ = sh("/usr/bin/python3", [tool, "clean"])
        let started = sh("/usr/bin/python3", [tool, "start"])
        if started.status == 2 { say("churnWhileTheMiniIsRecording skipped: nothing airing / no free tuner"); return }
        guard started.status == 0 else { Issue.record("mock_scenario.py start failed (\(started.status))"); return }
        defer { _ = sh("/usr/bin/python3", [tool, "clean"]) }

        let mini = localTarget(uiEvents: bin)
        guard let dev = discoverDeviceID() else { Issue.record("could not find a tuner device in the web guide"); return }
        Thread.sleep(forTimeInterval: 4)
        let base = tunerSnapshot(deviceID: dev, page: mini.fetchPage())
        guard let hw = base.hw, let app = base.app, hw == app else {
            Issue.record("baseline tuner state disagrees before any UI action: \(base)"); return
        }
        let problems = run(phase: "mini-recording", feedPhase: false, deviceID: dev, base: hw, target: mini, recorder: nil,
                           steps: e.steps, seed: e.seed, appLogOffset: mini.logOffset(),
                           recordedChannel: recordedChannel(started.out))
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    /// The *mini* records and feeds (its Recording FEED relay); the *laptop's* player is driven over ssh and watches that
    /// FEED as a primary and/or PiP, mixed with live PiPs on the shared HDHomeRun. A FEED must never cost a tuner on
    /// either Mac, and the laptop's count, the mini's count and the hardware must agree after every step.
    @Test func feedFromTheMiniShowsOnTheLaptop() throws {
        guard windowNavTestsOptedIn(), appRunning() else { return }
        let e = env()
        guard miniRelayEnabled() else {
            say("feedFromTheMiniShowsOnTheLaptop skipped: turn on Settings → Sharing → Recording FEED on the mini"); return
        }
        guard sh("/usr/bin/ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "laptop", "true"], timeout: 15).status == 0 else {
            say("feedFromTheMiniShowsOnTheLaptop skipped: `ssh laptop` is unreachable (asleep? keep it awake with `caffeinate -d`)"); return
        }
        guard remoteOsascript(#"tell application "System Events" to tell process "hdhr_VCR" to return count of windows"#, timeout: 40) != nil else {
            say("feedFromTheMiniShowsOnTheLaptop skipped: the laptop's app isn't running or its ssh session lacks Accessibility"); return
        }
        guard let laptopBin = compileLaptopHelper(e.repoRoot) else { return }

        let tool = scenarioTool(e.repoRoot)
        let laptopTool = "cd ~/GitHub/hdhr_VCR_swift && python3 tools/mock_scenario.py"
        _ = sh("/usr/bin/ssh", ["laptop", "\(laptopTool) clean"], timeout: 60)     // the laptop must NOT be recording — the mini feeds
        _ = sh("/usr/bin/python3", [tool, "clean"])
        let started = sh("/usr/bin/python3", [tool, "start"])
        if started.status == 2 { say("feedFromTheMiniShowsOnTheLaptop skipped: nothing airing / no free tuner"); return }
        guard started.status == 0 else { Issue.record("mock_scenario.py start failed (\(started.status))"); return }
        defer { _ = sh("/usr/bin/python3", [tool, "clean"]); _ = sh("/usr/bin/ssh", ["laptop", "\(laptopTool) clean"], timeout: 60) }

        let miniTarget = localTarget(uiEvents: "")
        let laptop = laptopTarget(uiEvents: laptopBin)
        guard let dev = discoverDeviceID() else { Issue.record("could not find a tuner device in the web guide"); return }
        Thread.sleep(forTimeInterval: 6)
        let base = tunerSnapshot(deviceID: dev, page: laptop.fetchPage())
        let miniBase = tunerSnapshot(deviceID: dev, page: miniTarget.fetchPage())
        guard let hw = base.hw, base.app == hw, miniBase.app == hw else {
            Issue.record("baseline tuner state disagrees before any UI action: laptop \(base) / mini \(miniBase)"); return
        }
        let problems = run(phase: "feed-from-mini→laptop", feedPhase: true, deviceID: dev, base: hw, target: laptop, recorder: miniTarget,
                           steps: e.steps, seed: e.seed &+ 1, appLogOffset: laptop.logOffset(), recorderLogOffset: miniTarget.logOffset(),
                           recordedChannel: recordedChannel(started.out))
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }
}
