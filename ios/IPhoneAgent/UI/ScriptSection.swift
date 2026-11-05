import SwiftUI

/// An intent's steps as a script (IntentDetailView): moves run without the model, AI steps hand one part to the
/// model, Read / Copy / Ask me add notebook and hand-off steps, and "Repeat until" runs the script again until a
/// condition holds on screen.
struct ScriptSection: View {
    @ObservedObject var intents: IntentStore
    let item: SavedTask
    @State private var adding: Kind?
    @State private var text = ""

    enum Kind: String, Identifiable {
        case ai, read, manual, until
        var id: String { rawValue }
    }

    var body: some View {
        Section {
            ForEach(Array((item.steps ?? []).enumerated()), id: \.offset) { i, step in
                let act = step.object ?? [:]
                Label { Text(verbatim: describe(act)).lineLimit(2) } icon: { Image(systemName: symbol(act)) }
                    .swipeActions {
                        Button(role: .destructive) { edit { $0.remove(at: i) } } label: { Label("Delete", systemImage: "trash") }
                        if Replay.replayable.contains(act["action"]?.str ?? "") {
                            Button { edit { $0[i] = Self.aiStep("Do this step: " + StepText.title(act)) } } label: {
                                Label("Let AI do it", systemImage: "sparkles")
                            }.tint(.purple)
                        }
                    }
            }
            Menu {
                Button("AI step", systemImage: "sparkles") { text = ""; adding = .ai }
                Button("Read from the screen", systemImage: "doc.text.viewfinder") { text = ""; adding = .read }
                Button("Copy the notebook", systemImage: "doc.on.clipboard") { edit { $0.append(Self.step(["action": .str("write")])) } }
                Button("Ask me to do a step", systemImage: "hand.raised") { text = ""; adding = .manual }
            } label: { Label("Add step", systemImage: "plus") }
            Button { text = item.until ?? ""; adding = .until } label: {
                LabeledContent("Repeat until") { Text(verbatim: item.until ?? "–").lineLimit(1) }
            }
            if item.until != nil {
                Stepper(value: Binding(get: { item.maxLoops ?? 5 }, set: { v in save { $0.maxLoops = v } }), in: 1...20) {
                    Text("At most \(item.maxLoops ?? 5) rounds")
                }
            }
        } header: {
            Text("Steps")
        } footer: {
            Text("Moves run without the AI while the screen matches; swipe a step to let the AI do it instead. With Repeat until, the steps run again until the condition is true on screen.")
        }
        .alert(title, isPresented: Binding(get: { adding != nil }, set: { if !$0 { adding = nil } })) {
            TextField(placeholder, text: $text)
            Button("Save") { add() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var title: LocalizedStringKey {
        switch adding {
        case .ai: "AI step"
        case .read: "Read from the screen"
        case .manual: "Ask me to do a step"
        default: "Repeat until"
        }
    }

    private var placeholder: LocalizedStringKey {
        switch adding {
        case .ai: "e.g. Open the next favorites folder"
        case .read: "e.g. video titles"
        case .manual: "e.g. Log in"
        default: "e.g. the list shows its end"
        }
    }

    private func add() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch adding {
        case .ai where !t.isEmpty: edit { $0.append(Self.aiStep(t)) }
        case .read: edit { $0.append(Self.step(["action": .str("read"), "what": .str(t)])) }
        case .manual where !t.isEmpty: edit { $0.append(Self.step(["action": .str("manual"), "reason": .str(t)])) }
        case .until: save { $0.until = t.isEmpty ? nil : t }
        default: break
        }
        adding = nil
    }

    static func step(_ action: JObject) -> RecordedStep { RecordedStep(action: action, sure: true, frame: nil) }
    static func aiStep(_ goal: String) -> RecordedStep { step(["action": .str("ai"), "goal": .str(goal)]) }

    private func edit(_ change: (inout [RecordedStep]) -> Void) { save { change(&$0.steps[default: []]) } }

    private func save(_ change: (inout SavedTask) -> Void) {
        var copy = item
        change(&copy)
        intents.upsert(copy)
    }

    private func describe(_ act: JObject) -> String {
        switch act["action"]?.str {
        case "ai": return String(localized: "AI: \(act["goal"]?.str ?? "")")
        case "manual": return String(localized: "You: \(act["reason"]?.str ?? "")")
        default: return StepText.title(act)
        }
    }

    private func symbol(_ act: JObject) -> String {
        switch act["action"]?.str {
        case "ai": "sparkles"
        case "manual": "hand.raised"
        case let name: StepText.symbol(name)
        }
    }
}

private extension Optional where Wrapped == [RecordedStep] {
    subscript(default value: [RecordedStep]) -> [RecordedStep] {
        get { self ?? value }
        set { self = newValue }
    }
}
