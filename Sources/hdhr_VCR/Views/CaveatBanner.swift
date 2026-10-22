import SwiftUI
import AppKit

// A muted informational/caveat banner — soft-tinted background rather than the solid saturated
// orange fill + white text this used to be everywhere (transcode-mismatch warnings, the XMLTV
// caveat note, etc.) — found too heavy/alarming in light mode during testing: a "this has a
// caveat" note doesn't need the same visual weight as an actual error block. Mirrors the About
// tab's own soft-tinted "Current Version" highlight box (Color.accentColor.opacity(0.12) fill,
// thin stroke) rather than inventing a second "quietly highlighted" convention. `tint` defaults to
// `.orange` (every call site so far is a warning/caveat) but isn't hardcoded — a future
// differently-toned banner (e.g. a blue "info" or green "success" note) can reuse this component
// instead of reintroducing a bespoke inline Label block or a near-duplicate copy of this struct.
// A system dynamic color as a foreground/tint (not a solid fill) reads correctly in both light and
// dark mode with no separate per-appearance tuning, for any color passed here.
struct CaveatBanner: View {
    let text: String
    var systemImage: String = "exclamationmark.triangle.fill"
    var tint: Color = .orange

    // Text/icon colour: the system tint itself fails WCAG AA (4.5:1) on its own 12% wash in light
    // mode (system orange is ~2.2:1), so light appearance blends it 45% toward black (orange -> ~5.6:1);
    // dark appearance keeps the tint unchanged. Resolved per appearance by a dynamic NSColor.
    private var textColor: Color {
        let base = NSColor(tint)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            var resolved = base
            appearance.performAsCurrentDrawingAppearance {
                resolved = base.usingColorSpace(.sRGB) ?? base
            }
            guard !isDark else { return resolved }
            return resolved.blended(withFraction: 0.45, of: .black) ?? resolved
        })
    }

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(textColor)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(tint.opacity(0.35), lineWidth: 1)
            )
    }
}
