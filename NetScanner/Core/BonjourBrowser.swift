import Foundation
import dnssd

/// One advertised Bonjour service instance, resolved to its IPv4 addresses.
struct BonjourService: Hashable, Sendable {
    /// Service type, e.g. "_airplay._tcp".
    let type: String
    /// Instance name, e.g. "Living Room".
    let name: String
    var host: String?
    var port: UInt16 = 0
    var txt: [String: String] = [:]
    var addresses: Set<IPv4Address> = []

    var displayType: String { BonjourBrowser.displayName(forType: type) }
}

/// Browses the local network for Bonjour services. The `_services._dns-sd._udp` meta-query
/// finds whatever types are being advertised; the known types are browsed directly as well.
enum BonjourBrowser {
    /// Human names for service types; also the explicit browse list (declared in NSBonjourServices).
    static let knownTypes: [String: String] = [
        "_airplay._tcp": "AirPlay",
        "_raop._tcp": "AirPlay Audio",
        "_googlecast._tcp": "Google Cast",
        "_ipp._tcp": "IPP Printing",
        "_ipps._tcp": "IPP Printing (TLS)",
        "_printer._tcp": "LPD Printing",
        "_pdl-datastream._tcp": "RAW Printing",
        "_uscan._tcp": "Scanner",
        "_scanner._tcp": "Scanner",
        "_smb._tcp": "SMB File Sharing",
        "_afpovertcp._tcp": "AFP File Sharing",
        "_adisk._tcp": "Time Machine",
        "_ssh._tcp": "SSH",
        "_sftp-ssh._tcp": "SFTP",
        "_rfb._tcp": "Screen Sharing",
        "_hap._tcp": "HomeKit",
        "_homekit._tcp": "HomeKit",
        "_companion-link._tcp": "Apple Companion Link",
        "_device-info._tcp": "Device Info",
        "_sonos._tcp": "Sonos",
        "_spotify-connect._tcp": "Spotify Connect",
        "_home-assistant._tcp": "Home Assistant",
        "_esphomelib._tcp": "ESPHome",
        "_mqtt._tcp": "MQTT",
        "_matter._tcp": "Matter",
        "_hue._tcp": "Philips Hue",
        "_shelly._tcp": "Shelly",
        "_http._tcp": "Web (HTTP)",
        "_https._tcp": "Web (HTTPS)",
        "_workstation._tcp": "Workstation",
        "_androidtvremote2._tcp": "Android TV Remote",
        "_amzn-wplay._tcp": "Amazon Fire TV",
        "_daap._tcp": "Music Sharing",
        "_airport._tcp": "AirPort",
        "_meshcop._udp": "Thread Border Router",
    ]

    static let metaQueryType = "_services._dns-sd._udp"

    static func displayName(forType type: String) -> String {
        knownTypes[type] ?? type
    }

    static func discover(timeout: TimeInterval = 3) async -> [BonjourService] {
        await withCheckedContinuation { continuation in
            BrowseSession(continuation: continuation).start(types: knownTypes.keys.sorted(), timeout: timeout)
        }
    }

    /// DNS-SD TXT record: length-prefixed "key=value" strings.
    static func parseTXT(_ bytes: [UInt8]) -> [String: String] {
        var result: [String: String] = [:]
        var index = 0
        while index < bytes.count {
            let length = Int(bytes[index])
            index += 1
            guard length > 0, index + length <= bytes.count else {
                index += length
                continue
            }
            let entry = String(decoding: bytes[index..<(index + length)], as: UTF8.self)
            index += length
            let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = parts.first, !key.isEmpty else { continue }
            let lowered = key.lowercased()
            if result[lowered] == nil {
                result[lowered] = parts.count == 2 ? String(parts[1]) : ""
            }
        }
        return result
    }
}

/// Browse → resolve → address lookup chain over dnssd. All state lives on `queue`, where every
/// callback is delivered; the session keeps itself alive until `finish`.
private final class BrowseSession: @unchecked Sendable {
    final class Context {
        unowned(unsafe) let session: BrowseSession
        let key: String

        init(session: BrowseSession, key: String) {
            self.session = session
            self.key = key
        }

        static func from(_ pointer: UnsafeMutableRawPointer) -> Context {
            Unmanaged<Context>.fromOpaque(pointer).takeUnretainedValue()
        }
    }

    private let queue = DispatchQueue(label: "NetScanner.Bonjour")
    private var refs: [DNSServiceRef] = []
    private var contexts: [Context] = []
    private var browsedTypes = Set<String>()
    private var lookedUp = Set<String>()
    private var services: [String: BonjourService] = [:]
    private var continuation: CheckedContinuation<[BonjourService], Never>?

    init(continuation: CheckedContinuation<[BonjourService], Never>) {
        self.continuation = continuation
    }

    func start(types: [String], timeout: TimeInterval) {
        queue.async { [self] in
            browse(BonjourBrowser.metaQueryType)
            types.forEach(browse)
            queue.asyncAfter(deadline: .now() + timeout) { self.finish() }
        }
    }

    private func context(_ key: String) -> UnsafeMutableRawPointer {
        let context = Context(session: self, key: key)
        contexts.append(context)
        return Unmanaged.passUnretained(context).toOpaque()
    }

    private func keep(_ ref: DNSServiceRef?, _ error: DNSServiceErrorType) {
        guard error == kDNSServiceErr_NoError, let ref else { return }
        DNSServiceSetDispatchQueue(ref, queue)
        refs.append(ref)
    }

    private func browse(_ type: String) {
        guard continuation != nil, browsedTypes.insert(type).inserted else { return }
        var ref: DNSServiceRef?
        let error = DNSServiceBrowse(&ref, 0, 0, type, "local.", { _, flags, interfaceIndex, error, name, regtype, domain, context in
            guard error == kDNSServiceErr_NoError, flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0,
                  let context, let name, let regtype, let domain else { return }
            Context.from(context).session.found(name: String(cString: name), regtype: String(cString: regtype),
                                                domain: String(cString: domain), interfaceIndex: interfaceIndex)
        }, context(type))
        keep(ref, error)
    }

    private func found(name: String, regtype: String, domain: String, interfaceIndex: UInt32) {
        // Meta-query answers name a type: "_airplay" in "_tcp.local.".
        if regtype.hasPrefix("_tcp.") || regtype.hasPrefix("_udp.") {
            browse("\(name).\(regtype.prefix(4))")
            return
        }
        let type = regtype.split(separator: ".").prefix(2).joined(separator: ".")
        let key = "\(name).\(type)"
        guard services[key] == nil else { return }
        services[key] = BonjourService(type: type, name: name)
        var ref: DNSServiceRef?
        let error = DNSServiceResolve(&ref, 0, interfaceIndex, name, regtype, domain, { _, _, interfaceIndex, error, _, host, port, txtLength, txt, context in
            guard error == kDNSServiceErr_NoError, let context, let host else { return }
            let bytes = txt.map { Array(UnsafeBufferPointer(start: $0, count: Int(txtLength))) } ?? []
            let ctx = Context.from(context)
            ctx.session.resolved(key: ctx.key, host: String(cString: host), port: UInt16(bigEndian: port),
                                 txt: bytes, interfaceIndex: interfaceIndex)
        }, context(key))
        keep(ref, error)
    }

    private func resolved(key: String, host: String, port: UInt16, txt: [UInt8], interfaceIndex: UInt32) {
        guard continuation != nil else { return }
        services[key]?.host = host
        services[key]?.port = port
        services[key]?.txt = BonjourBrowser.parseTXT(txt)
        guard lookedUp.insert(key).inserted else { return }
        var ref: DNSServiceRef?
        let error = DNSServiceGetAddrInfo(&ref, 0, interfaceIndex, DNSServiceProtocol(kDNSServiceProtocol_IPv4), host, { _, flags, _, error, _, address, _, context in
            guard error == kDNSServiceErr_NoError, flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0,
                  let context, let address, address.pointee.sa_family == sa_family_t(AF_INET) else { return }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { IPv4Address($0.pointee.sin_addr) }
            let ctx = Context.from(context)
            ctx.session.services[ctx.key]?.addresses.insert(ip)
        }, context(key))
        keep(ref, error)
    }

    private func finish() {
        guard let continuation else { return }
        self.continuation = nil
        refs.forEach(DNSServiceRefDeallocate)
        refs = []
        continuation.resume(returning: services.values.filter { !$0.addresses.isEmpty })
    }
}
