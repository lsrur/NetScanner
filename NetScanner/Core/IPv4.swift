import Darwin

/// IPv4 address stored in host byte order.
struct IPv4Address: Hashable, Comparable, Sendable, CustomStringConvertible {
    let raw: UInt32

    init(raw: UInt32) {
        self.raw = raw
    }

    static let loopback = IPv4Address(raw: 0x7F00_0001)

    init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard (1...3).contains(part.count),
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let octet = UInt8(part) else { return nil }
            value = value << 8 | UInt32(octet)
        }
        raw = value
    }

    init(_ address: in_addr) {
        raw = UInt32(bigEndian: address.s_addr)
    }

    var inAddr: in_addr { in_addr(s_addr: raw.bigEndian) }

    var description: String {
        "\(raw >> 24).\((raw >> 16) & 0xFF).\((raw >> 8) & 0xFF).\(raw & 0xFF)"
    }

    static func < (lhs: IPv4Address, rhs: IPv4Address) -> Bool {
        lhs.raw < rhs.raw
    }

    /// Calls `body` with this address as a `sockaddr_in`.
    func withSockaddr<R>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R {
        var sin = sockaddr_in()
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_addr = inAddr
        return withUnsafePointer(to: &sin) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
}

struct IPv4Subnet: Hashable, Sendable, CustomStringConvertible {
    let network: IPv4Address
    let prefixLength: Int

    init(address: IPv4Address, prefixLength: Int) {
        precondition((0...32).contains(prefixLength), "invalid prefix length \(prefixLength)")
        self.prefixLength = prefixLength
        network = IPv4Address(raw: address.raw & Self.mask(for: prefixLength))
    }

    init(address: IPv4Address, netmask: IPv4Address) {
        self.init(address: address, prefixLength: (~netmask.raw).leadingZeroBitCount)
    }

    init?(cidr: String) {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2,
              let address = IPv4Address(String(parts[0])),
              let prefix = Int(parts[1]), (0...32).contains(prefix) else { return nil }
        self.init(address: address, prefixLength: prefix)
    }

    static func mask(for prefixLength: Int) -> UInt32 {
        prefixLength == 0 ? 0 : UInt32.max << UInt32(32 - prefixLength)
    }

    var netmask: IPv4Address { IPv4Address(raw: Self.mask(for: prefixLength)) }

    var broadcast: IPv4Address { IPv4Address(raw: network.raw | ~Self.mask(for: prefixLength)) }

    func contains(_ address: IPv4Address) -> Bool {
        address.raw & Self.mask(for: prefixLength) == network.raw
    }

    /// Usable host addresses; network and broadcast are excluded for prefixes shorter than /31.
    var hosts: [IPv4Address] {
        let first = network.raw, last = broadcast.raw
        if prefixLength >= 31 {
            return (first...last).map(IPv4Address.init(raw:))
        }
        return (first + 1 ..< last).map(IPv4Address.init(raw:))
    }

    var description: String { "\(network)/\(prefixLength)" }
}
