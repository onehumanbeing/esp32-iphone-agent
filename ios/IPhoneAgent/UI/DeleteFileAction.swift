import SwiftUI

/// Delete from inside an open file or folder: a trash button in the toolbar, asked once, then back to the list
/// (Henry 2026-11-18: an opened result file had no way to delete it). Shown only for what the user may change.
struct DeleteFileAction: ViewModifier {
    let relative: String?
    let sandbox: FileSandbox?
    var folder = false
    var asked: Binding<Bool>?  // a page with its own ⋯ menu puts Delete there (one menu, not two)
    @Environment(\.dismiss) private var dismiss
    @State private var ownAsking = false
    private var asking: Binding<Bool> { asked ?? $ownAsking }
    @State private var failure: String?

    func body(content: Content) -> some View {
        if let relative, let sandbox, FileSandbox.canChange(relative) {
            content
                .toolbar {
                    if asked == nil {
                        ToolbarItem(placement: .secondaryAction) {
                            Button(folder ? "Delete Folder" : "Delete", systemImage: "trash", role: .destructive) { ownAsking = true }
                        }
                    }
                }
                .confirmationDialog(Text(verbatim: (relative as NSString).lastPathComponent), isPresented: asking,
                                    titleVisibility: .visible) {
                    Button("Delete", role: .destructive) {
                        if let error = sandbox.remove(relative) { failure = error.message } else { dismiss() }
                    }
                } message: {
                    Text(folder ? "The folder and everything in it are deleted from this iPhone."
                         : "The file is deleted from this iPhone.")
                }
                .alert("Couldn't do that", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                } message: {
                    Text(verbatim: failure ?? "")
                }
        } else {
            content
        }
    }
}

extension View {
    func deletable(_ relative: String?, in sandbox: FileSandbox?, folder: Bool = false, asked: Binding<Bool>? = nil) -> some View {
        modifier(DeleteFileAction(relative: relative, sandbox: sandbox, folder: folder, asked: asked))
    }
}
