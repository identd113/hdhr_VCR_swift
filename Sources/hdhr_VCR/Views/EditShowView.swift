import SwiftUI

struct EditShowView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss

    @State private var show: Show?
    @State private var originalShow: Show?
    @State private var seriesType: ShowState = .single
    @State private var airDays: Set<String> = []
    @State private var recordFolder: URL? = nil

    private var isDirty: Bool { show != nil && show != originalShow }

    // Mirrors AddShowView.canAdvance's non-empty-title + channel-in-lineup gate — Save had no
    // validation at all, so a cleared title or a free-text channel number that doesn't exist on
    // the assigned device could be saved as a show that will never record correctly. When the
    // device's lineup isn't currently known (e.g. its tuner is offline/undetected — see the web
    // guide's "tuner not detected" handling), membership can't be checked, so only the non-empty
    // check applies rather than blocking every edit to a show on a temporarily offline tuner.
    private var canSave: Bool {
        guard let s = show, !s.show_title.isEmpty, !s.show_channel.isEmpty else { return false }
        guard let lineup = state.lineups[s.hdhr_record], !lineup.isEmpty else { return true }
        return lineup.contains { $0.GuideNumber == s.show_channel }
    }

    private let weekdays = Show.weekdayNames

    var body: some View {
        Group {
            if let s = show {
                VStack(alignment: .leading, spacing: 0) {
                    form(for: s)
                        .overlay(alignment: .topTrailing) {
                            if show?.show_bonus_time == true && state.config.Sports_padding_enabled {
                                StarburstBadge(minutes: state.config.Sports_padding_minutes, size: 48)
                                    .padding(.trailing, 16).padding(.top, 10)
                                    .transition(.asymmetric(
                                        insertion: .identity,
                                        removal: .scale(scale: 0.05).combined(with: .opacity)
                                    ))
                            }
                        }
                    Divider()
                    navBar
                }
                .frame(width: 480, height: 520)
            } else {
                ProgressView("Loading…")
                    .frame(width: 480, height: 520)
            }
        }
        .onExitCommand {
            guard isDirty else { dismiss(); return }
            switch promptUnsavedChanges(
                title: "Unsaved Changes", canSave: canSave,
                savePrompt: "Save your changes before closing?",
                blockedPrompt: "This show can't be saved yet — fix the title/channel first. Discard changes?"
            ) {
            case .save:    saveWithoutDismiss(); dismiss()
            case .discard: dismiss()
            case .cancel:  break
            }
        }
        .background(WindowCloseInterceptor(isDirty: isDirty, canSave: canSave, onSave: saveWithoutDismiss))
        .onAppear { loadShow() }
        // The window is a single reusable instance, so onAppear won't fire when it's merely
        // re-focused for a different show — reload whenever the target show id changes.
        // Guard against discarding unsaved edits: if the user re-targets this window to a
        // different show (e.g. clicking "Edit…" on show B while show A's edits are unsaved),
        // prompt the same way onExitCommand does instead of silently overwriting `show`.
        .onChange(of: state.editingShowId) { oldValue, newValue in
            guard newValue != show?.show_id else { return } // reverted back to the loaded show (Cancel below) — nothing to do
            guard isDirty else { loadShow(); return }
            switch promptUnsavedChanges(
                title: "Unsaved Changes", canSave: canSave,
                savePrompt: "Save your changes to \"\(show?.show_title ?? "this show")\" before switching?",
                blockedPrompt: "\"\(show?.show_title ?? "This show")\" can't be saved yet — fix the title/channel first. Discard changes?"
            ) {
            case .save:    saveWithoutDismiss(); loadShow()
            case .discard: loadShow()
            case .cancel:  state.editingShowId = oldValue // stay on the show currently being edited
            }
        }
    }

    // MARK: - Form

    private func form(for s: Show) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Edit Show").font(.title2)

                ShowFormSection(
                    show: Binding($show)!,  // safe: called only inside `if let s = show` guard
                    seriesType: $seriesType,
                    airDays: $airDays,
                    recordFolder: $recordFolder,
                    folderButtonLabel: "Change…",
                    onSeriesTypeChange: { applySeriesType() },
                    onChooseFolder: { chooseFolder() }
                )

                LabeledContent("Channel") {
                    TextField("e.g. 5.4", text: Binding(
                        get: { show?.show_channel ?? "" },
                        set: { show?.show_channel = $0 }))
                        .frame(width: 80)
                }
                .help("The HDHomeRun guide channel number (e.g. 5.1, 9.2). Change this to redirect the recording to a different channel.")

                LabeledContent("Length (min)") {
                    TextField("", value: Binding(
                        get: { show?.show_length ?? 60 },
                        set: { show?.show_length = $0 }), format: .number)
                        .frame(width: 60)
                }
                .help("Recording duration in minutes, set from the guide end time. Bonus Time adds extra minutes past the guide end.")

                if s.show_fail_count > 0 {
                    LabeledContent("Failures") {
                        HStack {
                            Text("\(s.show_fail_count) — \(s.show_fail_reason)").foregroundStyle(.orange)
                            Button("Reset") {
                                show?.show_fail_count = 0
                                show?.show_fail_reason = ""
                                show?.show_active = true
                            }
                        }
                    }
                }

                LabeledContent("SeriesID") {
                    Text(s.show_seriesid.isEmpty ? "none" : s.show_seriesid).foregroundStyle(.secondary)
                }
                .help("The HDHomeRun series identifier used for smart recording. When set, hdhr_VCR matches any future airing of this series automatically, on this channel or across all channels.")

                LabeledContent("Stream URL") {
                    Text(s.show_url.isEmpty ? "not set" : s.show_url)
                        .foregroundStyle(.secondary).font(.caption).lineLimit(1)
                }
                .help("The HDHomeRun tuner stream URL for this channel's live feed. Set automatically when the show is added from the guide.")
            }
            .padding()
        }
    }

    private var navBar: some View {
        HStack {
            Button("Delete", role: .destructive) {
                if let s = show { state.confirmAndDeleteShow(s) { dismiss() } }
            }
            Spacer()
            Button("Save") { save() }.buttonStyle(.borderedProminent).disabled(!canSave)
        }
        .padding()
    }

    // MARK: - Logic

    private func loadShow() {
        guard let id = state.editingShowId,
              let s = state.shows.first(where: { $0.show_id == id }) else { return }
        show = s
        originalShow = s   // snapshot for dirty tracking
        seriesType = s.state
        airDays = Set(s.show_air_date)
        // Use show's existing dir, fall back to default setting, then ~/Movies
        if !s.posixRecordDir.isEmpty {
            recordFolder = URL(fileURLWithPath: s.posixRecordDir)
        } else {
            recordFolder = state.defaultSaveDir
        }
    }

    private func applySeriesType() {
        show?.show_is_series        = seriesType != .single
        show?.show_use_seriesid     = seriesType.isSeries
        show?.show_use_seriesid_all = seriesType == .seriesAll
        if seriesType.isSeries {
            airDays = Set(weekdays)
            // A Single show promoted to SeriesID may still carry a raw, episode-specific title
            // (e.g. from the guide entry it was originally added from) — strip it the same way
            // AddShowView.save() does, or it'd freeze on that one episode's title indefinitely.
            if let title = show?.show_title {
                show?.show_title = Show.seriesTitle(from: title)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { recordFolder = url }
    }

    private func saveWithoutDismiss() {
        guard var s = show else { return }
        // Sorted, not just Array(airDays) — Set iteration order is hash-seed dependent, so an
        // unsorted conversion rewrote show_air_date in a different permutation on every single
        // save even when the user changed nothing, which also fed into the isDirty divergence
        // below (show never got normalized back to match, so it never equaled originalShow).
        s.show_air_date         = weekdays.filter { airDays.contains($0) }
        s.show_is_series        = seriesType != .single
        s.show_use_seriesid     = seriesType.isSeries
        s.show_use_seriesid_all = seriesType == .seriesAll
        if let folder = recordFolder {
            s.show_dir      = folder.path
            // A local fallback distinct from show_dir, not a copy of it — this used to set
            // show_temp_dir to the same folder as show_dir, which silently destroyed the local
            // fallback posixRecordDir would otherwise redirect to if this folder's volume (e.g.
            // an external drive or NAS) went offline — on every single Edit Show save, whether or
            // not the user actually touched the folder picker. See Show.localFallbackDir.
            s.show_temp_dir = Show.localFallbackDir
        }
        state.updateShow(s)
        // Both show and originalShow must be reset to the normalized s — show alone was never
        // updated here before, so isDirty (show != originalShow) stayed true after every save,
        // popping a spurious "Unsaved Changes" prompt the next time a different show was opened
        // for edit in this same reused window.
        show = s
        originalShow = s   // reset dirty tracking after save
    }

    private func save() {
        saveWithoutDismiss()
        dismiss()
    }
}
