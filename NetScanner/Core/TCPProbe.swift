import Foundation
import Network

enum PortState: String, Sendable {
    case open = "Open"
    case closed = "Closed"
    case filtered = "Filtered"
}

enum TCPProbe {
    private static let queue = DispatchQueue(label: "NetScanner.TCPProbe", attributes: .concurrent)

    /// Attempts a TCP handshake: `.open` on connect, `.closed` on RST, `.filtered` on timeout or other errors.
    static func probe(_ address: IPv4Address, port: UInt16, timeout: TimeInterval) async -> PortState {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return .filtered }
        let connection = NWConnection(host: NWEndpoint.Host(address.description), port: endpointPort, using: .tcp)

        return await withCheckedContinuation { continuation in
            let finish = ConnectionFinisher<PortState>(connection: connection, continuation: continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(.open)
                case .waiting(let error), .failed(let error):
                    finish(portState(for: error))
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(.filtered) }
        }
    }

    private static func portState(for error: NWError) -> PortState {
        if case .posix(.ECONNREFUSED) = error { return .closed }
        return .filtered
    }
}

/// Resumes a connection's continuation exactly once and tears the connection down.
final class ConnectionFinisher<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<Value, Never>?

    init(connection: NWConnection, continuation: CheckedContinuation<Value, Never>) {
        self.connection = connection
        self.continuation = continuation
    }

    func callAsFunction(_ value: Value) {
        let (connection, continuation) = lock.withLock {
            defer { self.connection = nil; self.continuation = nil }
            return (self.connection, self.continuation)
        }
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        continuation?.resume(returning: value)
    }
}
