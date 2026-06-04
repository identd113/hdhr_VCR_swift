import SwiftUI

// Multi-step wizard: Device → Channel → Guide entry → Details → Save
struct AddShowView: View {

    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    @Environment(\.openWindow) private var openWindow

    enum Step { case device, guide, details }

    @State private var step: Step = .guide
    @State private var show = Show.blank()   // transcode overridden in onAppear

    // Step 1
    @State private var selectedDevice: HDHRDevice? = nil
    // Step 2 — cable guide
    @State private var allChannels:    [GuideChannel] = []
    @State private var selectedChannel: LineupEntry?  = nil
    @State private var selectedEntry: GuideEntry? = nil
    @State private var isLoadingGuide = false
    @State private var refreshToken = UUID()
    @State private var snapToNow   = false
    @State private var genreFilter: String? = nil

    private var taskId: String { "\(selectedDevice?.DeviceID ?? ""):\(refreshToken)" }

    // Genres extracted from loaded guide channels, sorted A-Z
    private var availableGenres: [String] {
        var seen = Set<String>()
        return allChannels.flatMap { $0.Guide ?? [] }
            .compactMap { $0.firstGenre }
            .filter { seen.insert($0.lowercased()).inserted }
            .sorted()
    }

    // Step 3
    @State private var seriesType: ShowState = .single
    @State private var airDays: Set<String> = []
    @State private var recordFolder: URL? = {
        let stored = UserDefaults.standard.string(forKey: "defaultSaveDirectory") ?? ""
        if !stored.isEmpty { return URL(fileURLWithPath: stored) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/hdhr_videos")
    }()


    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Progress indicator
            HStack(spacing: 4) {
                ForEach([Step.guide, .details], id: \.self) { s in
                    Circle().fill(s == step ? Color.accentColor : .secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel({
                switch step {
                case .device:  return "Select tuner"
                case .guide:   return "Step 1 of 2: Guide"
                case .details: return "Step 2 of 2: Details"
                }
            }())
            .padding(.horizontal).padding(.top, 12)

            Divider().padding(.top, 8)

            // Step content
            Group {
                switch step {
                case .device:  deviceStep
                case .guide:   guideStep
                case .details: detailsStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomTrailing) {
                if step == .details && show.show_bonus_time && state.config.Sports_padding_enabled {
                    StarburstBadge(minutes: state.config.Sports_padding_minutes, size: 115)
                        .padding(.trailing, 12).padding(.bottom, 12)
                        .transition(.asymmetric(
                            insertion: .identity,
                            removal: .scale(scale: 0.05).combined(with: .opacity)
                        ))
                }
            }

            if step != .guide {
                Divider()
                navBar
            }
        }
        .frame(
            minWidth: step == .guide ? 1100 : 560,
            idealWidth: step == .guide ? 1280 : 560,
            maxWidth: step == .guide ? .infinity : 560,
            minHeight: step == .guide ? 720 : 540,
            idealHeight: step == .guide ? 820 : 540,
            maxHeight: step == .guide ? .infinity : 540
        )
        .animation(.easeInOut(duration: 0.2), value: step)
        .onExitCommand { dismiss() }
        .onAppear {
            show.show_transcode = state.config.Default_transcode
            if let pending = state.pendingAddEntry {
                applyPendingEntry(pending)
            } else if let pending = state.pendingAddChannel {
                applyPendingChannel(pending)
            } else {
                if selectedDevice == nil { selectedDevice = state.devices.first }
                step = .guide
            }
        }
    }

    // MARK: - Steps

    private var deviceStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Select Tuner").font(.title2)
                Spacer()
                Button { Task { await state.discoverDevices() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .padding()
            if state.devices.isEmpty {
                EmptyStateView(title: "No tuners found", systemImage: "wifi.slash",
                               description: "Make sure your HDHomeRun is on the network.")
            } else {
                List(state.devices, selection: $selectedDevice) { device in
                    let activeRecordings = state.recordingShows.filter { $0.hdhr_record == device.DeviceID }.count
                    let channelCount = state.lineups[device.DeviceID]?.count ?? 0
                    HStack {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(device.DeviceID).bold()
                                Spacer()
                                if activeRecordings > 0 {
                                    Text("Recording \(activeRecordings)")
                                        .font(.caption).bold()
                                        .foregroundStyle(.red)
                                }
                            }
                            HStack(spacing: 6) {
                                Text(device.LocalIP)
                                if let tc = device.TunerCount { Text("· \(tc) tuners") }
                                if channelCount > 0 { Text("· \(channelCount) channels") }
                                if let fw = device.FirmwareVersion { Text("· fw \(fw)") }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .tag(device)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedDevice = device }
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        selectedDevice = device
                        goForward()
                    })
                }
            }
        }
    }

    private var guideStep: some View {
        let seriesIDShows    = state.shows.filter { $0.isSeries }
        let managedSeriesIDs = Set(seriesIDShows.compactMap { $0.show_seriesid.isEmpty ? nil : $0.show_seriesid })
        let managedTitles    = Set(seriesIDShows.map { $0.show_title })
        // Single shows: yellow on the one exact scheduled slot
        let managedSingleSlotKeys: Set<String> = Set(state.shows.compactMap { show in
            guard show.state == .single, let next = show.show_next else { return nil }
            return "\(show.hdhr_record):\(show.show_channel):\(Int(next.timeIntervalSince1970))"
        })
        // DateTime shows: yellow on every airing of that title on that channel
        let managedDateTimeTitleCh: Set<String> = Set(state.shows
            .filter { $0.state == .dateTime }
            .map { "\($0.show_title)|\($0.show_channel)" })
        // Recording now
        let recordingSeriesIDs = Set(state.recordingShows.compactMap { $0.show_seriesid.isEmpty ? nil : $0.show_seriesid })
        let recordingTitles    = Set(state.recordingShows.map { $0.show_title })
        // Next up: active shows whose next air is within 30 min (matches menu bar orange-clock threshold)
        let now30 = Date()
        let nextUpShows = state.activeShows.filter {
            guard let d = $0.show_next else { return false }
            return d > now30 && d.timeIntervalSince(now30) <= 30 * 60
        }
        let nextUpSeriesIDs = Set(nextUpShows.compactMap { $0.show_seriesid.isEmpty ? nil : $0.show_seriesid })
        let nextUpTitles    = Set(nextUpShows.map { $0.show_title })
        // Bonus Time: find managed shows with per-show bonus time enabled so the guide can draw the overtime dotted box
        let bonusShows = state.shows.filter { $0.show_bonus_time }
        let bonusSeriesIDs = Set(bonusShows.compactMap { $0.show_seriesid.isEmpty ? nil : $0.show_seriesid })
        let bonusTitles    = Set(bonusShows.map { $0.show_title })

        return VStack(spacing: 0) {
            // ── Compact toolbar: tuner + genre filter + actions ───────────────
            HStack(spacing: 10) {
                if state.devices.count > 1 {
                    Menu { ForEach(state.devices) { tunerMenuItem($0) } } label: { tunerMenuButton }
                        .frame(maxWidth: 220)
                }

                if !availableGenres.isEmpty {
                    Text("Genre:").foregroundStyle(.secondary).fixedSize()
                    Picker("", selection: $genreFilter) {
                        Text("All").tag(String?.none)
                        ForEach(availableGenres, id: \.self) { g in
                            Text(g).tag(Optional(g))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 160)
                }

                Spacer()

                if isLoadingGuide { ProgressView().scaleEffect(0.7) }
                Button { snapToNow = true } label: {
                    Label("Now", systemImage: "clock.arrow.circlepath")
                }
                Button {
                    if let id = selectedDevice?.DeviceID {
                        state.guideStore.invalidate(deviceId: id)
                    }
                    refreshToken = UUID()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoadingGuide)
                // Pop-out: open or focus the floating guide, then close the wizard
                Button {
                    if let existing = NSApp.windows.first(where: { $0.title == "Cable Guide" }) {
                        existing.makeKeyAndOrderFront(nil)
                    } else {
                        openWindow(id: "cable-guide")
                    }
                    dismiss()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .accessibilityLabel("Open guide in floating window")
                }
                .help("Open guide in floating window")
                Text("[\(allChannels.count) ch]").font(.caption2).foregroundStyle(.orange)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)

            Divider()

            // ── Summary (top 1/3) + Guide grid (bottom 2/3) ──────────────────
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    summaryPanel
                        .frame(height: proxy.size.height / 3)
                        .clipped()

                    Divider()

                    if allChannels.isEmpty && !isLoadingGuide {
                        EmptyStateView(title: "No guide data", systemImage: "tv.slash",
                                   description: "Guide data unavailable — tap Refresh to retry.")
                    } else {
                        CableGuideView(
                            allChannels:        allChannels,
                            lineup:             state.lineups[selectedDevice?.DeviceID ?? ""] ?? [],
                            guideHours:         state.config.GuideHours,
                            selectedEntry:      $selectedEntry,
                            selectedChannel:    $selectedChannel,
                            snapToNow:          $snapToNow,
                            deviceId:                selectedDevice?.DeviceID ?? "",
                            managedSeriesIDs:        managedSeriesIDs,
                            managedTitles:           managedTitles,
                            managedSingleSlotKeys:   managedSingleSlotKeys,
                            managedDateTimeTitleCh:  managedDateTimeTitleCh,
                            recordingSeriesIDs: recordingSeriesIDs,
                            recordingTitles:    recordingTitles,
                            nextUpSeriesIDs:    nextUpSeriesIDs,
                            nextUpTitles:       nextUpTitles,
                            bonusSeriesIDs:     bonusSeriesIDs,
                            bonusTitles:        bonusTitles,
                            bonusMinutes:       state.config.Sports_padding_minutes,
                            genreFilter:        genreFilter,
                            onConfirm: {
                                applyGuideEntry()
                                step = .details
                            },
                            onToggleFavorite: { lu in
                                guard let device = selectedDevice else { return }
                                state.toggleFavorite(device: device, channel: lu)
                            }
                        )
                    }
                }
            }
        }
        .task(id: taskId) { await loadAllGuide() }
        .onChange(of: selectedDevice) { _, newDevice in
            // Force fresh guide data whenever the user switches tuners.
            // Lineups are stable (loaded during discovery) — don't clear them or
            // CableGuideView gets an empty lineup and the Record button stays disabled.
            guard let id = newDevice?.DeviceID else { return }
            state.guideStore.invalidate(deviceId: id)
            allChannels = []
            refreshToken = UUID()
            genreFilter = nil   // new device has different genres — stale filter is misleading
        }
        .onChange(of: state.guideRevision) { _, _ in
            guard let id = selectedDevice?.DeviceID, allChannels.isEmpty else { return }
            let ch = state.guideStore.channels(deviceId: id)
            guard !ch.isEmpty else { return }
            state.logGuide("[Wizard] guideRevision fired — \(ch.count) channels pulled into view")
            allChannels = ch
            isLoadingGuide = false
        }
        .onChange(of: state.lineups[selectedDevice?.DeviceID ?? ""] ?? []) { _, _ in
            guard let id = selectedDevice?.DeviceID, !allChannels.isEmpty else { return }
            allChannels = sortedGuideChannels(allChannels, favorites: Set((state.lineups[id] ?? []).filter(\.isFavorite).map(\.GuideNumber)))
        }
        .onChange(of: allChannels.count) { _, count in
            guard count > 0, selectedEntry == nil else { return }
            let now = Date()
            guard let firstCh = allChannels.first,
                  let entry = firstCh.Guide?.first(where: { $0.startDate <= now && $0.endDate > now })
            else { return }
            selectedEntry   = entry
            selectedChannel = (state.lineups[selectedDevice?.DeviceID ?? ""] ?? [])
                .first(where: { $0.GuideNumber == firstCh.GuideNumber })
        }
        .onChange(of: state.pendingAddEntryGeneration) { _, _ in
            // Fired when the user taps "Record…" from the menu while the window is already open.
            if let pending = state.pendingAddEntry { applyPendingEntry(pending) }
        }
        .onChange(of: state.pendingAddChannelGeneration) { _, _ in
            // Fired when the user taps a channel in the menu cascade while the window is already open.
            if let pending = state.pendingAddChannel { applyPendingChannel(pending) }
        }
    }

    // ── Summary panel ─────────────────────────────────────────────────────────

    @ViewBuilder
    private var summaryPanel: some View {
        if let entry = selectedEntry {
            let onAir  = entry.startDate <= Date() && entry.endDate > Date()
            let bgColor = guideEntryColor(for: entry, onAir: onAir)
            let channelIcon = allChannels.first(where: { $0.GuideNumber == selectedChannel?.GuideNumber })?.ImageURL
            let isRecordingNow = state.recordingShows.contains { show in
                show.show_channel == selectedChannel?.GuideNumber &&
                (show.show_next ?? .distantFuture) <= Date() &&
                (show.show_end  ?? .distantPast)   >  Date()
            }
            let isSportsBonusEntry = entry.firstGenre?.lowercased().contains("sports") == true
                                  && state.config.Sports_padding_enabled
            let isManaged: Bool = {
                if let sid = entry.SeriesID, !sid.isEmpty {
                    return state.shows.contains { $0.show_seriesid == sid }
                }
                return state.shows.contains { $0.show_title == entry.Title }
            }()

            ZStack(alignment: .topTrailing) {
            HStack(alignment: .top, spacing: 16) {
                // Poster image — fixed width, fills panel height dynamically
                if let urlStr = entry.ImageURL, !urlStr.isEmpty, let url = URL(string: urlStr) {
                    AsyncImage(url: url) { img in
                        img.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Color.white.opacity(0.2)
                    }
                    .accessibilityLabel("\(entry.Title) poster")
                    .frame(width: 180)
                    .frame(maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(alignment: .topTrailing) { if isManaged { ManagedFlagView() } }
                } else {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.white.opacity(0.2))
                        .frame(width: 180)
                        .frame(maxHeight: .infinity)
                        .overlay(alignment: .topTrailing) { if isManaged { ManagedFlagView() } }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.Title)
                        .font(.title3).bold()
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.4), radius: 1, x: 0, y: 1)
                    if isRecordingNow {
                        Label("Recording Now", systemImage: "record.circle.fill")
                            .font(.caption).bold()
                            .foregroundColor(.red)
                    }

                    // Genre badge — skip the generic "Series" tag since it adds nothing;
                    // shown for meaningful genres like Sports, Drama, Comedy
                    if let genre = entry.firstGenre, genre.lowercased() != "series" {
                        Text(genre.uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.white.opacity(0.20))
                            .cornerRadius(3)
                            .foregroundColor(.white.opacity(0.90))
                            .shadow(color: .black.opacity(0.35), radius: 1.5, x: 0, y: 1)
                    }

                    if let ep = entry.episodeInfoLabel {
                        // Full white + shadow so episode info reads clearly on all genre colors
                        Text(ep)
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .shadow(color: .black.opacity(0.35), radius: 1.5, x: 0, y: 1)
                    }

                    // Original air date — present on most episodes; lets the user distinguish
                    // first-runs from repeats without needing to know the episode number
                    if let airdate = entry.OriginalAirdate {
                        Text("Orig. \(origAirdateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(airdate))))")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.80))
                            .shadow(color: .black.opacity(0.35), radius: 1.5, x: 0, y: 1)
                    }

                    if let syn = entry.Synopsis, !syn.isEmpty {
                        // Full white + shadow so synopsis is legible on both dark and light genre backgrounds
                        Text(syn)
                            .font(.callout)
                            .foregroundColor(.white)
                            .lineLimit(3)
                            .shadow(color: .black.opacity(0.35), radius: 1.5, x: 0, y: 1)
                    }
                    // Upcoming airings for series shows
                    if let sid = entry.SeriesID, !sid.isEmpty {
                        let upcoming = state.upcomingGuideEpisodes(seriesID: sid)
                        if !upcoming.isEmpty {
                                let labels = upcoming.map { "Channel \($0.channel) \(upcomingFormatter.string(from: $0.entry.startDate))" }
                            Text(labels.joined(separator: "  ·  "))
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.85))
                                .lineLimit(2)
                                .shadow(color: .black.opacity(0.35), radius: 1.5, x: 0, y: 1)
                        }
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 8) {
                        ChannelIcon(urlString: channelIcon, size: 52)
                        Text("Channel \(selectedChannel?.GuideNumber ?? "?")  ·  \(guideTimeRange(entry))")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.85))
                            .shadow(color: .black.opacity(0.35), radius: 1.5, x: 0, y: 1)
                        Spacer()
                        if onAir,
                           state.config.Watch_in_VLC,
                           FileManager.default.fileExists(atPath: "/Applications/VLC.app") {
                            Button {
                                state.watchInVLC(url: selectedChannel?.URL ?? "", deviceId: selectedDevice?.DeviceID)
                            } label: {
                                Label {
                                    Text("Watch in VLC")
                                } icon: {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: "/Applications/VLC.app"))
                                        .resizable().scaledToFit().frame(width: 16, height: 16)
                                        .accessibilityHidden(true)
                                }
                            }
                            .buttonStyle(WhiteOutlineButtonStyle(borderColor: Color(red: 1.0, green: 0.482, blue: 0.0)))
                            .disabled(selectedChannel == nil)
                        }
                        if onAir, VLCBridge.shared.isAvailable {
                            Button {
                                state.watchInApp(url: selectedChannel?.URL ?? "",
                                                 title: selectedEntry?.Title ?? "Live TV",
                                                 deviceId: selectedDevice?.DeviceID)
                            } label: {
                                Label("Watch Now!", systemImage: "play.tv.fill")
                            }
                            .buttonStyle(WhiteOutlineButtonStyle(borderColor: .blue))
                            .disabled(selectedChannel == nil)
                        }
                        let managedShow: Show? = {
                            guard let entry = selectedEntry else { return nil }
                            if let sid = entry.SeriesID, !sid.isEmpty {
                                return state.shows.first { $0.show_seriesid == sid }
                            }
                            return state.shows.first { $0.show_title == entry.Title }
                        }()
                        let isManaged = managedShow != nil
                        Button {
                            if let existing = managedShow {
                                state.editingShowId = existing.show_id
                                openWindow(id: "edit-show")
                            } else {
                                applyGuideEntry()
                                step = .details
                            }
                        } label: {
                            if isManaged {
                                Label("Edit Show", systemImage: "pencil")
                            } else {
                                Label("Record", systemImage: "record.circle.fill")
                            }
                        }
                        .buttonStyle(WhiteOutlineButtonStyle(borderColor: isManaged ? .blue : .red))
                        .disabled(!isManaged && selectedChannel == nil)
                        .frame(minWidth: 90)
                    }
                    // Overlap warning: shown when this show's start falls inside another show's bonus-time extension.
                    // Always rendered (opacity 0 when absent) so the button row above stays at a fixed vertical position.
                    let overlapWarning: String? = {
                        guard let device = selectedDevice, let ch = selectedChannel else { return nil }
                        return state.bonusOverlapWarning(for: entry, channel: ch, deviceId: device.DeviceID)
                    }()
                    Text(overlapWarning ?? " ")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.90))
                        .padding(.horizontal, 4)
                        .opacity(overlapWarning != nil ? 1 : 0)
                }
                // Dark gradient scrim behind the text column improves contrast on light genre
                // backgrounds (amber comedy, green sports) without changing the background color
                .background(
                    LinearGradient(
                        gradient: Gradient(colors: [Color.black.opacity(0.28), Color.black.opacity(0.04)]),
                        startPoint: .leading, endPoint: .trailing
                    )
                    .cornerRadius(8)
                    .blendMode(.multiply)
                )
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(bgColor.opacity(0.90))
            .cornerRadius(10)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            if isSportsBonusEntry {
                StarburstBadge(minutes: state.config.Sports_padding_minutes, size: 100)
                    .padding(.trailing, 18).padding(.top, 8)
            }
            } // ZStack
        } else {
            Text("Select a show from the grid")
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Tuner menu helpers

    @ViewBuilder
    private func tunerMenuItem(_ device: HDHRDevice) -> some View {
        let recCount = state.recordingShows.filter { $0.hdhr_record == device.DeviceID }.count
        Button {
            if selectedDevice?.DeviceID != device.DeviceID { selectedDevice = device }
        } label: {
            Label(tunerMenuItemLabel(device),
                  systemImage: recCount > 0 ? "record.circle.fill" : "antenna.radiowaves.left.and.right")
        }
    }

    private var tunerMenuButton: some View {
        let recCount = selectedDevice.map { d in
            state.recordingShows.filter { $0.hdhr_record == d.DeviceID }.count
        } ?? 0
        return Label(selectedDevice?.DeviceID ?? "No Tuner",
                     systemImage: recCount > 0 ? "record.circle.fill" : "antenna.radiowaves.left.and.right")
    }

    private func tunerMenuItemLabel(_ device: HDHRDevice) -> String {
        let recCount = state.recordingShows.filter { $0.hdhr_record == device.DeviceID }.count
        let chCount  = state.lineups[device.DeviceID]?.count ?? 0
        var parts    = [device.DeviceID, device.LocalIP]
        if let tc = device.TunerCount { parts.append("\(tc) tuner\(tc == 1 ? "" : "s")") }
        if chCount  > 0 { parts.append("\(chCount) ch") }
        if recCount > 0 { parts.append("\(recCount) recording\(recCount == 1 ? "" : "s")") }
        if let fw = device.FirmwareVersion { parts.append("fw \(fw)") }
        return parts.joined(separator: "  ·  ")
    }

    private var detailsStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Recording Details").font(.title2)

                ShowFormSection(
                    show: $show,
                    seriesType: $seriesType,
                    airDays: $airDays,
                    recordFolder: $recordFolder,
                    folderButtonLabel: "Choose…",
                    onSeriesTypeChange: { /* no-op: series flags applied at save() */ },
                    onChooseFolder: { chooseFolder() }
                )
            }
            .padding()
        }
    }

    // MARK: - Nav bar

    private var navBar: some View {
        HStack {
            Spacer()
            switch step {
            case .device:
                Button("Next") { goForward() }
                    .disabled(!canAdvance)
                    .buttonStyle(.borderedProminent)
            case .guide:
                EmptyView()
            case .details:
                HStack(spacing: 8) {
                    Button("Back") { goBack() }
                    Button("Save") { save() }
                        .disabled(!canAdvance)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding()
    }

    // MARK: - Navigation

    private var canAdvance: Bool {
        switch step {
        case .device:  return selectedDevice != nil
        case .guide:   return selectedEntry != nil && selectedChannel != nil
        case .details: return !show.show_title.isEmpty && recordFolder != nil
        }
    }

    private func goForward() {
        switch step {
        case .device:
            step = .guide
        case .guide:
            applyGuideEntry()
            step = .details
        case .details:
            save()
        }
    }

    private func goBack() {
        switch step {
        case .guide:   step = .device
        case .details: step = .guide
        default: break
        }
    }

    // MARK: - Logic

    private func loadAllGuide() async {
        guard let device = selectedDevice else {
            state.logGuide("[Wizard] no device selected — loadAllGuide returning")
            return
        }
        isLoadingGuide = true
        // Guarantee lineup is present before loading guide — recovers from silent startup fetch failures
        await state.ensureLineupLoaded(for: device)
        // Repair: guideRevision may have triggered auto-select before lineup was ready,
        // leaving selectedChannel nil. Now that lineup is confirmed available, fix it.
        repairSelectedChannel(deviceId: device.DeviceID)
        let id = device.DeviceID
        state.logGuide("[Wizard] loadAllGuide deviceId=\(id) fresh=\(state.guideStore.isFresh(deviceId: id)) loading=\(state.guideStore.isLoading(deviceId: id))")
        defer { isLoadingGuide = false }

        // Already cached — read immediately
        if state.guideStore.isFresh(deviceId: id) {
            let ch = state.guideStore.channels(deviceId: id)
            state.logGuide("[Wizard] cache hit — \(ch.count) channels, first guide counts: \(ch.prefix(3).map { "\($0.GuideNumber):\($0.Guide?.count ?? 0)" }.joined(separator: ", "))")
            allChannels = sortedGuideChannels(ch, favorites: Set((state.lineups[id] ?? []).filter(\.isFavorite).map(\.GuideNumber)))
            return
        }

        // Startup is already loading this device — wait for it then read
        if state.guideStore.isLoading(deviceId: id) {
            state.logGuide("[Wizard] startup load in progress, waiting...")
            let deadline = Date().addingTimeInterval(30)
            while state.guideStore.isLoading(deviceId: id) && Date() < deadline {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            let ch = state.guideStore.channels(deviceId: id)
            state.logGuide("[Wizard] startup finished — \(ch.count) channels")
            if !ch.isEmpty {
                state.guideByDevice = state.guideStore.channelsByDevice
                allChannels = sortedGuideChannels(ch, favorites: Set((state.lineups[id] ?? []).filter(\.isFavorite).map(\.GuideNumber)))
                return
            }
            state.logGuide("[Wizard] startup gave 0 channels — falling through to fresh load")
        }

        // Fresh load
        state.guideStore.verbose = state.config.Verbose_curl
        state.logGuide("[Wizard] fetching fresh guide for \(id)...")
        await state.guideStore.load(for: device, hours: state.config.GuideHours)
        state.guideByDevice = state.guideStore.channelsByDevice
        let ch = state.guideStore.channels(deviceId: id)
        state.logGuide("[Wizard] fetch complete — \(ch.count) channels")
        allChannels = sortedGuideChannels(ch, favorites: Set((state.lineups[id] ?? []).filter(\.isFavorite).map(\.GuideNumber)))
    }

    /// Called after lineup is confirmed loaded. Fixes selectedChannel when auto-select fired
    /// before the lineup arrived (guideRevision race) or when a tap captured a nil lineupEntry.
    private func repairSelectedChannel(deviceId: String) {
        guard let entry = selectedEntry, selectedChannel == nil else { return }
        let lineupList = state.lineups[deviceId] ?? []
        for ch in allChannels {
            guard ch.Guide?.contains(where: { $0.id == entry.id }) == true else { continue }
            selectedChannel = lineupList.first(where: { $0.GuideNumber == ch.GuideNumber })
            return
        }
    }

    private func applyPendingChannel(_ pending: (device: HDHRDevice, channel: LineupEntry)) {
        selectedDevice  = pending.device
        selectedChannel = pending.channel
        selectedEntry   = nil
        step = .guide
        state.pendingAddChannel = nil
    }

    private func applyPendingEntry(_ pending: (device: HDHRDevice, channel: LineupEntry, entry: GuideEntry)) {
        selectedDevice  = pending.device
        selectedChannel = pending.channel
        selectedEntry   = pending.entry
        applyGuideEntry()
        step = .details
        state.pendingAddEntry = nil
    }

    private func applyGuideEntry() {
        guard let entry = selectedEntry, let channel = selectedChannel, let device = selectedDevice else { return }
        show.show_title    = entry.Title
        show.show_channel  = channel.GuideNumber
        show.show_length   = entry.durationMinutes
        show.show_next     = entry.startDate
        show.show_end      = entry.endDate
        show.show_seriesid = entry.SeriesID ?? ""
        show.show_logo_url = entry.ImageURL ?? ""
        show.show_genre    = entry.firstGenre ?? ""
        show.show_bonus_time = entry.firstGenre?.lowercased().contains("sports") == true
        show.hdhr_record   = device.DeviceID
        show.show_url      = channel.URL ?? ""

        // Local time components — matches what the user sees in the guide
        let comps = Calendar.current.dateComponents([.hour, .minute, .weekday], from: entry.startDate)
        show.show_time = Double(comps.hour ?? 20) + Double(comps.minute ?? 0) / 60.0

        // Pre-populate airDays with the local weekday so it matches the guide display
        let dayName = ["Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"][(comps.weekday ?? 2) - 1]
        airDays = [dayName]

        seriesType = .single
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = state.defaultSaveDir
        if panel.runModal() == .OK, let url = panel.url {
            recordFolder = url
            UserDefaults.standard.set(url.path, forKey: "defaultSaveDirectory")
        }
    }

    private func save() {
        guard let folder = recordFolder else { return }
        // Apply series type flags
        show.show_is_series         = seriesType != .single
        show.show_use_seriesid      = seriesType.isSeries
        show.show_use_seriesid_all  = seriesType == .seriesAll
        show.show_air_date          = seriesType.isSeries
            ? ["Monday","Tuesday","Wednesday","Thursday","Friday","Saturday","Sunday"]
            : Array(airDays)
        show.show_dir               = folder.path
        show.show_temp_dir          = folder.path
        // For SeriesID shows, resolve to the current airing (or next) — same path as the menu flow
        if show.show_use_seriesid, let device = selectedDevice, let channel = selectedChannel {
            state.resolveSeriesAir(show: &show, device: device, isAll: show.show_use_seriesid_all, channel: channel)
        }
        state.addShow(show)
        dismiss()
    }

}

// Allow LineupEntry to be used with List selection
extension LineupEntry: Hashable, Equatable {
    static func == (lhs: LineupEntry, rhs: LineupEntry) -> Bool {
        lhs.GuideNumber == rhs.GuideNumber && lhs.Favorite == rhs.Favorite
    }
    func hash(into hasher: inout Hasher) { hasher.combine(GuideNumber) }
}
extension HDHRDevice: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(DeviceID) }
}

