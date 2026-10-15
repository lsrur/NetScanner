/// The host table's search: every whitespace-separated term must appear (case-insensitively)
/// in some field of the host.
enum HostFilter {
    static func matches(_ host: DiscoveredHost, query: String) -> Bool {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return true }
        let haystack = searchableText(host)
        return terms.allSatisfy { haystack.contains($0) }
    }

    static func searchableText(_ host: DiscoveredHost) -> String {
        let fields: [String?] = [
            host.address.description, host.macText, host.vendor, host.model, host.kindText,
            host.customName, host.computerName, host.advertisedName, host.bonjourName, host.netbiosName, host.dnsName,
            host.upnp?.friendlyName, host.upnp?.manufacturer, host.webTitle, host.comment, host.interface,
            host.isGateway ? "gateway" : nil,
        ]
        let lists = host.ipv6LinkLocal + host.ipv6Global + host.services.map(\.displayType)
        return (fields.compactMap { $0 } + lists).joined(separator: "\n").lowercased()
    }
}
