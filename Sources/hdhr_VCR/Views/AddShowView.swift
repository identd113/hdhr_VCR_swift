import SwiftUI

// Multi-step wizard: Device → Channel → Guide entry → Details → Save
struct AddShowView: View {

    // Static so these are created once, not on every guide cell tap or summaryPanel render
    private static let origAirdateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()
    private static let upcomingFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "E h:mm a"; return f
    }()
    private static let timeRangeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; f.locale = .current; return f
    }()
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss

    enum Step { case device, guide, details }

    @State private var step: Step = .device
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

    private let weekdays = ["Monday","Tuesday","Wednesday","Thursday","Friday","Saturday","Sunday"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Progress indicator
            HStack(spacing: 4) {
                ForEach([Step.device, .guide, .details], id: \.self) { s in
                    Circle().fill(s == step ? Color.accentColor : .secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
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
            // Single device — skip the device step entirely
            if state.devices.count == 1 {
                selectedDevice = state.devices[0]
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
                ContentUnavailableView("No tuners found", systemImage: "wifi.slash",
                    description: Text("Make sure your HDHomeRun is on the network."))
            } else {
                List(state.devices, selection: $selectedDevice) { device in
                    let activeRecordings = state.recordingShows.filter { $0.hdhr_record == device.DeviceID }.count
                    let channelCount = state.lineups[device.DeviceID]?.count ?? 0
                    HStack {
                        Image(systemName: "antenna.radiowaves.left.and.right")
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
        let managedSeriesIDs = Set(state.shows.compactMap {
            $0.show_seriesid.isEmpty ? nil : $0.show_seriesid
        })
        let managedTitles = Set(state.shows.map { $0.show_title })
        // Recording now
        let recordingSeriesIDs = Set(state.recordingShows.compactMap { $0.show_seriesid.isEmpty ? nil : $0.show_seriesid })
        let recordingTitles    = Set(state.recordingShows.map { $0.show_title })
        // Next up: active shows whose next air is within 30 min (matches menu bar orange-clock threshold)
        let now30 = Date()
        let nextUpShows = state.activeShows.filter {
            guard let d = $0.show_next.date else { return false }
            return d > now30 && d.timeIntervalSince(now30) <= 30 * 60
        }
        let nextUpSeriesIDs = Set(nextUpShows.compactMap { $0.show_seriesid.isEmpty ? nil : $0.show_seriesid })
        let nextUpTitles    = Set(nextUpShows.map { $0.show_title })
        // Bonus Time: find managed sports shows so the guide can draw the overtime dotted box
        let sportShows = state.shows.filter {
            state.config.Sports_padding_enabled && $0.show_genre.lowercased().contains("sports")
        }
        let bonusSeriesIDs = Set(sportShows.compactMap { $0.show_seriesid.isEmpty ? nil : $0.show_seriesid })
        let bonusTitles    = Set(sportShows.map { $0.show_title })

        return VStack(spacing: 0) {
            // ── Compact toolbar: tuner + genre filter + actions ───────────────
            HStack(spacing: 10) {
                if state.devices.count > 1 {
                    Text("Tuner:").foregroundStyle(.secondary).fixedSize()
                    Picker("", selection: $selectedDevice) {
                        ForEach(state.devices) { device in
                            Text(device.DeviceID).tag(Optional(device))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 170)
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
                Text("[\(allChannels.count) ch]").font(.caption2).foregroundStyle(.orange)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)

            Divider()

            // ── Summary (top 1/3) + Guide grid (bottom 2/3) ──────────────────
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    summaryPanel
                        .frame(height: proxy.size.height / 3)

                    Divider()

                    if allChannels.isEmpty && !isLoadingGuide {
                        ContentUnavailableView("No guide data", systemImage: "tv.slash",
                            description: Text("Guide data unavailable — tap Refresh to retry."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        CableGuideView(
                            allChannels:        allChannels,
                            lineup:             state.lineups[selectedDevice?.DeviceID ?? ""] ?? [],
                            guideHours:         state.config.GuideHours,
                            selectedEntry:      $selectedEntry,
                            selectedChannel:    $selectedChannel,
                            snapToNow:          $snapToNow,
                            managedSeriesIDs:   managedSeriesIDs,
                            managedTitles:      managedTitles,
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
                            }
                        )
                    }
                }
            }
        }
        .task(id: taskId) { await loadAllGuide() }
        .onChange(of: selectedDevice) { _, newDevice in
            // Force fresh data whenever the user switches tuners
            guard let id = newDevice?.DeviceID else { return }
            state.guideStore.invalidate(deviceId: id)
            state.lineups.removeValue(forKey: id)
            allChannels = []
            refreshToken = UUID()
        }
        .onChange(of: state.guideRevision) { _, _ in
            guard let id = selectedDevice?.DeviceID, allChannels.isEmpty else { return }
            let ch = state.guideStore.channels(deviceId: id)
            guard !ch.isEmpty else { return }
            state.logGuide("[Wizard] guideRevision fired — \(ch.count) channels pulled into view")
            allChannels = ch
            isLoadingGuide = false
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
                (show.show_next.date ?? .distantFuture) <= Date() &&
                (show.show_end.date  ?? .distantPast)   >  Date()
            }
            let isSportsBonusEntry = entry.firstGenre?.lowercased().contains("sports") == true
                                  && state.config.Sports_padding_enabled

            ZStack(alignment: .topTrailing) {
            HStack(alignment: .top, spacing: 14) {
                // Poster image
                if let urlStr = entry.ImageURL, !urlStr.isEmpty, let url = URL(string: urlStr) {
                    AsyncImage(url: url) { img in
                        img.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Color.white.opacity(0.2)
                    }
                    .frame(width: 140, height: 100)
                    .cornerRadius(7)
                    .clipped()
                } else {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.white.opacity(0.2))
                        .frame(width: 140, height: 100)
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

                    if let ep = episodeInfoLabel(entry) {
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
                        Text("Orig. \(Self.origAirdateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(airdate))))")
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
                                let labels = upcoming.map { "Channel \($0.channel) \(Self.upcomingFormatter.string(from: $0.entry.startDate))" }
                            Text(labels.joined(separator: "  ·  "))
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.85))
                                .lineLimit(2)
                                .shadow(color: .black.opacity(0.35), radius: 1.5, x: 0, y: 1)
                        }
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 8) {
                        ChannelIcon(urlString: channelIcon, size: 18)
                        Text("Channel \(selectedChannel?.GuideNumber ?? "?")  ·  \(guideTimeRange(entry))")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.85))
                            .shadow(color: .black.opacity(0.35), radius: 1.5, x: 0, y: 1)
                        Spacer()
                        if onAir,
                           state.config.Watch_in_VLC,
                           FileManager.default.fileExists(atPath: "/Applications/VLC.app") {
                            Button(action: { state.watchInVLC(url: selectedChannel?.URL ?? "") }) {
                                Text("Watch in VLC")
                                    .foregroundColor(Color(red: 1.0, green: 0.482, blue: 0.0))
                            }
                            .controlSize(.small)
                            .disabled(selectedChannel == nil)
                        }
                        Button("Record") {
                            applyGuideEntry()
                            step = .details
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedChannel == nil)
                    }
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

            // Sports bonus-time starburst — floats over top-right corner of the summary card
            if isSportsBonusEntry {
                StarburstShape()
                    .fill(Color.orange)
                    .frame(width: 80, height: 80)
                    .overlay(
                        VStack(spacing: 2) {
                            Text("🏈").font(.title3)
                            Text("+\(state.config.Sports_padding_minutes) min")
                                .font(.caption).bold().foregroundColor(.white)
                        }
                    )
                    .scaleEffect(showSummaryStarburst ? 1.0 : 0.1)
                    .rotationEffect(.degrees(showSummaryStarburst ? 0 : -45))
                    .animation(.spring(response: 0.4, dampingFraction: 0.55), value: showSummaryStarburst)
                    .onAppear  { showSummaryStarburst = true  }
                    .onDisappear { showSummaryStarburst = false }
                    .padding(.trailing, 18).padding(.top, 8)
            }
            } // ZStack
        } else {
            Text("Select a show from the grid")
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func episodeInfoLabel(_ entry: GuideEntry) -> String? {
        let parts = [entry.EpisodeNumber, entry.EpisodeTitle]
            .compactMap { s -> String? in
                guard let s, !s.isEmpty else { return nil }
                return s
            }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    private func guideTimeRange(_ entry: GuideEntry) -> String {
        return "\(Self.timeRangeFormatter.string(from: entry.startDate)) – \(Self.timeRangeFormatter.string(from: entry.endDate))"
    }

    // 12-point starburst shape for the bonus-time badge
    private struct StarburstShape: Shape {
        func path(in rect: CGRect) -> Path {
            let cx = rect.midX, cy = rect.midY
            let outerR = min(rect.width, rect.height) / 2
            let innerR = outerR * 0.55
            let points = 12
            var path = Path()
            for i in 0..<(points * 2) {
                let angle = Double(i) * .pi / Double(points) - .pi / 2
                let r = i.isMultiple(of: 2) ? outerR : innerR
                let x = cx + CGFloat(cos(angle)) * r
                let y = cy + CGFloat(sin(angle)) * r
                i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
            }
            path.closeSubpath()
            return path
        }
    }

    @State private var showStarburst        = false
    @State private var showSummaryStarburst = false

    private var detailsStep: some View {
        let isSportsBonusShow = show.show_genre.lowercased().contains("sports") && state.config.Sports_padding_enabled
        return ScrollView {
            ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Recording Details").font(.title2)

                LabeledContent("Title") {
                    TextField("Title", text: $show.show_title)
                }

                LabeledContent("Type") {
                    Picker("", selection: $seriesType) {
                        ForEach(ShowState.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                }

                if seriesType == .dateTime || seriesType == .single {
                    let daysLabel = seriesType == .single ? "Day" : "Days"
                    LabeledContent(daysLabel) {
                        HStack {
                            ForEach(weekdays, id: \.self) { day in
                                let abbr = String(day.prefix(2))
                                Toggle(isOn: Binding(
                                    get: { airDays.contains(day) },
                                    set: { on in
                                        if seriesType == .single {
                                            airDays = on ? [day] : []
                                        } else {
                                            if on { airDays.insert(day) } else { airDays.remove(day) }
                                        }
                                    }
                                )) { Text(abbr).font(.caption) }
                                .toggleStyle(.button)
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }

                LabeledContent("Transcode") {
                    Picker("", selection: $show.show_transcode) {
                        Text("None").tag("none")
                        Text("Heavy").tag("heavy")
                        Text("Mobile").tag("mobile")
                        Text("Internet 720").tag("internet720")
                    }
                }

                LabeledContent("Folder") {
                    HStack {
                        Text(recordFolder?.lastPathComponent ?? "Not set").foregroundStyle(.secondary)
                        Button("Choose…") { chooseFolder() }
                    }
                }
            }
            .padding()

            // Sports bonus-time starburst badge — animates in when a sports show is selected
            if isSportsBonusShow {
                StarburstShape()
                    .fill(Color.orange)
                    .frame(width: 90, height: 90)
                    .overlay(
                        VStack(spacing: 2) {
                            Text("🏈").font(.title3)
                            Text("+\(state.config.Sports_padding_minutes) min")
                                .font(.caption).bold().foregroundColor(.white)
                        }
                    )
                    .scaleEffect(showStarburst ? 1.0 : 0.1)
                    .rotationEffect(.degrees(showStarburst ? 0 : -45))
                    .animation(.spring(response: 0.4, dampingFraction: 0.55), value: showStarburst)
                    .onAppear { showStarburst = true }
                    .onDisappear { showStarburst = false }
                    .padding(.trailing, 12).padding(.top, 12)
            }
            } // ZStack
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
        let id = device.DeviceID
        state.logGuide("[Wizard] loadAllGuide deviceId=\(id) fresh=\(state.guideStore.isFresh(deviceId: id)) loading=\(state.guideStore.isLoading(deviceId: id))")
        isLoadingGuide = true
        defer { isLoadingGuide = false }

        // Already cached — read immediately
        if state.guideStore.isFresh(deviceId: id) {
            let ch = state.guideStore.channels(deviceId: id)
            state.logGuide("[Wizard] cache hit — \(ch.count) channels, first guide counts: \(ch.prefix(3).map { "\($0.GuideNumber):\($0.Guide?.count ?? 0)" }.joined(separator: ", "))")
            allChannels = ch
            return
        }

        // Startup is already loading this device — wait for it then read
        if state.guideStore.isLoading(deviceId: id) {
            state.logGuide("[Wizard] startup load in progress, waiting...")
            while state.guideStore.isLoading(deviceId: id) {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            let ch = state.guideStore.channels(deviceId: id)
            state.logGuide("[Wizard] startup finished — \(ch.count) channels")
            if !ch.isEmpty {
                state.guideByDevice = state.guideStore.channelsByDevice
                allChannels = ch
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
        allChannels = ch
    }

    private func applyGuideEntry() {
        guard let entry = selectedEntry, let channel = selectedChannel, let device = selectedDevice else { return }
        show.show_title    = entry.Title
        show.show_channel  = channel.GuideNumber
        show.show_length   = entry.durationMinutes
        show.show_next     = EpochDate(entry.startDate)
        show.show_end      = EpochDate(entry.endDate)
        show.show_seriesid = entry.SeriesID ?? ""
        show.show_logo_url = entry.ImageURL ?? ""
        show.show_genre    = entry.firstGenre ?? ""
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
        show.show_use_seriesid      = seriesType == .seriesChannel || seriesType == .seriesAll
        show.show_use_seriesid_all  = seriesType == .seriesAll
        show.show_air_date          = seriesType == .seriesChannel || seriesType == .seriesAll
            ? ["Monday","Tuesday","Wednesday","Thursday","Friday","Saturday","Sunday"]
            : Array(airDays)
        show.show_dir               = folder.path
        show.show_temp_dir          = folder.path
        state.addShow(show)
        dismiss()
    }

}

// Allow LineupEntry to be used with List selection
extension LineupEntry: Hashable, Equatable {
    static func == (lhs: LineupEntry, rhs: LineupEntry) -> Bool { lhs.GuideNumber == rhs.GuideNumber }
    func hash(into hasher: inout Hasher) { hasher.combine(GuideNumber) }
}
extension HDHRDevice: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(DeviceID) }
}

