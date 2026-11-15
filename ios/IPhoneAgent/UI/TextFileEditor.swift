import SwiftUI

/// A whole text file from the agent directory. A file is a full editing surface, so this is a text view rather than a field.
struct TextFileEditor: View {
    let file: URL
    let relative: String
    let sandbox: FileSandbox
    @State private var text = ""
    @State private var original = ""
    @State private var failure: String?
    @State private var saveError = ""
    @State private var showingSaveError = false
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
                Button("Save", action: save)
                    .bold()
                    .disabled(text == original)
            }
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: file) { Label("Share", systemImage: "square.and.arrow.up") }
                    .labelStyle(.iconOnly)
            }
        }
        .task { await load() }
        .alert("Saved", isPresented: $savedNote) {
        } message: {
            Text("The file is on this iPhone.")
        }
        .alert("Couldn't save", isPresented: $showingSaveError) {
        } message: {
            Text(verbatim: saveError)
        }
    }

    private func load() async {
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
            showingSaveError = true
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
