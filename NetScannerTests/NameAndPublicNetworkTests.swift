import Foundation
import Testing
@testable import NetScanner

struct NetBIOSTests {
    @Test func encodesWildcardNodeStatusQuery() {
        let packet = NetBIOS.nodeStatusRequest(transactionID: 0xABCD)
        #expect(packet.count == 50)
        #expect(Array(packet[0..<2]) == [0xAB, 0xCD])
        #expect(packet[12] == 0x20)
        #expect(String(decoding: packet[13..<45], as: UTF8.self) == "CK" + String(repeating: "A", count: 30))
        #expect(Array(packet[45...]) == [0x00, 0x00, 0x21, 0x00, 0x01])
    }

    /// Builds a node status response the way Windows/Samba send it.
    private func response(_ names: [(String, UInt8, UInt16)]) -> [UInt8] {
        let query = NetBIOS.nodeStatusRequest(transactionID: 1)
        var bytes: [UInt8] = [0, 1, 0x84, 0, 0, 0, 0, 1, 0, 0, 0, 0] + Array(query[12..<46])
        bytes += [0x00, 0x21, 0x00, 0x01, 0, 0, 0, 0]
        let rdLength = 1 + names.count * 18 + 46
        bytes += [UInt8(rdLength >> 8), UInt8(rdLength & 0xFF), UInt8(names.count)]
        for (name, suffix, flags) in names {
            let padded = Array(name.utf8.prefix(15)) + [UInt8](repeating: 0x20, count: 15 - min(name.utf8.count, 15))
            bytes += padded + [suffix, UInt8(flags >> 8), UInt8(flags & 0xFF)]
        }
        return bytes + [UInt8](repeating: 0, count: 46)
    }

    @Test func picksUniqueWorkstationName() throws {
        let entries = try #require(NetBIOS.parseNodeStatus(response([
            ("WORKGROUP", 0x00, 0x8400),
            ("DESKTOP-ABC123", 0x00, 0x0400),
            ("DESKTOP-ABC123", 0x20, 0x0400),
        ])))
        #expect(entries.count == 3)
        #expect(entries[0] == .init(name: "WORKGROUP", suffix: 0x00, isGroup: true))
        #expect(NetBIOS.machineName(from: entries) == "DESKTOP-ABC123")
    }

    @Test func fallsBackToFileServerName() throws {
        let entries = try #require(NetBIOS.parseNodeStatus(response([("NAS", 0x20, 0x0400)])))
        #expect(NetBIOS.machineName(from: entries) == "NAS")
    }

    @Test func rejectsGarbage() {
        #expect(NetBIOS.parseNodeStatus([1, 2, 3]) == nil)
        #expect(NetBIOS.parseNodeStatus([UInt8](repeating: 0, count: 60)) == nil)
    }
}

struct PublicNetworkTests {
    @Test func stripsAutonomousSystemNumber() {
        #expect(PublicNetworkLookup.ispName(fromOrg: "AS64500 Example Telecom S.A.") == "Example Telecom S.A.")
        #expect(PublicNetworkLookup.ispName(fromOrg: "Some ISP") == "Some ISP")
        #expect(PublicNetworkLookup.ispName(fromOrg: nil) == nil)
    }

    @Test func mergesIPv4AndIPv6Answers() throws {
        let v4 = try JSONDecoder().decode(PublicNetworkLookup.IPInfo.self, from: Data("""
        {"ip": "203.0.113.10", "city": "Buenos Aires", "country": "AR", "org": "AS64500 Example Telecom S.A.", "readme": "x"}
        """.utf8))
        let v6 = PublicNetworkLookup.IPInfo(ip: "2001:db8:1:2::1", org: nil, country: "AR", city: nil)

        let info = try #require(PublicNetworkLookup.merge(v4, v6))
        #expect(info.ipv4 == "203.0.113.10")
        #expect(info.ipv6 == "2001:db8:1:2::1")
        #expect(info.isp == "Example Telecom S.A.")
        #expect(info.flag == "🇦🇷")

        #expect(PublicNetworkLookup.merge(nil, v6)?.ipv4 == nil)
        #expect(PublicNetworkLookup.merge(nil, nil) == nil)
    }
}
