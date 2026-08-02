import SwiftUI
import Darwin

// MARK: - CRC-32

// IEEE 802.3 / ISO 3309 (polynomial 0xEDB88320) — shared by HDHRManager's UDP discovery packet
// trailer and WebServer's gzip response trailer. Both are cold paths (once per discovery packet,
// once per gzip response), so a table-driven scalar loop is plenty; no need for Data's
// withUnsafeBytes fast path here.
private let crc32Table: [UInt32] = (0..<256).map { i in
    var c = UInt32(i)
    for _ in 0..<8 { c = (c & 1) == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    return c
}

func crc32<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
    var c: UInt32 = 0xFFFF_FFFF
    for b in bytes { c = crc32Table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
    return c ^ 0xFFFF_FFFF
}

struct NetworkInterfaceInfo: Identifiable {
    var id: String { name }
    let name: String
    let ip: String
    var displayLabel: String { "\(name)  \(ip)" }
}

// IFF_POINTOPOINT catches all tunnel/VPN types (utun*, cscotun*, gpd*, zt*, etc.) regardless of name prefix.
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

// Returns IPv4 interfaces for the discovery/recording NIC picker.
// VPN/tunnel interfaces are admitted only if UP+RUNNING and non-link-local; loopback, AWDL, llw, gif, stf excluded.
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


