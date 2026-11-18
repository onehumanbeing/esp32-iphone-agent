import SwiftUI

/// The one ⋯ button of the Files tab: make something here, bring a file in, or send the folder out.
struct FilesMenu: View {
    var newFolder: () -> Void
    var newNote: () -> Void
    var importFile: () -> Void
    var export: () -> Void
    var delete: (() -> Void)? = nil  // inside a folder that may be deleted

    var body: some View {
        Menu {
            Section {
                Button("New Folder", systemImage: "folder.badge.plus", action: newFolder)
                Button("New Note", systemImage: "square.and.pencil", action: newNote)
            }
            Section {
                Button("Import", systemImage: "square.and.arrow.down", action: importFile)
                Button("Export Folder", systemImage: "square.and.arrow.up", action: export)
            }
            if let delete {
                Section {
                    Button("Delete Folder", systemImage: "trash", role: .destructive, action: delete)
                }
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
    }
}
