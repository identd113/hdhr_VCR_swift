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

/// Returns IPv4-bearing interfaces suitable for the discovery/recording interface picker.
///
/// Physical/WiFi interfaces (en*, eth*) are always included when up.
/// Tunnel interfaces (utun*, ipsec*, ppp*) are included only when they look like active
/// VPN tunnels: IFF_UP + IFF_RUNNING flags set, and a routable (non-link-local) IPv4
/// address assigned. On macOS, system-created utun interfaces (boot-time kernel entries,
/// Network Extension content filters, etc.) are typically created without a routable IPv4
/// address, so this filter naturally excludes them while admitting real VPN connections
/// (OpenVPN, WireGuard, Tailscale, macOS built-in IKEv2/L2TP, etc.).
///
/// Always excluded: loopback (lo*), AWDL/AirDrop (awdl*), low-latency WLAN (llw*).
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
              !results.contains(where: { $0.name == name }) else { continue }
        var ip = ""
        addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &sin.pointee.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
            ip = String(cString: buf)
        }
        let isTunnel = name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp")
        if isTunnel {
            let flags = iface.pointee.ifa_flags
            // Must be actively up and running
            guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_RUNNING) != 0 else { continue }
            // Link-local (169.254.x.x) is self-assigned and never a VPN endpoint
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
