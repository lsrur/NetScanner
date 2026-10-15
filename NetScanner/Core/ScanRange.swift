import Foundation

/// User-typed scan targets: comma/space separated CIDRs (`10.0.0.0/23`), ranges
/// (`192.168.0.100-200`, `192.168.0.100-192.168.1.20`) and single addresses.
enum ScanRange {
    /// A /20 worth of addresses; beyond that a scan takes minutes and floods the network.
    static let maxAddresses = 4096

    enum ParseError: LocalizedError, Equatable {
        case invalid(String)
        case tooLarge(Int)

        var errorDescription: String? {
            switch self {
            case .invalid(let token): "Invalid range: \(token)"
            case .tooLarge(let count): "Too many IPs (\(count)); the maximum is \(ScanRange.maxAddresses)"
            }
        }
    }

    /// Sorted, de-duplicated addresses. CIDRs exclude their network and broadcast addresses.
    static func parse(_ text: String) throws(ParseError) -> [IPv4Address] {
        var addresses = Set<IPv4Address>()
        let tokens = text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { throw .invalid(text) }

        for token in tokens {
            let (first, last) = try bounds(of: token)
            let count = Int(last.raw - first.raw) + 1
            guard addresses.count + count <= maxAddresses else { throw .tooLarge(addresses.count + count) }
            addresses.formUnion((first.raw...last.raw).map(IPv4Address.init(raw:)))
        }
        return addresses.sorted()
    }

    private static func bounds(of token: String) throws(ParseError) -> (IPv4Address, IPv4Address) {
        if token.contains("/") {
            guard let subnet = IPv4Subnet(cidr: token) else { throw .invalid(token) }
            let size = 1 << (32 - subnet.prefixLength)
            guard size <= maxAddresses * 2 else { throw .tooLarge(size) }
            guard let first = subnet.hosts.first, let last = subnet.hosts.last else { throw .invalid(token) }
            return (first, last)
        }
        if token.contains("-") {
            let sides = token.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard sides.count == 2, let start = IPv4Address(sides[0]) else { throw .invalid(token) }
            let end: IPv4Address
            if let full = IPv4Address(sides[1]) {
                end = full
            } else if sides[1].allSatisfy(\.isNumber), let octet = UInt8(sides[1]) {
                // "192.168.0.100-200": shorthand for the last octet.
                end = IPv4Address(raw: start.raw & 0xFFFF_FF00 | UInt32(octet))
            } else {
                throw .invalid(token)
            }
            guard end >= start else { throw .invalid(token) }
            return (start, end)
        }
        guard let address = IPv4Address(token) else { throw .invalid(token) }
        return (address, address)
    }
}
