import Foundation
import Network
import Testing
@testable import NetScanner

struct TraceTests {
    @Test func parsesTimeExceededQuotingOurRequest() throws {
        let request = ICMPPacket.echoRequest(identifier: 0xBEEF, sequence: 42)
        let innerIP: [UInt8] = [0x45] + [UInt8](repeating: 0, count: 19)
        let outerIP: [UInt8] = [0x45] + [UInt8](repeating: 0, count: 19)
        let timeExceeded: [UInt8] = [11, 0, 0, 0, 0, 0, 0, 0] + innerIP + Array(request.prefix(8))
        let parsed = try #require(ICMPPacket.parseError(outerIP + timeExceeded))
        #expect(parsed.type == 11)
        #expect(parsed.identifier == 0xBEEF)
        #expect(parsed.sequence == 42)
        #expect(ICMPPacket.parseError(request) == nil)  // an echo request isn't an error
    }

    @Test func formatsRTTs() {
        #expect(TraceResultsView.rttText([12.34, nil, 9]) == "12.3  *  9.0 ms")
        #expect(TraceResultsView.rttText([nil, nil, nil]) == "*  *  *")
    }

    /// Loopback: the first hop is already the destination.
    @Test func tracesLoopback() async throws {
        let tracer = try ICMPTracer()
        let result = await tracer.probe(NetScanner.IPv4Address("127.0.0.1")!, ttl: 1, timeout: 1)
        guard case .answer(let from, _, .echoReply) = result else {
            Issue.record("expected an echo reply, got \(result)")
            return
        }
        #expect(from.description == "127.0.0.1")
    }
}

struct BannerTests {
    @Test func parsesCommonGreetings() {
        #expect(ServiceBanner.parse(Array("SSH-2.0-OpenSSH_9.6p1 Ubuntu-3\r\n".utf8)) == "OpenSSH 9.6p1 Ubuntu-3")
        #expect(ServiceBanner.parse(Array("220 (vsFTPd 3.0.5)\r\n".utf8)) == "(vsFTPd 3.0.5)")
        #expect(ServiceBanner.parse(Array("220 mail.example.com ESMTP Postfix\r\n".utf8)) == "mail.example.com ESMTP Postfix")
        #expect(ServiceBanner.parse(Array("+OK Dovecot ready.\r\n".utf8)) == "Dovecot ready.")
        let mysql: [UInt8] = [0x4A, 0, 0, 0, 10] + Array("8.0.36".utf8) + [0, 1, 2, 3]
        #expect(ServiceBanner.parse(mysql) == "MySQL 8.0.36")
        #expect(ServiceBanner.parse([0x00, 0x01, 0xFF, 0xFE, 0x10, 0x80]) == nil)
    }

    @Test func grabsGreetingFromLoopbackServer() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.send(content: Data("SSH-2.0-OpenSSH_9.6p1\r\n".utf8), completion: .contentProcessed { _ in })
        }
        let ready = AsyncStream<UInt16> { continuation in
            listener.stateUpdateHandler = { if case .ready = $0 { continuation.yield(listener.port?.rawValue ?? 0) } }
        }
        listener.start(queue: .global())
        defer { listener.cancel() }
        var iterator = ready.makeAsyncIterator()
        let port = try #require(await iterator.next())
        #expect(await ServiceBanner.grab(NetScanner.IPv4Address("127.0.0.1")!, port: port, webURL: nil) == "OpenSSH 9.6p1")
    }
}

struct UDPProbeTests {
    @Test func parsesSNMPAndHeaders() {
        let description = Array("Example Router OS 1.2".utf8)
        let reply: [UInt8] = [0x30, 0x00, 0x2B, 0x06, 0x01, 0x02, 0x01, 0x01, 0x01, 0x00, 0x04, UInt8(description.count)] + description
        #expect(UDPProbe.snmpString(in: reply) == "Example Router OS 1.2")
        #expect(UDPProbe.snmpString(in: [1, 2, 3]) == nil)
        let ssdp = Array("HTTP/1.1 200 OK\r\nServer: Linux UPnP/1.0 Example/2\r\n\r\n".utf8)
        #expect(UDPProbe.header("SERVER", in: ssdp) == "Linux UPnP/1.0 Example/2")
        #expect(UDPProbe.services.map(\.port) == UDPProbe.services.map(\.port).sorted())
    }

    @Test func detectsOpenAndClosedLoopbackPorts() async throws {
        let listener = try NWListener(using: .udp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receiveMessage { _, _, _, _ in
                connection.send(content: Data("pong".utf8), completion: .contentProcessed { _ in })
            }
        }
        let ready = AsyncStream<UInt16> { continuation in
            listener.stateUpdateHandler = { if case .ready = $0 { continuation.yield(listener.port?.rawValue ?? 0) } }
        }
        listener.start(queue: .global())
        defer { listener.cancel() }
        var iterator = ready.makeAsyncIterator()
        let port = try #require(await iterator.next())
        let loopback = NetScanner.IPv4Address("127.0.0.1")!

        let open = UDPService(port: port, name: "test", request: [0x01]) { String(decoding: $0, as: UTF8.self) }
        #expect(await UDPProbe.probe(loopback, service: open, timeout: 1) == .reply(Array("pong".utf8)))
        let closed = UDPService(port: 9, name: "discard", request: [0x01]) { _ in nil }
        #expect(await UDPProbe.probe(loopback, service: closed, timeout: 1) == .refused)
    }
}

struct DNSAndWhoisTests {
    @Test func decodesRecordData() {
        #expect(DNSLookup.decode(type: 1, rdata: [192, 0, 2, 10]) == ("A", "192.0.2.10"))
        #expect(DNSLookup.decode(type: 28, rdata: [0x20, 0x01, 0x0D, 0xB8] + [UInt8](repeating: 0, count: 11) + [1]) == ("AAAA", "2001:db8::1"))
        let name = UDPProbe.dnsName(["mail", "example", "com"])
        #expect(DNSLookup.decode(type: 15, rdata: [0, 10] + name) == ("MX", "10 mail.example.com."))
        #expect(DNSLookup.decode(type: 16, rdata: [5] + Array("hello".utf8) + [2] + Array("hi".utf8)) == ("TXT", "\"hello\" \"hi\""))
        #expect(DNSLookup.decode(type: 33, rdata: [0, 1, 0, 5, 0x01, 0xBB] + name) == ("SRV", "1 5 443 mail.example.com."))
        let soa = UDPProbe.dnsName(["ns", "example", "com"]) + UDPProbe.dnsName(["admin", "example", "com"]) + (1...5).flatMap { [0, 0, 0, UInt8($0)] }
        #expect(DNSLookup.decode(type: 6, rdata: soa).1 == "ns.example.com. admin.example.com. serial 1 refresh 2 retry 3 expire 4 minimum 5")
        #expect(DNSLookup.decode(type: 99, rdata: [0xAB]) == ("TYPE99", "ab"))
    }

    /// Through the system resolver, which answers localhost without the network.
    @Test func looksUpLocalhost() async {
        let records = await DNSLookup.query("localhost", type: .a)
        #expect(records.contains { $0.type == "A" && $0.value == "127.0.0.1" })
    }

    @Test func followsWhoisReferrals() {
        #expect(Whois.referral(in: "domain: COM\nrefer:        whois.verisign-grs.com\n") == "whois.verisign-grs.com")
        #expect(Whois.referral(in: "   Registrar WHOIS Server: whois.example-registrar.com\n") == "whois.example-registrar.com")
        #expect(Whois.referral(in: "ReferralServer:  whois://whois.example.net:43\n") == "whois.example.net")
        #expect(Whois.referral(in: "% no referral here\n") == nil)
        #expect(Whois.isPrivate(NetScanner.IPv4Address("192.168.1.20")!))
        #expect(Whois.isPrivate(NetScanner.IPv4Address("100.64.3.1")!))
        #expect(!Whois.isPrivate(NetScanner.IPv4Address("203.0.113.42")!))
    }
}

@MainActor
struct NetworkToolsModelTests {
    /// Loopback keeps it off the network: one hop, a PTR answer and the private-address note.
    @Test func runsCheckedToolsInOrder() async throws {
        let model = NetworkToolsModel()
        model.destination = "127.0.0.1"
        model.ping.count = 2
        model.ping.interval = 0.2
        model.run()
        #expect(model.tabs == [.ping, .traceroute, .dns, .whois])
        #expect(model.selectedTab == .ping)
        var started: [NetworkTool] = []
        let deadline = Date().addingTimeInterval(20)
        while model.isRunning, Date() < deadline {
            for tool in NetworkTool.allCases where model.status(of: tool) == .running && started.last != tool {
                started.append(tool)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.isRunning)
        #expect(started.first == .ping)
        #expect(NetworkTool.allCases.allSatisfy { model.status(of: $0) == .done })
        #expect(model.ping.stats.received == 2)
        #expect(model.trace.reachedDestination)
        #expect(model.whois.message?.contains("private address") == true)

        model.enabled = [.dns]
        model.run()
        #expect(model.tabs == [.dns])
        #expect(model.selectedTab == .dns)
        model.stop()
        #expect(!model.isRunning)
        #expect(model.status(of: .dns) == .idle)
    }
}
