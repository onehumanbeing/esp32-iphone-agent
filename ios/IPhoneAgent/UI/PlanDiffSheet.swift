import SwiftUI

/// The edited plan beside the one it replaced. Nothing is kept until Save.
struct PlanDiffSheet: View {
    let proposal: PlanProposal
    var save: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    PlanReviewStatus(passed: proposal.verdictOK)
                    ForEach(proposal.notes) { note in
                        Text(verbatim: note.text).font(.subheadline)
                    }
                } header: {
                    Text("Review")
                } footer: {
                    PlanDiffFooter(blocking: proposal.blocking)
                }
                Section("Changes") {
                    if proposal.diff.isEmpty {
                        Text("No visible change").foregroundStyle(.secondary)
                    } else {
                        ForEach(proposal.diff) { row in
                            PlanDiffLine(row: row)
                        }
                    }
                }
            }
            .navigationTitle("Review changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Keep Editing", action: keepEditing) }
                ToolbarItem(placement: .confirmationAction) {
                    if proposal.verdictOK {
                        Button("Save plan", action: save).bold().disabled(proposal.blocking)
                    } else {
                        Button("Save anyway", action: save).bold().disabled(proposal.blocking)
                    }
                }
            }
        }
    }

    private func keepEditing() { dismiss() }
}
