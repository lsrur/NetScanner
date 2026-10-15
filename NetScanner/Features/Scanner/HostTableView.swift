import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct HostTableView: View {
    @Environment(AppModel.self) private var app
    let scanner: ScannerModel
    @Binding var selection: HostID?
    @State private var sortOrder = Self.initialSortOrder
    /// Visibility, order and widths of the columns; changed from the header's context menu.
    @State private var columns = Persisted.load(TableColumnCustomization<DiscoveredHost>.self,
                                                forKey: Self.columnsKey, from: .standard) ?? TableColumnCustomization()
    @State private var notice: String?
    private static let columnsKey = "hostTableColumns"

    private static var initialSortOrder: [KeyPathComparator<DiscoveredHost>] {
        #if DEBUG
        // NETSCANNER_SORT=firstSeen: newest devices first, for screenshots.
        if ProcessInfo.processInfo.environment["NETSCANNER_SORT"] == "firstSeen" {
            return [KeyPathComparator(\DiscoveredHost.firstSeenSortKey, order: .reverse)]
        }
        #endif
        return [KeyPathComparator(\DiscoveredHost.address)]
    }

    var body: some View {
        VStack(spacing: 0) {
            if !scanner.targetsWithoutResponses.isEmpty {
                PermissionBanner()
            }
            if let notice {
                Label(notice, systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.green.opacity(0.12))
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            table
        }
        .animation(.default, value: notice)
        // Counts and ranges live in the inspector's scan summary; the toolbar only holds actions.
        .navigationTitle("NetScanner")
        .toolbar(removing: .title)
    }

    private var visibleHosts: [DiscoveredHost] {
        scanner.hosts.filter { HostFilter.matches($0, query: app.hostQuery) }.sorted(using: sortOrder)
    }

    private var columnsBinding: Binding<TableColumnCustomization<DiscoveredHost>> {
        Binding(get: { columns }, set: { newValue in
            columns = newValue
            Persisted.save(newValue, forKey: Self.columnsKey, to: .standard)
        })
    }

    private func wake(_ host: DiscoveredHost) {
        let mac = host.mac?.description ?? ""
        notice = scanner.wake(host.id)
            ? "Wake-on-LAN packet sent to \(host.hostname ?? host.address.description) (\(mac))."
            : "Couldn't send the Wake-on-LAN packet."
        let shown = notice
        Task {
            try? await Task.sleep(for: .seconds(4))
            if notice == shown { notice = nil }
        }
    }

    private var table: some View {
        // Split in two builders: a single 12-column builder is too much for the type checker.
        Table(visibleHosts, selection: $selection, sortOrder: $sortOrder, columnCustomization: columnsBinding) {
            addressColumns
            detailColumns
        }
        .contextMenu(forSelectionType: HostID.self) { ids in
            if let host = scanner.host(ids.first) {
                if host.mac != nil, host.source != .local {
                    Button("Wake on LAN", systemImage: "power") { wake(host) }
                }
                Divider()
                Button("Copy IP") { copy(host.address.description) }
                copyAddressesItem("Copy IPv6 Local", host.ipv6LinkLocal)
                copyAddressesItem("Copy IPv6 Global", host.ipv6Global)
                if let mac = host.mac {
                    Button("Copy MAC") { copy(mac.description) }
                }
                if let hostname = host.hostname {
                    Button("Copy Hostname") { copy(hostname) }
                }
            }
        } primaryAction: { _ in
            app.showInspector = true
        }
        .overlay {
            if scanner.hosts.isEmpty {
                ContentUnavailableView("No Results", systemImage: "network",
                                       description: Text("Press ▶ in the toolbar (⌘R)."))
            } else if visibleHosts.isEmpty {
                ContentUnavailableView.search(text: app.hostQuery)
            }
        }
    }

    @TableColumnBuilder<DiscoveredHost, KeyPathComparator<DiscoveredHost>>
    private var addressColumns: some TableColumnContent<DiscoveredHost, KeyPathComparator<DiscoveredHost>> {
        TableColumn("IP", value: \.address) { host in
            AddressCell(host: host)
        }
        .width(min: 110, ideal: 140)
            .customizationID("ip")
                .disabledCustomizationBehavior(.visibility)
        TableColumn("Type", value: \.kindText) { host in
            HStack(spacing: 6) {
                Label(host.kindText, systemImage: host.kind.systemImage)
                    .labelStyle(DeviceKindLabelStyle())
                if host.isGateway {
                    Text("Gateway")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.tint.opacity(0.18), in: .capsule)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cellToolTip(host.isGateway ? "\(host.kindText) (default gateway)" : host.kindText)
        }
        .width(min: 90, ideal: 160)
            .customizationID("type")
        TableColumn("IPv6 Local", value: \.ipv6LinkLocalText) { host in
            Text(verbatim: host.ipv6LinkLocalText)
                .monospaced()
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cellToolTip(host.ipv6LinkLocal.joined(separator: "\n"))
        }
        .width(min: 90, ideal: 200)
            .customizationID("ipv6Local")
        TableColumn("IPv6 Global", value: \.ipv6GlobalText) { host in
            Text(verbatim: host.ipv6GlobalText + (host.ipv6Global.count > 1 ? " (+\(host.ipv6Global.count - 1))" : ""))
                .monospaced()
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cellToolTip(host.ipv6Global.joined(separator: "\n"))
        }
        .width(min: 90, ideal: 220)
            .customizationID("ipv6Global")
        TableColumn("MAC", value: \.macText) { Text(verbatim: $0.macText).monospaced() }
            .width(min: 130, ideal: 140)
                .customizationID("mac")
    }

    @TableColumnBuilder<DiscoveredHost, KeyPathComparator<DiscoveredHost>>
    private var detailColumns: some TableColumnContent<DiscoveredHost, KeyPathComparator<DiscoveredHost>> {
        TableColumn("Vendor", value: \.vendorText)
            .width(min: 120, ideal: 200)
                .customizationID("vendor")
        TableColumn("Model", value: \.modelText) { host in
            Text(verbatim: host.modelText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cellToolTip(host.modelText)
        }
        .width(min: 80, ideal: 170)
            .customizationID("model")
        TableColumn("Hostname", value: \.hostnameText) { host in
            Text(verbatim: host.hostnameText)
                .fontWeight(host.customName == nil ? .regular : .medium)
        }
        .width(min: 120, ideal: 200)
            .customizationID("hostname")
        TableColumn("Comment", value: \.commentText) { host in
            Text(verbatim: host.commentText)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cellToolTip(host.commentText)
        }
        .width(min: 80, ideal: 160)
            .customizationID("comment")
        TableColumn("First Seen", value: \.firstSeenSortKey) { host in
            Text(host.firstSeen?.formatted(date: .numeric, time: .shortened) ?? "")
                .monospacedDigit()
                .cellToolTip(host.firstSeen?.formatted(date: .complete, time: .standard) ?? "")
        }
        .width(min: 90, ideal: 130)
            .customizationID("firstSeen")
        TableColumn("Latency", value: \.latencySortKey) { host in
            Text(host.latency.map { $0.formatted(.number.precision(.fractionLength(1))) + " ms" } ?? "—")
                .monospacedDigit()
        }
        .width(min: 70, ideal: 80)
            .customizationID("latency")
        TableColumn("Source", value: \.source.rawValue)
            .width(min: 60, ideal: 70)
                .customizationID("source")
        TableColumn("Interface", value: \.interface)
            .width(min: 60, ideal: 70)
                .customizationID("interface")
    }

    /// One address: a plain item. Several (stable + temporary globals): a submenu with each one
    /// plus all of them, one per line.
    @ViewBuilder
    private func copyAddressesItem(_ title: String, _ addresses: [String]) -> some View {
        if addresses.count == 1, let address = addresses.first {
            Button(title) { copy(address) }
        } else if addresses.count > 1 {
            Menu(title) {
                ForEach(addresses, id: \.self) { address in
                    Button(address) { copy(address) }
                }
                Divider()
                Button("All") { copy(addresses.joined(separator: "\n")) }
            }
        }
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

private struct PermissionBanner: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
            Text("No device responded. Check that NetScanner has **Local Network** access in System Settings.")
            Spacer()
            Button("Open Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
                    openURL(url)
                }
            }
        }
        .padding(10)
        .background(.orange.opacity(0.12))
    }
}

struct CSVDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText]

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.featureUnsupported)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// Fixed-width icon column so type names line up.
private struct DeviceKindLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
                .foregroundStyle(.secondary)
                .frame(width: 18)
            configuration.title
        }
    }
}

/// The IP, in orange with a ⇄ badge when the device came back at a different address.
private struct AddressCell: View {
    let host: DiscoveredHost
    /// `.increased` on a selected row: orange on the blue highlight is hard to read.
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let style = host.previousAddress == nil || prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(.orange)
        HStack(spacing: 4) {
            Text(verbatim: host.address.description)
                .monospaced()
                .foregroundStyle(style)
            if host.previousAddress != nil {
                Image(systemName: "arrow.left.arrow.right.circle.fill")
                    .foregroundStyle(style)
                    .imageScale(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cellToolTip(host.previousAddress.map { "New IP address. Previously \($0)." } ?? "")
    }
}
