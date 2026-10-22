import AppKit
import Foundation

// Over-the-air guide: the app side of the scan (overtime/APP_PLAN.md). Starts an OTAScanner on a real tuner device, follows the
// tuner rules (idle tuners only, yields to recordings), saves the result under Application Support and loads it into GuideStore.
// The scan runs entirely off the main actor; only the small environment closures and the final hand-over touch app state.

extension AppState {
    /// Starts a scan of one device (default: the first real tuner). Returns a one-line status for the caller.
    @discardableResult
    func startOTAScan(deviceId: String? = nil, rfChannels: [Int]? = nil, seconds: TimeInterval = 90, lineupOnly: Bool = false, userInitiated: Bool = true, showWindow: Bool = true) -> String {
        if otaScanTask != nil { return "A scan is already running: \(otaScanStatus)" }
        guard let device = recordableDevices.first(where: { deviceId == nil || $0.DeviceID == deviceId }), device.isAvailable else {
            return "No tuner available to scan."
        }
        let id = device.DeviceID
        otaScanDeviceId = id
        let tunerCount = device.TunerCount ?? 1
        let seconds = lineupOnly ? min(seconds, 10) : seconds
        let host = device.LocalIP
        otaTunerMax = tunerCount
        otaTunerLimit = tunerCount
        let env = OTAScanEnvironment(
            host: host, tunerCount: tunerCount,
            appBusyTuners: { [weak self] in
                await MainActor.run { [weak self] in
                    guard let self else { return 0 }
                    // This app's own recordings and in-app player on this device (hardware occupancy is read by the scanner itself).
                    return self.recordingShows.filter { $0.hdhr_record == id }.count
                        + (self.vlcOccupiesTuner(for: id) ? 1 : 0) + (self.secondaryVlcOccupiesTuner(for: id) ? 1 : 0)
                }
            },
            secondsUntilNextRecording: { [weak self] in
                await MainActor.run { [weak self] in
                    guard let self else { return nil }
                    let next = self.shows.filter { $0.hdhr_record == id && $0.show_active && !$0.show_paused && !$0.show_recording }
                        .compactMap(\.show_next).filter { $0 > Date() }.min()
                    return next.map { $0.timeIntervalSinceNow }
                }
            },
            tunerLimit: { [weak self] in await MainActor.run { [weak self] in self?.otaTunerLimit ?? 1 } },
            onHeldChange: { [weak self] held in Task { @MainActor [weak self] in self?.otaHeldResources = held } },
            yieldRequested: { [weak self] in await MainActor.run { [weak self] in Date() < (self?.otaYieldUntil ?? .distantPast) } })
        otaScanStatus = "Scanning \(id)…"
        let twoPass = !lineupOnly && rfChannels == nil   // a full scan of the whole band: channel lists first, then guides
        otaProgress.reset(lineupOnly: lineupOnly, twoPass: twoPass)
        otaWindowActivates = userInitiated
        if showWindow { otaWindowRequest += 1 }   // the wizard shows its own progress and keeps this window closed
        glog("[OTA] \(lineupOnly ? "lineup-only " : "")scan starting on \(id) (\(host)), \(tunerCount) tuner(s), \(Int(seconds)) s per channel")
        let report: @Sendable (String) -> Void = { [weak self] line in Task { @MainActor in self?.otaScanStatus = line } }
        otaScanGeneration += 1
        let generation = otaScanGeneration
        let applyEvent: @MainActor (OTAScanEvent) -> Void = { [weak self] event in
            if let self, self.otaScanGeneration == generation { self.otaProgress.apply(event) }
        }
        otaScanTask = Task { [weak self] in
            let scanner = OTAScanner()
            let forward: @Sendable (OTAScanEvent) -> Void = { event in Task { @MainActor in applyEvent(event) } }
            var outcome: OTAScanOutcome
            var channelListSaved = false
            if twoPass {
                // Pass 1: every RF channel's channel list (a couple of seconds each), saved at once. Pass 2: the guide of only the
                // stations pass 1 found that announce one; the rest keep their pass 1 result.
                let first = await scanner.scan(env: env, rfChannels: OTAScanner.allRFChannels, secondsPerChannel: 10, lineupOnly: true, onEvent: forward, progress: report)
                channelListSaved = OTAStore.save(first, deviceId: id, lineupOnly: true) != nil
                let wanted = first.multiplexes.filter { $0.result.announcedEITCount > 0 }.map(\.rf)
                if first.cancelled || wanted.isEmpty {
                    outcome = first
                } else {
                    let second = await scanner.scan(env: env, rfChannels: wanted, secondsPerChannel: seconds, onEvent: forward, progress: report)
                    outcome = second
                    outcome.multiplexes += first.multiplexes.filter { m in !second.multiplexes.contains { $0.rf == m.rf } }
                    outcome.skipped = first.skipped
                }
            } else {
                outcome = await scanner.scan(env: env, rfChannels: rfChannels ?? OTAScanner.allRFChannels, secondsPerChannel: seconds, lineupOnly: lineupOnly,
                                             onEvent: forward, progress: report)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                // A cancelled scan's late finish must not clear the state of a scan started right after it.
                let current = self.otaScanGeneration == generation
                if current { self.otaScanTask = nil; self.otaProgress.running = false; self.otaProgress.endedAt = Date(); self.otaProgress.lanes = [:]; self.otaProgress.note = nil; self.otaHeldResources = [] }
                // A cancelled full scan saved its channel lists already; its half-read guide must not replace an earlier complete one.
                let saved = (twoPass && outcome.cancelled) ? nil : OTAStore.save(outcome, deviceId: id, lineupOnly: lineupOnly)
                if let summary = saved {
                    let done = "Done: \(summary.channels) channels, \(summary.events) events from \(summary.multiplexes) multiplexes"
                    if current { self.otaScanStatus = done }
                    glog("[OTA] scan finished: \(done); skipped \(summary.skipped.count) RF channel(s)")
                } else {
                    let why = outcome.cancelled ? (channelListSaved ? "Scan cancelled (channel list saved, guide unchanged)" : "Scan cancelled") : "Scan found nothing usable (earlier results kept)"
                    if current { self.otaScanStatus = why }
                    glog("[OTA] \(why)", level: .warning)
                }
            }
        }
        return otaScanStatus
    }

    // MARK: keeping the channel list from the air up to date

    /// Pure rule for the daily channel-list scan, so it can be tested: due once the chosen hour has passed today when the saved list
    /// is older than that mark, and at most one try per day (a scan that found nothing is not retried every tick). `hour` -1 = never.
    nonisolated static func lineupScanDue(now: Date, hour: Int, lineupDate: Date?, lastAttempt: Date?, calendar: Calendar = .current) -> Bool {
        guard hour >= 0, let mark = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now), now >= mark else { return false }
        if let lineupDate, lineupDate >= mark { return false }
        if let lastAttempt, lastAttempt >= mark { return false }
        return true
    }

    /// Idle-loop hook: a quick channel-list scan (a few minutes, no guide) once a day from `OTA_lineup_hour`.
    /// It runs without opening the scan window and, like every scan, gives its tuners up the moment a recording or a viewer needs one.
    func startScheduledOTALineupRefreshIfDue(now: Date = Date()) {
        guard config.OTA_lineup_hour >= 0, otaScanTask == nil, let device = recordableDevices.first(where: \.isAvailable) else { return }
        guard Self.lineupScanDue(now: now, hour: config.OTA_lineup_hour, lineupDate: OTAStore.lineupDate(deviceId: device.DeviceID), lastAttempt: lastOTALineupAttempt) else { return }
        lastOTALineupAttempt = now
        glog("[OTA] daily channel-list scan due (\(config.OTA_lineup_hour):00)")
        startOTAScan(deviceId: device.DeviceID, lineupOnly: true, userInitiated: false, showWindow: false)
    }

    // MARK: handing a tuner to the app while a scan runs

    /// Would a new stream on this device find every tuner held by something, with the OTA scan among the holders? Then the scan must let
    /// go first. (Tuners the scan holds do not count as occupied for `tunersFull`: the scan yields.)
    func otaNeedsYield(for deviceId: String) -> Bool {
        guard deviceId == otaScanDeviceId, otaScanTask != nil, !otaHeldResources.isEmpty,
              let device = devices.first(where: { $0.DeviceID == deviceId }), let tunerCount = device.TunerCount, tunerCount > 0 else { return false }
        let hwAll = deviceTunerOccupancy[deviceId]?.filter { $0.isInUse }.count ?? 0
        let app = recordingShows.filter { $0.hdhr_record == deviceId }.count
            + (vlcOccupiesTuner(for: deviceId) ? 1 : 0) + (secondaryVlcOccupiesTuner(for: deviceId) ? 1 : 0)
        return max(hwAll, app + otaHeldResources.count) >= tunerCount
    }

    /// Asks the scan to drop its captures and take no tuner for the next 25 s (the app is about to tune). The interrupted channels go back
    /// in the scan's queue; once the app's stream is up the scan carries on with whatever tuner is still free.
    func requestOTAYield(deviceId: String) {
        guard deviceId == otaScanDeviceId, otaScanTask != nil else { return }
        otaYieldUntil = Date().addingTimeInterval(25)   // long enough to outlast the idle loop's own tick, so the scan cannot take the tuner back first
        glog("[OTA] a tuner is needed on \(deviceId) — the scan is stepping aside")
    }

    /// For the live-watch paths: if the scan is in the way, ask it to step aside and wait (up to ~6 s) until it has let go.
    func yieldOTAScan(for device: HDHRDevice) async {
        guard otaNeedsYield(for: device.DeviceID) else { return }
        requestOTAYield(deviceId: device.DeviceID)
        for _ in 0..<12 where !otaHeldResources.isEmpty {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        await fetchDeviceStatus(for: device)
    }

    func cancelOTAScan() {
        otaScanTask?.cancel()
        otaScanTask = nil
        otaProgress.running = false
        otaProgress.endedAt = Date(); otaProgress.lanes = [:]; otaProgress.note = nil
        otaHeldResources = []
        otaScanStatus = "Scan cancelled"
    }

    // MARK: guide failure → offer the air guide

    /// The guide could not be pulled for `deviceId` (called once per outage, from `handleGuideLoadFailure`): ask the person whether to scan
    /// the air for a backup guide, tell Discord, and start the scan by itself if nobody answers within an hour. "Not now" ends the offer for
    /// this outage. A guide that loads again cancels everything (`endAirGuideFallbackOffer`).
    func offerAirGuideFallback(deviceId: String, wait: TimeInterval = 3600) {
        guard !airFallbackOffered, otaScanTask == nil, !OTAStore.hasFreshGuide(deviceId: deviceId),
              recordableDevices.contains(where: { $0.DeviceID == deviceId }) else { return }
        airFallbackOffered = true
        glog("[OTA] guide unavailable for \(deviceId) — offering an air scan, starting it in \(Int(wait / 60)) min if nobody answers")
        let alert = NSAlert()
        alert.messageText = "The guide is unavailable"
        alert.informativeText = "hdhrVCRplus can't load the guide for \(deviceId). It can scan the air for a backup guide instead (it takes a while, uses only idle tuners and steps aside for recordings). Scan now, or it starts by itself in an hour."
        alert.addButton(withTitle: "Scan Now")
        alert.addButton(withTitle: "Not Now")
        Dialogs.show(alert) { [weak self] response in
            guard let self else { return }
            self.airFallbackTask?.cancel(); self.airFallbackTask = nil
            if response == .alertFirstButtonReturn { self.startOTAScan(deviceId: deviceId) }
            else { glog("[OTA] air guide scan declined for this outage") }
        }
        discordError("📡 Guide unavailable — air scan offered",
                     detail: "Device \(deviceId) — the guide can't be loaded. Answer the prompt in the app (Scan Now / Not Now); with no answer the app scans the air for a backup guide in \(Int(wait / 60)) min.",
                     color: 0xE67E22, enabled: config.Discord_on_guide_error)
        airFallbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            self.airFallbackTask = nil
            glog("[OTA] no answer after \(Int(wait / 60)) min — starting the air scan")
            self.startOTAScan(deviceId: deviceId, userInitiated: false)
        }
    }

    /// The guide loads again (or the outage ended): forget the offer so the next outage asks afresh.
    func endAirGuideFallbackOffer() {
        airFallbackTask?.cancel(); airFallbackTask = nil
        airFallbackOffered = false
    }

    // MARK: air-only channels (web guide)

    /// Channels the saved air lineup has and this tuner's own lineup does not (empty when no scan is saved).
    func airOnlyChannels(deviceId: String) -> [OTALineupEntry] {
        // With the Developer lineup source "From the air" the air channels ARE the lineup: nothing is left over to list separately.
        guard !lineupFromAirByDevice.contains(deviceId), let date = OTAStore.lineupDate(deviceId: deviceId) else { airOnlyCache[deviceId] = nil; return [] }
        let tuner = lineups[deviceId] ?? []
        let stamp = "\(date.timeIntervalSince1970)-\(tuner.count)"
        if let hit = airOnlyCache[deviceId], hit.stamp == stamp { return hit.entries }
        let entries = OTAStore.airOnly(saved: OTAStore.savedLineup(deviceId: deviceId) ?? [], tunerLineup: tuner)
        airOnlyCache[deviceId] = (stamp, entries)
        return entries
    }

    /// Plays an air-only channel in the app's own player on this Mac (never records it), tuned by frequency and program. Returns why not, or nil.
    func watchAirOnly(deviceId: String, guideNumber: String) -> String? {
        guard let device = recordableDevices.first(where: { $0.DeviceID == deviceId }) else { return "Tuner not found" }
        guard let entry = airOnlyChannels(deviceId: deviceId).first(where: { $0.GuideNumber == guideNumber }) else { return "Channel not found" }
        guard VLCBridge.shared.isAvailable else { return "VLC is not installed on this Mac" }
        watchInApp(url: "http://\(device.LocalIP):5004/auto/ch\(entry.Frequency)-\(entry.ProgramNumber)", title: entry.GuideName,
                   deviceId: deviceId, guideNumber: entry.GuideNumber)
        return nil
    }
}
