import SwiftUI

/// Chat that rewrites one recording's plan. The model is whatever Settings › Model has selected (the Planner, if set).
/// A second pass reviews the edit. The diff is shown before anything is saved.
struct PlanEditView: View {
    @ObservedObject var app: AppModel
    let folder: URL
    var draft: ReviewDraft?

    var body: some View {
        if let sandbox = FileSandbox.insideAgentData(folder) {
            PlanEditChat(app: app, folder: folder, draft: draft, sandbox: sandbox)
        } else {
            ContentUnavailableView {
                Label("This folder can't be edited", systemImage: "folder")
            } description: {
                Text("Plans stay inside this app's files.")
            }
        }
    }
}

private struct PlanEditChat: View {
    @ObservedObject var app: AppModel
    let folder: URL
    var draft: ReviewDraft?
    @StateObject private var session: PlanEditSession
    @State private var input = ""
    @State private var showDiff = false
    @State private var confirmClose = false
    @State private var saved = false
    @Environment(\.dismiss) private var dismiss

    init(app: AppModel, folder: URL, draft: ReviewDraft?, sandbox: FileSandbox) {
        self.app = app
        self.folder = folder
        self.draft = draft
        let ready = draft ?? PlanFolder.makeDraft(folder)
        PlanFolder.ensure(sandbox, ready)
        _session = StateObject(wrappedValue: PlanEditSession(
            sandbox: sandbox,
            editor: { system, text in try await Self.ask(app, system: system, text: text, tokens: 1800, review: false) },
            reviewer: { system, text in try await Self.ask(app, system: system, text: text, tokens: 800, review: true) }))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.m) {
                        if session.turns.isEmpty { intro }
                        ForEach(session.turns) { turn in
                            bubble(turn)
                        }
                        if session.busy {
                            HStack(spacing: Space.s) {
                                ProgressView()
                                Text("Working").font(.subheadline).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, Space.l)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.vertical, Space.m)
                }
                .onChange(of: session.turns.count) { _, _ in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                        proxy.scrollTo("end", anchor: .bottom)
                    }
                }
            }
        }
        .background(Palette.background)
        .navigationTitle("Edit plan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close", action: requestClose)
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .sheet(isPresented: $showDiff) {
            if let proposal = session.proposal {
                PlanDiffSheet(proposal: proposal, save: save)
            }
        }
        .alert("Save the edited plan?", isPresented: $confirmClose) {
            Button("Save", action: save)
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("The review is ready. Closing now leaves the recording as it was.")
        }
        .alert("Couldn't edit the plan", isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(verbatim: session.error ?? "") }
        .onChange(of: session.proposal?.after) { _, after in
            if after != nil { showDiff = true }
        }
    }

    private var intro: some View {
        VStack(spacing: Space.m) {
            AgentFace(mood: .thinking, animated: false).frame(width: 72, height: 80)
            Text("Edit this plan").font(.headline)
            Text(session.hasPlan
                 ? "Say what should change. A second pass checks the result, and you see the difference before it is saved."
                 : "This folder has no recorded steps to edit.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text("Uses the Planner model when one is set in Settings › Model, otherwise the selected model.")
                .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            if let count = PlanText.parse(session.planText)?.steps.count, count > 1 {
                VStack(spacing: Space.s) {
                    suggestion(String(localized: "Make it a loop"), "repeat") {
                        send("Turn this into a loop. Repeat the steps until the list shows its end.")
                    }
                    suggestion(String(localized: "Stop before step \(count)"), "arrow.uturn.backward") {
                        send("Turn this into a loop, repeat until before step \(count).")
                    }
                }
            }
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity)
    }

    private func suggestion(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label { Text(title) } icon: { Image(systemName: symbol) }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 40)
        }
        .buttonStyle(.bordered)
        .disabled(session.busy)
    }

    @ViewBuilder private func bubble(_ turn: PlanTurn) -> some View {
        switch turn.role {
        case .tool:
            Label { Text(verbatim: turn.text).lineLimit(4) } icon: { Image(systemName: "wrench.and.screwdriver") }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.l)
        case .user, .assistant:
            HStack {
                if turn.role == .user { Spacer(minLength: 48) }
                Text(verbatim: turn.text)
                    .font(.body)
                    .foregroundStyle(turn.role == .user ? Color.white : Color.primary)
                    .padding(.horizontal, Space.m)
                    .padding(.vertical, Space.s)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(turn.role == .user ? Color.accentColor : Palette.surface)
                    )
                if turn.role == .assistant { Spacer(minLength: 48) }
            }
            .padding(.horizontal, Space.l)
        }
    }

    private var composer: some View {
        VStack(spacing: Space.s) {
            if let proposal = session.proposal {
                Button { showDiff = true } label: {
                    HStack(spacing: Space.s) {
                        Image(systemName: proposal.verdictOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(proposal.verdictOK ? Palette.ok : Palette.warning)
                        Text(proposal.verdictOK ? "Review passed" : "Review found something to check")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("See changes").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(Space.m)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface))
                }
                .buttonStyle(.plain)
            }
            HStack(alignment: .bottom, spacing: Space.s) {
                TextField("Ask for a change", text: $input, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, Space.m)
                    .padding(.vertical, Space.s)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.surface))
                    .accessibilityIdentifier("plan.message")
                Button(action: { send(input) }) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                }
                .disabled(session.busy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !session.hasPlan)
                .accessibilityLabel(Text("Send"))
            }
        }
        .padding(.horizontal, Space.l)
        .padding(.top, Space.s)
        .padding(.bottom, Space.s)
        .background(.bar)
    }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        input = ""
        Haptics.tick()
        Task { await session.send(trimmed) }
    }

    private func requestClose() {
        if session.proposal != nil && !saved { confirmClose = true } else { dismiss() }
    }

    private func save() {
        guard let proposal = session.proposal, !proposal.blocking else { return }
        do {
            try PlanSave.commit(proposal.after, folder: folder, draft: draft, app: app)
            saved = true
            showDiff = false
            Haptics.success()
            dismiss()
        } catch {
            session.error = error.localizedDescription
        }
    }

    private static func ask(_ app: AppModel, system: String, text: String, tokens: Int, review: Bool) async throws -> String {
        if MockMode.on {
            return review ? PlanEditMock.reviewReply(transcript: text) : PlanEditMock.editorReply(transcript: text)
        }
        let model = try await app.settings.client(PlanModels.role)
        return try await model.chat(system: system, text: text, image: nil, maxTokens: tokens,
                                    temperature: review ? 0 : 0.2).text
    }
}

/// The edited plan next to the one it replaced, plus the review notes. Saving is the only way it sticks.
private struct PlanDiffSheet: View {
    let proposal: PlanProposal
    var save: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label {
                        Text(proposal.verdictOK ? "Looks consistent with the recording" : "The review wants a look")
                    } icon: {
                        Image(systemName: proposal.verdictOK ? "checkmark.seal" : "exclamationmark.triangle")
                            .foregroundStyle(proposal.verdictOK ? Palette.ok : Palette.warning)
                    }
                    ForEach(Array(proposal.notes.enumerated()), id: \.offset) { _, note in
                        Text(verbatim: note).font(.subheadline)
                    }
                } header: {
                    Text("Review")
                } footer: {
                    Text(proposal.blocking
                         ? "This can't be saved until the plan is one the app can run, inside this folder."
                         : "Saving updates this recording's plan. The original screens stay in the folder.")
                }
                Section("Changes") {
                    if proposal.diff.isEmpty {
                        Text("No visible change").foregroundStyle(.secondary)
                    } else {
                        ForEach(proposal.diff) { row in
                            Text(verbatim: mark(row) + row.text)
                                .font(.caption.monospaced())
                                .foregroundStyle(color(row.kind))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .listRowInsets(EdgeInsets(top: 2, leading: Space.m, bottom: 2, trailing: Space.m))
                        }
                    }
                }
            }
            .navigationTitle("Review changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Keep Editing") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(proposal.verdictOK ? "Save plan" : "Save anyway", action: save)
                        .fontWeight(.semibold)
                        .disabled(proposal.blocking)
                }
            }
        }
    }

    private func mark(_ row: TextDiff.Row) -> String {
        switch row.kind {
        case .added: return "+ "
        case .removed: return "− "
        case .same: return "  "
        }
    }

    private func color(_ kind: TextDiff.Row.Kind) -> Color {
        switch kind {
        case .added: return Palette.ok
        case .removed: return Palette.stop
        case .same: return .primary
        }
    }
}
