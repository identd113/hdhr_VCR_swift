import SwiftUI

// Device-aware replacement for FirstRunWizardView's old plain network-status row — same
// checking/found/not-found job, but once a tuner is actually found it names it (the same
// "HDHR-XXXXXXXX" convention already used app-wide, e.g. WebServer.swift's device bar and the web
// guide's offline-device warning) and shows how many tuners + channels it offers, instead of just
// a generic checkmark. FirstRunWizardView derives `TunerDiscoveryStatus` from its own existing
// checking/confirmed/notFound tri-state (unchanged) plus `state.devices`/`state.lineups` — this
// view is purely presentational, no discovery logic of its own.
struct TunerDiscoveryStatus: Equatable {
    enum Kind: Equatable { case checking, foundSingle, foundMultiple, notFound }
    var kind: Kind
    var devices: [HDHRDevice] = []
    var channelCounts: [String: Int] = [:]   // deviceId -> lineup count, when known
}

struct TunerDiscoveryCard: View {
    var status: TunerDiscoveryStatus
    var onOpenPrivacySettings: () -> Void

    // Pops the checkmark once, the moment status first turns "found" — same spring family as
    // StarburstBadge's own pop-in (see that file's doc for the timing rationale), not a fresh design.
    @State private var checkPop = 0

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon.frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).bold()
                detail
            }
            Spacer(minLength: 0)
            if status.kind == .notFound {
                Button("Open Privacy Settings") { onOpenPrivacySettings() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("wizard-open-privacy-settings")
            }
        }
        .padding(.vertical, 2)
        .onChange(of: status.kind) { _, newKind in
            if newKind == .foundSingle || newKind == .foundMultiple { checkPop += 1 }
        }
    }

    // Searching: a native SF Symbols "variable color" pulse on the antenna glyph itself — chosen
    // over a hand-rolled radar-ping animation because it's a built-in macOS effect (zero animation
    // code to maintain) and is thematically exact: an antenna pulsing while it searches.
    @ViewBuilder private var icon: some View {
        switch status.kind {
        case .checking:
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.orange)
                .symbolEffect(.variableColor.iterative.reversing, options: .repeating, isActive: true)
        case .foundSingle, .foundMultiple:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .keyframeAnimator(initialValue: CheckPopValue(), trigger: checkPop) { content, v in
                    content.scaleEffect(v.scale)
                } keyframes: { _ in
                    KeyframeTrack(\.scale) {
                        LinearKeyframe(CGFloat(1.4), duration: 0.01)
                        CubicKeyframe(CGFloat(0.85), duration: 0.14)
                        SpringKeyframe(CGFloat(1.0), spring: Spring(response: 0.3, dampingRatio: 0.45))
                    }
                }
        case .notFound:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private var title: String {
        switch status.kind {
        case .checking:      return "Looking for your HDHomeRun tuner…"
        case .foundSingle:   return "Tuner found on your network"
        case .foundMultiple: return "\(status.devices.count) HDHomeRun devices found"
        case .notFound:      return "No tuner found yet"
        }
    }

    @ViewBuilder private var detail: some View {
        switch status.kind {
        case .checking:
            Text("If macOS asks for Local Network permission, click Allow — hdhrVCRplus needs it to find your tuner.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .foundSingle:
            VStack(alignment: .leading, spacing: 2) {
                Text("Local Network access is confirmed working.")
                    .font(.caption).foregroundStyle(.secondary)
                if let d = status.devices.first {
                    Text(identityLine(for: d))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        case .foundMultiple:
            VStack(alignment: .leading, spacing: 3) {
                Text("Local Network access is confirmed working.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(status.devices) { d in
                    Text("● \(identityLine(for: d))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        case .notFound:
            Text("If macOS asked for Local Network permission and you clicked Don't Allow, open Privacy & Security below and turn it on for hdhrVCRplus under Local Network. Otherwise, make sure your HDHomeRun is powered on and on the same network.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // "HDHR-XXXXXXXX · N tuners · M channels ready" — the tuner/channel clauses are each
    // independently omitted when not yet known (nil TunerCount, or no lineup fetched for that
    // device yet), never rendered as a false "0 tuners"/"0 channels".
    private func identityLine(for device: HDHRDevice) -> String {
        var parts = ["HDHR-\(device.DeviceID.uppercased())"]
        if let tuners = device.TunerCount {
            parts.append("\(tuners) tuner\(tuners == 1 ? "" : "s")")
        }
        if let channels = status.channelCounts[device.DeviceID], channels > 0 {
            parts.append("\(channels) channels ready")
        }
        return parts.joined(separator: " · ")
    }
}

// File-scope per StarburstBadge.swift's own note: @KeyframesBuilder type inference fails on a
// type nested inside the view.
private struct CheckPopValue: Animatable {
    var scale: CGFloat = 1
    var animatableData: CGFloat {
        get { scale }
        set { scale = newValue }
    }
}
