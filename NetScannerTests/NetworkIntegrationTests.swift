import Foundation
import Network
import Testing
@testable import NetScanner

/// Exercises real sockets from inside the sandboxed host app, against loopback only.
struct NetworkIntegrationTests {
    private let loopback = NetScanner.IPv4Address("127.0.0.1")!

    @Test func pingsLoopback() async throws {
        let pinger = try ICMPPinger()
        var stats = PingStats()
        for _ in 0..<5 {
            let outcome = await pinger.ping(loopback, timeout: 1)
            if case .reply(let ms) = outcome { stats.record(ms) } else { stats.record(nil) }
        }
        #expect(stats.received == 5)
        #expect(try #require(stats.maximum) < 50)
    }

    @Test func concurrentPingsAreMatchedToTheirRequests() async throws {
        let pinger = try ICMPPinger()
        let outcomes = await withTaskGroup(of: PingOutcome.self) { group in
            for _ in 0..<200 {
                group.addTask { await pinger.ping(loopback, timeout: 1) }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(outcomes.allSatisfy { if case .reply = $0 { true } else { false } }, "\(outcomes.map { "\($0)" }.reduce(into: [String: Int]()) { $0[String($1.prefix(9)), default: 0] += 1 })")
    }

    @Test func detectsOpenAndClosedPorts() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { $0.cancel() }
        let ready = AsyncStream<UInt16> { continuation in
            listener.stateUpdateHandler = { state in
                if case .ready = state { continuation.yield(listener.port?.rawValue ?? 0) }
            }
        }
        listener.start(queue: .global())
        defer { listener.cancel() }
        var iterator = ready.makeAsyncIterator()
        let port = try #require(await iterator.next())

        #expect(await TCPProbe.probe(loopback, port: port, timeout: 1) == .open)
        #expect(await TCPProbe.probe(loopback, port: 1, timeout: 1) == .closed)
    }

    @Test func resolvesHostnames() async throws {
        #expect(try await HostResolver.resolveIPv4("localhost") == loopback)
        #expect(try await HostResolver.resolveIPv4("10.1.2.3") == NetScanner.IPv4Address("10.1.2.3"))
    }

    /// Uses the real LAN: pings the first host of the subnet (usually the router), then reads MACs from the sandbox.
    @Test func readsARPCacheFromSandbox() async throws {
        let interface = try #require(NetworkInterface.current().first)
        let pinger = try ICMPPinger()
        _ = await pinger.ping(NetScanner.IPv4Address(raw: interface.subnet.network.raw + 1), timeout: 1)
        let table = ARPTable.read()
        #expect(table.keys.contains { interface.subnet.contains($0) }, "\(table)")
    }

    /// mDNSResponder publishes a reverse PTR for this Mac's own address, so it must resolve.
    @Test func resolvesOwnAddressOverMulticastDNS() async throws {
        let interface = try #require(NetworkInterface.current().first)
        let name = await MulticastDNS.reverseLookup(interface.address)
        #expect(name?.isEmpty == false)
        #expect(name?.hasSuffix(".local") == false)
    }

    /// Uses the real LAN: after the all-nodes ping the sandboxed app must see link-local addresses
    /// of other devices with their real (not redacted) MACs.
    @Test func readsIPv6NeighborsFromSandbox() async throws {
        let interface = try #require(NetworkInterface.current().first)
        IPv6Neighbors.pingAllNodes(interface: interface.name)
        try await Task.sleep(for: .milliseconds(1500))
        let entries = IPv6Neighbors.read(interface: interface.name)
        #expect(entries.contains { $0.isLinkLocal && $0.mac != interface.macAddress }, "\(entries)")
        #expect(!entries.contains { $0.mac.isRedacted })
    }

    /// Uses the real LAN: the primary interface has a default gateway inside its subnet.
    @Test func findsDefaultGateway() throws {
        let interface = try #require(NetworkInterface.current().first)
        let gateway = try #require(DefaultGateway.read()[interface.name])
        #expect(interface.subnet.contains(gateway))
    }

    @Test func findsActiveInterface() {
        let interfaces = NetworkInterface.current()
        #expect(!interfaces.isEmpty)
        #expect(interfaces.allSatisfy { $0.subnet.contains($0.address) })
        #expect(interfaces.first?.ipv6Addresses.contains { $0.hasPrefix("fe80::") } == true)
    }
}
