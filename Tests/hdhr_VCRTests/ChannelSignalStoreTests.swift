import Testing
import Foundation
@testable import hdhr_VCR

// MARK: - ChannelSignalStore
//
// key(for:) already had coverage (ChannelSignalStoreKeyTests.swift); everything else — record,
// needsSample's adaptive re-sample thresholds, stats, and the bucket-average logic underlying
// both — was 2.04% covered, blocked by `static let shared`'s `private init()` always resolving to
// the real ~/Library/Application Support/hdhrVCRplus/. Flagged in TODO.md 2026-08-15, fixed here
// by widening init to accept an appSupportDir seam (same shape as ConfigManager's own).

@MainActor
private func makeStore() -> ChannelSignalStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return ChannelSignalStore(appSupportDir: dir)
}

@Suite("ChannelSignalStore")
@MainActor
struct ChannelSignalStoreTests {
    @Test func record_singleSample_populatesBucketAndStats() {
        let store = makeStore()
        store.record(guideName: "KFOO-HD", snq: 80)
        #expect(store.buckets["kfoo-hd"] != nil)
        let stats = store.stats(guideName: "KFOO-HD")
        #expect(stats?.last == 80)
        #expect(stats?.avg == 80)
        #expect(stats?.windowCount == 1)
        #expect(stats?.totalCount == 1)
    }

    @Test func record_clampsOutOfRangeSNQ() {
        let store = makeStore()
        store.record(guideName: "KFOO-HD", snq: 150)
        #expect(store.stats(guideName: "KFOO-HD")?.last == 100)
        store.record(guideName: "KFOO-HD", snq: -20)
        #expect(store.stats(guideName: "KFOO-HD")?.last == 0)
    }

    @Test func record_keyedThroughKeyFor_trimAndLowercase() {
        // Writer uses a padded/mixed-case name; reader uses the canonical form — must resolve to
        // the same bucket (this is the exact regression ChannelSignalStoreKeyTests guards against,
        // exercised here end-to-end through record/stats instead of key(for:) in isolation).
        let store = makeStore()
        store.record(guideName: "  KFOO-HD  ", snq: 60)
        #expect(store.stats(guideName: "kfoo-hd") != nil)
    }

    @Test func record_retainsOnlyLast50Samples() {
        let store = makeStore()
        for i in 1...55 { store.record(guideName: "KFOO", snq: i) }
        #expect(store.stats(guideName: "KFOO")?.totalCount == 50)
        // Oldest 5 (snq 1-5) should have been dropped — last sample is still the most recent (55).
        #expect(store.stats(guideName: "KFOO")?.last == 55)
    }

    @Test func stats_windowIsLast20Samples() {
        let store = makeStore()
        for i in 1...30 { store.record(guideName: "KFOO", snq: i) }
        let stats = store.stats(guideName: "KFOO")
        #expect(stats?.windowCount == 20)
        #expect(stats?.totalCount == 30)
        // Window is samples 11...30 → min 11, max 30.
        #expect(stats?.min == 11)
        #expect(stats?.max == 30)
    }

    @Test func stats_unknownChannel_returnsNil() {
        let store = makeStore()
        #expect(store.stats(guideName: "NEVER-RECORDED") == nil)
    }

    @Test func needsSample_noHistory_isTrue() {
        let store = makeStore()
        #expect(store.needsSample(guideName: "KFOO") == true)
    }

    @Test func needsSample_freshPoorSignal_isFalse() {
        let store = makeStore()
        store.record(guideName: "KFOO", snq: 10)  // poor bucket
        #expect(store.needsSample(guideName: "KFOO") == false)
    }

    @Test func needsSample_freshGoodSignal_isFalse() {
        let store = makeStore()
        store.record(guideName: "KFOO", snq: 95)  // good bucket
        #expect(store.needsSample(guideName: "KFOO") == false)
    }

    @Test func flush_thenLoad_roundTripsHistory() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store1 = ChannelSignalStore(appSupportDir: dir)
        store1.record(guideName: "KFOO-HD", snq: 72)
        store1.flush()
        // flush() writes on a detached Task — give it a beat to land before reading it back.
        try? await Task.sleep(nanoseconds: 200_000_000)

        let store2 = ChannelSignalStore(appSupportDir: dir)
        await store2.load()
        #expect(store2.stats(guideName: "KFOO-HD")?.last == 72)
        #expect(store2.buckets["kfoo-hd"] != nil)
    }

    @Test func load_noExistingFile_isNoop() async {
        let store = makeStore()
        await store.load()
        #expect(store.buckets.isEmpty)
        #expect(store.stats(guideName: "anything") == nil)
    }
}
