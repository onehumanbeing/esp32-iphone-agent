import SwiftUI

/// A line under the running task on Home: words typed here join the run at its next round (AppModel.steer).
struct SteerField: View {
    @ObservedObject var app: AppModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Space.s) {
            TextField("Add to the task", text: $text)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit(send)
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title3) }
                    .accessibilityLabel(Text("Add to the task"))
            }
        }
        .font(.subheadline)
    }

    private func send() {
        if app.steer(text, from: "home") {
            Haptics.tick()
            app.toast = AppModel.Toast(text: String(localized: "Added. The agent reads it at its next step."))
        }
        text = ""
        focused = false
    }
}

/// From the Dynamic Island's New Task button (iphoneagent://quick) or the Control Center control: type a task or
/// pick an intent. While a run goes, what is typed is added to it instead.
struct QuickAskSheet: View {
    @ObservedObject var app: AppModel
    @ObservedObject var intents: IntentStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    private var running: Bool { app.agent.running }

    /// The most run first, at most 6.
    private var picks: [SavedTask] { Array(intents.items.sorted { $0.runs.count > $1.runs.count }.prefix(6)) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField(running ? "Add to the running task" : "What should I do?", text: $text, axis: .vertical)
                        .lineLimit(2...5)
                        .focused($focused)
                        .submitLabel(.send)
                        .onSubmit(send)
                } footer: {
                    if running { Text(verbatim: app.agent.task).lineLimit(2) }
                }
                if !running && !picks.isEmpty {
                    Section("Intents") {
                        ForEach(picks) { item in
                            Button { start(item.prompt, item) } label: {
                                Label { Text(verbatim: item.name) } icon: {
                                    Image(systemName: item.symbol).foregroundStyle(IntentTint.color(item.color))
                                }
                            }
                            .disabled(item.unfilled)
                        }
                    }
                }
            }
            .navigationTitle(running ? "Add to the Task" : "New Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(running ? "Add" : "Run", action: send).fontWeight(.semibold)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func send() {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        if running {
            app.steer(words, from: "quick")
            dismiss()
            Task { _ = await app.backToPrevious() }  // the run holds while this app is in front
        } else {
            start(words, nil)
        }
    }

    private func start(_ task: String, _ intent: SavedTask?) {
        Haptics.start()
        dismiss()
        Task { await app.runHere(task, intent: intent) }
    }
}
