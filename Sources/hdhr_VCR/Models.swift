import Foundation
import OSLog

// MARK: - LogLevel

enum LogLevel {
    case info, warning, error
}

// A single-writer, size-capped append log. Not thread-safe on its own — every call site drives
// one of these from its own serial DispatchQueue (glog's logQueue, discordLog's
// discordLogQueue), which is what actually makes access safe.
//
// Rotation is a generous backstop against unbounded growth over a months-long running session,
// not a housekeeping schedule — one prior generation kept (path + ".1") so a post-mortem can
// still see what led up to a rotation. Default cap (20 MB) is sized off the main app log's
// measured real-world rate (~1.2 MB/day, ~11,700 glog() lines/day) — roughly 2.5 weeks live plus
// 2.5 weeks in the backup.
final class RotatingLogFile {
    private let path: String
    private var handle: FileHandle?
    private var bytesWritten: UInt64 = 0
    private let rotateThreshold: UInt64

    init(path: String, rotateThresholdBytes: UInt64 = 20 * 1024 * 1024) {
        self.path = path
        self.rotateThreshold = rotateThresholdBytes
    }

    func write(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        if handle == nil { open() }
        handle?.write(data)
        bytesWritten += UInt64(data.count)
        if bytesWritten >= rotateThreshold { rotate() }
    }

    private func open() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) { fm.createFile(atPath: path, contents: nil) }
        guard let fh = FileHandle(forWritingAtPath: path) else { return }
        _ = try? fh.seekToEnd()
        handle = fh
        let attrs = try? fm.attributesOfItem(atPath: path)
        bytesWritten = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private func rotate() {
        handle?.closeFile()
        handle = nil
        let fm = FileManager.default
        let backupPath = path + ".1"
        try? fm.removeItem(atPath: backupPath)
        try? fm.moveItem(atPath: path, toPath: backupPath)
        bytesWritten = 0
        // Next write() reopens via open(), which creates a fresh empty file.
    }
}

private let appLog = Logger(subsystem: "com.hdhr.vcrplus", category: "app")
private let logQueue = DispatchQueue(label: "com.hdhr.vcrplus.log", qos: .utility)
// Shared formatter and file — accessed only from the serial logQueue so no concurrent access.
private let logDateFormatter = ISO8601DateFormatter()
let logFilePath = NSHomeDirectory() + "/Library/Logs/hdhrVCRplus.log"
private let logFile = RotatingLogFile(path: logFilePath)

func glog(_ msg: String, level: LogLevel = .info) {
    switch level {
    case .info:    appLog.notice("\(msg, privacy: .public)")
    case .warning: appLog.warning("\(msg, privacy: .public)")
    case .error:   appLog.error("\(msg, privacy: .public)")
    }
    let tag = level == .info ? "INFO" : level == .warning ? "WARN" : "ERROR"
    let ts = Date()
    logQueue.async {
        logFile.write("[\(logDateFormatter.string(from: ts))] [\(tag)] \(msg)\n")
    }
}

// MARK: - Show

struct Show: Identifiable, Equatable {
    static let weekdayNames = ["Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"]
    var id: String { show_id }
    var isSeries: Bool { state.isSeries }
    var show_id: String
    var show_title: String
    var show_is_series: Bool
    var show_use_seriesid: Bool
    var show_use_seriesid_all: Bool
    var show_air_date: [String]
    var show_channel: String
    var show_time: Double           // local decimal hours (0–24), e.g. 20.5 = 8:30 PM local time
    var show_length: Int            // minutes
    var show_next: Date?
    var show_end: Date?
    var show_active: Bool
    var show_paused: Bool           // auto-paused (failures, manual stop, skip); recovers automatically
    var hdhr_record: String         // device ID, e.g. "105404BE"
    var show_url: String            // stream URL from lineup
    var show_seriesid: String
    var show_fail_count: Int
    var show_fail_reason: String
    var show_logo_url: String
    var show_transcode: String      // "none", "heavy", "mobile", "internet720"…
    var show_recording: Bool
    var show_last: Date?
    var notify_upnext_time: Date?
    var notify_recording_time: Date?
    var show_dir: String            // recording destination (POSIX path)
    var show_temp_dir: String       // local recording-folder fallback — see Show.localFallbackDir; deliberately NOT the same as show_dir (that was a bug, self-healed in init(from:))
    var show_recording_path: String // path of active/last recording file
    var show_genre: String          // first genre tag from guide (e.g. "Sports")
    var show_bonus_time: Bool       // true = extend recording past guide end
    var discord_start_msg_id: String = ""   // message ID of the "Recording Started" embed; "" = none
    var show_tuner_resource: String  = ""   // e.g. "tuner0" — from X-HDHomeRun-Resource response header
    var show_ignore_duplicate_once: Bool  = false // per-show override: record even if Skip_recorded_episodes would skip it as already on disk

    var state: ShowState {
        if !show_is_series { return .single }
        if show_use_seriesid_all { return .seriesAll }
        if show_use_seriesid { return .seriesChannel }
        return .dateTime
    }

    // Single source of truth for the "always exists, always local" recording destination —
    // used as the ultimate fallback below, and as the local disk safety net any caller can fall
    // back to when a NAS/external volume that show_dir points at goes offline. Not a POSIX path
    // conversion target itself (already POSIX), unlike show_dir/show_temp_dir which may still be
    // legacy HFS colon-separated strings needing toPosix().
    static let localFallbackDir = NSHomeDirectory() + "/Movies/hdhr_videos"

    var posixRecordDir: String {
        let primary  = Self.toPosix(show_dir.isEmpty      ? Self.localFallbackDir : show_dir)
        let fallback = Self.toPosix(show_temp_dir.isEmpty ? Self.localFallbackDir : show_temp_dir)
        guard primary != fallback else { return primary }
        // Use primary only when its parent directory exists (i.e. the volume is mounted)
        let parent = URL(fileURLWithPath: primary).deletingLastPathComponent().path
        return FileManager.default.fileExists(atPath: parent) ? primary : fallback
    }

    // Converts legacy HFS colon-separated paths ("Raid6:DVR Tests:") to POSIX ("/Volumes/Raid6/DVR Tests").
    private static func toPosix(_ path: String) -> String {
        guard !path.hasPrefix("/"), path.contains(":") else { return path }
        let stripped = path.hasSuffix(":") ? String(path.dropLast()) : path
        let parts    = stripped.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        return "/Volumes/" + parts.joined(separator: "/")
    }

    private static let outputDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")  // fixed format, must not vary by locale
        f.dateFormat = "yyyyMMdd_HHmm"
        return f
    }()

    /// Extensions this app has ever written for a recording. Current output is `.ts`; `.m2ts`
    /// and `.mkv` are legacy (pre-2026-07) and stay here so existing recordings still count for
    /// dedup (`recordedEpisodeTags`) and Organize. Never includes `.mp4` — the app never wrote it.
    static let recordingExtensions: Set<String> = ["ts", "m2ts", "mkv"]

    /// True if `filename` is one this app produced as a recording (by extension).
    static func isRecordingFile(_ filename: String) -> Bool {
        recordingExtensions.contains((filename as NSString).pathExtension.lowercased())
    }

    func outputPath(date: Date = Date(), subfolder: String? = nil, episodeTag: String? = nil) -> String {
        let dateStr = Self.outputDateFormatter.string(from: date)
        let safe = show_title.replacingOccurrences(of: "/", with: "-")
        // The recorder writes the device's HTTP response verbatim (curl -o, no remux). On the wire
        // that is always an MPEG-2 transport stream — verified 188-byte TS packets (sync 0x47) for
        // BOTH transcode=none (MPEG-2 video) and transcode profiles (H.264 video); only the video
        // codec inside changes, never the container. So every recording is `.ts` regardless of
        // profile — matching the `video/mp2t` MIME the disk relay already serves it under, and the
        // `.ts` convention Plex/Emby/Jellyfin/MythTV/TVHeadend use for raw HDHR captures. (Before
        // 2026-07 this wrote `.m2ts` for none and `.mkv` for transcoded — both container mislabels;
        // those linger in `recordingExtensions` so old files still scan.)
        let ext = ".ts"
        var dir = posixRecordDir
        if let sub = subfolder { dir = (dir as NSString).appendingPathComponent(sub) }
        let epPart = episodeTag.map { "_\($0)" } ?? ""
        return (dir as NSString).appendingPathComponent("\(safe)\(epPart)_\(show_channel)_\(dateStr)\(ext)")
    }

    /// Strips a trailing episode-specific suffix (e.g. " S24E116 Trey Parker; Matt Stone; Alison
    /// Brie") from a raw guide title. For SeriesID-type shows — which go on to record many future,
    /// different episodes under one umbrella — keeping whichever single airing's guest line happened
    /// to be on screen when the show was added would freeze the display name at that one night
    /// forever (menu bar, Discord cards, and the recording folder name all read show_title, and
    /// nothing re-derives it from the guide on later nights). Single/dateTime shows deliberately
    /// keep the raw title since they refer to one specific airing, where that descriptive suffix is
    /// exactly what the user wants to see.
    static func seriesTitle(from rawTitle: String) -> String {
        guard let range = rawTitle.range(of: #"\s+S\d+E\d+.*$"#, options: [.regularExpression, .caseInsensitive])
        else { return rawTitle }
        return String(rawTitle[..<range.lowerBound])
    }

    static func blank(channel: String = "", device: String = "") -> Show {
        Show(
            show_id: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            show_title: "", show_is_series: false, show_use_seriesid: false,
            show_use_seriesid_all: false, show_air_date: [], show_channel: channel,
            show_time: 20.0, show_length: 60, show_next: nil, show_end: nil,
            show_active: true, show_paused: false, hdhr_record: device, show_url: "", show_seriesid: "",
            show_fail_count: 0, show_fail_reason: "", show_logo_url: "", show_transcode: "none",
            show_recording: false, show_last: nil,
            notify_upnext_time: nil, notify_recording_time: nil,
            show_dir: "", show_temp_dir: "", show_recording_path: "", show_genre: "",
            show_bonus_time: false
        )
    }

    mutating func recordFailure(reason: String) {
        show_fail_count += 1
        show_fail_reason = reason
        // show_paused is NOT set here — startRecording's threshold check pauses the show
        // after Fail_count_setting consecutive failures. AppState.recordShowFailure(index:reason:)
        // also starts an escalating idle-loop-tick cooldown before the next retry is attempted.
    }

    mutating func clearFailures() {
        show_fail_count = 0
        show_fail_reason = ""
    }
}

enum ShowState: String, CaseIterable {
    case single = "Single"
    case dateTime = "DateTime"
    case seriesChannel = "SeriesID(Channel)"
    case seriesAll = "SeriesID(All)"

    var isSeries: Bool { self == .seriesChannel || self == .seriesAll }
}

// MARK: - Codable conformance (custom to handle missing / renamed fields)

extension Show: Codable {
    enum CodingKeys: String, CodingKey {
        case show_id, show_title, show_is_series, show_use_seriesid, show_use_seriesid_all
        case show_air_date, show_channel, show_time, show_length
        case show_next, show_end, show_active, show_paused, hdhr_record, show_url
        case show_seriesid, show_fail_count, show_fail_reason, show_logo_url
        case show_transcode, show_recording, show_last
        case notify_upnext_time, notify_recording_time
        case show_dir, show_temp_dir, show_recording_path, show_genre, show_bonus_time
        case discord_start_msg_id, show_tuner_resource, show_ignore_duplicate_once
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Every other field below has a `try?` fallback; show_id must too — ConfigFile's [Show]
        // decode is all-or-nothing (falls to [] on any element throw, see ConfigFile.init), so a
        // single show with a missing/corrupt show_id would otherwise silently wipe every show.
        show_id            = (try? c.decode(String.self, forKey: .show_id))
            ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        show_title         = (try? c.decode(String.self, forKey: .show_title)) ?? ""
        show_is_series     = (try? c.decode(Bool.self,   forKey: .show_is_series)) ?? false
        show_use_seriesid  = (try? c.decode(Bool.self,   forKey: .show_use_seriesid)) ?? false
        show_use_seriesid_all = (try? c.decode(Bool.self, forKey: .show_use_seriesid_all)) ?? false
        show_air_date      = (try? c.decode([String].self, forKey: .show_air_date)) ?? []
        show_channel       = (try? c.decode(String.self, forKey: .show_channel)) ?? ""
        show_time          = (try? c.decode(Double.self, forKey: .show_time)) ?? 20.0
        show_length        = (try? c.decode(Int.self, forKey: .show_length)) ?? 60
        show_next          = try? c.decode(Date.self, forKey: .show_next)
        show_end           = try? c.decode(Date.self, forKey: .show_end)
        show_active        = (try? c.decode(Bool.self,   forKey: .show_active)) ?? true
        show_paused        = (try? c.decode(Bool.self,   forKey: .show_paused)) ?? false
        hdhr_record        = (try? c.decode(String.self, forKey: .hdhr_record)) ?? ""
        show_url           = (try? c.decode(String.self, forKey: .show_url)) ?? ""
        show_seriesid      = (try? c.decode(String.self, forKey: .show_seriesid)) ?? ""
        show_fail_count    = (try? c.decode(Int.self, forKey: .show_fail_count)) ?? 0
        show_fail_reason   = (try? c.decode(String.self, forKey: .show_fail_reason)) ?? ""
        show_logo_url      = (try? c.decode(String.self, forKey: .show_logo_url)) ?? ""
        show_transcode     = (try? c.decode(String.self, forKey: .show_transcode)) ?? "none"
        show_recording     = (try? c.decode(Bool.self,   forKey: .show_recording)) ?? false
        show_last          = try? c.decode(Date.self, forKey: .show_last)
        notify_upnext_time     = try? c.decode(Date.self, forKey: .notify_upnext_time)
        notify_recording_time  = try? c.decode(Date.self, forKey: .notify_recording_time)
        show_dir           = (try? c.decode(String.self, forKey: .show_dir)) ?? ""
        let decodedTempDir = (try? c.decode(String.self, forKey: .show_temp_dir)) ?? ""
        // Self-heal a prior bug where the native Add/Edit Show dialogs set show_temp_dir to the
        // exact same folder as show_dir (see AddShowView.swift's save() / EditShowView.swift's
        // saveWithoutDismiss()), leaving posixRecordDir nowhere real to redirect to if that
        // folder's volume (external drive/NAS) goes offline. A non-empty show_temp_dir identical
        // to a non-default show_dir is the unambiguous signature of that bug — a genuinely
        // intentional matching value would be pointless to ever set — so repair it to the local
        // fallback on every load instead of requiring every affected show to be re-saved through
        // the now-fixed dialogs.
        show_temp_dir = (!decodedTempDir.isEmpty && decodedTempDir == show_dir && show_dir != Show.localFallbackDir)
            ? Show.localFallbackDir
            : decodedTempDir
        show_recording_path = (try? c.decode(String.self, forKey: .show_recording_path)) ?? ""
        show_genre          = (try? c.decode(String.self, forKey: .show_genre)) ?? ""
        show_bonus_time     = (try? c.decode(Bool.self,   forKey: .show_bonus_time))
            ?? show_genre.lowercased().contains("sports")
        discord_start_msg_id = (try? c.decode(String.self, forKey: .discord_start_msg_id)) ?? ""
        show_tuner_resource  = (try? c.decode(String.self, forKey: .show_tuner_resource))  ?? ""
        show_ignore_duplicate_once = (try? c.decode(Bool.self, forKey: .show_ignore_duplicate_once)) ?? false
    }
}

// MARK: - AppConfig / ConfigFile

struct AppConfig: Equatable {
    // Notifications
    var Notify_recording: Double = 15.5     // minutes before recording alert
    var Notify_upnext: Double    = 35.0     // minutes before show airs

    // Guide
    var GuideHours: Int          = 24       // hours ahead to fetch
    var Guide_use_xml: Bool      = false    // use XMLTV endpoint instead of JSON; triggers guide refresh on toggle

    // Recording
    var Default_transcode: String   = "none"  // none | heavy | mobile | internet720
    var Fail_count_setting: Int     = 3       // deactivate show after N failures
    var Min_disk_free_gb: Double    = 10.0    // refuse to record below this free space
    var Idle_timer_interval: Int    = 10      // seconds between idle checks
    var Series_subfolder_enabled: Bool = false  // organize SeriesID recordings into Title/Season XX/ subfolders
    var Skip_recorded_episodes: Bool = false    // skip a series episode already on disk (needs Series_subfolder_enabled + SxxExx guide data)
    var Post_recording_script: String = ""      // POSIX path to script run after each successful recording

    // Series
    var Series_scan_retry_hours: Int = 4     // hours to wait before retrying guide scan

    // Default recording folder (POSIX path; empty = ~/Movies/hdhr_videos)
    var Hdhr_setup_folder: String = ""

    var Network_interface: String = ""  // empty = Auto (OS chooses interface)
    var Verbose_curl: Bool = false
    var Watch_in_VLC: Bool = false
    var Watch_in_VLC_initialized: Bool = false  // set true after first auto-detect so user toggles are preserved
    var Player_buffer_min_rate: Int = 93        // adaptive buffer fill-phase floor (90–100); 100 = disabled
    // Bonus Time: extends recording past the guide end for any show
    var Sports_padding_enabled: Bool = true
    var Sports_padding_minutes: Int  = 30   // user-settable 10–60 min, default 30
    var Config_version: String = "2"

    func applyTranscode(_ baseURL: String, override: String? = nil) -> String {
        let profile = (override ?? Default_transcode).lowercased().trimmingCharacters(in: .whitespaces)
        return (profile.isEmpty || profile == "none") ? baseURL : "\(baseURL)?transcode=\(profile)"
    }

    // Discord webhook
    var Discord_webhook_url: String  = ""
    var Discord_on_start:    Bool    = true    // Recording Started
    var Discord_on_complete: Bool    = true    // Recording Complete
    var Discord_on_failed:   Bool    = true    // Recording Failed
    var Discord_on_paused:   Bool    = true    // Show Paused (max fails / no air days)
    var Discord_on_skipped:  Bool    = true    // Skipped — disk full
    var Discord_on_duplicate: Bool   = true    // Skipped — already recorded
    var Discord_on_conflict: Bool    = true    // Tuner Conflict
    var Discord_on_guide_error: Bool = true    // Guide Load Failed
    var Discord_on_upnext:    Bool   = false   // Up Next reminder
    var Discord_on_soon:      Bool   = false   // Recording Soon reminder
    var Discord_on_show_added: Bool  = false   // Show Added
    var Discord_on_progress:  Bool   = false   // Edit start embed every 5 min with elapsed/remaining
    var Discord_enabled:      Bool   = false   // Master enable/disable toggle

    // Web server
    var Web_server_enabled: Bool = false
    var Web_server_port:    Int  = 1980

    // Signal quality
    var Signal_quality_enabled:      Bool = false  // show signal bars in guide + web UI
    var Signal_quality_alert_notify: Bool = false  // deliver system notification + Discord on dropout

    // Menu bar icon
    var Status_light_blink_enabled: Bool = false  // blink the built-in status light while recording/up-next

    // Donation nag
    var Donation_unlocked: Bool = false  // set true once the shared unlock code is entered in DonationNagView
    // Required hex-digit-sum for a valid unlock code (see DonationNagView.swift). -1 means
    // "not configured" — no code can ever match a negative target, so the nag simply never
    // unlocks until this is set via Settings → Advanced. Deliberately NOT a literal secret value
    // in this file: this repo is public, and the real number should only ever live in this
    // machine's own ~/Library/Application Support/hdhrVCRplus/ config, never in git.
    var Donation_target_checksum: Int = -1
}

extension AppConfig: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        Notify_recording      = (try? c.decode(Double.self,  forKey: .Notify_recording))      ?? 15.5
        Notify_upnext         = (try? c.decode(Double.self,  forKey: .Notify_upnext))         ?? 35.0
        // Clamp to 28 even for an old saved value above that — GuideStore.load()'s single-call
        // cloud request silently truncates past ~29h regardless (docs/HDHRFindings.md), so a
        // stale higher setting from before this cap was enforced would otherwise look honored.
        // Clamp both ends: the ~29h cloud cap sets the ceiling (28), and a floor of 1 guards against a
        // corrupt/hand-edited config with 0 or a negative — GuideHours feeds winSec = GuideHours*3600,
        // and WebServer.pct() divides by winSec, so 0 would be a division-by-zero trap that aborts the
        // app on every page render (and at startup during prebuildPageHTML), not just a bad UI value.
        GuideHours            = max(1, min(28, (try? c.decode(Int.self, forKey: .GuideHours)) ?? 24))
        Guide_use_xml         = (try? c.decode(Bool.self,   forKey: .Guide_use_xml))         ?? false
        Default_transcode     = (try? c.decode(String.self,  forKey: .Default_transcode))     ?? "none"
        Fail_count_setting    = (try? c.decode(Int.self,     forKey: .Fail_count_setting))    ?? 3
        Min_disk_free_gb      = (try? c.decode(Double.self,  forKey: .Min_disk_free_gb))      ?? 10.0
        Idle_timer_interval   = (try? c.decode(Int.self,     forKey: .Idle_timer_interval))   ?? 10
        Series_scan_retry_hours = (try? c.decode(Int.self,   forKey: .Series_scan_retry_hours)) ?? 4
        Hdhr_setup_folder     = (try? c.decode(String.self,  forKey: .Hdhr_setup_folder))     ?? ""
        Network_interface     = (try? c.decode(String.self,  forKey: .Network_interface))     ?? ""
        Verbose_curl          = (try? c.decode(Bool.self,    forKey: .Verbose_curl))          ?? false
        Watch_in_VLC          = (try? c.decode(Bool.self,    forKey: .Watch_in_VLC))          ?? false
        Watch_in_VLC_initialized = (try? c.decode(Bool.self, forKey: .Watch_in_VLC_initialized)) ?? false
        Player_buffer_min_rate   = (try? c.decode(Int.self,  forKey: .Player_buffer_min_rate))   ?? 93
        Sports_padding_enabled  = (try? c.decode(Bool.self,   forKey: .Sports_padding_enabled))  ?? true
        Sports_padding_minutes  = (try? c.decode(Int.self,    forKey: .Sports_padding_minutes))  ?? 30
        Config_version          = (try? c.decode(String.self,  forKey: .Config_version))         ?? "2"
        Discord_webhook_url     = (try? c.decode(String.self, forKey: .Discord_webhook_url))     ?? ""
        Discord_on_start        = (try? c.decode(Bool.self,   forKey: .Discord_on_start))        ?? true
        Discord_on_complete     = (try? c.decode(Bool.self,   forKey: .Discord_on_complete))     ?? true
        Discord_on_failed       = (try? c.decode(Bool.self,   forKey: .Discord_on_failed))       ?? true
        Discord_on_paused       = (try? c.decode(Bool.self,   forKey: .Discord_on_paused))       ?? true
        Discord_on_skipped      = (try? c.decode(Bool.self,   forKey: .Discord_on_skipped))      ?? true
        Discord_on_duplicate    = (try? c.decode(Bool.self,   forKey: .Discord_on_duplicate))    ?? true
        Discord_on_conflict     = (try? c.decode(Bool.self,   forKey: .Discord_on_conflict))     ?? true
        Discord_on_guide_error  = (try? c.decode(Bool.self,   forKey: .Discord_on_guide_error))  ?? true
        Discord_on_upnext       = (try? c.decode(Bool.self,   forKey: .Discord_on_upnext))       ?? false
        Discord_on_soon         = (try? c.decode(Bool.self,   forKey: .Discord_on_soon))         ?? false
        Discord_on_show_added   = (try? c.decode(Bool.self,   forKey: .Discord_on_show_added))   ?? false
        Discord_on_progress     = (try? c.decode(Bool.self,   forKey: .Discord_on_progress))     ?? false
        // Migration: existing configs with a URL had Discord working, so default to enabled for them.
        Discord_enabled         = (try? c.decode(Bool.self,   forKey: .Discord_enabled))         ?? !Discord_webhook_url.isEmpty
        Web_server_enabled      = (try? c.decode(Bool.self,   forKey: .Web_server_enabled))      ?? false
        Web_server_port         = (try? c.decode(Int.self,    forKey: .Web_server_port))         ?? 1980
        Signal_quality_enabled      = (try? c.decode(Bool.self, forKey: .Signal_quality_enabled))      ?? false
        Signal_quality_alert_notify = (try? c.decode(Bool.self, forKey: .Signal_quality_alert_notify)) ?? false
        Status_light_blink_enabled  = (try? c.decode(Bool.self, forKey: .Status_light_blink_enabled))  ?? false
        Series_subfolder_enabled    = (try? c.decode(Bool.self,   forKey: .Series_subfolder_enabled))    ?? false
        Skip_recorded_episodes      = (try? c.decode(Bool.self,   forKey: .Skip_recorded_episodes))      ?? false
        Post_recording_script       = (try? c.decode(String.self, forKey: .Post_recording_script))       ?? ""
        Donation_unlocked           = (try? c.decode(Bool.self,   forKey: .Donation_unlocked))            ?? false
        Donation_target_checksum    = (try? c.decode(Int.self,    forKey: .Donation_target_checksum))     ?? -1
    }
}

struct ConfigFile: Codable {
    var config: AppConfig
    var shows: [Show]
}

extension ConfigFile {
    // Custom decoder: accepts both "shows" (v2) and "the_shows" (v1 legacy key)
    init(from decoder: Decoder) throws {
        enum K: String, CodingKey { case config, shows, the_shows }
        let c = try decoder.container(keyedBy: K.self)
        config = try c.decode(AppConfig.self, forKey: .config)
        let decodedShows = (try? c.decode([Show].self, forKey: .shows))
                         ?? (try? c.decode([Show].self, forKey: .the_shows))
        // Every Show field (including show_id, as of this fix) has a fallback, so this array
        // decode should never throw on well-formed JSON — but if the "shows"/"the_shows" key is
        // present and still fails to decode (genuinely malformed structure, not just a missing
        // field), falling back to [] would silently wipe every saved show. Log loudly so that's
        // visible instead of a mysterious empty show list on next launch.
        if decodedShows == nil, c.contains(.shows) || c.contains(.the_shows) {
            glog("[Config] shows array present but failed to decode — starting with an empty list; check config file for corruption", level: .error)
        }
        shows = decodedShows ?? []
    }
}

// MARK: - HDHomeRun Device

struct HDHRDevice: Identifiable, Equatable {
    var id: String { DeviceID }
    var DeviceID: String
    var LocalIP: String     // present in cloud response; extracted from BaseURL for local/mDNS responses
    var BaseURL: String?
    var TunerCount: Int?
    var FirmwareVersion: String?
    var DeviceAuth: String?   // used to call SiliconDust cloud guide API (EXTEND and similar)

    // Runtime-only: incremented each probe cycle when the device is not seen; reset when seen.
    // Not persisted — resets to 0 (available) on every launch.
    var missedProbes: Int = 0
    var isAvailable: Bool { missedProbes < 3 }

    var streamBase: String { "http://\(LocalIP):5004" }
    var lineupURL:  String { "http://\(LocalIP)/lineup.json" }  // always IP — LineupURL from discover.json may contain mDNS hostname
    var statusURL:  String { "http://\(LocalIP)/status.json" }
}

extension HDHRDevice: Codable {
    enum CodingKeys: String, CodingKey {
        case DeviceID, LocalIP, BaseURL, TunerCount, FirmwareVersion, DeviceAuth
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        DeviceID        = try  c.decode(String.self, forKey: .DeviceID)
        BaseURL         = try? c.decode(String.self, forKey: .BaseURL)
        TunerCount      = try? c.decode(Int.self,    forKey: .TunerCount)
        FirmwareVersion = try? c.decode(String.self, forKey: .FirmwareVersion)
        DeviceAuth      = try? c.decode(String.self, forKey: .DeviceAuth)
        // Cloud response includes LocalIP directly; mDNS/device response omits it — extract host from BaseURL
        if let ip = try? c.decode(String.self, forKey: .LocalIP) {
            LocalIP = ip
        } else if let host = BaseURL.flatMap({ URL(string: $0)?.host }) {
            LocalIP = host
        } else {
            throw DecodingError.keyNotFound(CodingKeys.LocalIP,
                .init(codingPath: decoder.codingPath, debugDescription: "LocalIP missing and BaseURL not usable"))
        }
    }
}

// MARK: - Guide / Lineup

struct LineupEntry: Codable, Identifiable {
    var id: String { GuideNumber }
    var GuideNumber: String
    var GuideName: String
    var URL: String?
    var HD: Int?
    var Favorite: Int?
    var isFavorite: Bool { Favorite == 1 }

    private enum CodingKeys: String, CodingKey {
        case GuideNumber, GuideName, URL, HD, Favorite
    }
}

extension String {
    // Natural channel-number sort: "5.1" → (5, 1), "10.2" → (10, 2)
    var channelSortKey: (Int, Int) {
        let parts = split(separator: ".").compactMap { Int($0) }
        return (parts.first ?? 0, parts.dropFirst().first ?? 0)
    }

    // Stream URL without a transcode query: "http://host/auto?transcode=ts" → "http://host/auto"
    var urlBase: String { components(separatedBy: "?").first ?? self }
}

struct GuideChannel: Codable {
    var GuideNumber: String
    var GuideName: String
    var Affiliate: String?
    var ImageURL: String?
    var Guide: [GuideEntry]?
}

// MARK: - TunerStatus

// One entry from /status.json — only present when that tuner slot is actively streaming.
struct DeviceTunerInfo: Decodable {
    let Resource:             String  // "tuner0", "tuner1", …
    let VctNumber:            String? // channel number if locked
    let TargetIP:             String? // client IP receiving the stream
    let SignalQualityPercent: Int?    // snq 0–100 from status.json; used for passive signal collection
}

struct TunerStatus {
    let signalStrength: Int   // ss field (0–100)
    let lockType: String      // e.g. "qam256", "8vsb", "none"
    let bitrateMbps: Double   // bps / 1_000_000

    var displayString: String {
        guard lockType != "none" else { return "Signal: no lock" }
        return "Signal: \(signalStrength)% · \(lockType.uppercased()) · \(String(format: "%.1f", bitrateMbps)) Mbps"
    }
}

// MARK: - Signal Quality

struct ChannelSignalSample: Codable {
    var ts:  Date
    var snq: Int
}

enum SignalBucket: String, Codable, Equatable {
    case noData, poor, fair, good

    init(_ v: Double) {
        self = v < 0.33 ? .poor : v < 0.66 ? .fair : .good
    }
}

struct GuideEntry: Codable, Identifiable, Hashable {
    static func == (lhs: GuideEntry, rhs: GuideEntry) -> Bool { lhs.StartTime == rhs.StartTime }
    func hash(into hasher: inout Hasher) { hasher.combine(StartTime) }
    var id: Int { StartTime }
    var deviceId:    String = ""   // not in JSON — stamped after decode
    var channelNum:  String = ""   // not in JSON — stamped after decode
    var StartTime: Int
    var EndTime: Int
    var Title: String
    var EpisodeTitle: String?
    var EpisodeNumber: String?
    var Synopsis: String?
    var SeriesID: String?
    var ImageURL: String?
    var OriginalAirdate: Int?
    var Filter: [String]?   // genre tags from SiliconDust guide API (e.g. ["Drama","Series"])

    private enum CodingKeys: String, CodingKey {
        case StartTime, EndTime, Title, EpisodeTitle, EpisodeNumber, Synopsis, SeriesID, ImageURL, OriginalAirdate, Filter
    }

    var startDate: Date { Date(timeIntervalSince1970: TimeInterval(StartTime)) }
    var endDate:   Date { Date(timeIntervalSince1970: TimeInterval(EndTime)) }
    var durationMinutes: Int { (EndTime - StartTime) / 60 }
    // "Movie"/"Movies" wins regardless of position; otherwise skip "Series" meta-tag.
    // Handles ["Drama","Movie"], ["Movies"] → "Movie"; ["Series","Drama"] → "Drama"
    var firstGenre: String? {
        guard let f = Filter else { return nil }
        if f.contains("Movie") || f.contains("Movies") { return "Movie" }
        return f.first { $0.lowercased() != "series" }
    }
}

// MARK: - ManagedGuideMatcher

struct ManagedGuideMatcher: Equatable {
    // seriesAll shows record on any device — bare SeriesID/title keys, match regardless of device.
    // Values are the owning Show so callers needing "which show does this entry belong to" (e.g.
    // the web guide's skip-already-recorded check) don't need a second, separately-maintained
    // lookup alongside this one — see owner(for:).
    let seriesAllIDs:    [String: Show]   // bare SeriesID → owner
    let seriesAllTitles: [String: Show]   // bare title (no SeriesID) → owner
    // seriesChannel shows are assigned to a specific device — keys are "device:SeriesID" / "device:title".
    let seriesChKeys:    [String: Show]   // "device:SeriesID" → owner
    let seriesChTitles:  [String: Show]   // "device:title" (no SeriesID) → owner
    let singleSlotKeys:  [String: Show]   // "device:channel:epoch" → owner
    let datetimeSlotKeys: [String: Show]  // "device:channel:Weekday:HH:MM" → owner

    init(activeManagedShows: [Show]) {
        let cal = Calendar.current
        let dayNames = Show.weekdayNames
        let allShows  = activeManagedShows.filter { $0.state == .seriesAll }
        let chShows   = activeManagedShows.filter { $0.state == .seriesChannel }
        // uniquingKeysWith keeps the first match on a key collision (e.g. two shows sharing a
        // SeriesID) rather than trapping — matches the tolerant dedup a plain Set gave before.
        seriesAllIDs    = Dictionary(allShows.compactMap { s -> (String, Show)? in
            s.show_seriesid.isEmpty ? nil : (s.show_seriesid, s)
        }, uniquingKeysWith: { a, _ in a })
        seriesAllTitles = Dictionary(allShows.map { ($0.show_title, $0) }, uniquingKeysWith: { a, _ in a })
        seriesChKeys    = Dictionary(chShows.compactMap { s -> (String, Show)? in
            guard !s.show_seriesid.isEmpty else { return nil }
            return ("\(s.hdhr_record):\(s.show_seriesid)", s)
        }, uniquingKeysWith: { a, _ in a })
        seriesChTitles  = Dictionary(chShows.map { ("\($0.hdhr_record):\($0.show_title)", $0) }, uniquingKeysWith: { a, _ in a })
        // Plain subscript assignment, guarded to keep the first match on a collision — same
        // first-wins tolerance as the uniquingKeysWith dictionaries above, for consistency.
        var single: [String: Show] = [:]
        for s in activeManagedShows {
            guard s.state == .single, let next = s.show_next else { continue }
            let key = "\(s.hdhr_record):\(s.show_channel):\(Int(next.timeIntervalSince1970))"
            if single[key] == nil { single[key] = s }
        }
        singleSlotKeys = single
        // Key = "device:channel:Weekday:HH:MM" — one key per allowed air day.
        // Weekday comes from show_air_date; falls back to all 7 days if empty.
        var datetime: [String: Show] = [:]
        for s in activeManagedShows {
            guard s.state == .dateTime, let next = s.show_next else { continue }
            let c = cal.dateComponents([.hour, .minute], from: next)
            let hhmm = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
            let airDays = s.show_air_date.isEmpty ? dayNames : s.show_air_date.filter { dayNames.contains($0) }
            for day in airDays {
                let key = "\(s.hdhr_record):\(s.show_channel):\(day):\(hhmm)"
                if datetime[key] == nil { datetime[key] = s }
            }
        }
        datetimeSlotKeys = datetime
    }

    /// The managed show an entry belongs to, if any — same matching tiers as `isManaged`, but
    /// returns the owning `Show` instead of just whether one exists. Single source of truth for
    /// "is this entry managed, and by which show" — callers that need both no longer maintain a
    /// second, independently-derived lookup (which risked drifting out of sync with these tiers,
    /// e.g. a series lookup that isn't device-scoped for seriesChannel shows the way this is).
    func owner(for entry: GuideEntry) -> Show? {
        let dev = entry.deviceId
        if let sid = entry.SeriesID, !sid.isEmpty {
            if let s = seriesAllIDs[sid] { return s }
            if let s = seriesChKeys["\(dev):\(sid)"] { return s }
        }
        if let s = seriesAllTitles[entry.Title] { return s }
        if let s = seriesChTitles["\(dev):\(entry.Title)"] { return s }
        // Skip the Calendar computation entirely when there are no dateTime/single-slot managed
        // shows to match against — the common case for a guide with only SeriesID shows, and
        // otherwise this runs for every non-managed entry in the grid (most entries).
        guard !datetimeSlotKeys.isEmpty || !singleSlotKeys.isEmpty else { return nil }
        let c = Calendar.current.dateComponents([.hour, .minute, .weekday],
                    from: Date(timeIntervalSince1970: TimeInterval(entry.StartTime)))
        let hhmm = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        let dayName = Show.weekdayNames[(c.weekday ?? 1) - 1]
        let ch = entry.channelNum
        if let s = datetimeSlotKeys["\(dev):\(ch):\(dayName):\(hhmm)"] { return s }
        return singleSlotKeys["\(dev):\(ch):\(entry.StartTime)"]
    }

    func isManaged(entry: GuideEntry) -> Bool { owner(for: entry) != nil }
}

extension GuideEntry {
    var episodeInfoLabel: String? {
        let parts = [EpisodeNumber, EpisodeTitle].compactMap { s -> String? in
            guard let s, !s.isEmpty else { return nil }
            return s
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
