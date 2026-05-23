import SwiftUI
import Darwin

/// Returns true if the effective macOS major version is ≥ `major`.
/// Checks the "simulatedMacOSVersion" UserDefaults key first, so the
/// developer can preview compatibility shims on the current machine without
/// needing an older Mac (set via Settings → Maintenance → Developer).
/// 0 = unset (use real OS); storing the real version number also means "not simulating".
func effectiveMacOS(_ major: Int) -> Bool {
    let sim  = UserDefaults.standard.integer(forKey: "simulatedMacOSVersion")
    let real = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    if sim > 0 && sim != real { return sim >= major }
    return real >= major
}

/// Network interface entry for the interface picker.
struct NetworkInterfaceInfo: Identifiable {
    var id: String { name }
    let name: String
    let ip: String
    /// Display label shown in the picker — name plus IP so users can identify tunnels.
    var displayLabel: String { "\(name)  \(ip)" }
}

/// Returns true if `name` is a point-to-point (tunnel/VPN) interface by checking the
/// IFF_POINTOPOINT flag via getifaddrs. Works for any interface type regardless of name
/// (utun*, tun*, cscotun*, gpd*, zt*, ppp*, ipsec*, etc.).
func isPointToPointInterface(_ name: String) -> Bool {
    var ptr: UnsafeMutablePointer<ifaddrs>? = nil
    guard getifaddrs(&ptr) == 0 else { return false }
    defer { freeifaddrs(ptr) }
    var cur = ptr
    while let iface = cur {
        defer { cur = iface.pointee.ifa_next }
        guard String(cString: iface.pointee.ifa_name) == name else { continue }
        return iface.pointee.ifa_flags & UInt32(IFF_POINTOPOINT) != 0
    }
    return false
}

/// Returns IPv4-bearing interfaces suitable for the discovery/recording interface picker.
///
/// Tunnel/VPN detection uses IFF_POINTOPOINT rather than name prefixes, so all VPN
/// types are caught regardless of vendor naming (utun*, tun*, cscotun* for Cisco
/// AnyConnect, gpd* for GlobalProtect, zt* for ZeroTier, ppp*, ipsec*, etc.).
///
/// Point-to-point interfaces are admitted only when IFF_UP + IFF_RUNNING are set and the
/// assigned IP is routable (not link-local 169.254.x.x). System-created tunnel entries
/// without a real IP are already filtered by the AF_INET check; the flags + link-local
/// guard catches any edge cases where a non-VPN tunnel gets an IP.
///
/// Always excluded: loopback (lo*), AWDL/AirDrop (awdl*), low-latency WLAN (llw*),
/// and IPv6 transition tunnels (gif*, stf*) which are not VPN interfaces.
func availableNetworkInterfaces() -> [NetworkInterfaceInfo] {
    var results: [NetworkInterfaceInfo] = []
    var ptr: UnsafeMutablePointer<ifaddrs>? = nil
    guard getifaddrs(&ptr) == 0 else { return results }
    defer { freeifaddrs(ptr) }
    var cur = ptr
    while let iface = cur {
        defer { cur = iface.pointee.ifa_next }
        guard let addr = iface.pointee.ifa_addr,
              addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
        let name = String(cString: iface.pointee.ifa_name)
        guard !name.hasPrefix("lo"), !name.hasPrefix("awdl"), !name.hasPrefix("llw"),
              !name.hasPrefix("gif"), !name.hasPrefix("stf"),
              !results.contains(where: { $0.name == name }) else { continue }
        let flags = iface.pointee.ifa_flags
        var ip = ""
        addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &sin.pointee.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
            ip = String(cString: buf)
        }
        // Point-to-point flag identifies all tunnel/VPN types regardless of name.
        if flags & UInt32(IFF_POINTOPOINT) != 0 {
            guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_RUNNING) != 0 else { continue }
            guard !ip.hasPrefix("169.254.") else { continue }
        }
        results.append(NetworkInterfaceInfo(name: name, ip: ip))
    }
    return results.sorted { $0.name < $1.name }
}

// MARK: - EmptyStateView

/// Compatibility wrapper for ContentUnavailableView (macOS 14+).
/// Shows the native view on macOS 14+ unless an older OS is being simulated.
struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage,
                               description: Text(description))
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
