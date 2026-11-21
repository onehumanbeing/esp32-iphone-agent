import SwiftUI

/// Opens the plan chat when the folder is inside this app's files, and says so when it is not.
struct PlanEditView: View {
    @ObservedObject var app: AppModel
    let folder: URL
    var draft: ReviewDraft?

    var body: some View {
        if let sandbox = FileSandbox.insideAgentData(folder) {
            PlanEditChat(app: app, folder: folder, draft: draft, sandbox: sandbox)
        } else {
            UnavailableView("This folder can't be edited", systemImage: "folder",
                       description: Text("Plans stay inside this app's files."))
        }
    }
}
