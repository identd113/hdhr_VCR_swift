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

@Suite("Triage T07 / T21 helpers")
struct TriageHelperTests {
    @Test func firstWinsOf_doesNotTrapOnADuplicateKey_andKeepsTheFirst() {
        let pairs = [("DEV1", 1), ("DEV2", 2), ("DEV1", 99)]
        let d = Dictionary(firstWinsOf: pairs)
        #expect(d.count == 2)
        #expect(d["DEV1"] == 1)
        #expect(d["DEV2"] == 2)
    }

    @Test func firstWinsOf_emptySequence() {
        let d: [String: Int] = Dictionary(firstWinsOf: [(String, Int)]())
        #expect(d.isEmpty)
    }

    @Test func lanDataSession_hasShortTimeouts_notTheSixtySecondDefault() {
        let c = HDHRManager.lanDataSession.configuration
        #expect(c.timeoutIntervalForRequest == LANFetch.requestTimeout)
        #expect(c.timeoutIntervalForRequest < 60)
        #expect(c.timeoutIntervalForResource == LANFetch.requestTimeout * 2)
    }
}


@Suite("Discord webhook token redaction + untrusted show titles")
struct WebhookAndTitleSafetyTests {
    @Test(arguments: [
        ("failed https://discord.com/api/webhooks/123456/abcDEF_-token ok",
         "failed https://discord.com/api/webhooks/123456/REDACTED ok"),
        ("NSErrorFailingURLStringKey=https://discord.com/api/webhooks/9/tok?wait=true)",
         "NSErrorFailingURLStringKey=https://discord.com/api/webhooks/9/REDACTED?wait=true)"),
        ("no secret here", "no secret here"),
        ("/webhooks/not-numeric/x", "/webhooks/not-numeric/x"),
    ] as [(input: String, expected: String)])
    func webhookTokensAreMasked(_ row: (input: String, expected: String)) {
        #expect(redactingSecrets(row.input) == row.expected)
    }

    @Test func bothSecretKindsRedactedInOneLine() {
        let out = redactingSecrets("a DeviceAuth=sek b https://discord.com/api/webhooks/1/tkn c")
        #expect(!out.contains("sek") && !out.contains("tkn"))
    }

    @Test(arguments: [
        ("..", ""), (".", ""), ("...hidden", "hidden"), ("  Seth Meyers \n", "Seth Meyers"),
        ("A\u{0000}B\u{0007}C", "ABC"), ("Normal Title", "Normal Title"),
    ] as [(input: String, expected: String)])
    func titleSanitizing(_ row: (input: String, expected: String)) {
        #expect(row.input.sanitizedShowTitle == row.expected)
    }

    @Test func overlongTitleIsCapped() {
        #expect(String(repeating: "x", count: 500).sanitizedShowTitle.count == 120)
    }
}
