import Foundation

// Over-the-air guide: the app side of the scan (overtime/APP_PLAN.md). Starts an OTAScanner on a real tuner device, follows the
// tuner rules (idle tuners only, yields to recordings), saves the result under Application Support and loads it into GuideStore.
// The scan runs entirely off the main actor; only the small environment closures and the final hand-over touch app state.

extension AppState {
    /// Starts a scan of one device (default: the first real tuner). Returns a one-line status for the caller.
    @discardableResult
    func startOTAScan(deviceId: String? = nil, rfChannels: [Int]? = nil, seconds: TimeInterval = 90) -> String {
        if otaScanTask != nil { return "A scan is already running: \(otaScanStatus)" }
        guard let device = recordableDevices.first(where: { deviceId == nil || $0.DeviceID == deviceId }), device.isAvailable else {
            return "No tuner available to scan."
        }
        let id = device.DeviceID
        let tunerCount = device.TunerCount ?? 1
        let host = device.LocalIP
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
            })
        otaScanStatus = "Scanning \(id)…"
        glog("[OTA] scan starting on \(id) (\(host)), \(tunerCount) tuner(s), \(Int(seconds)) s per channel")
        let report: @Sendable (String) -> Void = { [weak self] line in Task { @MainActor in self?.otaScanStatus = line } }
        otaScanTask = Task { [weak self] in
            let outcome = await OTAScanner().scan(env: env, rfChannels: rfChannels ?? OTAScanner.allRFChannels, secondsPerChannel: seconds, progress: report)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.otaScanTask = nil
                if let summary = OTAStore.save(outcome, deviceId: id) {
                    self.otaScanStatus = "Done: \(summary.channels) channels, \(summary.events) events from \(summary.multiplexes) multiplexes"
                    glog("[OTA] scan finished: \(self.otaScanStatus); skipped \(summary.skipped.count) RF channel(s)")
                } else {
                    self.otaScanStatus = outcome.cancelled ? "Scan cancelled" : "Scan found nothing usable (earlier results kept)"
                    glog("[OTA] \(self.otaScanStatus)", level: .warning)
                }
            }
        }
        return otaScanStatus
    }

    func cancelOTAScan() {
        otaScanTask?.cancel()
        otaScanTask = nil
        otaScanStatus = "Scan cancelled"
    }
}
