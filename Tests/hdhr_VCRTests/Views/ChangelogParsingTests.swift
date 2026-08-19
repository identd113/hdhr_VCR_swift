import Testing
@testable import hdhr_VCR

// MARK: - SettingsView.parseChangelog
//
// Backs the About tab's changelog display (TODO.md's "About tab: highlight the current version's
// changes, cap the visible changelog at 6 entries" item). Widened from `private` to `internal` for
// direct coverage — same "widen for testability" precedent TODO.md documents for HDHRManager.
//
// appVersion (Version.swift) is a fixed compiled-in constant ("YYMMDD-HHMM"), not test-injectable —
// dates here are chosen far enough in the past/future that these tests stay valid across rebuilds
// rather than pinned to today's exact appVersion value.

@Suite("SettingsView.parseChangelog")
struct ChangelogParsingTests {

    private func section(_ version: String, date: String) -> String {
        "## \(version) — \(date)\n\nSome change.\n"
    }

    @Test func capsToDefaultSixSections() {
        // 8 sections, all safely in the past — every one should be kept before capping.
        let text = (1...8).map { section("v1.0.\($0)", date: "2020-01-0\($0)") }.joined(separator: "\n")
        let (sections, _) = SettingsView.parseChangelog(text)
        #expect(sections.count == 6)
    }

    @Test func respectsCustomMaxSections() {
        let text = (1...8).map { section("v1.0.\($0)", date: "2020-01-0\($0)") }.joined(separator: "\n")
        let (sections, _) = SettingsView.parseChangelog(text, maxSections: 3)
        #expect(sections.count == 3)
    }

    @Test func keepsOriginalNewestFirstOrder() {
        let text = [section("v1.0.3", date: "2020-01-03"),
                    section("v1.0.2", date: "2020-01-02"),
                    section("v1.0.1", date: "2020-01-01")].joined(separator: "\n")
        let (sections, _) = SettingsView.parseChangelog(text)
        #expect(sections.map { $0.contains("v1.0.3") } == [true, false, false])
        #expect(sections[1].contains("v1.0.2"))
        #expect(sections[2].contains("v1.0.1"))
    }

    @Test func excludesSectionNewerThanAppVersion() {
        // The very first section is always unconditionally kept regardless of date (existing,
        // pre-existing behavior this test isn't re-litigating) — the newer-than-appVersion filter
        // only ever applies to later sections, so the future-dated one must sort second here to
        // actually exercise it.
        let text = [section("v1.0.1", date: "2020-01-01"),
                    section("v9.9.9", date: "2099-01-01")].joined(separator: "\n")   // far future — must be omitted
        let (sections, _) = SettingsView.parseChangelog(text)
        #expect(sections.count == 1)
        #expect(sections[0].contains("v1.0.1"))
        #expect(!sections.contains { $0.contains("v9.9.9") })
    }

    @Test func everyReturnedSectionIsIndependentlyHeadingPrefixed() {
        // Each element must be a standalone renderable markdown block — the "## " the split
        // consumes from every section after the first must be restored.
        let text = [section("v1.0.2", date: "2020-01-02"),
                    section("v1.0.1", date: "2020-01-01")].joined(separator: "\n")
        let (sections, _) = SettingsView.parseChangelog(text)
        #expect(sections.allSatisfy { $0.hasPrefix("## ") })
    }

    @Test func unreleasedSectionHasNoDate_alwaysKept() {
        let text = ["## Unreleased\n\nSomething not yet released.\n",
                    section("v1.0.1", date: "2020-01-01")].joined(separator: "\n")
        let (sections, _) = SettingsView.parseChangelog(text)
        #expect(sections.count == 2)
        #expect(sections[0].hasPrefix("## Unreleased"))
    }

    @Test func emptyText_returnsNoSections() {
        let (sections, latestVersion) = SettingsView.parseChangelog("")
        #expect(sections.isEmpty)
        #expect(latestVersion == nil)
    }

    @Test func noHeadingDelimiter_returnsWholeTextAsOneSection() {
        let text = "just some plain text, no ## heading anywhere"
        let (sections, _) = SettingsView.parseChangelog(text)
        #expect(sections == [text])
    }
}
