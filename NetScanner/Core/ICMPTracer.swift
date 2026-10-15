import Foundation

/// What one traceroute probe got back.
enum TraceProbeResult: Sendable, Equatable {
    /// A router (Time Exceeded) or the destination (Echo Reply / Unreachable) answered.
    case answer(from: IPv4Address, rtt: Double, kind: Kind)
    case timeout
    case sendError(Int32)

    enum Kind: Sendable, Equatable {
        case timeExceeded
        case echoReply
        case unreachable(code: UInt8)
    }
}

extension ICMPPacket {
    static let timeExceededType: UInt8 = 11
    static let destinationUnreachableType: UInt8 = 3

    /// For Time Exceeded / Destination Unreachable: the type and code, plus the identifier and
    /// sequence of our echo request quoted inside (IP header + first 8 bytes of the original).
    static func parseError(_ bytes: [UInt8]) -> (type: UInt8, code: UInt8, identifier: UInt16, sequence: UInt16)? {
        var offset = 0
        if let first = bytes.first, first >> 4 == 4 {
            offset = Int(first & 0x0F) * 4
        }
        guard bytes.count >= offset + 8 else { return nil }
        let type = bytes[offset]
        guard type == timeExceededType || type == destinationUnreachableType else { return nil }
        let inner = offset + 8
        guard bytes.count > inner, bytes[inner] >> 4 == 4 else { return nil }
        let innerICMP = inner + Int(bytes[inner] & 0x0F) * 4
        guard bytes.count >= innerICMP + 8, bytes[innerICMP] == echoRequestType else { return nil }
        return (type, bytes[offset + 1],
                UInt16(bytes[innerICMP + 4]) << 8 | UInt16(bytes[innerICMP + 5]),
                UInt16(bytes[innerICMP + 6]) << 8 | UInt16(bytes[innerICMP + 7]))
    }
}

/// Echo requests with a chosen TTL over the unprivileged ICMP socket. Routers answer with Time
/// Exceeded quoting our request, so replies are matched by the identifier and sequence inside.
/// Like `ICMPPinger`, all mutable state lives on `queue`.
final class ICMPTracer: @unchecked Sendable {
    private struct Pending {
        let sentAt: ContinuousClock.Instant
        let continuation: CheckedContinuation<TraceProbeResult, Never>
    }

    private let fd: Int32
    private let identifier = UInt16.random(in: .min ... .max)
    private let queue = DispatchQueue(label: "NetScanner.ICMPTracer")
    private let readSource: DispatchSourceRead
    private var pending: [UInt16: Pending] = [:]
    private var nextSequence: UInt16 = 0

    init() throws {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { throw PingSocketError(code: errno) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
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

    func probe(_ address: IPv4Address, ttl: Int, timeout: TimeInterval) async -> TraceProbeResult {
        await withCheckedContinuation { continuation in
            queue.async { self.send(to: address, ttl: ttl, timeout: timeout, continuation: continuation) }
        }
    }

    private func send(to address: IPv4Address, ttl: Int, timeout: TimeInterval,
                      continuation: CheckedContinuation<TraceProbeResult, Never>) {
        let sequence = nextSequence
        nextSequence &+= 1
        pending.removeValue(forKey: sequence)?.continuation.resume(returning: .timeout)

        // TTL is applied at send time, and sends are serialized on this queue.
        var hops = Int32(ttl)
        _ = setsockopt(fd, IPPROTO_IP, IP_TTL, &hops, socklen_t(MemoryLayout<Int32>.size))
        let packet = ICMPPacket.echoRequest(identifier: identifier, sequence: sequence)
        let sentAt = ContinuousClock.now
        let result = address.withSockaddr { sa, length in
            packet.withUnsafeBytes { sendto(fd, $0.baseAddress, $0.count, 0, sa, length) }
        }
        guard result >= 0 else {
            continuation.resume(returning: .sendError(errno))
            return
        }
        pending[sequence] = Pending(sentAt: sentAt, continuation: continuation)
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
            let bytes = Array(buffer[..<count])
            let sender = IPv4Address(from.sin_addr)

            let match: (UInt16, TraceProbeResult.Kind)?
            if let header = ICMPPacket.parse(bytes), header.type == ICMPPacket.echoReplyType, header.identifier == identifier {
                match = (header.sequence, .echoReply)
            } else if let error = ICMPPacket.parseError(bytes), error.identifier == identifier {
                match = (error.sequence, error.type == ICMPPacket.timeExceededType ? .timeExceeded : .unreachable(code: error.code))
            } else {
                match = nil
            }
            guard let (sequence, kind) = match, let entry = pending.removeValue(forKey: sequence) else { continue }
            entry.continuation.resume(returning: .answer(from: sender, rtt: (receivedAt - entry.sentAt).milliseconds, kind: kind))
        }
    }
}
