import SwiftUI

/// The intent's saved plan (PlanCache): what the next run starts from without waiting for the planner, and a way
/// to drop it so the next run plans afresh.
struct IntentPlanSection: View {
    @ObservedObject var cache: PlanCache
    let item: SavedTask
    @State private var showing = false

    var body: some View {
        if let entry = cache.entry(for: item) {
            Section {
                DisclosureGroup(isExpanded: $showing) {
                    Text(verbatim: entry.plan).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                } label: {
                    LabeledContent("Saved Plan") {
                        Text(verbatim: entry.saved.formatted(.relative(presentation: .named)))
                    }
                }
                Button("Forget Saved Plan", role: .destructive) { cache.forget(item.id) }
            } footer: {
                Text(entry.edited ? "Your edited plan: runs start from it until the instruction changes. It is in Files › Plans." : "Runs start from this plan while the instruction is unchanged, without waiting for a new one. It is dropped when you edit the instruction, a run with it fails, or after 7 days. Edit it in Files › Plans.")
            }
        }
    }
}
