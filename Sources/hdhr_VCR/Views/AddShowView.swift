import SwiftUI
import WebKit

// Multi-step wizard: (optional Device) → Web Guide → Details → Save
struct AddShowView: View {

    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss

    // No device-selection step — the tuner is chosen inside the web guide.
    enum Step { case guide, details }

    // Guide-step size is remembered across reopens and app restarts (persisted in UserDefaults via
    // @AppStorage). These feed the guide-step ideal width/height on open; the background
    // GeometryReader in `body` writes the user's resized size back. Floored at the 1100×720 minimum.
    @AppStorage("addShowGuideWidth")  private var savedGuideWidth:  Double = 1450
    @AppStorage("addShowGuideHeight") private var savedGuideHeight: Double = 820

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
        return URL(fileURLWithPath: Show.localFallbackDir)
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
                case .guide:   return "Step 1 of 2: Guide"
                case .details: return "Step 2 of 2: Details"
                }
            }())
            .padding(.horizontal).padding(.top, 12)

            Divider().padding(.top, 8)

            Group {
                switch step {
                case .guide:   guideStep
                case .details: detailsStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomTrailing) {
                if step == .details && show.show_bonus_time && state.config.Sports_padding_enabled {
                    StarburstBadge(minutes: state.config.Sports_padding_minutes, size: 65)
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
            idealWidth:  step == .guide ? max(1100, CGFloat(savedGuideWidth))  : 560,
            maxWidth:    step == .guide ? .infinity : 560,
            minHeight:   step == .guide ? 720  : 540,
            idealHeight: step == .guide ? max(720, CGFloat(savedGuideHeight)) : 540,
            maxHeight:   step == .guide ? .infinity : 540
        )
        .animation(.easeInOut(duration: 0.2), value: step)
        // Remember the guide-step size across reopens/restarts — pure SwiftUI, no AppKit. This
        // background GeometryReader reads the window-content size (== window size under .contentSize)
        // and writes it to @AppStorage on resize. Sizes narrower than 1000 (the details step) are
        // ignored, so they never overwrite the saved guide size.
        .background(GeometryReader { geo in
            Color.clear.onChange(of: geo.size) { _, newSize in
                if newSize.width >= 1000 {
                    savedGuideWidth  = Double(newSize.width)
                    savedGuideHeight = Double(newSize.height)
                }
            }
        })
        // Esc backs out one screen at a time rather than always closing the whole wizard — from
        // Details it returns to the Guide (goBack(), the same transition the Back button uses),
        // and only actually dismisses the window once already on Guide (step 1).
        .onExitCommand {
            switch step {
            case .details: goBack()
            case .guide: dismiss()
            }
        }
        .onAppear {
            show.show_transcode = state.config.Default_transcode
            // Acquire the internal web server for this wizard instance on EVERY entry path — the
            // matching onDisappear release is unconditional, so a path that skips the acquire would
            // underflow internalWebServerUseCount and stop a server another window/relay still needs.
            // The pending-entry path lands on .details but can still navigate Back to .guide (goBack:
            // details → guide), whose WKWebView loads localhost:1980, so it genuinely needs it too.
            state.ensureWebServerRunning()
            if let pending = state.pendingAddEntry {
                applyPendingEntry(pending)
            } else if let pending = state.pendingAddChannel {
                applyPendingChannel(pending)
            } else {
                if selectedDevice == nil { selectedDevice = state.devices.first }
                step = .guide
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

    private var guideStep: some View {
        Group {
            if state.webServerRunning {
                AddShowWebView(port: state.config.Web_server_port,
                               appearanceMode: state.config.Appearance_mode,
                               onAppearanceChanged: { mode in
                                   // The embedded guide's own theme switcher is "this app's own
                                   // setting" here (unlike a real LAN browser hitting the same
                                   // guide.js, which has no such bridge to call at all) — so a
                                   // click on it updates the same global Appearance_mode Settings
                                   // → General shows, not just this one window's own display.
                                   state.config.Appearance_mode = mode
                                   state.saveConfig()
                               }) { data in
                    guard
                        let deviceId    = data["deviceId"]    as? String,
                        let guideNumber = data["guideNumber"] as? String,
                        let startTime   = data["startTime"]   as? Int,
                        let endTime     = data["endTime"]     as? Int
                    else {
                        // A click on the guide's Record button that never advances the wizard,
                        // with no visible error, is otherwise silent all the way down — this is
                        // the one native-side signal a future occurrence would leave behind.
                        glog("[AddShow] guide record message missing/malformed required field(s) — got keys: \(data.keys.sorted())", level: .warning)
                        return
                    }
                    let title    = data["title"]    as? String ?? ""
                    let seriesId = data["seriesId"] as? String ?? ""
                    let genre    = data["genre"]    as? String ?? ""
                    let imageURL = data["imageURL"] as? String ?? ""
                    glog("[AddShow] guide record → '\(title)' ch=\(guideNumber) device=\(deviceId)")
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
        // Keyed by state.devices.isEmpty (not a bare .task) — a plain .task only fires once for
        // this view's lifetime, so if the wizard opens during a cold launch before device
        // discovery has completed, `state.devices` is empty, the guard returns immediately, and
        // it would otherwise never retry once discovery finishes; this id flips false once
        // devices populate, re-running the task at that point.
        .task(id: state.devices.isEmpty) {
            guard let device = selectedDevice ?? state.devices.first else { return }
            await state.ensureLineupLoaded(for: device)
        }
    }

    private var detailsStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Recording Details").font(.title2)

                if show.show_url.isEmpty {
                    CaveatBanner(text: "Stream URL not found — lineup may not be loaded yet. Go back and reselect the channel.")
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

                otherAiringsSection
            }
            .padding()
        }
        .task(id: otherAiringsKey) {
            otherAiringsCache = computeOtherAirings()
        }
    }

    // MARK: - Other Airings

    // Cached result of computeOtherAirings() — recomputed via .task(id:) in detailsStep only when
    // an input it actually depends on changes, not on every unrelated body re-render (e.g. every
    // keystroke in the Title field, which otherAirings never depended on in the first place).
    @State private var otherAiringsCache: [(channel: String, entry: GuideEntry)] = []

    private struct OtherAiringsKey: Equatable {
        var seriesId: String, isSeries: Bool, channelScoped: Bool, channel: String, next: Date?, guideGeneration: Int
    }
    private var otherAiringsKey: OtherAiringsKey {
        // guideGeneration included so the ~hourly background guide refresh forces a recompute even
        // when none of this show's own fields changed — otherwise the wizard could keep showing a
        // stale "Other Upcoming Airings" list (a moved/cancelled/newly-visible airing) for as long
        // as it's left open across that refresh. channelScoped included so toggling the Scope
        // picker (Channel/All) recomputes the list immediately, not just a channel/type change.
        OtherAiringsKey(seriesId: show.show_seriesid, isSeries: seriesType.isSeries,
                        channelScoped: seriesType == .seriesChannel,
                        channel: show.show_channel, next: show.show_next,
                        guideGeneration: state.guideGeneration)
    }

    // Other upcoming airings of the same SeriesID, excluding the airing just selected in Step 2.
    // SeriesID-recording types only (seriesType.isSeries) — a Single/DateTime show records
    // one specific slot, so other airings aren't relevant to what will actually record.
    // Bounded by GuideStore's ~29h guide window per device — best-effort preview, not exhaustive.
    private func computeOtherAirings() -> [(channel: String, entry: GuideEntry)] {
        guard seriesType.isSeries, !show.show_seriesid.isEmpty else { return [] }
        let selectedStart = show.show_next.map { Int($0.timeIntervalSince1970) }
        // SeriesID(Channel) only ever records from the one channel it's locked to — filtering the
        // preview to that channel keeps it from listing airings this show could never actually
        // catch. SeriesID(All) can record from any channel on the assigned device, so stays
        // unfiltered. Device is deliberately never filtered either way — a cross-device airing is
        // still shown so double-clicking it can re-anchor the show to that other tuner (see the
        // exclusion filter below and switchToAiring()).
        let channelFilter = (seriesType == .seriesChannel) ? show.show_channel : nil
        return state.upcomingGuideEpisodes(seriesID: show.show_seriesid, channelNum: channelFilter)
            .filter { !($0.channel == show.show_channel && $0.entry.StartTime == selectedStart
                        && $0.entry.deviceId == show.hdhr_record) }
    }

    // Hidden entirely when there's nothing informative to show.
    @ViewBuilder
    private var otherAiringsSection: some View {
        let airings = otherAiringsCache
        if !airings.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Other Upcoming Airings")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(airings.enumerated()), id: \.offset) { index, pair in
                        if index > 0 { Divider() }
                        OtherAiringRow(
                            channel: pair.channel,
                            entry: pair.entry,
                            channelName: state.lineups[pair.entry.deviceId]?
                                .first(where: { $0.GuideNumber == pair.channel })?.GuideName,
                            channelLogo: state.channelImageURLs["\(pair.entry.deviceId):\(pair.channel)"]
                                .flatMap { state.channelIconImages[$0] },
                            onSwitchTo: { switchToAiring(channel: pair.channel, entry: pair.entry) }
                        )
                    }
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // Double-click on an "Other Upcoming Airings" row re-anchors the Details step to that
    // airing — same field set as the initial guide selection (applyWebGuideEntry/applyPendingEntry),
    // minus seriesType/bonus, which are left as the user already set them on this step. This panel
    // only shows while seriesType.isSeries (save() overrides show_air_date to all 7 days for series
    // types regardless of airDays' value), but airDays IS kept in sync with the newly-picked
    // entry's weekday — nothing stops the user from switching Type to dateTime/single afterward,
    // and a stale airDays from whichever airing was originally selected would then silently
    // schedule the wrong day's recurrence.
    private func switchToAiring(channel: String, entry: GuideEntry) {
        if selectedDevice?.DeviceID != entry.deviceId {
            selectedDevice = state.devices.first(where: { $0.DeviceID == entry.deviceId })
        }
        show.show_title    = entry.Title
        show.show_channel  = channel
        show.show_length   = entry.durationMinutes
        show.show_next     = entry.startDate
        show.show_end      = entry.endDate
        show.show_logo_url = entry.ImageURL ?? show.show_logo_url
        show.show_genre    = entry.firstGenre ?? show.show_genre
        // Re-anchoring to a different airing can change genre (e.g. a non-sports pick swapped for
        // an "Other Upcoming Airings" sports broadcast of the same series) — recompute Bonus Time
        // the same way applyWebGuideEntry/applyPendingEntry do, so it doesn't stay stuck at
        // whichever value the previously-selected airing implied.
        show.show_bonus_time = Show.genreImpliesBonusTime(show.show_genre) && state.config.Sports_padding_enabled
        show.hdhr_record   = entry.deviceId
        show.show_url      = state.lineups[entry.deviceId]?.first(where: { $0.GuideNumber == channel })?.URL ?? ""
        let comps = Calendar.current.dateComponents([.hour, .minute, .weekday], from: entry.startDate)
        show.show_time = Double(comps.hour ?? 20) + Double(comps.minute ?? 0) / 60.0
        airDays = [Show.weekdayNames[(comps.weekday ?? 2) - 1]]
    }

    // MARK: - Nav bar

    private var navBar: some View {
        HStack {
            Spacer()
            switch step {
            case .guide:
                EmptyView()
            case .details:
                HStack(spacing: 8) {
                    Button("Back") { goBack() }
                    Button("Record") { save() }
                        .disabled(!canAdvance)
                        .buttonStyle(.borderedProminent)
                        .tint(recordRed)
                }
            }
        }
        .padding()
    }

    // MARK: - Navigation

    private var canAdvance: Bool {
        switch step {
        case .guide:   return false  // web guide advances via its own Record button
        case .details:
            guard !show.show_title.isEmpty, recordFolder != nil, !show.show_url.isEmpty else { return false }
            // A recurring DateTime show with every day deselected saves and then never fires —
            // single/seriesChannel/seriesAll shows don't use airDays this way (series types
            // override show_air_date to all 7 days at save regardless of this UI state).
            if seriesType == .dateTime { return !airDays.isEmpty }
            return true
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
        show.show_bonus_time     = Show.genreImpliesBonusTime(entry.firstGenre) && state.config.Sports_padding_enabled
        show.hdhr_record         = device.DeviceID
        show.show_url            = channel.URL ?? ""
        if show.show_url.isEmpty {
            glog("[AddShow] pending entry '\(entry.Title)' ch=\(channel.GuideNumber) device=\(device.DeviceID) — stream URL not found on the passed-in channel", level: .warning)
        }
        let comps = Calendar.current.dateComponents([.hour, .minute, .weekday], from: entry.startDate)
        show.show_time = Double(comps.hour ?? 20) + Double(comps.minute ?? 0) / 60.0
        airDays    = [Show.weekdayNames[(comps.weekday ?? 2) - 1]]
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
        show.show_bonus_time = Show.genreImpliesBonusTime(genre) && state.config.Sports_padding_enabled
        show.hdhr_record     = deviceId
        // Look up the stream URL from the lineup so the recording process has the HDHR URL
        show.show_url = state.lineups[deviceId]?.first(where: { $0.GuideNumber == guideNumber })?.URL ?? ""
        if show.show_url.isEmpty {
            // This is the exact condition that leaves the Details step's Record button silently
            // disabled — the UI shows an orange banner for it, but nothing was logged, so a report
            // of "clicked Record, nothing happened" was previously undiagnosable after the fact.
            let lineup = state.lineups[deviceId]
            let reason = lineup == nil ? "lineup not loaded for this device"
                                        : "lineup loaded (\(lineup!.count) channels) but none match GuideNumber \(guideNumber)"
            glog("[AddShow] '\(title)' ch=\(guideNumber) device=\(deviceId) — stream URL not found: \(reason)", level: .warning)
        }
        // selectedDevice needed for save() — set it if not already set to the matching device
        if selectedDevice == nil || selectedDevice?.DeviceID != deviceId {
            selectedDevice = state.devices.first(where: { $0.DeviceID == deviceId })
        }
        let comps = Calendar.current.dateComponents([.hour, .minute, .weekday], from: startDate)
        show.show_time = Double(comps.hour ?? 20) + Double(comps.minute ?? 0) / 60.0
        airDays    = [Show.weekdayNames[(comps.weekday ?? 2) - 1]]
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
        guard let folder = recordFolder else {
            // Shouldn't be reachable — recordFolder defaults from config on init and canAdvance
            // already gates the Record button on it being non-nil — but log it rather than a
            // silent no-op if it somehow happens anyway.
            glog("[AddShow] save() aborted — recordFolder was nil for '\(show.show_title)'", level: .warning)
            return
        }
        show.show_is_series         = seriesType != .single
        show.show_use_seriesid      = seriesType.isSeries
        show.show_use_seriesid_all  = seriesType == .seriesAll
        // ShowFormSection hides the New Only toggle for .single, but the binding itself keeps
        // whatever was last checked — clear it here so a stale true from a DateTime/Series pick
        // can't silently ride along on a show whose UI no longer exposes the field at all.
        if seriesType == .single {
            show.show_new_only = false
        }
        // Step 2's guide selection sets show_title straight from the raw guide entry (which can
        // carry an episode-specific suffix, e.g. " S24E116 Trey Parker; Matt Stone; Alison Brie") —
        // strip it now that the show is confirmed as a SeriesID type, matching addShowFromGuide's
        // web-guide path. Without this, the title (and everything that reads it — menu bar, Discord
        // cards, the recording folder name) stays frozen on whichever single airing's guests were on
        // screen when the show was added, even though new episodes correctly record every night.
        if seriesType.isSeries {
            show.show_title = Show.seriesTitle(from: show.show_title)
        }
        show.show_air_date          = seriesType.isSeries
            ? Show.weekdayNames
            : Array(airDays)
        show.show_dir               = folder.path
        // A local fallback distinct from show_dir — not a copy of it — so posixRecordDir has
        // somewhere real to redirect to if this folder's volume (e.g. an external drive or NAS)
        // is offline when a recording is due. Matches addShowFromGuide's web-guide path; setting
        // show_temp_dir to the same folder as show_dir (as this used to) leaves no actual fallback.
        show.show_temp_dir          = Show.localFallbackDir
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
//
// Also two-way syncs Settings → General's Appearance setting with this specific embedded
// instance: native pushes appearanceMode down (on load, and live via updateNSView whenever
// Settings changes it while this window is already open) via a guide.js function
// (applyNativeTheme) that never posts back, and the guide's OWN theme-switcher buttons (a genuine
// user click, guide.js's setTheme) post the new choice back up through a second script-message
// handler — kept as two separate JS entry points specifically so pushing a theme down can never
// loop back and silently overwrite Appearance_mode itself (e.g. "auto" resolving to a concrete
// "dark" on load must never get echoed back as if the user had explicitly chosen "dark").
// A real browser hitting the same guide.js over the LAN has no `window.webkit` object at all, so
// its own theme clicks silently no-op past the try/catch instead of reaching this bridge —
// exactly the isolation CLAUDE.md/Settings' own Appearance InfoButton copy promises.
private struct AddShowWebView: NSViewRepresentable {
    let port: Int
    let appearanceMode: String   // "auto" | "dark" | "light" — mirrors AppConfig.Appearance_mode
    let onAppearanceChanged: (String) -> Void
    let onRecord: ([String: Any]) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "record")
        config.userContentController.add(context.coordinator, name: "appearanceChanged")
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        wv.load(URLRequest(url: URL(string: "http://localhost:\(port)/")!))
        return wv
    }

    // didFinish only fires on navigation — without this, a Settings change made while this
    // window is already open and sitting on the guide step wouldn't be reflected until the next
    // reload/reopen. Guarded on an actual change: updateNSView runs on *every* SwiftUI re-render
    // of this view, not just ones where appearanceMode itself changed (AddShowView observes
    // AppState, whose @Published churn — idle loop, guide refreshes — re-renders it often), so an
    // unconditional evaluateJavaScript here was spamming applyNativeTheme far more often than
    // intended: harmless in isolation, but a real, reproducible interference with the web guide's
    // own live search-box typing (WindowNavigationTests.swift's
    // addShowGuideSearchBoxIsAccessibleAndTypingDoesNotAutoSelect caught this — see its own
    // history for the repro) once it was firing on effectively every tick.
    func updateNSView(_ nsView: WKWebView, context: Context) {
        guard context.coordinator.appearanceMode != appearanceMode else { return }
        context.coordinator.appearanceMode = appearanceMode
        context.coordinator.pushAppearance(to: nsView)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "record")
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "appearanceChanged")
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(appearanceMode: appearanceMode, onRecord: onRecord, onAppearanceChanged: onAppearanceChanged)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var appearanceMode: String
        let onRecord: ([String: Any]) -> Void
        let onAppearanceChanged: (String) -> Void

        init(appearanceMode: String, onRecord: @escaping ([String: Any]) -> Void,
             onAppearanceChanged: @escaping (String) -> Void) {
            self.appearanceMode = appearanceMode
            self.onRecord = onRecord
            self.onAppearanceChanged = onAppearanceChanged
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "record":
                guard let body = message.body as? [String: Any] else { return }
                DispatchQueue.main.async { self.onRecord(body) }
            case "appearanceChanged":
                guard let mode = message.body as? String, ["auto", "dark", "light"].contains(mode) else { return }
                DispatchQueue.main.async { self.onAppearanceChanged(mode) }
            default: break
            }
        }

        func webView(_ wv: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.request.url?.host == "localhost" ? .allow : .cancel)
        }

        func webView(_ wv: WKWebView, didFinish _: WKNavigation!) {
            pushAppearance(to: wv)
        }

        // "auto" resolves against the current system appearance here (same as this file's
        // pre-existing behavior before Appearance_mode existed) rather than passing "auto"
        // through to guide.js's own media-query-based auto — the two would usually agree, but
        // resolving on the native side keeps a single source of truth for what "auto" means
        // across every one of this app's own windows, this embedded guide included.
        func pushAppearance(to wv: WKWebView) {
            let isDark: Bool
            switch appearanceMode {
            case "dark": isDark = true
            case "light": isDark = false
            default: isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            }
            let theme = isDark ? "dark" : "light"
            wv.evaluateJavaScript(
                "if (typeof applyNativeTheme === 'function') applyNativeTheme('\(theme)');",
                completionHandler: nil
            )
        }
    }
}

// Row for the "Other Upcoming Airings" panel on the Details step. No show title (redundant —
// the whole panel is about one series); episode info only when the guide has it. Styling
// mirrors WatchNowRow (channel logo + bold/secondary text hierarchy) and reuses the guide's
// genre color (guideEntryColor) as a leading accent bar — same visual language as the guide
// grid and Watch Now, just condensed to a compact list row. Double-click re-anchors the whole
// Details step to this airing (see AddShowView.switchToAiring) — a light hover tint plus a
// tooltip are the only affordance, since double-click isn't otherwise used in this view.
private struct OtherAiringRow: View {
    let channel: String        // GuideNumber, e.g. "4.1"
    let entry: GuideEntry
    let channelName: String?   // resolved GuideName, if lineup is loaded
    let channelLogo: NSImage?  // resolved from state.channelImageURLs/channelIconImages, if cached
    let onSwitchTo: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(guideEntryColor(for: entry, onAir: true))
                .frame(width: 3)
            channelIcon
            VStack(alignment: .leading, spacing: 1) {
                Text(upcomingFormatter.string(from: entry.startDate))
                    .font(.caption.weight(.semibold))
                Text(channelName.map { "Ch \(channel) · \($0)" } ?? "Ch \(channel)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let info = entry.episodeInfoLabel {
                    Text(info)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(hovering ? Color.secondary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: onSwitchTo)
        .help("Double-click to record this airing instead")
    }

    @ViewBuilder
    private var channelIcon: some View {
        Group {
            if let logo = channelLogo {
                Image(nsImage: logo).resizable().scaledToFit()
            } else {
                Image(systemName: "tv").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 18, height: 18)
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
