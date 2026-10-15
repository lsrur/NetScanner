struct MACAddress: Hashable, Sendable, CustomStringConvertible {
    let bytes: [UInt8]

    init?(bytes: some Collection<UInt8>) {
        guard bytes.count == 6 else { return nil }
        self.bytes = Array(bytes)
    }

    init?(_ string: String) {
        let parts = string.split(separator: ":")
        guard parts.count == 6 else { return nil }
        let octets = parts.compactMap { UInt8($0, radix: 16) }
        self.init(bytes: octets)
    }

    /// Reads the link-layer address out of a `sockaddr_dl`.
    /// Layout: len, family, index(2), type, nlen, alen, slen, data[nlen + alen].
    init?(sockaddrDL raw: UnsafeRawPointer) {
        let nameLength = Int(raw.load(fromByteOffset: 5, as: UInt8.self))
        let addressLength = raw.load(fromByteOffset: 6, as: UInt8.self)
        guard addressLength == 6 else { return nil }
        let start = 8 + nameLength
        let bytes = (0..<6).map { raw.load(fromByteOffset: start + $0, as: UInt8.self) }
        guard bytes.contains(where: { $0 != 0 }) else { return nil }
        self.bytes = bytes
    }

    var description: String {
        bytes.map { $0 < 0x10 ? "0" + String($0, radix: 16) : String($0, radix: 16) }
            .joined(separator: ":")
    }

    /// First three octets, as used by the IEEE OUI registry.
    var ouiPrefix: UInt32 {
        UInt32(bytes[0]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[2])
    }

    /// Randomized "private" addresses (iOS, Android, macOS) set the locally administered bit.
    var isLocallyAdministered: Bool { bytes[0] & 0x02 != 0 }

    var isBroadcast: Bool { bytes.allSatisfy { $0 == 0xFF } }

    /// What macOS hands sandboxed processes instead of a neighbor's real MAC.
    var isRedacted: Bool { bytes == [0x02, 0, 0, 0, 0, 0] }
}
