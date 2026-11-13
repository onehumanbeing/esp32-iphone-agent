import SwiftUI

/// What the model proposes after the instruction changed (Replan): the title, each step that changes, the checklist.
/// Apply writes it; Keep As Is leaves the intent as the user left it.
struct ReplanSheet: View {
    @ObservedObject var intents: IntentStore
    let id: UUID
    let proposal: Replan.Proposal
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            if let item = intents.item(id) {
                let steps = item.steps ?? []
                List {
                    Section("Name") {
                        if proposal.name.isEmpty || proposal.name == item.name {
                            Text(verbatim: item.name)
                        } else {
                            Text(verbatim: item.name).strikethrough().foregroundStyle(.secondary)
                            Text(verbatim: proposal.name)
                        }
                    }
                    Section {
                        ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                            let edit = proposal.edits[safe: i] ?? .keep
                            Label { Text(verbatim: Replan.describe(edit, step: step)).lineLimit(3) } icon: {
                                Image(systemName: symbol(edit)).foregroundStyle(edit == .keep ? Color.secondary : Color.orange)
                            }
                            .foregroundStyle(edit == .keep ? .secondary : .primary)
                        }
                    } header: { Text("Steps") } footer: {
                        Text(proposal.changes == 0 ? "The steps still fit the new instruction." : "\(proposal.changes) steps change.")
                    }
                    if !proposal.hints.isEmpty || !item.checklist.isEmpty {
                        Section("Checklist") {
                            ForEach(proposal.hints, id: \.self) { Text(verbatim: $0) }
                            ForEach(item.checklist.filter { !proposal.hints.contains($0) }, id: \.self) {
                                Text(verbatim: $0).strikethrough().foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .navigationTitle("Check the Steps")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Keep As Is") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Apply") { apply(item); dismiss() }.fontWeight(.semibold)
                    }
                }
            }
        }
    }

    private func symbol(_ edit: Replan.Edit) -> String {
        switch edit {
        case .keep: "checkmark"
        case .drop: "minus.circle"
        case .type: "keyboard"
        case .ai: "sparkles"
        }
    }

    private func apply(_ item: SavedTask) {
        var copy = item
        if !proposal.name.isEmpty { copy.name = proposal.name }
        if let steps = item.steps { copy.steps = Replan.apply(proposal.edits, to: steps) }
        copy.hints = proposal.hints
        intents.upsert(copy)
    }
}
