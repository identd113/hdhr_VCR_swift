import Foundation
import Darwin

final class HDHRManager {
    // Short-timeout session for discovery; regular session for data transfers
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest  = 5
        c.timeoutIntervalForResource = 10
        return URLSession(configuration: c)
    }()
    private let dataSession = URLSession.shared
    private let cloudDiscoveryURL = URL(string: "http://discover.hdhomerun.com/discover.json")!

    // MARK: - Device Discovery

    /// Discover devices. Tries known hosts from saved shows first (fastest path when IP is stable),
    /// then falls back to mDNS → cloud → UDP broadcast.
    func discoverDevices(knownHosts: [String] = []) async throws -> [HDHRDevice] {
        // Known hosts from saved show URLs — avoids full network scan on stable networks
        if !knownHosts.isEmpty {
            let direct = await withTaskGroup(of: HDHRDevice?.self) { group in
                for host in knownHosts {
                    group.addTask { try? await self.fetchDeviceInfo(ip: host) }
                }
                var found: [HDHRDevice] = []
                for await d in group {
                    if let d, !found.contains(where: { $0.DeviceID == d.DeviceID }) { found.append(d) }
                }
                return found
            }
            if !direct.isEmpty {
                print("[Discovery] Found \(direct.count) device(s) via known hosts")
                return direct
            }
        }
        // mDNS — works on local network without internet, preferred for EXTEND devices
        if let mdns = try? await mDNSDiscover(), !mdns.isEmpty {
            return mdns
        }
        // Cloud discovery (requires device to be registered with SiliconDust)
        if let cloud = try? await cloudDiscover(), !cloud.isEmpty {
            return cloud
        }
        // Local UDP broadcast discovery (works without internet, no mDNS)
        let local = await udpDiscover()
        guard !local.isEmpty else { throw URLError(.cannotFindHost) }
        return await withTaskGroup(of: HDHRDevice?.self) { group in
            for device in local {
                group.addTask { (try? await self.fetchDeviceInfo(ip: device.LocalIP)) ?? device }
            }
            var result: [HDHRDevice] = []
            for await d in group { if let d { result.append(d) } }
            return result
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
    private func udpDiscover() async -> [HDHRDevice] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.udpDiscoverSync())
            }
        }
    }

    private static func udpDiscoverSync() -> [HDHRDevice] {
        var found: [HDHRDevice] = []

        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { return found }
        defer { Darwin.close(sock) }

        // Enable broadcast and set a 2-second receive timeout
        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Discovery request packet
        // Payload TLV: tag=0x01 (DeviceType), len=4, value=0xFFFFFFFF (wildcard)
        let payload: [UInt8] = [0x01, 0x04, 0xFF, 0xFF, 0xFF, 0xFF]
        var pkt: [UInt8] = [0x00, 0x02,                                 // type = DISCOVER_REQUEST
                             UInt8(payload.count >> 8),
                             UInt8(payload.count & 0xFF)] + payload
        let crcVal = crc32(pkt)
        pkt += withUnsafeBytes(of: crcVal.littleEndian) { Array($0) }

        // Broadcast to 255.255.255.255:65001
        var dst = sockaddr_in()
        dst.sin_family   = sa_family_t(AF_INET)
        dst.sin_port     = in_port_t(65001).bigEndian
        dst.sin_addr.s_addr = 0xFFFFFFFF  // INADDR_BROADCAST

        pkt.withUnsafeBytes { raw in
            withUnsafePointer(to: dst) { dstPtr in
                dstPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    _ = sendto(sock, raw.baseAddress!, pkt.count, 0, saPtr,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        // Collect replies until timeout
        var buf    = [UInt8](repeating: 0, count: 1024)
        var from   = sockaddr_in()
        var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        var seenIPs = Set<String>()

        let bufCapacity = buf.count
        while true {
            let n = buf.withUnsafeMutableBytes { raw -> Int in
                withUnsafeMutablePointer(to: &from) { fromPtr in
                    fromPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                        recvfrom(sock, raw.baseAddress!, bufCapacity, 0, saPtr, &fromLen)
                    }
                }
            }
            guard n > 8, buf[0] == 0x00, buf[1] == 0x03 else { break }  // DISCOVER_REPLY = 0x0003

            // Parse TLV payload for DeviceID tag (0x02)
            let payloadLen = Int(buf[2]) << 8 | Int(buf[3])
            var off = 4
            var deviceID: UInt32 = 0
            while off + 2 <= 4 + payloadLen {
                let tag = buf[off], tagLen = Int(buf[off + 1])
                off += 2
                if off + tagLen > 4 + payloadLen { break }
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
        return try JSONDecoder().decode([LineupEntry].self, from: data)
    }

    func streamURL(for channel: String, lineup: [LineupEntry]) -> String? {
        lineup.first { $0.GuideNumber == channel }?.URL
    }

}
