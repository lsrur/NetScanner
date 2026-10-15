import Foundation
import Network
import Observation

struct PublicNetworkInfo: Equatable, Sendable {
    var ipv4: String?
    var ipv6: String?
    var isp: String?
    /// "AS64500".
    var asn: String?
    var countryCode: String?
    var city: String?
    var region: String?

    var countryName: String? {
        countryCode.flatMap { Locale.current.localizedString(forRegionCode: $0) }
    }

    /// "AR" → 🇦🇷 via regional indicator symbols.
    var flag: String? {
        guard let code = countryCode?.uppercased(), code.count == 2,
              code.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) }) else { return nil }
        let scalars = code.unicodeScalars.compactMap { Unicode.Scalar(0x1F1E6 + $0.value - 65) }
        return String(String.UnicodeScalarView(scalars))
    }
}

/// Public address, ISP and country as seen from the Internet, via ipinfo.io (no API key needed).
/// `v6.ipinfo.io` only answers over IPv6, so it fails fast when there is no IPv6 connectivity.
enum PublicNetworkLookup {
    struct IPInfo: Decodable, Sendable {
        let ip: String
        let org: String?
        let country: String?
        let city: String?
        let region: String?
    }

    static let ipv4URL = URL(string: "https://ipinfo.io/json")!
    static let ipv6URL = URL(string: "https://v6.ipinfo.io/json")!

    static func fetch() async -> PublicNetworkInfo? {
        async let primary = get(ipv4URL)
        async let secondary = get(ipv6URL)
        return merge(await primary, await secondary)
    }

    static func merge(_ responses: IPInfo?...) -> PublicNetworkInfo? {
        let answered = responses.compactMap { $0 }
        guard let first = answered.first else { return nil }
        return PublicNetworkInfo(
            ipv4: answered.first { !$0.ip.contains(":") }?.ip,
            ipv6: answered.first { $0.ip.contains(":") }?.ip,
            isp: ispName(fromOrg: first.org),
            asn: asn(fromOrg: first.org),
            countryCode: first.country,
            city: first.city,
            region: first.region
        )
    }

    /// The AS number of ipinfo's "AS64500 Example Telecom S.A.".
    static func asn(fromOrg org: String?) -> String? {
        guard let first = org?.split(separator: " ", maxSplits: 1).first, first.hasPrefix("AS"),
              first.count > 2, first.dropFirst(2).allSatisfy(\.isNumber) else { return nil }
        return String(first)
    }

    /// ipinfo reports the ISP as "AS64500 Example Telecom S.A."; drop the AS number.
    static func ispName(fromOrg org: String?) -> String? {
        guard let org, !org.isEmpty else { return nil }
        let parts = org.split(separator: " ", maxSplits: 1)
        if parts.count == 2, parts[0].hasPrefix("AS"), parts[0].dropFirst(2).allSatisfy(\.isNumber) {
            return String(parts[1])
        }
        return org
    }

    private static func get(_ url: URL) async -> IPInfo? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(IPInfo.self, from: data)
    }
}

@MainActor
@Observable
final class PublicNetworkModel {
    private(set) var info: PublicNetworkInfo?
    private(set) var isLoading = false
    private(set) var isOffline = false
    private(set) var updatedAt: Date?
    /// Bumped on every network path change; other models observe it to refresh themselves.
    private(set) var pathChanges = 0
    private let monitor = NWPathMonitor()
    private var task: Task<Void, Never>?
    /// Set by the debug demo mode so real lookups don't overwrite fictional data.
    private var isFrozen = false

    /// Refreshes on launch and whenever the network path changes (Wi-Fi switch, VPN, cable).
    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let isConnected = path.status == .satisfied
            Task { @MainActor in self?.pathChanged(isConnected: isConnected) }
        }
        monitor.start(queue: DispatchQueue(label: "NetScanner.PathMonitor"))
    }

    func refresh() {
        guard !isFrozen else { return }
        task?.cancel()
        isLoading = true
        task = Task {
            let result = await PublicNetworkLookup.fetch()
            guard !Task.isCancelled else { return }
            info = result
            isOffline = result == nil
            isLoading = false
            updatedAt = .now
        }
    }

    private func pathChanged(isConnected: Bool) {
        guard !isFrozen else { return }
        pathChanges += 1
        if isConnected {
            refresh()
        } else {
            task?.cancel()
            info = nil
            isLoading = false
            isOffline = true
        }
    }
}

#if DEBUG
extension PublicNetworkModel {
    func loadDemo(_ info: PublicNetworkInfo) {
        task?.cancel()
        isFrozen = true
        self.info = info
        isLoading = false
        isOffline = false
        updatedAt = .now
    }
}
#endif
