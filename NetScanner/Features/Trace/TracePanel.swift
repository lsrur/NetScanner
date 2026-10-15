import SwiftUI

struct TracePanel: View {
    @Bindable var session: TraceSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Host or IP", text: $session.host, prompt: Text(verbatim: "example.com"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if !session.isRunning { session.start() } }
                Picker("Max hops", selection: $session.maxHops) {
                    ForEach([15, 30, 64], id: \.self) { Text("\($0)").tag($0) }
                }
                .fixedSize()
            }
            Button(action: toggle) {
                Label(session.isRunning ? "Stop" : "Start Traceroute",
                      systemImage: session.isRunning ? "stop.fill" : "point.topleft.down.to.point.bottomright.curvepath")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!session.isRunning && session.host.trimmingCharacters(in: .whitespaces).isEmpty)

            if let error = session.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            status
            hopList
        }
    }

    @ViewBuilder
    private var status: some View {
        if session.isRunning {
            ProgressView {
                Text("Hop \(session.hops.count + 1) of up to \(session.maxHops)…")
                    .font(.caption)
            }
        } else if session.reachedDestination {
            Text("Reached \(session.resolvedAddress?.description ?? "") in \(session.hops.count) hops")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if !session.hops.isEmpty {
            Text("Destination not reached after \(session.hops.count) hops")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private var hopList: some View {
        List(session.hops) { hop in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(hop.ttl)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 22, alignment: .trailing)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: hop.hostname ?? hop.address?.description ?? "*")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if hop.hostname != nil, let address = hop.address {
                        Text(verbatim: address.description)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                Text(verbatim: Self.rttText(hop.rtts))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(hop.address == nil ? .secondary : .primary)
            }
            .cellToolTip(Self.tooltip(hop))
        }
        .listStyle(.bordered)
    }

    private func toggle() {
        session.isRunning ? session.stop() : session.start()
    }

    /// "12.3  11.9  *  ms" — one value per probe.
    nonisolated static func rttText(_ rtts: [Double?]) -> String {
        guard rtts.contains(where: { $0 != nil }) else { return rtts.map { _ in "*" }.joined(separator: "  ") }
        return rtts.map { $0.map { String(format: "%.1f", $0) } ?? "*" }.joined(separator: "  ") + " ms"
    }

    private static func tooltip(_ hop: TraceSession.Hop) -> String {
        var lines = ["Hop \(hop.ttl)"]
        if let address = hop.address { lines.append(address.description) }
        if let name = hop.hostname { lines.append(name) }
        if hop.isDestination { lines.append("Destination") }
        if hop.unreachable { lines.append("Destination unreachable") }
        return lines.joined(separator: "\n")
    }
}
