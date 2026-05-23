import SwiftUI
import AppKit

private let vlcOrange = Color(red: 1.0, green: 0.482, blue: 0.0)

struct MenuContent: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) var openWindow
    @AppStorage("addShowMode") private var addShowMode: AddShowMode = .menu

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
            case "add-show":  title = "Add Show"
            case "edit-show": title = "Edit Show"
            case "settings":  title = "Settings"
            default:          title = id
            }
            if let w = NSApp.windows.first(where: { $0.title == title }) {
                w.makeKeyAndOrderFront(nil)
                return
            }
            openWindow(id: id)
        }
    }

    var body: some View {

        // Compute derived show lists once — each is a filter/sort over shows[];
        // binding to let avoids re-running the filter for every reference below
        let recordingShows = state.recordingShows
        let activeShows    = state.activeShows
        let inactiveShows  = state.inactiveShows

        // ── Header ────────────────────────────────────────────────────────
        ForEach(state.devices) { device in
            let slots  = device.TunerCount ?? 1
            let active = recordingShows.filter { $0.hdhr_record == device.DeviceID }.count
            Text("\(device.DeviceID)  \(active)/\(slots)")
                .foregroundStyle(active > 0 ? Color(NSColor.labelColor) : Color(NSColor.secondaryLabelColor))
        }
        Text(state.statusMessage).foregroundStyle(Color(NSColor.secondaryLabelColor))
        // ── Add Show ──────────────────────────────────────────────────────
        if addShowMode == .menu {
            addShowMenu
        } else {
            Button("Add Show…") { open("add-show") }
        }
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
        // Compute slotShows here so the Scheduled section can exclude them (avoids
        // showing the same show in both Next Up and Scheduled at the same time).
        let now = Date()
        let slotShows: [Show] = {
            guard let t = activeShows.compactMap({ $0.show_next.date }).filter({ $0 > now }).min()
            else { return [] }
            return activeShows.filter {
                guard let d = $0.show_next.date else { return false }
                return abs(d.timeIntervalSince(t)) < 5 * 60
            }
        }()
        let slotShowIds   = Set(slotShows.map { $0.show_id })
        let remainingActive = activeShows.filter { !slotShowIds.contains($0.show_id) }

        if !slotShows.isEmpty, let slotTime = slotShows.first?.show_next.date {
            Section("Next Up") {
                menuInfo("\(Self.timeFormatter.string(from: slotTime)) · in \(relativeLabel(slotTime.timeIntervalSince(now)))",
                         font: .footnote, secondary: true)
                ForEach(slotShows) { scheduledMenu($0) }
            }
            Divider()
        }

        // ── Scheduled shows ───────────────────────────────────────────────
        if activeShows.isEmpty && inactiveShows.isEmpty {
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
            if !inactiveShows.isEmpty {
                Section("Paused") {
                    ForEach(inactiveShows) { show in pausedMenu(show) }
                }
            }
        }
        Divider()

        Button("Settings…")    { open("settings") }
        Divider()

        Button("Quit hdhrVCRplus", role: .destructive) { state.quit() }
    }

    // MARK: ── Level 1: Add Show ──────────────────────────────────────────
    // If only 1 device, skip the device level and go straight to channels.

    @ViewBuilder
    private var addShowMenu: some View {
        let menuLabel = "Add Show"
        if state.devices.isEmpty {
            Text("No tuners detected").foregroundStyle(.secondary)
        } else if state.devices.count == 1, let device = state.devices.first {
            Menu(menuLabel) {
                // Trigger guide fetch as soon as this menu renders
                let _ = { state.ensureGuideLoaded(for: device.DeviceID) }()
                channelMenus(for: device)
            }
        } else {
            // Level 2: device chooser
            Menu(menuLabel) {
                ForEach(state.devices) { device in
                    Menu(device.DeviceID) {
                        let _ = { state.ensureGuideLoaded(for: device.DeviceID) }()
                        channelMenus(for: device)
                    }
                }
            }
        }
    }

    // MARK: ── Level 2 (or 3): Channel list ──────────────────────────────

    @ViewBuilder
    private func channelMenus(for device: HDHRDevice) -> some View {
        let channels = state.lineups[device.DeviceID] ?? []
        // Amber accent bar (comedy/warm hue from the guide genre palette) marks the channel-list depth
        Rectangle()
            .fill(Color(hue: 0.13, saturation: 0.75, brightness: 0.90).opacity(0.65))
            .frame(height: 5)
        if channels.isEmpty {
            Text("No channels — try Refresh Guide").foregroundStyle(.secondary)
        } else {
            ForEach(channels, id: \.GuideNumber) { ch in
                channelMenu(device: device, channel: ch)
            }
        }
    }

    // MARK: ── Level 3 (or 4): Guide entries for a channel ───────────────

    @ViewBuilder
    private func channelMenu(device: HDHRDevice, channel: LineupEntry) -> some View {
        let entries   = state.guideEntries(deviceId: device.DeviceID, channelNum: channel.GuideNumber)
        let loading   = state.isGuideLoading(for: device.DeviceID)
        let hdBadge   = channel.HD == 1 ? " HD" : ""
        let label     = "\(channel.GuideNumber)  \(channel.GuideName)\(hdBadge)"
        let now       = Date()
        let onAir     = entries.filter { $0.startDate <= now && $0.endDate > now }
        let upcoming  = entries.filter { $0.startDate > now }

        Menu(label) {
            // Blue accent bar (drama hue from guide palette) marks the entry-list depth
            Rectangle()
                .fill(Color(hue: 0.60, saturation: 0.75, brightness: 0.85).opacity(0.65))
                .frame(height: 5)
            if entries.isEmpty {
                if loading {
                    Text("Fetching guide…").foregroundStyle(.secondary)
                } else {
                    Text("No upcoming shows").foregroundStyle(.secondary)
                    Button("Load guide") { state.ensureGuideLoaded(for: device.DeviceID) }
                }
            } else {
                ForEach(onAir) { entry in
                    entryMenu(entry: entry, device: device, channel: channel, isOnAir: true)
                }
                if !onAir.isEmpty && !upcoming.isEmpty { Divider() }
                ForEach(upcoming) { entry in
                    entryMenu(entry: entry, device: device, channel: channel, isOnAir: false)
                }
            }
        }
    }

    // MARK: ── Level 4 (or 5): Show entry + type selection ───────────────
    // Label in the parent menu: "8:00 PM  Jeopardy! (30 min)"
    // Submenu: synopsis, divider, Add as Single / Add as Series → (3 types)

    @ViewBuilder
    private func entryMenu(entry: GuideEntry, device: HDHRDevice, channel: LineupEntry, isOnAir: Bool = false) -> some View {
        let entryColor = guideEntryColor(for: entry, onAir: isOnAir)
        Menu {

            // Genre color accent bar — matches the show block color in the cable guide
            Rectangle()
                .fill(entryColor.opacity(0.65))
                .frame(height: 5)

            // Info (disabled) ─────────────────────────────────────────────
            // Poster image (best-effort — NSMenu rendering of AsyncImage varies)
            if let urlStr = entry.ImageURL, !urlStr.isEmpty, let url = URL(string: urlStr) {
                AsyncImage(url: url) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 240, height: 135).clipped().cornerRadius(4)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(NSColor.separatorColor))
                        .frame(width: 240, height: 135)
                }
            }
            // Wrap info in a no-op Button so AppKit treats it as an enabled NSMenuItem
            // and renders at full brightness. Pure Text views are auto-disabled by AppKit
            // and drawn at ~50% opacity regardless of the foreground color set.
            Button(action: {}) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.Title)
                        .font(.title3).bold()
                        .foregroundColor(Color(NSColor.labelColor))
                    if let ep = episodeInfoLabel(entry) {
                        Text(ep)
                            .font(.subheadline)
                            .foregroundColor(Color(NSColor.secondaryLabelColor))
                    }
                    Text(timeRange(entry))
                        .font(.caption)
                        .foregroundColor(Color(NSColor.secondaryLabelColor))
                    if let syn = entry.Synopsis, !syn.isEmpty {
                        Text(syn).font(.caption).lineLimit(3)
                            .foregroundColor(Color(NSColor.labelColor))
                    }
                }
            }
            Divider()

            // Single ───────────────────────────────────────────────────────
            Button("Single — record once") {
                state.addShowFromGuide(entry: entry, type: .single, device: device, channel: channel)
            }

            Divider()

            // DateTime: repeats this same day + time on this channel
            Button {
                state.addShowFromGuide(entry: entry, type: .dateTime, device: device, channel: channel)
            } label: {
                VStack(alignment: .leading) {
                    Text("DateTime — same day & time")
                    Text("Repeats on \(weekdayName(entry.startDate))s at \(state.shortTime(entry.startDate)) on Channel \(channel.GuideNumber)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            // SeriesID Channel: any episode, this channel only
            Button {
                state.addShowFromGuide(entry: entry, type: .seriesChannel, device: device, channel: channel)
            } label: {
                VStack(alignment: .leading) {
                    Text("SeriesID — this channel")
                    Text("Any episode on Channel \(channel.GuideNumber)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            // SeriesID All: any episode, any channel
            Button {
                state.addShowFromGuide(entry: entry, type: .seriesAll, device: device, channel: channel)
            } label: {
                VStack(alignment: .leading) {
                    Text("SeriesID — all channels")
                    if let sid = entry.SeriesID {
                        Text("Matches \(sid) anywhere in the guide")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if state.config.Watch_in_VLC && isOnAir {
                Button(action: { state.watchInVLC(url: channel.URL ?? "") }) {
                    Text("Watch in VLC").foregroundColor(vlcOrange)
                }
            }
        } label: {
            Label {
                Text(entryLabel(entry, isOnAir: isOnAir))
            } icon: {
                Image(systemName: "square.fill")
                    .foregroundStyle(entryColor)
            }
        }
    }

    // MARK: ── Existing show menus ────────────────────────────────────────

    @ViewBuilder
    private func recordingMenu(_ show: Show) -> some View {
        let recNow       = Date()
        let recEntries   = state.guideEntries(deviceId: show.hdhr_record, channelNum: show.show_channel)
        let currentEntry = recEntries.first { $0.startDate <= recNow && $0.endDate > recNow }
        let recEp        = currentEntry.flatMap { episodeInfoLabel($0) }
        let menuTitle    = recEp.map { "🔴 \(show.show_title) · \($0)" } ?? "🔴 \(show.show_title)"
        // Bonus Time: sports shows record past the guide end — adjust the displayed end time
        let isSportsBonus = state.config.Sports_padding_enabled
                         && show.show_genre.lowercased().contains("sports")
        let bonusPadding  = isSportsBonus ? TimeInterval(state.config.Sports_padding_minutes * 60) : 0
        Menu(menuTitle) {
            let started      = show.show_next.date ?? recNow
            let guideEnd     = show.show_end.date  ?? recNow
            let ends         = guideEnd.addingTimeInterval(bonusPadding)
            let inBonusTime  = isSportsBonus && recNow > guideEnd

            showInfoHeader(show, entry: currentEntry)
            Divider()
            menuInfo("Channel \(show.show_channel) · \(show.state.rawValue) · tuner \(show.hdhr_record)", font: .footnote, secondary: true)
            menuInfo("\(elapsedLabel(since: started)) elapsed · \(remainingLabel(until: ends)) left", font: .footnote, secondary: true)
            if inBonusTime {
                menuInfo("🏈 Bonus Time (+\(state.config.Sports_padding_minutes) min)", font: .footnote, secondary: true)
            }
            if let sig = state.tunerStatus[show.show_id] {
                menuInfo(sig.displayString, font: .footnote, secondary: true)
            }
            Divider()
            Button("Stop Recording", role: .destructive) {
                let alert = NSAlert()
                alert.messageText     = "Stop recording \"\(show.show_title)\"?"
                alert.informativeText = "This deactivates the show. Use \"Skip This Airing\" to skip without deactivating."
                alert.addButton(withTitle: "Stop & Deactivate")
                alert.addButton(withTitle: "Keep Recording")
                alert.alertStyle = .warning
                if alert.runModal() == .alertFirstButtonReturn {
                    state.stopRecording(showId: show.show_id)
                }
            }
            Button("Skip This Airing") { Task { await state.skipRecording(showId: show.show_id) } }
            if !show.show_recording_path.isEmpty {
                Button("Show Recording in Finder") {
                    NSWorkspace.shared.selectFile(show.show_recording_path,
                                                  inFileViewerRootedAtPath: "")
                }
            }
            if state.config.Watch_in_VLC {
                Button(action: { state.watchInVLC(url: show.show_url, transcode: show.show_transcode) }) {
                    Text("Watch in VLC").foregroundColor(vlcOrange)
                }
            }
            Button("Edit…") { editShow(show) }
        }
    }

    @ViewBuilder
    private func scheduledMenu(_ show: Show) -> some View {
        let schNext    = show.show_next.date ?? .distantFuture
        let schEntries = state.guideEntries(deviceId: show.hdhr_record, channelNum: show.show_channel)
        let schEp      = schEntries.first { abs($0.startDate.timeIntervalSince(schNext)) < 5 * 60 }
                                   .flatMap { episodeInfoLabel($0) }
        let conflict   = state.hasConflict(for: show)
        let prefix     = conflict ? "⚠️ " : ""
        let schLabel   = schEp.map { "\(prefix)\(stateIcon(show)) \(show.show_title) · \($0)" }
                      ?? "\(prefix)\(stateIcon(show)) \(show.show_title)"
        Menu(schLabel) {
            let now    = Date()
            let next   = show.show_next.date ?? .distantFuture
            let ends   = show.show_end.date  ?? .distantFuture

            // Item 5: look up the guide entry at the scheduled time so we can display episode
            // title/number — this is a sync read from the in-memory guide cache
            let guideEntries = state.guideEntries(deviceId: show.hdhr_record, channelNum: show.show_channel)
            let scheduledEntry = guideEntries.first {
                // Match the entry whose start time is within 5 minutes of show_next
                abs($0.startDate.timeIntervalSince(next)) < 5 * 60
            }

            showInfoHeader(show, entry: scheduledEntry)
            Divider()

            // Type + channel
            menuInfo("\(show.state.rawValue) · Channel \(show.show_channel)", font: .footnote)
            if conflict {
                menuInfo("⚠️ Conflict — all tuners busy at this time", font: .footnote, secondary: true)
            }

            // Timing: starts in / ended
            if next > now {
                menuInfo("In \(relativeLabel(next.timeIntervalSince(now))) · \(show.show_length) min", font: .footnote, secondary: true)
            } else if ends > now {
                menuInfo("Started \(relativeLabel(now.timeIntervalSince(next))) ago · \(remainingLabel(until: ends)) left", font: .footnote, secondary: true)
            }

            // Upcoming recording slots — source depends on show type
            let upcoming: [(channel: String, date: Date)] = {
                switch show.state {
                case .single:
                    if let d = show.show_next.date { return [(show.show_channel, d)] }
                    return []
                case .dateTime:
                    return nextDateTimeOccurrences(for: show, count: 3).map { (show.show_channel, $0) }
                case .seriesChannel, .seriesAll:
                    return state.upcomingGuideEpisodes(seriesID: show.show_seriesid, limit: 3)
                        .map { ($0.channel, $0.entry.startDate) }
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
            Button("Deactivate") { state.toggleActive(show) }
            Button("Delete…", role: .destructive) {
                let alert = NSAlert()
                alert.messageText     = "Delete \"\(show.show_title)\"?"
                alert.informativeText = "This cannot be undone."
                alert.addButton(withTitle: "Delete")
                alert.addButton(withTitle: "Cancel")
                alert.alertStyle = .warning
                if alert.runModal() == .alertFirstButtonReturn { state.deleteShow(show) }
            }
        }
    }

    @ViewBuilder
    private func pausedMenu(_ show: Show) -> some View {
        Menu("⏸ \(show.show_title)") {
            let pausedEntries = state.guideEntries(deviceId: show.hdhr_record, channelNum: show.show_channel)
            let pausedEntry   = pausedEntries.first {
                abs($0.startDate.timeIntervalSince(show.show_next.date ?? .distantPast)) < 5 * 60
            }
            showInfoHeader(show, entry: pausedEntry)
            Divider()
            menuInfo("\(show.state.rawValue) · Channel \(show.show_channel)", font: .footnote, secondary: true)
            if !show.show_fail_reason.isEmpty {
                menuInfo("Last error: \(show.show_fail_reason)", font: .footnote, secondary: true)
            }
            Divider()
            Button("Activate")  { state.toggleActive(show) }
            Button("Edit…")     { editShow(show) }
            Button("Delete…", role: .destructive) {
                let alert = NSAlert()
                alert.messageText     = "Delete \"\(show.show_title)\"?"
                alert.informativeText = "This cannot be undone."
                alert.addButton(withTitle: "Delete")
                alert.addButton(withTitle: "Cancel")
                alert.alertStyle = .warning
                if alert.runModal() == .alertFirstButtonReturn { state.deleteShow(show) }
            }
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

    // Next N weekday+time occurrences for a DateTime show, computed from show_air_date / show_time.
    // AppState.nextDateTime(for:) has no after: parameter so we derive occurrences locally.
    private func nextDateTimeOccurrences(for show: Show, count: Int) -> [Date] {
        let cal = Calendar.current
        let now = Date()
        let dayNames = ["sunday","monday","tuesday","wednesday","thursday","friday","saturday"]
        let airIndices = show.show_air_date.compactMap { dayNames.firstIndex(of: $0.lowercased()) }
        let hours = Int(show.show_time)
        let minutes = Int((show.show_time - Double(hours)) * 60)
        var results: [Date] = []
        var check = now
        guard let limit = cal.date(byAdding: .day, value: 60, to: now) else { return [] }
        while results.count < count && check < limit {
            let idx = cal.component(.weekday, from: check) - 1  // 0 = Sunday
            if airIndices.contains(idx) {
                var c = cal.dateComponents([.year, .month, .day], from: check)
                c.hour = hours; c.minute = minutes
                if let d = cal.date(from: c), d > now { results.append(d) }
            }
            check = cal.date(byAdding: .day, value: 1, to: check) ?? check
        }
        return results
    }

    // Shared show-info panel used by recordingMenu, scheduledMenu, and pausedMenu.
    // Renders poster (520×292), title, episode info, and synopsis in a consistent layout.
    @ViewBuilder
    private func showInfoHeader(_ show: Show, entry: GuideEntry?) -> some View {
        if !show.show_logo_url.isEmpty, let url = URL(string: show.show_logo_url) {
            AsyncImage(url: url) { img in
                img.resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 520, height: 292).clipped().cornerRadius(6)
            } placeholder: {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(NSColor.separatorColor))
                    .frame(width: 520, height: 292)
            }
        }
        menuInfo(show.show_title, font: .title3)
        if let ep = entry.flatMap({ episodeInfoLabel($0) }) {
            menuInfo(ep, font: .callout)
        }
        if let syn = entry?.Synopsis, !syn.isEmpty {
            menuInfo(syn, font: .callout, maxWidth: 520)
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

    // "▶ 8:00 PM  Jeopardy! (30 min)" or "8:00 PM  Jeopardy! (30 min)"
    private func entryLabel(_ entry: GuideEntry, isOnAir: Bool = false) -> String {
        let prefix = isOnAir ? "▶ " : ""
        return "\(prefix)\(Self.timeFormatter.string(from: entry.startDate))  \(entry.Title) (\(entry.durationMinutes)m)"
    }

    // "8:00 PM – 8:30 PM"
    private func timeRange(_ entry: GuideEntry) -> String {
        return "\(Self.timeFormatter.string(from: entry.startDate)) – \(Self.timeFormatter.string(from: entry.endDate))"
    }

    private func weekdayName(_ date: Date) -> String {
        return Self.weekdayFormatter.string(from: date)
    }

    private func episodeInfoLabel(_ entry: GuideEntry) -> String? {
        let parts = [entry.EpisodeNumber, entry.EpisodeTitle]
            .compactMap { s -> String? in
                guard let s, !s.isEmpty else { return nil }
                return s
            }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }
}

