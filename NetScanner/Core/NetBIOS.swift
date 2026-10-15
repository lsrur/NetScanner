import Foundation
import Network

/// NetBIOS Node Status (NBSTAT) lookups on UDP 137: Windows machines, Samba servers and many NAS
/// answer with the names they registered, which is what Finder and LanScan show as the SMB name.
enum NetBIOS {
    struct NameEntry: Equatable {
        let name: String
        let suffix: UInt8
        let isGroup: Bool
    }

    static func lookup(_ address: IPv4Address, port: UInt16 = 137, timeout: TimeInterval = 1) async -> String? {
        let request = nodeStatusRequest(transactionID: UInt16.random(in: .min ... .max))
        guard let reply = await UDPExchange.request(address, port: port, payload: Data(request), timeout: timeout),
              let entries = parseNodeStatus(Array(reply)) else { return nil }
        return machineName(from: entries)
    }

    /// Query for the wildcard name `*` with type NBSTAT (0x21), class IN.
    static func nodeStatusRequest(transactionID: UInt16) -> [UInt8] {
        var packet: [UInt8] = [UInt8(transactionID >> 8), UInt8(transactionID & 0xFF),
                               0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        // First-level encoding (RFC 1001 §14.1): each nibble becomes 'A' + nibble.
        let name: [UInt8] = [0x2A] + [UInt8](repeating: 0, count: 15)
        packet.append(0x20)
        for byte in name {
            packet.append(0x41 + (byte >> 4))
            packet.append(0x41 + (byte & 0x0F))
        }
        packet += [0x00, 0x00, 0x21, 0x00, 0x01]
        return packet
    }

    static func parseNodeStatus(_ bytes: [UInt8]) -> [NameEntry]? {
        var index = 12
        // Skip the echoed question name (labels or a compression pointer).
        while index < bytes.count {
            let length = bytes[index]
            if length == 0 {
                index += 1
                break
            }
            if length & 0xC0 == 0xC0 {
                index += 2
                break
            }
            index += 1 + Int(length)
        }
        // type(2) class(2) ttl(4) rdlength(2), then the name count.
        guard index + 11 <= bytes.count, bytes[index] == 0x00, bytes[index + 1] == 0x21 else { return nil }
        index += 10
        let count = Int(bytes[index])
        index += 1

        var entries: [NameEntry] = []
        for _ in 0..<count {
            guard index + 18 <= bytes.count else { break }
            let raw = bytes[index..<(index + 15)]
            let name = String(decoding: raw.map { $0 < 0x20 ? 0x20 : $0 }, as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            let flags = UInt16(bytes[index + 16]) << 8 | UInt16(bytes[index + 17])
            entries.append(NameEntry(name: name, suffix: bytes[index + 15], isGroup: flags & 0x8000 != 0))
            index += 18
        }
        return entries
    }

    /// The unique workstation name (suffix 0x00), else the file server name (0x20).
    static func machineName(from entries: [NameEntry]) -> String? {
        let unique = entries.filter { !$0.isGroup && !$0.name.isEmpty }
        return (unique.first { $0.suffix == 0x00 } ?? unique.first { $0.suffix == 0x20 })?.name
    }
}

/// One UDP request/response with a timeout; nil on timeout, ICMP unreachable or any error.
enum UDPExchange {
    private static let queue = DispatchQueue(label: "NetScanner.UDPExchange", attributes: .concurrent)

    static func request(_ address: IPv4Address, port: UInt16, payload: Data, timeout: TimeInterval) async -> Data? {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return nil }
        let connection = NWConnection(host: NWEndpoint.Host(address.description), port: endpointPort, using: .udp)

        return await withCheckedContinuation { continuation in
            let finish = ConnectionFinisher<Data?>(connection: connection, continuation: continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: payload, completion: .contentProcessed { error in
                        if error != nil { finish(nil) }
                    })
                    connection.receiveMessage { data, _, _, error in
                        finish(error == nil ? data : nil)
                    }
                case .waiting, .failed:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }
}
