import SwiftUI

/// Add, edit, delete and restore the named port lists. Edits a draft; Cancel discards it.
struct PortListsEditor: View {
    let store: PortListStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: [PortList] = []
    @State private var selection: PortList.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Port Lists")
                .font(.title2.weight(.semibold))

            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 0) {
                    List(draft, selection: $selection) { list in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(list.displayName)
                            Text(list.parsedPorts.map { "\($0.count) ports" } ?? "invalid")
                                .font(.caption)
                                .foregroundStyle(list.parsedPorts == nil ? .red : .secondary)
                        }
                        .tag(list.id)
                    }
                    .listStyle(.bordered)
                    HStack(spacing: 0) {
                        Button("Add List", systemImage: "plus") {
                            let list = PortList(name: "New List", ports: "22, 80, 443")
                            draft.append(list)
                            selection = list.id
                        }
                        Button("Remove List", systemImage: "minus") {
                            draft.removeAll { $0.id == selection }
                            selection = draft.first?.id
                        }
                        .disabled(selection == nil)
                        Spacer()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .padding(6)
                }
                .frame(width: 200)

                if let index = draft.firstIndex(where: { $0.id == selection }) {
                    editor(for: $draft[index])
                } else {
                    ContentUnavailableView("No List Selected", systemImage: "list.bullet")
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 280)

            HStack {
                Button("Restore Defaults") {
                    draft = PortListStore.builtIn
                    selection = draft.first?.id
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    store.setLists(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.contains { $0.validationError != nil })
            }
        }
        .padding(20)
        .frame(width: 620)
        .onAppear {
            draft = store.lists
            selection = draft.first?.id
        }
    }

    private func editor(for list: Binding<PortList>) -> some View {
        Form {
            TextField("Name", text: list.name)
            TextField("Ports", text: list.ports, prompt: Text("22, 80, 443, 8000-8100"), axis: .vertical)
                .lineLimit(4...8)
                .font(.body.monospaced())
            if let error = list.wrappedValue.validationError {
                Text(error)
                    .foregroundStyle(.red)
            } else if let ports = list.wrappedValue.parsedPorts {
                Text("\(ports.count) ports")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity)
    }
}
