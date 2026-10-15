import AppKit
import SwiftUI

struct PortScanPanel: View {
    @Bindable var model: PortScanModel
    @Environment(\.openURL) private var openURL
    @State private var selection = Set<UInt16>()
    @State private var isEditingLists = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // One control per line: side by side they need more than the inspector width.
            HStack {
                Picker("Ports", selection: $model.selectedListID) {
                    ForEach(model.lists.lists) { Text($0.displayName).tag(Optional($0.id)) }
                }
                Button("Edit Lists…", systemImage: "pencil") { isEditingLists = true }
                    .labelStyle(.iconOnly)
                    .help("Edit port lists")
            }
            Picker("Timeout", selection: $model.timeout) {
                ForEach(PortScanModel.timeouts, id: \.self) { Text("\(Int($0 * 1000)) ms").tag($0) }
            }
            .fixedSize()
            Toggle("Show closed", isOn: $model.showClosed)
            Button(action: toggle) {
                Label(model.isRunning ? "Stop" : "Scan Ports",
                      systemImage: model.isRunning ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            status
            results
        }
        .sheet(isPresented: $isEditingLists) {
            PortListsEditor(store: model.lists)
        }
    }

    @ViewBuilder
    private var status: some View {
        if model.isRunning {
            ProgressView(value: model.progress) {
                Text("\(model.scannedCount) / \(model.totalCount) — \(model.openCount) open")
                    .font(.caption)
                    .monospacedDigit()
            }
        } else if let elapsed = model.elapsed {
            Text("\(model.openCount) open of \(model.totalCount) in \(elapsed.formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated)))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var results: some View {
        Table(model.visibleResults, selection: $selection) {
            TableColumn("Port") { result in
                Text(verbatim: "\(result.port)")
                    .monospacedDigit()
            }
            .width(min: 44, ideal: 50, max: 64)
            TableColumn("Service") { result in
                if let url = result.webURL {
                    Link(destination: url) {
                        Label(result.service, systemImage: "arrow.up.forward.square")
                    }
                } else {
                    Text(verbatim: result.service)
                }
            }
            .width(min: 70, ideal: 100)
            TableColumn("Typical Use") { result in
                Text(verbatim: PortDescriptions.tooltip(for: result.port))
                    .foregroundStyle(.secondary)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cellToolTip(Self.tooltip(for: result))
            }
            .width(min: 80, ideal: 160)
            TableColumn("") { result in
                Image(systemName: result.state == .open ? "lock.open.fill" : "lock.fill")
                    .foregroundStyle(result.state == .open ? .green : .secondary)
                    .cellToolTip(result.state.rawValue)
                    .accessibilityLabel(result.state.rawValue)
            }
            .width(22)
        }
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: UInt16.self) { ports in
            if let result = model.visibleResults.first(where: { ports.contains($0.port) }) {
                if let url = result.webURL {
                    Button("Open in Browser") { openURL(url) }
                    Button("Copy URL") { copy(url.absoluteString) }
                }
                Button("Copy Port") { copy("\(result.port)") }
            }
        } primaryAction: { ports in
            if let url = model.visibleResults.first(where: { ports.contains($0.port) })?.webURL {
                openURL(url)
            }
        }
        .overlay {
            if model.visibleResults.isEmpty, !model.isRunning, model.elapsed != nil {
                ContentUnavailableView("No Open Ports", systemImage: "lock.fill")
            }
        }
    }

    private static func tooltip(for result: PortScanModel.Result) -> String {
        let description = "\(result.port) — \(PortDescriptions.tooltip(for: result.port))"
        guard let url = result.webURL else { return description }
        return description + "\n" + url.absoluteString
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private func toggle() {
        model.isRunning ? model.stop() : model.start()
    }
}
