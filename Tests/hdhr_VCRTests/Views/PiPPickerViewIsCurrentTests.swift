import Testing
@testable import hdhr_VCR

// Coverage for PiPPickerView's three isCurrent* decisions — each row's "is this already playing as
// the primary stream" check, which drives dimming it to 40% opacity and swapping its "Add as PIP"
// button for a plain "Now Playing" label (added 2026-09-19, so the picker never offers to add
// something alongside itself).
@Suite("PiPPickerView isCurrent checks")
struct PiPPickerViewIsCurrentTests {

    // MARK: isCurrentRecording

    @Test func isCurrentRecording_matchingShowId_isTrue() {
        #expect(PiPPickerView.isCurrentRecording(recordingShowId: "abc123", showId: "abc123") == true)
    }

    @Test func isCurrentRecording_differentShowId_isFalse() {
        #expect(PiPPickerView.isCurrentRecording(recordingShowId: "abc123", showId: "xyz789") == false)
    }

    @Test func isCurrentRecording_nilRecordingShowId_isFalse() {
        // Primary isn't a Watch Now relay at all (e.g. a live channel or FEED) — must never match.
        #expect(PiPPickerView.isCurrentRecording(recordingShowId: nil, showId: "abc123") == false)
    }

    // MARK: isCurrentLiveChannel

    @Test func isCurrentLiveChannel_matchingDeviceAndChannel_isTrue() {
        #expect(PiPPickerView.isCurrentLiveChannel(currentDeviceID: "DEV1", currentChannelNumber: "5.1",
                                                    targetDeviceID: "DEV1", targetChannelNumber: "5.1") == true)
    }

    @Test func isCurrentLiveChannel_sameDeviceDifferentChannel_isFalse() {
        #expect(PiPPickerView.isCurrentLiveChannel(currentDeviceID: "DEV1", currentChannelNumber: "5.1",
                                                    targetDeviceID: "DEV1", targetChannelNumber: "7.1") == false)
    }

    @Test func isCurrentLiveChannel_sameChannelNumberDifferentDevice_isFalse() {
        // A channel "5.1" on a different physical tuner is not the same stream — both device and
        // channel number must match, not just one.
        #expect(PiPPickerView.isCurrentLiveChannel(currentDeviceID: "DEV2", currentChannelNumber: "5.1",
                                                    targetDeviceID: "DEV1", targetChannelNumber: "5.1") == false)
    }

    @Test func isCurrentLiveChannel_nothingPlaying_isFalse() {
        #expect(PiPPickerView.isCurrentLiveChannel(currentDeviceID: nil, currentChannelNumber: nil,
                                                    targetDeviceID: "DEV1", targetChannelNumber: "5.1") == false)
    }

    // MARK: isCurrentFeed

    @Test func isCurrentFeed_matchingURL_isTrue() {
        let url = "http://mac-mini.local:5004/auto/v2.1"
        #expect(PiPPickerView.isCurrentFeed(currentFeedRemoteURL: url, entryURL: url) == true)
    }

    @Test func isCurrentFeed_differentURL_isFalse() {
        #expect(PiPPickerView.isCurrentFeed(currentFeedRemoteURL: "http://mac-mini.local:5004/auto/v2.1",
                                             entryURL: "http://mac-mini.local:5004/auto/v9.1") == false)
    }

    @Test func isCurrentFeed_noFeedPlaying_isFalse() {
        #expect(PiPPickerView.isCurrentFeed(currentFeedRemoteURL: nil, entryURL: "http://mac-mini.local:5004/auto/v2.1") == false)
    }

    @Test func isCurrentFeed_entryURLNil_isFalse() {
        // A lineup entry with no URL at all must never accidentally match a nil currentFeedRemoteURL.
        #expect(PiPPickerView.isCurrentFeed(currentFeedRemoteURL: nil, entryURL: nil) == false,
                "two nils must not read as 'the same feed' — there is no feed playing in that state")
    }
}
