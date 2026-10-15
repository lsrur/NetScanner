import Foundation

/// Something to scan: an interface's current subnet (from the ⌄ menu or ▶) or a saved,
/// named range the user manages in "Customize…".
struct ScanTarget: Codable, Identifiable, Hashable, Sendable {
    enum Kind: Codable, Hashable, Sendable {
        /// Follows whatever subnet the interface has at scan time (Wi-Fi networks change).
        case interfaceSubnet(String)
        /// Fixed addresses in `ScanRange` syntax.
        case range(String)
    }

    var id = UUID()
    var name: String
    var kind: Kind

    static func subnet(of interface: String) -> ScanTarget {
        ScanTarget(name: "Interface \(interface)", kind: .interfaceSubnet(interface))
    }

    static func newRange() -> ScanTarget {
        ScanTarget(name: "New Range", kind: .range(""))
    }

    var rangeText: String? {
        if case .range(let text) = kind { return text }
        return nil
    }

    var interfaceName: String? {
        if case .interfaceSubnet(let name) = kind { return name }
        return nil
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    /// Nil when the target can be scanned as typed. Interface targets are always valid; a
    /// disconnected interface is just skipped.
    var validationError: String? {
        guard let text = rangeText?.trimmingCharacters(in: .whitespaces) else { return nil }
        guard !text.isEmpty else { return "Enter a range" }
        do {
            _ = try ScanRange.parse(text)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// User name and comment for a host, keyed by MAC (follows DHCP changes) or by IP without one.
struct HostAnnotation: Codable, Equatable, Sendable {
    var name: String?
    var comment: String?

    var isEmpty: Bool { name == nil && comment == nil }

    static func key(for host: DiscoveredHost) -> String {
        host.mac.map { "mac:\($0)" } ?? "ip:\(host.address)"
    }
}
