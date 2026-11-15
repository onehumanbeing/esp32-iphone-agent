import SwiftUI

/// The line under the file list: at the top it says these are the app's own files, beside Memory.
struct FilesLocationFooter: View {
    var atRoot: Bool

    var body: some View {
        if atRoot {
            Text("These files stay on this iPhone, in this app, the same place as Memory. Import adds a file here. Share sends a copy.")
        } else {
            Text("Share sends a copy. Text files can be edited. A file outside this folder can't be opened.")
        }
    }
}
