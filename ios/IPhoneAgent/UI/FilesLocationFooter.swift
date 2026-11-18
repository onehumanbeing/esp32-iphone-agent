import SwiftUI

/// The line under the file list: at the top it says what lives here; inside a folder, how to change things.
struct FilesLocationFooter: View {
    var atRoot: Bool

    var body: some View {
        if atRoot {
            Text("These files stay on this iPhone, in this app. Memory holds what the agent remembers and the results it saves. Use ⋯ to add a folder or note, import a file or export a folder.")
        } else {
            Text("Swipe left to delete. Touch and hold to rename or share.")
        }
    }
}
