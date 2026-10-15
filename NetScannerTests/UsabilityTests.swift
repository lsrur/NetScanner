import Foundation
import Network
import Testing
@testable import NetScanner

struct WakeOnLANTests {
    @Test func buildsMagicPacket() {
        let mac = MACAddress("00:11:22:33:44:55")!
        let packet = WakeOnLAN.magicPacket(for: mac)
        #expect(packet.count == 102)
        #expect(packet.prefix(6).allSatisfy { $0 == 0xFF })
        #expect(Array(packet[6..<12]) == mac.bytes)
        #expect(Array(packet.suffix(6)) == mac.bytes)
    }

    /// Sends a real packet to a loopback UDP listener and checks what arrives.
    @Test func sendsPacketOverUDP() async throws {
        let listener = try NWListener(using: .udp, on: .any)
        let received = AsyncStream<Data> { continuation in
            listener.newConnectionHandler = { connection in
                connection.start(queue: .global())
                connection.receiveMessage { data, _, _, _ in
                    if let data { continuation.yield(data) }
                }
            }
        }
        let ready = AsyncStream<UInt16> { continuation in
            listener.stateUpdateHandler = { state in
                if case .ready = state { continuation.yield(listener.port?.rawValue ?? 0) }
            }
        }
        listener.start(queue: .global())
        defer { listener.cancel() }
        var readyIterator = ready.makeAsyncIterator()
        let port = try #require(await readyIterator.next())

        let mac = MACAddress("00:11:22:33:44:55")!
        #expect(WakeOnLAN.wake(mac, to: [NetScanner.IPv4Address("127.0.0.1")!], port: port) == 1)
        var dataIterator = received.makeAsyncIterator()
        let data = try #require(await dataIterator.next())
        #expect(Array(data) == WakeOnLAN.magicPacket(for: mac))
    }
}

struct HostFilterTests {
    private var host: DiscoveredHost {
        var host = DiscoveredHost(interface: "en0", address: NetScanner.IPv4Address("192.168.1.20")!, source: .icmp,
                                  mac: MACAddress("00:11:32:a4:b2:20"), vendor: "Synology Incorporated")
        host.customName = "Synology NAS"
        host.comment = "Backups + Plex"
        host.services = [BonjourService(type: "_smb._tcp", name: "DiskStation")]
        return host
    }

    @Test func matchesAnyFieldAndAllTerms() {
        #expect(HostFilter.matches(host, query: ""))
        #expect(HostFilter.matches(host, query: "192.168.1.2"))
        #expect(HostFilter.matches(host, query: "b2:20"))
        #expect(HostFilter.matches(host, query: "plex"))
        #expect(HostFilter.matches(host, query: "SYNOLOGY backups"))
        #expect(HostFilter.matches(host, query: "smb"))
        #expect(HostFilter.matches(host, query: "nas"))  // device type
        #expect(!HostFilter.matches(host, query: "synology printer"))
    }
}

struct NetworkSettingsTests {
    /// Uses the real system configuration from inside the sandbox.
    @Test func readsDNSServers() {
        let servers = DNSServers.current()
        #expect(!servers.isEmpty)
        #expect(servers.allSatisfy { !$0.contains("%") })
    }
}
