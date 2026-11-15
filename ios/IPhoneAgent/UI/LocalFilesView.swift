import SwiftUI
import UniformTypeIdentifiers

/// Settings › Files, next to Memory. Browses this app's documents, where `memory/MEMORY.md` lives.
/// Folder links use `NavigationLink(destination:)` because Settings already does; mixing in
/// `navigationDestination(for:)` in that stack breaks navigation.
struct LocalFilesView: View {
    @ObservedObject var app: AppModel
    private let sandbox: FileSandbox
    private let directory: URL
    @State private var entries: [AgentFileEntry] = []
    @State private var importing = false
    @State private var shareURL: URL?
    @State private var editingPlan = false
    @State private var notice = ""
    @State private var showingNotice = false

    init(app: AppModel, directory: URL? = nil) {
        self.app = app
        let root = AgentFiles.root
        let asked = directory ?? root
        self.directory = AgentFiles.contains(asked) ? asked.standardizedFileURL : root
        self.sandbox = FileSandbox(root: root)
    }

    private var atRoot: Bool { directory.resolvingSymlinksInPath().path == AgentFiles.root.resolvingSymlinksInPath().path }
    private var relative: String {
        let root = AgentFiles.root.resolvingSymlinksInPath().path
        let path = directory.resolvingSymlinksInPath().path
        guard path.hasPrefix(root) else { return "" }
        return String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    private var here: String { relative.isEmpty ? "." : relative }

    var body: some View {
        List {
            if PlanFolder.looksLike(directory) {
                Section {
                    Button("Edit plan with AI", systemImage: "text.bubble", action: showPlanEditor)
                } footer: {
                    Text("Change this recording in a chat. Nothing is kept until you accept the review.")
                }
            }
            if entries.isEmpty {
                Section {
                    EmptyState(mood: .sleeping, title: "Nothing in this folder",
                               message: "Import a file, or open a folder such as memory.")
                }
            } else {
                Section {
                    ForEach(entries) { entry in
                        AgentFileRow(app: app, entry: entry, url: sandbox.resolve(child(entry.name)),
                                     relative: child(entry.name), sandbox: sandbox, share: shareFile)
                    }
                } header: {
                    if !relative.isEmpty {
                        Text(verbatim: relative).font(.footnote).foregroundStyle(.secondary)
                    }
                } footer: {
                    FilesLocationFooter(atRoot: atRoot)
                }
            }
        }
        .navigationTitle(atRoot ? Text("Files") : Text(verbatim: directory.lastPathComponent))
        .navigationBarTitleDisplayMode(atRoot ? .large : .inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Import", systemImage: "square.and.arrow.down", action: startImport)
                    .labelStyle(.iconOnly)
            }
            ToolbarItem(placement: .automatic) {
                Button("Share", systemImage: "square.and.arrow.up", action: shareFolder)
                    .labelStyle(.iconOnly)
            }
        }
        .task(id: directory) { await load() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], onCompletion: imported)
        .sheet(item: $shareURL) { ShareSheet(items: [$0]) }
        .sheet(isPresented: $editingPlan) {
            NavigationStack { PlanEditView(app: app, folder: directory) }
        }
        .alert("Couldn't save that file", isPresented: $showingNotice) {
        } message: {
            Text(verbatim: notice)
        }
        .accessibilityIdentifier(atRoot ? "settings.files" : "files.folder")
    }

    private func child(_ name: String) -> String { relative.isEmpty ? name : relative + "/" + name }

    private func showPlanEditor() { editingPlan = true }
    private func startImport() { importing = true }
    private func shareFolder() { shareURL = directory }
    private func shareFile(_ url: URL) { shareURL = url }

    private func load() async { reload() }

    private func reload() {
        guard let url = sandbox.resolve(here) else { entries = []; return }
        let items = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles])) ?? []
        entries = items.compactMap { item in
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            if values?.isSymbolicLink == true, !AgentFiles.contains(item.resolvingSymlinksInPath()) { return nil }
            let name = item.lastPathComponent
            guard sandbox.resolve(child(name)) != nil else { return nil }
            return AgentFileEntry(name: name, isDirectory: values?.isDirectory == true, bytes: values?.fileSize ?? 0)
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func imported(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let message = FileSandbox(root: directory).importFile(from: url, name: url.lastPathComponent) {
            notice = message
            showingNotice = true
        }
        reload()
    }
}
