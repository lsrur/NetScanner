import Foundation

/// Reads the kernel ARP cache (the same data `arp -an` prints).
enum ARPTable {
    static func read() -> [IPv4Address: MACAddress] {
        let entries = readSysctl()
        return entries.isEmpty ? readArpCommand() : entries
    }

    /// Fallback for unsandboxed runs (command-line tools): there the routing sysctl comes back
    /// empty while the system `arp` binary still sees the cache. Inside the sandbox it is the
    /// other way around.
    private static func readArpCommand() -> [IPv4Address: MACAddress] {
        SystemTool.output(of: "/usr/sbin/arp", arguments: ["-an"]).map(parseArpOutput) ?? [:]
    }

    /// Parses lines like `? (192.168.0.1) at 00:11:22:aa:bb:cc on en0 ifscope [ethernet]`.
    /// `arp` drops leading zeros (`00:aa:bb:8:cc:dd`), which `MACAddress(_:)` accepts.
    static func parseArpOutput(_ text: String) -> [IPv4Address: MACAddress] {
        var result: [IPv4Address: MACAddress] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ")
            guard fields.count >= 4, fields[2] == "at",
                  fields[1].hasPrefix("("), fields[1].hasSuffix(")"),
                  let address = IPv4Address(String(fields[1].dropFirst().dropLast())),
                  let mac = MACAddress(String(fields[3])),
                  !mac.isBroadcast, !mac.isRedacted else { continue }
            result[address] = mac
        }
        return result
    }

    private static func readSysctl() -> [IPv4Address: MACAddress] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO]
        let mibCount = UInt32(mib.count)
        var length = 0
        guard sysctl(&mib, mibCount, nil, &length, nil, 0) == 0, length > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, mibCount, &buffer, &length, nil, 0) == 0 else { return [:] }
        return parse(buffer.prefix(length))
    }

    /// Parses a sequence of `rt_msghdr` messages, each followed by a `sockaddr_inarp` and a `sockaddr_dl`.
    static func parse(_ data: some Collection<UInt8>) -> [IPv4Address: MACAddress] {
        let bytes = Array(data)
        let headerSize = MemoryLayout<rt_msghdr>.size
        var result: [IPv4Address: MACAddress] = [:]
        var offset = 0

        while offset + headerSize <= bytes.count {
            let messageLength = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
            guard messageLength > 0, offset + messageLength <= bytes.count else { break }
            let end = offset + messageLength
            defer { offset = end }

            let sin = offset + headerSize
            guard sin + 8 <= end, bytes[sin + 1] == UInt8(AF_INET) else { continue }
            let address = IPv4Address(raw: bytes[(sin + 4)..<(sin + 8)].reduce(0) { $0 << 8 | UInt32($1) })

            let dl = sin + roundUp(Int(bytes[sin]))
            guard dl + 8 <= end, bytes[dl + 1] == UInt8(AF_LINK) else { continue }
            let nameLength = Int(bytes[dl + 5])
            let addressLength = Int(bytes[dl + 6])
            let macStart = dl + 8 + nameLength
            guard addressLength == 6, macStart + 6 <= end,
                  let mac = MACAddress(bytes: bytes[macStart..<(macStart + 6)]),
                  !mac.isBroadcast, !mac.isRedacted else { continue }
            result[address] = mac
        }
        return result
    }

    /// Socket addresses in routing messages are padded to 4-byte boundaries.
    private static func roundUp(_ length: Int) -> Int {
        length > 0 ? 1 + ((length - 1) | 3) : 4
    }
}
