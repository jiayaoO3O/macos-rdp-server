import Foundation
import Darwin

/// One IPv4 address on an active, non-loopback, non-virtual interface.
public struct LANInterface: Equatable, Sendable, Codable {
    public let name: String
    public let address: String

    public init(name: String, address: String) {
        self.name = name
        self.address = address
    }
}

/// LAN address discovery, mirroring internal/config/lan_address.go closely
/// enough for display and certificate SANs. The Worker remains authoritative:
/// with address "auto" it selects the address itself and the app only reads the
/// selected address back from the Worker log.
public enum LANAddress {
    private struct Candidate {
        let name: String
        let index: Int
        let up: Bool
        let loopback: Bool
        let address: String
    }

    /// All eligible private IPv4 addresses, lowest interface rank first.
    public static func eligibleInterfaces() -> [LANInterface] {
        candidates()
            .filter(isEligible)
            .sorted(by: rankOrder)
            .map { LANInterface(name: $0.name, address: $0.address) }
    }

    /// Best-effort current LAN address: the default-route source address when it
    /// is an eligible interface, otherwise the highest-ranked eligible one.
    public static func select() -> LANInterface? {
        let eligible = eligibleInterfaces()
        guard !eligible.isEmpty else { return nil }
        if let route = defaultRouteAddress(),
           let match = eligible.first(where: { $0.address == route }) {
            return match
        }
        return eligible[0]
    }

    /// Unique private IPv4 addresses for certificate subjectAltName entries.
    public static func privateIPv4Addresses() -> [String] {
        var seen = Set<String>()
        var results: [String] = []
        for entry in eligibleInterfaces() where !seen.contains(entry.address) {
            seen.insert(entry.address)
            results.append(entry.address)
        }
        return results
    }

    public static func isValidIPv4(_ value: String) -> Bool {
        var address = in_addr()
        return value.withCString({ inet_pton(AF_INET, $0, &address) }) == 1
    }

    /// RFC 1918 only: 10/8, 172.16/12, 192.168/16.
    public static func isPrivateIPv4(_ value: String) -> Bool {
        var address = in_addr()
        guard value.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else { return false }
        let raw = UInt32(bigEndian: address.s_addr)
        let first = UInt8((raw >> 24) & 0xFF)
        let second = UInt8((raw >> 16) & 0xFF)
        if first == 10 { return true }
        if first == 172, (16...31).contains(second) { return true }
        if first == 192, second == 168 { return true }
        return false
    }

    private static func rankOrder(_ left: Candidate, _ right: Candidate) -> Bool {
        let leftRank = interfaceRank(left.name)
        let rightRank = interfaceRank(right.name)
        if leftRank != rightRank { return leftRank < rightRank }
        return left.index < right.index
    }

    private static func interfaceRank(_ name: String) -> Int {
        let lower = name.lowercased()
        if lower == "en0" { return 0 }
        if lower.hasPrefix("en") { return 1 }
        return 2
    }

    private static func isEligible(_ candidate: Candidate) -> Bool {
        guard candidate.up, !candidate.loopback,
              isValidIPv4(candidate.address),
              isPrivateIPv4(candidate.address) else {
            return false
        }
        let name = candidate.name.lowercased()
        for prefix in ["utun", "awdl", "llw", "bridge", "gif", "stf", "anpi", "p2p", "tap", "tun", "vmenet"] {
            if name.hasPrefix(prefix) { return false }
        }
        return true
    }

    private static func candidates() -> [Candidate] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }
        var results: [Candidate] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            let flags = Int32(entry.pointee.ifa_flags)
            if let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(address,
                                         socklen_t(address.pointee.sa_len),
                                         &host,
                                         socklen_t(host.count),
                                         nil,
                                         0,
                                         NI_NUMERICHOST)
                if result == 0 {
                    let name = String(cString: entry.pointee.ifa_name)
                    results.append(Candidate(name: name,
                                             index: Int(if_nametoindex(entry.pointee.ifa_name)),
                                             up: flags & IFF_UP != 0,
                                             loopback: flags & IFF_LOOPBACK != 0,
                                             address: String(cString: host)))
                }
            }
            cursor = entry.pointee.ifa_next
        }
        return results
    }

    /// A UDP connect only asks the kernel to pick a route; no packet is sent.
    private static func defaultRouteAddress() -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var target = sockaddr_in()
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = in_port_t(9).bigEndian
        var targetAddress = in_addr()
        guard "192.0.2.1".withCString({ inet_pton(AF_INET, $0, &targetAddress) }) == 1 else { return nil }
        target.sin_addr = targetAddress
        let connected = withUnsafePointer(to: &target) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                connect(fd, address, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                getsockname(fd, address, &length)
            }
        }
        guard named == 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let converted = withUnsafePointer(to: &local.sin_addr) { pointer -> UnsafePointer<CChar>? in
            inet_ntop(AF_INET, UnsafeRawPointer(pointer), &buffer, socklen_t(buffer.count))
        }
        guard converted != nil else { return nil }
        return String(cString: buffer)
    }
}
