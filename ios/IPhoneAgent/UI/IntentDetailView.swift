import SwiftUI

/// An intent: run it, its stats (last run, success rate, average time), its words, edit and delete.
struct IntentDetailView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var intents: IntentStore
    let id: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var exporting = false

    var body: some View {
        if let item = intents.item(id) {
            List {
                Section {
                    VStack(spacing: Space.m) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 72, height: 72)
                            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(IntentTint.color(item.color)))
                        Text(verbatim: item.name).font(.title2.bold()).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
                Section {
                    stat("Last run", item.runs.last.map { ($0.ok ? "✓ " : "✗ ") + $0.date.formatted(.relative(presentation: .named)) })
                    stat("Success rate", item.successRate.map { $0.formatted(.percent.precision(.fractionLength(0))) })
                    stat("Average time", item.averageSeconds?.durationText)
                    stat("Runs", item.runs.isEmpty ? nil : "\(item.runs.count)")
                    if let steps = item.steps, !steps.isEmpty {
                        stat("Recorded steps", "\(steps.count)")
                    }
                }
                Section("Instruction") { Text(verbatim: item.prompt) }
                ScriptSection(intents: intents, item: item)
                if !item.checklist.isEmpty {
                    Section("Checklist") {
                        ForEach(item.checklist, id: \.self) { h in
                            Label { Text(verbatim: h) } icon: { Image(systemName: "checkmark.circle").foregroundStyle(Palette.ok) }
                        }
                    }
                }
                if let run = item.learnedFrom {  // IntentLearner: the steps came from a run that worked
                    Section {
                        Button { app.openReview(run: run) } label: {
                            Label("Steps learned from the run \(run)", systemImage: "wand.and.stars")
                        }
                        if item.previousSteps != nil {
                            Button { intents.undoLearned(item.id) } label: {
                                Label("Undo: Use the Previous Steps", systemImage: "arrow.uturn.backward")
                            }
                        }
                    } footer: {
                        Text("The recorded steps missed, so the steps of a run that worked replaced them.")
                    }
                }
                Section {
                    Button { edit(item) } label: { Label("Edit", systemImage: "slider.horizontal.3") }
                    if item.refRecording != nil {  // recorded before recordings were runs
                        Button { app.review = ReviewDraft(intent: item) } label: {
                            Label("Review Demonstration", systemImage: "record.circle")
                        }
                    } else if let demo = item.refRun, app.runs.run(demo)?.isDemo == true {
                        Button { app.openReview(run: demo) } label: { Label("Review Demonstration", systemImage: "record.circle") }
                    }
                    if let last = item.runs.last?.run ?? item.refRun {
                        Button { app.openReview(run: last) } label: { Label("Review Last Run", systemImage: "play.rectangle") }
                    }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete Intent", systemImage: "trash") }
                }
            }
            .navigationTitle(Text(verbatim: item.name))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { exporting = true } label: { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel(Text("Export"))
                }
            }
            .sheet(isPresented: $exporting) { IntentExportSheet(app: app, intents: [item]) }
            .safeAreaInset(edge: .bottom) {
                BottomBar {
                    Button {
                        Haptics.start()
                        dismiss()
                        Task { await app.run(item.prompt, intent: item) }
                    } label: { Label("Run", systemImage: "play.fill") }
                    .buttonStyle(BigButton())
                    .disabled(app.agent.running || app.startingAgent || app.recorder.busy)
                }
            }
            .confirmationDialog("Delete this intent?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { intents.delete(id); dismiss() }
            }
        } else {
            ContentUnavailableView("Intent deleted", systemImage: "trash")
        }
    }

    private func stat(_ title: LocalizedStringKey, _ value: String?) -> some View {
        LabeledContent(title) { Text(verbatim: value ?? "–").monospacedDigit() }
    }

    /// The same editor as a run's review: with its last run's steps if it has one.
    private func edit(_ item: SavedTask) {
        let ref = (item.runs.last?.run ?? item.refRun).flatMap { app.runs.run($0) }
        app.review = ref.map { ReviewDraft(run: $0, intent: item) } ?? ReviewDraft(intent: item)
    }
}
