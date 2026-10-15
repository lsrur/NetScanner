import Darwin
import Testing
@testable import NetScanner

struct IPv6NeighborsTests {
    private let sample = """
    Neighbor                                Linklayer Address  Netif Expire    St Flgs Prbs
    2001:db8:1:2:5555:6666:7777:8888   00:11:22:33:44:55    en0 22h11m18s S
    2001:db8:1:2:211:22ff:feaa:bbcc  00:11:22:aa:bb:cc    en0 22h11m18s S  R
    fe80::1111:2222:3333:4444%en0            00:11:22:33:44:55    en0 23h59m33s S
    fe80::211:22ff:feaa:bbcc%en0           00:11:22:aa:bb:cc    en0 24s       R  R
    fe80::1%lo0                             (incomplete)         lo0 permanent R
    fe80::ac15:13ff:feb5:bba5%awdl0         ae:15:13:b5:bb:a5  awdl0 permanent R
    fe80::99%en0                            (incomplete)         en0 expired   I
    """

    @Test func parsesEntriesForOneInterface() {
        let entries = IPv6Neighbors.parseNDPOutput(sample, interface: "en0")
        #expect(entries.count == 4)
        #expect(entries.contains(.init(address: "fe80::1111:2222:3333:4444", mac: MACAddress("00:11:22:33:44:55")!)))
        #expect(!entries.contains { $0.address.contains("%") })
    }

    @Test func groupsByMACAndScope() throws {
        let grouped = IPv6Neighbors.classify(IPv6Neighbors.parseNDPOutput(sample, interface: "en0"))
        let android = try #require(grouped[MACAddress("00:11:22:33:44:55")!])
        #expect(android.linkLocal == ["fe80::1111:2222:3333:4444"])
        #expect(android.global == ["2001:db8:1:2:5555:6666:7777:8888"])
    }
}

struct IPv6RoutingParseTests {
    /// rt_msghdr (index at offset 4) + sockaddr_in6 (28 bytes) + sockaddr_dl("en0", mac).
    private func message(index: UInt16, address: [UInt8], mac: [UInt8]) -> [UInt8] {
        let header = MemoryLayout<rt_msghdr>.size
        let sin6: [UInt8] = [28, UInt8(AF_INET6), 0, 0, 0, 0, 0, 0] + address + [0, 0, 0, 0]
        let name = Array("en0".utf8)
        let dl: [UInt8] = [20, UInt8(AF_LINK), UInt8(index & 0xFF), 0, 6, UInt8(name.count), UInt8(mac.count), 0] + name + mac
        let padded = dl + [UInt8](repeating: 0, count: max(0, 20 - dl.count))
        let length = header + sin6.count + padded.count
        var bytes = [UInt8](repeating: 0, count: header)
        bytes[0] = UInt8(length & 0xFF)
        bytes[1] = UInt8(length >> 8)
        bytes[4] = UInt8(index & 0xFF)
        return bytes + sin6 + padded
    }

    @Test func clearsEmbeddedScopeAndFiltersInterface() {
        // fe80:000e::1 as stored by the kernel (scope 14 embedded) on interface 14.
        let linkLocal: [UInt8] = [0xFE, 0x80, 0x00, 0x0E] + [UInt8](repeating: 0, count: 11) + [1]
        let global: [UInt8] = [0x20, 0x01, 0x0D, 0xB8] + [UInt8](repeating: 0, count: 11) + [2]
        let data = message(index: 14, address: linkLocal, mac: [0xB8, 0xAB, 0x62, 1, 2, 3])
            + message(index: 14, address: global, mac: [0xB8, 0xAB, 0x62, 1, 2, 3])
            + message(index: 7, address: global, mac: [1, 2, 3, 4, 5, 6])
            + message(index: 14, address: global, mac: [0x02, 0, 0, 0, 0, 0])
        let entries = IPv6Neighbors.parseRoutingMessages(data, interfaceIndex: 14)
        #expect(entries.map(\.address) == ["fe80::1", "2001:db8::2"])
        #expect(entries.allSatisfy { $0.mac.description == "b8:ab:62:01:02:03" })
    }
}
