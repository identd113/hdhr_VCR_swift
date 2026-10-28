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
    var viewers = 1   // browsers that started or joined it and have not asked to stop; the last one out frees the tuner
}

extension AppState {
    /// How long a live spool lives after the last browser stopped fetching its stream (the HLS session itself ends after 30 s).
    static let webLiveIdleSeconds: TimeInterval = 45
    /// A live spool is ended past this size (about 3 hours at 4 Mb/s; the viewer simply presses Watch again).
    static let webLiveMaxSpoolBytes = 6_000_000_000

    /// Starts (or joins) live TV for a channel: a lineup channel, or one only the air scan found. Returns the stream id for `/api/hls/<id>/…`, or why not.
    func startWebLive(deviceId: String, guideNumber: String) async -> Result<WebLiveSession, WebLiveError> {
        guard config.Web_streaming_enabled else { return .failure(.init("Web streaming is off (Settings → Web Streaming)")) }
        guard let device = recordableDevices.first(where: { $0.DeviceID == deviceId && $0.isAvailable }) else { return .failure(.init("Tuner not found")) }
        // The channel's stream URL: its lineup entry, else the saved air scan's (tuned by frequency and program).
        let url: String, title: String
        if let entry = lineups[deviceId]?.first(where: { $0.GuideNumber == guideNumber }), let u = entry.URL, !u.isEmpty {
            url = u; title = entry.GuideName
        } else { return .failure(.init("Channel not found")) }
        if let joined = await joinWebLive(deviceId: deviceId, guideNumber: guideNumber) { return .success(joined) }
        await yieldOTAScan(for: device)   // an air scan holding the tuners steps aside first
        // Another first request for this channel may have started the stream while this one waited for the scan to step aside: join it, never open a second tuner.
        if let joined = await joinWebLive(deviceId: deviceId, guideNumber: guideNumber) { return .success(joined) }
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
        guard await waitForFirstBytes(of: session) else {
            stopWebLive(id: id, reason: "no signal")
            return .failure(.init("The channel did not tune (no signal or no free tuner)"))
        }
        await broadcastTunerOccupancyChange(deviceId: deviceId)
        return .success(session)
    }

    /// Joins the live session already running for this channel (a second viewer shares the spool and the tuner); nil when there is none.
    /// A session whose puller has died is stopped here so it does not count against the tuner about to be used.
    private func joinWebLive(deviceId: String, guideNumber: String) async -> WebLiveSession? {
        guard var existing = webLiveSessions.values.first(where: { $0.deviceId == deviceId && $0.guideNumber == guideNumber }) else { return nil }
        if recordingManager.isFeedCachePullRunning(sessionId: existing.id) {
            existing.lastActive = Date(); existing.viewers += 1; webLiveSessions[existing.id] = existing
            await waitForFirstBytes(of: existing)   // the first viewer may still be waiting for the tuner
            return existing
        }
        stopWebLive(id: existing.id, reason: "the tuner stream ended")
        return nil
    }

    /// Waits (up to ~6 s) for the spool's first bytes; a channel that will not tune ends the puller at once.
    @discardableResult
    private func waitForFirstBytes(of session: WebLiveSession) async -> Bool {
        var waited = 0.0
        func size() -> Int { (try? FileManager.default.attributesOfItem(atPath: session.cachePath))?[.size] as? Int ?? 0 }
        while size() == 0, waited < 6, recordingManager.isFeedCachePullRunning(sessionId: session.id) {
            try? await Task.sleep(nanoseconds: 150_000_000); waited += 0.15
        }
        return size() > 0
    }

    /// A browser closed its player. The tuner is freed only when the last viewer of the channel has gone.
    func releaseWebLiveViewer(id: String) {
        guard var s = webLiveSessions[id] else { return }
        s.viewers -= 1
        if s.viewers > 0 { webLiveSessions[id] = s; return }
        stopWebLive(id: id, reason: "viewer closed it")
    }

    func stopAllWebLive(reason: String) {
        for id in Array(webLiveSessions.keys) { stopWebLive(id: id, reason: reason) }
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
                // The spool is the whole stream from the first byte (the HLS side keeps only the last half hour), so it is bounded here.
                let spool = (try? FileManager.default.attributesOfItem(atPath: s.cachePath))?[.size] as? Int ?? 0
                if spool > Self.webLiveMaxSpoolBytes || self.feedCacheDiskLow(minFreeGB: Self.feedCacheStopMinFreeGB) {
                    self.stopWebLive(id: id, reason: "spool limit or low disk space"); continue
                }
                let active = await self.webServer.isStreamActive(id: id)
                // Re-read after the await: a viewer may have joined (lastActive bumped) or the session ended meanwhile.
                guard let current = self.webLiveSessions[id] else { continue }
                if active { self.webLiveSessions[id]?.lastActive = Date(); continue }
                if Date().timeIntervalSince(current.lastActive) > Self.webLiveIdleSeconds { self.stopWebLive(id: id, reason: "no viewers") }
            }
        }
    }
}

struct WebLiveError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
