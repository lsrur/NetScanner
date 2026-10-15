import SwiftUI

struct StatusBar: View {
    let model: PublicNetworkModel
    let scanner: ScannerModel

    var body: some View {
        HStack(spacing: 18) {
            if scanner.isScanningAny {
                scanProgress
            } else if let info = model.info {
                item("ISP", info.isp)
                item("Country", [info.flag, info.countryName].compactMap { $0 }.joined(separator: " "))
                item("Public IPv4", info.ipv4)
                item("Public IPv6", info.ipv6)
            } else if model.isLoading {
                ProgressView()
                    .controlSize(.mini)
                Text("Looking up public IP…")
                    .foregroundStyle(.secondary)
            } else if model.isOffline {
                Label("No Internet connection", systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if model.isLoading, model.info != nil, !scanner.isScanningAny {
                ProgressView()
                    .controlSize(.mini)
            }
            Button("Refresh", systemImage: "arrow.clockwise", action: model.refresh)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(model.isLoading)
                .help(helpText)
        }
        .font(.caption)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var scanProgress: some View {
        let running = scanner.orderedScans.filter(\.state.isScanning).map(\.state.name)
        return HStack(spacing: 8) {
            Text("Scanning \(running.joined(separator: ", "))…")
                .foregroundStyle(.secondary)
            ProgressView(value: scanner.overallProgress)
                .frame(width: 200)
            Text(scanner.overallProgress.formatted(.percent.precision(.fractionLength(0))))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text("· \(scanner.hosts.count) hosts")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func item(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(spacing: 4) {
                Text(title)
                    .foregroundStyle(.secondary)
                Text(verbatim: value)
                    .textSelection(.enabled)
            }
        }
    }

    private var helpText: String {
        let source = "Source: ipinfo.io"
        guard let updatedAt = model.updatedAt else { return source }
        return "\(source) · updated \(updatedAt.formatted(date: .omitted, time: .shortened))"
    }
}
