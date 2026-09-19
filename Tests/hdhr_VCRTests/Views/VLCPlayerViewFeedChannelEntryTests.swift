import Testing
@testable import hdhr_VCR

// Coverage for VLCPlayerView.feedChannelEntry(remoteURL:remoteRelayEntries:) — synthesizes the
// channel picker's "Live" row for a FEED that became primary via a cross-device PiP swap (the
// window's own `device`/`lineup` stay bound to whichever device it originally opened on, so a
// swapped-in FEED from a *different* source Mac has no entry in `lineup` to resolve against at
// all — see docs/VLCPlayerView.md's "cross-device swap" note). Found live 2026-09-19: without
// this, the picker just showed the plain favorites/rest list with nothing selected.
@Suite("VLCPlayerView.feedChannelEntry")
struct VLCPlayerViewFeedChannelEntryTests {

    private func makeDevice(id: String = "SOURCEMAC") -> HDHRDevice {
        HDHRDevice(DeviceID: id, LocalIP: "192.168.1.50", BaseURL: "http://192.168.1.50",
                   TunerCount: 2, FirmwareVersion: nil, DeviceAuth: nil)
    }

    @Test func nilRemoteURL_returnsNil() {
        let device = makeDevice()
        let entries = [(device: device, entry: LineupEntry(GuideNumber: "2.1", GuideName: "KVUE",
                                                             URL: "http://192.168.1.50:5004/auto/v2.1", HD: 1, Favorite: nil))]
        #expect(VLCPlayerView.feedChannelEntry(deviceIsVirtualRelay: false, remoteURL: nil, remoteRelayEntries: entries) == nil)
    }

    @Test func noMatchingEntry_returnsNil() {
        let device = makeDevice()
        let entries = [(device: device, entry: LineupEntry(GuideNumber: "2.1", GuideName: "KVUE",
                                                             URL: "http://192.168.1.50:5004/auto/v2.1", HD: 1, Favorite: nil))]
        let result = VLCPlayerView.feedChannelEntry(deviceIsVirtualRelay: false,
                                                      remoteURL: "http://192.168.1.50:5004/auto/v9.9", remoteRelayEntries: entries)
        #expect(result == nil)
    }

    @Test func emptyRemoteRelayEntries_returnsNil() {
        #expect(VLCPlayerView.feedChannelEntry(deviceIsVirtualRelay: false,
                                                remoteURL: "http://192.168.1.50:5004/auto/v2.1", remoteRelayEntries: []) == nil)
    }

    // Found in code review 2026-09-19: a direct FEED open already has device.isVirtualRelay ==
    // true and resolves through syncChannel(to:)'s own lineup-matching path instead — without this
    // gate, the toolbar Picker would show a second, duplicate "FEED ..." row for the same content
    // whenever a matching remoteRelayEntries URL happened to also equal currentFeedRemoteURL.
    @Test func deviceIsVirtualRelay_returnsNilEvenWithAMatchingEntry() {
        let device = makeDevice()
        let url = "http://192.168.1.50:5004/auto/v2.1"
        var entry = LineupEntry(GuideNumber: "2.1", GuideName: "KVUE", URL: url, HD: 1, Favorite: nil)
        entry.virtualRelayShowTitle = "The Tonight Show"
        let result = VLCPlayerView.feedChannelEntry(deviceIsVirtualRelay: true, remoteURL: url, remoteRelayEntries: [(device, entry)])

        #expect(result == nil)
    }

    @Test func matchingEntry_usesVirtualRelayShowTitleWhenPresent() {
        let device = makeDevice()
        let url = "http://192.168.1.50:5004/auto/v2.1"
        var entry = LineupEntry(GuideNumber: "2.1", GuideName: "KVUE", URL: url, HD: 1, Favorite: nil)
        entry.virtualRelayShowTitle = "The Tonight Show"
        let result = VLCPlayerView.feedChannelEntry(deviceIsVirtualRelay: false, remoteURL: url, remoteRelayEntries: [(device, entry)])

        #expect(result?.GuideName == "FEED  The Tonight Show")
    }

    @Test func matchingEntry_fallsBackToGuideNameWhenNoShowTitle() {
        let device = makeDevice()
        let url = "http://192.168.1.50:5004/auto/v2.1"
        let entry = LineupEntry(GuideNumber: "2.1", GuideName: "KVUE", URL: url, HD: 1, Favorite: nil)
        let result = VLCPlayerView.feedChannelEntry(deviceIsVirtualRelay: false, remoteURL: url, remoteRelayEntries: [(device, entry)])

        #expect(result?.GuideName == "FEED  KVUE")
    }

    @Test func matchingEntry_appendsSourceHostnameWhenPresent() {
        let device = makeDevice()
        let url = "http://192.168.1.50:5004/auto/v2.1"
        var entry = LineupEntry(GuideNumber: "2.1", GuideName: "KVUE", URL: url, HD: 1, Favorite: nil)
        entry.virtualRelayShowTitle = "The Tonight Show"
        entry.virtualRelaySourceHostname = "woodflix.local"
        let result = VLCPlayerView.feedChannelEntry(deviceIsVirtualRelay: false, remoteURL: url, remoteRelayEntries: [(device, entry)])

        #expect(result?.GuideName == "FEED  The Tonight Show — woodflix.local")
    }

    @Test func guideNumberUsesLiveFeedPrefixAndTheRemoteURL_soItCanNeverCollideWithARealChannel() {
        // LineupEntry's Hashable/Equatable keys solely on GuideNumber (AddShowView.swift) — this
        // synthetic entry must use a GuideNumber no real channel could ever have.
        let device = makeDevice()
        let url = "http://192.168.1.50:5004/auto/v2.1"
        let entry = LineupEntry(GuideNumber: "2.1", GuideName: "KVUE", URL: url, HD: 1, Favorite: nil)
        let result = VLCPlayerView.feedChannelEntry(deviceIsVirtualRelay: false, remoteURL: url, remoteRelayEntries: [(device, entry)])

        #expect(result?.GuideNumber == "\(VLCPlayerView.liveFeedGuideNumberPrefix)\(url)")
        #expect(result?.GuideNumber.hasPrefix(VLCPlayerView.liveFeedGuideNumberPrefix) == true)
    }

    @Test func matchesTheCorrectEntryAmongMultipleRelays() {
        let deviceA = makeDevice(id: "MACA")
        let deviceB = makeDevice(id: "MACB")
        let urlA = "http://192.168.1.50:5004/auto/v2.1"
        let urlB = "http://192.168.1.51:5004/auto/v5.1"
        var entryA = LineupEntry(GuideNumber: "2.1", GuideName: "A", URL: urlA, HD: 1, Favorite: nil)
        entryA.virtualRelayShowTitle = "Show A"
        var entryB = LineupEntry(GuideNumber: "5.1", GuideName: "B", URL: urlB, HD: 1, Favorite: nil)
        entryB.virtualRelayShowTitle = "Show B"

        let result = VLCPlayerView.feedChannelEntry(deviceIsVirtualRelay: false, remoteURL: urlB,
                                                      remoteRelayEntries: [(deviceA, entryA), (deviceB, entryB)])

        #expect(result?.GuideName == "FEED  Show B")
    }
}
