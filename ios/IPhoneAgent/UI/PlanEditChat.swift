import SwiftUI

/// The conversation that rewrites one plan. Preparing the file waits until the screen is shown.
struct PlanEditChat: View {
    @ObservedObject var app: AppModel
    let folder: URL
    var draft: ReviewDraft?
    @StateObject private var session: PlanEditSession
    @State private var input = ""
    @State private var shownProposal: PlanProposal?
    @State private var confirmClose = false
    @State private var saved = false
    @State private var showingError = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(app: AppModel, folder: URL, draft: ReviewDraft?, sandbox: FileSandbox) {
        self.app = app
        self.folder = folder
        self.draft = draft
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
                        if session.turns.isEmpty {
                            PlanEditIntro(session: session, send: send)
                        }
                        ForEach(session.turns) { turn in
                            PlanChatTurnView(turn: turn)
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
                .onChange(of: session.turns.count) { _, _ in scroll(proxy) }
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
        .safeAreaInset(edge: .bottom) {
            PlanEditComposer(session: session, input: $input, showDiff: presentDiff, send: sendDraft)
        }
        .task { await prepare() }
        .sheet(item: $shownProposal) { proposal in
            PlanDiffSheet(proposal: proposal, save: save)
        }
        .alert("Save the edited plan?", isPresented: $confirmClose) {
            Button("Save", action: save)
            Button("Discard", role: .destructive, action: discard)
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("The review is ready. Closing now leaves the recording as it was.")
        }
        .alert("Couldn't edit the plan", isPresented: $showingError) {
        } message: {
            Text(verbatim: session.error ?? "")
        }
        .onChange(of: session.proposal) { _, proposal in
            if proposal != nil { shownProposal = proposal }
        }
        .onChange(of: session.error) { _, error in
            showingError = error != nil
        }
    }

    private func prepare() async {
        let ready = draft ?? PlanFolder.makeDraft(folder)
        PlanFolder.ensure(session.sandbox, ready)
        session.reloadPlan()
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        if reduceMotion {
            proxy.scrollTo("end", anchor: .bottom)
        } else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                proxy.scrollTo("end", anchor: .bottom)
            }
        }
    }

    private func presentDiff() { shownProposal = session.proposal }

    private func sendDraft() { send(input) }

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

    private func discard() { dismiss() }

    private func save() {
        guard let proposal = session.proposal, !proposal.blocking else { return }
        do {
            try PlanSave.commit(proposal.after, folder: folder, draft: draft, app: app)
            saved = true
            shownProposal = nil
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
