import SwiftUI

/// Both tool panels report the same ideal width so switching tabs doesn't resize the inspector.
let inspectorPanelWidth: CGFloat = 360

extension View {
    func inspectorPanelFrame() -> some View {
        frame(idealWidth: inspectorPanelWidth, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case info = "Info"
    case ping = "Ping"
    case trace = "Trace"
    case ports = "Ports"
    case lookup = "DNS"

    var id: Self { self }
}

struct HostInspector: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        if let host = app.selectedHost {
            VStack(alignment: .leading, spacing: 12) {
                HostHeader(host: host, scanner: app.scanner)
                Picker("Tool", selection: $app.inspectorTab) {
                    ForEach(InspectorTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                switch app.inspectorTab {
                case .info: HostDetails(host: host).inspectorPanelFrame()
                case .ping: PingPanel(session: app.ping).inspectorPanelFrame()
                case .trace: TracePanel(session: app.trace).inspectorPanelFrame()
                case .ports: PortScanPanel(model: app.ports).inspectorPanelFrame()
                case .lookup: LookupPanel(model: app.lookup).inspectorPanelFrame()
                }
            }
            .padding()
            // Pinned to the top: the header has a fixed height and the panels fill the rest,
            // so nothing moves when another host is selected.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScanSummary(scanner: app.scanner)
        }
    }
}

/// Shown when no row is selected: hosts found per interface in the last scan.
private struct ScanSummary: View {
    let scanner: ScannerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Scan Summary")
                .font(.title3.weight(.semibold))
            if scanner.scans.isEmpty {
                Text("Nothing scanned yet. Press ▶ (⌘R).")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(scanner.orderedScans, id: \.id) { scan in
                        row(scan.state)
                    }
                }
                HStack {
                    Text("Total")
                        .font(.headline)
                    Spacer()
                    Text("\(scanner.hosts.count) hosts")
                        .font(.headline.monospacedDigit())
                }
                .padding(.horizontal, 10)
            }
            if !networkRows.isEmpty {
                Text("Network")
                    .font(.title3.weight(.semibold))
                    .padding(.top, 8)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    ForEach(networkRows, id: \.title) { row in
                        GridRow(alignment: .firstTextBaseline) {
                            Text(row.title)
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.trailing)
                            Text(verbatim: row.value)
                                .textSelection(.enabled)
                        }
                    }
                }
                .font(.callout)
            }
            Spacer()
            Label("Select a row in the table to see its details, ping it or scan its ports.",
                  systemImage: "cursorarrow.click")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding()
        .inspectorPanelFrame()
    }

    /// Gateway per scanned interface (with its name when known) and the resolvers in use.
    private var networkRows: [(title: String, value: String)] {
        var rows: [(String, String)] = []
        var seen = Set<IPv4Address>()
        for scan in scanner.orderedScans {
            guard let gateway = scan.state.gateway, seen.insert(gateway).inserted else { continue }
            let name = scanner.hosts.first { $0.address == gateway && $0.interface == scan.state.interface }?.hostname
            rows.append(("Gateway (\(scan.state.interface))", name.map { "\(gateway) — \($0)" } ?? gateway.description))
        }
        if !scanner.dnsServers.isEmpty {
            rows.append(("DNS", scanner.dnsServers.joined(separator: "\n")))
        }
        return rows
    }

    private func row(_ state: ScanState) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: state.name)
                    .font(.headline)
                Text(verbatim: details(state))
                    .font(.caption)
                    .foregroundStyle(state.foundNothing ? .orange : .secondary)
            }
            Spacer()
            if state.isScanning {
                ProgressView(value: state.progress)
                    .frame(width: 60)
            }
            Text("\(state.hostCount)")
                .font(.title2.monospacedDigit().weight(.semibold))
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }

    private func details(_ state: ScanState) -> String {
        var parts = [state.interface, state.summary]
        if state.isScanning {
            parts.append("scanning…")
        } else if let completedAt = state.completedAt {
            parts.append(completedAt.formatted(date: .omitted, time: .shortened))
        } else {
            parts.append("stopped")
        }
        if state.foundNothing {
            parts.append("no responses (Local Network permission?)")
        }
        return parts.compactMap { $0 }.joined(separator: " · ")
    }
}

/// Fixed-height part of the inspector: the same three lines for every host.
private struct HostHeader: View {
    let host: DiscoveredHost
    let scanner: ScannerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: host.kind.systemImage)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 30)
                    .help(host.kindText)
                Text(verbatim: host.address.description)
                    .font(.title2.monospaced().weight(.semibold))
                    .textSelection(.enabled)
            }
            // Saved per MAC (or IP without one); edits persist as you type.
            TextField("Name", text: nameBinding, prompt: Text(verbatim: host.detectedName ?? "Name"))
                .textFieldStyle(.roundedBorder)
                .help("Your own name for this device. Leave empty to use the detected name.")
            TextField("Comment", text: commentBinding, prompt: Text("Comment"))
                .textFieldStyle(.roundedBorder)
                .help(host.comment ?? "Comment")
        }
    }

    private var nameBinding: Binding<String> {
        Binding(get: { host.customName ?? "" }, set: { scanner.setCustomName($0, for: host.id) })
    }

    private var commentBinding: Binding<String> {
        Binding(get: { host.comment ?? "" }, set: { scanner.setComment($0, for: host.id) })
    }
}

/// Everything detected about the host; its length varies, so it gets its own tab.
struct HostDetails: View {
    let host: DiscoveredHost

    var body: some View {
        ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                row("Type", host.isGateway ? "\(host.kindText) (default gateway)" : host.kindText)
                row("Model", host.model)
                row("Manufacturer", host.upnp?.maker)
                row("Computer", host.computerName)
                row("Advertised", host.advertisedName)
                row("Bonjour", host.bonjourName)
                row("NetBIOS", host.netbiosName)
                row("DNS", host.dnsName)
                row("IPv6 Local", host.ipv6LinkLocal.isEmpty ? nil : host.ipv6LinkLocal.joined(separator: "\n"))
                row("IPv6 Global", host.ipv6Global.isEmpty ? nil : host.ipv6Global.joined(separator: "\n"))
                row("MAC", host.mac?.description)
                row("Vendor", host.vendor)
                row("Latency", host.latency.map { $0.formatted(.number.precision(.fractionLength(1))) + " ms" })
                row("Source", host.source.rawValue)
                row("Interface", host.interface)
                row("UPnP", host.upnp?.friendlyName)
                row("Web Page", host.webTitle)
                row("Services", host.services.isEmpty ? nil
                    : Array(NSOrderedSet(array: host.services.map(\.displayType))).compactMap { $0 as? String }.joined(separator: "\n"))
                row("Comment", host.comment)
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func row(_ title: String, _ value: String?) -> some View {
        if let value {
            GridRow(alignment: .firstTextBaseline) {
                Text(title)
                    .foregroundStyle(.secondary)
                    .gridColumnAlignment(.trailing)
                Text(verbatim: value)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
