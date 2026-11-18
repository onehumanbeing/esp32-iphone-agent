import MarkdownUI
import SwiftUI

/// A Markdown file from the agent's files as it reads: text, tables and its images. Edit opens the text; Export shares
/// the whole folder it sits in (a result is a folder: README.md and its images) as one .zip.
struct MarkdownFilePage: View {
    let file: URL
    let relative: String
    let sandbox: FileSandbox
    @State private var text = ""
    @State private var zip: URL?
    @State private var exporting = false
    @State private var exportFailed = false

    var body: some View {
        ScrollView {
            Markdown(text, imageBaseURL: file.deletingLastPathComponent())
                .markdownImageProvider(LocalImageProvider())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.l)
        }
        .background(Palette.grouped)
        .navigationTitle(Text(verbatim: file.lastPathComponent))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    TextFileEditor(file: file, relative: relative, sandbox: sandbox)
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
            }
            ToolbarItem(placement: .automatic) {
                Button("Export Folder", systemImage: "square.and.arrow.up", action: export)
                    .disabled(exporting)
            }
        }
        .deletable(relative, in: sandbox)
        .onAppear(perform: load)  // again after Edit
        .sheet(item: $zip) { ShareSheet(items: [$0]) }
        .alert("Couldn't export this folder", isPresented: $exportFailed) {}
    }

    private func load() {
        text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }

    private func export() {
        let folder = file.deletingLastPathComponent()
        exporting = true
        Task {
            let made = await Task.detached(priority: .userInitiated) { FolderZip.make(folder) }.value
            exporting = false
            zip = made
            exportFailed = made == nil
        }
    }
}
