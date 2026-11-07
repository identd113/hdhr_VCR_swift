import Foundation
import Testing
@testable import hdhr_VCR

// `GET /lineup.json?tuning` (docs/EndpointDiscoveryLog.md): per-channel RF tuning, used to skip RF channels the tuner's lineup already
// covers in the daily channel-list scan. Without tuning data everything is scanned, as before.

struct LineupTuningTests {
    private func entry(_ num: String, freq: Int?, url: String = "http://10.0.0.5:5004/auto/v") -> LineupEntry {
        LineupEntry(GuideNumber: num, GuideName: "ch\(num)", URL: url + num, HD: 1, Favorite: nil, VideoCodec: nil, AudioCodec: nil, Frequency: freq)
    }

    @Test func tuningFieldsDecodeFromTheDeviceJSON() throws {
        let json = #"[{"GuideNumber":"2.1","GuideName":"MNPBS","URL":"http://10.0.0.5:5004/auto/v2.1","HD":1,"TransportStreamID":1605,"Modulation":"8vsb","Frequency":593000000,"ProgramNumber":3}]"#
        let e = try JSONDecoder().decode([LineupEntry].self, from: Data(json.utf8))[0]
        #expect(e.Frequency == 593_000_000 && e.ProgramNumber == 3 && e.TransportStreamID == 1605 && e.Modulation == "8vsb")
    }

    @Test func aPlainLineupStillDecodesWithNilTuning() throws {
        let json = #"[{"GuideNumber":"2.1","GuideName":"MNPBS","URL":"http://10.0.0.5:5004/auto/v2.1"}]"#
        let e = try JSONDecoder().decode([LineupEntry].self, from: Data(json.utf8))[0]
        #expect(e.Frequency == nil && e.ProgramNumber == nil)
    }

    @Test func coveredChannelsAreSkipped_theRestAreScanned() throws {
        // 593 MHz = RF 34, 575 MHz = RF 31
        let rfs = try #require(OTAScanner.rfChannelsNotCovered(by: [entry("2.1", freq: 593_000_000), entry("11.1", freq: 575_000_000)]))
        #expect(!rfs.contains(34) && !rfs.contains(31))
        #expect(rfs.contains(19) && rfs.contains(2) && rfs.contains(51))
        #expect(rfs.count == OTAScanner.allRFChannels.count - 2)
    }

    @Test func noTuningDataMeansScanEverything() {
        #expect(OTAScanner.rfChannelsNotCovered(by: [entry("2.1", freq: nil)]) == nil)
        #expect(OTAScanner.rfChannelsNotCovered(by: []) == nil)
    }

    @Test func airTunedEntriesDoNotCountAsCovered() {
        let air = entry("19.1", freq: 503_000_000, url: "http://10.0.0.5:5004/auto/ch503000000-")
        #expect(OTAScanner.rfChannelsNotCovered(by: [air]) == nil)
    }
}

// `GET /lineup_status.json`: ScanInProgress tells a rescanning tuner's empty lineup from a failed fetch.
struct LineupStatusTests {
    @Test func decodesTheDevicesBody() {
        let s = HDHRManager.LineupStatus.decode(Data(#"{"ScanInProgress":0,"ScanPossible":1,"Source":"Antenna","SourceList":["Antenna","Cable"]}"#.utf8))
        #expect(s == .init(scanInProgress: false, scanPossible: true, source: "Antenna"))
    }
    @Test func aScanInProgressReadsTrue() {
        #expect(HDHRManager.LineupStatus.decode(Data(#"{"ScanInProgress":1,"ScanPossible":0}"#.utf8))?.scanInProgress == true)
    }
    @Test func aBodyThatIsNotJSONIsNil() {
        #expect(HDHRManager.LineupStatus.decode(Data("<html>".utf8)) == nil)
    }
}
