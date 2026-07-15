import Foundation
import Darwin

final class HDHRManager {
    // Short-timeout session for discovery; regular session for data transfers
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest  = 2
        c.timeoutIntervalForResource = 6
        return URLSession(configuration: c)
    }()
    private let dataSession = URLSession.shared
    private let cloudDiscoveryURL = URL(string: "http://discover.hdhomerun.com/discover.json")!

    // MARK: - Device Discovery

    /// Discover HDHomeRun devices on the local network.
    ///
    /// Always probes hdhomerun.local (mDNS) and UDP broadcast concurrently so all device
    /// types are found in a single pass. mDNS is the primary source for EXTEND devices;
    /// UDP catches any additional tuners that don't respond to mDNS. Results are merged
    /// and DeviceAuth is supplemented from cloud for any device missing it.
    func discoverDevices(knownHosts: [String] = [], interface: String = "") async throws -> [HDHRDevice] {
        // Run all three paths concurrently — known hosts (fastest on stable networks),
        // mDNS (EXTEND devices), and UDP broadcast (all other tuner types)
        async let knownHostDevices = knownHostsDiscover(ips: knownHosts)
        async let mdnsDevices      = mDNSDiscover()
        async let udpDevices       = udpDiscoverAndFetch(interface: interface)

        let fromKnown = await knownHostDevices
        let fromMDNS  = (try? await mdnsDevices) ?? []
        let fromUDP   = await udpDevices

        var found = fromKnown
        for dev in fromMDNS where !found.contains(where: { $0.DeviceID == dev.DeviceID }) { found.append(dev) }
        for dev in fromUDP  where !found.contains(where: { $0.DeviceID == dev.DeviceID }) { found.append(dev) }
        glog("[Discovery] known=\(fromKnown.count) mDNS=\(fromMDNS.count) UDP=\(fromUDP.count) merged=\(found.count)")

        if found.isEmpty {
            guard let cloud = try? await cloudDiscover(), !cloud.isEmpty else {
                throw URLError(.cannotFindHost)
            }
            return cloud
        }

        // Supplement DeviceAuth from cloud for EXTEND devices that need it for the guide API
        if found.contains(where: { $0.DeviceAuth == nil }),
           let cloud = try? await cloudDiscover(), !cloud.isEmpty {
            found = supplementDeviceAuth(local: found, cloud: cloud)
            glog("[Discovery] DeviceAuth supplemented from cloud")
        }

        return found
    }

    /// Direct HTTP lookup for device IPs extracted from saved show URLs — fastest path on stable networks.
    private func knownHostsDiscover(ips: [String]) async -> [HDHRDevice] {
        guard !ips.isEmpty else { return [] }
        return await withTaskGroup(of: HDHRDevice?.self) { group in
            for ip in ips {
                group.addTask { try? await self.fetchDeviceInfo(ip: ip) }
            }
            var found: [HDHRDevice] = []
            for await d in group {
                if let d, !found.contains(where: { $0.DeviceID == d.DeviceID }) { found.append(d) }
            }
            return found
        }
    }

    /// Run UDP broadcast discovery and follow up each reply with a fetchDeviceInfo call.
    private func udpDiscoverAndFetch(interface: String = "") async -> [HDHRDevice] {
        let raw = await udpDiscover(interface: interface)
        guard !raw.isEmpty else { return [] }
        return await withTaskGroup(of: HDHRDevice?.self) { group in
            for device in raw {
                group.addTask { (try? await self.fetchDeviceInfo(ip: device.LocalIP)) ?? device }
            }
            var result: [HDHRDevice] = []
            for await d in group { if let d { result.append(d) } }
            return result
        }
    }

    /// Copy DeviceAuth into locally-discovered devices that are missing it.
    /// Prefers auth already present on another local device (same network = same SiliconDust
    /// account) over the cloud's per-device auth — cloud may return a device-specific token
    /// that doesn't cover the guide subscription (e.g. mock device with test DeviceID).
    private func supplementDeviceAuth(local: [HDHRDevice], cloud: [HDHRDevice]) -> [HDHRDevice] {
        let localAuth = local.compactMap { $0.DeviceAuth }.first
        return local.map { dev in
            guard dev.DeviceAuth == nil else { return dev }
            var updated = dev
            updated.DeviceAuth = localAuth
                              ?? cloud.first(where: { $0.DeviceID == dev.DeviceID })?.DeviceAuth
            return updated
        }
    }

    /// mDNS discovery via the well-known hdhomerun.local multicast hostname.
    private func mDNSDiscover() async throws -> [HDHRDevice] {
        guard let url = URL(string: "http://hdhomerun.local/discover.json") else { throw URLError(.badURL) }
        let (data, _) = try await session.data(from: url)
        // Response may be a single object or an array
        if let arr = try? JSONDecoder().decode([HDHRDevice].self, from: data), !arr.isEmpty {
            return arr
        }
        let single = try JSONDecoder().decode(HDHRDevice.self, from: data)
        return [single]
    }

    private func cloudDiscover() async throws -> [HDHRDevice] {
        let (data, _) = try await session.data(from: cloudDiscoveryURL)
        return try JSONDecoder().decode([HDHRDevice].self, from: data)
    }

    /// Fetch full device info from the device's own HTTP API.
    private func fetchDeviceInfo(ip: String) async throws -> HDHRDevice {
        guard let url = URL(string: "http://\(ip)/discover.json") else { throw URLError(.badURL) }
        let (data, _) = try await session.data(from: url)
        return try JSONDecoder().decode(HDHRDevice.self, from: data)
    }

    // MARK: - UDP Local Discovery

    /// Broadcast SiliconDust discovery packet on the local network and collect replies.
    /// Blocks for up to 2 seconds waiting for device responses.
    private func udpDiscover(interface: String = "") async -> [HDHRDevice] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.udpDiscoverSync(interface: interface))
            }
        }
    }

    /// Subnet-directed broadcast address (e.g. 10.0.3.255) for each active, non-loopback,
    /// non-point-to-point IPv4 interface — or just the named one if `interface` is non-empty.
    /// Values are raw sin_addr.s_addr bit patterns (already in network byte order), computed as
    /// (addr | ~netmask) via bitwise ops that are byte-order agnostic.
    private static func subnetBroadcastAddresses(interface: String) -> [in_addr_t] {
        var results: [in_addr_t] = []
        var ptr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ptr) == 0 else { return results }
        defer { freeifaddrs(ptr) }
        var cur = ptr
        while let iface = cur {
            defer { cur = iface.pointee.ifa_next }
            let flags = iface.pointee.ifa_flags
            guard flags & UInt32(IFF_UP) != 0,
                  flags & UInt32(IFF_LOOPBACK) == 0,
                  flags & UInt32(IFF_POINTOPOINT) == 0,
                  let addrPtr = iface.pointee.ifa_addr, addrPtr.pointee.sa_family == sa_family_t(AF_INET),
                  let maskPtr = iface.pointee.ifa_netmask, maskPtr.pointee.sa_family == sa_family_t(AF_INET)
            else { continue }
            let name = String(cString: iface.pointee.ifa_name)
            guard interface.isEmpty || name == interface else { continue }
            let addr = addrPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let mask = maskPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            results.append(addr | ~mask)
        }
        return results
    }

    private static func udpDiscoverSync(interface: String = "") -> [HDHRDevice] {
        // Tunnel/VPN interfaces don't support broadcast — skip UDP entirely.
        // Known-hosts discovery handles remote devices via their saved IPs.
        guard interface.isEmpty || !isPointToPointInterface(interface) else {
            glog("[Discovery] UDP skipped — \(interface) is a tunnel, no broadcast support", level: .warning)
            return []
        }

        var found: [HDHRDevice] = []

        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { return found }
        defer { Darwin.close(sock) }

        // Enable broadcast and set a 2-second receive timeout
        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Bind to a specific interface when requested (IP_BOUND_IF = 25 on macOS)
        if !interface.isEmpty {
            var ifIndex = if_nametoindex(interface)
            if ifIndex > 0 {
                setsockopt(sock, IPPROTO_IP, IP_BOUND_IF, &ifIndex, socklen_t(MemoryLayout<UInt32>.size))
            } else {
                // Interface name not recognised by the kernel — bind is skipped and UDP goes
                // out on the OS default route. Log so the user can spot a misconfigured name.
                glog("[Discovery] UDP: if_nametoindex('\(interface)') returned 0 — unknown interface, binding skipped", level: .warning)
            }
        }

        // Discovery request packet
        // Payload TLV: tag=0x01 (DeviceType), len=4, value=0xFFFFFFFF (wildcard)
        let payload: [UInt8] = [0x01, 0x04, 0xFF, 0xFF, 0xFF, 0xFF]
        var pkt: [UInt8] = [0x00, 0x02,                                 // type = DISCOVER_REQUEST
                             UInt8(payload.count >> 8),
                             UInt8(payload.count & 0xFF)] + payload
        let crcVal = crc32(pkt)
        pkt += withUnsafeBytes(of: crcVal.littleEndian) { Array($0) }

        // Send to each active interface's subnet-directed broadcast (e.g. 10.0.3.255), plus the
        // global 255.255.255.255 as a best-effort extra. Some setups — a Thunderbolt Bridge or
        // Internet Sharing adding a second "default" route (visible as a reject route in `netstat -rn`)
        // — cause the kernel to route global broadcast into that dead route (EHOSTUNREACH/errno 65)
        // even though the subnet is perfectly reachable, so global broadcast alone can silently find
        // nothing while every device is one directed broadcast away.
        var targets = subnetBroadcastAddresses(interface: interface)
        targets.append(0xFFFFFFFF)  // INADDR_BROADCAST — kept as a fallback for setups where it works

        for targetAddr in targets {
            var dst = sockaddr_in()
            dst.sin_family      = sa_family_t(AF_INET)
            dst.sin_port        = in_port_t(65001).bigEndian
            dst.sin_addr.s_addr = targetAddr

            pkt.withUnsafeBytes { raw in
                withUnsafePointer(to: dst) { dstPtr in
                    dstPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                        let sent = sendto(sock, raw.baseAddress!, pkt.count, 0, saPtr,
                                          socklen_t(MemoryLayout<sockaddr_in>.size))
                        // The global-broadcast fallback failing is expected on networks with a
                        // second default route (see above) — only warn for directed-broadcast
                        // failures, which indicate a real problem reaching the local subnet.
                        if sent < 0 && targetAddr != 0xFFFFFFFF {
                            glog("UDP sendto failed: errno \(errno)", level: .warning)
                        }
                    }
                }
            }
        }

        // Collect replies until timeout
        var buf    = [UInt8](repeating: 0, count: 1024)
        var from   = sockaddr_in()
        var seenIPs = Set<String>()

        let bufCapacity = buf.count
        while true {
            // fromLen must reset before each recvfrom; the syscall may reduce it
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = buf.withUnsafeMutableBytes { raw -> Int in
                withUnsafeMutablePointer(to: &from) { fromPtr in
                    fromPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                        recvfrom(sock, raw.baseAddress!, bufCapacity, 0, saPtr, &fromLen)
                    }
                }
            }
            if n <= 0 {
                if n < 0 && errno == EINTR { continue }  // signal interrupt — retry
                break                                     // SO_RCVTIMEO expired (EAGAIN) or error
            }
            guard n > 8, buf[0] == 0x00, buf[1] == 0x03 else { continue }  // DISCOVER_REPLY = 0x0003

            // Parse TLV payload for DeviceID tag (0x02).
            // payloadLen is attacker-controlled (2 bytes straight from the packet, up to 65535)
            // and must never be trusted alone — bound the loop against the actual bytes received
            // (n) and the fixed buffer capacity too, or a reply claiming a huge payloadLen while
            // sending few actual bytes walks `off` past `buf`'s bounds and traps the whole app.
            let payloadLen = Int(buf[2]) << 8 | Int(buf[3])
            let limit = min(4 + payloadLen, n, bufCapacity)
            var off = 4
            var deviceID: UInt32 = 0
            while off + 2 <= limit {
                let tag = buf[off], tagLen = Int(buf[off + 1])
                off += 2
                if off + tagLen > limit { break }
                if tag == 0x02, tagLen == 4 {
                    deviceID = UInt32(buf[off]) << 24 | UInt32(buf[off+1]) << 16
                             | UInt32(buf[off+2]) << 8  | UInt32(buf[off+3])
                }
                off += tagLen
            }

            // Convert source address to IP string
            let ipStr: String = withUnsafePointer(to: from.sin_addr) { addrPtr in
                var strBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, addrPtr, &strBuf, socklen_t(INET_ADDRSTRLEN))
                return String(cString: strBuf)
            }
            guard !seenIPs.contains(ipStr) else { continue }
            seenIPs.insert(ipStr)

            found.append(HDHRDevice(DeviceID: String(format: "%08X", deviceID),
                                    LocalIP: ipStr, BaseURL: "http://\(ipStr)",
                                    TunerCount: nil, FirmwareVersion: nil))
        }
        return found
    }

    // Standard CRC-32 (ISO 3309, polynomial 0xEDB88320)
    private static func crc32(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1 }
        }
        return ~crc
    }

    // MARK: - Lineup

    func fetchLineup(for device: HDHRDevice) async throws -> [LineupEntry] {
        guard let url = URL(string: device.lineupURL) else { throw URLError(.badURL) }
        let (data, _) = try await dataSession.data(from: url)
        let entries = try JSONDecoder().decode([LineupEntry].self, from: data)
        return entries
    }

    func streamURL(for channel: String, lineup: [LineupEntry]) -> String? {
        lineup.first { $0.GuideNumber == channel }?.URL
    }

    /// Toggle the favorite flag for a channel on the device.
    /// POST http://{device-ip}/lineup.post?favorite=+GuideNumber  (mark)
    /// POST http://{device-ip}/lineup.post?favorite=-GuideNumber  (unmark)
    func setFavorite(device: HDHRDevice, channel: LineupEntry, favorite: Bool) async throws {
        let prefix = favorite ? "+" : "-"
        guard let url = URL(string: "http://\(device.LocalIP)/lineup.post?favorite=\(prefix)\(channel.GuideNumber)") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let (_, resp) = try await dataSession.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            glog("[Favorite] device returned HTTP \(http.statusCode) for \(url)", level: .error)
            throw URLError(.badServerResponse)
        }
    }

}
