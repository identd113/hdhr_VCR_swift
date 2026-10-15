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

// A show still holding a legacy HFS colon path ("Vol:Dir:", migrated from the AppleScript app) must
// not be reported as "recording to fallback" while its volume is mounted — the old comparison
// (posixRecordDir vs the raw show_dir string) always differed for HFS strings.
@Suite("Show.isRecordingToFallback")
struct ShowRecordingFallbackTests {
    @Test func hfsPathOnMountedVolume_isNotFallback() throws {
        // A volume that is really mounted right now. Needs a drive under /Volumes (the startup volume is "/", not
        // there): a CI runner or a Mac with no external disk has none, so this skips instead of failing — same as
        // startupVolumeAlias_isMounted below. (GitHub CI failed here from 2026-10-14 until this guard.)
        guard let vol = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [])?
            .first(where: { $0.path.hasPrefix("/Volumes/") }) else { return }
        var show = Show.blank(channel: "5.1", device: "DEV1")
        show.show_dir = vol.lastPathComponent + ":"      // legacy HFS form -> /Volumes/<name>
        show.show_temp_dir = Show.localFallbackDir
        #expect(show.posixRecordDir == "/Volumes/" + vol.lastPathComponent)
        #expect(!show.isRecordingToFallback)
    }

    @Test func offlineVolume_isFallback() {
        var show = Show.blank(channel: "5.1", device: "DEV1")
        show.show_dir = "ZZNoSuchVolume:Dir:" // parent /Volumes/ZZNoSuchVolume is absent
        show.show_temp_dir = Show.localFallbackDir
        #expect(show.isRecordingToFallback)
        #expect(show.posixRecordDir == Show.localFallbackDir)
    }

    @Test func emptyShowDir_isNotFallback() {
        #expect(!Show.blank().isRecordingToFallback)
    }
}

// T02: a folder that IS a volume root used to count as "mounted" because /Volumes (its parent) always exists,
// so an unmounted drive made recordings land in a plain /Volumes/<name> folder on the startup disk.
@Suite("Show.recordDir mounted-volume check")
struct ShowRecordDirMountTests {
    private let fallback = "/Users/x/Movies/hdhr_videos"

    @Test func unmountedVolumeRoot_fallsBack() {
        #expect(Show.pathIsOnMountedVolume("/Volumes/ZZNoSuchVolume-\(UUID().uuidString)") == false)
        #expect(Show.recordDir(primary: "/Volumes/Raid6", fallback: fallback, isMounted: { _ in false }) == fallback)
    }

    @Test func unmountedVolumeSubfolder_fallsBack() {
        #expect(Show.pathIsOnMountedVolume("/Volumes/ZZNoSuchVolume-\(UUID().uuidString)/DVR/Shows") == false)
    }

    @Test func plainFolderLeftOnBootDiskUnderVolumes_isNotAMount() throws {
        // What the old bug left behind: an ordinary directory named like the drive, not a mount point.
        let name = "ZZStrayVolume-\(UUID().uuidString)"
        let stray = "/Volumes/" + name
        guard (try? FileManager.default.createDirectory(atPath: stray, withIntermediateDirectories: false)) != nil else { return }   // /Volumes not writable here
        defer { try? FileManager.default.removeItem(atPath: stray) }
        #expect(Show.pathIsOnMountedVolume(stray) == false)
        #expect(Show.pathIsOnMountedVolume(stray + "/DVR") == false)
    }

    @Test func realMountedVolume_isMounted_atRootAndBelow() throws {
        // Skips (does not fail) when nothing is mounted under /Volumes — CI runners have no external disk.
        guard let vol = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [])?
            .first(where: { $0.path.hasPrefix("/Volumes/") }) else { return }
        #expect(Show.pathIsOnMountedVolume(vol.path))
        #expect(Show.pathIsOnMountedVolume(vol.path + "/Some/New/Folder"))
    }

    @Test func startupVolumeAlias_isMounted() {
        // /Volumes/Macintosh HD is a symlink to "/"; it must not be mistaken for an unmounted drive.
        let alias = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes"))?
            .first { (try? FileManager.default.destinationOfSymbolicLink(atPath: "/Volumes/" + $0)) == "/" }
        guard let alias else { return }
        #expect(Show.pathIsOnMountedVolume("/Volumes/" + alias + "/Users"))
    }

    @Test func pathsOutsideVolumes_useTheParentDirectoryCheck() {
        #expect(Show.pathIsOnMountedVolume(NSTemporaryDirectory() + "new-subfolder"))
        #expect(Show.pathIsOnMountedVolume("/definitely-missing-\(UUID().uuidString)/child") == false)
    }

    @Test func samePrimaryAndFallback_isReturnedWithoutAnyMountCheck() {
        #expect(Show.recordDir(primary: fallback, fallback: fallback, isMounted: { _ in false }) == fallback)
    }

    @Test func mountedPrimary_isUsed() {
        #expect(Show.recordDir(primary: "/Volumes/Raid6/DVR", fallback: fallback, isMounted: { _ in true }) == "/Volumes/Raid6/DVR")
    }
}
