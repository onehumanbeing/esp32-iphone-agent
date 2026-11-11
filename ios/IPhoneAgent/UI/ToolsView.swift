import SwiftUI
import UniformTypeIdentifiers

/// Settings › Model › Tools: what the agent may look up before or while it acts (Tools.swift). Handsy Search comes
/// with a Handsy key; Web Search runs on one's own Exa key; more tools come from a JSON file.
struct ToolsView: View {
    @ObservedObject private var store = ToolStore.shared
    @ObservedObject private var trial = Trial.shared
    @State private var importing = false
    @State private var importError: String?
    @State private var editing: ToolSpec?
    @Environment(\.locale) private var locale

    var body: some View {
        Form {
            Section {
                ForEach(store.all) { tool in
                    ToolRow(tool: tool, store: store, keyed: trial.keyed) { editing = tool }
                }
                .onDelete(perform: delete)
            } footer: {
                Text("Before acting, the agent can look up what the task names, such as a product, a brand or a place, so a misspelt name or a product that doesn't exist doesn't send it scrolling.")
            }
            Section {
                Button(action: startImport) { Label("Import a Tool…", systemImage: "square.and.arrow.down") }
            } footer: {
                Link(destination: docsURL) {
                    Label("How to Make a Tool", systemImage: "book")
                }
                .font(.footnote)
            }
        }
        .navigationTitle("Tools")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: Space.s) {
                    Text("Tools").font(.headline)
                    BetaBadge()
                }
                .accessibilityElement(children: .combine)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json], onCompletion: imported)
        .alert("Couldn't Import", isPresented: Binding { importError != nil } set: { if !$0 { importError = nil } }) {
        } message: { Text(verbatim: importError ?? "") }
        .sheet(item: $editing) { ToolKeySheet(tool: $0, store: store) }
    }

    /// The tool file format, on handsy.tech's docs (the Chinese page on a Chinese iPhone).
    private var docsURL: URL {
        let zh = locale.language.languageCode == .chinese
        return URL(string: zh ? "https://handsy.tech/zh/docs/tools" : "https://handsy.tech/docs/tools")!
    }

    private func startImport() { importing = true }

    private func imported(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { importError = String(localized: "Not a tool file."); return }
        importError = store.add(json: data)
    }

    private func delete(_ offsets: IndexSet) {
        for i in offsets where store.all[i].builtin == nil { store.remove(store.all[i].id) }
    }
}

/// One tool: on or off, what it is, and whether it can run (its key).
private struct ToolRow: View {
    let tool: ToolSpec
    @ObservedObject var store: ToolStore
    let keyed: Bool
    let edit: () -> Void

    var body: some View {
        Toggle(isOn: Binding { store.enabled.contains(tool.id) } set: { store.set(tool.id, on: $0) }) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: tool.title)
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
            } icon: {
                icon
            }
        }
        .tint(Palette.accent)
        .swipeActions(edge: .leading) {
            if tool.needsKey { Button("Key", systemImage: "key", action: edit).tint(.gray) }
        }
        .contextMenu {
            if tool.needsKey { Button("Set Key…", systemImage: "key", action: edit) }
        }
    }

    @ViewBuilder private var icon: some View {
        switch tool.builtin {
        case "handsy": Image("Logo").resizable().scaledToFit().accessibilityHidden(true)
        case "exa": Image(systemName: "globe")
        default: Image(systemName: "puzzlepiece.extension")
        }
    }

    private var status: LocalizedStringKey {
        if tool.builtin == "handsy" { return keyed ? "Uses your Handsy key" : "Needs a Handsy key" }
        if tool.needsKey && store.key(tool.id).isEmpty { return "No key yet: press and hold to set one" }
        return tool.builtin == nil ? "Imported" : "Uses your own key"
    }
}

/// A tool's own API key (Keychain).
private struct ToolKeySheet: View {
    let tool: ToolSpec
    @ObservedObject var store: ToolStore
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("API key", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: {
                    Text("Stays in this iPhone's Keychain and is only sent to \(URL(string: tool.url)?.host ?? tool.url).")
                }
            }
            .navigationTitle(Text(verbatim: tool.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: close) }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
            .onAppear(perform: load)
        }
        .presentationDetents([.medium])
        .presentationBackground(Color(.systemGroupedBackground))
    }

    private func load() { key = store.key(tool.id) }
    private func close() { dismiss() }
    private func save() {
        store.setKey(tool.id, key)
        if !key.isEmpty { store.set(tool.id, on: true) }
        dismiss()
    }
}
