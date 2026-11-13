import SwiftUI
import UniformTypeIdentifiers

/// Settings › Memory: what the agent remembers across runs (MEMORY.md). Swipe to delete, tap to edit, + to add.
/// The ⋯ menu shares the file or folds another copy in (the CLI's `esp32agent memory export` / `import`).
struct MemoryView: View {
    @ObservedObject var store: MemoryStore
    @State private var editing: MemoryEntry?
    @State private var draft = ""
    @State private var adding = false
    @State private var importing = false
    @State private var imported: String?

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
        .toolbar {
            Menu {
                ShareLink(item: store.file) { Label("Export MEMORY.md", systemImage: "square.and.arrow.up") }
                Button { importing = true } label: { Label("Import…", systemImage: "square.and.arrow.down") }
            } label: { Image(systemName: "ellipsis.circle") }
            Button { adding = true; draft = "" } label: { Image(systemName: "plus") }
        }
        .onAppear { _ = store.exportFile() }
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.types) { result in
            imported = Self.read(result).map { text in
                let (added, updated) = store.merge(text)
                return String(localized: "\(added) added, \(updated) updated.")
            } ?? String(localized: "That file could not be read.")
        }
        .alert("Import", isPresented: Binding(get: { imported != nil }, set: { if !$0 { imported = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(verbatim: imported ?? "") }
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

    private static let types: [UTType] = [UTType(filenameExtension: "md") ?? .plainText, .plainText]

    private static func read(_ result: Result<URL, Error>) -> String? {
        guard case .success(let url) = result else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func label(_ kind: MemoryEntry.Kind) -> String {
        switch kind {
        case .preference: String(localized: "Preference")
        case .fact: String(localized: "Fact")
        case .app: String(localized: "App")
        }
    }
}
