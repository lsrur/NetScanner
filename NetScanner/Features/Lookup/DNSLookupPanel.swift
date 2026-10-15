import Observation
import SwiftUI

@MainActor
@Observable
final class DNSLookupModel {
    var query = ""
    var recordType = DNSLookup.RecordType.all

    private(set) var records: [DNSRecord] = []
    private(set) var isRunning = false
    private(set) var message: String?
    fileprivate var task: Task<Void, Never>?
    private var runID = 0

    func start() {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        task?.cancel()
        records = []
        message = nil
        isRunning = true
        runID += 1
        let runID = runID
        let recordType = recordType
        task = Task {
            let found = await DNSLookup.lookup(query, type: recordType)
            guard self.runID == runID else { return }
            records = found
            if found.isEmpty { message = "No records found." }
            isRunning = false
        }
    }
}

struct DNSLookupPanel: View {
    @Bindable var model: DNSLookupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Domain or IP", text: $model.query, prompt: Text(verbatim: "example.com"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(model.start)
                Picker("Type", selection: $model.recordType) {
                    ForEach(DNSLookup.RecordType.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("Record type. An IPv4 address is always looked up as PTR.")
            }
            Button(action: model.start) {
                Label("Look Up", systemImage: "magnifyingglass")
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
    }
}

#if DEBUG
extension DNSLookupModel {
    /// Finished results, for screenshots.
    func loadDemo(query: String, records: [DNSRecord]) {
        task?.cancel()
        self.query = query
        recordType = .all
        isRunning = false
        message = nil
        self.records = records
    }
}
#endif
