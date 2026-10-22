import SwiftUI

// About tab: the logo mirrors the menu-bar light as it is right now, and clicking the logo steps through every light
// and blink pattern, then returns to the live state after a few idle seconds. Observes `StatusLightModel` only (never AppState) — the same narrow observation the
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
        .accessibilityHidden(true)   // decorative: the "What do the lights mean?" button and the text below carry the meaning
    }
}

/// The About logo plus a small text-only description. By default both show the live menu-bar light; each
/// click on the logo steps to the next light (none → red → amber → blue flashing → blue solid), showing
/// that light's image (with its blink pattern) and what it means, and `previewTimeout` of no clicks
/// returns to live. Observes `StatusLightModel` only — never AppState.
struct AboutStatusLight: View {
    @ObservedObject var light: StatusLightModel
    let blinkEnabled: Bool
    var previewTimeout: Duration = .seconds(8)

    @State private var preview: Int? = nil
    @State private var clicks = 0
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Entry: Identifiable {
        let id: String
        let kind: AppState.StatusLightKind?
        let title: String
        let detail: String
        let blinks: Bool
    }

    private var entries: [Entry] {
        let blink = blinkEnabled ? "blinks (5 s on, 1 s off)" : "stays solid (“Blink menu bar icon” is off)"
        return [
            Entry(id: "idle", kind: nil, title: "No light", detail: "Idle. Nothing recording, nothing coming up within the hour.", blinks: false),
            Entry(id: "rec", kind: .recording, title: "Red", detail: "Recording in progress — \(blink).", blinks: blinkEnabled),
            Entry(id: "next", kind: .upNext(minutes: 0), title: "Amber", detail: "A recording starts within the hour — \(blink).", blinks: blinkEnabled),
            Entry(id: "feed", kind: .feedAvailable, title: "Blue, blinking", detail: "Another Mac is recording and its FEED is ready to watch — always blinks, whatever the setting.", blinks: true),
            Entry(id: "watch", kind: .feedWatching, title: "Blue, solid", detail: "You are watching a FEED from another Mac.", blinks: false),
        ]
    }

    private func color(_ kind: AppState.StatusLightKind?) -> Color {
        switch kind {
        case nil: return .secondary
        case .recording: return .red
        case .upNext: return .orange
        case .feedAvailable, .feedWatching: return .blue
        }
    }

    /// Index of the entry matching the live light.
    private var liveIndex: Int {
        switch light.active {
        case nil: return 0
        case .recording: return 1
        case .upNext: return 2
        case .feedAvailable: return 3
        case .feedWatching: return 4
        }
    }

    private func advance(_ count: Int) {
        preview = ((preview ?? liveIndex) + 1) % count
        clicks += 1
    }

    var body: some View {
        let list = entries
        let shown = list[preview ?? liveIndex]
        VStack(spacing: 8) {
            logo(for: shown)
                .frame(width: 180, height: 180)
                // Obviously clickable: hover ring + slight lift + pointing-hand cursor, and a real button below.
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor.opacity(hovering ? 0.8 : 0), lineWidth: 2))
                .scaleEffect(hovering ? 1.03 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
                .contentShape(Rectangle())
                .onHover { inside in
                    hovering = inside
                    if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                .onTapGesture { advance(list.count) }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Steps through the menu bar light states")
            Button { advance(list.count) } label: {
                Label(preview == nil ? "What do the lights mean?" : "Next light", systemImage: "chevron.right.circle")
            }
            .controlSize(.small)
            VStack(spacing: 3) {
                Text(preview == nil ? "Right now" : "\((preview ?? 0) + 1) of \(list.count)")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                Text(shown.title).font(.system(size: 12)).bold().foregroundStyle(color(shown.kind))
                Text(shown.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if preview != nil {
                    Text("Returns to the live light shortly.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: 320)
        }
        .task(id: clicks) {
            guard clicks > 0 else { return }
            try? await Task.sleep(for: previewTimeout)
            if !Task.isCancelled { preview = nil }
        }
        .onDisappear { if hovering { NSCursor.pop(); hovering = false } }
    }

    @ViewBuilder
    private func logo(for shown: Entry) -> some View {
        if preview == nil {
            AboutLogo(light: light)
        } else {
            // Previewed light: simulate the 5 s on / 1 s off blink the menu bar uses.
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                // Reduce Motion: no blinking, the preview stays lit.
                let lit = reduceMotion || !shown.blinks || Int(ctx.date.timeIntervalSinceReferenceDate) % 6 != 5
                if let icon = fullSizeStatusImage(for: shown.kind, lit: lit) {
                    Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).cornerRadius(12)
                        .accessibilityHidden(true)
                }
            }
        }
    }
}
