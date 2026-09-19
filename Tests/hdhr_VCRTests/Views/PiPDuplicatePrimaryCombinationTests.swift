import Testing
@testable import hdhr_VCR

// Combinatorial coverage tying together every "is the thing I'm about to add as a PiP secondary
// already playing as the primary?" check — AppState.watchAsSecondary/watchRemoteRelayAsSecondary/
// watchRecordingInAppAsSecondary (added 2026-09-19, commit f9f2007) each reuse exactly one of
// PiPPickerView.isCurrentLiveChannel/isCurrentFeed/isCurrentRecording rather than a private copy,
// so the picker's own row-dimming and the functional refusal guard can never drift apart. The
// existing PiPPickerViewIsCurrentTests suite covers each function in isolation with hand-picked
// cases; this suite instead cross-products every "what's currently primary" scenario against every
// "what's being requested as secondary" scenario, proving each guard fires for its own exact match
// and stays silent for every other primary state — not just the one case each function's own name
// happens to describe.
@Suite("PiP duplicate-primary refusal — full scenario cross-product")
struct PiPDuplicatePrimaryCombinationTests {

    // One row per realistic "what's currently playing as primary" snapshot. `nothing` covers the
    // standalone-PiP case (no primary at all — PiPPickerView opened directly); the other three
    // cover the three actual primary content types AppState can have open.
    private struct PrimaryScenario: CustomStringConvertible, Sendable {
        let name: String
        let deviceID: String?
        let channelNumber: String?
        let feedRemoteURL: String?
        let recordingShowId: String?
        var description: String { name }
    }

    private static let nothing = PrimaryScenario(
        name: "nothing playing", deviceID: nil, channelNumber: nil, feedRemoteURL: nil, recordingShowId: nil)
    private static let liveChannel = PrimaryScenario(
        name: "live channel DEV1/5.1", deviceID: "DEV1", channelNumber: "5.1", feedRemoteURL: nil, recordingShowId: nil)
    private static let feed = PrimaryScenario(
        name: "FEED mac-mini v2.1", deviceID: "DEV1", channelNumber: nil,
        feedRemoteURL: "http://mac-mini.local:5004/auto/v2.1", recordingShowId: nil)
    private static let recording = PrimaryScenario(
        name: "Watch Now recording show-123", deviceID: "DEV1", channelNumber: nil, feedRemoteURL: nil,
        recordingShowId: "show-123")

    // A live channel on the SAME device as `liveChannel`/`feed`/`recording` above but a DIFFERENT
    // channel number — makes sure a device-only match (ignoring channel) can never slip through.
    private static let liveChannelOtherNumber = PrimaryScenario(
        name: "live channel DEV1/9.1", deviceID: "DEV1", channelNumber: "9.1", feedRemoteURL: nil, recordingShowId: nil)
    // Same device, but the FEED source is a different Mac than the canonical `feed` scenario.
    private static let feedOtherSource = PrimaryScenario(
        name: "FEED other-mac v2.1", deviceID: "DEV1", channelNumber: nil,
        feedRemoteURL: "http://other-mac.local:5004/auto/v2.1", recordingShowId: nil)
    private static let recordingOtherShow = PrimaryScenario(
        name: "Watch Now recording show-999", deviceID: "DEV1", channelNumber: nil, feedRemoteURL: nil,
        recordingShowId: "show-999")

    private static let allPrimaries = [nothing, liveChannel, feed, recording, liveChannelOtherNumber, feedOtherSource, recordingOtherShow]

    // MARK: - Requesting a live channel (DEV1/5.1) as secondary

    @Test(arguments: allPrimaries)
    private func requestingLiveChannel_refusedOnlyWhenPrimaryIsThatExactChannel(_ primary: PrimaryScenario) {
        let result = PiPPickerView.isCurrentLiveChannel(
            currentDeviceID: primary.deviceID, currentChannelNumber: primary.channelNumber,
            targetDeviceID: "DEV1", targetChannelNumber: "5.1")
        let shouldRefuse = primary.deviceID == "DEV1" && primary.channelNumber == "5.1"
        #expect(result == shouldRefuse, "primary=\(primary.name)")
    }

    // MARK: - Requesting the FEED from mac-mini v2.1 as secondary

    @Test(arguments: allPrimaries)
    private func requestingFeed_refusedOnlyWhenPrimaryIsThatExactFeed(_ primary: PrimaryScenario) {
        let targetURL = "http://mac-mini.local:5004/auto/v2.1"
        let result = PiPPickerView.isCurrentFeed(currentFeedRemoteURL: primary.feedRemoteURL, entryURL: targetURL)
        let shouldRefuse = primary.feedRemoteURL == targetURL
        #expect(result == shouldRefuse, "primary=\(primary.name)")
    }

    // MARK: - Requesting the recording show-123 as secondary

    @Test(arguments: allPrimaries)
    private func requestingRecording_refusedOnlyWhenPrimaryIsThatExactRecording(_ primary: PrimaryScenario) {
        let targetShowId = "show-123"
        let result = PiPPickerView.isCurrentRecording(recordingShowId: primary.recordingShowId, showId: targetShowId)
        let shouldRefuse = primary.recordingShowId == targetShowId
        #expect(result == shouldRefuse, "primary=\(primary.name)")
    }

    // MARK: - Sanity: exactly one primary scenario ever refuses each request type

    // Guards against a future scenario fixture change accidentally making two rows "match" the
    // same target, which would silently defeat the point of the cross-product above.
    @Test func exactlyOnePrimaryScenarioMatchesEachRequestType() {
        let liveMatches = Self.allPrimaries.filter {
            PiPPickerView.isCurrentLiveChannel(currentDeviceID: $0.deviceID, currentChannelNumber: $0.channelNumber,
                                                targetDeviceID: "DEV1", targetChannelNumber: "5.1")
        }
        #expect(liveMatches.map(\.name) == [Self.liveChannel.name])

        let feedMatches = Self.allPrimaries.filter {
            PiPPickerView.isCurrentFeed(currentFeedRemoteURL: $0.feedRemoteURL, entryURL: "http://mac-mini.local:5004/auto/v2.1")
        }
        #expect(feedMatches.map(\.name) == [Self.feed.name])

        let recordingMatches = Self.allPrimaries.filter {
            PiPPickerView.isCurrentRecording(recordingShowId: $0.recordingShowId, showId: "show-123")
        }
        #expect(recordingMatches.map(\.name) == [Self.recording.name])
    }
}
