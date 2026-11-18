import SwiftUI
import UniformTypeIdentifiers

/// the Files tab. Browses this app's documents (FilesLayout): the agent's result folders at the top level, Memory,
/// Logs, and whatever the user keeps here; the app's own data and developer folders only with developer files on.
/// Folder links use `NavigationLink(destination:)` because Settings already does; mixing in
/// `navigationDestination(for:)` in that stack breaks navigation.
struct LocalFilesView: View {
    @ObservedObject var app: AppModel
    private let sandbox: FileSandbox
    private let directory: URL
    @AppStorage(FilesLayout.developerKey) private var developer = false
    @State private var entries: [AgentFileEntry] = []
    @State private var importing = false
    @State private var shareURL: URL?
    @State private var editingPlan = false
    @State private var notice = ""
    @State private var showingNotice = false
    @State private var naming: FileNaming?
    @State private var typedName = ""
    @State private var askingName = false
    @State private var deleting: AgentFileEntry?
    @State private var deletingFolder = false  // this folder itself, from the ⋯ menu
    @State private var results: [ResultFolder] = []  // root: the recent result folders, newest first
    @State private var origin: Run?  // a result folder: the run that wrote it
    @State private var query = ""  // root: search names and the agent's notes and tables (FileSearch)
    @State private var hits: [AgentFileEntry] = []

    private let showsOrigin: Bool  // off when opened from that run's own review

    init(app: AppModel, directory: URL? = nil, showsOrigin: Bool = true) {
        self.app = app
        self.showsOrigin = showsOrigin
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
    private var isResultFolder: Bool { relative.split(separator: "/").count == 1 && !MemoryFiles.isReserved(relative) }
    private var here: String { relative.isEmpty ? "." : relative }

    var body: some View {
        List {
            if atRoot && !query.trimmingCharacters(in: .whitespaces).isEmpty {
                searchResults
            } else {
                folderContents
            }
        }
        .modifier(SearchAtRoot(on: atRoot, text: $query))
        .task(id: query) { await search() }
        .navigationTitle(atRoot ? Text("Files") : Text(verbatim: FilesLayout.displayName(relative)))
        .navigationBarTitleDisplayMode(atRoot ? .large : .inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                FilesMenu(newFolder: startNewFolder, newNote: startNewNote, importFile: startImport, export: shareFolder,
                          delete: !atRoot && FileSandbox.canChange(relative) ? { deletingFolder = true } : nil)
            }
        }
        .deletable(atRoot ? nil : relative, in: sandbox, folder: true, asked: $deletingFolder)
        .task(id: directory) { await load() }
        .onAppear(perform: reload)  // back from a folder or file that was deleted inside
        .onChange(of: developer) { reload() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], onCompletion: imported)
        .sheet(item: $shareURL) { ShareSheet(items: [$0]) }
        .sheet(isPresented: $editingPlan) {
            NavigationStack { PlanEditView(app: app, folder: directory) }
        }
        .alert(naming?.title ?? Text(verbatim: ""), isPresented: $askingName) {
            TextField("Name", text: $typedName)
            Button("Cancel", role: .cancel) {}
            Button("Save", action: finishNaming)
        }
        .alert("Couldn't do that", isPresented: $showingNotice) {
        } message: {
            Text(verbatim: notice)
        }
        .accessibilityIdentifier(atRoot ? "settings.files" : "files.folder")
    }

    @ViewBuilder private var folderContents: some View {
            if relative == "logs" {
                LogsSendSection(app: app)
            }
            if let origin {
                ResultOriginSection(app: app, run: origin)
            }
            if atRoot && !results.isEmpty {
                ResultsSection(app: app, folders: results, delete: askDeleteFolder)
            }
            if PlanFolder.looksLike(directory) {
                Section {
                    Button("Edit plan with AI", systemImage: "text.bubble", action: showPlanEditor)
                } footer: {
                    Text("Change this recording in a chat. Nothing is kept until you accept the review.")
                }
            }
            if entries.isEmpty && (results.isEmpty || !atRoot) {
                Section {
                    EmptyState(mood: .sleeping, title: "Nothing in this folder",
                               message: "Add a folder or a note, or import a file, from the ⋯ menu.")
                }
            } else if !entries.isEmpty {
                Section {
                    ForEach(entries) { entry in row(entry) }
                } header: {
                    if atRoot { Text("Files") }
                } footer: {
                    FilesLocationFooter(atRoot: atRoot)
                }
            }
    }

    @ViewBuilder private var searchResults: some View {
        if hits.isEmpty {
            Section { Text("No matches").foregroundStyle(.secondary) }
        } else {
            Section {
                ForEach(hits) { entry in row(entry) }
            } header: {
                Text("\(hits.count) matches")
            }
        }
    }

    private func row(_ entry: AgentFileEntry) -> some View {
        AgentFileRow(app: app, entry: entry, url: sandbox.resolve(entry.relative), relative: entry.relative,
                     sandbox: sandbox, share: shareFile, rename: startRename, delete: askDelete)
    }

    private func child(_ name: String) -> String { relative.isEmpty ? name : relative + "/" + name }

    private func showPlanEditor() { editingPlan = true }
    private func startImport() { importing = true }
    private func startNewFolder() { ask(.folder, "") }
    private func startNewNote() { ask(.note, "") }
    private func startRename(_ entry: AgentFileEntry) { ask(.rename(path(entry)), entry.name) }
    private func ask(_ kind: FileNaming, _ name: String) { typedName = name; naming = kind; askingName = true }
    /// A swipe or the row's menu is the confirmation (as in Mail): no second dialog. Henry 2026-11-19: the dialog
    /// floated over the list, away from the row. Deleting this folder from the ⋯ menu still asks (deletable).
    private func askDelete(_ entry: AgentFileEntry) { deleting = entry; finishDelete() }
    private func askDeleteFolder(_ url: URL) {
        let name = url.lastPathComponent
        askDelete(AgentFileEntry(name: name, isDirectory: true, bytes: 0, relative: name))
    }
    /// From Documents: a search hit sits deeper than this folder.
    private func path(_ entry: AgentFileEntry) -> String { entry.relative.isEmpty ? child(entry.name) : entry.relative }

    /// The folder as one .zip, so it leaves the iPhone whole (a README and its images together).
    private func shareFolder() {
        let folder = directory
        Task {
            shareURL = await Task.detached(priority: .userInitiated) { FolderZip.make(folder) }.value ?? folder
        }
    }
    private func shareFile(_ url: URL) { shareURL = url }

    private func finishNaming() {
        let name = typedName
        let failure: ManageError?
        switch naming {
        case .folder: failure = sandbox.makeFolder(in: here, named: name).error
        case .note: failure = sandbox.makeNote(in: here, named: name).error
        case .rename(let old): failure = sandbox.rename(old, to: name)
        case nil: failure = nil
        }
        naming = nil
        show(failure)
        reload()
    }

    private func finishDelete() {
        guard let entry = deleting else { return }
        deleting = nil
        show(sandbox.remove(path(entry)))
        reload()
        if !query.isEmpty { Task { await search() } }
    }

    private func show(_ failure: ManageError?) {
        guard let failure else { return }
        notice = failure.message
        showingNotice = true
    }

    private func load() async { reload() }

    /// Off the main thread, a moment after the last keystroke; the folder a hit is in is its subtitle.
    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard atRoot, !text.isEmpty else { hits = []; return }
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        let (root, dev) = (AgentFiles.root, developer)
        let found = await Task.detached(priority: .userInitiated) { FileSearch.run(text, root: root, developer: dev) }.value
        guard !Task.isCancelled else { return }
        hits = found.map { hit in
            let parts = hit.relative.split(separator: "/").map(String.init)
            let folder = parts.count > 1 ? FilesLayout.displayName(parts[0]) : nil
            let note = [folder, hit.line].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            return AgentFileEntry(name: parts.last ?? hit.relative, isDirectory: hit.isDirectory, bytes: 0,
                                  relative: hit.relative, note: note.isEmpty ? nil : note)
        }
    }

    private func reload() {
        if atRoot || isResultFolder { app.runs.reload() }
        results = atRoot ? ResultFolder.list(app) : []
        origin = isResultFolder && showsOrigin ? ResultFolder.origin(of: directory, app) : nil
        let shownAsResults = Set(results.map { $0.url.lastPathComponent })
        guard let url = sandbox.resolve(here) else { entries = []; return }
        let items = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles])) ?? []
        entries = items.compactMap { item in
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            if values?.isSymbolicLink == true, !AgentFiles.contains(item.resolvingSymlinksInPath()) { return nil }
            let name = item.lastPathComponent
            let path = child(name)
            guard FilesLayout.isVisible(path, developer: developer), sandbox.resolve(path) != nil else { return nil }
            if atRoot, shownAsResults.contains(name) { return nil }  // listed once, under Results
            return AgentFileEntry(name: name, isDirectory: values?.isDirectory == true, bytes: values?.fileSize ?? 0,
                                  relative: path)
        }.sorted(by: Self.order)
    }

    /// The app's own folders first (Memory, Logs), then folders, then files, each by name.
    private static func order(_ a: AgentFileEntry, _ b: AgentFileEntry) -> Bool {
        let rank = { (e: AgentFileEntry) in FilesLayout.rank(e.relative) ?? (e.isDirectory ? 10 : 11) }
        if rank(a) != rank(b) { return rank(a) < rank(b) }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
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

/// Search only on the Files root: inside a folder the list is short.
private struct SearchAtRoot: ViewModifier {
    let on: Bool
    @Binding var text: String

    func body(content: Content) -> some View {
        if on {
            content.searchable(text: $text, placement: .navigationBarDrawer(displayMode: .automatic),
                               prompt: Text("Search names and notes"))
        } else {
            content
        }
    }
}
