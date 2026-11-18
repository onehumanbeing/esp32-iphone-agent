import SwiftUI

/// One row in the Files tab. Always a single stack, so the list does not rebuild every row when the kind changes.
/// Our own formats open their own page: MEMORY.md the Memory page, a .intent its preview, Markdown as it reads.
struct AgentFileRow: View {
    @ObservedObject var app: AppModel
    let entry: AgentFileEntry
    let url: URL?
    let relative: String
    let sandbox: FileSandbox
    var share: (URL) -> Void
    var rename: (AgentFileEntry) -> Void
    var delete: (AgentFileEntry) -> Void

    /// The swipe and context actions sit on the row's own top-level view: inside a stack they did not show
    /// (Henry 2026-11-18: result folders could not be deleted).
    var body: some View {
        Group {
            if let url {
                link(url)
                    .swipeActions {
                        if changeable {
                            Button("Delete", systemImage: "trash", role: .destructive, action: deleteThis)
                        }
                        if !entry.isDirectory {
                            Button("Share", systemImage: "square.and.arrow.up", action: shareThis).tint(.blue)
                        }
                    }
                    .contextMenu {
                        if !entry.isDirectory {
                            Button("Share", systemImage: "square.and.arrow.up", action: shareThis)
                        }
                        if changeable {
                            Button("Rename", systemImage: "pencil", action: renameThis)
                            Button("Delete", systemImage: "trash", role: .destructive, action: deleteThis)
                        }
                    }
            } else {
                AgentFileLabel(entry: entry).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func link(_ url: URL) -> some View {
        if entry.isDirectory {
            NavigationLink { LocalFilesView(app: app, directory: url) } label: { AgentFileLabel(entry: entry) }
        } else if entry.memory {
            NavigationLink { MemoryView(store: MemoryStore.shared) } label: { AgentFileLabel(entry: entry) }
        } else if entry.intent {
            NavigationLink { IntentFilePage(app: app, file: url) } label: { IntentFileLabel(entry: entry, file: url) }
        } else if entry.markdown, PlanCache.holds(relative) {
            NavigationLink {
                PlanFilePage(app: app, file: url, relative: relative, sandbox: sandbox)
            } label: { AgentFileLabel(entry: entry) }
        } else if entry.markdown {
            NavigationLink {
                MarkdownFilePage(file: url, relative: relative, sandbox: sandbox)
            } label: { AgentFileLabel(entry: entry) }
        } else if entry.text {
            NavigationLink {
                TextFileEditor(file: url, relative: relative, sandbox: sandbox)
            } label: { AgentFileLabel(entry: entry) }
        } else if entry.image {
            NavigationLink { ImageFilePage(file: url, relative: relative, sandbox: sandbox) } label: { AgentFileLabel(entry: entry) }
        } else {
            Button(action: shareThis) { AgentFileLabel(entry: entry) }
        }
    }

    private var changeable: Bool { FileSandbox.canChange(relative) }
    private func shareThis() { if let url { share(url) } }
    private func renameThis() { rename(entry) }
    private func deleteThis() { delete(entry) }
}
