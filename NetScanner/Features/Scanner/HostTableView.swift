import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct HostTableView: View {
    @Environment(AppModel.self) private var app
    let scanner: ScannerModel
    @Binding var selection: HostID?
    @State private var sortOrder = [KeyPathComparator(\DiscoveredHost.address)]

    var body: some View {
        VStack(spacing: 0) {
            if !scanner.targetsWithoutResponses.isEmpty {
                PermissionBanner()
            }
            table
        }
        // Counts and ranges live in the inspector's scan summary; the toolbar only holds actions.
        .navigationTitle("NetScanner")
        .toolbar(removing: .title)
    }

    private var table: some View {
        Table(scanner.hosts.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
            TableColumn("IP", value: \.address) { Text(verbatim: $0.address.description).monospaced() }
                .width(min: 110, ideal: 120)
            TableColumn("IPv6 Local", value: \.ipv6LinkLocalText) { host in
                Text(verbatim: host.ipv6LinkLocalText)
                    .monospaced()
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cellToolTip(host.ipv6LinkLocal.joined(separator: "\n"))
            }
            .width(min: 90, ideal: 200)
            TableColumn("IPv6 Global", value: \.ipv6GlobalText) { host in
                Text(verbatim: host.ipv6GlobalText + (host.ipv6Global.count > 1 ? " (+\(host.ipv6Global.count - 1))" : ""))
                    .monospaced()
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cellToolTip(host.ipv6Global.joined(separator: "\n"))
            }
            .width(min: 90, ideal: 220)
            TableColumn("MAC", value: \.macText) { Text(verbatim: $0.macText).monospaced() }
                .width(min: 130, ideal: 140)
            TableColumn("Vendor", value: \.vendorText)
                .width(min: 120, ideal: 200)
            TableColumn("Hostname", value: \.hostnameText) { host in
                Text(verbatim: host.hostnameText)
                    .fontWeight(host.customName == nil ? .regular : .medium)
            }
            TableColumn("Comment", value: \.commentText) { host in
                Text(verbatim: host.commentText)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cellToolTip(host.commentText)
            }
            .width(min: 80, ideal: 160)
                .width(min: 120, ideal: 200)
            TableColumn("Latency", value: \.latencySortKey) { host in
                Text(host.latency.map { $0.formatted(.number.precision(.fractionLength(1))) + " ms" } ?? "—")
                    .monospacedDigit()
            }
            .width(min: 70, ideal: 80)
            TableColumn("Source", value: \.source.rawValue)
                .width(min: 60, ideal: 70)
            TableColumn("Interface", value: \.interface)
                .width(min: 60, ideal: 70)
        }
        .contextMenu(forSelectionType: HostID.self) { ids in
            if let host = scanner.host(ids.first) {
                Button("Edit Name and Comment…", systemImage: "pencil") {
                    selection = host.id
                    app.showInspector = true
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
            }
        }
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
