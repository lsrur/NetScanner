import Foundation
import Network

enum WebScheme: String, Sendable {
    case http
    case https
}

/// Detects whether an open port serves a web UI by actually speaking HTTP to it,
/// so non-standard ports (8080, 8123, 3000…) work and non-web TLS services (993, 5223…) don't.
enum WebProbe {
    private static let queue = DispatchQueue(label: "NetScanner.WebProbe", attributes: .concurrent)

    /// TLS first: a plain request to a TLS port often gets an HTTP 400 back (nginx), which would
    /// otherwise be misread as plain HTTP.
    static func detect(_ address: IPv4Address, port: UInt16, timeout: TimeInterval = 2) async -> WebScheme? {
        if await speaksHTTP(address, port: port, tls: true, timeout: timeout) { return .https }
        if await speaksHTTP(address, port: port, tls: false, timeout: timeout) { return .http }
        return nil
    }

    static func url(_ scheme: WebScheme, address: IPv4Address, port: UInt16) -> URL? {
        let isDefaultPort = (scheme == .http && port == 80) || (scheme == .https && port == 443)
        return URL(string: "\(scheme.rawValue)://\(address)" + (isDefaultPort ? "" : ":\(port)"))
    }

    static func looksLikeHTTPResponse(_ data: Data?) -> Bool {
        guard let data else { return false }
        return data.starts(with: Data("HTTP/".utf8))
    }

    private static func speaksHTTP(_ address: IPv4Address, port: UInt16, tls: Bool, timeout: TimeInterval) async -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return false }
        let parameters: NWParameters
        if tls {
            let options = NWProtocolTLS.Options()
            // Routers, NAS and printers almost always use self-signed certificates.
            sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, _, complete in
                complete(true)
            }, queue)
            parameters = NWParameters(tls: options)
        } else {
            parameters = .tcp
        }
        let connection = NWConnection(host: NWEndpoint.Host(address.description), port: endpointPort, using: parameters)
        let request = Data("HEAD / HTTP/1.0\r\nHost: \(address)\r\n\r\n".utf8)

        return await withCheckedContinuation { continuation in
            let finish = ConnectionFinisher<Bool>(connection: connection, continuation: continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: request, completion: .contentProcessed { error in
                        if error != nil { finish(false) }
                    })
                    connection.receive(minimumIncompleteLength: 5, maximumLength: 64) { data, _, _, _ in
                        finish(looksLikeHTTPResponse(data))
                    }
                case .waiting, .failed:
                    finish(false)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }
}
