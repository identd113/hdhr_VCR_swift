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
