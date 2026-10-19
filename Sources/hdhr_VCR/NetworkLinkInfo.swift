import Foundation
import Network
import CoreWLAN
import Darwin

/// How this Mac reaches a tuner (or FEED source) right now: Ethernet or Wi-Fi, the negotiated link rate, Wi-Fi signal
/// and the TCP round-trip time. Shown in the player's Stream popover. Pure helpers are unit-tested; `NetworkLinkProbe`
/// does the I/O.
struct NetworkLinkInfo: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case wifi, ethernet, other, unknown }
    var kind: Kind = .unknown
    var interface: String?
    var linkMbps: Int?        // negotiated link rate (Ethernet: interface speed; Wi-Fi: current transmit rate)
    var rssiDBm: Int?         // Wi-Fi only
    var rttMs: Double?        // median TCP connect time to the device

    var kindLabel: String {
        switch kind {
        case .wifi: return "Wi-Fi"
        case .ethernet: return "Ethernet"
        case .other: return "Network"
        case .unknown: return "Unknown"
        }
    }

    /// "Ethernet · 1 Gbps" / "Wi-Fi · 866 Mbps · −58 dBm".
    var linkText: String {
        var parts = [kindLabel]
        if let rate = linkMbps, rate > 0 { parts.append(Self.rateText(rate)) }
        if let rssi = rssiDBm { parts.append("\(rssi) dBm") }
        return parts.joined(separator: " · ")
    }

    static func rateText(_ mbps: Int) -> String {
        mbps >= 1000 && mbps % 100 == 0 ? "\(Double(mbps) / 1000) Gbps".replacingOccurrences(of: ".0 ", with: " ") : "\(mbps) Mbps"
    }

    /// Median of the samples (nil when empty) — one slow handshake shouldn't define the reading.
    static func median(_ samples: [Double]) -> Double? {
        guard !samples.isEmpty else { return nil }
        let s = samples.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Good / fair / poor from round-trip time and (Wi-Fi) signal; the worse of the two wins. nil when neither is known.
    var quality: PlayerStatusFormat.Health? {
        func rank(_ h: PlayerStatusFormat.Health) -> Int { h == .poor ? 3 : (h == .fair ? 2 : 1) }
        var results: [PlayerStatusFormat.Health] = []
        if let rtt = rttMs { results.append(rtt <= 20 ? .good : (rtt <= 50 ? .fair : .poor)) }
        if kind == .wifi, let rssi = rssiDBm { results.append(rssi >= -67 ? .good : (rssi >= -75 ? .fair : .poor)) }
        return results.max { rank($0) < rank($1) }
    }
}

enum NetworkLinkProbe {
    /// Opens `samples` short TCP connections to `host:port`, noting the interface the first one used and the median
    /// connect time. Never throws; fields it can't learn stay nil.
    static func measure(host: String, port: UInt16 = 80, samples: Int = 3) async -> NetworkLinkInfo {
        var info = NetworkLinkInfo()
        var times: [Double] = []
        var interface: NWInterface?
        for _ in 0..<samples {
            guard let r = await connectOnce(host: host, port: port) else { continue }
            times.append(r.ms)
            if interface == nil { interface = r.interface }
        }
        info.rttMs = NetworkLinkInfo.median(times)
        if let interface {
            info.interface = interface.name
            switch interface.type {
            case .wifi: info.kind = .wifi
            case .wiredEthernet: info.kind = .ethernet
            default: info.kind = .other
            }
            if info.kind == .wifi, let wifi = CWWiFiClient.shared().interface(withName: interface.name) {
                let rate = wifi.transmitRate()
                if rate > 0 { info.linkMbps = Int(rate.rounded()) }
                let rssi = wifi.rssiValue()
                if rssi != 0 { info.rssiDBm = rssi }
            } else {
                info.linkMbps = baudrateMbps(interface: interface.name)
            }
        }
        return info
    }

    /// Interface speed from `getifaddrs` (`ifi_baudrate`, bits per second) — 0 or unavailable → nil.
    static func baudrateMbps(interface name: String) -> Int? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cursor {
            if String(cString: p.pointee.ifa_name) == name,
               p.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
               let data = p.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                let bps = UInt64(data.pointee.ifi_baudrate)
                return bps > 0 ? Int(bps / 1_000_000) : nil
            }
            cursor = p.pointee.ifa_next
        }
        return nil
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func run(_ body: () -> Void) {
            lock.lock(); defer { lock.unlock() }
            guard !done else { return }
            done = true
            body()
        }
    }

    private static func connectOnce(host: String, port: UInt16) async -> (ms: Double, interface: NWInterface?)? {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let start = DispatchTime.now()
        return await withCheckedContinuation { (cont: CheckedContinuation<(ms: Double, interface: NWInterface?)?, Never>) in
            let once = Once()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
                    let iface = conn.currentPath?.availableInterfaces.first
                    once.run { conn.cancel(); cont.resume(returning: (ms, iface)) }
                case .failed, .cancelled:
                    once.run { cont.resume(returning: nil) }
                default: break
                }
            }
            conn.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                once.run { conn.cancel(); cont.resume(returning: nil) }
            }
        }
    }
}
