import Observation
import SwiftUI

@MainActor
@Observable
final class DNSLookupModel {
    var recordType = DNSLookup.RecordType.all

    private(set) var records: [DNSRecord] = []
    private(set) var isRunning = false
    private(set) var message: String?

    /// Looks `query` up and returns when the answers are in.
    func lookup(_ query: String) async {
        clear()
        isRunning = true
        let found = await DNSLookup.lookup(query, type: recordType)
        isRunning = false
        guard !Task.isCancelled else { return }
        records = found
        if found.isEmpty { message = "No records found." }
    }

    func clear() {
        records = []
        message = nil
    }
}

/// The DNS tab of the Network Tools window.
struct DNSResultsView: View {
    let model: DNSLookupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
    func loadDemo(records: [DNSRecord]) {
        recordType = .all
        isRunning = false
        message = nil
        self.records = records
    }
}
#endif
