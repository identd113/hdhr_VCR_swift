import SwiftUI

// Shared by SettingsView's Recording section and FirstRunWizardView's Step 1 — same four fields,
// same copy (including InfoButton help text) previously duplicated verbatim between the two files.
// Kept as one view so a future edit to any of it (a new transcode option, revised wording, a
// changed Stepper range) can't silently drift between Settings and the wizard. Bindings only —
// each caller owns its own persistence (SettingsView writes through `draft`, committed on Save;
// the wizard writes to plain @State, committed only on Finish).
struct RecordingDefaultsFields: View {
    var folderLabel: String
    var onChooseFolder: () -> Void
    // nil hides the Reset button entirely (both current callers always pass one — the folder is
    // always resettable — but this keeps the row itself, not just its action, caller-controlled).
    var onResetFolder: (() -> Void)?
    @Binding var transcode: String
    @Binding var minFreeDiskGB: Double
    @Binding var failThreshold: Int
    // Distinguishes the two call sites' controls for UI automation (e.g. "settings-recording" vs
    // "wizard-recording") — see WindowNavigationTests.swift for why these matter more for
    // AppleScript/System Events automation than accessibilityLabel alone.
    var idPrefix: String

    var body: some View {
        Group {
            LabeledContent {
                HStack {
                    Text(folderLabel).foregroundStyle(.secondary)
                    Button("Choose…") { onChooseFolder() }
                        .accessibilityIdentifier("\(idPrefix)-choose-folder")
                    if let onResetFolder {
                        Button("Reset") { onResetFolder() }
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("\(idPrefix)-reset-folder")
                    }
                }
            } label: {
                HStack { Text("Default folder"); InfoButton("Where recordings are saved. Falls back to ~/Movies/hdhr_videos when not set.") }
            }

            Picker(selection: $transcode) {
                Text("None").tag("none")
                Text("Heavy").tag("heavy")
                Text("Mobile").tag("mobile")
                Text("Internet 720").tag("internet720")
            } label: {
                HStack { Text("Default transcode"); InfoButton("Applied to all new shows. None records the raw MPEG-2 stream — best quality, no re-encoding overhead. Not all tuner models support transcoding — on an unsupported tuner this is silently ignored and recorded as None, with no error.") }
            }
            .accessibilityIdentifier("\(idPrefix)-default-transcode")

            Stepper(value: $minFreeDiskGB, in: 1...100, step: 1) {
                HStack { Text("Min free disk: \(minFreeDiskGB, specifier: "%.0f") GB"); InfoButton("Recordings are skipped when free space on the save drive drops below this threshold.") }
            }
            .accessibilityIdentifier("\(idPrefix)-min-free-disk")

            Stepper(value: $failThreshold, in: 1...10) {
                HStack { Text("Pause after \(failThreshold) failure(s)"); InfoButton("A show is automatically paused after this many consecutive failures. Restore it via Maintenance → Reactivate Paused Shows.") }
            }
            .accessibilityIdentifier("\(idPrefix)-fail-threshold")
        }
    }
}
