import SwiftUI

struct StatusBar: View {
    let model: PublicNetworkModel
    let scanner: ScannerModel

    var body: some View {
        HStack(spacing: 18) {
            if scanner.isScanningAny {
                scanProgress
            } else if model.isOffline {
                Label("No Internet connection", systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
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

    /// Only shown while scanning or offline; ISP and public addresses live in
    /// Tools → Internet Connection.
    static func isVisible(model: PublicNetworkModel, scanner: ScannerModel) -> Bool {
        scanner.isScanningAny || model.isOffline
    }
}
