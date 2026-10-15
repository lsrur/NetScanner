import Observation
import SwiftUI

@MainActor
@Observable
final class LookupModel {
    enum Mode: String, CaseIterable, Identifiable {
        case dns = "DNS"
        case whois = "Whois"
        var id: Self { self }
    }

    var query = ""
    var mode = Mode.dns
    var recordType = DNSLookup.RecordType.all

    private(set) var records: [DNSRecord] = []
    private(set) var whois: [(server: String, text: String)] = []
    private(set) var isRunning = false
    private(set) var message: String?
    fileprivate var task: Task<Void, Never>?
    private var runID = 0

    /// Points at a new host, discarding the previous results.
    func retarget(_ query: String) {
        guard query != self.query else { return }
        task?.cancel()
        isRunning = false
        self.query = query
        records = []
        whois = []
        message = nil
    }

    func start() {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        task?.cancel()
        records = []
        whois = []
        message = nil
        isRunning = true
        runID += 1
        let runID = runID
        let mode = mode, recordType = recordType
        task = Task {
            switch mode {
            case .dns:
                let found = await DNSLookup.lookup(query, type: recordType)
                guard self.runID == runID else { return }
                records = found
                if found.isEmpty { message = "No records found." }
            case .whois:
                if let address = IPv4Address(query), Whois.isPrivate(address) {
                    message = "\(query) is a private address; public whois has no data for it."
                } else {
                    let answers = await Whois.lookup(query)
                    guard self.runID == runID else { return }
                    whois = answers
                    if answers.isEmpty { message = "No whois server answered." }
                }
            }
            if self.runID == runID { isRunning = false }
        }
    }
}

struct LookupPanel: View {
    @Bindable var model: LookupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Host, IP or domain", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .onSubmit(model.start)
            HStack {
                Picker("Mode", selection: $model.mode) {
                    ForEach(LookupModel.Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                if model.mode == .dns {
                    Picker("Type", selection: $model.recordType) {
                        ForEach(DNSLookup.RecordType.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .fixedSize()
                }
            }
            Button(action: model.start) {
                Label(model.mode == .dns ? "Look Up" : "Whois", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model.isRunning || model.query.trimmingCharacters(in: .whitespaces).isEmpty)

            if model.isRunning {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            } else if let message = model.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            switch model.mode {
            case .dns: recordList
            case .whois: whoisText
            }
        }
    }

    private var recordList: some View {
        List(model.records, id: \.self) { record in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(record.type)
                    .font(.caption.weight(.semibold).monospaced())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
                Text(verbatim: record.value)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(record.ttl)s")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .listStyle(.bordered)
    }

    private var whoisText: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(model.whois.enumerated()), id: \.offset) { _, answer in
                    Text(verbatim: "— \(answer.server) —")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(verbatim: answer.text.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(8)
        }
        .background(.background, in: .rect(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
    }
}

#if DEBUG
extension LookupModel {
    /// Finished DNS results, for screenshots.
    func loadDemo(query: String, records: [DNSRecord]) {
        task?.cancel()
        self.query = query
        mode = .dns
        recordType = .all
        isRunning = false
        message = nil
        whois = []
        self.records = records
    }
}
#endif
