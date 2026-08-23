import SwiftUI

struct ShowFormSection: View {
    @EnvironmentObject var state: AppState

    @Binding var show: Show
    @Binding var seriesType: ShowState
    @Binding var airDays: Set<String>
    @Binding var recordFolder: URL?

    var folderButtonLabel: String
    var onSeriesTypeChange: () -> Void
    var onChooseFolder: () -> Void

    private let weekdays = Show.weekdayNames

    // Collapses ShowState's 4 real cases to 3 top-level picker segments — seriesChannel and
    // seriesAll render as one "SeriesID" segment, with the Channel/All choice moved to the
    // separate Scope picker below. The underlying `seriesType`/`Show` fields are untouched:
    // this is presentation-only, so ManagedGuideMatcher/scheduling/Discord/docs — everything
    // keyed off the real 4-way ShowState — sees no change.
    private enum TopType: String, CaseIterable {
        case single = "Single", dateTime = "DateTime", seriesID = "SeriesID"
    }
    private var topType: Binding<TopType> {
        Binding(
            get: {
                switch seriesType {
                case .single: return .single
                case .dateTime: return .dateTime
                case .seriesChannel, .seriesAll: return .seriesID
                }
            },
            set: { newValue in
                switch newValue {
                case .single: seriesType = .single
                case .dateTime: seriesType = .dateTime
                // Picking SeriesID fresh from Single/DateTime defaults to Channel scope;
                // re-picking it while already a series type (a same-value tap) preserves
                // whichever scope was already selected instead of resetting it.
                case .seriesID: if !seriesType.isSeries { seriesType = .seriesChannel }
                }
            }
        )
    }

    // Cached result of the (disk-scanning) duplicate-episode check — recomputed via .task(id:)
    // below only when an input it actually depends on changes, rather than on every unrelated
    // body re-render (e.g. toggling Bonus Time no longer re-scans the series' folder). A title
    // edit that still names a real series folder does still trigger a real rescan — the cache
    // saves re-renders that don't touch these fields, not every keystroke unconditionally.
    @State private var duplicateTag: String? = nil

    private struct DuplicateCheckKey: Equatable {
        var title: String, isSeries: Bool, baseDir: String, channel: String, device: String, next: Date?
        var subfolderEnabled: Bool, skipEnabled: Bool
    }
    private var duplicateCheckKey: DuplicateCheckKey {
        DuplicateCheckKey(title: show.show_title, isSeries: seriesType.isSeries,
                          baseDir: recordFolder?.path ?? "", channel: show.show_channel,
                          device: show.hdhr_record, next: show.show_next,
                          subfolderEnabled: state.config.Series_subfolder_enabled,
                          skipEnabled: state.config.Skip_recorded_episodes)
    }

    // Signal quality for the selected channel, resolved from the same call-sign-keyed store the
    // guide/menu use. nil when the feature is off or the channel/GuideName can't be resolved;
    // .noData when the channel has never been recorded or scanned (nothing to show).
    private var channelSignal: (name: String, bucket: SignalBucket)? {
        guard state.config.Signal_quality_enabled,
              let gn = state.lineups[show.hdhr_record]?
                         .first(where: { $0.GuideNumber == show.show_channel })?.GuideName
        else { return nil }
        return (gn, signalBucket(guideName: gn))
    }

    var body: some View {
        Group {
            LabeledContent("Title") {
                TextField("Title", text: $show.show_title)
            }

            if let sig = channelSignal, sig.bucket != .noData {
                if sig.bucket == .poor {
                    Label("Weak signal on this channel — recordings may drop out or fail.",
                          systemImage: "antenna.radiowaves.left.and.right.slash")
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(Color.orange.cornerRadius(8))
                        .font(.callout)
                }
                LabeledContent("Signal") {
                    SignalBarsView(bucket: sig.bucket, guideName: sig.name)
                }
            }

            LabeledContent("Type") {
                Picker("", selection: topType) {
                    ForEach(TopType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Single: one recording on a specific date and time. DateTime: repeats weekly on selected days. SeriesID: records new episodes automatically via SeriesID matching — pick Channel or All scope below.")
            }

            if seriesType.isSeries {
                LabeledContent("Scope") {
                    Picker("", selection: Binding(
                        get: { seriesType == .seriesAll },
                        set: { isAll in seriesType = isAll ? .seriesAll : .seriesChannel }
                    )) {
                        Text("Channel").tag(false)
                        Text("All").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                .help("Channel: records new episodes only on the channel you picked. All: records new episodes on any channel this tuner receives.")
            }

            LabeledContent("Transcode") {
                Picker("", selection: $show.show_transcode) {
                    Text("None").tag("none")
                    Text("Heavy").tag("heavy")
                    Text("Mobile").tag("mobile")
                    Text("Internet 720").tag("internet720")
                }
                .help("None keeps the raw MPEG stream (recommended). Heavy, Mobile, and Internet 720 transcode the stream to reduce file size or target a specific playback device. Not all tuner models support transcoding — if a recording fails immediately after picking one, switch back to None.")
            }

            if state.config.Sports_padding_enabled {
                LabeledContent("Bonus Time") {
                    Toggle("+\(state.config.Sports_padding_minutes) min past guide end",
                           isOn: Binding(
                        get: { show.show_bonus_time },
                        set: { val in
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
                                show.show_bonus_time = val
                            }
                        }
                    ))
                }
            }

            if seriesType == .dateTime || seriesType == .single {
                let daysLabel = seriesType == .single ? "Day " : "Days"
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
                .help(seriesType == .single
                      ? "The day of the week this one-time recording will air."
                      : "All days of the week this show airs — select every applicable day.")
            }

            if seriesType != .single {
                LabeledContent("New Only") {
                    Toggle("Skip reruns", isOn: $show.show_new_only)
                }
                .help("Only record an airing the guide marks as new (today/tonight's original air date). A rerun the app hasn't recorded before is skipped and the show advances to its next scheduled airing — independent of \"Skip already-recorded episodes,\" which only catches an exact episode already on disk. Not available for Single, which always records one specific known airing.")
            }

            if state.config.Series_subfolder_enabled, state.config.Skip_recorded_episodes, seriesType.isSeries {
                if !show.show_ignore_duplicate_once, let tag = duplicateTag {
                    Label("Episode \(tag) is already on disk — this recording will be skipped.",
                          systemImage: "tray.full")
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(Color.orange.cornerRadius(8))
                        .font(.callout)
                }
                LabeledContent("Duplicate Episodes") {
                    Toggle("Record even if already on disk", isOn: $show.show_ignore_duplicate_once)
                }
                .help("Overrides \"Skip already-recorded episodes\" for this one recording — use this if you want a rerun captured again (e.g. you deleted the existing file, or want another copy). Clears itself once the recording succeeds, so future reruns go back to being skipped.")
            }

            LabeledContent("Folder") {
                HStack {
                    Text(recordFolder?.lastPathComponent ?? "Not set").foregroundStyle(.secondary)
                    Button(folderButtonLabel) { onChooseFolder() }
                }
            }
        }
        // Attached at the Group level (not on the Type Picker itself) so it also fires when the
        // Scope picker changes seriesType — that Picker's own selection is a derived Bool, not
        // seriesType directly, so an onChange on it wouldn't see the real ShowState value change.
        .onChange(of: seriesType) { onSeriesTypeChange() }
        .task(id: duplicateCheckKey) {
            // Debounce: .task(id:) cancels the previous task on every id change, i.e. every
            // keystroke in Title. Waiting briefly first means a burst of keystrokes only scans
            // once, after typing pauses, instead of on every character. The scan itself (behind
            // duplicateEpisodeTag) now runs off @MainActor via a detached task, so a slow-to-wake
            // external drive stalls only this debounced check, not the whole app.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            duplicateTag = await state.duplicateEpisodeTag(for: show, isSeries: seriesType.isSeries,
                                                            baseDir: recordFolder?.path ?? "")
        }
    }
}
