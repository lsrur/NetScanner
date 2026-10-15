import Observation
import SwiftUI

@MainActor
@Observable
final class WhoisModel {
    var query = ""

    private(set) var answers: [(server: String, text: String)] = []
    private(set) var isRunning = false
    private(set) var message: String?
    private var task: Task<Void, Never>?
    private var runID = 0

    func start() {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        task?.cancel()
        runID += 1
        answers = []
        message = nil
        if let address = IPv4Address(query), Whois.isPrivate(address) {
            message = "\(query) is a private address; public whois has no data for it."
            isRunning = false
            return
        }
        isRunning = true
        let runID = runID
        task = Task {
            let answers = await Whois.lookup(query)
            guard self.runID == runID else { return }
            self.answers = answers
            if answers.isEmpty { message = "No whois server answered." }
            isRunning = false
        }
    }
}

struct WhoisPanel: View {
    @Bindable var model: WhoisModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Domain or public IP", text: $model.query, prompt: Text(verbatim: "example.com"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(model.start)
            Button(action: model.start) {
                Label("Whois", systemImage: "magnifyingglass")
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
            }
            .background(.background, in: .rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
        }
    }
}
