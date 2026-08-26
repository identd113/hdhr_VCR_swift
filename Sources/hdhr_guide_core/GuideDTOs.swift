import Foundation

// Mirrors the Encodable payload WebServer.swift's buildGuideJSON()/handleRecord() produce —
// see docs/WebServer.md's /api/guide.json and POST /api/record sections. Kept as local DTOs
// rather than importing the hdhr_VCR module: that target is an executable, not a library, and
// this is a thin two-endpoint JSON client — not worth sharing model types with hdhr_VCR itself
// over. (These types *are* now split into their own module, hdhr_guide_core — that's this file's
// whole reason for existing — just not merged into hdhr_VCR's own model types.)
//
// Every type below writes its own `public init(from decoder:)` rather than relying on Decodable's
// compiler synthesis — synthesis gives the initializer the same access level as the type only in
// some cases; the reliable rule is that a synthesized `init(from:)` stays `internal` regardless of
// the type's own `public` access unless written out explicitly, which would otherwise make these
// types undecodable from the hdhr_guide executable target once actually moved to a separate module.

public struct DeviceSummary: Decodable {
    public let deviceId: String
    public let active, total: Int

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try c.decode(String.self, forKey: .deviceId)
        active = try c.decode(Int.self, forKey: .active)
        total = try c.decode(Int.self, forKey: .total)
    }

    enum CodingKeys: String, CodingKey { case deviceId, active, total }
}

public struct GuideEntryDTO: Decodable {
    public let title: String
    public let episodeTitle, episodeNumber, synopsis, seriesId, genre: String?
    public let tags: [String]?
    public let startTime, endTime: Int
    public let isRecording, isScheduled: Bool
    public let scheduledShowId: String?

    public var startDate: Date { Date(timeIntervalSince1970: TimeInterval(startTime)) }
    public var endDate: Date { Date(timeIntervalSince1970: TimeInterval(endTime)) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        episodeTitle = try c.decodeIfPresent(String.self, forKey: .episodeTitle)
        episodeNumber = try c.decodeIfPresent(String.self, forKey: .episodeNumber)
        synopsis = try c.decodeIfPresent(String.self, forKey: .synopsis)
        seriesId = try c.decodeIfPresent(String.self, forKey: .seriesId)
        genre = try c.decodeIfPresent(String.self, forKey: .genre)
        tags = try c.decodeIfPresent([String].self, forKey: .tags)
        startTime = try c.decode(Int.self, forKey: .startTime)
        endTime = try c.decode(Int.self, forKey: .endTime)
        isRecording = try c.decode(Bool.self, forKey: .isRecording)
        isScheduled = try c.decode(Bool.self, forKey: .isScheduled)
        scheduledShowId = try c.decodeIfPresent(String.self, forKey: .scheduledShowId)
    }

    // `internal`, not `public`, and deliberately so: this exists only for hdhr_guide_coreTests
    // fixtures (reachable via `@testable import`, which exposes `internal` as if `public`) to
    // build entries without going through JSON. Real production code (hdhr_guide, the executable —
    // sees only this module's actual `public` API) only ever decodes these, never constructs one
    // by hand; a `public` memberwise init here would let it fabricate a fake "decoded" entry (e.g.
    // isRecording: true without it ever coming from the server), which the decode-only design is
    // otherwise built to make unreachable.
    init(title: String, episodeTitle: String? = nil, episodeNumber: String? = nil,
                synopsis: String? = nil, seriesId: String? = nil, genre: String? = nil,
                tags: [String]? = nil, startTime: Int, endTime: Int,
                isRecording: Bool = false, isScheduled: Bool = false, scheduledShowId: String? = nil) {
        self.title = title
        self.episodeTitle = episodeTitle
        self.episodeNumber = episodeNumber
        self.synopsis = synopsis
        self.seriesId = seriesId
        self.genre = genre
        self.tags = tags
        self.startTime = startTime
        self.endTime = endTime
        self.isRecording = isRecording
        self.isScheduled = isScheduled
        self.scheduledShowId = scheduledShowId
    }

    enum CodingKeys: String, CodingKey {
        case title, episodeTitle, episodeNumber, synopsis, seriesId, genre, tags
        case startTime, endTime, isRecording, isScheduled, scheduledShowId
    }
}

public struct GuideChannelDTO: Decodable {
    public let guideNumber, guideName: String
    public let hd, favorite: Bool
    public let entries: [GuideEntryDTO]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guideNumber = try c.decode(String.self, forKey: .guideNumber)
        guideName = try c.decode(String.self, forKey: .guideName)
        hd = try c.decode(Bool.self, forKey: .hd)
        favorite = try c.decode(Bool.self, forKey: .favorite)
        entries = try c.decode([GuideEntryDTO].self, forKey: .entries)
    }

    public init(guideNumber: String, guideName: String, hd: Bool = false, favorite: Bool = false,
                entries: [GuideEntryDTO] = []) {
        self.guideNumber = guideNumber
        self.guideName = guideName
        self.hd = hd
        self.favorite = favorite
        self.entries = entries
    }

    enum CodingKeys: String, CodingKey { case guideNumber, guideName, hd, favorite, entries }
}

public struct GuidePayload: Decodable {
    public let deviceId: String
    public let winStart, winSec: Int
    public let devices: [DeviceSummary]
    public let channels: [GuideChannelDTO]
    // Mirrors guide.js's own SPORTS_PADDING_ENABLED template token — lets confirmRecord() (main.swift)
    // gate its sports-genre auto-Bonus-Time detection on the same setting the web Record modal and
    // native Add Show wizard already gate on, instead of always assuming it's on. Defaults true only
    // as a decode fallback for an old server that predates this field — matches Sports_padding_enabled's
    // own default (Models.swift) — not a statement about what's actually configured.
    public let sportsPaddingEnabled: Bool
    // Mirrors Terminal_guide_enabled (state.config) — main.swift checks this right after the first
    // successful fetch and exits if false. A courtesy/discoverability gate only, not a security
    // boundary — see the field's own doc comment in WebServer.swift's buildGuideJSON. Defaults true
    // as a decode fallback for an old server that predates this field, matching
    // Terminal_guide_enabled's own default (Models.swift).
    public let terminalGuideEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case deviceId, winStart, winSec, devices, channels, sportsPaddingEnabled, terminalGuideEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try c.decode(String.self, forKey: .deviceId)
        winStart = try c.decode(Int.self, forKey: .winStart)
        winSec = try c.decode(Int.self, forKey: .winSec)
        devices = try c.decode([DeviceSummary].self, forKey: .devices)
        channels = try c.decode([GuideChannelDTO].self, forKey: .channels)
        sportsPaddingEnabled = (try? c.decode(Bool.self, forKey: .sportsPaddingEnabled)) ?? true
        terminalGuideEnabled = (try? c.decode(Bool.self, forKey: .terminalGuideEnabled)) ?? true
    }

    public init(deviceId: String, winStart: Int, winSec: Int, devices: [DeviceSummary],
                channels: [GuideChannelDTO], sportsPaddingEnabled: Bool = true, terminalGuideEnabled: Bool = true) {
        self.deviceId = deviceId
        self.winStart = winStart
        self.winSec = winSec
        self.devices = devices
        self.channels = channels
        self.sportsPaddingEnabled = sportsPaddingEnabled
        self.terminalGuideEnabled = terminalGuideEnabled
    }
}

public struct RecordResponse: Decodable {
    public let ok: Bool
    public let error: String?
    public let title: String?
    public let tunerFull: Bool?
    public let recStarted: Bool?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decode(Bool.self, forKey: .ok)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        tunerFull = try c.decodeIfPresent(Bool.self, forKey: .tunerFull)
        recStarted = try c.decodeIfPresent(Bool.self, forKey: .recStarted)
    }

    public init(ok: Bool, error: String?, title: String?, tunerFull: Bool?, recStarted: Bool?) {
        self.ok = ok
        self.error = error
        self.title = title
        self.tunerFull = tunerFull
        self.recStarted = recStarted
    }

    enum CodingKeys: String, CodingKey { case ok, error, title, tunerFull, recStarted }
}

public struct DeleteResponse: Decodable {
    public let ok: Bool
    public let error: String?
    public let title: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decode(Bool.self, forKey: .ok)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        title = try c.decodeIfPresent(String.self, forKey: .title)
    }

    public init(ok: Bool, error: String?, title: String?) {
        self.ok = ok
        self.error = error
        self.title = title
    }

    enum CodingKeys: String, CodingKey { case ok, error, title }
}

public struct ToggleFavoriteResponse: Decodable {
    public let ok: Bool
    public let error: String?
    public let isFavorite: Bool?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decode(Bool.self, forKey: .ok)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite)
    }

    public init(ok: Bool, error: String?, isFavorite: Bool?) {
        self.ok = ok
        self.error = error
        self.isFavorite = isFavorite
    }

    enum CodingKeys: String, CodingKey { case ok, error, isFavorite }
}
