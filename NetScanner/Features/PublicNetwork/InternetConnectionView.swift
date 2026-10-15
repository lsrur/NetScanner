import SwiftUI

/// The Internet Connection section: who your ISP is, your public addresses, and a speed test.
struct InternetConnectionView: View {
    let publicNetwork: PublicNetworkModel
    let speedTest: SpeedTestModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            connection
            Divider()
            speed
            Spacer(minLength: 0)
        }
        .padding()
        .frame(minWidth: 460, maxWidth: .infinity, minHeight: 440, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: ISP and public addresses

    private var connection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Connection")
                    .font(.title3.weight(.semibold))
                Spacer()
                if publicNetwork.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Refresh", systemImage: "arrow.clockwise", action: publicNetwork.refresh)
                    .labelStyle(.iconOnly)
                    .disabled(publicNetwork.isLoading)
                    .help("Look up the public addresses again")
            }
            if let info = publicNetwork.info {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    row("ISP", info.isp)
                    row("ASN", info.asn)
                    row("Public IPv4", info.ipv4, monospaced: true)
                    row("Public IPv6", info.ipv6 ?? "None (no IPv6 connectivity)", monospaced: info.ipv6 != nil)
                    row("Location", location(info))
                }
            } else if publicNetwork.isOffline {
                Label("No Internet connection", systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.secondary)
            } else {
                Text("Looking up your public address…")
                    .foregroundStyle(.secondary)
            }
            Text(sourceNote)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func location(_ info: PublicNetworkInfo) -> String? {
        let place = [info.city, info.region, info.countryName].compactMap { $0 }.filter { !$0.isEmpty }
        guard !place.isEmpty else { return nil }
        return ([info.flag].compactMap { $0 } + [place.joined(separator: ", ")]).joined(separator: " ")
    }

    private var sourceNote: String {
        let source = "Source: ipinfo.io"
        guard let updatedAt = publicNetwork.updatedAt else { return source }
        return "\(source) · updated \(updatedAt.formatted(date: .omitted, time: .shortened))"
    }

    @ViewBuilder
    private func row(_ title: String, _ value: String?, monospaced: Bool = false) -> some View {
        if let value, !value.isEmpty {
            GridRow(alignment: .firstTextBaseline) {
                Text(title)
                    .foregroundStyle(.secondary)
                    .gridColumnAlignment(.trailing)
                Text(verbatim: value)
                    .font(monospaced ? .body.monospaced() : .body)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: Speed test

    private var speed: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Speed Test")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button(action: { speedTest.isRunning ? speedTest.stop() : speedTest.start() }) {
                    Label(speedTest.isRunning ? "Stop" : "Run Speed Test",
                          systemImage: speedTest.isRunning ? "stop.fill" : "speedometer")
                }
                .disabled(publicNetwork.isOffline && !speedTest.isRunning)
            }
            if speedTest.isRunning, let startedAt = speedTest.startedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Measuring download, upload and responsiveness… \(Int(context.date.timeIntervalSince(startedAt))) s")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let error = speedTest.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            if let result = speedTest.result {
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        tile("Download", NetworkQuality.formatRate(result.download), systemImage: "arrow.down.circle")
                        tile("Upload", NetworkQuality.formatRate(result.upload), systemImage: "arrow.up.circle")
                    }
                    GridRow {
                        tile("Idle Latency", result.idleLatency.map { String(format: "%.0f ms", $0) } ?? "—",
                             systemImage: "timer")
                        tile("Responsiveness", result.responsiveness.map { String(format: "%.0f RPM", $0) } ?? "—",
                             systemImage: "waveform.path.ecg",
                             help: "Round trips per minute while the connection is busy. Higher is better.")
                    }
                }
                .opacity(speedTest.isRunning ? 0.4 : 1)
                Text(details(result))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !speedTest.isRunning {
                Text("Uses macOS's built-in networkQuality test against Apple's servers. It takes about 20 seconds and transfers a few hundred megabytes on a fast connection.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func details(_ result: SpeedTestResult) -> String {
        var parts = [result.date.formatted(date: .abbreviated, time: .shortened)]
        if let interface = result.interface { parts.append("via \(interface)") }
        if let server = result.server { parts.append("server \(server)") }
        return parts.joined(separator: " · ")
    }

    private func tile(_ title: String, _ value: String, systemImage: String, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.monospacedDigit().weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        .help(help ?? "")
    }
}
