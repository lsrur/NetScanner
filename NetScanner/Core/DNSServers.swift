import Foundation
import SystemConfiguration

/// The resolvers macOS is using right now (IPv4 and IPv6), from the dynamic store.
enum DNSServers {
    static func current() -> [String] {
        guard let store = SCDynamicStoreCreate(nil, "NetScanner" as CFString, nil, nil),
              let settings = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any],
              let servers = settings["ServerAddresses"] as? [String] else { return [] }
        // Link-local IPv6 resolvers come with a "%en0" scope suffix.
        return servers.map { $0.split(separator: "%").first.map(String.init) ?? $0 }
    }
}
