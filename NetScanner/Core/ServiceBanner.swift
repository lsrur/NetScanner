import Foundation
import Network

/// What an open TCP port says about itself: the `Server` header of web servers, or the greeting
/// that SSH, FTP, SMTP, POP3, IMAP, MySQL… send as soon as you connect.
enum ServiceBanner {
    static func grab(_ address: IPv4Address, port: UInt16, webURL: URL?, timeout: TimeInterval = 1.5) async -> String? {
        if let webURL {
            return await LocalHTTP.headers(webURL)?.value(forHTTPHeaderField: "Server").flatMap(clean)
        }
        guard let data = await TCPExchange.firstBytes(address, port: port, timeout: timeout) else { return nil }
        return parse(Array(data))
    }

    static func parse(_ bytes: [UInt8]) -> String? {
        // MySQL/MariaDB handshake: 3-byte length, sequence 0, protocol 10, NUL-terminated version.
        if bytes.count > 6, bytes[3] == 0, bytes[4] == 10, let end = bytes[5...].firstIndex(of: 0) {
            let version = String(decoding: bytes[5..<end], as: UTF8.self)
            if version.first?.isNumber == true {
                return "MySQL " + version
            }
        }
        let text = String(decoding: bytes.prefix(512), as: UTF8.self)
        guard let line = text.split(whereSeparator: \.isNewline).first.map(String.init) else { return nil }
        var banner = line
        if banner.hasPrefix("SSH-") {
            // "SSH-2.0-OpenSSH_9.6p1 Ubuntu-3" → "OpenSSH 9.6p1 Ubuntu-3"
            banner = banner.split(separator: "-", maxSplits: 2).dropFirst(2).first.map(String.init) ?? banner
            banner = banner.replacingOccurrences(of: "_", with: " ")
        } else {
            for prefix in ["220-", "220 ", "+OK ", "* OK ", "200 "] where banner.hasPrefix(prefix) {
                banner = String(banner.dropFirst(prefix.count))
                break
            }
        }
        return clean(banner)
    }

    /// Printable ASCII only, trimmed, at most 80 characters; nil for binary protocols.
    private static func clean(_ text: String) -> String? {
        let printable = text.unicodeScalars.filter { (0x20...0x7E).contains($0.value) }
        guard printable.count * 10 >= text.unicodeScalars.count * 9 else { return nil }  // mostly binary
        let result = String(String.UnicodeScalarView(printable)).trimmingCharacters(in: .whitespaces)
        guard result.count >= 3 else { return nil }
        return result.count > 80 ? String(result.prefix(79)) + "…" : result
    }
}

enum TCPExchange {
    private static let queue = DispatchQueue(label: "NetScanner.TCPExchange", attributes: .concurrent)

    /// Connects and returns whatever the server sends first, without sending anything.
    static func firstBytes(_ address: IPv4Address, port: UInt16, timeout: TimeInterval) async -> Data? {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return nil }
        let connection = NWConnection(host: NWEndpoint.Host(address.description), port: endpointPort, using: .tcp)
        return await withCheckedContinuation { continuation in
            let finish = ConnectionFinisher<Data?>(connection: connection, continuation: continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 512) { data, _, _, _ in
                        finish(data.flatMap { $0.isEmpty ? nil : $0 })
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

    /// Sends `request` and reads until the server closes or `limit` bytes/`timeout` is reached.
    static func request(_ host: String, port: UInt16, request: Data, timeout: TimeInterval, limit: Int = 128_000) async -> Data? {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return nil }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        let buffer = DataBuffer()
        return await withCheckedContinuation { continuation in
            let finish = ConnectionFinisher<Data?>(connection: connection, continuation: continuation)
            @Sendable func readMore() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, isComplete, error in
                    if let data { buffer.append(data) }
                    if isComplete || error != nil || buffer.count >= limit {
                        finish(buffer.data.isEmpty ? nil : buffer.data)
                    } else {
                        readMore()
                    }
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: request, completion: .contentProcessed { _ in })
                    readMore()
                case .waiting, .failed:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(buffer.data.isEmpty ? nil : buffer.data) }
        }
    }

    private final class DataBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()
        func append(_ data: Data) { lock.withLock { storage.append(data) } }
        var data: Data { lock.withLock { storage } }
        var count: Int { lock.withLock { storage.count } }
    }
}
