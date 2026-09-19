import Testing
@testable import hdhr_VCR

// Coverage for VLCPlayerView.reusesExistingTuner(...) — the pre-flight decision playChannel()
// (the in-window toolbar channel picker) uses to decide whether a channel switch can start
// immediately (same tuner slot already held) or needs a fresh AppState.tunerAvailable(...) check
// first (a genuinely new tuner request). Added 2026-09-19 after a real report: with a FEED
// primary (0 tuners held on this device) and the device already at its hardware limit from two
// other machines' recordings, picking a live channel silently hung instead of showing "All Tuners
// Busy" — because the old code always assumed same-device meant "just reuse the slot," which is
// false whenever the primary isn't actually a live-tuner connection on that device at all.
@Suite("VLCPlayerView.reusesExistingTuner")
struct VLCPlayerViewTunerReuseTests {

    private let targetDevice = "DEV1"

    @Test func liveChannelOnSameDevice_reusesTuner() {
        // The ordinary case: already tuned to something real on this device, switching channels.
        let result = VLCPlayerView.reusesExistingTuner(
            currentDeviceID: targetDevice, targetDeviceID: targetDevice,
            recordingShowId: nil, currentFeedRemoteURL: nil, currentURL: "http://1.2.3.4:5004/auto/v5.1")
        #expect(result == true)
    }

    @Test func feedPrimary_doesNotReuseTuner_evenOnSameDeviceID() {
        // The exact bug scenario: currentDeviceID happens to equal targetDeviceID (or is unset),
        // but the primary is a FEED — it holds zero real tuners on this device.
        let result = VLCPlayerView.reusesExistingTuner(
            currentDeviceID: targetDevice, targetDeviceID: targetDevice,
            recordingShowId: nil, currentFeedRemoteURL: "http://mac-mini.local:5004/auto/v2.1",
            currentURL: "http://127.0.0.1:1980/api/feed-local-relay?session=abc")
        #expect(result == false)
    }

    @Test func watchNowRelayPrimary_doesNotReuseTuner() {
        let result = VLCPlayerView.reusesExistingTuner(
            currentDeviceID: targetDevice, targetDeviceID: targetDevice,
            recordingShowId: "show-123", currentFeedRemoteURL: nil,
            currentURL: "http://127.0.0.1:1980/api/watch-recording?show=show-123")
        #expect(result == false)
    }

    @Test func differentDevice_doesNotReuseTuner() {
        // A live channel from a genuinely different device (e.g. swapped in via PiP from another
        // tuner) — currentDeviceID doesn't match this window's own device at all.
        let result = VLCPlayerView.reusesExistingTuner(
            currentDeviceID: "DEV2", targetDeviceID: targetDevice,
            recordingShowId: nil, currentFeedRemoteURL: nil, currentURL: "http://1.2.3.4:5004/auto/v5.1")
        #expect(result == false)
    }

    @Test func nothingPlayingYet_doesNotReuseTuner() {
        // No primary session at all — currentURL empty/nil must not be treated as "already holds a
        // slot," or the very first channel pick in a fresh standalone PiP-primary window would
        // skip the availability check it actually needs.
        #expect(VLCPlayerView.reusesExistingTuner(currentDeviceID: targetDevice, targetDeviceID: targetDevice,
                                                   recordingShowId: nil, currentFeedRemoteURL: nil, currentURL: nil) == false)
        #expect(VLCPlayerView.reusesExistingTuner(currentDeviceID: targetDevice, targetDeviceID: targetDevice,
                                                   recordingShowId: nil, currentFeedRemoteURL: nil, currentURL: "") == false)
    }

    @Test func currentDeviceIDNil_doesNotReuseTuner() {
        // No primary window/device tracked at all.
        let result = VLCPlayerView.reusesExistingTuner(
            currentDeviceID: nil, targetDeviceID: targetDevice,
            recordingShowId: nil, currentFeedRemoteURL: nil, currentURL: "http://1.2.3.4:5004/auto/v5.1")
        #expect(result == false)
    }

    // MARK: - Full truth table (all 16 combinations of the 4 boolean-ish inputs)

    // The individual-scenario tests above document *why* each of the four conditions matters; this
    // exhaustively cross-products all of them together (2^4 = 16 rows) against the function's own
    // definition (deviceMatches && recordingShowId == nil && currentFeedRemoteURL == nil &&
    // !currentURL.isEmpty), so a future edit that accidentally short-circuits on the wrong
    // combination of conditions (e.g. an `||` typo'd for `&&`) fails immediately rather than only on
    // whichever single combination a hand-picked case happened to cover. Shared by both playChannel
    // (primary) and playSecondaryChannel (secondary, added 2026-09-19) — see each call site's own
    // doc comment.
    private struct TunerReuseCase: CustomStringConvertible, Sendable {
        let deviceMatches: Bool
        let recordingShowIdSet: Bool
        let feedURLSet: Bool
        let currentURLSet: Bool
        var description: String {
            "device=\(deviceMatches) recording=\(recordingShowIdSet) feed=\(feedURLSet) url=\(currentURLSet)"
        }
        var expectedReuse: Bool { deviceMatches && !recordingShowIdSet && !feedURLSet && currentURLSet }
    }

    private static let allTunerReuseCases: [TunerReuseCase] = {
        var cases: [TunerReuseCase] = []
        for deviceMatches in [true, false] {
            for recordingShowIdSet in [true, false] {
                for feedURLSet in [true, false] {
                    for currentURLSet in [true, false] {
                        cases.append(TunerReuseCase(deviceMatches: deviceMatches, recordingShowIdSet: recordingShowIdSet,
                                                     feedURLSet: feedURLSet, currentURLSet: currentURLSet))
                    }
                }
            }
        }
        return cases
    }()

    @Test(arguments: allTunerReuseCases)
    private func fullTruthTable_matchesDefinitionExactly(_ c: TunerReuseCase) {
        let result = VLCPlayerView.reusesExistingTuner(
            currentDeviceID: c.deviceMatches ? targetDevice : "OTHER_DEVICE",
            targetDeviceID: targetDevice,
            recordingShowId: c.recordingShowIdSet ? "show-123" : nil,
            currentFeedRemoteURL: c.feedURLSet ? "http://mac-mini.local:5004/auto/v2.1" : nil,
            currentURL: c.currentURLSet ? "http://1.2.3.4:5004/auto/v5.1" : nil)
        #expect(result == c.expectedReuse, "\(c)")
    }

    @Test func exactlyOneOfSixteenCombinationsReusesTheTuner() {
        // Only device-matches + nothing-else-set + a real currentURL should ever skip the
        // availability check — every other one of the 16 combinations must run it.
        let reusing = Self.allTunerReuseCases.filter(\.expectedReuse)
        #expect(reusing.count == 1)
        #expect(reusing.first?.deviceMatches == true)
        #expect(reusing.first?.recordingShowIdSet == false)
        #expect(reusing.first?.feedURLSet == false)
        #expect(reusing.first?.currentURLSet == true)
    }
}
