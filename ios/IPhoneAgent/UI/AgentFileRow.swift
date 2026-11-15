import SwiftUI

/// One row in Settings › Files. Always a single stack, so the list does not rebuild every row when the kind changes.
struct AgentFileRow: View {
    @ObservedObject var app: AppModel
    let entry: AgentFileEntry
    let url: URL?
    let relative: String
    let sandbox: FileSandbox
    var share: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let url {
                if entry.isDirectory {
                    NavigationLink { LocalFilesView(app: app, directory: url) } label: { AgentFileLabel(entry: entry) }
                } else if entry.text {
                    NavigationLink {
                        TextFileEditor(file: url, relative: relative, sandbox: sandbox)
                    } label: { AgentFileLabel(entry: entry) }
                } else if entry.image {
                    NavigationLink { ImageFilePage(file: url) } label: { AgentFileLabel(entry: entry) }
                        .swipeActions { Button("Share", systemImage: "square.and.arrow.up", action: shareThis).tint(.blue) }
                } else {
                    Button(action: shareThis) { AgentFileLabel(entry: entry) }
                        .swipeActions { Button("Share", systemImage: "square.and.arrow.up", action: shareThis).tint(.blue) }
                }
            } else {
                AgentFileLabel(entry: entry).foregroundStyle(.secondary)
            }
        }
    }

    private func shareThis() {
        guard let url else { return }
        share(url)
    }
}
