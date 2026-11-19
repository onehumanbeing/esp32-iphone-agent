import SwiftUI

/// Review: what the run saved in the agent's files (RunOutputs), one line like the Result card; a tap opens the one
/// thing saved, or lists several, each opening in a sheet. Not shown when the run saved nothing (or it was deleted since).
struct RunOutputsCard: View {
    @ObservedObject var app: AppModel
    let run: Run
    @State private var items: [String] = []
    @State private var open: RunOutput?

    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {  // a container even when empty, so the task runs
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Button(action: headerTapped) {
                        HStack(spacing: Space.xs) {
                            Image(systemName: items.count > 1 && expanded ? "chevron.down" : "chevron.right")
                                .font(.caption.weight(.semibold))
                            Text("Files").font(.subheadline.weight(.semibold))
                            Text(verbatim: names).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if expanded {
                        ForEach(items, id: \.self) { item in
                            Button { open = RunOutput(item: item) } label: { RunOutputLabel(item: item) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, Space.m).padding(.vertical, Space.s)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, Space.xl).padding(.bottom, Space.s)
            }
        }
        .task(id: run.id) { items = RunOutputs.items(run) }
        .sheet(item: $open) { output in
            NavigationStack {
                RunOutputPage(app: app, item: output.item)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { open = nil } } }
            }
        }
    }

    /// "orders · notes.md": what the run saved, by name.
    private var names: String { items.map { ($0 as NSString).lastPathComponent }.joined(separator: " · ") }

    /// One thing saved: open it. Several: show them.
    private func headerTapped() {
        if items.count == 1 { open = RunOutput(item: items[0]) } else { withAnimation(.snappy) { expanded.toggle() } }
    }
}

struct RunOutput: Identifiable {
    var id: String { item }
    let item: String  // relative to Documents/memory
}

/// A result folder or a file the agent saved, with its own symbol.
struct RunOutputLabel: View {
    let item: String

    var body: some View {
        let url = MemoryFiles.root.appendingPathComponent(item)
        let folder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        let entry = AgentFileEntry(name: url.lastPathComponent, isDirectory: folder, bytes: 0, relative: "memory/" + item)
        HStack(spacing: Space.s) {
            Image(systemName: folder ? "tray.full" : entry.symbol).foregroundStyle(folder ? Color.accentColor : entry.tint)
                .frame(width: 24)
            Text(verbatim: url.lastPathComponent).lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .font(.subheadline)
        .frame(minHeight: 32)
        .contentShape(Rectangle())
    }
}

/// Opens what a run saved: a folder as its file list, Markdown read as it renders, an image, else the folder it is in.
struct RunOutputPage: View {
    @ObservedObject var app: AppModel
    let item: String

    var body: some View {
        let url = MemoryFiles.root.appendingPathComponent(item)
        let relative = "memory/" + item
        let entry = AgentFileEntry(name: url.lastPathComponent, isDirectory: false, bytes: 0, relative: relative)
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            LocalFilesView(app: app, directory: url, showsOrigin: false)
        } else if entry.markdown {
            MarkdownFilePage(file: url, relative: relative, sandbox: FileSandbox(root: AgentFiles.root))
        } else if entry.image {
            ImageFilePage(file: url)
        } else {
            LocalFilesView(app: app, directory: url.deletingLastPathComponent(), showsOrigin: false)
        }
    }
}
