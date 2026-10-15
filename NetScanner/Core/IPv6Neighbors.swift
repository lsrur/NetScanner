import Foundation

/// IPv6 addresses of LAN neighbors, keyed by MAC so they can be joined to IPv4 hosts.
enum IPv6Neighbors {
    struct Entry: Equatable {
        let address: String
        let mac: MACAddress
        var isLinkLocal: Bool { address.lowercased().hasPrefix("fe80:") }
    }

    /// An ICMPv6 echo to the all-nodes group makes every IPv6 host on the link answer, which
    /// fills the neighbor cache that `read(interface:)` returns. Unprivileged datagram socket.
    static func pingAllNodes(interface: String) {
        let index = if_nametoindex(interface)
        guard index != 0 else { return }
        let fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6)
        guard fd >= 0 else { return }
        defer { close(fd) }

        var interfaceIndex = index
        _ = setsockopt(fd, IPPROTO_IPV6, IPV6_MULTICAST_IF, &interfaceIndex, socklen_t(MemoryLayout<UInt32>.size))
        var destination = sockaddr_in6()
        destination.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        destination.sin6_family = sa_family_t(AF_INET6)
        destination.sin6_scope_id = index
        _ = inet_pton(AF_INET6, "ff02::1", &destination.sin6_addr)

        // Echo request (type 128); the kernel fills in the ICMPv6 checksum.
        let packet: [UInt8] = [128, 0, 0, 0, 0x4E, 0x53, 0, 1] + Array("NetScanner".utf8)
        withUnsafePointer(to: &destination) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                packet.withUnsafeBytes {
                    _ = sendto(fd, $0.baseAddress, $0.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
    }

    /// Neighbor cache entries on `interface`. Inside the app sandbox (with Local Network access)
    /// the routing sysctl returns real MACs while a spawned `ndp` sees only redacted ones, and
    /// outside the sandbox it is the other way around, so try both.
    static func read(interface: String) -> [Entry] {
        let entries = readSysctl(interfaceIndex: UInt16(truncatingIfNeeded: if_nametoindex(interface)))
        if !entries.isEmpty { return entries }
        guard let output = SystemTool.output(of: "/usr/sbin/ndp", arguments: ["-an"]) else { return [] }
        return parseNDPOutput(output, interface: interface)
    }

    private static func readSysctl(interfaceIndex: UInt16) -> [Entry] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET6, NET_RT_FLAGS, RTF_LLINFO]
        let mibCount = UInt32(mib.count)
        var length = 0
        guard sysctl(&mib, mibCount, nil, &length, nil, 0) == 0, length > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, mibCount, &buffer, &length, nil, 0) == 0 else { return [] }
        return parseRoutingMessages(buffer.prefix(length), interfaceIndex: interfaceIndex)
    }

    /// Parses `rt_msghdr` + `sockaddr_in6` + `sockaddr_dl` messages, keeping `interfaceIndex`.
    static func parseRoutingMessages(_ data: some Collection<UInt8>, interfaceIndex: UInt16) -> [Entry] {
        let bytes = Array(data)
        let headerSize = MemoryLayout<rt_msghdr>.size
        var entries: [Entry] = []
        var offset = 0
        while offset + headerSize <= bytes.count {
            let messageLength = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
            guard messageLength > 0, offset + messageLength <= bytes.count else { break }
            let end = offset + messageLength
            defer { offset = end }

            let index = UInt16(bytes[offset + 4]) | UInt16(bytes[offset + 5]) << 8
            let sin6 = offset + headerSize
            guard index == interfaceIndex, sin6 + 24 <= end, bytes[sin6 + 1] == UInt8(AF_INET6) else { continue }
            guard let address = format(Array(bytes[(sin6 + 8)..<(sin6 + 24)])) else { continue }

            let dl = sin6 + roundUp(Int(bytes[sin6]))
            guard dl + 8 <= end, bytes[dl + 1] == UInt8(AF_LINK) else { continue }
            let macStart = dl + 8 + Int(bytes[dl + 5])
            guard bytes[dl + 6] == 6, macStart + 6 <= end,
                  let mac = MACAddress(bytes: bytes[macStart..<(macStart + 6)]),
                  !mac.isBroadcast, !mac.isRedacted else { continue }
            entries.append(Entry(address: address, mac: mac))
        }
        return entries
    }

    /// Text form of a raw address. The kernel (routing sysctl and getifaddrs alike) embeds the
    /// scope id in bytes 2-3 of link-local addresses (KAME convention), so those are cleared.
    static func format(_ address: [UInt8]) -> String? {
        guard address.count == 16 else { return nil }
        var raw = address
        if raw[0] == 0xFE, raw[1] & 0xC0 == 0x80 {
            raw[2] = 0
            raw[3] = 0
        }
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let capacity = socklen_t(text.count)
        let ok = raw.withUnsafeBytes { inet_ntop(AF_INET6, $0.baseAddress, &text, capacity) } != nil
        return ok ? text.withUnsafeBufferPointer { String(cString: $0.baseAddress!) } : nil
    }

    private static func roundUp(_ length: Int) -> Int {
        length > 0 ? 1 + ((length - 1) | 3) : 4
    }

    /// Parses `ndp -an` rows: `Neighbor  Linklayer-Address  Netif  Expire  St ...`.
    static func parseNDPOutput(_ text: String, interface: String) -> [Entry] {
        text.split(separator: "\n").dropFirst().compactMap { line in
            let fields = line.split(separator: " ")
            guard fields.count >= 3, fields[2] == interface,
                  let mac = MACAddress(String(fields[1])), !mac.isBroadcast, !mac.isRedacted else { return nil }
            let address = fields[0].split(separator: "%").first.map(String.init) ?? String(fields[0])
            return Entry(address: address, mac: mac)
        }
    }

    /// Splits addresses into link-local and the rest (global and unique-local), each sorted.
    static func classify(_ entries: [Entry]) -> [MACAddress: (linkLocal: [String], global: [String])] {
        var result: [MACAddress: (linkLocal: [String], global: [String])] = [:]
        for entry in entries {
            if entry.isLinkLocal {
                result[entry.mac, default: ([], [])].linkLocal.append(entry.address)
            } else {
                result[entry.mac, default: ([], [])].global.append(entry.address)
            }
        }
        return result.mapValues { (Array(Set($0.linkLocal)).sorted(), Array(Set($0.global)).sorted()) }
    }
}

enum SystemTool {
    /// Runs a system binary and returns its stdout, or nil if it could not be launched.
    static func output(of path: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
