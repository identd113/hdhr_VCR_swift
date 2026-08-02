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

    @Test func lowercasesMixedCase() {
        #expect(ChannelSignalStore.key(for: "KFOO-HD") == "kfoo-hd")
    }

    @Test func trimsLeadingAndTrailingWhitespace() {
        // Combines with alreadyCanonical_isUnchanged below to prove the exact bug the doc
        // comment warns about: a reader that only lowercases (without trimming) would derive
        // a *different* key here than the canonical "kfoo-hd" one.
        #expect(ChannelSignalStore.key(for: "  KFOO-HD  ") == "kfoo-hd")
    }

    @Test func alreadyCanonical_isUnchanged() {
        #expect(ChannelSignalStore.key(for: "kfoo-hd") == "kfoo-hd")
    }

    @Test func emptyString_staysEmpty() {
        #expect(ChannelSignalStore.key(for: "") == "")
    }

    @Test func internalWhitespace_isPreserved() {
        // Only leading/trailing whitespace is stripped — a name with an internal space is a
        // different channel, not a formatting variant to collapse.
        #expect(ChannelSignalStore.key(for: "K FOO HD") == "k foo hd")
    }
}
