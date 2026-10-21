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

    /// Idle-loop hook: starts a scan in the background when the user's schedule (`OTA_scan_hour`) says one is due. Never interrupts
    /// anything: the scanner itself only takes idle tuners and yields to a recording or the player.
    func startScheduledOTAScanIfDue(now: Date = Date()) {
        guard config.OTA_scan_hour >= 0, otaScanTask == nil,
              let device = recordableDevices.first(where: \.isAvailable) else { return }
        let id = device.DeviceID
        let cal = Calendar.current
        guard let dueToday = cal.date(bySettingHour: config.OTA_scan_hour, minute: 0, second: 0, of: now), now >= dueToday else { return }
        if let last = OTAStore.loadSummary(deviceId: id)?.date, last >= dueToday { return }
        if let tried = lastScheduledOTAAttempt, tried >= dueToday { return }   // one try per day: a scan that found nothing is not retried every tick
        lastScheduledOTAAttempt = now
        glog("[OTA] scheduled scan due (\(config.OTA_scan_hour):00)")
        startOTAScan(deviceId: id, userInitiated: false)
    }

    // MARK: keeping the channel list from the air up to date

    /// Pure rule for the automatic channel-list refresh, so it can be tested: due when the list is missing or older than `maxAge`, only in
    /// the early hours (a slow moment, never prime time), and at most once a day.
    nonisolated static func lineupRefreshDue(now: Date, lineupDate: Date?, lastAttempt: Date?, calendar: Calendar = .current,
                                              quietHours: Range<Int> = 2..<6, maxAge: TimeInterval = 7 * 24 * 3600) -> Bool {
        guard quietHours.contains(calendar.component(.hour, from: now)) else { return false }
        if let lineupDate, now.timeIntervalSince(lineupDate) < maxAge { return false }
        if let lastAttempt, calendar.isDate(lastAttempt, inSameDayAs: now) { return false }
        return true
    }

    /// Idle-loop hook: a quick channel-list scan (a few minutes, no guide) in the early hours when the saved list is missing or a week old.
    /// It runs without opening the scan window and, like every scan, gives its tuners up the moment a recording or a viewer needs one.
    func startScheduledOTALineupRefreshIfDue(now: Date = Date()) {
        guard config.OTA_lineup_auto, otaScanTask == nil, let device = recordableDevices.first(where: \.isAvailable) else { return }
        guard Self.lineupRefreshDue(now: now, lineupDate: OTAStore.lineupDate(deviceId: device.DeviceID), lastAttempt: lastOTALineupAttempt) else { return }
        lastOTALineupAttempt = now
        glog("[OTA] refreshing the channel list from the air (early hours, list missing or a week old)")
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
}
