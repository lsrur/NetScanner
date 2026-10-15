import Charts
import SwiftUI

struct PingPanel: View {
    @Bindable var session: PingSession

    private static let counts = [5, 10, 20, 50, 100, 0]
    private static let intervals: [TimeInterval] = [0.2, 0.5, 1, 2]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Count", selection: $session.count) {
                    ForEach(Self.counts, id: \.self) { Text($0 == 0 ? "∞" : "\($0)").tag($0) }
                }
                .fixedSize()
                Picker("Every", selection: $session.interval) {
                    ForEach(Self.intervals, id: \.self) { Text("\($0.formatted()) s").tag($0) }
                }
                .fixedSize()
            }
            Button(action: toggle) {
                Label(session.isRunning ? "Stop" : "Start Ping",
                      systemImage: session.isRunning ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)

            if let error = session.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            PingStatsGrid(stats: session.stats)
            chart
            log
        }
    }

    private var chart: some View {
        Chart(session.samples) { sample in
            if let rtt = sample.rtt {
                LineMark(x: .value("Sequence", sample.id), y: .value("RTT (ms)", rtt))
                    .interpolationMethod(.monotone)
                PointMark(x: .value("Sequence", sample.id), y: .value("RTT (ms)", rtt))
                    .symbolSize(12)
            } else {
                RuleMark(x: .value("Sequence", sample.id))
                    .foregroundStyle(.red.opacity(0.5))
            }
        }
        .chartYAxisLabel("ms")
        .frame(height: 130)
    }

    private var log: some View {
        List(session.samples.reversed()) { sample in
            Text(Self.logLine(for: sample))
                .font(.caption.monospaced())
                .foregroundStyle(sample.rtt == nil ? .red : .primary)
        }
        .listStyle(.bordered)
        .frame(minHeight: 100)
    }

    private func toggle() {
        session.isRunning ? session.stop() : session.start()
    }

    private static func logLine(for sample: PingSession.Sample) -> String {
        switch sample.outcome {
        case .reply(let ms):
            "seq=\(sample.id)  \(ms.formatted(.number.precision(.fractionLength(2)))) ms"
        case .timeout:
            "seq=\(sample.id)  timeout"
        case .sendError(let code):
            "seq=\(sample.id)  \(String(cString: strerror(code)))"
        }
    }
}

private struct PingStatsGrid: View {
    let stats: PingStats

    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                StatTile(title: "Sent", value: "\(stats.sent)")
                StatTile(title: "Received", value: "\(stats.received)")
            }
            GridRow {
                StatTile(title: "Loss", value: stats.lossPercent.formatted(.number.precision(.fractionLength(1))) + " %",
                         highlight: stats.lost > 0 ? .red : nil)
                StatTile(title: "Jitter", value: Self.ms(stats.jitter))
            }
            GridRow {
                StatTile(title: "Min", value: Self.ms(stats.minimum))
                StatTile(title: "Max", value: Self.ms(stats.maximum))
            }
            GridRow {
                StatTile(title: "Avg", value: Self.ms(stats.average))
                StatTile(title: "Std Dev", value: Self.ms(stats.standardDeviation))
            }
        }
    }

    private static func ms(_ value: Double?) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(2))) + " ms" } ?? "—"
    }
}

private struct StatTile: View {
    let title: String
    let value: String
    var highlight: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.monospacedDigit().weight(.semibold))
                .foregroundStyle(highlight ?? .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
    }
}
