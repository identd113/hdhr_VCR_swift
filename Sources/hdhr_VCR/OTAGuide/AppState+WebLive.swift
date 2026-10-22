import Foundation

// Live TV in a browser, kept light (docs/WebStreaming.md "Live TV"): the web-streaming converter already turns a growing transport-stream file
// into HLS, so a live channel is just a tuner stream spooled into a temp file and handed to it as if it were a recording that is never saved.
// Reuses the FEED cache's puller (RecordingManager.startFeedCachePull), the HLS sessions (StreamSessions) and the guide's Watch Now! player.

struct WebLiveSession {
    let id: String
    let deviceId: String
    let guideNumber: String
    let title: String
    let cachePath: String
    let startedAt: Date
    var lastActive: Date
}

extension AppState {
    /// How long a live spool lives after the last browser stopped fetching its stream (the HLS session itself ends after 30 s).
    static let webLiveIdleSeconds: TimeInterval = 45

    /// Starts (or joins) live TV for a channel: a lineup channel, or one only the air scan found. Returns the stream id for `/api/hls/<id>/…`, or why not.
    func startWebLive(deviceId: String, guideNumber: String) async -> Result<WebLiveSession, WebLiveError> {
        guard config.Web_streaming_enabled else { return .failure(.init("Web streaming is off (Settings → Web Streaming)")) }
        guard let device = recordableDevices.first(where: { $0.DeviceID == deviceId && $0.isAvailable }) else { return .failure(.init("Tuner not found")) }
        // The channel's stream URL: its lineup entry, else the saved air scan's (tuned by frequency and program).
        let url: String, title: String
        if let entry = lineups[deviceId]?.first(where: { $0.GuideNumber == guideNumber }), let u = entry.URL, !u.isEmpty {
            url = u; title = entry.GuideName
        } else if let air = airOnlyChannels(deviceId: deviceId).first(where: { $0.GuideNumber == guideNumber }) {
            url = "http://\(device.LocalIP):5004/auto/ch\(air.Frequency)-\(air.ProgramNumber)"; title = air.GuideName
        } else { return .failure(.init("Channel not found")) }
        if var existing = webLiveSessions.values.first(where: { $0.deviceId == deviceId && $0.guideNumber == guideNumber }),
           recordingManager.isFeedCachePullRunning(sessionId: existing.id) {
            existing.lastActive = Date(); webLiveSessions[existing.id] = existing
            return .success(existing)   // a second viewer joins the same spool and the same tuner
        }
        guard !tunersFull(for: deviceId) else { return .failure(.init("All tuners are in use")) }
        guard !feedCacheDiskLow(minFreeGB: Self.feedCacheStartMinFreeGB) else { return .failure(.init("Not enough free disk space for live TV")) }
        let id = "live-\(deviceId.safeFileComponent)-\(UUID().uuidString.prefix(8))"
        let path = "\(Self.feedCacheDirectory)/\(id).ts"
        try? FileManager.default.createDirectory(atPath: Self.feedCacheDirectory, withIntermediateDirectories: true)
        do {
            try recordingManager.startFeedCachePull(sessionId: id, url: url, outputPath: path, networkInterface: effectiveNetworkInterface)
        } catch { return .failure(.init("Could not tune the channel")) }
        let session = WebLiveSession(id: id, deviceId: deviceId, guideNumber: guideNumber, title: title, cachePath: path, startedAt: Date(), lastActive: Date().addingTimeInterval(30))
        webLiveSessions[id] = session
        glog("[WebLive] started \(guideNumber) \(title) on \(deviceId) as \(id)")
        // Wait for the first bytes (a channel that will not tune ends the puller at once).
        var waited = 0.0
        while waited < 6 {
            let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
            if size > 0 { break }
            guard recordingManager.isFeedCachePullRunning(sessionId: id) else { break }
            try? await Task.sleep(nanoseconds: 150_000_000); waited += 0.15
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
        guard size > 0 else {
            stopWebLive(id: id, reason: "no signal")
            return .failure(.init("The channel did not tune (no signal or no free tuner)"))
        }
        await broadcastTunerOccupancyChange(deviceId: deviceId)
        return .success(session)
    }

    func stopWebLive(id: String, reason: String) {
        guard let s = webLiveSessions.removeValue(forKey: id) else { return }
        recordingManager.stopFeedCachePull(sessionId: id)
        try? FileManager.default.removeItem(atPath: s.cachePath)
        webServer.endStream(id: id)
        glog("[WebLive] stopped \(s.guideNumber) (\(reason))")
        Task { await broadcastTunerOccupancyChange(deviceId: s.deviceId) }
    }

    /// Once per idle tick: ends a live spool nobody is watching any more (the browser closed, or the HLS session went quiet), one whose puller
    /// died, or all of them when web streaming is switched off.
    func reapWebLiveSessions() {
        guard !webLiveSessions.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            for (id, s) in self.webLiveSessions {
                if !self.config.Web_streaming_enabled { self.stopWebLive(id: id, reason: "web streaming turned off"); continue }
                if !self.recordingManager.isFeedCachePullRunning(sessionId: id) { self.stopWebLive(id: id, reason: "the tuner stream ended"); continue }
                if await self.webServer.isStreamActive(id: id) { self.webLiveSessions[id]?.lastActive = Date(); continue }
                if Date().timeIntervalSince(s.lastActive) > Self.webLiveIdleSeconds { self.stopWebLive(id: id, reason: "no viewers") }
            }
        }
    }
}

struct WebLiveError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
