import SwiftUI
import AppKit

private let vlcOrange   = Color(red: 1.0, green: 0.482, blue: 0.0)
private let watchNowBlue = Color(red: 0.2, green: 0.6, blue: 1.0)

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
        let pausedShows    = state.pausedShows

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

        if !slotShows.isEmpty {
            Section("Next Up") {
                ForEach(slotShows) { show in
                    if let next = show.show_next.date {
                        menuInfo("\(Self.timeFormatter.string(from: next)) · \(show.show_length) min", font: .caption, secondary: true)
                    }
                    scheduledMenu(show)
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
                Section("Paused") {
                    ForEach(pausedShows) { show in pausedMenu(show) }
                }
            }
        }
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
        let loading  = state.isGuideLoading(for: device.DeviceID)
        // Only build submenus for channels that have cached guide entries — avoids constructing
        // empty Menu views for 30-50 channels with no guide data, which SwiftUI evaluates eagerly.
        let populated = channels.filter {
            !(state.menuGuideEntries["\(device.DeviceID):\($0.GuideNumber)"] ?? []).isEmpty
        }
        // Amber accent bar (comedy/warm hue from the guide genre palette) marks the channel-list depth
        Rectangle()
            .fill(Color(hue: 0.13, saturation: 0.75, brightness: 0.90).opacity(0.65))
            .frame(height: 5)
        if channels.isEmpty {
            Text("No channels — try Refresh Guide").foregroundStyle(.secondary)
        } else if populated.isEmpty {
            if loading {
                Text("Fetching guide…").foregroundStyle(.secondary)
            } else {
                Text("No upcoming shows").foregroundStyle(.secondary)
                Button("Load guide") { state.ensureGuideLoaded(for: device.DeviceID) }
            }
        } else {
            let sorted = populated.sorted { a, b in
                if a.isFavorite != b.isFavorite { return a.isFavorite }
                return a.GuideNumber.channelSortKey < b.GuideNumber.channelSortKey
            }
            ForEach(sorted, id: \.GuideNumber) { ch in
                channelMenu(device: device, channel: ch)
            }
        }
    }

    // MARK: ── Level 3 (or 4): Guide entries for a channel ───────────────
    // Each entry is a flat Button (not a nested Menu) — avoids eager evaluation of
    // per-entry submenus for all ~100 channels when the channel list opens.

    @ViewBuilder
    private func channelMenu(device: HDHRDevice, channel: LineupEntry) -> some View {
        let entries  = state.menuGuideEntries["\(device.DeviceID):\(channel.GuideNumber)"] ?? []
        let loading  = state.isGuideLoading(for: device.DeviceID)
        let now      = Date()
        let onAir    = entries.filter { $0.startDate <= now && $0.endDate > now }
        let upcoming = entries.filter { $0.startDate > now }
        let hdBadge  = channel.HD == 1 ? " HD" : ""
        let star     = channel.isFavorite ? " ★" : ""
        let chLabel  = "\(channel.GuideNumber)  \(channel.GuideName)\(hdBadge)\(star)"
        let logoImage = state.channelImageURLs["\(device.DeviceID):\(channel.GuideNumber)"]
                            .flatMap { state.channelIconImages[$0] }

        Menu {
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
            Divider()
            Button("Browse channel in guide…") {
                state.pendingAddChannel = (device, channel)
                state.pendingAddChannelGeneration += 1
                open("add-show")
            }
        } label: {
            Label {
                Text(chLabel)
            } icon: {
                if let logoImage {
                    Image(nsImage: logoImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "tv")
                        .frame(width: 16, height: 16)
                }
            }
        }
    }

    // "8:00 PM  Jeopardy! (30 min)" / "🔴 8:00 PM  Jeopardy! (30 min)"
    private func entryLabel(_ entry: GuideEntry, isOnAir: Bool) -> String {
        let prefix = isOnAir ? "▶ " : ""
        return "\(prefix)\(Self.timeFormatter.string(from: entry.startDate))  \(entry.Title)"
    }

    @ViewBuilder
    private func entryMenu(entry: GuideEntry, device: HDHRDevice, channel: LineupEntry, isOnAir: Bool) -> some View {
        let entryColor = guideEntryColor(for: entry, onAir: isOnAir)
        Menu {
            Rectangle()
                .fill(entryColor.opacity(0.65))
                .frame(height: 5)
            menuInfo(entry.Title, font: .title3, maxWidth: 240)
            if let ep = episodeInfoLabel(entry) {
                menuInfo(ep, font: .callout, maxWidth: 240)
            }
            menuInfo(timeRange(entry), font: .caption, maxWidth: 240)
            if let syn = entry.Synopsis, !syn.isEmpty {
                menuInfo(truncateSynopsis(syn, limit: 120), font: .callout, maxWidth: 240)
            }
            Divider()
            if let existing = managedShow(for: entry) {
                Button("Edit Show…") { editShow(existing) }
            } else {
                Button {
                    state.pendingAddEntry = (device, channel, entry)
                    state.pendingAddEntryGeneration += 1
                    open("add-show")
                } label: {
                    Label { Text("Record…").foregroundColor(.red) }
                          icon: { Image(systemName: "record.circle").foregroundColor(.red) }
                }
            }
            if state.config.Watch_in_VLC && isOnAir {
                Button(action: { state.watchInVLC(url: channel.URL ?? "", deviceId: device.DeviceID) }) {
                    Label { Text("Watch in VLC").foregroundColor(vlcOrange) }
                          icon: { Image(systemName: "arrow.up.forward.app").foregroundColor(vlcOrange) }
                }
            }
            if VLCBridge.shared.isAvailable && isOnAir {
                Button(action: { state.watchInApp(url: channel.URL ?? "", title: entry.Title, deviceId: device.DeviceID) }) {
                    Label { Text("Watch Now!").foregroundColor(watchNowBlue) }
                          icon: { Image(systemName: "play.tv.fill").foregroundColor(watchNowBlue) }
                }
            }
        } label: {
            Text(entryLabel(entry, isOnAir: isOnAir))
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
        let isSportsBonus = state.config.Sports_padding_enabled && show.show_bonus_time
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
                alert.informativeText = "This pauses the show. Use \"Skip This Airing\" to skip to the next airing instead."
                alert.addButton(withTitle: "Stop & Pause")
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
    private func scheduledMenu(_ show: Show) -> some View {
        // Pre-computed in AppState.rebuildMenuEntries() every idle tick and after guide loads —
        // avoids O(series entries) scan per show per menu open.
        let conflict = state.conflictingShowIDs.contains(show.show_id)
        let prefix   = conflict ? "⚠️ " : ""
        let schEntry = state.menuScheduledEntry[show.show_id]
        let schEp    = schEntry.flatMap { episodeInfoLabel($0) }
        let schLabel = schEp.map { "\(prefix)\(stateIcon(show)) \(show.show_title) · \($0)" }
                   ?? "\(prefix)\(stateIcon(show)) \(show.show_title)"

        Menu(schLabel) {
            let now  = Date()
            let next = show.show_next.date ?? .distantFuture
            let ends = show.show_end.date  ?? .distantFuture

            showInfoHeader(show, entry: schEntry)
            Divider()

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
                menuInfo("Reason: \(show.show_fail_reason)", font: .footnote, secondary: true)
            }
            if let next = show.show_next.date, next > Date() {
                menuInfo("Next attempt: \(Self.timeFormatter.string(from: next))", font: .footnote, secondary: true)
            }
            Divider()
            Button("Resume Now") { state.resumeShow(show) }
            Button("Edit…") { editShow(show) }
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

    private func managedShow(for entry: GuideEntry) -> Show? {
        if let sid = entry.SeriesID, !sid.isEmpty {
            return state.managedShowBySeriesID[sid]
        }
        return state.managedShowByTitle[entry.Title]
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
        }
        menuInfo(show.show_title, font: .title3, maxWidth: 460)
        if let ep = entry.flatMap({ episodeInfoLabel($0) }) {
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

    private func episodeInfoLabel(_ entry: GuideEntry) -> String? {
        let parts = [entry.EpisodeNumber, entry.EpisodeTitle]
            .compactMap { s -> String? in
                guard let s, !s.isEmpty else { return nil }
                return s
            }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }
}

