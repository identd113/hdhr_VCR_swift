import Testing
import Foundation
@testable import hdhr_VCR

// Covers Show.init(from:)'s self-healing repair of a prior bug where the native Add/Edit Show
// dialogs set show_temp_dir to the exact same folder as show_dir, leaving posixRecordDir nowhere
// real to fall back to if that folder's volume went offline (see AddShowView.swift/
// EditShowView.swift and Models.swift's Show.localFallbackDir).
struct ShowDecodingTests {

    private func decode(showDir: String, tempDir: String) throws -> Show {
        let json = """
        {"show_id":"x","show_title":"Test","show_dir":"\(showDir)","show_temp_dir":"\(tempDir)"}
        """
        return try JSONDecoder().decode(Show.self, from: Data(json.utf8))
    }

    // One (tempDir → expected show_temp_dir) table — show_dir is fixed at the same custom path
    // across every row; only the on-disk tempDir value and the expected repaired result vary.
    @Test(arguments: [
        ("/Volumes/Raid6/DVR Tests", Show.localFallbackDir),  // repairsTempDirMatchingCustomShowDir
        (Show.localFallbackDir,      Show.localFallbackDir),  // leavesGenuinelyDistinctTempDirAlone
        ("",                         ""),                     // leavesEmptyTempDirAlone
    ] as [(tempDir: String, expected: String)])
    func tempDirRepair(_ row: (tempDir: String, expected: String)) throws {
        let show = try decode(showDir: "/Volumes/Raid6/DVR Tests", tempDir: row.tempDir)
        #expect(show.show_temp_dir == row.expected)
    }

    // A "both already Show.localFallbackDir" case was deliberately not added here: the repair
    // guard is `decodedTempDir == show_dir && show_dir != Show.localFallbackDir ? fallback :
    // decodedTempDir` — when show_dir already equals the fallback, that third clause is false,
    // but the repair and no-repair branches produce the identical value (fallback) regardless.
    // No input exercises that clause's correctness for this scenario; a test asserting the
    // output there would pass identically whether the clause were correct, inverted, or deleted.
}
