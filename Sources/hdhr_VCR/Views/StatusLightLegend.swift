import SwiftUI

// About tab: the logo mirrors the menu-bar light as it is right now, and a legend explains every light
// and blink pattern. Observes `StatusLightModel` only (never AppState) — the same narrow observation the
// menu-bar label uses, so a 1 Hz light tick doesn't re-render the whole Settings window
// (docs/MenuContent.md "Menu Bar Icon States", review #21).

/// The full-size mark for a light state (`nil` = idle). Falls back to the idle mark if a variant is missing.
func fullSizeStatusImage(for kind: AppState.StatusLightKind?, lit: Bool) -> NSImage? {
    guard lit, let kind else { return appIconImage }
    switch kind {
    case .recording: return appIconRecordingImage ?? appIconImage
    case .upNext: return appIconUpNextImage ?? appIconImage
    case .feedAvailable, .feedWatching: return appIconFeedImage ?? appIconImage
    }
}

/// The About logo: whatever the menu-bar icon is showing this second (lit or in its off frame).
struct AboutLogo: View {
    @ObservedObject var light: StatusLightModel

    var body: some View {
        Group {
            if let icon = fullSizeStatusImage(for: light.active, lit: light.on) {
                Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).cornerRadius(12)
            } else {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 80)).foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("hdhrVCRplus app icon, matching the menu bar status light")
    }
}

struct StatusLightLegend: View {
    let blinkEnabled: Bool

    private struct Entry: Identifiable {
        let id: String
        let kind: AppState.StatusLightKind?
        let title: String
        let detail: String
    }

    private var entries: [Entry] {
        let blink = blinkEnabled ? "blinks (5 s on, 1 s off)" : "stays solid (“Blink menu bar icon” is off)"
        return [
            Entry(id: "idle", kind: nil, title: "No light", detail: "Idle. Nothing recording, nothing coming up within the hour."),
            Entry(id: "rec", kind: .recording, title: "Red", detail: "Recording in progress — \(blink)."),
            Entry(id: "next", kind: .upNext(minutes: 0), title: "Amber", detail: "A recording starts within the hour — \(blink)."),
            Entry(id: "feed", kind: .feedAvailable, title: "Blue, blinking", detail: "Another Mac is recording and its FEED is ready to watch — always blinks, whatever the setting."),
            Entry(id: "watch", kind: .feedWatching, title: "Blue, solid", detail: "You are watching a FEED from another Mac."),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Menu bar light").font(.subheadline).bold()
            ForEach(entries) { e in
                HStack(alignment: .center, spacing: 10) {
                    Image(nsImage: fullSizeStatusImage(for: e.kind, lit: true) ?? NSImage())
                        .resizable().aspectRatio(contentMode: .fit)
                        .frame(width: 28, height: 28).cornerRadius(5)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.title).font(.caption).bold()
                        Text(e.detail).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Text("The icon is dimmed while the app is starting up. If several lights apply, they take turns (6 s each); recording and FEED outrank up-next.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 440, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
