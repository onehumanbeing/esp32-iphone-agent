import SwiftUI

/// Settings › Memory: what the agent remembers across runs (MEMORY.md). Swipe to delete, tap to edit, + to add.
struct MemoryView: View {
    @ObservedObject var store: MemoryStore
    @State private var editing: MemoryEntry?
    @State private var draft = ""
    @State private var adding = false

    var body: some View {
        List {
            if store.entries.isEmpty {
                Text("Nothing yet. Tell the agent \"remember …\" in a task, or add a line here. Lessons from finished runs show up here too.")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.entries.reversed()) { e in
                Button { editing = e; draft = e.text } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: e.text).foregroundStyle(.primary)
                        Text(verbatim: [label(e.kind), e.topic].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in
                let shown = Array(store.entries.reversed())
                offsets.map { shown[$0].id }.forEach(store.remove)
            }
        }
        .navigationTitle("Memory")
        .toolbar { Button { adding = true; draft = "" } label: { Image(systemName: "plus") } }
        .alert("Edit memory", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Memory", text: $draft)
            Button("Save") { if let e = editing { store.update(e.id, text: draft) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Add memory", isPresented: $adding) {
            TextField("e.g. I prefer short answers", text: $draft)
            Button("Add") { store.add(draft, kind: .preference) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Passwords, codes and card numbers are never kept.")
        }
    }

    private func label(_ kind: MemoryEntry.Kind) -> String {
        switch kind {
        case .preference: String(localized: "Preference")
        case .fact: String(localized: "Fact")
        case .app: String(localized: "App")
        }
    }
}
