import Darwin

/// Default IPv4 gateways per interface, from the kernel routing table.
enum DefaultGateway {
    static func read() -> [String: IPv4Address] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_GATEWAY]
        let mibCount = UInt32(mib.count)
        var length = 0
        guard sysctl(&mib, mibCount, nil, &length, nil, 0) == 0, length > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, mibCount, &buffer, &length, nil, 0) == 0 else { return [:] }
        var result: [String: IPv4Address] = [:]
        for route in parse(buffer.prefix(length)) {
            var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
            guard if_indextoname(UInt32(route.interfaceIndex), &name) != nil else { continue }
            let interface = name.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            result[interface] = result[interface] ?? route.gateway
        }
        return result
    }

    /// Default routes (destination 0.0.0.0/0) in a routing sysctl dump.
    static func parse(_ data: some Collection<UInt8>) -> [(interfaceIndex: UInt16, gateway: IPv4Address)] {
        let bytes = Array(data)
        let headerSize = MemoryLayout<rt_msghdr>.size
        let indexOffset = MemoryLayout<rt_msghdr>.offset(of: \rt_msghdr.rtm_index)!
        let addrsOffset = MemoryLayout<rt_msghdr>.offset(of: \rt_msghdr.rtm_addrs)!
        var routes: [(UInt16, IPv4Address)] = []
        var offset = 0
        while offset + headerSize <= bytes.count {
            let messageLength = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
            guard messageLength > 0, offset + messageLength <= bytes.count else { break }
            let end = offset + messageLength
            defer { offset = end }

            let index = UInt16(bytes[offset + indexOffset]) | UInt16(bytes[offset + indexOffset + 1]) << 8
            let addrs = (0..<4).reduce(Int32(0)) { $0 | Int32(bytes[offset + addrsOffset + $1]) << (8 * $1) }
            var destination: IPv4Address?
            var gateway: IPv4Address?
            var maskIsZero = true
            var position = offset + headerSize
            // Sockaddrs follow in RTA_* bit order, each padded to 4 bytes.
            for bit in 0..<8 where addrs & (1 << bit) != 0 {
                guard position < end else { break }
                let length = Int(bytes[position])
                let family = position + 1 < end ? Int32(bytes[position + 1]) : 0
                let hasAddress = length >= 8 && position + 8 <= end
                switch Int32(1 << bit) {
                case RTA_DST where family == AF_INET && hasAddress:
                    destination = ipv4(bytes, at: position + 4)
                case RTA_GATEWAY where family == AF_INET && hasAddress:
                    gateway = ipv4(bytes, at: position + 4)
                case RTA_NETMASK:
                    // Netmasks are often truncated after their last non-zero byte.
                    let available = min(position + length, end)
                    maskIsZero = position + 4 >= available || bytes[(position + 4)..<available].allSatisfy { $0 == 0 }
                default:
                    break
                }
                position += length > 0 ? 1 + ((length - 1) | 3) : 4
            }
            if destination?.raw == 0, maskIsZero, let gateway {
                routes.append((index, gateway))
            }
        }
        return routes
    }

    private static func ipv4(_ bytes: [UInt8], at index: Int) -> IPv4Address {
        IPv4Address(raw: bytes[index..<(index + 4)].reduce(0) { $0 << 8 | UInt32($1) })
    }
}
