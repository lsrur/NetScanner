import Foundation
import dnssd

struct DNSRecord: Hashable, Sendable {
    let type: String
    let value: String
    let ttl: UInt32
}

/// DNS queries through the system resolver (dnssd), so they use the same DNS servers as macOS.
enum DNSLookup {
    enum RecordType: String, CaseIterable, Identifiable, Sendable {
        case all = "All"
        case a = "A"
        case aaaa = "AAAA"
        case cname = "CNAME"
        case mx = "MX"
        case ns = "NS"
        case txt = "TXT"
        case soa = "SOA"
        case srv = "SRV"
        case ptr = "PTR"

        var id: Self { self }

        var code: UInt16 {
            switch self {
            case .all: 255
            case .a: 1
            case .ns: 2
            case .cname: 5
            case .soa: 6
            case .ptr: 12
            case .mx: 15
            case .txt: 16
            case .aaaa: 28
            case .srv: 33
            }
        }

        /// What "All" queries for a name.
        static let common: [RecordType] = [.a, .aaaa, .cname, .mx, .ns, .txt, .soa]
    }

    /// Runs the query (or the common set for `.all`); an IPv4 address is looked up as PTR.
    static func lookup(_ input: String, type: RecordType) async -> [DNSRecord] {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        if let address = IPv4Address(trimmed) {
            return await query(MulticastDNS.reverseName(for: address), type: .ptr)
        }
        let types = type == .all ? RecordType.common : [type]
        return await withTaskGroup(of: [DNSRecord].self) { group in
            for type in types {
                group.addTask { await query(trimmed, type: type) }
            }
            var records: [DNSRecord] = []
            for await batch in group { records += batch }
            let order = RecordType.allCases.map(\.rawValue)
            return Array(Set(records)).sorted {
                ((order.firstIndex(of: $0.type) ?? 99), $0.value) < ((order.firstIndex(of: $1.type) ?? 99), $1.value)
            }
        }
    }

    static func query(_ name: String, type: RecordType, timeout: TimeInterval = 3) async -> [DNSRecord] {
        await withCheckedContinuation { continuation in
            QuerySession(continuation: continuation).start(name: name, type: type.code, timeout: timeout)
        }
    }

    // MARK: RDATA decoding

    static func decode(type: UInt16, rdata: [UInt8]) -> (String, String) {
        let name = RecordType.allCases.first { $0.code == type && $0 != .all }?.rawValue ?? "TYPE\(type)"
        let value: String? = switch type {
        case 1 where rdata.count == 4:
            rdata.map(String.init).joined(separator: ".")
        case 28 where rdata.count == 16:
            IPv6Neighbors.format(rdata)
        case 2, 5, 12:
            wireName(rdata, at: 0)?.name
        case 15 where rdata.count > 2:
            wireName(rdata, at: 2).map { "\(UInt16(rdata[0]) << 8 | UInt16(rdata[1])) \($0.name)" }
        case 16:
            txtStrings(rdata).map { "\"\($0)\"" }.joined(separator: " ")
        case 6:
            soa(rdata)
        case 33 where rdata.count > 6:
            wireName(rdata, at: 6).map {
                let priority = UInt16(rdata[0]) << 8 | UInt16(rdata[1])
                let weight = UInt16(rdata[2]) << 8 | UInt16(rdata[3])
                let port = UInt16(rdata[4]) << 8 | UInt16(rdata[5])
                return "\(priority) \(weight) \(port) \($0.name)"
            }
        default:
            nil
        }
        return (name, value ?? rdata.map { String(format: "%02x", $0) }.joined())
    }

    /// An uncompressed wire-format name starting at `index`, and the index after it.
    static func wireName(_ bytes: [UInt8], at index: Int) -> (name: String, end: Int)? {
        var labels: [String] = []
        var position = index
        while position < bytes.count {
            let length = Int(bytes[position])
            if length == 0 {
                return (labels.isEmpty ? "." : labels.joined(separator: ".") + ".", position + 1)
            }
            guard length < 64, position + 1 + length <= bytes.count else { return nil }
            labels.append(String(decoding: bytes[(position + 1)..<(position + 1 + length)], as: UTF8.self))
            position += 1 + length
        }
        return nil
    }

    static func txtStrings(_ bytes: [UInt8]) -> [String] {
        var strings: [String] = []
        var index = 0
        while index < bytes.count {
            let length = Int(bytes[index])
            guard index + 1 + length <= bytes.count else { break }
            strings.append(String(decoding: bytes[(index + 1)..<(index + 1 + length)], as: UTF8.self))
            index += 1 + length
        }
        return strings
    }

    private static func soa(_ bytes: [UInt8]) -> String? {
        guard let primary = wireName(bytes, at: 0), let mailbox = wireName(bytes, at: primary.end),
              mailbox.end + 20 <= bytes.count else { return nil }
        let numbers = (0..<5).map { field in
            bytes[(mailbox.end + field * 4)..<(mailbox.end + field * 4 + 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        }
        return "\(primary.name) \(mailbox.name) serial \(numbers[0]) refresh \(numbers[1]) retry \(numbers[2]) expire \(numbers[3]) minimum \(numbers[4])"
    }
}

/// One DNSServiceQueryRecord; finishes when the answer set is complete, on a negative answer
/// or at the timeout. State lives on `queue`; the session retains itself until it finishes.
private final class QuerySession: @unchecked Sendable {
    private let queue = DispatchQueue(label: "NetScanner.DNSLookup")
    private var ref: DNSServiceRef?
    private var records: [DNSRecord] = []
    private var continuation: CheckedContinuation<[DNSRecord], Never>?

    init(continuation: CheckedContinuation<[DNSRecord], Never>) {
        self.continuation = continuation
    }

    func start(name: String, type: UInt16, timeout: TimeInterval) {
        queue.async { [self] in
            let context = Unmanaged.passRetained(self).toOpaque()
            var ref: DNSServiceRef?
            // ReturnIntermediates also delivers CNAMEs and fast negative answers.
            let error = DNSServiceQueryRecord(
                &ref, DNSServiceFlags(kDNSServiceFlagsReturnIntermediates), 0, name, type, UInt16(kDNSServiceClass_IN),
                { _, flags, _, error, _, rrtype, _, length, rdata, ttl, context in
                    guard let context else { return }
                    let session = Unmanaged<QuerySession>.fromOpaque(context).takeUnretainedValue()
                    guard error == kDNSServiceErr_NoError else {
                        session.finish()
                        return
                    }
                    if flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0, let rdata {
                        let bytes = Array(UnsafeBufferPointer(start: rdata.assumingMemoryBound(to: UInt8.self), count: Int(length)))
                        let (typeName, value) = DNSLookup.decode(type: rrtype, rdata: bytes)
                        session.records.append(DNSRecord(type: typeName, value: value, ttl: ttl))
                    }
                    if flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) == 0, !session.records.isEmpty {
                        session.finish()
                    }
                },
                context)
            guard error == kDNSServiceErr_NoError, let ref else {
                finish()
                return
            }
            self.ref = ref
            DNSServiceSetDispatchQueue(ref, queue)
            queue.asyncAfter(deadline: .now() + timeout) { self.finish() }
        }
    }

    /// Runs on `queue`; only the first call has an effect.
    private func finish() {
        guard let continuation else { return }
        self.continuation = nil
        if let ref {
            DNSServiceRefDeallocate(ref)
            self.ref = nil
        }
        Unmanaged.passUnretained(self).release()
        continuation.resume(returning: records)
    }
}

/// Whois over TCP 43, starting at IANA and following referrals (registry, then registrar).
enum Whois {
    static let rootServer = "whois.iana.org"

    /// The answer of each server consulted, most specific last. IANA knows IP blocks and TLDs but
    /// not domains, so for a domain it is asked about the TLD and the referral gets the full name.
    static func lookup(_ query: String, timeout: TimeInterval = 8) async -> [(server: String, text: String)] {
        let query = query.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        let isAddress = IPv4Address(query) != nil || query.contains(":")
        var answers: [(String, String)] = []
        var server = rootServer
        var question = isAddress ? query : String(query.split(separator: ".").last ?? Substring(query))
        var visited = Set<String>()
        for _ in 0..<3 {
            guard visited.insert(server).inserted,
                  let data = await TCPExchange.request(server, port: 43, request: Data((question + "\r\n").utf8), timeout: timeout)
            else { break }
            let text = String(decoding: data, as: UTF8.self)
            answers.append((server, text))
            guard let next = referral(in: text), !visited.contains(next) else { break }
            server = next
            question = query
        }
        return answers
    }

    /// "refer:" (IANA), "whois:", "Registrar WHOIS Server:" or "ReferralServer: whois://…" (ARIN).
    static func referral(in text: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard ["refer", "whois", "registrar whois server", "referralserver"].contains(key) else { continue }
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let scheme = value.range(of: "://") { value = String(value[scheme.upperBound...]) }
            value = value.split(separator: ":").first.map(String.init) ?? value
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            if !value.isEmpty, value.contains(".") { return value.lowercased() }
        }
        return nil
    }

    /// Addresses whois knows nothing useful about: private, CGNAT, loopback, link-local.
    static func isPrivate(_ address: IPv4Address) -> Bool {
        let ranges = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16"]
        return ranges.compactMap(IPv4Subnet.init(cidr:)).contains { $0.contains(address) }
    }
}
