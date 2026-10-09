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
