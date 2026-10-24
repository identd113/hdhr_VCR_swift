import SwiftUI
import WebKit

// Add Show: the web guide, with the recording details as a sheet over it (Record in the guide → sheet → Save).
struct AddShowView: View {

    @EnvironmentObject var state: AppState
    @Environment(\.dismissWindow) var dismissWindow   // closes the window by id; `dismiss` from inside the sheet only closed the sheet

    // No device-selection step — the tuner is chosen inside the web guide.
    enum Step { case guide, details }

    // Guide-step size is remembered across reopens and app restarts (persisted in UserDefaults via
    // @AppStorage). These feed the guide-step ideal width/height on open; the background
    // GeometryReader in `body` writes the user's resized size back. Floored at the 1100×720 minimum.
    @AppStorage("addShowGuideWidth")  private var savedGuideWidth:  Double = 1450
    @AppStorage("addShowGuideHeight") private var savedGuideHeight: Double = 820

    @State private var step: Step = .guide
    // Embedded-guide load failure (shown as an overlay with a Reload button) and the token that triggers the reload.
    @State private var guideLoadError: String? = nil
    @State private var guideReloadToken = 0
    @State private var show = Show.blank()   // transcode overridden in onAppear

    // Tuner chosen in the guide
    @State private var selectedDevice: HDHRDevice? = nil

    // Details sheet
    @State private var seriesType: ShowState = .single
    @State private var airDays: Set<String> = []
    @State private var recordFolder: URL? = {
        let stored = UserDefaults.standard.string(forKey: "defaultSaveDirectory") ?? ""
        if !stored.isEmpty { return URL(fileURLWithPath: stored) }
        return URL(fileURLWithPath: Show.localFallbackDir)
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            guideStep
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // The guide window keeps one size. The details step is a sheet that slides down from the title bar (the system's
        // own animation), so nothing resizes and the guide stays loaded underneath.
        .sheet(isPresented: Binding(get: { step == .details }, set: { if !$0 { step = .guide } })) {
            VStack(spacing: 0) {
                detailsStep
                Divider()
                navBar
            }
            .frame(width: 560, height: 540)
        }
        .frame(minWidth: 1100, idealWidth: max(1100, CGFloat(savedGuideWidth)), maxWidth: .infinity,
               minHeight: 720, idealHeight: max(720, CGFloat(savedGuideHeight)), maxHeight: .infinity)
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
        // Esc on the guide closes the window; on the details sheet it cancels the sheet (its Cancel button's shortcut).
        .onExitCommand { dismissWindow(id: "add-show") }
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
                if selectedDevice == nil { selectedDevice = state.availableDevices.first }
                go(.guide)
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
            // guidePageCacheWarm, not just webServerRunning — a listener bound but a still-cold
            // GET / page cache would otherwise point this WKWebView at a request that falls back to
            // a synchronous, multi-second @MainActor-blocking guide build (see AppState.startup()'s
            // own prebuildPageHTML call, which makes this effectively always already true by the
            // time a user could open this window; this is the defensive backstop for the rare case
            // it isn't yet).
            if state.webServerRunning && state.guidePageCacheWarm {
                AddShowWebView(port: state.config.Web_server_port,
                               appearanceMode: state.config.Appearance_mode,
                               reloadToken: guideReloadToken,
                               onLoadFailed: { guideLoadError = $0 },
                               onLoadSucceeded: { guideLoadError = nil },
                               onScanMultiplex: { rf, deviceId in
                                   // Only this embedded guide can ask for a scan (a LAN browser has no such bridge, and the web
                                   // server has no scan route): the app starts it itself and tells the page what happened.
                                   state.startOTAScan(deviceId: deviceId, rfChannels: [rf], userInitiated: false, showWindow: false)
                               },
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
                    go(.details)
                }
                .overlay {
                    if let error = guideLoadError {
                        VStack(spacing: 12) {
                            CaveatBanner(text: "The guide didn't load (\(error)).")
                            Button("Reload") { guideLoadError = nil; guideReloadToken += 1 }
                        }
                        .padding(24)
                        .frame(maxWidth: 480)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            } else {
                GuideStartingView(onRetry: {
                    // Re-run the same web-server claim/cache steps a fresh open does.
                    state.ensureWebServerRunning()
                    state.releaseInternalWebServer()
                    if state.webServerRunning && !state.guidePageCacheWarm {
                        state.webServer.prebuildPageHTML(state: state)
                    }
                })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Ensure the lineup is present before the user can click Record in the web guide.
        // Recovers from silent startup fetch failures so show_url is never empty on first click.
        // Keyed by state.availableDevices.isEmpty (not a bare .task, and not state.devices.isEmpty)
        // — a plain .task only fires once for this view's lifetime, so if the wizard opens during a
        // cold launch before device discovery has completed, the guard returns immediately and it
        // would otherwise never retry once discovery finishes; this id flips false once a real
        // (non-relay) device populates, re-running the task at that point. recordableDevices, not
        // raw devices, matters here: a discovered virtual-relay device (another instance's, watch-
        // only) can populate state.devices first while no real tuner has appeared yet — keying on
        // devices.isEmpty would flip false right then, fire this task with recordableDevices still
        // empty (the `guard let device` returns immediately), and never re-fire once a real tuner
        // shows up moments later since devices.isEmpty stays false from that point on.
        // Keyed on availableDevices (reachable tuners) because that is what the body loads from: keyed on
        // recordableDevices, a tuner that was present but unreachable at open left the key unchanged when it came back,
        // so the task never re-ran and the guide step sat on an empty lineup (2.6.5 review).
        .task(id: state.availableDevices.isEmpty) {
            guard let device = selectedDevice ?? state.availableDevices.first else { return }
            if selectedDevice == nil { selectedDevice = device }
            await state.ensureLineupLoaded(for: device)
        }
    }

    private var detailsStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Recording Details").font(.title2)

                if show.show_url.isEmpty {
                    CaveatBanner(text: "Stream URL not found — lineup may not be loaded yet. Cancel and pick the channel again.")
                }

                ShowFormSection(
                    show: $show,
                    seriesType: $seriesType,
                    airDays: $airDays,
                    recordFolder: $recordFolder,
                    folderButtonLabel: "Choose…",
                    onSeriesTypeChange: { /* no-op: series flags applied at save() */ },
                    onChooseFolder: { chooseFolder() },
                    titleError: show.show_title.isEmpty ? "Title is required." : nil,
                    daysError: (seriesType == .single || seriesType == .dateTime) && airDays.isEmpty
                        ? "Pick at least one day." : nil
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
        // guideGeneration included so the periodic background guide refresh forces a recompute even
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
            // recordableDevices — a virtual relay device (VirtualTunerService.swift) should never
            // become selectedDevice, same reasoning as the sibling lookup in applyWebGuideEntry below.
            selectedDevice = state.recordableDevices.first(where: { $0.DeviceID == entry.deviceId })
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
                    Button("Cancel") { step = .guide }
                        .keyboardShortcut(.cancelAction)
                    Button("Record") {
                        save()
                    }
                        .keyboardShortcut(.defaultAction)
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
            // A DateTime or Single show with every day deselected saves and then never fires —
            // seriesChannel/seriesAll shows don't use airDays this way (series types
            // override show_air_date to all 7 days at save regardless of this UI state).
            if seriesType == .dateTime || seriesType == .single { return !airDays.isEmpty }
            return true
        }
    }

    private func go(_ next: Step) { step = next }

    // MARK: - Logic

    /// Starts every guide pick from a brand-new `Show`. This Window is single-instance and `@State show`
    /// outlives a wizard session, so resetting only `show_id` (and transcode) let the previous show's other
    /// per-show choices — `show_ignore_duplicate_once`, `show_new_only`, `show_bonus_time`, the Discord and
    /// failure fields, the recording folder fallback — ride along into the next show; a leftover
    /// `show_ignore_duplicate_once` could even bypass Skip-already-recorded (2026-10-05 review). Callers fill
    /// in everything the guide entry supplies right after.
    private func resetShowForNewEntry() {
        show = Show.blank()
        show.show_transcode = state.config.Default_transcode
        // @State's initialiser only runs once per window lifetime; re-read so a default folder
        // changed in Settings since then is honoured.
        recordFolder = state.defaultSaveDir
    }

    private func applyPendingChannel(_ pending: (device: HDHRDevice, channel: LineupEntry)) {
        selectedDevice = pending.device
        go(.guide)
        state.pendingAddChannel = nil
    }

    private func applyPendingEntry(_ pending: (device: HDHRDevice, channel: LineupEntry, entry: GuideEntry)) {
        let entry   = pending.entry
        let channel = pending.channel
        let device  = pending.device
        selectedDevice           = device
        // Same fix as applyWebGuideEntry's own doc comment below — this is the wizard's other,
        // independent entry point into the same @State show (right-click/quick-add flows that
        // skip the guide step via state.pendingAddEntry), so it needs the identical show_id reset.
        resetShowForNewEntry()   // fresh Show (new id AND every flag back to its default) — see its doc comment
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
        go(.details)
        state.pendingAddEntry = nil
    }

    private func applyWebGuideEntry(deviceId: String, guideNumber: String,
                                     startTime: Int, endTime: Int,
                                     title: String, seriesId: String,
                                     genre: String, imageURL: String) {
        let startDate = Date(timeIntervalSince1970: TimeInterval(startTime))
        let endDate   = Date(timeIntervalSince1970: TimeInterval(endTime))
        // This Window is single-instance and @State show survives between sessions, so every guide pick starts from a fresh
        // Show (new show_id) — a reused id was silently dropped by addShow's duplicate guard.
        resetShowForNewEntry()   // fresh Show (new id AND every flag back to its default) — see its doc comment
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
            // recordableDevices — a virtual relay device is watch-only (addShow/updateShow reject
            // it anyway), so it should never become selectedDevice in the first place.
            selectedDevice = state.recordableDevices.first(where: { $0.DeviceID == deviceId })
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
        Dialogs.choose(panel, on: sheetWindow()) { url in
            guard let url else { return }
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
        // Only close the wizard if the show was actually added — addShow refuses a duplicate id or a
        // watch-only relay tuner, and closing unconditionally made a refused Record look like it worked
        // (2026-10-05 triage T10).
        switch state.addShow(show) {
        case .added:
            step = .guide   // drop the sheet, then close the window
            dismissWindow(id: "add-show")
        case .alreadyExists:
            showAddRefusal("This show was already added (the wizard kept an earlier show's identity). Close this window and start again from the guide.")
        case .watchOnlyTuner:
            showAddRefusal("That tuner is a watch-only relay of another Mac's recording, so it can't record. Pick a real tuner in the guide and try again.")
        }
    }

    private func showAddRefusal(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't Add Show"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        Dialogs.show(alert, on: sheetWindow())
    }

    /// The Details sheet's own window while it is up (the key window then), so pickers/alerts nest on the sheet
    /// instead of falling back to a detached panel; nil lets Dialogs pick its usual host.
    private func sheetWindow() -> NSWindow? {
        guard let key = NSApp.keyWindow, key.isSheet else { return nil }
        return key
    }
}

// "Starting guide…" spinner; if the guide server still isn't ready after 15 s, swaps to a caveat with Retry.
private struct GuideStartingView: View {
    let onRetry: () -> Void
    @State private var timedOut = false

    var body: some View {
        Group {
            if timedOut {
                VStack(spacing: 12) {
                    CaveatBanner(text: "The guide server isn't responding.")
                    Button("Retry") { timedOut = false; onRetry() }
                }
                .frame(maxWidth: 420)
            } else {
                ProgressView("Starting guide…")
            }
        }
        // Re-armed on every Retry (timedOut flips back to false).
        .task(id: timedOut) {
            guard !timedOut else { return }
            try? await Task.sleep(for: .seconds(15))
            if !Task.isCancelled { timedOut = true }
        }
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
    let reloadToken: Int         // bump to reload the guide after a load failure
    let onLoadFailed: (String) -> Void
    let onLoadSucceeded: () -> Void
    let onScanMultiplex: (Int, String) -> String   // RF channel, device id → a one-line status for the page
    let onAppearanceChanged: (String) -> Void
    let onRecord: ([String: Any]) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "record")
        config.userContentController.add(context.coordinator, name: "appearanceChanged")
        config.userContentController.add(context.coordinator, name: "scanMultiplex")
        // Mark the page as the in-app view before it paints, so guide.css's `html.native` rules (native scrollbars,
        // no frame around the grid) apply without a flash. LAN browsers never get this class.
        config.userContentController.addUserScript(WKUserScript(
            source: "document.documentElement.classList.add('native');",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
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
        context.coordinator.onRecord = onRecord   // the coordinator is made once; keep its callbacks current
        context.coordinator.onScanMultiplex = onScanMultiplex
        context.coordinator.onAppearanceChanged = onAppearanceChanged
        context.coordinator.onLoadFailed = onLoadFailed
        context.coordinator.onLoadSucceeded = onLoadSucceeded
        if context.coordinator.reloadToken != reloadToken {
            context.coordinator.reloadToken = reloadToken
            nsView.load(URLRequest(url: URL(string: "http://localhost:\(port)/")!))
        }
        guard context.coordinator.appearanceMode != appearanceMode else { return }
        context.coordinator.appearanceMode = appearanceMode
        context.coordinator.pushAppearance(to: nsView)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "record")
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "appearanceChanged")
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "scanMultiplex")
    }

    func makeCoordinator() -> Coordinator {
        let c = Coordinator(appearanceMode: appearanceMode, onRecord: onRecord, onAppearanceChanged: onAppearanceChanged)
        c.onScanMultiplex = onScanMultiplex
        c.reloadToken = reloadToken
        c.onLoadFailed = onLoadFailed
        c.onLoadSucceeded = onLoadSucceeded
        return c
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var appearanceMode: String
        var onRecord: ([String: Any]) -> Void
        var onAppearanceChanged: (String) -> Void
        var onScanMultiplex: (Int, String) -> String = { _, _ in "" }
        weak var webView: WKWebView?
        var reloadToken = 0
        var onLoadFailed: (String) -> Void = { _ in }
        var onLoadSucceeded: () -> Void = {}

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
            case "scanMultiplex":
                guard let body = message.body as? [String: Any], let rf = body["rf"] as? Int, OTAScanner.frequencyHz(rf: rf) != nil,
                      let deviceId = body["deviceId"] as? String else { return }
                DispatchQueue.main.async {
                    let status = self.onScanMultiplex(rf, deviceId)
                    let literal = (try? JSONSerialization.data(withJSONObject: [status])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
                    self.webView?.evaluateJavaScript("airScanStatus(\(literal)[0])", completionHandler: nil)
                }
            default: break
            }
        }

        func webView(_ wv: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.request.url?.host == "localhost" ? .allow : .cancel)
        }

        func webView(_ wv: WKWebView, didFinish _: WKNavigation!) {
            webView = wv
            pushAppearance(to: wv)
            DispatchQueue.main.async { self.onLoadSucceeded() }
        }

        func webView(_ wv: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
            reportLoadFailure(error)
        }

        func webView(_ wv: WKWebView, didFail _: WKNavigation!, withError error: Error) {
            reportLoadFailure(error)
        }

        private func reportLoadFailure(_ error: Error) {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }   // a superseded load, not a failure
            glog("[AddShow] embedded guide failed to load: \(ns.localizedDescription)", level: .warning)
            let message = ns.localizedDescription
            DispatchQueue.main.async { self.onLoadFailed(message) }
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
            // The app icon stands in until/unless the station's real logo is cached (see stationLogoPlaceholder).
            Image(nsImage: channelLogo ?? stationLogoPlaceholder).resizable().scaledToFit()
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
