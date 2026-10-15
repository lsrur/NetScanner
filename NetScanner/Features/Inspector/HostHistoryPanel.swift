import SwiftUI

/// The inspector's History tab: every IPv4 address the device has used, most recent first.
struct HostHistoryPanel: View {
    let host: DiscoveredHost

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: identity)
                .font(.caption)
                .foregroundStyle(.secondary)
            if host.addressHistory.isEmpty {
                ContentUnavailableView("No History Yet", systemImage: "clock",
                                       description: Text("Addresses are recorded once the scan has read the MAC addresses."))
                    .frame(maxHeight: .infinity)
            } else {
                List(host.addressHistory, id: \.address) { sighting in
                    row(sighting)
                }
                .listStyle(.bordered)
            }
        }
    }

    /// What the history follows: the MAC, or the address itself when there's no MAC.
    private var identity: String {
        if let mac = host.mac {
            return "Addresses seen for MAC \(mac)"
        }
        return "No MAC address: tracked by IP, so the history can't follow address changes."
    }

    private func row(_ sighting: AddressSighting) -> some View {
        let isCurrent = sighting.address == host.address.description
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(verbatim: sighting.address)
                    .font(.body.monospaced())
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .textSelection(.enabled)
                if isCurrent {
                    Text("Current")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.tint.opacity(0.18), in: .capsule)
                }
                if sighting.address == host.previousAddress?.description {
                    Text("Previous")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.orange.opacity(0.15), in: .capsule)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 1) {
                GridRow {
                    Text("First seen").foregroundStyle(.secondary)
                    Text(sighting.firstSeen.formatted(date: .abbreviated, time: .shortened))
                }
                GridRow {
                    Text("Last seen").foregroundStyle(.secondary)
                    Text(sighting.lastSeen.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 2)
    }
}
