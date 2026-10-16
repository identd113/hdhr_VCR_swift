import Testing
import Foundation
@testable import hdhr_VCR

// AppRelocator's release-only flow can't run under test (it's compiled out in DEBUG and shows a modal),
// so its two safety-critical pieces are plain functions exercised here on temp directories.
@Suite("AppRelocator safety")
struct AppRelocatorTests {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("reloc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func makeApp(_ dir: URL, name: String = "X.app", marker: String) throws -> URL {
        let app = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: app.appendingPathComponent("Contents/marker.txt"))
        return app
    }

    private func marker(_ app: URL) -> String? {
        (try? Data(contentsOf: app.appendingPathComponent("Contents/marker.txt"))).flatMap { String(data: $0, encoding: .utf8) }
    }

    @Test func installReplacesAnExistingCopyWithTheNewOne() throws {
        let src = try tempDir(), dst = try tempDir()
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        let new = try makeApp(src, marker: "new")
        let old = try makeApp(dst, marker: "old")
        try AppRelocator.install(new, replacing: old)
        #expect(marker(old) == "new")
        // no leftover temp sibling
        #expect(try FileManager.default.contentsOfDirectory(atPath: dst.path).filter { $0.contains("incoming") }.isEmpty)
    }

    @Test func installIntoAnEmptyDestinationJustCopies() throws {
        let src = try tempDir(), dst = try tempDir()
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        let new = try makeApp(src, marker: "new")
        let target = dst.appendingPathComponent("X.app")
        try AppRelocator.install(new, replacing: target)
        #expect(marker(target) == "new")
    }

    // The old flow deleted the existing install BEFORE copying, so a failed copy left nothing.
    @Test func aFailedCopyLeavesTheExistingInstallUntouched() throws {
        let dst = try tempDir()
        defer { try? FileManager.default.removeItem(at: dst) }
        let old = try makeApp(dst, marker: "old")
        let missingSource = dst.appendingPathComponent("does-not-exist.app")
        #expect(throws: (any Error).self) { try AppRelocator.install(missingSource, replacing: old) }
        #expect(marker(old) == "old")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dst.path).filter { $0.contains("incoming") }.isEmpty)
    }

    @Test func appInsideAGitCheckoutIsRecognised() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let app = try makeApp(root, name: "hdhrVCRplus.app", marker: "x")
        #expect(AppRelocator.isInsideGitCheckout(app))
        let elsewhere = try tempDir()
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        let plain = try makeApp(elsewhere, marker: "x")
        #expect(!AppRelocator.isInsideGitCheckout(plain))
    }
}


@Suite("AppRelocator permission retry")
struct AppRelocatorPermissionTests {
    private let noPermission = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)

    @Test func permissionErrorsAreRecognisedIncludingUnderlyingOnes() {
        #expect(AppRelocator.isPermissionError(noPermission))
        #expect(AppRelocator.isPermissionError(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))))
        #expect(AppRelocator.isPermissionError(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                                                       userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))])))
        #expect(!AppRelocator.isPermissionError(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)))
    }

    @Test func retriesUntilThePermissionIsGrantedThenSucceeds() throws {
        var attempts = 0, sleeps = 0, announced = 0
        var clock = Date(timeIntervalSince1970: 0)
        try AppRelocator.retryWhileAwaitingPermission(timeout: 60, interval: 1.5,
            sleep: { clock = clock.addingTimeInterval($0); sleeps += 1 }, now: { clock },
            onWaiting: { announced += 1 }) {
            attempts += 1
            if attempts < 4 { throw noPermission }
        }
        #expect(attempts == 4)
        #expect(sleeps == 3)
        #expect(announced == 1)      // told once, not on every retry
    }

    @Test func givesUpWithThePermissionErrorOnceTheTimeoutPasses() {
        var attempts = 0
        var clock = Date(timeIntervalSince1970: 0)
        #expect(throws: NSError.self) {
            try AppRelocator.retryWhileAwaitingPermission(timeout: 10, interval: 2,
                sleep: { clock = clock.addingTimeInterval($0) }, now: { clock }) {
                attempts += 1
                throw noPermission
            }
        }
        #expect(attempts >= 5 && attempts <= 7)
    }

    @Test func otherErrorsAreNotRetried() {
        var attempts = 0
        #expect(throws: NSError.self) {
            try AppRelocator.retryWhileAwaitingPermission(timeout: 60, interval: 1, sleep: { _ in }, now: Date.init) {
                attempts += 1
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
            }
        }
        #expect(attempts == 1)
    }
}

@Suite("AppRelocator launch gate")
struct AppRelocatorGateTests {
    @Test func waitForDecisionReturnsOnceTheDecisionIsMade() async {
        AppRelocator.markDecided()
        #expect(AppRelocator.isDecided)
        let t = Date()
        await AppRelocator.waitForDecision(timeout: 30)
        #expect(Date().timeIntervalSince(t) < 1)        // returned at once, not after the timeout
    }
}
