import Darwin

struct NetworkInterface: Identifiable, Hashable, Sendable {
    let name: String
    let address: IPv4Address
    let netmask: IPv4Address
    let macAddress: MACAddress?
    var ipv6Addresses: [String] = []

    var id: String { name }
    var subnet: IPv4Subnet { IPv4Subnet(address: address, netmask: netmask) }
    var displayName: String { "\(name) — \(address)/\(subnet.prefixLength)" }

    /// Active, non-loopback, non point-to-point IPv4 interfaces, `en0` first.
    static func current() -> [NetworkInterface] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }

        var ipv4: [(name: String, address: IPv4Address, netmask: IPv4Address)] = []
        var macs: [String: MACAddress] = [:]
        var ipv6: [String: [String]] = [:]

        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = entry.pointee
            guard let sa = ifa.ifa_addr else { continue }
            let name = String(cString: ifa.ifa_name)

            switch Int32(sa.pointee.sa_family) {
            case AF_LINK:
                if let mac = MACAddress(sockaddrDL: UnsafeRawPointer(sa)) {
                    macs[name] = mac
                }
            case AF_INET:
                let flags = Int32(ifa.ifa_flags)
                guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
                      flags & IFF_LOOPBACK == 0, flags & IFF_POINTOPOINT == 0,
                      let mask = ifa.ifa_netmask else { continue }
                let address = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { IPv4Address($0.pointee.sin_addr) }
                let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { IPv4Address($0.pointee.sin_addr) }
                ipv4.append((name, address, netmask))
            case AF_INET6:
                let raw = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) }
                }
                if let address = IPv6Neighbors.format(raw) {
                    ipv6[name, default: []].append(address)
                }
            default:
                break
            }
        }

        return ipv4
            .map {
                NetworkInterface(name: $0.name, address: $0.address, netmask: $0.netmask,
                                 macAddress: macs[$0.name], ipv6Addresses: ipv6[$0.name] ?? [])
            }
            .sorted { ($0.name == "en0" ? 0 : 1, $0.name) < ($1.name == "en0" ? 0 : 1, $1.name) }
    }
}
