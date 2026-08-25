import Darwin
import Foundation

DebugLog.log("=== hdhr_guide started (pid \(getpid())) ===")

// hdhr_guide — bundled terminal client for the guide (Contents/Helpers/hdhr_guide). Talks only
// to hdhrVCRplus's own LAN web server over plain HTTP (localhost:1980, hardcoded — matches
// Web_server_port's default; a custom port isn't supported yet, see docs/TUIGuide.md), never
// spawns a subprocess or dlopens anything, so it adds no App Sandbox blocker (see
// docs/MAS_COMPLIANCE.md). Requires Settings → Sharing enabled (the underlying `Web_server_enabled`
// config key/Swift symbol names are unchanged — only the Settings UI's own label was renamed, see
// SettingsView.swift) — defaults to false, so a fresh install needs that flipped once before this
// tool can reach anything.

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
// glyph is a plain "o", not the web guide's own ⏺/⏱ pair or this app's earlier "●" — color alone
// (matching the ring) carries the meaning here, and "●" is Unicode "Ambiguous width" like every
// other structural glyph this file used to use (see Terminal.swift's truncate()): plain ASCII is
// the only width-safe choice through an unknown terminal chain.
let recordingColor  = "\u{1B}[1;91m"
let recordingBadge  = "\u{1B}[91mo "
let scheduledColor  = "\u{1B}[1;38;2;59;147;255m"
let scheduledBadge  = "\u{1B}[38;2;59;147;255mo "

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
    print("Make sure hdhrVCRplus is running with Settings → Sharing enabled.")
    exit(1)
}
// Checked once, right after the first successful fetch — a courtesy gate, not a security one (the
// same endpoint this payload came from is already reachable to any browser on the LAN once Sharing
// is on regardless, see Settings → Sharing → Terminal Guide's own explanation). Exiting here just
// respects the switch rather than silently ignoring it.
guard initial.terminalGuideEnabled else {
    print("hdhr_guide: disabled — Settings → Sharing → Terminal Guide is off.")
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

// The absolute time the current selection represents — the currently selected entry's own start
// time when there is one, otherwise the left edge of the visible time window. moveRow(_:) anchors
// on this before switching rows so a channel switch can re-select "whatever's airing at the same
// time" on the new row, rather than always landing on entry 0.
func currentAnchorTime() -> Int {
    if let ch = currentChannel() {
        let entries = visibleEntries(ch)
        if selEntry >= 0, selEntry < entries.count { return entries[selEntry].startTime }
    }
    return payload.winStart + colStart * secondsPerSlot
}

// Index of whichever entry on `ch` was airing at `anchorTime`, or — if this channel has a gap in
// its schedule right at that time — whichever entry starts closest to it. nil channel/entries
// (e.g. right after a device switch resets the payload) fall back to entry 0, same as before.
func entryIndex(nearestTo anchorTime: Int, in ch: GuideChannelDTO?) -> Int {
    guard let ch else { return 0 }
    let entries = visibleEntries(ch)
    guard !entries.isEmpty else { return 0 }
    if let idx = entries.firstIndex(where: { $0.startTime <= anchorTime && $0.endTime > anchorTime }) {
        return idx
    }
    return entries.indices.min(by: {
        abs(entries[$0].startTime - anchorTime) < abs(entries[$1].startTime - anchorTime)
    }) ?? 0
}

func moveRow(_ delta: Int) {
    guard !payload.channels.isEmpty else { return }
    // Anchor on the time being viewed *before* moving the selection, not after — switching rows
    // should feel like scrolling a column of channels past a fixed point in time, not resetting
    // the horizontal position back to whatever this new channel's own first visible entry is.
    // ensureEntryVisible() below only shifts colStart if the newly selected entry actually falls
    // outside the current window, which it normally won't (its start time is, by construction,
    // at or near the currently visible anchor) — so in the common case colStart doesn't move at
    // all, and any shift that does happen is at most the small schedule-alignment gap between
    // channels, never a jump back to the start of the guide window.
    let anchorTime = currentAnchorTime()
    selRow = max(0, min(payload.channels.count - 1, selRow + delta))
    selEntry = entryIndex(nearestTo: anchorTime, in: currentChannel())
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
    // sports recording made from the TUI. Also gated on `payload.sportsPaddingEnabled`, matching
    // every other client's own `genreImpliesBonusTime && Sports_padding_enabled` pattern
    // (AddShowView.swift) — without this gate, a sports show scheduled here while the setting is
    // off would still get `show_bonus_time=true` stored, unlike an equivalent show scheduled from
    // the web guide or native wizard at the same moment, and would start actually padding the
    // instant the user later re-enables the setting for a show they never opted in.
    let bonusTime = payload.sportsPaddingEnabled && genreImpliesBonusTime(entry.genre)
    let resp = API.postRecord(deviceId: payload.deviceId, guideNumber: ch.guideNumber,
                               startTime: entry.startTime, showType: showType, bonusTime: bonusTime)
    if resp.ok {
        let recNote = resp.recStarted == true ? " (recording now)" : ""
        let queueNote = resp.tunerFull == true ? " - tuner full, queued" : ""
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
    let (cols, _) = Terminal.size()
    var out = ""

    guard let (ch, e) = currentEntry() else { Terminal.writeFrame(out); return }

    let bg = genreBackground(e.genre)
    let titleColor = e.isRecording ? recordingColor : (e.isScheduled ? scheduledColor : "\u{1B}[97m")
    out += bold + truncate(e.isScheduled ? "Manage Recording" : "Schedule Recording", max(4, cols)) + reset + "\n\n"
    // titleBudget accounts for the leading/trailing space the banner adds around the title itself.
    let titleBudget = max(4, cols - 2)
    out += bg + titleColor + " " + truncate(e.title, titleBudget) + " " + reset + "\n\n"

    let range = "\(timeFormatter.string(from: e.startDate)) - \(timeFormatter.string(from: e.endDate))"
    let mins = max(0, (e.endTime - e.startTime) / 60)
    let statusText = e.isRecording ? "Recording now" : (e.isScheduled ? "Already scheduled" : "Not scheduled")
    let statusColor = e.isRecording ? recordingColor : (e.isScheduled ? scheduledColor : "")
    // Field values are plain text (no embedded ANSI) so truncate() can measure them directly — the
    // 10-col label pad is fixed, so the value's own budget is whatever's left of `cols`. Status is
    // colored *after* truncation (fieldColored below), not before — truncate() counts raw
    // characters, so running it over an already-ANSI-wrapped string could cut mid-escape-code.
    let fieldValueBudget = max(4, cols - 10)
    func field(_ label: String, _ value: String) -> String {
        dim + pad(label, 10) + reset + truncate(value, fieldValueBudget) + "\n"
    }
    func fieldColored(_ label: String, _ value: String, _ color: String) -> String {
        dim + pad(label, 10) + reset + color + truncate(value, fieldValueBudget) + reset + "\n"
    }

    out += field("Channel", "\(ch.guideNumber) \(ch.guideName)")
    out += field("Time", "\(range)  (\(mins) min)")
    let epLabel = [e.episodeNumber, e.episodeTitle]
        .compactMap { ($0?.isEmpty == false) ? $0 : nil }
        .joined(separator: " - ")
    if !epLabel.isEmpty { out += field("Episode", epLabel) }
    if let g = e.genre, !g.isEmpty { out += field("Genre", g) }
    if let tags = e.tags, !tags.isEmpty { out += field("Tags", tags.joined(separator: ", ")) }
    if !e.isScheduled && payload.sportsPaddingEnabled && genreImpliesBonusTime(e.genre) {
        out += field("Bonus Time", "On - sports padding applied automatically")
    }
    out += fieldColored("Status", statusText, statusColor)
    out += "\n"

    if let syn = e.synopsis, !syn.isEmpty {
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

    guard let ch = currentChannel() else { return pad0([dim + truncate("No channel selected", budget) + reset]) }
    guard let (_, e) = currentEntry() else {
        let msg = "> \(ch.guideNumber) \(ch.guideName) - nothing in the guide right now"
        return pad0([dim + truncate(msg, budget) + reset])
    }

    let badge = e.isRecording ? recordingBadge + "\u{1B}[0m" : (e.isScheduled ? scheduledBadge + "\u{1B}[0m" : "")
    let titleColor = e.isRecording ? recordingColor : (e.isScheduled ? scheduledColor : bold)
    let range = "\(timeFormatter.string(from: e.startDate))-\(timeFormatter.string(from: e.endDate))"
    let mins = max(0, (e.endTime - e.startTime) / 60)

    var lines: [String] = []
    // 1: badge + title — listed first, not second, so it's the one line guaranteed to survive
    // when the panel is squeezed down to its 1-line floor on a short terminal ("what show is
    // this" matters more there than the channel/time detail on the line after it). `badge` (when
    // present) is 2 more visible characters on top of the "> " marker that `budget` already
    // reserves room for — without subtracting it here too, a recording/scheduled entry's title
    // line ran 2 characters past `cols` and wrapped.
    let badgeWidth = badge.isEmpty ? 0 : 2
    let titleBudget = max(2, budget - badgeWidth)
    lines.append("> " + badge + titleColor + truncate(e.title, titleBudget) + reset)
    // 2: channel + time/duration
    lines.append("  " + bold + truncate("\(ch.guideNumber) \(ch.guideName)   \(range)  (\(mins) min)", budget) + reset)
    // 3: episode, if any
    let epLabel = [e.episodeNumber, e.episodeTitle].compactMap { ($0?.isEmpty == false) ? $0 : nil }.joined(separator: " - ")
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
    // visibleCols()'s own `max(1, ...)` floor forces at least 1 grid column even when there isn't
    // room for the fixed 20-char channel gutter plus a single 14-char slot beside it — every row
    // line would then emit more characters than `cols` regardless, the same overflow-and-wrap bug
    // class fixed elsewhere in this file. Making the gutter itself narrower/adaptive would be the
    // real fix but touches gutter/row/box rendering throughout; this just refuses to attempt the
    // grid at all below that width, rather than rendering one that's guaranteed to overflow.
    guard cols >= channelColWidth + slotWidth else {
        let msg = "Terminal too narrow for the guide grid (need >= \(channelColWidth + slotWidth) cols, have \(cols))."
        Terminal.writeFrame(truncate(msg, max(1, cols)))
        return
    }
    let vc = visibleCols()
    // Every fixed (non-body) line this function emits, counted exactly — undercounting this by
    // even one line means the frame renders taller than the terminal, which forces a scroll, and
    // since every redraw starts with a bare cursor-home (Terminal.writeFrame), a scrolling
    // viewport makes the top of the screen appear to jump/flash on every keypress instead of
    // staying put. topFixedLines: the HDHR/clock line, the summary panel (adaptive, see
    // buildSummaryLines), the hour-label ruler, and the "+" gutter rule. bottomFixedLines: the
    // "+" gutter rule, the blank line after it, the keybinding-hint line, and the status line.
    // boxLines: the selected tile's top+bottom border — always drawn, since the selected row is
    // always within the visible range.
    //
    // Fixed at 8 lines rather than scaling with terminal height — an earlier scaling formula
    // ((rows-16)/3, capped 2...8) hit its own cap on any terminal taller than ~40 rows, which in
    // practice meant most real terminals always rendered the same max-size panel anyway, just via
    // an unpredictable formula instead of a plain constant; a fixed-10 revision after that still
    // looked too tall in practice. Still fully protected by the shrink-loop right below: a short
    // terminal that can't fit 8 lines shrinks this down (as low as 0, hiding the panel) exactly
    // the same way it already handled the earlier formula's floor.
    var summaryLines = 8
    let bottomFixedLines = 4
    let boxLines = 2
    // visibleRows' own floor of 1 (a data row has to exist for the app to be usable at all) can't
    // shrink further, so if the fixed overhead still doesn't fit at that floor, reclaim lines from
    // the summary panel instead — down to 0 (hiding it) before conceding to genuine overflow. This
    // is what the "one line too many forces the terminal itself to scroll" failure mode in
    // docs/TUIGuide.md's "Redraw model" section actually traces back to: the old hard floor of 1
    // meant `visibleRows` could stay pinned at 1 even when `rows` was too small to fit the rest of
    // the fixed budget around it, so the frame silently rendered taller than the terminal — each
    // subsequent redraw's cursor-home then landed on whatever row the previous overflow had
    // scrolled to, not true row 1, so the top of the frame (this summary panel included) appeared
    // to climb off-screen a little further on every keypress.
    var topFixedLines = 3 + summaryLines
    var visibleRows = rows - topFixedLines - bottomFixedLines - boxLines
    while visibleRows < 1 && summaryLines > 0 {
        summaryLines -= 1
        topFixedLines = 3 + summaryLines
        visibleRows = rows - topFixedLines - bottomFixedLines - boxLines
    }
    visibleRows = max(1, visibleRows)

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
        String(repeating: "-", count: channelColWidth - 1) + String(corner) + String(repeating: "-", count: vc * slotWidth)
    }

    var out = ""

    let dev = payload.devices.first { $0.deviceId == payload.deviceId }
    let countStr = dev.map { "\($0.active)/\($0.total) tuners" } ?? "? tuners"
    // Built from whole, individually-colored segments rather than one long ANSI-laden string —
    // unlike the grid/summary panel's plain substrings, there's no safe way to truncate() a string
    // that already has escape codes woven through it (cutting could land mid-code), so a narrow
    // terminal instead drops whole trailing segments (least essential first) until what's left
    // fits `cols`, rather than silently overflowing into a wrap.
    // "|" rather than "-" — the header sits directly above a wall of "----+----" gutter/hour-ruler
    // rules, and reusing "-" as a field separator there read as noisy repetition right next to
    // them. "|" doubles as the same divider glyph the grid's own channel gutter uses, so it reads
    // as the same "this separates fields" language rather than an unrelated pick.
    let headerSeps = "  |  "
    let headerSegs: [(plain: String, colored: String)] = [
        ("HDHR-\(payload.deviceId.uppercased())", bold + "HDHR-\(payload.deviceId.uppercased())" + reset),
        (countStr, dim + countStr + reset),
        ("\(cols)x\(rows)", dim + "\(cols)x\(rows)" + reset),
        (clockFormatter.string(from: Date()), bold + clockFormatter.string(from: Date()) + reset),
        ("Tab: switch tuner", dim + "Tab: switch tuner" + reset),
    ]
    var headerLine = "", headerPlainLen = 0
    for (i, seg) in headerSegs.enumerated() {
        let addLen = (i == 0 ? 0 : headerSeps.count) + seg.plain.count
        guard headerPlainLen + addLen <= cols else { break }
        if i > 0 { headerLine += dim + headerSeps + reset }
        headerLine += seg.colored
        headerPlainLen += addLen
    }
    out += headerLine + "\n"

    // Selected channel + program, spelled out in full and expanded to `summaryLines` — the grid
    // cell for it is often truncated ("Sesame S…"), so this panel is the one place that always
    // shows the whole title (and, given the room, episode/genre/tags/synopsis) unambiguously.
    for line in buildSummaryLines(maxLines: summaryLines, cols: cols) {
        out += line + "\n"
    }

    var timeLine = String(repeating: " ", count: channelColWidth - 1) + "|"
    for c in 0..<vc {
        let ts = payload.winStart + (colStart + c) * secondsPerSlot
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let label = Calendar.current.component(.minute, from: date) == 0 ? hourFormatter.string(from: date) : ""
        timeLine += dim + pad(label, slotWidth) + reset
    }
    out += timeLine + "\n"
    out += dim + gutterRule("+") + reset + "\n"

    // Pure 24-bit white (not the 16-color "bright white" code, which some terminal themes remap
    // to an off-white/gray), a plain-ASCII box — "+"/"="/"|", not the heavier Unicode box-drawing
    // glyphs this used to use (┏━┓/┃/┗━┛): those are all Unicode "Ambiguous width", so a terminal
    // in the rendering chain that draws them 2 columns wide instead of 1 (confirmed on a
    // browser → Raspberry Pi → SSH chain) silently overflowed every line that had one. ASCII has
    // no ambiguous-width case anywhere, so it's the only choice guaranteed correct through an
    // unknown chain of terminals. Costs the 2 extra lines reserved in visibleRows above. The box's
    // left/right verticals are drawn *inside* the selected tile's own content span (consuming 2 of
    // its labelWidth budget, same as the status badge already does) rather than on the shared
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
        let marker = r == selRow ? ">" : " "   // ">" on the selected row's gutter, so the
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
            // Clamped to `colStart + cursorCol`, not just `colStart` — real-world guide data can
            // carry overlapping/duplicate entries for one channel (a live-feed quirk, confirmed
            // seen on this device: two back-to-back "Jerry Springer" listings whose slot ranges
            // actually overlapped by a slot), and without this an overlapping entry rendered
            // starting *before* the previous block had finished, pushing `cursorCol` past `vc` —
            // the row's total content then ran wider than the terminal and wrapped.
            let visStart = max(startSlot, colStart, colStart + cursorCol)
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
            out += frameEdge(frameStart, frameEnd, selBg, "+", "=", "+") + "\n"
        }

        // Gutter is 5 fixed columns (19 chars total, matching channelColWidth-1): selection
        // marker(1) + favorite star(1) + name(15) + space(1) + signal dot(1). Each indicator
        // reserves its slot whether active or not, so channel number/name always starts at the
        // same column across every row.
        let favChar = ch.favorite ? "*" : " "
        let favColorOn = ch.favorite ? favoriteColor : ""
        // Trim, not just lowercase — ChannelSignalStore.key(for:) (the canonical key every writer
        // uses) does both; a reader that only lowercases silently misses data recorded for any
        // whitespace-padded GuideName (CLAUDE.md's "Signal keys" invariant).
        let sigBucket = signalMap[ch.guideName.trimmingCharacters(in: .whitespaces).lowercased()]
        let sigChar = (sigBucket == nil || sigBucket == "noData") ? " " : "o"
        var line = gutterStyle + marker
            + favColorOn + favChar + reset + gutterStyle
            + pad("\(ch.guideNumber) \(ch.guideName)", 15) + " "
            + signalColor(sigBucket) + sigChar + reset + "|"

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
                if isSel { used += 2 }   // the embedded "||" below

                let titleWidth = max(0, labelWidth - used)
                let title = pad(truncate(e.title, titleWidth), titleWidth)
                if isSel {
                    line += bg + badge + outline + "|" + statusColor + title + outline + "|" + reset
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
            out += frameEdge(frameStart, frameEnd, selBg, "+", "=", "+") + "\n"
        }
    }
    out += dim + gutterRule("+") + reset + "\n\n"

    // Explicitly clamped to `cols` (not just "kept comfortably under 80" by wording alone) — on a
    // narrower terminal a longer line here would wrap and silently break the exact line-count
    // budget above (an extra wrapped line is exactly the scroll-flash bug that budget exists to
    // prevent).
    let hint = "^v channel  <> show  [] page  f fav  Enter record  Tab tuner  q quit"
    out += dim + truncate(hint, cols) + reset + "\n"
    // statusMsg embeds the show's own title (e.g. "✓ Scheduled: <title>") — unbounded length,
    // unlike the hint line above — so it needs the same clamp, not just a short fixed string.
    let statusColor = statusMsg.hasPrefix("\u{2713}") ? "\u{1B}[32m" : (statusMsg.hasPrefix("\u{2717}") ? "\u{1B}[31m" : (statusMsg.hasPrefix("\u{26A0}") ? "\u{1B}[33m" : ""))
    out += statusColor + truncate(statusMsg, cols) + reset

    Terminal.writeFrame(out)
}

Terminal.enterRawScreen()
render()

while !interrupted {
    if Terminal.pollStdin(timeoutMs: 300) {
        if let key = Terminal.readKey() {
            handle(key)
            // A fast mouse/trackpad scroll arrives as a burst of arrow-key-equivalent bytes (the
            // terminal's own alternate-scroll-mode translation, Terminal.swift's enterRawScreen),
            // not one at a time — draining everything already waiting on stdin (pollStdin with a
            // 0ms timeout: "is there more right now," no blocking) and applying it all before the
            // next render() makes a fast scroll jump the selection multiple rows per redraw, the
            // way a normal scrollable list does, instead of crawling one row per full-frame
            // rewrite. It also means one redraw instead of N for that whole burst — over a slow or
            // multi-hop connection (confirmed elsewhere in this app: browser → Raspberry Pi → SSH),
            // N full-frame writes in rapid succession is N chances for a hop somewhere in that
            // chain to drop, delay, or interleave one of them, which is a very plausible way for
            // the terminal's own view to end up scrolled/desynced from what this app thinks row 1
            // is — see "Redraw model" in docs/TUIGuide.md. Capped at 200 so a stuck key or a
            // pathological input flood can't wedge this loop indefinitely without ever redrawing.
            var drained = 0
            while !interrupted, drained < 200, Terminal.pollStdin(timeoutMs: 0), let next = Terminal.readKey() {
                handle(next)
                drained += 1
            }
            render()
        }
    }
    // Skipped (both the fetch and lastPoll itself) while the record/manage confirmation screen is
    // up — renderSummaryScreen()/handle(_:) rely on selRow/selEntry staying valid against whatever
    // `payload` they were opened against ("it's safe to re-resolve the same entry here" — see that
    // comment), which a mid-air payload swap could quietly break: currentEntry() could start
    // returning a different program than the one on screen, or nil (leaving an empty frame stuck
    // in this mode with only Esc still working). Not updating lastPoll means the next eligible
    // tick fires as soon as this screen closes, rather than the poll going stale for however long
    // someone sat on the screen.
    if mode != .recordSummary, Date().timeIntervalSince(lastPoll) >= pollInterval {
        if let fresh = API.fetchGuide(device: currentDeviceId) {
            payload = fresh
            signalMap = API.fetchSignal() ?? signalMap
            statusMsg = "Updated."
        } else {
            statusMsg = "\u{26A0} web server unreachable - showing last known data."
        }
        lastPoll = Date()
        render()
    }
}

Terminal.leaveRawScreen()
print("hdhr_guide: exiting.")
