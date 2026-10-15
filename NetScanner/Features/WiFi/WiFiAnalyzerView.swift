import AppKit
import Charts
import SwiftUI

struct WiFiAnalyzerView: View {
    @Bindable var model: WiFiAnalyzerModel
    @State private var sortOrder = [KeyPathComparator(\WiFiAnalyzerModel.Network.rssi, order: .reverse)]
    @State private var selection: WiFiAnalyzerModel.Network.ID?
    @State private var columns = Persisted.load(TableColumnCustomization<WiFiAnalyzerModel.Network>.self,
                                                forKey: Self.columnsKey, from: .standard) ?? TableColumnCustomization()
    private static let columnsKey = "wifiTableColumns"

    var body: some View {
        VStack(spacing: 0) {
            controls
                .padding(.horizontal)
                .padding(.vertical, 10)
            if model.needsLocationAccess {
                locationBanner
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
            Divider()
            VSplitView {
                ChartPanel(model: model)
                    .padding()
                    .frame(minHeight: 200, idealHeight: 280)
                table
                    .frame(minHeight: 200)
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        .onAppear(perform: model.start)
        .onDisappear(perform: model.stop)
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 14) {
            Button(action: { model.isRunning ? model.stop() : model.start() }) {
                Label(model.isRunning ? "Pause" : "Scan", systemImage: model.isRunning ? "pause.fill" : "play.fill")
                    .frame(minWidth: 60)
            }
            Picker("Every", selection: $model.interval) {
                ForEach([2.0, 5, 10, 30], id: \.self) { Text("\(Int($0)) s").tag($0) }
            }
            .fixedSize()
            Picker("Band", selection: $model.bandFilter) {
                ForEach(WiFiAnalyzerModel.BandFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            status
            Button("Clear", systemImage: "trash") { model.clear() }
                .labelStyle(.iconOnly)
                .help("Forget the networks and their history")
        }
    }

    @ViewBuilder
    private var status: some View {
        HStack(spacing: 6) {
            if model.isScanning {
                ProgressView()
                    .controlSize(.small)
                Text("Scanning…")
            } else if let lastScan = model.lastScan {
                Text("\(model.visibleNetworks.count) networks · scanned \(lastScan, style: .relative) ago")
            }
            if let link = model.link {
                Text("· connected \(link.rssi) dBm, \(Int(link.transmitRate)) Mbps")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }

    private var locationBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "location.slash")
                .foregroundStyle(.orange)
            Text(model.location.isDenied
                 ? "macOS hides network names and BSSIDs without Location access. Allow NetScanner in System Settings → Privacy & Security → Location Services."
                 : "macOS shows network names and BSSIDs only to apps with Location access. Allow it when asked.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if model.location.isDenied {
                Button("Open Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                        NSWorkspace.shared.open(url)
                    }
                }
            } else {
                Button("Allow…") { model.location.requestIfNeeded() }
            }
        }
        .font(.callout)
        .padding(10)
        .background(.orange.opacity(0.12))
    }

    // MARK: Table

    private var rows: [WiFiAnalyzerModel.Network] {
        model.visibleNetworks.sorted(using: sortOrder)
    }

    private var columnsBinding: Binding<TableColumnCustomization<WiFiAnalyzerModel.Network>> {
        Binding(get: { columns }, set: { newValue in
            columns = newValue
            Persisted.save(newValue, forKey: Self.columnsKey, to: .standard)
        })
    }

    private var table: some View {
        // Two builders: one with all 17 columns is too much for the type checker.
        Table(rows, selection: $selection, sortOrder: $sortOrder, columnCustomization: columnsBinding) {
            identityColumns
            signalColumns
        }
        .overlay {
            if model.networks.isEmpty {
                ContentUnavailableView(model.isScanning ? "Scanning…" : "No Networks Yet", systemImage: "wifi",
                                       description: Text("The first scan takes a few seconds."))
            }
        }
    }

    @TableColumnBuilder<WiFiAnalyzerModel.Network, KeyPathComparator<WiFiAnalyzerModel.Network>>
    private var identityColumns: some TableColumnContent<WiFiAnalyzerModel.Network, KeyPathComparator<WiFiAnalyzerModel.Network>> {
        TableColumn("") { network in
            Toggle("Show in chart", isOn: checkedBinding(network.id))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .tint(WiFiPalette.color(network.colorIndex))
                .help("Show in the signal chart")
        }
        .width(22)
        .customizationID("chart")
        .disabledCustomizationBehavior(.visibility)
        TableColumn("SSID", value: \.ssidText) { network in
            HStack(spacing: 5) {
                Text(verbatim: network.ssidText)
                    .fontWeight(network.isConnected ? .semibold : .regular)
                    .foregroundStyle(network.latest.ssid == nil || network.latest.ssid?.isEmpty == true ? .secondary : .primary)
                Spacer(minLength: 2)
                if network.isConnected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                        .help("This Mac is connected to it")
                }
                if network.latest.isSecured {
                    Image(systemName: "lock.fill")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
            }
            .rowDimmed(!model.isInRange(network))
        }
        .width(min: 110, ideal: 150)
        .customizationID("ssid")
        .disabledCustomizationBehavior(.visibility)
        TableColumn("BSSID", value: \.bssidText) { network in
            Text(verbatim: network.bssidText.uppercased()).font(.callout.monospaced()).rowDimmed(!model.isInRange(network))
        }
        .width(min: 90, ideal: 136)
        .customizationID("bssid")
        TableColumn("Graph") { network in
            Sparkline(samples: network.samples, color: WiFiPalette.color(network.colorIndex))
                .frame(height: 18)
                .rowDimmed(!model.isInRange(network))
        }
        .width(min: 50, ideal: 70)
        .customizationID("graph")
        TableColumn("Channel", value: \.channel) { network in
            Text("\(network.channel)").monospacedDigit().rowDimmed(!model.isInRange(network))
        }
        .width(min: 40, ideal: 52)
        .customizationID("channel")
        TableColumn("Width", value: \.width) { network in
            Text(network.width == 0 ? "—" : "\(network.width)").monospacedDigit().rowDimmed(!model.isInRange(network))
        }
        .width(min: 34, ideal: 40)
        .customizationID("width")
        TableColumn("Band", value: \.bandSortKey) { network in
            Text(verbatim: network.bandText).rowDimmed(!model.isInRange(network))
        }
        .width(min: 30, ideal: 34)
        .customizationID("band")
        TableColumn("Security", value: \.security) { network in
            Text(verbatim: network.security).rowDimmed(!model.isInRange(network))
        }
        .width(min: 70, ideal: 108)
        .customizationID("security")
    }

    @TableColumnBuilder<WiFiAnalyzerModel.Network, KeyPathComparator<WiFiAnalyzerModel.Network>>
    private var signalColumns: some TableColumnContent<WiFiAnalyzerModel.Network, KeyPathComparator<WiFiAnalyzerModel.Network>> {
        TableColumn("Vendor", value: \.vendorText) { network in
            Text(verbatim: network.vendorText).rowDimmed(!model.isInRange(network))
        }
        .width(min: 70, ideal: 100)
        .customizationID("vendor")
        TableColumn("Mode", value: \.modes) { network in
            Text(verbatim: network.modes).rowDimmed(!model.isInRange(network))
        }
        .width(min: 40, ideal: 64)
        .customizationID("mode")
        TableColumn("Level", value: \.rssi) { network in
            LevelBar(rssi: model.isInRange(network) ? network.rssi : -100)
                .frame(height: 12)
        }
        .width(min: 50, ideal: 75)
        .customizationID("level")
        TableColumn("Signal", value: \.rssi) { network in
            Text("\(network.rssi)").monospacedDigit().rowDimmed(!model.isInRange(network))
        }
        .width(min: 36, ideal: 46)
        .customizationID("signal")
        TableColumn("Avg", value: \.average) { network in
            Text(String(format: "%.0f", network.average)).monospacedDigit().rowDimmed(!model.isInRange(network))
        }
        .width(min: 32, ideal: 40)
        .customizationID("avg")
        TableColumn("Max", value: \.maximum) { network in
            Text("\(network.maximum)").monospacedDigit().rowDimmed(!model.isInRange(network))
        }
        .width(min: 32, ideal: 40)
        .customizationID("max")
        TableColumn("Min", value: \.minimum) { network in
            Text("\(network.minimum)").monospacedDigit().rowDimmed(!model.isInRange(network))
        }
        .width(min: 32, ideal: 40)
        .customizationID("min")
        TableColumn("Noise", value: \.noise) { network in
            Text(network.noise == 0 ? "—" : "\(network.noise)").monospacedDigit().rowDimmed(!model.isInRange(network))
        }
        .width(min: 32, ideal: 44)
        .customizationID("noise")
        TableColumn("Last Seen", value: \.lastSeen) { network in
            Text(Self.ago(network.lastSeen, now: model.lastScan ?? .now)).monospacedDigit().rowDimmed(!model.isInRange(network))
        }
        .width(min: 60, ideal: 80)
        .customizationID("lastSeen")
    }

    private func checkedBinding(_ id: WiFiAnalyzerModel.Network.ID) -> Binding<Bool> {
        Binding(get: { model.checked.contains(id) }, set: { isOn in
            if isOn { model.checked.insert(id) } else { model.checked.remove(id) }
        })
    }

    /// "now", "45s ago", "3m 5s ago", "2h 4m ago" — relative to the latest scan, so it only
    /// changes when a scan does.
    static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 1 { return "now" }
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s ago" }
        return "\(seconds / 3600)h \(seconds % 3600 / 60)m ago"
    }
}

// MARK: - Pieces

enum WiFiPalette {
    static let colors: [Color] = [.blue, .purple, .teal, .orange, .pink, .green, .indigo, .brown, .cyan, .mint, .red, .yellow]
    static func color(_ index: Int) -> Color { colors[index % colors.count] }
}

/// The two charts: signal over time, and the networks laid out on their channels.
private struct ChartPanel: View {
    enum Mode: String, CaseIterable, Identifiable {
        case time = "Signal over Time"
        case channels = "Channels"
        var id: Self { self }
    }

    let model: WiFiAnalyzerModel
    @AppStorage("wifiChartMode") private var mode = Mode.time
    /// The channel chart shows one band at a time; it follows the band filter unless that's "All".
    @AppStorage("wifiChannelBand") private var channelBand = WiFiBand.ghz2.rawValue

    private var band: WiFiBand {
        switch model.bandFilter {
        case .ghz2: .ghz2
        case .ghz5: .ghz5
        case .ghz6: .ghz6
        case .all: WiFiBand(rawValue: channelBand) ?? .ghz2
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("Chart", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if mode == .channels, model.bandFilter == .all {
                    Picker("Band", selection: $channelBand) {
                        Text("2.4 GHz").tag(WiFiBand.ghz2.rawValue)
                        Text("5 GHz").tag(WiFiBand.ghz5.rawValue)
                        Text("6 GHz").tag(WiFiBand.ghz6.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            switch mode {
            case .time: SignalChart(model: model)
            case .channels: ChannelChart(model: model, band: band)
            }
        }
    }
}

/// Each network in range as an arch over the channels it occupies, as tall as its signal.
/// Checked networks are drawn stronger.
private struct ChannelChart: View {
    let model: WiFiAnalyzerModel
    let band: WiFiBand

    private struct Point: Identifiable {
        let id: Int
        let channel: Double
        let rssi: Double
    }

    private static let floor = -100.0

    private var domain: ClosedRange<Double> {
        switch band {
        case .ghz5: 30 ... 179
        case .ghz6: -3 ... 237
        default: -1 ... 16
        }
    }

    private var ticks: [Int] {
        switch band {
        case .ghz5: [36, 52, 64, 100, 116, 132, 144, 149, 165, 177]
        case .ghz6: Array(stride(from: 1, through: 233, by: 16))
        default: Array(1...14)
        }
    }

    /// A parabola from the floor at both edges up to the network's signal at the center.
    private func arch(_ network: WiFiAnalyzerModel.Network) -> [Point] {
        let (center, half) = WiFiChannelSpan.span(channel: network.channel, width: network.width, band: band)
        let peak = Double(network.rssi)
        return (0...24).map { step in
            let x = -1 + Double(step) / 12
            return Point(id: step, channel: center + x * half, rssi: Self.floor + (peak - Self.floor) * (1 - x * x))
        }
    }

    var body: some View {
        let networks = model.networks
            .filter { $0.latest.band == band && model.isInRange($0) }
            .sorted { $0.rssi < $1.rssi }  // strongest drawn last, on top
        Chart {
            ForEach(networks) { network in
                let color = WiFiPalette.color(network.colorIndex)
                let isChecked = model.checked.contains(network.id)
                ForEach(arch(network)) { point in
                    AreaMark(x: .value("Channel", point.channel), yStart: .value("Floor", Self.floor),
                             yEnd: .value("Signal", point.rssi), series: .value("Network", network.id))
                        .foregroundStyle(color.opacity(isChecked ? 0.2 : 0.08))
                    LineMark(x: .value("Channel", point.channel), y: .value("Signal", point.rssi),
                             series: .value("Network", network.id))
                        .foregroundStyle(color.opacity(isChecked ? 1 : 0.6))
                        .lineStyle(StrokeStyle(lineWidth: isChecked ? 2 : 1))
                }
                let (center, _) = WiFiChannelSpan.span(channel: network.channel, width: network.width, band: band)
                PointMark(x: .value("Channel", center), y: .value("Signal", network.rssi))
                    .opacity(0)
                    .annotation(position: .top, spacing: 2) {
                        Text(verbatim: network.ssidText)
                            .font(.caption.weight(isChecked ? .semibold : .regular))
                            .foregroundStyle(color.opacity(isChecked ? 1 : 0.75))
                    }
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: Self.floor ... -20)
        .chartXAxis {
            AxisMarks(values: ticks) { value in
                AxisGridLine()
                AxisValueLabel { Text("\(value.as(Int.self) ?? 0)") }
            }
        }
        .chartXAxisLabel("Channel", alignment: .center)
        .chartYAxisLabel("dBm")
        .chartLegend(.hidden)
        .chartPlotStyle { $0.clipped() }
        .overlay {
            if networks.isEmpty, !model.networks.isEmpty {
                Text("No networks in range on \(band.rawValue) GHz.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// RSSI over time of the checked networks.
private struct SignalChart: View {
    let model: WiFiAnalyzerModel

    var body: some View {
        let shown = model.visibleNetworks.filter { model.checked.contains($0.id) }
        Chart {
            ForEach(shown) { network in
                ForEach(network.samples, id: \.date) { sample in
                    LineMark(x: .value("Time", sample.date), y: .value("Signal (dBm)", sample.rssi),
                             series: .value("Network", network.id))
                        .foregroundStyle(WiFiPalette.color(network.colorIndex))
                        .interpolationMethod(.monotone)
                }
            }
        }
        .chartYScale(domain: -100 ... -20)
        .chartYAxisLabel("dBm")
        .chartLegend(.hidden)
        .overlay {
            if shown.isEmpty, !model.networks.isEmpty {
                Text("Check networks in the table to chart their signal.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The last few minutes of signal as a tiny line.
private struct Sparkline: View {
    let samples: [WiFiAnalyzerModel.Sample]
    let color: Color

    var body: some View {
        Canvas { context, size in
            let recent = samples.suffix(40)
            guard recent.count > 1 else { return }
            var path = Path()
            for (offset, sample) in recent.enumerated() {
                let x = size.width * CGFloat(offset) / CGFloat(recent.count - 1)
                let level = (Double(min(max(sample.rssi, -100), -30)) + 100) / 70
                let point = CGPoint(x: x, y: size.height * (1 - level))
                if offset == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(color), lineWidth: 1.2)
        }
    }
}

/// Segmented signal meter: green from −60 dBm, orange from −75, red below.
struct LevelBar: View {
    let rssi: Int
    static let segments = 20

    static func filled(_ rssi: Int) -> Int {
        let fraction = (Double(min(max(rssi, -100), -30)) + 100) / 70
        return Int((fraction * Double(segments)).rounded())
    }

    static func color(_ rssi: Int) -> Color {
        rssi >= -60 ? .green : rssi >= -75 ? .orange : .red
    }

    var body: some View {
        Canvas { context, size in
            let gap: CGFloat = 1
            let width = (size.width - gap * CGFloat(Self.segments - 1)) / CGFloat(Self.segments)
            let filled = Self.filled(rssi)
            for index in 0..<Self.segments {
                let rect = CGRect(x: CGFloat(index) * (width + gap), y: 0, width: width, height: size.height)
                context.fill(Path(rect), with: .color(index < filled ? Self.color(rssi) : .secondary.opacity(0.2)))
            }
        }
        .help("\(rssi) dBm")
    }
}

private extension View {
    /// Networks missing from the latest scan fade out.
    func rowDimmed(_ dimmed: Bool) -> some View {
        opacity(dimmed ? 0.45 : 1)
    }
}
