import SwiftUI
import UniformTypeIdentifiers

/// Settings › Files, next to Memory. The agent directory on this iPhone: browse, edit text, import, and share.
/// A recording folder in here opens the plan chat. Nothing outside the directory can be opened.
struct LocalFilesView: View {
    @ObservedObject var app: AppModel
    private let sandbox: FileSandbox
    private let directory: URL
    @State private var entries: [AgentFileEntry] = []
    @State private var importing = false
    @State private var shareURL: URL?
    @State private var editingPlan = false
    @State private var notice: String?

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
                    Button { editingPlan = true } label: {
                        Label("Edit plan with AI", systemImage: "text.bubble")
                    }
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
                        row(entry)
                    }
                } header: {
                    if !relative.isEmpty { Text(verbatim: relative).font(.caption) }
                } footer: {
                    Text(atRoot
                         ? "These files stay on this iPhone, in this app, the same place as Memory. Import adds a file here. Share sends a copy."
                         : "Share sends a copy. Text files can be edited. A file outside this folder can't be opened.")
                }
            }
        }
        .navigationTitle(atRoot ? Text("Files") : Text(verbatim: directory.lastPathComponent))
        .navigationBarTitleDisplayMode(atRoot ? .large : .inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { importing = true } label: { Image(systemName: "square.and.arrow.down") }
                    .accessibilityLabel(Text("Import"))
            }
            ToolbarItem(placement: .automatic) {
                Button { shareURL = directory } label: { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel(Text("Share"))
            }
        }
        .onAppear(perform: reload)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], onCompletion: imported)
        .sheet(item: $shareURL) { ShareSheet(items: [$0]) }
        .sheet(isPresented: $editingPlan) {
            NavigationStack { PlanEditView(app: app, folder: directory) }
        }
        .alert("Couldn't save that file", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(verbatim: notice ?? "") }
        .accessibilityIdentifier(atRoot ? "settings.files" : "files.folder")
    }

    @ViewBuilder private func row(_ entry: AgentFileEntry) -> some View {
        if entry.isDirectory, let url = sandbox.resolve(child(entry.name)) {
            NavigationLink { LocalFilesView(app: app, directory: url) } label: { label(entry) }
        } else if entry.text, let url = sandbox.resolve(child(entry.name)) {
            NavigationLink { TextFileEditor(file: url, relative: child(entry.name), sandbox: sandbox) } label: { label(entry) }
        } else if entry.image, let url = sandbox.resolve(child(entry.name)) {
            NavigationLink { ImageFilePage(file: url) } label: { label(entry) }
                .swipeActions { shareButton(url) }
        } else if let url = sandbox.resolve(child(entry.name)) {
            Button { shareURL = url } label: { label(entry) }
                .swipeActions { shareButton(url) }
        } else {
            label(entry).foregroundStyle(.secondary)
        }
    }

    private func label(_ entry: AgentFileEntry) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.name).foregroundStyle(.primary).lineLimit(1)
                Text(verbatim: entry.detail).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: entry.symbol).foregroundStyle(entry.tint).frame(width: 28)
        }
    }

    private func shareButton(_ url: URL) -> some View {
        Button { shareURL = url } label: { Label("Share", systemImage: "square.and.arrow.up") }
            .tint(.blue)
    }

    private func child(_ name: String) -> String { relative.isEmpty ? name : relative + "/" + name }

    private func reload() {
        guard let url = sandbox.resolve(here) else { entries = []; return }
        let items = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles])) ?? []
        entries = items.compactMap { item in
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            if values?.isSymbolicLink == true, !AgentFiles.contains(item.resolvingSymlinksInPath()) {
                return nil
            }
            let name = item.lastPathComponent
            guard sandbox.resolve(child(name)) != nil else { return nil }
            let directory = values?.isDirectory == true
            return AgentFileEntry(name: name, isDirectory: directory, bytes: values?.fileSize ?? 0)
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func imported(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let folder = FileSandbox(root: directory)
        notice = folder.importFile(from: url, name: url.lastPathComponent)
        reload()
    }
}

private struct AgentFileEntry: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var isDirectory: Bool
    var bytes: Int

    var text: Bool { !isDirectory && FileSandbox.textExtensions.contains((name as NSString).pathExtension.lowercased()) }
    var image: Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return !isDirectory && ["jpg", "jpeg", "png", "heic", "gif", "webp"].contains(ext)
    }
    var symbol: String {
        if isDirectory { return "folder.fill" }
        if image { return "photo" }
        if text { return "doc.text" }
        return "doc"
    }
    var tint: Color {
        if isDirectory { return .blue }
        if image { return .purple }
        if text { return .teal }
        return .secondary
    }
    var detail: String {
        if isDirectory { return String(localized: "Folder") }
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.0f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }
}

/// A text file in the agent directory. Save writes it back; Memory reloads when the file is MEMORY.md.
struct TextFileEditor: View {
    let file: URL
    let relative: String
    let sandbox: FileSandbox
    @State private var text = ""
    @State private var original = ""
    @State private var failure: String?
    @State private var saveError: String?
    @State private var savedNote = false

    var body: some View {
        Group {
            if let failure, original.isEmpty {
                ContentUnavailableView {
                    Label("Can't edit this file", systemImage: "doc")
                } description: {
                    Text(verbatim: failure)
                } actions: {
                    ShareLink(item: file) { Label("Share", systemImage: "square.and.arrow.up") }
                }
            } else {
                TextEditor(text: $text)
                    .font(.body)
                    .padding(Space.s)
                    .scrollContentBackground(.hidden)
                    .background(Palette.background)
            }
        }
        .navigationTitle(Text(verbatim: file.lastPathComponent))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .fontWeight(.semibold)
                    .disabled(text == original)
            }
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: file) { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel(Text("Share"))
            }
        }
        .onAppear(perform: load)
        .alert("Saved", isPresented: $savedNote) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The file is on this iPhone.")
        }
        .alert("Couldn't save", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(verbatim: saveError ?? "") }
    }

    private func load() {
        guard let loaded = sandbox.textFile(relative, limit: 500_000) else {
            failure = String(localized: "This file is too large, or it isn't text. You can still share it.")
            return
        }
        text = loaded
        original = loaded
    }

    private func save() {
        if let error = sandbox.saveUserText(text, to: relative) {
            saveError = error
            return
        }
        original = text
        if file.resolvingSymlinksInPath().path == MemoryStore.shared.file.resolvingSymlinksInPath().path {
            MemoryStore.shared.reload()
        }
        Haptics.success()
        savedNote = true
    }
}

struct ImageFilePage: View {
    let file: URL

    var body: some View {
        VStack(spacing: Space.l) {
            if let image = UIImage(contentsOfFile: file.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, Space.l)
                    .accessibilityLabel(Text("Image"))
            } else {
                ContentUnavailableView {
                    Label("Can't show this image", systemImage: "photo")
                } description: {
                    Text("You can still share the file.")
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.grouped)
        .navigationTitle(Text(verbatim: file.lastPathComponent))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: file) { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel(Text("Share"))
            }
        }
    }
}
