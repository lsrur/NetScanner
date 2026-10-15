import Foundation

enum ICMPPacket {
    static let echoRequestType: UInt8 = 8
    static let echoReplyType: UInt8 = 0
    static let defaultPayload: [UInt8] = (0..<56).map { UInt8($0) }

    struct Header: Equatable {
        let type: UInt8
        let code: UInt8
        let identifier: UInt16
        let sequence: UInt16
    }

    /// RFC 1071 Internet checksum.
    static func checksum(_ bytes: some Collection<UInt8>) -> UInt16 {
        let bytes = Array(bytes)
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < bytes.count {
            sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            index += 2
        }
        if index < bytes.count {
            sum += UInt32(bytes[index]) << 8
        }
        while sum >> 16 != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        return ~UInt16(sum)
    }

    static func echoRequest(identifier: UInt16, sequence: UInt16, payload: [UInt8] = defaultPayload) -> [UInt8] {
        var packet: [UInt8] = [
            echoRequestType, 0, 0, 0,
            UInt8(identifier >> 8), UInt8(identifier & 0xFF),
            UInt8(sequence >> 8), UInt8(sequence & 0xFF),
        ] + payload
        let sum = checksum(packet)
        packet[2] = UInt8(sum >> 8)
        packet[3] = UInt8(sum & 0xFF)
        return packet
    }

    /// Parses an ICMP message, skipping the IPv4 header that macOS prepends on datagram ICMP sockets.
    /// Returns nil for truncated messages or a bad checksum.
    static func parse(_ bytes: [UInt8]) -> Header? {
        var offset = 0
        if let first = bytes.first, first >> 4 == 4 {
            offset = Int(first & 0x0F) * 4
        }
        guard bytes.count >= offset + 8 else { return nil }
        let message = bytes[offset...]
        guard checksum(message) == 0 else { return nil }
        return Header(
            type: bytes[offset],
            code: bytes[offset + 1],
            identifier: UInt16(bytes[offset + 4]) << 8 | UInt16(bytes[offset + 5]),
            sequence: UInt16(bytes[offset + 6]) << 8 | UInt16(bytes[offset + 7])
        )
    }
}

enum PingOutcome: Sendable, Equatable {
    /// Round-trip time in milliseconds.
    case reply(Double)
    case timeout
    /// `sendto` failed, e.g. EHOSTUNREACH when Local Network access is denied.
    case sendError(Int32)
}

struct PingSocketError: LocalizedError {
    let code: Int32
    var errorDescription: String? { "Couldn't open the ICMP socket: \(String(cString: strerror(code)))" }
}

/// Sends ICMP echo requests over an unprivileged datagram socket (no root needed on macOS)
/// and matches replies by sequence number and source address. Mutable state is confined to `queue`.
final class ICMPPinger: @unchecked Sendable {
    private struct Pending {
        let address: IPv4Address
        let sentAt: ContinuousClock.Instant
        let continuation: CheckedContinuation<PingOutcome, Never>
    }

    private let fd: Int32
    private let identifier = UInt16.random(in: .min ... .max)
    private let queue = DispatchQueue(label: "NetScanner.ICMPPinger")
    private let readSource: DispatchSourceRead
    private var pending: [UInt16: Pending] = [:]
    private var nextSequence: UInt16 = 0

    init() throws {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { throw PingSocketError(code: errno) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        // The default ICMP receive buffer (~8 KB) drops replies when many pings are in flight.
        var receiveBuffer: Int32 = 1 << 20
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout<Int32>.size))
        self.fd = fd
        readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        readSource.setEventHandler { [weak self] in self?.drainSocket() }
        readSource.setCancelHandler { close(fd) }
        readSource.resume()
    }

    deinit {
        readSource.cancel()
    }

    func ping(_ address: IPv4Address, timeout: TimeInterval) async -> PingOutcome {
        await withCheckedContinuation { continuation in
            queue.async { self.send(to: address, timeout: timeout, continuation: continuation) }
        }
    }

    private func send(to address: IPv4Address, timeout: TimeInterval, continuation: CheckedContinuation<PingOutcome, Never>) {
        let sequence = nextSequence
        nextSequence &+= 1
        pending.removeValue(forKey: sequence)?.continuation.resume(returning: .timeout)

        let packet = ICMPPacket.echoRequest(identifier: identifier, sequence: sequence)
        let sentAt = ContinuousClock.now
        let result = address.withSockaddr { sa, length in
            packet.withUnsafeBytes { sendto(fd, $0.baseAddress, $0.count, 0, sa, length) }
        }
        guard result >= 0 else {
            continuation.resume(returning: .sendError(errno))
            return
        }

        pending[sequence] = Pending(address: address, sentAt: sentAt, continuation: continuation)
        // Captures self strongly so the pinger outlives every in-flight request.
        queue.asyncAfter(deadline: .now() + timeout) {
            if let entry = self.pending[sequence], entry.sentAt == sentAt {
                self.pending[sequence] = nil
                entry.continuation.resume(returning: .timeout)
            }
        }
    }

    private func drainSocket() {
        var buffer = [UInt8](repeating: 0, count: 1500)
        let capacity = buffer.count
        while true {
            var from = sockaddr_in()
            var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = buffer.withUnsafeMutableBytes { bytes in
                withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, bytes.baseAddress, capacity, 0, $0, &fromLength)
                    }
                }
            }
            guard count > 0 else { return }
            let receivedAt = ContinuousClock.now

            guard let header = ICMPPacket.parse(Array(buffer[..<count])),
                  header.type == ICMPPacket.echoReplyType,
                  header.identifier == identifier,
                  let entry = pending[header.sequence],
                  entry.address == IPv4Address(from.sin_addr) else { continue }

            pending[header.sequence] = nil
            entry.continuation.resume(returning: .reply((receivedAt - entry.sentAt).milliseconds))
        }
    }
}

extension Duration {
    var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}
