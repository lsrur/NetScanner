import Foundation
import dnssd

/// Reverse lookups over multicast DNS. Phones, printers and Macs often have no PTR record on the
/// router's DNS but answer `x.x.x.x.in-addr.arpa` PTR queries for themselves via Bonjour.
enum MulticastDNS {
    static func reverseLookup(_ address: IPv4Address, timeout: TimeInterval = 2) async -> String? {
        await withCheckedContinuation { continuation in
            Query(continuation: continuation).start(name: reverseName(for: address), timeout: timeout)
        }
    }

    static func reverseName(for address: IPv4Address) -> String {
        address.description.split(separator: ".").reversed().joined(separator: ".") + ".in-addr.arpa."
    }

    /// Decodes an uncompressed DNS name in wire format (length-prefixed labels), dropping `.local`.
    static func decodeName(_ bytes: [UInt8]) -> String? {
        var labels: [String] = []
        var index = 0
        while index < bytes.count, bytes[index] != 0 {
            let length = Int(bytes[index])
            guard length < 64, index + 1 + length <= bytes.count else { return nil }
            labels.append(String(decoding: bytes[(index + 1)..<(index + 1 + length)], as: UTF8.self))
            index += 1 + length
        }
        if labels.last?.lowercased() == "local" {
            labels.removeLast()
        }
        return labels.isEmpty ? nil : labels.joined(separator: ".")
    }

    /// One DNSServiceQueryRecord call; all state lives on `queue`. The query retains itself
    /// (via the callback context) until it finishes.
    private final class Query: @unchecked Sendable {
        private let queue = DispatchQueue(label: "NetScanner.MulticastDNS")
        private var ref: DNSServiceRef?
        private var continuation: CheckedContinuation<String?, Never>?

        init(continuation: CheckedContinuation<String?, Never>) {
            self.continuation = continuation
        }

        func start(name: String, timeout: TimeInterval) {
            queue.async { [self] in
                let context = Unmanaged.passRetained(self).toOpaque()
                var ref: DNSServiceRef?
                let error = DNSServiceQueryRecord(
                    &ref, DNSServiceFlags(kDNSServiceFlagsForceMulticast), 0, name,
                    UInt16(kDNSServiceType_PTR), UInt16(kDNSServiceClass_IN),
                    { _, flags, _, error, _, _, _, length, data, _, context in
                        guard let context else { return }
                        let query = Unmanaged<Query>.fromOpaque(context).takeUnretainedValue()
                        guard error == kDNSServiceErr_NoError,
                              flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0,
                              let data else { return }
                        let bytes = Array(UnsafeRawBufferPointer(start: data, count: Int(length)))
                        query.finish(MulticastDNS.decodeName(bytes))
                    },
                    context)
                guard error == kDNSServiceErr_NoError, let ref else {
                    finish(nil)
                    return
                }
                self.ref = ref
                DNSServiceSetDispatchQueue(ref, queue)
                queue.asyncAfter(deadline: .now() + timeout) { self.finish(nil) }
            }
        }

        /// Runs on `queue`; only the first call has an effect.
        private func finish(_ name: String?) {
            guard let continuation else { return }
            self.continuation = nil
            if let ref {
                DNSServiceRefDeallocate(ref)
                self.ref = nil
            }
            Unmanaged.passUnretained(self).release()
            continuation.resume(returning: name)
        }
    }
}
