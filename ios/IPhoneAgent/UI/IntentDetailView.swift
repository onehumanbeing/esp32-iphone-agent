import SwiftUI

/// An intent: run it, its stats (last run, success rate, average time), its words, edit and delete.
struct IntentDetailView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var intents: IntentStore
    let id: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var exporting = false
    @State private var draft: String?  // the instruction while it is being typed
    @FocusState private var typing: Bool
    @State private var selection: Any?  // a TextSelection (iOS 18); typed Any so the view builds on iOS 16
    @State private var checking = false  // Replan running after an edit
    @State private var proposal: Replan.Proposal?
    @State private var renaming: String?  // the name while the rename alert is open

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
                        Button { renaming = item.name } label: {
                            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                                Text(verbatim: item.name).font(.title2.bold()).multilineTextAlignment(.center)
                                Image(systemName: "pencil").font(.body.weight(.semibold)).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(Text("Rename Intent"))
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
                IntentRunsSection(app: app, item: item)
                IntentPlanSection(cache: app.planCache, intents: intents, item: item)
                Section {
                    // Edited in place (Henry 2026-11-13): tap the words and type; the first [blank] is selected, so
                    // typing replaces it. Saved when the keyboard goes away or the page closes.
                    instructionField(item)
                        .focused($typing)
                        .onValueChange(of: typing) { _, on in on ? selectBlank(item) : savePrompt(item) }
                    // Follows the words ("Call …" turns it on) until switched by hand; on: always the call routine.
                    Toggle(isOn: Binding(get: { Calls.isCall(draft ?? item.prompt, kind: item.kind) },
                                         set: { on in var copy = item; copy.kind = on ? "call" : "task"; intents.upsert(copy) })) {
                        HStack(spacing: Space.s) { Text("Phone call"); BetaBadge() }
                    }
                } header: { Text("Instruction") } footer: {
                    if checking {
                        Label("Checking the steps against the new instruction…", systemImage: "sparkles")
                    } else if IntentStore.unfilled(draft ?? item.prompt) {
                        Text("Tap the instruction and fill in the parts in [brackets], such as who to text or call, before running it.")
                    } else {
                        Text("Phone call: the agent dials, speaks with Live Speech and listens with Live Captions. On when the instruction starts with Call.")
                    }
                }
                ScriptSection(intents: intents, item: item)
                if !item.checklist.isEmpty {
                    Section("Checklist") {
                        ForEach(item.checklist, id: \.self) { h in
                            Label { Text(verbatim: h) } icon: { Image(systemName: "checkmark.circle").foregroundStyle(Palette.ok) }
                        }
                        .onDelete { rows in  // a lesson a run brought that does not hold
                            var copy = item
                            copy.hints = item.checklist.enumerated().filter { !rows.contains($0.offset) }.map(\.element)
                            intents.upsert(copy)
                        }
                    }
                }
                if let run = item.learnedFrom {  // IntentLearner: the steps came from a run (that worked, or not: demoted)
                    Section {
                        Button { app.openReview(run: run) } label: {
                            Label("Steps learned from the run \(run)", systemImage: "wand.and.stars")
                        }
                        Button { intents.undoLearned(item.id) } label: {
                            Label("Undo: Use the Previous Steps", systemImage: "arrow.uturn.backward")
                        }
                    } footer: {
                        if item.runs.last(where: { $0.run == run })?.ok == false {
                            Text("Some saved steps missed in that run, which did not finish: taps nothing names were removed, the others are now AI steps.")
                        } else {
                            Text("The AI did part of this task itself and the run worked, so that run's steps are now the saved steps.")
                        }
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
            .onAppear { app.planCache.reload() }  // Files › Plans may have changed
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if typing {
                        Button("Done") { typing = false }.fontWeight(.semibold)
                    } else {
                        Button { exporting = true } label: { Image(systemName: "square.and.arrow.up") }
                            .accessibilityLabel(Text("Export"))
                    }
                }
            }
            .sheet(isPresented: $exporting) { IntentExportSheet(app: app, intents: [item]) }
            .sheet(isPresented: Binding(get: { proposal != nil }, set: { if !$0 { proposal = nil } })) {
                if let proposal { ReplanSheet(intents: intents, id: id, proposal: proposal) }
            }
            .safeAreaInset(edge: .bottom) {
                BottomBar {
                    Button {
                        Haptics.start()
                        dismiss()
                        Task { await app.run(item.prompt, intent: item) }
                    } label: { Label("Run", systemImage: "play.fill") }
                    .buttonStyle(BigButton())
                    .disabled(app.agent.running || app.startingAgent || app.recorder.busy || item.unfilled || typing)
                }
            }
            .onDisappear { if draft != nil { savePrompt(item) } }
            .alert("Rename Intent", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: Binding(get: { renaming ?? "" }, set: { renaming = $0 }))
                Button("Cancel", role: .cancel) {}
                Button("Save") { rename(item) }
            }
            .confirmationDialog("Delete this intent?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { intents.delete(id); dismiss() }
            }
        } else {
            UnavailableView("Intent deleted", systemImage: "trash")
        }
    }

    private func stat(_ title: LocalizedStringKey, _ value: String?) -> some View {
        LabeledContent(title) { Text(verbatim: value ?? "–").monospacedDigit() }
    }

    /// iOS 16 has no text selection: the field opens with the caret at the end instead of the blank selected.
    @ViewBuilder private func instructionField(_ item: SavedTask) -> some View {
        let text = Binding(get: { draft ?? item.prompt }, set: { draft = $0 })
        if #available(iOS 18.0, *) {
            TextField("Instruction", text: text,
                      selection: Binding(get: { selection as? TextSelection }, set: { selection = $0 }), axis: .vertical)
        } else {
            TextField("Instruction", text: text, axis: .vertical)
        }
    }

    /// The first template blank ("[who]") selected, so what is typed replaces it.
    private func selectBlank(_ item: SavedTask) {
        let text = draft ?? item.prompt
        guard let range = IntentStore.blanks.compactMap({ text.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound })
        else { return }
        guard #available(iOS 18.0, *) else { return }
        Task { selection = TextSelection(range: range) }  // after the field took focus, or it puts the caret back
    }

    /// Keeps what was typed as the instruction; an emptied field goes back to the saved words.
    private func savePrompt(_ item: SavedTask) {
        let text = (draft ?? item.prompt).trimmingCharacters(in: .whitespacesAndNewlines)
        draft = nil
        guard !text.isEmpty, text != item.prompt else { return }
        var copy = item
        copy.prompt = text
        intents.upsert(copy)
        guard !(item.steps ?? []).isEmpty || !item.checklist.isEmpty else { return }  // nothing to check
        checking = true
        Task {
            defer { checking = false }
            do {
                let found = try await app.replan(copy, old: item.prompt)
                // only if nobody edited it meanwhile, and only when something would change
                guard intents.item(id)?.prompt == text,
                      found.changes > 0 || (!found.name.isEmpty && found.name != item.name) || found.hints != item.checklist
                else { return }
                proposal = found
            } catch {
                DebugLog.write("intent \"\(item.name)\": steps not checked after the edit: \(error.localizedDescription)")
            }
        }
    }

    /// Only the name changes; the instruction and the saved steps stay as they are.
    private func rename(_ item: SavedTask) {
        let name = (renaming ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !name.isEmpty, name != item.name, var copy = intents.item(id) else { return }
        copy.name = name
        intents.upsert(copy)
    }

    /// The same editor as a run's review: with its last run's steps if it has one.
    private func edit(_ item: SavedTask) {
        let ref = (item.runs.last?.run ?? item.refRun).flatMap { app.runs.run($0) }
        app.review = ref.map { ReviewDraft(run: $0, intent: item) } ?? ReviewDraft(intent: item)
    }
}
