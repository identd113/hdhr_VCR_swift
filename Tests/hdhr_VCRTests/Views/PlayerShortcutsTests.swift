import Testing
@testable import hdhr_VCR

// The "?" card lists every key VLCPlayerWindowManager.installKeyMonitor handles, and says which of them can
// do anything right now. A key added to the monitor without a row here would be an undocumented hotkey.
@Suite("PlayerShortcuts — the \"?\" help card's rows")
struct PlayerShortcutsTests {
    private func rows(seek: Bool = true, pause: Bool = true, pip: Bool = true, full: Bool = true) -> [ShortcutRow] {
        PlayerShortcuts.rows(canSeek: seek, canPause: pause, hasPiP: pip, isFullScreen: full)
    }
    private func row(_ key: String, in rows: [ShortcutRow]) -> ShortcutRow? { rows.first { $0.keys.contains(key) } }

    @Test func listsEveryKeyThePlayerHandles() {
        let keys = Set(rows().flatMap(\.keys))
        #expect(keys == ["←", "→", "Space", "Tab", "Esc", "i", "?"])
    }

    @Test func everythingAvailable_whenEverythingApplies() {
        let all = rows()
        #expect(all.allSatisfy { $0.isAvailable })
    }

    @Test func seekAndPause_needADiskBackedStream() {
        let live = rows(seek: false, pause: false)
        #expect(row("←", in: live)?.isAvailable == false)
        #expect(row("Space", in: live)?.isAvailable == false)
        #expect(row("←", in: live)?.note == "Recordings and FEEDs only")
    }

    @Test func tab_needsAPictureInPicture() {
        #expect(row("Tab", in: rows(pip: false))?.isAvailable == false)
        #expect(row("Tab", in: rows(pip: true))?.isAvailable == true)
    }

    @Test func esc_onlyMattersInFullScreen() {
        #expect(row("Esc", in: rows(full: false))?.isAvailable == false)
    }

    @Test func infoAndHelp_areAlwaysAvailable() {
        let none = rows(seek: false, pause: false, pip: false, full: false)
        #expect(row("i", in: none)?.isAvailable == true)
        #expect(row("?", in: none)?.isAvailable == true)
    }

    @Test func rowsHaveUniqueIDs_andEveryUnavailableRowSaysWhen() {
        let none = rows(seek: false, pause: false, pip: false, full: false)
        #expect(Set(none.map(\.id)).count == none.count)
        for r in none where !r.isAvailable { #expect(r.note?.isEmpty == false, "\(r.title) needs a note") }
    }
}
