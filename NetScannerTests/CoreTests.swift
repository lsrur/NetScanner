import Darwin
import Testing
@testable import NetScanner

struct IPv4Tests {
    @Test func parsesAndFormats() {
        #expect(IPv4Address("192.168.1.20")?.description == "192.168.1.20")
        #expect(IPv4Address("192.168.1.20")?.raw == 0xC0A8_0114)
        #expect(IPv4Address("0.0.0.0")?.raw == 0)
        #expect(IPv4Address("255.255.255.255")?.raw == .max)
    }

    @Test(arguments: ["", "1.2.3", "1.2.3.4.5", "256.1.1.1", "1..2.3", "+1.2.3.4", "a.b.c.d", "1.2.3.0004"])
    func rejectsInvalid(_ text: String) {
        #expect(IPv4Address(text) == nil)
    }

    @Test func inAddrRoundTrip() {
        let address = IPv4Address("10.0.0.42")!
        #expect(IPv4Address(address.inAddr) == address)
    }

    @Test func subnetFromNetmask() {
        let subnet = IPv4Subnet(address: IPv4Address("192.168.1.77")!, netmask: IPv4Address("255.255.255.0")!)
        #expect(subnet.prefixLength == 24)
        #expect(subnet.network.description == "192.168.1.0")
        #expect(subnet.broadcast.description == "192.168.1.255")
        #expect(subnet.hosts.count == 254)
        #expect(subnet.hosts.first?.description == "192.168.1.1")
        #expect(subnet.hosts.last?.description == "192.168.1.254")
        #expect(subnet.contains(IPv4Address("192.168.1.200")!))
        #expect(!subnet.contains(IPv4Address("192.168.2.1")!))
    }

    @Test func cidrEdgeCases() {
        #expect(IPv4Subnet(cidr: "10.0.0.5/22")?.hosts.count == 1022)
        #expect(IPv4Subnet(cidr: "10.0.0.4/31")?.hosts.map(\.description) == ["10.0.0.4", "10.0.0.5"])
        #expect(IPv4Subnet(cidr: "10.0.0.4/32")?.hosts.count == 1)
        #expect(IPv4Subnet(cidr: "0.0.0.0/0")?.netmask.raw == 0)
        #expect(IPv4Subnet(cidr: "10.0.0.0/33") == nil)
    }
}

struct MACAddressTests {
    @Test func formatsWithLeadingZeros() {
        let mac = MACAddress(bytes: [0x00, 0x1A, 0x2B, 0x03, 0x04, 0xFF])!
        #expect(mac.description == "00:1a:2b:03:04:ff")
        #expect(MACAddress("00:1a:2b:03:04:ff") == mac)
        #expect(mac.ouiPrefix == 0x001A2B)
        #expect(!mac.isLocallyAdministered)
    }

    @Test func detectsRandomizedAddresses() {
        #expect(MACAddress("da:a1:19:00:00:01")!.isLocallyAdministered)
    }
}

struct MulticastDNSTests {
    @Test func buildsReverseName() {
        #expect(MulticastDNS.reverseName(for: IPv4Address("192.168.0.215")!) == "215.0.168.192.in-addr.arpa.")
    }

    @Test func decodesWireNamesAndDropsLocal() {
        let android: [UInt8] = [7] + Array("Android".utf8) + [5] + Array("local".utf8) + [0]
        #expect(MulticastDNS.decodeName(android) == "Android")
        let router: [UInt8] = [6] + Array("router".utf8) + [4] + Array("home".utf8) + [0]
        #expect(MulticastDNS.decodeName(router) == "router.home")
        #expect(MulticastDNS.decodeName([0]) == nil)
        #expect(MulticastDNS.decodeName([9, 65, 66]) == nil)
    }
}

struct ICMPPacketTests {
    @Test func rfc1071Checksum() {
        #expect(ICMPPacket.checksum([0x00, 0x01, 0xF2, 0x03, 0xF4, 0xF5, 0xF6, 0xF7]) == 0x220D)
        #expect(ICMPPacket.checksum([0x01]) == ~UInt16(0x0100))
    }

    @Test func echoRequestIsWellFormed() {
        let packet = ICMPPacket.echoRequest(identifier: 0xBEEF, sequence: 7)
        #expect(packet.count == 64)
        #expect(packet[0] == ICMPPacket.echoRequestType)
        #expect(ICMPPacket.checksum(packet) == 0)
        #expect(ICMPPacket.parse(packet) == .init(type: 8, code: 0, identifier: 0xBEEF, sequence: 7))
    }

    @Test func parsesReplyWithIPHeader() {
        var reply = ICMPPacket.echoRequest(identifier: 0x1234, sequence: 300)
        reply[0] = ICMPPacket.echoReplyType
        reply[2] = 0
        reply[3] = 0
        let sum = ICMPPacket.checksum(reply)
        reply[2] = UInt8(sum >> 8)
        reply[3] = UInt8(sum & 0xFF)
        let ipHeader: [UInt8] = [0x45] + [UInt8](repeating: 0, count: 19)

        #expect(ICMPPacket.parse(ipHeader + reply) == .init(type: 0, code: 0, identifier: 0x1234, sequence: 300))
    }

    @Test func rejectsCorruptOrTruncated() {
        var packet = ICMPPacket.echoRequest(identifier: 1, sequence: 1)
        packet[10] ^= 0xFF
        #expect(ICMPPacket.parse(packet) == nil)
        #expect(ICMPPacket.parse([0, 0, 0]) == nil)
    }
}

struct ARPParsingTests {
    /// Builds one routing message: rt_msghdr + sockaddr_inarp + sockaddr_dl("en0", mac).
    private func message(ip: [UInt8], mac: [UInt8]) -> [UInt8] {
        let header = MemoryLayout<rt_msghdr>.size
        let sin: [UInt8] = [16, UInt8(AF_INET), 0, 0] + ip + [UInt8](repeating: 0, count: 8)
        let name = Array("en0".utf8)
        let dl: [UInt8] = [20, UInt8(AF_LINK), 4, 0, 6, UInt8(name.count), UInt8(mac.count), 0] + name + mac
        let padded = dl + [UInt8](repeating: 0, count: 20 - dl.count)
        let length = header + sin.count + padded.count
        var bytes = [UInt8](repeating: 0, count: header)
        bytes[0] = UInt8(length & 0xFF)
        bytes[1] = UInt8(length >> 8)
        return bytes + sin + padded
    }

    @Test func parsesEntries() {
        let data = message(ip: [192, 168, 0, 1], mac: [0xA4, 0x2B, 0xB0, 1, 2, 3])
            + message(ip: [192, 168, 0, 9], mac: [0x3C, 0x22, 0xFB, 4, 5, 6])
        let table = ARPTable.parse(data)
        #expect(table.count == 2)
        #expect(table[IPv4Address("192.168.0.1")!]?.description == "a4:2b:b0:01:02:03")
        #expect(table[IPv4Address("192.168.0.9")!]?.description == "3c:22:fb:04:05:06")
    }

    @Test func skipsIncompleteAndBroadcastEntries() {
        let data = message(ip: [192, 168, 0, 2], mac: [])
            + message(ip: [192, 168, 0, 255], mac: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
            + message(ip: [192, 168, 0, 3], mac: [1, 2, 3, 4, 5, 6])
        #expect(Array(ARPTable.parse(data).keys) == [IPv4Address("192.168.0.3")!])
    }

    @Test func parsesArpCommandOutput() {
        let output = """
        ? (192.168.0.1) at 00:11:22:aa:bb:cc on en0 ifscope [ethernet]
        ? (192.168.0.90) at 00:aa:bb:8:cc:dd on en0 ifscope [ethernet]
        ? (192.168.0.50) at (incomplete) on en0 ifscope [ethernet]
        ? (192.168.0.255) at ff:ff:ff:ff:ff:ff on en0 ifscope [ethernet]
        """
        let table = ARPTable.parseArpOutput(output)
        #expect(table.count == 2)
        #expect(table[IPv4Address("192.168.0.90")!]?.description == "00:aa:bb:08:cc:dd")
    }

    @Test func toleratesTruncatedBuffer() {
        let data = message(ip: [10, 0, 0, 1], mac: [1, 2, 3, 4, 5, 6])
        #expect(ARPTable.parse(data.dropLast(4)).isEmpty)
    }
}

struct ScanRangeTests {
    private func parse(_ text: String) throws -> [String] {
        try ScanRange.parse(text).map(\.description)
    }

    @Test func parsesShorthandAndFullRanges() throws {
        #expect(try parse("192.168.0.100-103") == ["192.168.0.100", "192.168.0.101", "192.168.0.102", "192.168.0.103"])
        #expect(try parse("10.0.0.254-10.0.1.1") == ["10.0.0.254", "10.0.0.255", "10.0.1.0", "10.0.1.1"])
    }

    @Test func parsesCIDRWithoutNetworkAndBroadcast() throws {
        #expect(try parse("10.0.0.0/30") == ["10.0.0.1", "10.0.0.2"])
        #expect(try ScanRange.parse("10.0.0.0/23").count == 510)
    }

    @Test func combinesAndDeduplicates() throws {
        #expect(try parse("192.168.0.5, 192.168.0.1-3 192.168.0.2") == ["192.168.0.1", "192.168.0.2", "192.168.0.3", "192.168.0.5"])
    }

    @Test(arguments: ["", "abc", "192.168.0.10-5", "192.168.0.1-300", "192.168.0.0/33", "192.168.0.1-", "1.2.3"])
    func rejectsInvalid(_ text: String) {
        #expect(throws: ScanRange.ParseError.self) { try ScanRange.parse(text) }
    }

    @Test func rejectsHugeRanges() {
        #expect(throws: ScanRange.ParseError.tooLarge(65536)) { try ScanRange.parse("10.0.0.0/16") }
        #expect(throws: ScanRange.ParseError.self) { try ScanRange.parse("10.0.0.0-10.0.255.255") }
    }
}
