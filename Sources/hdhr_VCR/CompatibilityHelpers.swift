import SwiftUI

/// Returns true if the effective macOS major version is ≥ `major`.
/// Checks the "simulatedMacOSVersion" UserDefaults key first, so the
/// developer can preview compatibility shims on the current machine without
/// needing an older Mac (set via Settings → Maintenance → Developer).
/// 0 = use the real running OS; 13/14/15 = simulate that version.
func effectiveMacOS(_ major: Int) -> Bool {
    let sim = UserDefaults.standard.integer(forKey: "simulatedMacOSVersion")
    if sim > 0 { return sim >= major }
    return ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= major
}

// MARK: - EmptyStateView

/// Compatibility wrapper for ContentUnavailableView (macOS 14+).
/// Shows the native view on macOS 14+ unless an older OS is being simulated.
struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        if effectiveMacOS(14), #available(macOS 14, *) {
            ContentUnavailableView(title, systemImage: systemImage,
                                   description: Text(description))
        } else {
            VStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.system(size: 48)).foregroundStyle(.secondary)
                Text(title).font(.title3).fontWeight(.semibold)
                Text(description).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Scroll offset tracking

struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGPoint = .zero
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) { value = nextValue() }
}

extension View {
    /// Tracks the content offset of the nearest enclosing ScrollView and calls
    /// `onChange` when it changes by ≥ 1 pt on either axis.
    ///
    /// On macOS 15+ (or when not simulating an older OS) uses the native
    /// `onScrollGeometryChange`. On macOS 13/14 (or when the simulation is
    /// active) uses a PreferenceKey + GeometryReader placed in the view's
    /// background, reading position relative to `coordinateSpaceName` — which
    /// must match the `.coordinateSpace(name:)` applied to the ScrollView.
    @ViewBuilder
    func onScrollOffset(coordinateSpaceName: String,
                        onChange: @escaping (CGPoint) -> Void) -> some View {
        if effectiveMacOS(15), #available(macOS 15, *) {
            self.onScrollGeometryChange(for: CGPoint.self,
                                        of: { $0.contentOffset }) { old, pt in
                if abs(pt.x - old.x) >= 1 || abs(pt.y - old.y) >= 1 { onChange(pt) }
            }
        } else {
            self
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: ScrollOffsetPreferenceKey.self,
                            value: CGPoint(
                                x: -geo.frame(in: .named(coordinateSpaceName)).origin.x,
                                y: -geo.frame(in: .named(coordinateSpaceName)).origin.y
                            )
                        )
                    }
                )
                .onPreferenceChange(ScrollOffsetPreferenceKey.self, perform: onChange)
        }
    }
}
