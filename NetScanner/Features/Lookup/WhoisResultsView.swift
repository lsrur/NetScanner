import Observation
import SwiftUI

@MainActor
@Observable
final class WhoisModel {
    private(set) var answers: [(server: String, text: String)] = []
    private(set) var isRunning = false
    private(set) var message: String?

    /// Queries whois for `query` (a domain or public address) and returns when done.
    func lookup(_ query: String) async {
        clear()
        if let address = IPv4Address(query), Whois.isPrivate(address) {
            message = "\(query) is a private address; public whois has no data for it."
            return
        }
        isRunning = true
        let answers = await Whois.lookup(query)
        isRunning = false
        guard !Task.isCancelled else { return }
        self.answers = answers
        if answers.isEmpty { message = "No whois server answered." }
    }

    func clear() {
        answers = []
        message = nil
    }
}

/// The Whois tab of the Network Tools window.
struct WhoisResultsView: View {
    let model: WhoisModel

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
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(model.answers.enumerated()), id: \.offset) { _, answer in
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
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.background, in: .rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
        }
    }
}

#if DEBUG
extension WhoisModel {
    /// Finished results, for screenshots.
    func loadDemo(answers: [(server: String, text: String)]) {
        isRunning = false
        message = nil
        self.answers = answers
    }
}
#endif
