import Testing
import Foundation
@testable import hdhr_VCR

// MARK: - AppState.deleteShow — show_id-keyed side-table cleanup
//
// CLAUDE.md's "New show_id-keyed tracking table" invariant: there are over a dozen Set<String>/
// [String: X] dicts in AppState keyed by show_id, and any new one "must also be cleared in
// deleteShow, or it leaks for the life of the app session." deleteShow already clears each one
// explicitly (AppState.swift) — this test asserts against the real properties directly (not a
// hand-duplicated shadow list) so it can't silently drift out of sync with deleteShow itself:
// if someone adds table #11 and forgets the deleteShow line, this test doesn't know to check it
// either — but if they clear the *wrong* key or forget one of the tables already wired up, this
// catches it immediately instead of leaking silently for a session's lifetime.
//
// discordEpisodeSnapshots was added after this test was originally written and is correctly
// cleared by deleteShow, but wasn't added to this table's populate/assert list until now
// (docs/AppState.md, TODO.md — 2026-08-16 audit) — the exact "forgot one of the tables already
// wired up" gap the comment above warns about, just in the test rather than the code.
//
// Uses makeTestAppState, which points ConfigManager at a per-call temp directory — deleteShow
// calls saveConfig(), and without that seam this test would overwrite the real on-disk config
// the deployed app uses (see ConfigManager.init's doc comment).

@Suite("AppState.deleteShow side-table cleanup")
struct AppStateDeleteShowCleanupTests {

    @Test @MainActor func deleteShow_clearsEveryShowIdKeyedSideTable() async {
        let show = Show.testActive(title: "Cleanup Target")
        let other = Show.testActive(title: "Unrelated Show")
        let state = makeTestAppState(shows: [show, other])
        let id = show.show_id

        state.showRetryAfter[id] = Date()
        state.conflictNotifiedEpochs[id] = 123
        state.missedStartNotifiedEpochs[id] = 456
        state.pendingDiscordStart.insert(id)
        state.failedThisAttempt.insert(id)
        state.duplicateOverrideUsedThisAttempt.insert(id)
        state.suppressStartDiscord.insert(id)
        state.tunerStatus[id] = TunerStatus(signalStrength: 90, lockType: "qam256", bitrateMbps: 12.3)
        state.signalDropoutTicks[id] = 3
        state.discordCardTasks[id] = Task {}
        state.discordEpisodeSnapshots[id] = AppState.DiscordEpisodeSnapshot(
            epNum: "S01E01", epTitle: "Pilot", synopsis: "A snapshot captured at Recording Started",
            tags: ["Drama"], isNew: true)

        // Same tables, unrelated show — proves deleteShow removes only the deleted show's own
        // entries, not every entry in each table.
        let otherId = other.show_id
        state.showRetryAfter[otherId] = Date()
        state.conflictNotifiedEpochs[otherId] = 789
        state.discordEpisodeSnapshots[otherId] = AppState.DiscordEpisodeSnapshot(
            epNum: "S02E02", epTitle: "Unrelated", synopsis: "", tags: [], isNew: false)

        state.deleteShow(show)

        #expect(state.showRetryAfter[id] == nil)
        #expect(state.conflictNotifiedEpochs[id] == nil)
        #expect(state.missedStartNotifiedEpochs[id] == nil)
        #expect(state.pendingDiscordStart.contains(id) == false)
        #expect(state.failedThisAttempt.contains(id) == false)
        #expect(state.duplicateOverrideUsedThisAttempt.contains(id) == false)
        #expect(state.suppressStartDiscord.contains(id) == false)
        #expect(state.tunerStatus[id] == nil)
        #expect(state.signalDropoutTicks[id] == nil)
        #expect(state.discordCardTasks[id] == nil)
        #expect(state.discordEpisodeSnapshots[id] == nil)

        // The show itself is gone…
        #expect(state.shows.contains { $0.show_id == id } == false)
        // …but the unrelated show and its own side-table entries are untouched.
        #expect(state.shows.contains { $0.show_id == otherId } == true)
        #expect(state.showRetryAfter[otherId] != nil)
        #expect(state.conflictNotifiedEpochs[otherId] != nil)
        #expect(state.discordEpisodeSnapshots[otherId] != nil)
    }
}
