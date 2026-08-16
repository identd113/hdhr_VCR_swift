import Testing
import Foundation
@testable import hdhr_VCR

// MARK: - ConfigManager date decoding + legacy config compatibility
//
// ConfigManager's custom dateDecodingStrategy accepts three on-disk shapes — v2 ISO8601
// strings, v1 string epochs ("1748613600"), and v1 numeric epochs — and treats sentinel
// junk ("missing value", "0", "") as nil rather than a decode failure. A regression here
// doesn't error loudly: `try?` in Show.init(from:) turns a broken date parse into a nil
// show_next, which silently unschedules every show in an old config on first launch after
// an update. Exercised through the real load() path (init(appSupportDir:) test seam +
// configPath) so the ConfigFile wrapper and the "the_shows" v1 key stay covered too.

@Suite("ConfigManager date decoding")
struct ConfigManagerDateDecodingTests {

    private func makeManager() -> (ConfigManager, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hdhrCfgTest-\(UUID().uuidString)")
        return (ConfigManager(appSupportDir: dir), dir)
    }

    private func write(_ json: String, to manager: ConfigManager) throws {
        try Data(json.utf8).write(to: URL(fileURLWithPath: manager.configPath))
    }

    // Config_version "2" everywhere below keeps maybeUpgrade() from re-saving mid-test,
    // except the legacy-key test, where exercising the v1→v2 upgrade is the point.

    // The three accepted on-disk date shapes, as one parameterized table — the bodies were
    // identical except for the JSON literal. The ISO row's epoch is 2026-01-01T00:00:00Z.
    @Test(arguments: [
        (jsonValue: #""2026-01-01T00:00:00Z""#, expectedEpoch: 1_767_225_600.0),  // v2 ISO8601
        (jsonValue: #""1786457465""#,           expectedEpoch: 1_786_457_465.0),  // v1 string epoch
        (jsonValue: "1786457465",               expectedEpoch: 1_786_457_465.0),  // v1 numeric epoch
    ])
    func allThreeDateShapes_decode(_ row: (jsonValue: String, expectedEpoch: Double)) throws {
        let (mgr, dir) = makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(#"""
        {"config": {"Config_version": "2"},
         "shows": [{"show_id": "a", "show_title": "T", "show_next": \#(row.jsonValue)}]}
        """#, to: mgr)
        let file = mgr.load()
        #expect(file?.shows.first?.show_next == Date(timeIntervalSince1970: row.expectedEpoch))
    }

    @Test func sentinelJunkDates_decodeAsNil_notAsFailure() throws {
        // AppleScript-era configs wrote "missing value" / "0" / "" into date slots. The
        // strategy must throw for the field (so Show's `try?` yields nil) WITHOUT sinking
        // the whole Show or ConfigFile decode.
        let (mgr, dir) = makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(#"""
        {"config": {"Config_version": "2"},
         "shows": [{"show_id": "a", "show_title": "Junk", "show_next": "missing value",
                    "show_end": "0", "show_last": ""}]}
        """#, to: mgr)
        let file = mgr.load()
        let show = file?.shows.first
        #expect(show != nil, "junk dates must not sink the whole config decode")
        #expect(show?.show_title == "Junk")
        #expect(show?.show_next == nil)
        #expect(show?.show_end == nil)
        #expect(show?.show_last == nil)
    }

    @Test func v1LegacyShowsKey_decodesAndUpgrades() throws {
        // v1 stored the show array under "the_shows"; ConfigFile's custom init falls back to
        // it, and load()'s maybeUpgrade() rewrites the file as v2 in place.
        let (mgr, dir) = makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(#"""
        {"config": {"Config_version": "1"},
         "the_shows": [{"show_id": "a", "show_title": "Legacy", "show_next": "1786457465"}]}
        """#, to: mgr)
        let file = mgr.load()
        #expect(file?.shows.first?.show_title == "Legacy")
        #expect(file?.config.Config_version == "2", "load() must upgrade a v1 file to v2")
        // The upgrade re-saves — a second load must round-trip the same show through the
        // v2 encoder/decoder pair.
        let reloaded = mgr.load()
        #expect(reloaded?.shows.first?.show_title == "Legacy")
        #expect(reloaded?.shows.first?.show_next == Date(timeIntervalSince1970: 1_786_457_465))
    }
}
