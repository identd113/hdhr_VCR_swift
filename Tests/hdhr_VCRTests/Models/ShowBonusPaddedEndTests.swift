import Testing
import Foundation
@testable import hdhr_VCR

// Bonus Time's "already padded" marker must survive a relaunch (it lives on Show, not in the
// in-memory showRuntime), or a mid-airing restart pads the already-padded show_end a second time.
@Suite("Show.show_bonus_padded_end persistence")
struct ShowBonusPaddedEndTests {
    @Test func roundTripsThroughCodable() throws {
        var show = Show.blank(channel: "5.1", device: "DEV1")
        let padded = Date(timeIntervalSince1970: 1_800_000_000)
        show.show_bonus_padded_end = padded
        let data = try JSONEncoder().encode(show)
        let back = try JSONDecoder().decode(Show.self, from: data)
        #expect(back.show_bonus_padded_end == padded)
    }

    @Test func oldConfigWithoutTheKey_decodesToNil() throws {
        let show = Show.blank(channel: "5.1", device: "DEV1")
        var obj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(show)) as? [String: Any])
        obj.removeValue(forKey: "show_bonus_padded_end")
        let back = try JSONDecoder().decode(Show.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(back.show_bonus_padded_end == nil)
    }
}

// A show still holding a legacy HFS colon path ("Vol:Dir:", migrated from the AppleScript app) must
// not be reported as "recording to fallback" while its volume is mounted — the old comparison
// (posixRecordDir vs the raw show_dir string) always differed for HFS strings.
@Suite("Show.isRecordingToFallback")
struct ShowRecordingFallbackTests {
    @Test func hfsPathOnMountedVolume_isNotFallback() {
        var show = Show.blank(channel: "5.1", device: "DEV1")
        show.show_dir = "ZZTestDir:"          // -> /Volumes/ZZTestDir, parent /Volumes always exists
        show.show_temp_dir = Show.localFallbackDir
        #expect(show.posixRecordDir == "/Volumes/ZZTestDir")
        #expect(!show.isRecordingToFallback)
    }

    @Test func offlineVolume_isFallback() {
        var show = Show.blank(channel: "5.1", device: "DEV1")
        show.show_dir = "ZZNoSuchVolume:Dir:" // parent /Volumes/ZZNoSuchVolume is absent
        show.show_temp_dir = Show.localFallbackDir
        #expect(show.isRecordingToFallback)
        #expect(show.posixRecordDir == Show.localFallbackDir)
    }

    @Test func emptyShowDir_isNotFallback() {
        #expect(!Show.blank().isRecordingToFallback)
    }
}
