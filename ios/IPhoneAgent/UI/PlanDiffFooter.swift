import SwiftUI

/// What Save will do, or why it is unavailable.
struct PlanDiffFooter: View {
    var blocking: Bool

    var body: some View {
        if blocking {
            Text("This can't be saved until the plan is one the app can run, inside this folder.")
        } else {
            Text("Saving updates this recording's plan. The original screens stay in the folder.")
        }
    }
}
