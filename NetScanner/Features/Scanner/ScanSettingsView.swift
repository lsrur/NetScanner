import SwiftUI

/// "Customize…": manage saved scans (named IP ranges). Only edits; scans are launched from
/// the ⌄ menu. Works on a draft so Cancel leaves the saved list untouched.
struct ScanSettingsView: View {
    let scanner: ScannerModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: [ScanTarget] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Saved Scans")
                    .font(.title2.weight(.semibold))
                Text("Named ranges that appear in the ⌄ menu, ready to scan with one click.")
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(spacing: 0) {
                    ForEach($draft) { $scan in
                        SavedScanRow(scan: $scan) {
                            draft.removeAll { $0.id == scan.id }
                        }
                        if scan.id != draft.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
            }
            // Full width even when empty; otherwise the box shrinks to its (empty) content.
            .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 320)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
            .overlay {
                if draft.isEmpty {
                    Text("No saved scans.")
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .firstTextBaseline) {
                Button("Add", systemImage: "plus") { draft.append(.newRange()) }
                Spacer()
                Text("Ranges: 192.168.0.100-200 · 10.0.0.0/23 · 192.168.1.5, comma-separated")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    scanner.setSavedScans(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.contains { $0.validationError != nil })
            }
        }
        .padding(20)
        .frame(width: 600)
        .onAppear { draft = initialDraft ?? scanner.savedScans }
    }

    /// For previews and snapshot checks: start with a given draft.
    init(scanner: ScannerModel, draft: [ScanTarget]? = nil) {
        self.scanner = scanner
        _draft = State(initialValue: draft ?? [])
        initialDraft = draft
    }

    private let initialDraft: [ScanTarget]?
}

private struct SavedScanRow: View {
    @Binding var scan: ScanTarget
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                TextField("Name", text: $scan.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                TextField("Range", text: rangeBinding, prompt: Text(verbatim: "192.168.0.100-200"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Delete saved scan")
            }
            if let error = scan.validationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, 190)
            }
        }
        .padding(.vertical, 8)
    }

    private var rangeBinding: Binding<String> {
        Binding(get: { scan.rangeText ?? "" }, set: { scan.kind = .range($0) })
    }
}
