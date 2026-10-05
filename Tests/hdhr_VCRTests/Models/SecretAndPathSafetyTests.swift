import Testing
import Foundation
@testable import hdhr_VCR

@Suite("Log secret redaction + safe path components")
struct SecretAndPathSafetyTests {

    @Test(arguments: [
        ("GET https://api.hdhomerun.com/api/guide.php?DeviceAuth=abc123XYZ&Start=1", "GET https://api.hdhomerun.com/api/guide.php?DeviceAuth=REDACTED&Start=1"),
        ("NETWORK ERROR: URLError \"https://x/guide.php?DeviceAuth=secret\" failed", "NETWORK ERROR: URLError \"https://x/guide.php?DeviceAuth=REDACTED\" failed"),
        ("a DeviceAuth=one and DeviceAuth=two end", "a DeviceAuth=REDACTED and DeviceAuth=REDACTED end"),
        ("DeviceAuth=tail", "DeviceAuth=REDACTED"),
        ("no secret here", "no secret here"),
        ("DeviceAuth=present", "DeviceAuth=REDACTED"),
    ] as [(input: String, expected: String)])
    func redaction(_ row: (input: String, expected: String)) {
        #expect(redactingSecrets(row.input) == row.expected)
    }

    @Test(arguments: [
        ("105404BE", "105404BE"),
        ("../../etc/passwd", "etcpasswd"),
        ("a/b\\c", "abc"),
        ("id\nX-Evil: 1", "idX-Evil1"),
        ("", "device"),
        ("////", "device"),
        ("my-relay_01", "my-relay_01"),
    ] as [(input: String, expected: String)])
    func safeComponent(_ row: (input: String, expected: String)) {
        #expect(row.input.safeFileComponent == row.expected)
    }

    @Test func safeComponent_isCappedAt64() {
        #expect(String(repeating: "a", count: 500).safeFileComponent.count == 64)
    }

    @Test func safeComponent_neverContainsAPathSeparatorOrDots() {
        for s in ["..", "../", "..\\..", "a.b", "~root", "/abs"] {
            let c = s.safeFileComponent
            #expect(!c.contains("/") && !c.contains("\\") && !c.contains("."))
        }
    }
}

@Suite("Show.posixPrimaryDir")
struct ShowPrimaryDirTests {
    @Test func offlineVolume_posixRecordDirFallsBack_butPosixPrimaryDirKeepsTheConfiguredFolder() {
        var s = Show.blank()
        s.show_dir = "/Volumes/DefinitelyNotMounted-\(UUID().uuidString)/DVR"
        s.show_temp_dir = Show.localFallbackDir
        #expect(s.posixRecordDir == Show.localFallbackDir)          // recording falls back while the volume is gone…
        #expect(s.posixPrimaryDir == s.show_dir)                    // …but the Edit form must keep showing/saving the real folder
    }

    @Test func legacyHFSPath_isConvertedToPosix() {
        var s = Show.blank()
        s.show_dir = "Raid6:DVR Tests:"
        #expect(s.posixPrimaryDir == "/Volumes/Raid6/DVR Tests")
    }

    @Test func emptyShowDir_meansLocalFallback() {
        var s = Show.blank(); s.show_dir = ""
        #expect(s.posixPrimaryDir == Show.localFallbackDir)
    }
}
