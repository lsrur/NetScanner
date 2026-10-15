import Foundation
import Network
import Testing
@testable import NetScanner

struct WebProbeTests {
    private let router = NetScanner.IPv4Address("192.168.0.1")!

    @Test func buildsURLsOmittingDefaultPorts() {
        #expect(WebProbe.url(.http, address: router, port: 80)?.absoluteString == "http://192.168.0.1")
        #expect(WebProbe.url(.https, address: router, port: 443)?.absoluteString == "https://192.168.0.1")
        #expect(WebProbe.url(.http, address: router, port: 8123)?.absoluteString == "http://192.168.0.1:8123")
        #expect(WebProbe.url(.https, address: router, port: 80)?.absoluteString == "https://192.168.0.1:80")
    }

    @Test func recognizesHTTPStatusLine() {
        #expect(WebProbe.looksLikeHTTPResponse(Data("HTTP/1.1 200 OK\r\n".utf8)))
        #expect(!WebProbe.looksLikeHTTPResponse(Data("SSH-2.0-OpenSSH_9.6\r\n".utf8)))
        #expect(!WebProbe.looksLikeHTTPResponse(nil))
    }

    /// Starts a loopback TCP server that answers every connection with `banner`.
    private func server(replying banner: String) async throws -> (NWListener, UInt16) {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, _, _ in
                connection.send(content: Data(banner.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let ready = AsyncStream<UInt16> { continuation in
            listener.stateUpdateHandler = { state in
                if case .ready = state { continuation.yield(listener.port?.rawValue ?? 0) }
            }
        }
        listener.start(queue: .global())
        var iterator = ready.makeAsyncIterator()
        return (listener, try #require(await iterator.next()))
    }

    @Test func detectsPlainHTTPServer() async throws {
        let (listener, port) = try await server(replying: "HTTP/1.0 200 OK\r\nContent-Length: 0\r\n\r\n")
        defer { listener.cancel() }
        #expect(await WebProbe.detect(NetScanner.IPv4Address("127.0.0.1")!, port: port, timeout: 1) == .http)
    }

    @Test func ignoresNonHTTPService() async throws {
        let (listener, port) = try await server(replying: "SSH-2.0-OpenSSH_9.6\r\n")
        defer { listener.cancel() }
        #expect(await WebProbe.detect(NetScanner.IPv4Address("127.0.0.1")!, port: port, timeout: 1) == nil)
    }
}
