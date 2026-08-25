import Darwin
import Foundation

DebugLog.log("=== hdhr_guide started (pid \(getpid())) ===")

// hdhr_guide — bundled terminal client for the guide (Contents/Helpers/hdhr_guide). Talks only
// to hdhrVCRplus's own LAN web server over plain HTTP (localhost:1980, hardcoded — matches
// Web_server_port's default; a custom port isn't supported yet, see docs/TUIGuide.md), never
// spawns a subprocess or dlopens anything, so it adds no App Sandbox blocker (see
// docs/MAS_COMPLIANCE.md). Requires Settings → Web Server enabled — Web_server_enabled defaults
// to false, so a fresh install needs that flipped once before this tool can reach anything.

let hourFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "h a"
    return f
}()
let clockFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "EEE h:mm a"
    return f
}()
let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "h:mm a"
    return f
}()

// Same status colors as the web guide's status ring (Resources/guide.css's --vc-rec/--vc-sched —
// CLAUDE.md's "Status ring + badge"), not arbitrary ANSI 16-color picks: recording stays close
// (ANSI bright red vs. #ff5a5a is near enough not to bother with truecolor), but scheduled was
// cyan here, not the guide's actual blue (#3b93ff) — fixed to truecolor to match exactly. Badge
// glyph is a plain dot for both, not the web guide's own ⏺/⏱ pair — color alone (matching the
// ring) carries the meaning here, and a uniform dot reads better at this width than a stopwatch.
let recordingColor  = "\u{1B}[1;91m"
let recordingBadge  = "\u{1B}[91m\u{25CF} "
let scheduledColor  = "\u{1B}[1;38;2;59;147;255m"
let scheduledBadge  = "\u{1B}[38;2;59;147;255m\u{25CF} "

// favAmber dark-mode value (GuideViewHelpers.swift/guide.css's --fav, "#e8a000") — same amber the
// web guide and native app use for favorites, not an independent pick.
let favoriteColor = "\u{1B}[38;2;232;160;0m"

// Same bucket palette as the web guide's channel-column signal bars (docs/WebServer.md: "poor
// #e53935 / fair #fbc02d / good #43a047").
func signalColor(_ bucket: String?) -> String {
    switch bucket {
    case "good": return "\u{1B}[38;2;67;160;71m"
    case "fair": return "\u{1B}[38;2;251;192;45m"
    case "poor": return "\u{1B}[38;2;229;57;53m"
    default: return ""
    }
}

// Mirrors Show.genreImpliesBonusTime (Models.swift) — "sport" not "sports" matches both guide.php's
// plural "Sports" and XMLTV's singular "Sport" tag. Duplicated rather than imported (hdhr_VCR is an
// executable, not a library) — without this, a sports show scheduled from the TUI silently never
// gets Bonus Time, unlike the native wizard and the web Record modal's own checkbox.
func genreImpliesBonusTime(_ genre: String?) -> Bool {
    genre?.lowercased().contains("sport") == true
}

let channelColWidth = 20
let slotWidth = 14
let secondsPerSlot = 1800

enum Mode { case normal, recordSummary }

var interrupted = false
signal(SIGINT) { _ in interrupted = true }
signal(SIGTERM) { _ in interrupted = true }

guard let initial = API.fetchGuide(device: nil) else {
    print("hdhr_guide: can't reach the web server at 127.0.0.1:1980.")
    print("Make sure hdhrVCRplus is running with Settings → Web Server enabled.")
    exit(1)
}
if initial.channels.isEmpty && initial.deviceId.isEmpty {
    print("hdhr_guide: no HDHomeRun tuner detected yet — open hdhrVCRplus and wait for discovery, then retry.")
    exit(1)
}

var payload = initial
var signalMap = API.fetchSignal() ?? [:]   // {guideName.lowercased(): "good"|"fair"|"poor"|"noData"}
var currentDeviceId: String? = nil   // nil = "server default" — set once the user explicitly Tabs
var selRow = 0
var rowScroll = 0
var selEntry = 0
var colStart = 0
var mode: Mode = .normal
var statusMsg = "Loaded \(payload.channels.count) channels on HDHR-\(payload.deviceId.uppercased())."
var lastPoll = Date()
let pollInterval: TimeInterval = 20

func visibleCols() -> Int {
    let (cols, _) = Terminal.size()
    // Capped at maxSlot() too — a terminal wide enough to fit the whole guide window shouldn't
    // report more columns than there's actually data for.
    return max(1, min((cols - channelColWidth) / slotWidth, maxSlot()))
}

func currentChannel() -> GuideChannelDTO? {
    guard selRow >= 0, selRow < payload.channels.count else { return nil }
    return payload.channels[selRow]
}

// No client-side time cap — an earlier 8-hour limit here made paging permanently stick at 0 on
// any terminal wide enough to fit all 8 hours in one screen (visibleCols() clamped to that same
// cap, so `maxSlot() - vc` bottomed out at exactly 0: there was nowhere left to page to, ever,
// regardless of how many later hours the server actually had). Paging/selection now range over
// the server's own full window instead, same as the web guide.
func visibleEntries(_ ch: GuideChannelDTO) -> [GuideEntryDTO] { ch.entries }

func maxSlot() -> Int { payload.winSec / secondsPerSlot }

func ensureEntryVisible() {
    guard let ch = currentChannel() else { return }
    let entries = visibleEntries(ch)
    guard selEntry >= 0, selEntry < entries.count else { return }
    let startSlot = (entries[selEntry].startTime - payload.winStart) / secondsPerSlot
    let vc = visibleCols()
    if startSlot < colStart { colStart = max(0, startSlot) }
    if startSlot >= colStart + vc { colStart = startSlot }
    colStart = max(0, min(colStart, max(0, maxSlot() - vc)))
}

func moveRow(_ delta: Int) {
    guard !payload.channels.isEmpty else { return }
    selRow = max(0, min(payload.channels.count - 1, selRow + delta))
    selEntry = 0
    ensureEntryVisible()
}

func moveEntry(_ delta: Int) {
    guard let ch = currentChannel() else {
        DebugLog.log("moveEntry(\(delta)): no current channel — no-op")
        return
    }
    let count = visibleEntries(ch).count
    guard count > 0 else {
        DebugLog.log("moveEntry(\(delta)): channel \(ch.guideNumber) has 0 visible entries — no-op")
        return
    }
    let newIndex = selEntry + delta
    guard newIndex >= 0 && newIndex < count else {
        // Already at this channel's first/last entry — page the shared timeline viewport instead
        // of doing nothing, so holding →/← scrolls continuously across the whole grid (through
        // the server's full guide window, not an artificially narrower one) instead of stopping
        // dead at wherever this one channel's own schedule happens to end.
        DebugLog.log("moveEntry(\(delta)): selEntry=\(selEntry) count=\(count) newIndex=\(newIndex) out of range — paging timeline instead")
        pageTime(delta > 0 ? 1 : -1)
        return
    }
    DebugLog.log("moveEntry(\(delta)): selEntry \(selEntry) -> \(newIndex) on \(ch.guideNumber)")
    selEntry = newIndex
    ensureEntryVisible()
}

func pageTime(_ dir: Int) {
    let vc = visibleCols()
    let cap = max(0, maxSlot() - vc)
    let before = colStart
    colStart = max(0, min(cap, colStart + dir * vc))
    DebugLog.log("pageTime(\(dir)): vc=\(vc) cap=\(cap) colStart \(before) -> \(colStart)")
}

func switchDevice() {
    guard payload.devices.count > 1 else { statusMsg = "Only one tuner detected."; return }
    let ids = payload.devices.map { $0.deviceId }
    guard let idx = ids.firstIndex(of: payload.deviceId) else { return }
    let next = ids[(idx + 1) % ids.count]
    guard let fresh = API.fetchGuide(device: next) else { statusMsg = "Failed to switch tuner."; return }
    payload = fresh
    currentDeviceId = next
    selRow = 0; selEntry = 0; colStart = 0
    statusMsg = "Switched to HDHR-\(next.uppercased())."
}

// Shared by confirmRecord/confirmDelete/renderSummaryScreen/the header's "selected program" line
// — the same "resolve the currently selected channel+entry, or nil" lookup was repeated at each
// call site independently.
func currentEntry() -> (channel: GuideChannelDTO, entry: GuideEntryDTO)? {
    guard let ch = currentChannel() else { return nil }
    let entries = visibleEntries(ch)
    guard selEntry < entries.count else { return nil }
    return (ch, entries[selEntry])
}

func confirmRecord(_ typeKey: Character) {
    let showType: String
    switch typeKey {
    case "1": showType = "single"
    case "2": showType = "dateTime"
    case "3": showType = "seriesChannel"
    case "4": showType = "seriesAll"
    default: mode = .normal; return
    }
    mode = .normal
    guard let (ch, entry) = currentEntry() else { return }
    // Sports genre → Bonus Time on, same auto-default the native Add Show wizard applies
    // (genreImpliesBonusTime above) — addShowFromGuide itself defaults this to false and does
    // not detect genre on its own, so omitting it here would silently drop Bonus Time for every
    // sports recording made from the TUI.
    let bonusTime = genreImpliesBonusTime(entry.genre)
    let resp = API.postRecord(deviceId: payload.deviceId, guideNumber: ch.guideNumber,
                               startTime: entry.startTime, showType: showType, bonusTime: bonusTime)
    if resp.ok {
        let recNote = resp.recStarted == true ? " (recording now)" : ""
        let queueNote = resp.tunerFull == true ? " — tuner full, queued" : ""
        statusMsg = "\u{2713} Scheduled: \(resp.title ?? entry.title)\(recNote)\(queueNote)"
        if let fresh = API.fetchGuide(device: currentDeviceId) { payload = fresh }
    } else {
        statusMsg = "\u{2717} \(resp.error ?? "failed to schedule")"
    }
}

func toggleFavorite() {
    guard let ch = currentChannel() else { return }
    let resp = API.postToggleFavorite(deviceId: payload.deviceId, guideNumber: ch.guideNumber)
    if resp.ok {
        let verb = resp.isFavorite == true ? "Favorited" : "Unfavorited"
        statusMsg = "\u{2713} \(verb): \(ch.guideNumber) \(ch.guideName)"
        if let fresh = API.fetchGuide(device: currentDeviceId) { payload = fresh }
    } else {
        statusMsg = "\u{2717} \(resp.error ?? "failed to toggle favorite")"
    }
}

// Offered on the summary screen instead of the record options whenever the selected entry is
// already managed (isScheduled — which also covers "currently recording", since a recording
// entry is owned by the same managed show) — scheduling it again would just be confusing, so
// the only sensible action left is removing it.
func confirmDelete() {
    mode = .normal
    guard let (_, entry) = currentEntry(), let showId = entry.scheduledShowId else { return }
    let resp = API.postDelete(showId: showId)
    if resp.ok {
        statusMsg = "\u{2713} Deleted: \(resp.title ?? entry.title)"
        if let fresh = API.fetchGuide(device: currentDeviceId) { payload = fresh }
    } else {
        statusMsg = "\u{2717} \(resp.error ?? "failed to delete")"
    }
}

func handle(_ key: Key) {
    DebugLog.log("handle(\(key)) mode=\(mode)")
    if mode == .recordSummary {
        let isScheduled = currentEntry()?.entry.isScheduled ?? false
        switch key {
        case .char(let c) where isScheduled && (c == "d" || c == "D"): confirmDelete()
        case .char(let c) where !isScheduled && "1234".contains(c): confirmRecord(c)
        case .escape: mode = .normal
        default: break
        }
        return
    }
    switch key {
    case .up: moveRow(-1)
    case .down: moveRow(1)
    case .left: moveEntry(-1)
    case .right: moveEntry(1)
    case .char("["): pageTime(-1)
    case .char("]"): pageTime(1)
    case .char("f"), .char("F"): toggleFavorite()
    case .tab: switchDevice()
    case .enter:
        if currentEntry() != nil { mode = .recordSummary }
    case .char("q"): interrupted = true
    default: break
    }
}

// Full-screen takeover for Enter — replaces the grid entirely rather than squeezing recording
// options into the footer, since a one-line "[1] Once [2] Weekly..." prompt gave no context on
// what was actually about to be scheduled. selRow/selEntry don't change while this mode is
// active (only 1–4/Esc are handled), so it's safe to re-resolve the same entry here.
func renderSummaryScreen() {
    let bold = "\u{1B}[1m", dim = "\u{1B}[2m", reset = "\u{1B}[0m"
    var out = ""

    guard let (ch, e) = currentEntry() else { Terminal.writeFrame(out); return }

    let bg = genreBackground(e.genre)
    let titleColor = e.isRecording ? recordingColor : (e.isScheduled ? scheduledColor : "\u{1B}[97m")
    out += bold + (e.isScheduled ? "Manage Recording" : "Schedule Recording") + reset + "\n\n"
    out += bg + titleColor + " \(e.title) " + reset + "\n\n"

    let range = "\(timeFormatter.string(from: e.startDate)) – \(timeFormatter.string(from: e.endDate))"
    let mins = max(0, (e.endTime - e.startTime) / 60)
    let status = e.isRecording ? recordingColor + "Recording now" + reset
        : (e.isScheduled ? scheduledColor + "Already scheduled" + reset : "Not scheduled")
    func field(_ label: String, _ value: String) -> String { dim + pad(label, 10) + reset + value + "\n" }

    out += field("Channel", "\(ch.guideNumber) \(ch.guideName)")
    out += field("Time", "\(range)  (\(mins) min)")
    let epLabel = [e.episodeNumber, e.episodeTitle]
        .compactMap { ($0?.isEmpty == false) ? $0 : nil }
        .joined(separator: " · ")
    if !epLabel.isEmpty { out += field("Episode", epLabel) }
    if let g = e.genre, !g.isEmpty { out += field("Genre", g) }
    if let tags = e.tags, !tags.isEmpty { out += field("Tags", tags.joined(separator: ", ")) }
    if !e.isScheduled && genreImpliesBonusTime(e.genre) {
        out += field("Bonus Time", "On — sports padding applied automatically")
    }
    out += field("Status", status)
    out += "\n"

    if let syn = e.synopsis, !syn.isEmpty {
        let (cols, _) = Terminal.size()
        let wrapWidth = max(20, min(76, cols - 2))
        out += bold + "Synopsis" + reset + "\n"
        for line in wordWrap(syn, width: wrapWidth) { out += "  " + line + "\n" }
        out += "\n"
    }

    // Already managed (scheduled or currently recording, both owned by the same show) — scheduling
    // it again would just be confusing, so the only sensible action is removing it, mirroring the
    // web guide's own Delete/"Stop & Delete" wording (docs/WebServer.md's delete confirmation modal).
    if e.isScheduled {
        let verb = e.isRecording ? "Stop & Delete" : "Remove"
        out += bold + "Manage:" + reset + "\n"
        out += "  \(bold)[d]\(reset) \(verb) this recording\n\n"
    } else {
        out += bold + "Record:" + reset + "\n"
        out += "  \(bold)[1]\(reset) This episode only\n"
        out += "  \(bold)[2]\(reset) Every week at this time\n"
        out += "  \(bold)[3]\(reset) New episodes on this channel\n"
        out += "  \(bold)[4]\(reset) New episodes on any channel on this tuner\n\n"
    }
    out += dim + "[Esc] Cancel" + reset

    Terminal.writeFrame(out)
}

// Adaptive summary panel above the grid — a compact version of the Enter-summary screen's field
// layout (title/episode/genre-tags-status/synopsis), scaled by terminal height rather than a
// fixed 1 line, so a tall terminal gets real detail (like the web guide's #sum panel) while a
// short one still gets the essentials. Always returns exactly `maxLines` lines (padded with ""
// when there's less content than room, never fewer) — render()'s line-count budget depends on
// this being exact, the same discipline topFixedLines/bottomFixedLines/boxLines already require.
// Every line is truncated to fit `cols` for the same reason the footer hint text is capped
// (Terminal.writeFrame's per-line \u{1B}[K stops a *shorter* line from leaving stale trailing
// content, but can't stop a *longer* one from wrapping and silently adding an extra screen line).
func buildSummaryLines(maxLines: Int, cols: Int) -> [String] {
    guard maxLines > 0 else { return [] }
    let bold = "\u{1B}[1m", dim = "\u{1B}[2m", reset = "\u{1B}[0m"
    let budget = max(4, cols - 2)   // reserves ~2 cols for each line's own leading marker/indent

    func pad0(_ out: [String]) -> [String] {
        var out = out
        while out.count < maxLines { out.append("") }
        return Array(out.prefix(maxLines))
    }

    guard let ch = currentChannel() else { return pad0([dim + "No channel selected" + reset]) }
    guard let (_, e) = currentEntry() else {
        return pad0([dim + "\u{25B6} \(ch.guideNumber) \(ch.guideName) — nothing in the guide right now" + reset])
    }

    let badge = e.isRecording ? recordingBadge + "\u{1B}[0m" : (e.isScheduled ? scheduledBadge + "\u{1B}[0m" : "")
    let titleColor = e.isRecording ? recordingColor : (e.isScheduled ? scheduledColor : bold)
    let range = "\(timeFormatter.string(from: e.startDate))–\(timeFormatter.string(from: e.endDate))"
    let mins = max(0, (e.endTime - e.startTime) / 60)

    var lines: [String] = []
    // 1: channel + time/duration
    lines.append("\u{25B6} " + bold + truncate("\(ch.guideNumber) \(ch.guideName)   \(range)  (\(mins) min)", budget) + reset)
    // 2: badge + title
    lines.append("  " + badge + titleColor + truncate(e.title, budget) + reset)
    // 3: episode, if any
    let epLabel = [e.episodeNumber, e.episodeTitle].compactMap { ($0?.isEmpty == false) ? $0 : nil }.joined(separator: " · ")
    if !epLabel.isEmpty { lines.append("  " + dim + truncate(epLabel, budget) + reset) }
    // 4: genre + tags as color chips (each tinted with that same tag's own tile-background color
    // via genreBackground — so "Kids" reads in the same color here as a Kids-genre tile does in
    // the grid, not an arbitrary text color) + status. Genre first, then any tags not already
    // equal to it (they commonly overlap — genre is just tags' first non-generic entry).
    var chipLabels: [String] = []
    if let g = e.genre, !g.isEmpty { chipLabels.append(g) }
    for t in e.tags ?? [] where !chipLabels.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) {
        chipLabels.append(t)
    }
    if !chipLabels.isEmpty || e.isRecording || e.isScheduled {
        var metaLine = "  "
        var used = 2   // plain-text visible width used so far — tracked separately from
                        // `metaLine` itself, which carries ANSI codes truncate() can't measure
        for label in chipLabels {
            let chipText = " \(label) "
            guard used + chipText.count + 1 <= budget else { break }   // drop chips that don't
                                                                        // fit rather than cut one
                                                                        // in half mid-ANSI-code
            let bg = genreBackground(label)
            metaLine += (bg.isEmpty ? dim + chipText + reset : bg + "\u{1B}[97m" + chipText + reset) + " "
            used += chipText.count + 1
        }
        let statusText = e.isRecording ? "Recording now" : (e.isScheduled ? "Scheduled" : nil)
        if let statusText, used + statusText.count <= budget {
            let statusColor = e.isRecording ? recordingColor : scheduledColor
            metaLine += statusColor + statusText + reset
        }
        lines.append(metaLine)
    }

    var out = Array(lines.prefix(maxLines))
    let remaining = maxLines - out.count
    if remaining > 0, let syn = e.synopsis, !syn.isEmpty {
        for wrapped in wordWrap(syn, width: budget).prefix(remaining) {
            out.append("  " + dim + wrapped + reset)
        }
    }
    return pad0(out)
}

func render() {
    if mode == .recordSummary { renderSummaryScreen(); return }

    let (cols, rows) = Terminal.size()
    let vc = visibleCols()
    // Every fixed (non-body) line this function emits, counted exactly — undercounting this by
    // even one line means the frame renders taller than the terminal, which forces a scroll, and
    // since every redraw starts with a bare cursor-home (Terminal.writeFrame), a scrolling
    // viewport makes the top of the screen appear to jump/flash on every keypress instead of
    // staying put. topFixedLines: the HDHR/clock line, the summary panel (adaptive, see
    // buildSummaryLines), the hour-label ruler, and the "┬" gutter rule. bottomFixedLines: the
    // "┴" gutter rule, the blank line after it, the keybinding-hint line, and the status line.
    // boxLines: the selected tile's top+bottom border — always drawn, since the selected row is
    // always within the visible range.
    //
    // summaryLines scales with terminal height (capped 1...8) rather than a fixed count, so a
    // tall terminal gets real detail (episode/genre/tags/synopsis, like the web guide's #sum
    // panel) while a short one still shows just the essentials — (rows-16)/3 reaches the 8-line
    // cap around a 40-row terminal, a common "large window" size, not an extreme one.
    let summaryLines = max(1, min(8, (rows - 16) / 3))
    let topFixedLines = 3 + summaryLines
    let bottomFixedLines = 4
    let boxLines = 2
    let visibleRows = max(1, rows - topFixedLines - bottomFixedLines - boxLines)

    if selRow < rowScroll { rowScroll = selRow }
    if selRow >= rowScroll + visibleRows { rowScroll = selRow - visibleRows + 1 }
    // selRow - visibleRows + 1 above goes negative whenever visibleRows exceeds selRow+1 (a
    // small lineup, or a very tall terminal) — an unclamped negative rowScroll would make
    // `rowScroll..<max(rowScroll, endRow)` below index payload.channels with a negative
    // subscript and trap.
    rowScroll = max(0, min(rowScroll, max(0, payload.channels.count - visibleRows)))

    let bold = "\u{1B}[1m", dim = "\u{1B}[2m", reset = "\u{1B}[0m"

    // Structure comes from color blocks (genre-tinted, matching the web guide's own gc()
    // palette — see Genre.swift) plus one plain space between cells, not a box-drawing grid —
    // adjacent programs are never the same exact hue back-to-back, and the blank separator
    // guarantees a visible seam even when they're close. The one deliberate line left is the
    // channel-gutter divider: a single anchor down the whole frame, not a divider per cell.
    func gutterRule(_ corner: Character) -> String {
        String(repeating: "─", count: channelColWidth - 1) + String(corner) + String(repeating: "─", count: vc * slotWidth)
    }

    var out = ""

    let dev = payload.devices.first { $0.deviceId == payload.deviceId }
    let countStr = dev.map { "\($0.active)/\($0.total) tuners" } ?? "? tuners"
    out += bold + "HDHR-\(payload.deviceId.uppercased())" + reset
        + dim + "  ·  \(countStr)  ·  Tab: switch tuner" + reset
        + "  ·  " + bold + clockFormatter.string(from: Date()) + reset + "\n"

    // Selected channel + program, spelled out in full and expanded to `summaryLines` — the grid
    // cell for it is often truncated ("Sesame S…"), so this panel is the one place that always
    // shows the whole title (and, given the room, episode/genre/tags/synopsis) unambiguously.
    for line in buildSummaryLines(maxLines: summaryLines, cols: cols) {
        out += line + "\n"
    }

    var timeLine = String(repeating: " ", count: channelColWidth - 1) + "│"
    for c in 0..<vc {
        let ts = payload.winStart + (colStart + c) * secondsPerSlot
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let label = Calendar.current.component(.minute, from: date) == 0 ? hourFormatter.string(from: date) : ""
        timeLine += dim + pad(label, slotWidth) + reset
    }
    out += timeLine + "\n"
    out += dim + gutterRule("┬") + reset + "\n"

    // Pure 24-bit white (not the 16-color "bright white" code, which some terminal themes remap
    // to an off-white/gray), heavy box-drawing glyphs — a real top+bottom+sides box, not just a
    // side bracket. Costs the 2 extra lines reserved in visibleRows above. The box's left/right
    // verticals are drawn *inside* the selected tile's own content span (consuming 2 of its
    // labelWidth budget, same as the status badge already does) rather than on the shared
    // separator character between tiles — using the separator left a full character of
    // default-background gap between the colored tile and the white line on each side, so the
    // box looked like it was floating off the tile instead of hugging it.
    let outline = "\u{1B}[1;38;2;255;255;255m"

    // Builds one border line (top or bottom) for the selected tile spanning character columns
    // [frameStart, frameEnd] inclusive, filled with the tile's own genre background so the border
    // reads as traced around the tile's color, not floating on the plain terminal background.
    // frameStart/frameEnd are derived arithmetically from the slot-unit block spans (see below),
    // not by scanning the rendered (ANSI-laden) line string.
    func frameEdge(_ frameStart: Int, _ frameEnd: Int, _ bg: String, _ left: Character, _ fill: Character, _ right: Character) -> String {
        var s = String(repeating: " ", count: frameStart) + bg + outline + String(left)
        if frameEnd - frameStart > 1 { s += String(repeating: fill, count: frameEnd - frameStart - 1) }
        return s + String(right) + reset
    }

    let endRow = min(payload.channels.count, rowScroll + visibleRows)
    for r in rowScroll..<max(rowScroll, endRow) {
        let ch = payload.channels[r]
        let marker = r == selRow ? "\u{25B6}" : " "   // ▶ on the selected row's gutter, so the
                                                       // active channel is visible even scrolled
        let gutterStyle = r == selRow ? bold : ""

        // Phase 1: lay out every visible block left to right — either a real program (Some) or a
        // blank guide gap (None). No longer needs a lookahead at the next block — the box lives
        // entirely inside the selected block's own span now, not on a shared separator.
        var blocks: [(span: Int, entry: (offset: Int, element: GuideEntryDTO)?)] = []
        var cursorCol = 0
        for (idx, e) in visibleEntries(ch).enumerated() {
            let startSlot = (e.startTime - payload.winStart) / secondsPerSlot
            let endSlot = max(startSlot + 1, (e.endTime - payload.winStart + secondsPerSlot - 1) / secondsPerSlot)
            let visStart = max(startSlot, colStart)
            let visEnd = min(endSlot, colStart + vc)
            guard visEnd > visStart else { continue }
            let gapCols = max(0, (visStart - colStart) - cursorCol)
            if gapCols > 0 { blocks.append((gapCols, nil)); cursorCol += gapCols }
            let spanCols = visEnd - visStart
            blocks.append((spanCols, (idx, e)))
            cursorCol += spanCols
        }

        func isSelected(_ block: (span: Int, entry: (offset: Int, element: GuideEntryDTO)?)) -> Bool {
            r == selRow && block.entry?.offset == selEntry
        }
        let selBlockIndex = r == selRow ? blocks.firstIndex(where: isSelected) : nil

        // Character-column offsets of the selected block's own content span — exactly where its
        // title text is drawn, not the separator beyond it — so the border hugs the tile with no
        // gap. Same arithmetic-from-slot-spans approach as before, just measuring the content
        // span instead of borrowing the neighboring separator position.
        var frameStart = -1, frameEnd = -1, selBg = ""
        if let si = selBlockIndex {
            let priorSpan = blocks[0..<si].reduce(0) { $0 + $1.span }
            let labelWidth = blocks[si].span * slotWidth - 1
            frameStart = channelColWidth + priorSpan * slotWidth
            frameEnd = frameStart + labelWidth - 1
            selBg = genreBackground(blocks[si].entry?.element.genre)
        }

        if selBlockIndex != nil {
            out += frameEdge(frameStart, frameEnd, selBg, "\u{250F}", "\u{2501}", "\u{2513}") + "\n"
        }

        // Gutter is 5 fixed columns (19 chars total, matching channelColWidth-1): selection
        // marker(1) + favorite star(1) + name(15) + space(1) + signal dot(1). Each indicator
        // reserves its slot whether active or not, so channel number/name always starts at the
        // same column across every row.
        let favChar = ch.favorite ? "\u{2605}" : " "
        let favColorOn = ch.favorite ? favoriteColor : ""
        let sigBucket = signalMap[ch.guideName.lowercased()]
        let sigChar = (sigBucket == nil || sigBucket == "noData") ? " " : "\u{25CF}"
        var line = gutterStyle + marker
            + favColorOn + favChar + reset + gutterStyle
            + pad("\(ch.guideNumber) \(ch.guideName)", 15) + " "
            + signalColor(sigBucket) + sigChar + reset + "│"

        for block in blocks {
            let isSel = isSelected(block)
            let labelWidth = block.span * slotWidth - 1   // trailing char is the plain separator below

            if let (_, e) = block.entry {
                // Status is shown two ways at once — a badge glyph (mirroring the web guide's own
                // "ring + badge over genre tint" model, CLAUDE.md's "Status ring + badge") *and*
                // the whole title recolored, not just a 1-glyph icon, so a scheduled/recording
                // show reads as obviously different at a glance, not something you have to spot.
                let bg = genreBackground(e.genre)
                var used = 0
                let statusColor: String
                var badge = ""
                if e.isRecording {
                    statusColor = recordingColor
                    badge = recordingBadge; used += 2
                } else if e.isScheduled {
                    statusColor = scheduledColor
                    badge = scheduledBadge; used += 2
                } else {
                    statusColor = "\u{1B}[97m"
                }
                if isSel { used += 2 }   // the embedded "┃┃" below

                let titleWidth = max(0, labelWidth - used)
                let title = pad(truncate(e.title, titleWidth), titleWidth)
                if isSel {
                    line += bg + badge + outline + "\u{2503}" + statusColor + title + outline + "\u{2503}" + reset
                } else {
                    line += bg + badge + statusColor + title + reset
                }
            } else {
                line += String(repeating: " ", count: labelWidth)
            }
            line += " "
        }
        out += line + "\n"

        if selBlockIndex != nil {
            out += frameEdge(frameStart, frameEnd, selBg, "\u{2517}", "\u{2501}", "\u{251B}") + "\n"
        }
    }
    out += dim + gutterRule("┴") + reset + "\n\n"

    // Kept comfortably under 80 columns deliberately — this line isn't clamped to `cols` like the
    // grid content is, so on an 80-column terminal a longer string here would wrap and silently
    // break the exact line-count budget above (an extra wrapped line is exactly the scroll-flash
    // bug that budget exists to prevent).
    out += dim + "\u{2191}\u{2193} channel  \u{2190}\u{2192} show  [] page  f fav  Enter record  Tab tuner  q quit" + reset + "\n"
    let statusColor = statusMsg.hasPrefix("\u{2713}") ? "\u{1B}[32m" : (statusMsg.hasPrefix("\u{2717}") ? "\u{1B}[31m" : (statusMsg.hasPrefix("\u{26A0}") ? "\u{1B}[33m" : ""))
    out += statusColor + statusMsg + reset

    Terminal.writeFrame(out)
}

Terminal.enterRawScreen()
render()

while !interrupted {
    if Terminal.pollStdin(timeoutMs: 300) {
        if let key = Terminal.readKey() {
            handle(key)
            render()
        }
    }
    if Date().timeIntervalSince(lastPoll) >= pollInterval {
        if let fresh = API.fetchGuide(device: currentDeviceId) {
            payload = fresh
            signalMap = API.fetchSignal() ?? signalMap
            statusMsg = "Updated."
        } else {
            statusMsg = "\u{26A0} web server unreachable — showing last known data."
        }
        lastPoll = Date()
        render()
    }
}

Terminal.leaveRawScreen()
print("hdhr_guide: exiting.")
