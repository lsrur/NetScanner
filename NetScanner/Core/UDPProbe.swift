import Foundation

/// A UDP service probed with a real request of its protocol: UDP has no handshake, so a port
/// only counts as open when it answers. An ICMP port-unreachable means closed; silence is
/// "no response" (open but quiet, or filtered).
struct UDPService: Sendable {
    let port: UInt16
    let name: String
    let request: [UInt8]
    /// Turns the reply into a short description ("NTP stratum 2", the SNMP sysDescr…).
    let describe: @Sendable ([UInt8]) -> String?
}

enum UDPProbe {
    enum Outcome: Equatable, Sendable {
        case reply([UInt8])
        case refused
        case noResponse
    }

    static let services: [UDPService] = [
        UDPService(port: 53, name: "dns", request: dnsQuery) { reply in
            reply.count >= 4 ? "DNS server (rcode \(reply[3] & 0x0F))" : "DNS server"
        },
        UDPService(port: 69, name: "tftp", request: tftpReadRequest) { _ in
            "TFTP server"
        },
        UDPService(port: 123, name: "ntp", request: ntpRequest) { reply in
            reply.count > 1 ? "NTP stratum \(reply[1])" : "NTP server"
        },
        UDPService(port: 137, name: "netbios-ns", request: NetBIOS.nodeStatusRequest(transactionID: 0x4E53)) { reply in
            NetBIOS.parseNodeStatus(reply).flatMap(NetBIOS.machineName).map { "NetBIOS name \($0)" } ?? "NetBIOS name service"
        },
        UDPService(port: 161, name: "snmp", request: snmpGetSysDescr) { reply in
            snmpString(in: reply).map { "SNMP: \($0)" } ?? "SNMP agent"
        },
        UDPService(port: 1900, name: "ssdp", request: ssdpUnicastSearch) { reply in
            header("SERVER", in: reply).map { "UPnP: \($0)" } ?? "UPnP/SSDP"
        },
        UDPService(port: 5060, name: "sip", request: Array(sipOptions.utf8)) { reply in
            (header("SERVER", in: reply) ?? header("USER-AGENT", in: reply)).map { "SIP: \($0)" } ?? "SIP"
        },
        UDPService(port: 5353, name: "mdns", request: mdnsServicesQuery) { _ in
            "Bonjour / mDNS responder"
        },
        UDPService(port: 5683, name: "coap", request: coapDiscovery) { _ in
            "CoAP (IoT)"
        },
        UDPService(port: 10001, name: "ubnt-discovery", request: [0x01, 0x00, 0x00, 0x00]) { _ in
            "Ubiquiti discovery"
        },
    ]

    static func probe(_ address: IPv4Address, service: UDPService, timeout: TimeInterval = 1.5) async -> Outcome {
        let request = service.request
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: exchange(address, port: service.port, request: request, timeout: timeout))
            }
        }
    }

    /// A connected UDP socket so the kernel reports ICMP port-unreachable as ECONNREFUSED.
    private static func exchange(_ address: IPv4Address, port: UInt16, request: [UInt8], timeout: TimeInterval) -> Outcome {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return .noResponse }
        defer { close(fd) }
        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = port.bigEndian
        target.sin_addr = address.inAddr
        let connected = withUnsafePointer(to: &target) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return .noResponse }
        var wait = timeval(tv_sec: 0, tv_usec: 250_000)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))

        // Text requests (SSDP, SIP) name the target host; binary ones are sent as is.
        let bytes: [UInt8] = request.contains(0)
            ? request
            : Array(String(decoding: request, as: UTF8.self).replacingOccurrences(of: "{host}", with: address.description).utf8)
        func transmit() { _ = bytes.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) } }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let capacity = buffer.count
        let deadline = Date().addingTimeInterval(timeout)
        let retryAt = Date().addingTimeInterval(timeout / 2)
        var retried = false
        transmit()
        while Date() < deadline {
            if !retried, Date() > retryAt {  // UDP may drop the first request
                transmit()
                retried = true
            }
            let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, capacity, 0) }
            if count > 0 { return .reply(Array(buffer[..<count])) }
            if count < 0, errno == ECONNREFUSED { return .refused }
        }
        return .noResponse
    }

    // MARK: Requests

    /// Standard query for the root NS records; any answer (even REFUSED) proves a DNS server.
    static let dnsQuery: [UInt8] = [0x4E, 0x53, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01]

    /// SNMPv2c GetRequest, community "public", OID 1.3.6.1.2.1.1.1.0 (sysDescr).
    static let snmpGetSysDescr: [UInt8] = [
        0x30, 0x29, 0x02, 0x01, 0x01, 0x04, 0x06, 0x70, 0x75, 0x62, 0x6C, 0x69, 0x63,
        0xA0, 0x1C, 0x02, 0x04, 0x4E, 0x53, 0x00, 0x01, 0x02, 0x01, 0x00, 0x02, 0x01, 0x00,
        0x30, 0x0E, 0x30, 0x0C, 0x06, 0x08, 0x2B, 0x06, 0x01, 0x02, 0x01, 0x01, 0x01, 0x00, 0x05, 0x00,
    ]

    /// Length-prefixed DNS labels plus the root terminator.
    static func dnsName(_ labels: [String]) -> [UInt8] {
        var bytes: [UInt8] = []
        for label in labels {
            bytes.append(UInt8(label.utf8.count))
            bytes += Array(label.utf8)
        }
        bytes.append(0)
        return bytes
    }

    /// Unicast mDNS query (from an ephemeral port, so the answer comes back to us) for the
    /// service-type enumeration name, PTR, class IN with the unicast-response bit.
    static let mdnsServicesQuery: [UInt8] = {
        var bytes: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        bytes += dnsName(["_services", "_dns-sd", "_udp", "local"])
        bytes += [0x00, 0x0C, 0x80, 0x01]
        return bytes
    }()

    /// TFTP read request for a file that won't exist; servers answer with an error packet.
    static let tftpReadRequest: [UInt8] = {
        var bytes: [UInt8] = [0x00, 0x01]
        bytes += Array("netscanner-probe".utf8)
        bytes.append(0)
        bytes += Array("octet".utf8)
        bytes.append(0)
        return bytes
    }()

    /// NTPv3 client request.
    static let ntpRequest: [UInt8] = [0x1B] + [UInt8](repeating: 0, count: 47)

    /// The SSDP search, sent to the host instead of the multicast group.
    static let ssdpUnicastSearch: [UInt8] = Array(SSDP.searchRequest.replacingOccurrences(of: "239.255.255.250", with: "{host}").utf8)

    /// CoAP GET /.well-known/core.
    static let coapDiscovery: [UInt8] = {
        var bytes: [UInt8] = [0x40, 0x01, 0x4E, 0x53, 0xBB]
        bytes += Array(".well-known".utf8)
        bytes.append(0x04)
        bytes += Array("core".utf8)
        return bytes
    }()

    static let sipOptions = [
        "OPTIONS sip:probe@{host} SIP/2.0",
        "Via: SIP/2.0/UDP 0.0.0.0:5060;branch=z9hG4bK-netscanner",
        "From: <sip:probe@netscanner>;tag=1",
        "To: <sip:probe@{host}>",
        "Call-ID: netscanner-probe",
        "CSeq: 1 OPTIONS",
        "Max-Forwards: 1",
        "Content-Length: 0",
        "", "",
    ].joined(separator: "\r\n")

    // MARK: Reply parsing

    /// The OCTET STRING value following the sysDescr OID in an SNMP response.
    static func snmpString(in reply: [UInt8]) -> String? {
        let oid: [UInt8] = [0x2B, 0x06, 0x01, 0x02, 0x01, 0x01, 0x01, 0x00]
        guard let start = (0...max(0, reply.count - oid.count)).first(where: { Array(reply[$0..<min($0 + oid.count, reply.count)]) == oid }) else {
            return nil
        }
        var index = start + oid.count
        guard index + 1 < reply.count, reply[index] == 0x04 else { return nil }
        index += 1
        var length = Int(reply[index])
        index += 1
        if length & 0x80 != 0 {  // long form
            let bytes = length & 0x7F
            guard bytes <= 2, index + bytes <= reply.count else { return nil }
            length = reply[index..<(index + bytes)].reduce(0) { $0 << 8 | Int($1) }
            index += bytes
        }
        guard length > 0, index + length <= reply.count else { return nil }
        let text = String(decoding: reply[index..<(index + length)], as: UTF8.self)
            .components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !text.isEmpty else { return nil }
        return text.count > 80 ? String(text.prefix(79)) + "…" : text
    }

    /// An HTTP-style header value (SSDP, SIP).
    static func header(_ name: String, in reply: [UInt8]) -> String? {
        for line in String(decoding: reply, as: UTF8.self).components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":"), line[..<colon].uppercased() == name else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { return value }
        }
        return nil
    }
}
