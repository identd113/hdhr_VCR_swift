import Testing
import Foundation
@testable import hdhr_VCR

// CachePruner — pure over a temp dir + injected `now` / in-use set. Also pins the two CHANGELOG.md
// copies (repo root = what deploy.sh bundles; Sources/hdhr_VCR = the SPM .copy resource) together.

private func makeDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("prune-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@discardableResult
private func touch(_ dir: URL, _ name: String, bytes: Int = 10, ageHours: Double, now: Date) -> URL {
    let u = dir.appendingPathComponent(name)
    try? Data(count: bytes).write(to: u)
    try? FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-ageHours * 3600)], ofItemAtPath: u.path)
    return u
}

private func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }

@Suite struct CachePrunerTests {
    @Test func guideCacheDropsOnlyOldGuideFiles() {
        let dir = makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let fresh = touch(dir, "A-json-24h.guide", ageHours: 2, now: now)
        let old   = touch(dir, "A-json-12h.guide", ageHours: 40, now: now)
        let other = touch(dir, "notes.txt", ageHours: 400, now: now)
        let r = CachePruner.pruneGuideCache(in: dir, now: now)
        #expect(r.removed == 1)
        #expect(exists(fresh)); #expect(!exists(old)); #expect(exists(other))
    }

    @Test func zeroByteRemovedOnlyAfterGrace() {
        let dir = makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let justMade = touch(dir, "new.guide", bytes: 0, ageHours: 0, now: now)
        let stale0   = touch(dir, "empty.guide", bytes: 0, ageHours: 1, now: now)
        CachePruner.pruneGuideCache(in: dir, now: now)
        #expect(exists(justMade)); #expect(!exists(stale0))
    }

    @Test func inUseAndDirectoriesAreNeverRemoved() {
        let dir = makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let busy = touch(dir, "hdhrVCRplus-live.headers", ageHours: 100, now: now)
        let gone = touch(dir, "hdhrVCRplus-dead.headers", ageHours: 100, now: now)
        let young = touch(dir, "hdhrVCRplus-young.headers", ageHours: 1, now: now)
        let unrelated = touch(dir, "other.headers", ageHours: 100, now: now)
        let sub = dir.appendingPathComponent("hdhrVCRplus-dir.headers", isDirectory: true)
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-100 * 3600)], ofItemAtPath: sub.path)
        let r = CachePruner.pruneHeaderFiles(in: dir, now: now, inUse: ["hdhrVCRplus-live.headers"])
        #expect(r.removed == 1)
        #expect(exists(busy)); #expect(!exists(gone)); #expect(exists(young)); #expect(exists(unrelated)); #expect(exists(sub))
    }

    @Test func missingDirectoryIsHarmless() {
        let r = CachePruner.pruneGuideCache(in: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        #expect(r == CachePruner.Result())
    }

    @Test func changelogCopiesStayIdentical() throws {
        // #filePath = <repo>/Tests/hdhr_VCRTests/Caches/CachePrunerTests.swift
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let root = try Data(contentsOf: repo.appendingPathComponent("CHANGELOG.md"))
        let src  = try Data(contentsOf: repo.appendingPathComponent("Sources/hdhr_VCR/CHANGELOG.md"))
        #expect(root == src, "Sources/hdhr_VCR/CHANGELOG.md must be a byte copy of CHANGELOG.md (cp CHANGELOG.md Sources/hdhr_VCR/CHANGELOG.md)")
    }
}
