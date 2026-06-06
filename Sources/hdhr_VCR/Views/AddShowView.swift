import SwiftUI
import WebKit

// Multi-step wizard: (optional Device) → Web Guide → Details → Save
struct AddShowView: View {

    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    @Environment(\.openWindow) private var openWindow

    enum Step { case device, guide, details }

    @State private var step: Step = .guide
    @State private var show = Show.blank()   // transcode overridden in onAppear

    // Step 1
    @State private var selectedDevice: HDHRDevice? = nil

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
            // Progress dots — device step intentionally omitted (device is chosen inside web guide)
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
            minWidth:    step == .guide ? 1100 : 560,
            idealWidth:  step == .guide ? 1280 : 560,
            maxWidth:    step == .guide ? .infinity : 560,
            minHeight:   step == .guide ? 720  : 540,
            idealHeight: step == .guide ? 820  : 540,
            maxHeight:   step == .guide ? .infinity : 540
        )
        .animation(.easeInOut(duration: 0.2), value: step)
        .onExitCommand { dismiss() }
        .onAppear {
            show.show_transcode = state.config.Default_transcode
            if let pending = state.pendingAddEntry {
                // Goes directly to details — no guide step, no web server needed.
                applyPendingEntry(pending)
            } else {
                // Guide step will show; start server now so it's ready before onRecord fires.
                state.ensureWebServerRunning()
                if let pending = state.pendingAddChannel {
                    applyPendingChannel(pending)
                } else {
                    if selectedDevice == nil { selectedDevice = state.devices.first }
                    step = .guide
                }
            }
        }
        .onDisappear { state.releaseInternalWebServer() }
        // Re-fire when the user opens the wizard again from WatchNow or the menu while it's already open.
        .onChange(of: state.pendingAddEntryGeneration) { _, _ in
            if let pending = state.pendingAddEntry { applyPendingEntry(pending) }
        }
        .onChange(of: state.pendingAddChannelGeneration) { _, _ in
            if let pending = state.pendingAddChannel { applyPendingChannel(pending) }
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
        Group {
            if state.webServerRunning {
                AddShowWebView(port: state.config.Web_server_port) { data in
                    guard
                        let deviceId    = data["deviceId"]    as? String,
                        let guideNumber = data["guideNumber"] as? String,
                        let startTime   = data["startTime"]   as? Int,
                        let endTime     = data["endTime"]     as? Int
                    else { return }
                    let title    = data["title"]    as? String ?? ""
                    let seriesId = data["seriesId"] as? String ?? ""
                    let genre    = data["genre"]    as? String ?? ""
                    let imageURL = data["imageURL"] as? String ?? ""
                    applyWebGuideEntry(deviceId: deviceId, guideNumber: guideNumber,
                                       startTime: startTime, endTime: endTime,
                                       title: title, seriesId: seriesId,
                                       genre: genre, imageURL: imageURL)
                    step = .details
                }
            } else {
                ProgressView("Starting guide…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Ensure the lineup is present before the user can click Record in the web guide.
        // Recovers from silent startup fetch failures so show_url is never empty on first click.
        .task {
            guard let device = selectedDevice ?? state.devices.first else { return }
            await state.ensureLineupLoaded(for: device)
        }
    }

    private var detailsStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Recording Details").font(.title2)

                if show.show_url.isEmpty {
                    Label("Stream URL not found — lineup may not be loaded yet. Go back and reselect the channel.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(Color.orange.cornerRadius(8))
                        .font(.callout)
                }

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
        case .guide:   return false  // web guide advances via its own Record button
        case .details: return !show.show_title.isEmpty && recordFolder != nil && !show.show_url.isEmpty
        }
    }

    private func goForward() {
        switch step {
        case .device:  step = .guide
        case .guide:   break   // web guide advances via its own Record button; nav bar hidden
        case .details: save()
        }
    }

    private func goBack() {
        switch step {
        case .details: step = .guide
        default: break
        }
    }

    // MARK: - Logic

    private func applyPendingChannel(_ pending: (device: HDHRDevice, channel: LineupEntry)) {
        selectedDevice = pending.device
        step = .guide
        state.pendingAddChannel = nil
    }

    private func applyPendingEntry(_ pending: (device: HDHRDevice, channel: LineupEntry, entry: GuideEntry)) {
        let entry   = pending.entry
        let channel = pending.channel
        let device  = pending.device
        selectedDevice           = device
        show.show_title          = entry.Title
        show.show_channel        = channel.GuideNumber
        show.show_length         = entry.durationMinutes
        show.show_next           = entry.startDate
        show.show_end            = entry.endDate
        show.show_seriesid       = entry.SeriesID ?? ""
        show.show_logo_url       = entry.ImageURL ?? ""
        show.show_genre          = entry.firstGenre ?? ""
        show.show_bonus_time     = entry.firstGenre?.lowercased().contains("sports") == true && state.config.Sports_padding_enabled
        show.hdhr_record         = device.DeviceID
        show.show_url            = channel.URL ?? ""
        let comps = Calendar.current.dateComponents([.hour, .minute, .weekday], from: entry.startDate)
        show.show_time = Double(comps.hour ?? 20) + Double(comps.minute ?? 0) / 60.0
        airDays    = [["Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"][(comps.weekday ?? 2) - 1]]
        seriesType = .single
        step = .details
        state.pendingAddEntry = nil
    }

    private func applyWebGuideEntry(deviceId: String, guideNumber: String,
                                     startTime: Int, endTime: Int,
                                     title: String, seriesId: String,
                                     genre: String, imageURL: String) {
        let startDate = Date(timeIntervalSince1970: TimeInterval(startTime))
        let endDate   = Date(timeIntervalSince1970: TimeInterval(endTime))
        show.show_title      = title
        show.show_channel    = guideNumber
        show.show_length     = (endTime - startTime) / 60
        show.show_next       = startDate
        show.show_end        = endDate
        show.show_seriesid   = seriesId
        show.show_logo_url   = imageURL
        show.show_genre      = genre
        show.show_bonus_time = genre.lowercased().contains("sports") && state.config.Sports_padding_enabled
        show.hdhr_record     = deviceId
        // Look up the stream URL from the lineup so the recording process has the HDHR URL
        show.show_url = state.lineups[deviceId]?.first(where: { $0.GuideNumber == guideNumber })?.URL ?? ""
        // selectedDevice needed for save() — set it if not already set to the matching device
        if selectedDevice == nil || selectedDevice?.DeviceID != deviceId {
            selectedDevice = state.devices.first(where: { $0.DeviceID == deviceId })
        }
        let comps = Calendar.current.dateComponents([.hour, .minute, .weekday], from: startDate)
        show.show_time = Double(comps.hour ?? 20) + Double(comps.minute ?? 0) / 60.0
        airDays    = [["Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"][(comps.weekday ?? 2) - 1]]
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
        show.show_is_series         = seriesType != .single
        show.show_use_seriesid      = seriesType.isSeries
        show.show_use_seriesid_all  = seriesType == .seriesAll
        show.show_air_date          = seriesType.isSeries
            ? ["Monday","Tuesday","Wednesday","Thursday","Friday","Saturday","Sunday"]
            : Array(airDays)
        show.show_dir               = folder.path
        show.show_temp_dir          = folder.path
        if show.show_use_seriesid, let device = selectedDevice,
           let channel = state.lineups[device.DeviceID]?.first(where: { $0.GuideNumber == show.show_channel }) {
            state.resolveSeriesAir(show: &show, device: device, isAll: show.show_use_seriesid_all, channel: channel)
        }
        state.addShow(show)
        dismiss()
    }
}

// WKWebView wrapper for the web guide in the Add Show wizard.
// Posts a WKScriptMessage on "record" when the user clicks Record in the web guide.
// The onRecord callback receives the entry data and advances the wizard to the details step.
private struct AddShowWebView: NSViewRepresentable {
    let port: Int
    let onRecord: ([String: Any]) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "record")
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        wv.load(URLRequest(url: URL(string: "http://localhost:\(port)/")!))
        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "record")
    }

    func makeCoordinator() -> Coordinator { Coordinator(onRecord: onRecord) }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let onRecord: ([String: Any]) -> Void
        init(onRecord: @escaping ([String: Any]) -> Void) { self.onRecord = onRecord }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "record", let body = message.body as? [String: Any] else { return }
            DispatchQueue.main.async { self.onRecord(body) }
        }

        func webView(_ wv: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.request.url?.host == "localhost" ? .allow : .cancel)
        }

        func webView(_ wv: WKWebView, didFinish _: WKNavigation!) {
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            wv.evaluateJavaScript(
                "localStorage.setItem('theme','\(isDark ? "dark" : "light")');if(typeof applyTheme==='function')applyTheme();",
                completionHandler: nil
            )
        }
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
