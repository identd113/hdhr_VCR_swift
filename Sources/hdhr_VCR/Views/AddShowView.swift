import SwiftUI

// Multi-step wizard: Device → Channel → Guide entry → Details → Save
struct AddShowView: View {
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

    private var taskId: String { "\(selectedDevice?.DeviceID ?? ""):\(refreshToken)" }
    // Step 3
    @State private var seriesType: ShowState = .single
    @State private var airDays: Set<String> = []
    @State private var recordFolder: URL? = {
        let stored = UserDefaults.standard.string(forKey: "defaultSaveDirectory") ?? ""
        if !stored.isEmpty { return URL(fileURLWithPath: stored) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
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

            Divider()
            navBar
        }
        .frame(width: step == .guide ? 960 : 560,
               height: step == .guide ? 700 : 540)
        .animation(.easeInOut(duration: 0.2), value: step)
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
            Text("Select Tuner").font(.title2).padding()
            if state.devices.isEmpty {
                ContentUnavailableView("No tuners found", systemImage: "wifi.slash",
                    description: Text("Make sure your HDHomeRun is on the network."))
            } else {
                List(state.devices, selection: $selectedDevice) { device in
                    HStack {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                        VStack(alignment: .leading) {
                            Text(device.DeviceID).bold()
                            Text(device.LocalIP).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(device.TunerCount ?? 0) tuners").foregroundStyle(.secondary)
                    }
                    .tag(device)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedDevice = device }
                }
            }
        }
    }

    private var guideStep: some View {
        VStack(spacing: 0) {
            // ── Tuner picker + refresh ────────────────────────────────────────
            HStack(spacing: 8) {
                Text("Tuner:").foregroundStyle(.secondary)
                if state.devices.count > 1 {
                    Picker("", selection: $selectedDevice) {
                        ForEach(state.devices) { device in
                            Text(device.DeviceID).tag(Optional(device))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 180)
                } else {
                    Text(selectedDevice?.DeviceID ?? "—")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isLoadingGuide {
                    ProgressView().scaleEffect(0.7)
                    Text("Loading…").font(.caption).foregroundStyle(.secondary)
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
            }
            .padding(.horizontal).padding(.vertical, 8)

            Divider()

            // ── Show summary panel ────────────────────────────────────────────
            summaryPanel
                .frame(height: 120)

            Divider()

            // ── Cable guide grid ──────────────────────────────────────────────
            if allChannels.isEmpty && !isLoadingGuide {
                ContentUnavailableView("No guide data", systemImage: "tv.slash",
                    description: Text("Guide data unavailable — tap Refresh to retry."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CableGuideView(
                    allChannels:     allChannels,
                    lineup:          state.lineups[selectedDevice?.DeviceID ?? ""] ?? [],
                    guideHours:      state.config.GuideHours,
                    selectedEntry:   $selectedEntry,
                    selectedChannel: $selectedChannel,
                    onConfirm: {
                        applyGuideEntry()
                        step = .details
                    }
                )
            }
        }
        .task(id: taskId) { await loadAllGuide() }
    }

    // ── Summary panel ─────────────────────────────────────────────────────────

    @ViewBuilder
    private var summaryPanel: some View {
        if let entry = selectedEntry {
            HStack(alignment: .top, spacing: 12) {
                // Poster image
                if let urlStr = entry.ImageURL, !urlStr.isEmpty, let url = URL(string: urlStr) {
                    AsyncImage(url: url) { img in
                        img.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Color(NSColor.separatorColor)
                    }
                    .frame(width: 120, height: 96)
                    .cornerRadius(6)
                    .clipped()
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(NSColor.separatorColor))
                        .frame(width: 120, height: 96)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.Title)
                        .font(.headline)
                        .lineLimit(1)
                    if let ep = episodeInfoLabel(entry) {
                        Text(ep)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let syn = entry.Synopsis, !syn.isEmpty {
                        Text(syn)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    Spacer(minLength: 0)
                    Text("ch \(selectedChannel?.GuideNumber ?? "?")  ·  \(guideTimeRange(entry))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
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
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
        return "\(f.string(from: entry.startDate)) – \(f.string(from: entry.endDate))"
    }

    private var detailsStep: some View {
        ScrollView {
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
        }
    }

    // MARK: - Nav bar

    private var navBar: some View {
        HStack {
            Button("Cancel") { dismiss() }
            Spacer()
            if step != .device {
                Button("Back") { goBack() }
            }
            Button(step == .details ? "Save" : "Next") {
                if step == .details { save() } else { goForward() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canAdvance)
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
        guard let device = selectedDevice else { return }
        isLoadingGuide = true
        allChannels = []
        defer { isLoadingGuide = false }

        // Use cached data if fresh (loaded within the last hour)
        if state.guideStore.isFresh(deviceId: device.DeviceID) {
            allChannels = state.guideStore.channels(deviceId: device.DeviceID)
            return
        }

        // Load fresh via the unified store
        state.guideStore.verbose = state.config.Verbose_curl
        await state.guideStore.load(for: device, hours: state.config.GuideHours)
        state.guideByDevice = state.guideStore.channelsByDevice
        allChannels = state.guideStore.channels(deviceId: device.DeviceID)
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
        show.hdhr_record   = device.DeviceID
        show.show_url      = channel.URL ?? ""

        // UTC time components (show_time and show_air_date are always in UTC)
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC")!
        let comps = utcCal.dateComponents([.hour, .minute, .weekday], from: entry.startDate)
        show.show_time = Double(comps.hour ?? 20) + Double(comps.minute ?? 0) / 60.0

        // Pre-populate airDays with the UTC weekday so DateTime mode works out-of-the-box
        let dayName = ["Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"][(comps.weekday ?? 2) - 1]
        airDays = [dayName]

        seriesType = entry.SeriesID != nil ? .seriesChannel : .single
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

