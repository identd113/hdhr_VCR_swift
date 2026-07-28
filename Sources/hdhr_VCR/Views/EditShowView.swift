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

    private let weekdays = ["Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"]

    var body: some View {
        Group {
            if let s = show {
                VStack(alignment: .leading, spacing: 0) {
                    form(for: s)
                        .overlay(alignment: .topTrailing) {
                            if show?.show_bonus_time == true && state.config.Sports_padding_enabled {
                                StarburstBadge(minutes: state.config.Sports_padding_minutes, size: 150)
                                    .padding(.trailing, 16).padding(.top, 16)
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
            if isDirty {
                let alert = NSAlert()
                alert.messageText     = "Unsaved Changes"
                alert.informativeText = "Save your changes before closing?"
                alert.addButton(withTitle: "Save")
                alert.addButton(withTitle: "Discard")
                alert.addButton(withTitle: "Cancel")
                switch alert.runModal() {
                case .alertFirstButtonReturn:  saveWithoutDismiss(); dismiss()
                case .alertSecondButtonReturn: dismiss()
                default: break
                }
            } else {
                dismiss()
            }
        }
        .background(WindowCloseInterceptor(isDirty: isDirty, canSave: true, onSave: saveWithoutDismiss))
        .onAppear { loadShow() }
        // The window is a single reusable instance, so onAppear won't fire when it's merely
        // re-focused for a different show — reload whenever the target show id changes.
        // Guard against discarding unsaved edits: if the user re-targets this window to a
        // different show (e.g. clicking "Edit…" on show B while show A's edits are unsaved),
        // prompt the same way onExitCommand does instead of silently overwriting `show`.
        .onChange(of: state.editingShowId) { oldValue, newValue in
            guard newValue != show?.show_id else { return } // reverted back to the loaded show (Cancel below) — nothing to do
            guard isDirty else { loadShow(); return }
            let alert = NSAlert()
            alert.messageText     = "Unsaved Changes"
            alert.informativeText = "Save your changes to \"\(show?.show_title ?? "this show")\" before switching?"
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:  saveWithoutDismiss(); loadShow()
            case .alertSecondButtonReturn: loadShow()
            default: state.editingShowId = oldValue // stay on the show currently being edited
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
                    TextField("60", value: Binding(
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
            Button("Save") { save() }.buttonStyle(.borderedProminent)
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
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { recordFolder = url }
    }

    private func saveWithoutDismiss() {
        guard var s = show else { return }
        s.show_air_date         = Array(airDays)
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
        originalShow = s   // reset dirty tracking after save
    }

    private func save() {
        saveWithoutDismiss()
        dismiss()
    }
}
