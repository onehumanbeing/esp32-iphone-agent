import SwiftUI

/// The intent's saved plan (PlanCache): what the next run starts from without waiting for the planner, a way to
/// drop it so the next run plans afresh, and Reuse Plan (off: never used, never saved for this intent).
struct IntentPlanSection: View {
    @ObservedObject var cache: PlanCache
    @ObservedObject var intents: IntentStore
    let item: SavedTask
    @State private var showing = false

    var body: some View {
        let entry = item.reusesPlan ? cache.entry(for: item) : nil
        Section {
            Toggle("Reuse Plan", isOn: Binding(get: { item.reusesPlan },
                                               set: { on in var copy = item; copy.planReuse = on ? nil : false; intents.upsert(copy) }))
            if let entry {
                DisclosureGroup(isExpanded: $showing) {
                    Text(verbatim: entry.plan).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                } label: {
                    LabeledContent("Saved Plan") {
                        Text(verbatim: entry.saved.formatted(.relative(presentation: .named)))
                    }
                }
                Button("Forget Saved Plan", role: .destructive) { cache.forget(item.id) }
            }
        } footer: {
            if !item.reusesPlan {
                Text("Off: every run plans afresh, and no plan is saved for this intent.")
            } else if let entry {
                Text(entry.edited ? "Your edited plan: runs start from it until the instruction changes. It is in Files › Plans." : "Runs start from this plan while the instruction is unchanged, without waiting for a new one. It is dropped when you edit the instruction, a run with it fails, or after 7 days. Edit it in Files › Plans.")
            } else {
                Text("After a run, AI checks whether its plan is worth reusing. If it is, the next run starts from it without waiting for a new one.")
            }
        }
    }
}
