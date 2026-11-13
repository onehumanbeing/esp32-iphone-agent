import SwiftUI

/// Fix a step: tap where it should have tapped on its screenshot, or write what should have happened.
struct FixSheet: View {
    @ObservedObject var draft: ReviewDraft
    let step: DraftStep
    @Environment(\.dismiss) private var dismiss
    @State private var point: CGPoint?
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let url = step.frame, let img = UIImage(contentsOfFile: url.path) {
                        GeometryReader { g in
                            Image(uiImage: img).resizable().scaledToFit()
                                .frame(width: g.size.width, height: g.size.height)
                                .overlay { ActionOverlay(action: step.action) }
                                .overlay { if let point { FixMarker(point: point) } }
                                .contentShape(Rectangle())
                                .onTapGesture { p in
                                    point = CGPoint(x: (p.x / g.size.width * 1000).rounded(),
                                                    y: (p.y / g.size.height * 1000).rounded())
                                    Haptics.tick()
                                }
                        }
                        .aspectRatio(img.size, contentMode: .fit)
                        .frame(maxHeight: 420)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .listRowInsets(EdgeInsets(top: Space.m, leading: Space.m, bottom: Space.m, trailing: Space.m))
                    }
                } footer: {
                    Text("Tap where it should have tapped. The green target marks it.")
                }
                Section("Note") {
                    TextField("e.g. Tap the + at the top right", text: $note, axis: .vertical).lineLimit(2...4)
                        .accessibilityIdentifier("intent.step.note")
                }
                if point != nil {
                    Section { Button("Clear the Point", role: .destructive) { point = nil } }
                }
            }
            .navigationTitle(Text(verbatim: StepText.title(step.action)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        draft.setFix(step.id, point: point, note: note.trimmingCharacters(in: .whitespacesAndNewlines))
                        Haptics.success()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear { point = step.fix; note = step.note }
        }
    }
}

/// The model's improved prompt and checklist next to the current ones; accept or keep editing.
struct OptimizeSheet: View {
    @ObservedObject var draft: ReviewDraft
    @ObservedObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var result: (prompt: String, hints: [String])?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Group {
                if let result {
                    List {
                        Section("Before") { words(draft.prompt, draft.hints, muted: true) }
                        Section("After") { words(result.prompt, result.hints, muted: false) }
                    }
                } else if let failure {
                    ContentUnavailableView {
                        Label("Could not optimize", systemImage: "exclamationmark.triangle")
                    } description: { Text(verbatim: failure) } actions: {
                        Button("Try Again") { Task { await run() } }
                    }
                } else {
                    VStack(spacing: Space.l) {
                        AgentFace(mood: .thinking).frame(width: 96, height: 108)
                        Text("Learning from \(draft.corrections) corrections…").font(.headline)
                        Text("I'm reading the steps and your fixes to write a clearer intent.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding(Space.xl)
                    .frame(maxHeight: .infinity)
                }
            }
            .navigationTitle("Optimize with AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Keep Editing") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Accept") {
                        if let result { draft.prompt = result.prompt; draft.hints = result.hints; draft.saveEdits() }
                        Haptics.success()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(result == nil)
                }
            }
            .task { await run() }
        }
    }

    private func run() async {
        failure = nil
        do { result = try await app.optimize(draft) } catch { failure = error.localizedDescription }
    }

    private func words(_ prompt: String, _ hints: [String], muted: Bool) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(verbatim: prompt).font(.body).foregroundStyle(muted ? .secondary : .primary)
            ForEach(hints, id: \.self) { h in
                Label { Text(verbatim: h) } icon: { Image(systemName: "checkmark.circle") }
                    .font(.subheadline).foregroundStyle(muted ? .secondary : .primary)
            }
        }
        .padding(.vertical, Space.xs)
    }
}

/// Save as intent: name, icon, prompt, checklist and the reference run.
struct SaveIntentSheet: View {
    @ObservedObject var draft: ReviewDraft
    @ObservedObject var intents: IntentStore
    var saved: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var saveError: String?
    static let icons = ["bolt.fill", "alarm.fill", "message.fill", "note.text", "gearshape.fill", "cart.fill",
                        "music.note", "map.fill", "camera.fill", "envelope.fill", "paintbrush.fill", "star.fill"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $draft.name, prompt: Text("e.g. Morning alarm"))
                        .accessibilityIdentifier("intent.name")
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: Space.m) {
                        ForEach(Self.icons, id: \.self) { icon in
                            Button { draft.icon = icon; Haptics.tick() } label: {
                                SettingsIcon(symbol: icon, color: draft.icon == icon ? IntentTint.color(draft.color) : Color(uiColor: .systemGray3))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(verbatim: icon))
                            .accessibilityAddTraits(draft.icon == icon ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, Space.xs)
                    HStack(spacing: 0) {
                        ForEach(IntentTint.names, id: \.self) { name in
                            let chosen = (draft.color ?? "accent") == name
                            Button { draft.color = name; Haptics.tick() } label: {
                                Circle().fill(IntentTint.color(name)).frame(width: 22, height: 22)
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(chosen ? 0.7 : 0), lineWidth: 2).padding(-4))
                                    .frame(maxWidth: .infinity, minHeight: 32)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(verbatim: name))
                            .accessibilityAddTraits(chosen ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, Space.xs)
                }
                Section("Instruction") {
                    TextField("What should the agent do?", text: $draft.prompt, axis: .vertical).lineLimit(2...6)
                }
                ChecklistSection(hints: $draft.hints)
                if let run = draft.runID {
                    Section("Reference run") { Label { Text(verbatim: run) } icon: { Image(systemName: "play.rectangle") } }
                }
            }
            .navigationTitle(draft.intentID == nil ? "Save as Intent" : "Save Intent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .fontWeight(.semibold)
                    .disabled(draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .alert("Could not save intent", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK") { saveError = nil }
        } message: { Text(verbatim: saveError ?? "") }
    }

    private func save() {
        do {
            try draft.persistEdits()
            var item = draft.intent(existing: intents.item(draft.intentID))
            if let steps = try draft.recordedSteps(for: item.id) { item.steps = steps }
            intents.upsert(item)
            draft.intentID = item.id
            Haptics.success()
            dismiss()
            saved()
        } catch { saveError = error.localizedDescription }
    }
}

/// The checklist: one hint per row, add and swipe to delete.
struct ChecklistSection: View {
    @Binding var hints: [String]

    var body: some View {
        Section {
            ForEach(hints.indices, id: \.self) { i in
                TextField("Hint", text: Binding(get: { hints[safe: i] ?? "" }, set: { if hints.indices.contains(i) { hints[i] = $0 } }))
            }
            .onDelete { hints.remove(atOffsets: $0) }
            Button { hints.append("") } label: { Label("Add Hint", systemImage: "plus.circle.fill") }
        } header: {
            Text("Checklist")
        } footer: {
            Text("Given to the agent as hints every time this intent runs.")
        }
    }
}

/// An intent with no recorded steps yet: just its words.
struct IntentWordsView: View {
    @ObservedObject var draft: ReviewDraft

    var body: some View {
        Form {
            Section("Instruction") {
                TextField("What should the agent do?", text: $draft.prompt, axis: .vertical).lineLimit(2...8)
            }
            ChecklistSection(hints: $draft.hints)
            Section {
                Text("Run it once to get steps you can review and fix here.").foregroundStyle(.secondary)
            }
        }
    }
}
