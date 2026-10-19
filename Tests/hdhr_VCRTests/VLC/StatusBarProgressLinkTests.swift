import Testing
import Foundation
import Network
@testable import hdhr_VCR

// Status bar additions (docs/VLCPlayerView.md, "Status bar"): show progress, the FEED next-show lookup, and the
// Stream popover's connection details.

@Suite("PlayerStatusFormat progress")
struct StatusBarProgressTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func progress_isClampedToZeroAndOne() {
        let end = start.addingTimeInterval(1800)
        #expect(PlayerStatusFormat.progress(start: start, end: end, now: start.addingTimeInterval(-60)) == 0)
        #expect(PlayerStatusFormat.progress(start: start, end: end, now: start.addingTimeInterval(900)) == 0.5)
        #expect(PlayerStatusFormat.progress(start: start, end: end, now: end.addingTimeInterval(600)) == 1)
    }

    @Test func progress_zeroLengthShow_isZero() {
        #expect(PlayerStatusFormat.progress(start: start, end: start, now: start) == 0)
    }
}

@Suite("Status bar FEED next show")
@MainActor
struct StatusBarFeedLookupTests {
    @Test func titleMatchAtTheFileStart_findsTheChannelAndItsFollowingShows() {
        let store = GuideStore()
        let base = 1_800_000_000
        let chan = GuideChannel(GuideNumber: "5.1", GuideName: "KSTP", Guide: [
            GuideEntry(StartTime: base, EndTime: base + 1800, Title: "Seinfeld"),
            GuideEntry(StartTime: base + 1800, EndTime: base + 3600, Title: "Frasier"),
            GuideEntry(StartTime: base + 3600, EndTime: base + 5400, Title: "Cheers"),
        ])
        store.buildIndex(deviceId: "AAA", channels: [chan])
        // The relay reports when its recording file began; the lookup uses a moment just after it.
        let m = store.currentEntryByTitle("Seinfeld", at: Date(timeIntervalSince1970: TimeInterval(base + 60)))
        #expect(m?.channelNum == "5.1")
        let next = PlayerStatusFormat.upcoming(
            after: m!.entry,
            in: store.entries(deviceId: m!.deviceId, channelNum: m!.channelNum, after: m!.entry.endDate),
            now: Date(timeIntervalSince1970: TimeInterval(base + 60)))
        #expect(next.map(\.Title) == ["Frasier", "Cheers"])
    }

    @Test func aLaterAiringOfTheSameSeries_isNotPicked() {
        let store = GuideStore()
        let base = 1_800_000_000
        let chan = GuideChannel(GuideNumber: "5.1", GuideName: "KSTP", Guide: [
            GuideEntry(StartTime: base, EndTime: base + 1800, Title: "Seinfeld"),
            GuideEntry(StartTime: base + 7200, EndTime: base + 9000, Title: "Seinfeld"),
        ])
        store.buildIndex(deviceId: "AAA", channels: [chan])
        let m = store.currentEntryByTitle("Seinfeld", at: Date(timeIntervalSince1970: TimeInterval(base + 60)))
        #expect(m?.entry.StartTime == base)
    }
}

@Suite("NetworkLinkInfo")
struct NetworkLinkInfoTests {
    @Test func median_oddEvenEmpty() {
        #expect(NetworkLinkInfo.median([]) == nil)
        #expect(NetworkLinkInfo.median([9, 1, 5]) == 5)
        #expect(NetworkLinkInfo.median([1, 3]) == 2)
    }

    @Test func linkText_ethernetAndWifi() {
        #expect(NetworkLinkInfo(kind: .ethernet, linkMbps: 1000).linkText == "Ethernet · 1 Gbps")
        #expect(NetworkLinkInfo(kind: .ethernet, linkMbps: 100).linkText == "Ethernet · 100 Mbps")
        #expect(NetworkLinkInfo(kind: .wifi, linkMbps: 866, rssiDBm: -58).linkText == "Wi-Fi · 866 Mbps · -58 dBm")
        #expect(NetworkLinkInfo(kind: .unknown).linkText == "Unknown")
    }

    @Test func quality_theWorseOfPingAndSignalWins() {
        #expect(NetworkLinkInfo(kind: .ethernet, rttMs: 0.8).quality == .good)
        #expect(NetworkLinkInfo(kind: .ethernet, rttMs: 30).quality == .fair)
        #expect(NetworkLinkInfo(kind: .ethernet, rttMs: 80).quality == .poor)
        #expect(NetworkLinkInfo(kind: .wifi, rssiDBm: -80, rttMs: 3).quality == .poor)
        #expect(NetworkLinkInfo(kind: .wifi, rssiDBm: -55, rttMs: 3).quality == .good)
        #expect(NetworkLinkInfo(kind: .ethernet).quality == nil)
        // Signal only counts on Wi-Fi.
        #expect(NetworkLinkInfo(kind: .ethernet, rssiDBm: -90, rttMs: 2).quality == .good)
    }

    @Test func measure_againstALocalListener_reportsAPingAndTheLoopbackInterface() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { $0.start(queue: .global()); $0.cancel() }
        let ready = ReadyFlag()
        listener.stateUpdateHandler = { if case .ready = $0 { ready.set() } }
        listener.start(queue: .global())
        defer { listener.cancel() }
        for _ in 0..<100 where !ready.isSet { try await Task.sleep(for: .milliseconds(20)) }
        let port = try #require(listener.port?.rawValue)
        let info = await NetworkLinkProbe.measure(host: "127.0.0.1", port: port, samples: 2)
        #expect(info.rttMs != nil)
        #expect(info.interface != nil)
    }

    @Test func measure_nothingListening_leavesFieldsEmptyRatherThanThrowing() async {
        let info = await NetworkLinkProbe.measure(host: "127.0.0.1", port: 9, samples: 1)
        #expect(info.rttMs == nil)
    }
}

private final class ReadyFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

@Suite("Native size target (Zoom)")
struct NativeToggleTests {
    private let hd = CGSize(width: 1920, height: 1080)

    @Test func fits_goesToOneToOnePixels() {
        let t = VLCPlayerWindowManager.nativeTarget(pixels: hd, scale: 2, chrome: 44, visible: CGSize(width: 1600, height: 1000))
        #expect(t.divisor == 1)
        #expect(t.content == CGSize(width: 960, height: 540 + 44))
    }

    @Test func tooBig_goesToACleanHalf() {
        // 1:1 would be 1920×1124 on a 1:1 display; the screen is 1440×900 → half.
        let t = VLCPlayerWindowManager.nativeTarget(pixels: hd, scale: 1, chrome: 44, visible: CGSize(width: 1440, height: 900))
        #expect(t.divisor == 2)
        #expect(t.content == CGSize(width: 960, height: 540 + 44))
    }

    @Test func statusBarCountsAsChrome() {
        let t = VLCPlayerWindowManager.nativeTarget(pixels: hd, scale: 2, chrome: 96, visible: CGSize(width: 1600, height: 1000))
        #expect(t.content.height == CGFloat(636))
    }

    @Test func tinyDisplay_keepsHalving() {
        let t = VLCPlayerWindowManager.nativeTarget(pixels: hd, scale: 1, chrome: 44, visible: CGSize(width: 700, height: 500))
        #expect(t.divisor == 4)
    }
}

@Suite("PlayerStatusFormat detail line")
struct StatusBarDetailLineTests {
    @Test func synopsisWins_trimmed() {
        #expect(PlayerStatusFormat.detailLine(synopsis: "  A panda climbs a hill.  ", originalAirdate: 1_600_000_000) == "A panda climbs a hill.")
    }
    @Test func noSynopsis_fallsBackToFirstAired() {
        let text = PlayerStatusFormat.detailLine(synopsis: "", originalAirdate: 1_600_000_000)
        #expect(text?.hasPrefix("First aired ") == true)
    }
    @Test func newEpisode_withoutSynopsis_hasNoAirDate() {
        #expect(PlayerStatusFormat.detailLine(synopsis: nil, originalAirdate: 1_600_000_000, isNew: true) == nil)
        #expect(PlayerStatusFormat.detailLine(synopsis: "Plot.", originalAirdate: 1_600_000_000, isNew: true) == "Plot.")
    }
    @Test func neither_isNil() {
        #expect(PlayerStatusFormat.detailLine(synopsis: nil, originalAirdate: nil) == nil)
    }
}

@Suite("PlayerStatusFormat scale note")
struct StatusBarScaleNoteTests {
    private let file = CGSize(width: 1920, height: 1080)

    @Test func smallerAndLarger() {
        #expect(PlayerStatusFormat.scaleNote(displayed: CGSize(width: 1280, height: 720), native: file) == "33% smaller")
        #expect(PlayerStatusFormat.scaleNote(displayed: CGSize(width: 960, height: 540), native: file) == "50% smaller")
        #expect(PlayerStatusFormat.scaleNote(displayed: CGSize(width: 2880, height: 1620), native: file) == "50% larger")
    }

    @Test func sameSize_hasNoNote() {
        #expect(PlayerStatusFormat.scaleNote(displayed: file, native: file) == nil)
        #expect(PlayerStatusFormat.scaleNote(displayed: CGSize(width: 1925, height: 1083), native: file) == nil)   // rounds to 0%
    }

    @Test func missingSizes_haveNoNote() {
        #expect(PlayerStatusFormat.scaleNote(displayed: .zero, native: file) == nil)
        #expect(PlayerStatusFormat.scaleNote(displayed: file, native: .zero) == nil)
    }
}
