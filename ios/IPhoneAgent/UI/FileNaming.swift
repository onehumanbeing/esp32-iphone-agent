import SwiftUI

/// What the name field in the Files tab is for.
enum FileNaming: Equatable {
    case folder, note
    case rename(String)  // the current name

    var title: Text {
        switch self {
        case .folder: Text("New Folder")
        case .note: Text("New Note")
        case .rename: Text("Rename")
        }
    }
}
