import SwiftUI
import AppKit

private let vlcOrange   = Color(red: 1.0, green: 0.482, blue: 0.0)
private let watchNowBlue = Color(red: 0.2, green: 0.6, blue: 1.0)

struct MenuContent: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) var openWindow

    // Static so DateFormatter is created once for the app lifetime, not once per guide entry shown
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f
    }()
    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE"; return f
    }()
    // "Thu" abbreviation for compact upcoming-slot labels in scheduledMenu
    private static let shortWeekdayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE"; return f
    }()

    /// Open a WindowGroup scene reliably from a .menu-style MenuBarExtra.
    /// The menu dismisses synchronously; deferring to the next run loop tick
    /// ensures the window request fires after the menu is fully gone.
    private func open(_ id: String) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let title: String
            switch id {
            case "add-show":   title = "Add Show"
            case "edit-show":  title = "Edit Show"
            case "settings":   title = "Settings"
            case "watch-now":  title = "Watch Now"
            default:          title = id
            }
            if let w = NSApp.windows.first(where: { $0.title == title }) {
                w.makeKeyAndOrderFront(nil)
                return
            }
            openWindow(id: id)
        }
    }

    // Returns the channel + current guide entry for the active VLC stream, or nil when nothing is playing.
    private var nowWatchingInfo: (channel: LineupEntry, entry: GuideEntry?)? {
        guard !state.vlcCurrentURL.isEmpty else { return nil }
        let base = state.vlcCurrentURL.components(separatedBy: "?").first ?? state.vlcCurrentURL
        for device in state.devices {
            guard let channel = (state.lineups[device.DeviceID] ?? []).first(where: {
                let u = $0.URL ?? ""
                return !u.isEmpty && u == base
            }) else { continue }
            let now   = Date()
            let entry = state.guideEntries(deviceId: device.DeviceID, channelNum: channel.GuideNumber)
                .first { $0.startDate <= now && $0.endDate > now }
            return (channel, entry)
        }
        return nil
    }

    var body: some View {

        // Compute derived show lists once — each is a filter/sort over shows[];
        // binding to let avoids re-running the filter for every reference below
        let recordingShows = state.recordingShows
        let activeShows    = state.activeShows
        let pausedShows    = state.pausedShows

        // ── Header ────────────────────────────────────────────────────────
        ForEach(state.devices) { device in
            let slots     = device.TunerCount ?? 1
            let appCount  = recordingShows.filter { $0.hdhr_record == device.DeviceID }.count
            let liveInfo  = state.deviceTunerOccupancy[device.DeviceID]
            let liveCount = liveInfo?.filter { $0.VctNumber != nil }.count ?? appCount
            let mismatch  = liveInfo != nil && liveCount != appCount
            let noLineup  = !state.isStartingUp && (state.lineups[device.DeviceID]?.isEmpty ?? true)
            let noGuide   = !state.isStartingUp && (state.guideByDevice[device.DeviceID]?.isEmpty ?? true)
            let warnings  = [noLineup ? "no lineup" : nil, noGuide ? "no guide" : nil]
                                .compactMap { $0 }.joined(separator: ", ")
            let hasWarn   = !warnings.isEmpty
            Text("\(device.DeviceID)  \(liveCount)/\(slots)" +
                 (mismatch ? "  ⚠ app expects \(appCount)" : "") +
                 (hasWarn  ? "  ⚠ \(warnings)" : ""))
                .foregroundStyle(hasWarn    ? Color(NSColor.systemOrange) :
                                 liveCount > 0 ? Color(NSColor.labelColor) :
                                                 Color(NSColor.secondaryLabelColor))
        }
        Text(state.statusMessage).foregroundStyle(Color(NSColor.secondaryLabelColor))
        // ── Now Watching ──────────────────────────────────────────────────
        if let info = nowWatchingInfo {
            Button {
                DispatchQueue.main.async { VLCPlayerWindowManager.shared.focus() }
            } label: {
                Label {
                    Text("Ch \(info.channel.GuideNumber)  \(info.channel.GuideName)" +
                         (info.entry.map { " · \($0.Title)" } ?? ""))
                } icon: {
                    Image(systemName: "play.tv.fill").foregroundStyle(watchNowBlue)
                }
            }
        }
        // ── Watch Now ─────────────────────────────────────────────────────
        watchNowMenu
        // ── Add Show ──────────────────────────────────────────────────────
        Button { open("add-show") } label: { Label("Add Show…", systemImage: "plus") }
        Divider()

        Button("Settings…")    { open("settings") }
        Divider()

        // ── Recording now ─────────────────────────────────────────────────
        if !recordingShows.isEmpty {
            if state.devices.count > 1 {
                ForEach(state.devices) { device in
                    let recs = recordingShows.filter { $0.hdhr_record == device.DeviceID }
                    if !recs.isEmpty {
                        Section("Recording · \(device.DeviceID)") {
                            ForEach(recs) { recordingMenu($0) }
                        }
                    }
                }
            } else {
                Section("Recording Now") {
                    ForEach(recordingShows) { recordingMenu($0) }
                }
            }
            Divider()
        }

        // ── Next Up ────────────────────────────────────────────────────────
        // Shows starting within the next hour, grouped by start time (bucketed to minute).
        let now = Date()
        let nextUpGroups: [(time: Date, shows: [Show])] = {
            let cutoff = now + 60 * 60
            let cal = Calendar.current
            var byMinute: [Date: [Show]] = [:]
            for show in activeShows {
                guard let d = show.show_next, d > now, d <= cutoff else { continue }
                var c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: d)
                c.second = 0
                let bucket = cal.date(from: c) ?? d
                byMinute[bucket, default: []].append(show)
            }
            return byMinute.sorted { $0.key < $1.key }.map { (time: $0.key, shows: $0.value) }
        }()
        let nextUpIds       = Set(nextUpGroups.flatMap { $0.shows }.map { $0.show_id })
        let remainingActive = activeShows.filter { !nextUpIds.contains($0.show_id) }

        if !nextUpGroups.isEmpty {
            if state.devices.count > 1 {
                ForEach(state.devices) { device in
                    let deviceGroups = nextUpGroups
                        .map { (time: $0.time, shows: $0.shows.filter { $0.hdhr_record == device.DeviceID }) }
                        .filter { !$0.shows.isEmpty }
                    if !deviceGroups.isEmpty {
                        Section("Up Next · \(device.DeviceID)") {
                            ForEach(deviceGroups, id: \.time) { group in
                                Section(Self.timeFormatter.string(from: group.time)) {
                                    ForEach(group.shows) { scheduledMenu($0, showChannel: true) }
                                }
                            }
                        }
                    }
                }
            } else {
                Section("Up Next") {
                    ForEach(nextUpGroups, id: \.time) { group in
                        Section(Self.timeFormatter.string(from: group.time)) {
                            ForEach(group.shows) { scheduledMenu($0, showChannel: true) }
                        }
                    }
                }
            }
            Divider()
        }

        // ── Scheduled shows ───────────────────────────────────────────────
        if activeShows.isEmpty && pausedShows.isEmpty {
            Text("No shows scheduled").foregroundStyle(.secondary)
        } else {
            if !remainingActive.isEmpty {
                if state.devices.count > 1 {
                    ForEach(state.devices) { device in
                        let deviceShows = remainingActive.filter { $0.hdhr_record == device.DeviceID }
                        if !deviceShows.isEmpty {
                            Section("Scheduled · \(device.DeviceID)") {
                                ForEach(deviceShows) { scheduledMenu($0) }
                            }
                        }
                    }
                } else {
                    Section("Scheduled") {
                        ForEach(remainingActive) { scheduledMenu($0) }
                    }
                }
            }
            if !pausedShows.isEmpty {
                if state.devices.count > 1 {
                    ForEach(state.devices) { device in
                        let devicePaused = pausedShows.filter { $0.hdhr_record == device.DeviceID }
                        if !devicePaused.isEmpty {
                            Section("Paused · \(device.DeviceID)") {
                                ForEach(devicePaused) { pausedMenu($0) }
                            }
                        }
                    }
                } else {
                    Section("Paused") {
                        ForEach(pausedShows) { pausedMenu($0) }
                    }
                }
            }
        }
        Divider()

        Button("Quit hdhrVCRplus", role: .destructive) { state.quit() }
    }

    // MARK: ── Watch Now ───────────────────────────────────────────────────
    // Opens a dedicated window with poster-card grid; no cascade needed.

    @ViewBuilder
    private var watchNowMenu: some View {
        if !state.devices.isEmpty {
            Button {
                state.watchNowDeviceId = nil
                open("watch-now")
            } label: {
                Label("Watch Now…", systemImage: "play.tv.fill")
                    .foregroundStyle(watchNowBlue)
            }
        }
    }

    // MARK: ── Existing show menus ────────────────────────────────────────

    @ViewBuilder
    private func recordingMenu(_ show: Show) -> some View {
        let recNow       = Date()
        let recEntries   = state.guideEntries(deviceId: show.hdhr_record, channelNum: show.show_channel)
        let currentEntry = recEntries.first { $0.startDate <= recNow && $0.endDate > recNow }
        let recEp        = currentEntry.flatMap { $0.episodeInfoLabel }
        let menuTitle    = recEp.map { "🔴 \(show.show_title) · \($0)" } ?? "🔴 \(show.show_title)"
        // Bonus Time: sports shows record past the guide end — adjust the displayed end time
        let isSportsBonus = state.config.Sports_padding_enabled && show.show_bonus_time
        let bonusPadding  = isSportsBonus ? TimeInterval(state.config.Sports_padding_minutes * 60) : 0
        Menu(menuTitle) {
            let started      = show.show_next ?? recNow
            let guideEnd     = show.show_end  ?? recNow
            let ends         = guideEnd.addingTimeInterval(bonusPadding)
            let inBonusTime  = isSportsBonus && recNow > guideEnd

            showInfoHeader(show, entry: currentEntry)
            Divider()
            menuInfo("\(show.state.rawValue) · Channel \(show.show_channel)", font: .footnote)
            menuInfo("\(Self.timeFormatter.string(from: started)) · \(show.show_length) min", font: .footnote, secondary: true)
            if inBonusTime {
                menuInfo("🏈 Bonus Time (+\(state.config.Sports_padding_minutes) min)", font: .footnote, secondary: true)
            }
            menuInfo("tuner \(show.hdhr_record)", font: .footnote, secondary: true)
            if let sig = state.tunerStatus[show.show_id] {
                menuInfo(sig.displayString, font: .footnote, secondary: true)
            }
            Divider()
            Button("Skip", role: .destructive) { Task { await state.skipRecording(showId: show.show_id) } }
            Button("Delete…", role: .destructive) { state.confirmAndDeleteShow(show) }
            if !show.show_recording_path.isEmpty {
                Button("Show Recording in Finder") {
                    NSWorkspace.shared.selectFile(show.show_recording_path,
                                                  inFileViewerRootedAtPath: "")
                }
            }
            if state.config.Watch_in_VLC {
                Button(action: { state.watchInVLC(url: show.show_url, transcode: show.show_transcode, deviceId: show.hdhr_record) }) {
                    Label { Text("Watch in VLC").foregroundColor(vlcOrange) }
                          icon: { Image(systemName: "arrow.up.forward.app").foregroundColor(vlcOrange) }
                }
            }
            if VLCBridge.shared.isAvailable {
                Button(action: { state.watchInApp(url: show.show_url, title: show.show_title, deviceId: show.hdhr_record, transcode: show.show_transcode) }) {
                    Label { Text("Watch Now!").foregroundColor(watchNowBlue) }
                          icon: { Image(systemName: "play.tv.fill").foregroundColor(watchNowBlue) }
                }
            }
            Button("Edit…") { editShow(show) }
        }
    }

    @ViewBuilder
    private func scheduledMenu(_ show: Show, showChannel: Bool = false) -> some View {
        // Pre-computed in AppState.rebuildMenuEntries() every idle tick and after guide loads —
        // avoids O(series entries) scan per show per menu open.
        let conflict  = state.conflictingShowIDs.contains(show.show_id)
        let prefix    = conflict ? "⚠️ " : ""
        let schEntry  = state.menuScheduledEntry[show.show_id]
        let schEp     = schEntry.flatMap { $0.episodeInfoLabel }
        let chSuffix  = showChannel ? "  ch \(show.show_channel)" : ""
        let schLabel  = schEp.map { "\(prefix)\(stateIcon(show)) \(show.show_title) · \($0)\(chSuffix)" }
                    ?? "\(prefix)\(stateIcon(show)) \(show.show_title)\(chSuffix)"

        Menu(schLabel) {
            let now  = Date()
            let next = show.show_next ?? .distantFuture
            let ends = show.show_end  ?? .distantFuture

            showInfoHeader(show, entry: schEntry)
            Divider()

            menuInfo("\(show.state.rawValue) · Channel \(show.show_channel)", font: .footnote)
            if conflict {
                menuInfo("⚠️ Conflict — all tuners busy at this time", font: .footnote, secondary: true)
            }

            // Timing: start time · duration
            menuInfo("\(Self.timeFormatter.string(from: next)) · \(show.show_length) min", font: .footnote, secondary: true)

            // Upcoming recording slots — source depends on show type
            let upcoming: [(channel: String, date: Date)] = {
                switch show.state {
                case .single:
                    if let d = show.show_next { return [(show.show_channel, d)] }
                    return []
                case .dateTime:
                    return state.nextDateTimeOccurrences(for: show, after: Date(), count: 3).map { (show.show_channel, $0) }
                case .seriesChannel, .seriesAll:
                    return state.menuUpcomingSlots[show.show_id] ?? []
                }
            }()
            if !upcoming.isEmpty {
                Divider()
                if upcoming.count > 1 {
                    menuInfo("Upcoming", font: .caption, secondary: true)
                }
                ForEach(upcoming, id: \.date) { slot in
                    menuInfo(upcomingLabel(channel: slot.channel, date: slot.date), font: .footnote)
                }
            }

            if show.show_fail_count > 0 {
                Divider()
                menuInfo("⚠️ \(show.show_fail_count) failure(s): \(show.show_fail_reason)", font: .footnote)
            }
            Divider()
            Button("Edit…")      { editShow(show) }
            Button("Pause") { state.pauseShow(show) }
            Button("Delete…", role: .destructive) { state.confirmAndDeleteShow(show) }
        }
    }

    @ViewBuilder
    private func pausedMenu(_ show: Show) -> some View {
        Menu("⏸ \(show.show_title)") {
            let pausedEntries = state.guideEntries(deviceId: show.hdhr_record, channelNum: show.show_channel)
            let pausedEntry   = pausedEntries.first {
                abs($0.startDate.timeIntervalSince(show.show_next ?? .distantPast)) < 5 * 60
            }
            showInfoHeader(show, entry: pausedEntry)
            Divider()
            menuInfo("\(show.state.rawValue) · Channel \(show.show_channel)", font: .footnote, secondary: true)
            if !show.show_fail_reason.isEmpty {
                menuInfo("Reason: \(show.show_fail_reason)", font: .footnote, secondary: true)
            }
            if let next = show.show_next, next > Date() {
                menuInfo("Next attempt: \(Self.timeFormatter.string(from: next))", font: .footnote, secondary: true)
            }
            Divider()
            Button("Resume Now") { state.resumeShow(show) }
            Button("Edit…") { editShow(show) }
            Button("Delete…", role: .destructive) { state.confirmAndDeleteShow(show) }
        }
    }

    // MARK: ── Helpers ────────────────────────────────────────────────────

    private func editShow(_ show: Show) {
        state.editingShowId = show.show_id
        open("edit-show")
    }

    private func stateIcon(_ show: Show) -> String {
        switch show.state {
        case .single:        return "1️⃣"
        case .dateTime:      return "📅"
        case .seriesChannel: return "🔂"
        case .seriesAll:     return "🔁"
        }
    }

    /// "2h 15m", "45m", "30s" — for a positive interval
    private func relativeLabel(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let h = total / 3600; let m = (total % 3600) / 60; let s = total % 60
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        if m > 0 { return "\(m)m" }
        return "\(s)s"
    }

    private func elapsedLabel(since start: Date) -> String {
        relativeLabel(Date().timeIntervalSince(start))
    }

    private func remainingLabel(until end: Date) -> String {
        relativeLabel(end.timeIntervalSince(Date()))
    }

    // "ch 5.1 · 8:00 PM" (today) or "ch 5.1 · Thu 8:00 PM" (future day)
    private func upcomingLabel(channel: String, date: Date) -> String {
        let t = Self.timeFormatter.string(from: date)
        if Calendar.current.isDateInToday(date) { return "Channel \(channel) · \(t)" }
        return "Channel \(channel) · \(Self.shortWeekdayFormatter.string(from: date)) \(t)"
    }

    // Shared show-info panel used by recordingMenu, scheduledMenu, and pausedMenu.
    // Renders poster (460×258), title, episode info, and synopsis in a consistent layout.
    @ViewBuilder
    private func showInfoHeader(_ show: Show, entry: GuideEntry?) -> some View {
        if !show.show_logo_url.isEmpty, let url = URL(string: show.show_logo_url) {
            AsyncImage(url: url) { img in
                img.resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 460, height: 258).clipped().cornerRadius(6)
            } placeholder: {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(NSColor.separatorColor))
                    .frame(width: 460, height: 258)
            }
            .accessibilityLabel("\(show.show_title) poster")
            .overlay(alignment: .topTrailing) {
                Path { p in
                    p.move(to:    CGPoint(x: 0,  y: 0))
                    p.addLine(to: CGPoint(x: 24, y: 0))
                    p.addLine(to: CGPoint(x: 24, y: 24))
                    p.closeSubpath()
                }
                .fill(Color.yellow)
                .frame(width: 24, height: 24)
                .accessibilityLabel("Already scheduled")
            }
        }
        menuInfo(show.show_title, font: .title3, maxWidth: 460)
        if let ep = entry?.episodeInfoLabel {
            menuInfo(ep, font: .callout, maxWidth: 460)
        }
        if let syn = entry?.Synopsis, !syn.isEmpty {
            menuInfo(truncateSynopsis(syn), font: .callout, maxWidth: 460)
        }
    }

    // Universal helper: wraps info text in a no-op Button so AppKit renders it at full
    // brightness. Plain Text views in Menu {} blocks are auto-disabled by NSMenu and drawn
    // at ~50% opacity regardless of the foreground color — Button avoids that treatment.
    // Pass maxWidth to constrain width and allow the text to wrap (up to 4 lines).
    @ViewBuilder
    private func menuInfo(_ string: String, font: Font = .body, secondary: Bool = false, maxWidth: CGFloat? = nil) -> some View {
        Button(action: {}) {
            Text(string).font(font)
                .foregroundColor(secondary ? Color(NSColor.secondaryLabelColor) : Color(NSColor.labelColor))
                .lineLimit(maxWidth == nil ? nil : 4)
                // Fixed width (not maxWidth) forces NSMenu items to wrap rather than
                // expanding the menu horizontally to fit a single long line.
                .frame(width: maxWidth, alignment: .leading)
        }
    }

    // "8:00 PM – 8:30 PM"
    private func timeRange(_ entry: GuideEntry) -> String {
        return "\(Self.timeFormatter.string(from: entry.startDate)) – \(Self.timeFormatter.string(from: entry.endDate))"
    }

    private func weekdayName(_ date: Date) -> String {
        return Self.weekdayFormatter.string(from: date)
    }

    private func truncateSynopsis(_ text: String, limit: Int = 160) -> String {
        guard text.count > limit else { return text }
        let cut = text.index(text.startIndex, offsetBy: limit)
        if let space = text[..<cut].lastIndex(of: " ") {
            return String(text[..<space]) + "…"
        }
        return String(text[..<cut]) + "…"
    }

}

