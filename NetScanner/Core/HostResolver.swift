import Foundation

struct ResolveError: LocalizedError {
    let host: String
    let message: String
    var errorDescription: String? { "Couldn't resolve \(host): \(message)" }
}

/// Blocking resolver calls are moved off the caller's thread.
enum HostResolver {
    static func resolveIPv4(_ host: String) async throws -> IPv4Address {
        if let address = IPv4Address(host) { return address }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_family = AF_INET
                hints.ai_socktype = SOCK_STREAM
                var info: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(host, nil, &hints, &info)
                guard status == 0, let first = info, let sa = first.pointee.ai_addr else {
                    continuation.resume(throwing: ResolveError(host: host, message: String(cString: gai_strerror(status))))
                    return
                }
                defer { freeaddrinfo(info) }
                let address = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { IPv4Address($0.pointee.sin_addr) }
                continuation.resume(returning: address)
            }
        }
    }

    /// Reverse DNS; mDNSResponder also answers `.local` names for LAN devices.
    static func reverseLookup(_ address: IPv4Address) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let capacity = socklen_t(name.count)
                let status = address.withSockaddr { sa, length in
                    getnameinfo(sa, length, &name, capacity, nil, 0, NI_NAMEREQD)
                }
                guard status == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let host = name.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                continuation.resume(returning: host.hasSuffix(".") ? String(host.dropLast()) : host)
            }
        }
    }
}
