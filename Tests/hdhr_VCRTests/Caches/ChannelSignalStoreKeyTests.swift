import Testing
@testable import hdhr_VCR

// MARK: - ChannelSignalStore.key(for:)
//
// CLAUDE.md flags this directly: "every signal-history read/write derives its key via
// ChannelSignalStore.key(for:) (trim+lowercase). A reader that only lowercases silently
// misses data." Trivial function, but zero coverage before this — locking down both halves
// (trim AND lowercase, not just one) is exactly the kind of one-line regression this warning
// exists to prevent.

@Suite("ChannelSignalStore.key(for:)")
struct ChannelSignalStoreKeyTests {

    // One (input → expected) table — every row is a single key(for:) == expected comparison.
    @Test(arguments: [
        (input: "KFOO-HD",       expected: "kfoo-hd"),   // lowercasesMixedCase
        // Combines with the "already canonical" row below to prove the exact bug the doc comment
        // warns about: a reader that only lowercases (without trimming) would derive a *different*
        // key here than the canonical "kfoo-hd" one.
        (input: "  KFOO-HD  ",   expected: "kfoo-hd"),   // trimsLeadingAndTrailingWhitespace
        (input: "kfoo-hd",       expected: "kfoo-hd"),   // alreadyCanonical_isUnchanged
        (input: "",              expected: ""),          // emptyString_staysEmpty
        // Only leading/trailing whitespace is stripped — a name with an internal space is a
        // different channel, not a formatting variant to collapse.
        (input: "K FOO HD",      expected: "k foo hd"),  // internalWhitespace_isPreserved
    ])
    func key(_ row: (input: String, expected: String)) {
        #expect(ChannelSignalStore.key(for: row.input) == row.expected)
    }
}
