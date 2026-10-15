import Darwin

/// Wake-on-LAN: a "magic packet" (6 × 0xFF followed by the MAC 16 times) sent by UDP broadcast.
enum WakeOnLAN {
    static func magicPacket(for mac: MACAddress) -> [UInt8] {
        [UInt8](repeating: 0xFF, count: 6) + (0..<16).flatMap { _ in mac.bytes }
    }

    /// Sends the packet to each address (typically the subnet broadcast and 255.255.255.255).
    /// Returns how many sends succeeded.
    @discardableResult
    static func wake(_ mac: MACAddress, to addresses: [IPv4Address], port: UInt16 = 9) -> Int {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return 0 }
        defer { close(fd) }
        var enabled: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout<Int32>.size))

        let packet = magicPacket(for: mac)
        var sent = 0
        for address in addresses {
            var destination = sockaddr_in()
            destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            destination.sin_family = sa_family_t(AF_INET)
            destination.sin_port = port.bigEndian
            destination.sin_addr = address.inAddr
            let result = withUnsafePointer(to: &destination) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { target in
                    packet.withUnsafeBytes { sendto(fd, $0.baseAddress, $0.count, 0, target, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
            }
            if result == packet.count { sent += 1 }
        }
        return sent
    }
}
