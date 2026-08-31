import Testing
import Foundation
@testable import hdhr_VCR

// MARK: - AppState.deleteShow — show_id-keyed side-table cleanup
//
// AppState.ShowRuntimeState consolidates the show_id-keyed "what's currently going on with this
// show" tracking that used to live as 12 independent Set<String>/[String: X] dictionaries (see
// ISSUES.md's "AppState as a god-object" entry) into one dictionary keyed by show_id — deleteShow's
// cleanup is now a single removal instead of a checklist a future feature has to remember to
// extend. tunerStatus deliberately stays its own separate @Published dict (folding it in would
// make every other field's mutation also fire objectWillChange) so this test checks it separately.
// This test asserts against the real properties directly (not a hand-duplicated shadow list) so it
// can't silently drift out of sync with deleteShow itself.
//
// Uses makeTestAppState, which points ConfigManager at a per-call temp directory — deleteShow
// calls saveConfig(), and without that seam this test would overwrite the real on-disk config
// the deployed app uses (see ConfigManager.init's doc comment).

@Suite("AppState.deleteShow side-table cleanup")
struct AppStateDeleteShowCleanupTests {

    @Test @MainActor func deleteShow_clearsShowRuntimeAndTunerStatus() async {
        let show = Show.testActive(title: "Cleanup Target")
        let other = Show.testActive(title: "Unrelated Show")
        let state = makeTestAppState(shows: [show, other])
        let id = show.show_id

        state.showRuntime[id] = AppState.ShowRuntimeState(
            isConflicting: true, conflictBeatenByFavorite: true,
            conflictNotifiedEpoch: 123, missedStartNotifiedEpoch: 456,
            suppressStartDiscord: true, pendingDiscordStart: true,
            failedThisAttempt: true, duplicateOverrideUsedThisAttempt: true,
            discordEpisodeSnapshot: AppState.DiscordEpisodeSnapshot(
                epNum: "S01E01", epTitle: "Pilot", synopsis: "A snapshot captured at Recording Started",
                tags: ["Drama"], isNew: true),
            signalDropoutTicks: 3, retryAfter: Date(), discordCardTask: Task {})
        state.tunerStatus[id] = TunerStatus(signalStrength: 90, lockType: "qam256", bitrateMbps: 12.3)

        // Same tables, unrelated show — proves deleteShow removes only the deleted show's own
        // entries, not every entry in each table.
        let otherId = other.show_id
        state.showRuntime[otherId] = AppState.ShowRuntimeState(retryAfter: Date())
        state.tunerStatus[otherId] = TunerStatus(signalStrength: 70, lockType: "8vsb", bitrateMbps: 8.0)

        state.deleteShow(show)

        #expect(state.showRuntime[id] == nil)
        #expect(state.tunerStatus[id] == nil)

        // The show itself is gone…
        #expect(state.shows.contains { $0.show_id == id } == false)
        // …but the unrelated show and its own side-table entries are untouched.
        #expect(state.shows.contains { $0.show_id == otherId } == true)
        #expect(state.showRuntime[otherId] != nil)
        #expect(state.tunerStatus[otherId] != nil)
    }
}
