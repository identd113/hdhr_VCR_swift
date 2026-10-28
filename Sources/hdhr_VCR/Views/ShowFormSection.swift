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
    /// Red caption shown under the Title / Day(s) rows when the host form's primary button is disabled because of them.
    var titleError: String? = nil
    var daysError: String? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

    // Defaults to true (no warning) only when no tuner has been picked yet at all (hdhr_record
    // empty — e.g. before a tuner is selected in the Add wizard): a false positive there would
    // wrongly warn about a device that was simply never selected. Once hdhr_record is set but
    // doesn't resolve to a known device — the documented "Web guide offline devices" case, a show
    // assigned to a real tuner that just isn't currently detected — falls back to false (warn),
    // matching AppState.startRecording's own conservative "unknown ⇒ force None" posture instead of
    // silently hiding a warning for a device whose actual capability genuinely isn't known.
    private var selectedDeviceSupportsTranscode: Bool {
        guard !show.hdhr_record.isEmpty else { return true }
        return state.devices.first(where: { $0.DeviceID == show.hdhr_record })?.supportsTranscode ?? false
    }

    /// The over-the-air guide has no SeriesIDs, so a SeriesID recording could never match: the SeriesID segment is dimmed for that tuner.
    private var seriesIDUnavailable: Bool {
        !show.hdhr_record.isEmpty && state.guideStore.guideHasNoSeriesIDs(deviceId: show.hdhr_record)
    }

    var body: some View {
        Group {
            LabeledContent("Title") {
                TextField("Title", text: $show.show_title).focusEffectDisabled(false)
            }
            if let titleError { FormErrorCaption(text: titleError) }

            if let sig = channelSignal, sig.bucket != .noData {
                if sig.bucket == .poor {
                    CaveatBanner(text: "Weak signal on this channel — recordings may drop out or fail.",
                                 systemImage: "antenna.radiowaves.left.and.right.slash")
                }
                LabeledContent("Signal") {
                    HStack(spacing: 6) {
                        SignalBarsView(bucket: sig.bucket, guideName: sig.name)
                        Text(sig.bucket == .good ? "Strong" : sig.bucket == .poor ? "Weak" : "Fair")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityHidden(true)   // the bars already carry the spoken label
                    }
                }
            }

            LabeledContent("Type") {
              HStack(spacing: 6) {
                Picker("Type", selection: topType) {
                    ForEach(TopType.allCases, id: \.self) { type in
                        Text(type.rawValue).tag(type)
                            .disabled(type == .seriesID && seriesIDUnavailable && !seriesType.isSeries)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Single: one recording on a specific date and time. DateTime: repeats weekly on selected days. SeriesID: records new episodes automatically via SeriesID matching — pick Channel or All scope below.")
                InfoButton("SeriesID is the guide's identifier for a TV series. It links every airing of the same series, so the app can find new episodes on its own, match a recording to its series, and skip repeats of an episode it already has.", about: "SeriesID")
                    .accessibilityIdentifier("show-form-seriesid-info")
              }
            }

            if seriesType.isSeries {
                LabeledContent("Scope") {
                    Picker("Scope", selection: Binding(
                        get: { seriesType == .seriesAll },
                        set: { isAll in seriesType = isAll ? .seriesAll : .seriesChannel }
                    )) {
                        Text("Channel").tag(false)
                        Text("All").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .help("Channel: records new episodes only on the channel you picked. All: records new episodes on any channel this tuner receives.")
            }

            LabeledContent("Transcode") {
                Picker("Transcode", selection: $show.show_transcode) {
                    Text("None").tag("none")
                    Text("Heavy").tag("heavy")
                    Text("Mobile").tag("mobile")
                    Text("Internet 720").tag("internet720")
                }
                .labelsHidden()
                .help("None keeps the raw MPEG stream (recommended). Heavy, Mobile, and Internet 720 transcode the stream to reduce file size or target a specific playback device. Not all tuner models support transcoding — on an unsupported tuner this is silently ignored and recorded as None, with no error.")
            }

            if seriesIDUnavailable {
                Text("Over-the-air guides have no SeriesIDs.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if show.show_transcode != "none", !selectedDeviceSupportsTranscode {
                CaveatBanner(text: "This tuner doesn't support transcoding — the Transcode setting above will be ignored and recorded as None.",
                             systemImage: "exclamationmark.triangle")
                    .accessibilityIdentifier("show-form-no-transcode-warning")
            }

            if state.config.Sports_padding_enabled {
                LabeledContent("Bonus Time") {
                    // The badge sits inline beside the toggle (it used to float over the form and
                    // cover controls) and scrolls with the form.
                    HStack(spacing: 8) {
                        Toggle("+\(state.config.Sports_padding_minutes) min past guide end",
                               isOn: Binding(
                            get: { show.show_bonus_time },
                            set: { val in
                                withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.65)) {
                                    show.show_bonus_time = val
                                }
                            }
                        ))
                        .accessibilityIdentifier("show-form-bonus-toggle")
                        if show.show_bonus_time {
                            StarburstBadge(minutes: state.config.Sports_padding_minutes, size: 60)
                                .transition(.asymmetric(insertion: .identity,
                                                        removal: .scale(scale: 0.05).combined(with: .opacity)))
                                .accessibilityIdentifier("show-form-bonus-badge")
                        }
                    }
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
                            .accessibilityLabel(day)
                        }
                    }
                }
                .help(seriesType == .single
                      ? "The day of the week this one-time recording will air."
                      : "All days of the week this show airs — select every applicable day.")
                if let daysError { FormErrorCaption(text: daysError) }
            }

            if seriesType != .single {
                LabeledContent("New Only") {
                    Toggle("Skip reruns", isOn: $show.show_new_only)
                }
                .help("Only record an airing the guide marks as new (today/tonight's original air date). A rerun the app hasn't recorded before is skipped and the show advances to its next scheduled airing — independent of \"Skip already-recorded episodes,\" which only catches an exact episode already on disk. Not available for Single, which always records one specific known airing.")
            }

            if state.config.Series_subfolder_enabled, state.config.Skip_recorded_episodes, seriesType.isSeries {
                if !show.show_ignore_duplicate_once, let tag = duplicateTag {
                    CaveatBanner(text: "Episode \(tag) is already on disk — this recording will be skipped.",
                                 systemImage: "tray.full")
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

/// One-line red validation caption used under a form field (Add/Edit Show).
struct FormErrorCaption: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.red)
            .accessibilityIdentifier("form-error-caption")
    }
}
