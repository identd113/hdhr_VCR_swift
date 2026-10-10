import Testing
import Foundation
import Security
@testable import hdhr_VCR

// The advance warning for the guide service's certificate (2026-10-09: SiliconDust's *.hdhomerun.com
// certificate expired). The probe itself needs a network, so the pieces around it are tested here.
@Suite("CertificateExpiry")
struct CertificateExpiryTests {
    // A throwaway self-signed certificate (CN=hdhrvcr-test) whose notAfter is Jul 13 00:32:22 2081 GMT
    // = epoch 3519592342, generated with openssl for this test.
    private static let testCertDER = "MIIC8DCCAdigAwIBAgIUQ2Tre3o7EOA5wMf9ib1ENu7RgxQwDQYJKoZIhvcNAQELBQAwFzEVMBMGA1UEAwwMaGRocnZjci10ZXN0MCAXDTI2MTAxMDAwMzIyMloYDzIwODEwNzEzMDAzMjIyWjAXMRUwEwYDVQQDDAxoZGhydmNyLXRlc3QwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDEmNyk3XsHxFAlPUXGgTtjWrAX73PmmNS2e3LBVnMelYs+UJxPrGbzNMtNk2QznZxms4m1iaKmuXHkfU9JHAQtchpyQP8LyjEykUEpwIZfcUpUKo+Sm/PacfSXkywcHZgo/A+2+NgVM1sGBIX+851+NwbNcYYE4SwSfYDxclW71wH/3Sug9yGjJGNo05ov9QQN0RrIlHtx3Wdy08Hi+3dkPpPcZzyKRMtZo97RkBQMA35Uy1aeZxpYY6Lo+siVGm2naqAGmW8Gv/lKhjEjSD0Y2LKE4qUbv2IFdnkpTREWTo8mfxr8uC2zg9tY0lKPB1YxRJn1SvWNS1OjH/K5Iaw5AgMBAAGjMjAwMB0GA1UdDgQWBBSHv8ABwOU0xIbrvKWwNySuWxhTVTAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4IBAQCgxc9dEXJfewboU1DJZem5RqzfS6sRxmuMdSM7AaUgrJQXsDgn2VxwTv2PG/ohd9BTuF+edaYPWFHOvgypd/4hpXW1eqQ4AKOV06GNEEgLQ3PJsYDnDi4hdld3kAxWMPFJqiCukPquPhgW+ZfTPmp4az1hIbdO7dsxYOAJgkoWj9M3vWf+hONtsf26B8G8El+gT0yNPlGWWYIozjvYkgISZgSg81tAP2JYzO6NlMUIFkZW87xjWjYPt2pPP0xU4pg5zcSbjhLEavggx6SZupqhMcz8pM6UpT9sb3TOBbC9fI5prvJgEA40VgruZdnm1u8v0FlRY9+D1VQSDAsbnOHd"
    private static let testCertNotAfter: TimeInterval = 3_519_592_342

    @Test func notAfter_readsTheRealDateFromACertificate() throws {
        let der = try #require(Data(base64Encoded: Self.testCertDER))
        let cert = try #require(SecCertificateCreateWithData(nil, der as CFData))
        let date = try #require(CertificateExpiry.notAfter(of: cert))
        #expect(abs(date.timeIntervalSince1970 - Self.testCertNotAfter) < 2)
    }

    @Test func daysLeft_isWholeDaysRoundedDown() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(CertificateExpiry.daysLeft(until: now.addingTimeInterval(14 * 86_400 + 60), from: now) == 14)
        #expect(CertificateExpiry.daysLeft(until: now.addingTimeInterval(13.5 * 86_400), from: now) == 13)
        #expect(CertificateExpiry.daysLeft(until: now.addingTimeInterval(3_600), from: now) == 0)
        #expect(CertificateExpiry.daysLeft(until: now.addingTimeInterval(-3_600), from: now) < 0)
    }

    @Test(arguments: [
        // (daysLeft, alreadyWarnedAt, expected)
        (30, nil as Int?, nil as Int?),     // plenty of time
        (15, nil, nil),
        (14, nil, 14),                      // first threshold reached
        (14, 14, nil),                      // already warned at 14
        (13, 14, nil),                      // still within the 14-day band
        (7, 14, 7),                         // next threshold
        (6, 7, nil),
        (3, 7, 3),
        (1, 3, 1),
        (0, 1, nil),                        // already warned at the last threshold
        (0, nil, 1),                        // first seen very late: one warning at the lowest band
        (20, 7, nil),                       // an older warning never re-fires for a higher band
    ] as [(Int, Int?, Int?)])
    func dueThreshold_warnsOncePerBand(_ row: (Int, Int?, Int?)) {
        #expect(CertificateExpiry.dueThreshold(daysLeft: row.0, alreadyWarnedAt: row.1) == row.2)
    }

    @Test func warningMessage_saysWhoMustFixItAndWhatHappens() {
        let expiry = Date(timeIntervalSince1970: 2_000_000_000)
        let m = CertificateExpiry.warningMessage(host: "api.hdhomerun.com", expiry: expiry, daysLeft: 7)
        #expect(m.title == "Guide Service Certificate Expiring")
        #expect(m.subtitle.contains("in 7 days"))
        #expect(m.detail.contains("api.hdhomerun.com"))
        #expect(m.detail.contains("SiliconDust has to renew it"))
        #expect(m.detail.contains("last saved guide"))
        let one = CertificateExpiry.warningMessage(host: "h", expiry: expiry, daysLeft: 1)
        #expect(one.subtitle.contains("in 1 day") && !one.subtitle.contains("1 days"))
        #expect(CertificateExpiry.warningMessage(host: "h", expiry: expiry, daysLeft: 0).subtitle.contains("under a day"))
    }

    // Opt-in live check (CERT_LIVE=1): the probe must read the date even when validation fails — which is
    // exactly the 2026-10-09 situation (an expired certificate the request itself rejects).
    @Test func liveProbe_readsTheRealServersCertificate() async throws {
        guard ProcessInfo.processInfo.environment["CERT_LIVE"] == "1" else { return }
        let date = try #require(await CertificateExpiry.fetchNotAfter(host: "api.hdhomerun.com"))
        print("api.hdhomerun.com certificate notAfter: \(date)  (\(CertificateExpiry.daysLeft(until: date)) day(s) from now)")
    }
}
