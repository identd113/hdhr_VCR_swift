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
