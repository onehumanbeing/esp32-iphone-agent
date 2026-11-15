import Foundation

/// Which configured model edits a plan and calls the file tools, and which one reviews the edit.
/// Both go through `Settings.client` so the choice in Settings › Model is what runs. This is a role, not a model id.
enum PlanModels {
    static let role = "planner"
}

struct PlanTurn: Identifiable, Equatable {
    enum Role: Equatable { case user, assistant, tool }
    var id = UUID()
    var role: Role
    var text: String
}

struct PlanNote: Identifiable, Equatable {
    var id: Int
    var text: String
}

struct PlanProposal: Identifiable, Equatable {
    var id = UUID()
    var before: String
    var after: String
    var verdictOK: Bool
    var blocking: Bool
    var notes: [PlanNote]
    var diff: [TextDiff.Row]
}

/// One chat that rewrites `plan.txt` with the file tools, then a second pass that may only list and read.
/// Nothing is applied to the review until the user saves the proposal.
@MainActor
final class PlanEditSession: ObservableObject {
    typealias Ask = (String, String) async throws -> String

    let sandbox: FileSandbox
    private let editor: Ask
    private let reviewer: Ask
    @Published private(set) var turns: [PlanTurn] = []
    @Published private(set) var proposal: PlanProposal?
    @Published private(set) var busy = false
    @Published var error: String?
    /// Bumped when `plan.txt` is written outside a chat turn, so the screen reads it again.
    @Published private(set) var diskTick = 0

    init(sandbox: FileSandbox, editor: @escaping Ask, reviewer: @escaping Ask) {
        self.sandbox = sandbox
        self.editor = editor
        self.reviewer = reviewer
    }

    var planText: String {
        _ = diskTick
        return sandbox.textFile("plan.txt") ?? ""
    }

    func reloadPlan() { diskTick += 1 }
    var hasPlan: Bool { PlanText.parse(planText) != nil }

    func send(_ user: String) async {
        let text = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        busy = true
        error = nil
        turns.append(PlanTurn(role: .user, text: text))
        defer { busy = false }
        do {
            let before = planText
            try await edit()
            let after = planText
            guard after != before else { proposal = nil; return }
            proposal = try await review(before: before, after: after)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func edit() async throws {
        for _ in 0..<6 {
            let reply = try await editor(Self.editorPrompt, transcript())
            let parsed = FileTool.parse(reply)
            if !parsed.message.isEmpty { turns.append(PlanTurn(role: .assistant, text: parsed.message)) }
            if parsed.calls.isEmpty { return }
            for call in parsed.calls {
                let result = sandbox.perform(call, allow: FileTool.edit)
                turns.append(PlanTurn(role: .tool, text: "\(call.name): \(result)"))
            }
        }
    }

    private func review(before: String, after: String) async throws -> PlanProposal {
        let local = PlanText.localCheck(before: before, after: after, sandbox: sandbox)
        var notes = local.notes
        var modelOK: Bool?
        var seen: [PlanTurn] = []
        for _ in 0..<4 {
            let reply = try await reviewer(Self.reviewPrompt, reviewTranscript(before: before, after: after, seen: seen))
            let parsed = FileTool.parse(reply)
            let said = PlanText.verdict(parsed.message.isEmpty ? reply : parsed.message)
            for call in parsed.calls {
                let result = sandbox.perform(call, allow: FileTool.review)
                let turn = PlanTurn(role: .tool, text: "\(call.name): \(result)")
                seen.append(turn)
                turns.append(turn)
            }
            if said.ok != nil {
                modelOK = said.ok
                notes.append(contentsOf: said.notes)
                break
            }
            if parsed.calls.isEmpty { break }
        }
        if modelOK == nil {
            notes.append(String(localized: "The review pass did not answer. The check above is from the plan file."))
        }
        let verdictOK = !local.blocking && modelOK != false
        let shown = notes.enumerated().map { PlanNote(id: $0.offset, text: $0.element) }
        return PlanProposal(before: before, after: after, verdictOK: verdictOK, blocking: local.blocking,
                            notes: shown, diff: TextDiff.lines(before, after))
    }

    private func transcript() -> String {
        var parts = ["Plan file: plan.txt"]
        let frames = sandbox.keyframes().map(\.lastPathComponent)
        if !frames.isEmpty { parts.append("Recording frames: " + frames.joined(separator: ", ")) }
        parts.append("Current plan.txt:\n" + planText)
        for turn in turns.suffix(12) {
            switch turn.role {
            case .user: parts.append("User: \(turn.text)")
            case .assistant: parts.append("Assistant: \(turn.text)")
            case .tool: parts.append("Tool result: \(turn.text)")
            }
        }
        var text = parts.joined(separator: "\n\n")
        if text.count > 14_000 { text = String(text.suffix(14_000)) }
        return text
    }

    private func reviewTranscript(before: String, after: String, seen: [PlanTurn]) -> String {
        var text = "Original plan:\n\(before)\n\nEdited plan:\n\(after)"
        for turn in seen { text += "\n\nTool result: \(turn.text)" }
        return text
    }

    static let editorPrompt = """
    You edit one recorded iPhone task. The recording is already in this folder. You never touch the phone: \
    no taps, no typing on the device, no network, and no files outside this folder. You change the plan with tools only.

    Tools, each exactly in this form:
    TOOL list .
    TOOL read plan.txt
    TOOL write plan.txt
    <new text>
    END
    TOOL screenshot <n> <name.jpg>
    TOOL crop <source.jpg> <x> <y> <w> <h> <name.jpg>
    TOOL save_image <name.jpg>
    <base64 of a jpeg>
    END

    screenshot copies recording frame n (1 is the first) to a new jpeg in this folder. crop cuts that image; \
    x y w h are 0 to 1000 across the image. save_image writes a jpeg you supply. write saves text and nothing else. \
    list and read only look. Do not call any other tool.

    The plan is plan.txt:
    NAME: <short name>
    PROMPT: <one instruction>
    UNTIL: <optional; when this is true on screen the steps stop repeating>
    MAX_LOOPS: <1 to 20, with UNTIL>
    1. <command> | <frame.jpg>
    Commands: tap X Y "label", swipe X1 Y1 X2 Y2, type "text", open "App", key enter, home, back, wait, \
    ai "what to do", read "what to copy", manual "what the user does". Keep a step's frame file when it still has one.

    When the user asks for a loop, keep the steps they named, set UNTIL to a condition that can be seen on screen, \
    and leave out the steps after the cutoff. Do not add taps the recording never did unless they asked for a new \
    kind of step (ai, read, manual). Then stop calling tools and say what you changed, in the user's language.
    """

    static let reviewPrompt = """
    You review an edited iPhone plan against the recording it came from. You may only look:
    TOOL list .
    TOOL read plan.txt
    No write, no screenshot, no crop, no save_image. Then answer in this form only:
    VERDICT: ok
    NOTES:
    - <one short note>
    or VERDICT: issues. ok means the edited steps are still the recorded task, a loop repeats a real part of it \
    and stops on something the screen can show, and every frame file named is one that exists. issues means a step \
    contradicts the recording, a frame is missing, or the loop would not end. Keep the user's language. At most 4 notes.
    """
}

/// What demo mode does instead of calling the model: the same tool text the editor would send.
enum PlanEditMock {
    static func editorReply(transcript: String) -> String {
        if transcript.contains("Tool result:") {
            return "MESSAGE: The steps now repeat, and the ones after the cutoff are left out."
        }
        guard let range = transcript.range(of: "Current plan.txt:\n") else {
            return "MESSAGE: There is no plan.txt to edit."
        }
        let plan = String(transcript[range.upperBound...]).components(separatedBy: "\n\nUser:").first ?? ""
        let user = transcript.components(separatedBy: "User: ").last ?? ""
        let edited = looped(plan, user: user)
        return """
        MESSAGE: I'll turn the steps before the cutoff into a loop.
        TOOL write plan.txt
        \(edited.trimmingCharacters(in: .newlines))
        END
        """
    }

    static func reviewReply(transcript: String) -> String {
        if !transcript.contains("Tool result:"), transcript.contains("Edited plan:") {
            return "TOOL read plan.txt"
        }
        return """
        VERDICT: ok
        NOTES:
        - The loop keeps recorded steps and stops on a condition the screen can show.
        """
    }

    /// Steps before "before step N" stay; the rest become the stop condition.
    static func looped(_ plan: String, user: String) -> String {
        guard var doc = PlanText.parse(plan) else { return plan }
        if let n = cutoff(user), n > 1 { doc.steps = Array(doc.steps.prefix(n - 1)) }
        doc.until = doc.steps.isEmpty ? nil : "the screen is ready for what used to come next"
        doc.maxLoops = 8
        return PlanText.render(doc)
    }

    static func cutoff(_ user: String) -> Int? {
        let folded = user.lowercased()
        for marker in ["before step ", "until step "] {
            guard let range = folded.range(of: marker) else { continue }
            let rest = folded[range.upperBound...]
            let digits = rest.prefix { $0.isNumber }
            if let n = Int(digits), n > 0 { return n }
        }
        if let range = user.range(of: #"第\s*\d+\s*步"#, options: .regularExpression) {
            let digits = user[range].filter(\.isNumber)
            return Int(digits)
        }
        return nil
    }
}

enum PlanSave {
    /// Write the accepted plan into the review, and into the linked intent when there is one.
    @MainActor
    static func commit(_ text: String, folder: URL, draft: ReviewDraft?, app: AppModel) throws {
        guard let plan = PlanText.parse(text) else {
            throw LLMError(message: String(localized: "The plan file is not a plan the app can run."))
        }
        let target = draft ?? PlanFolder.makeDraft(folder)
        target.applyPlan(plan)
        if let open = app.review, open !== target, sameFolder(open.folder, folder) {
            open.applyPlan(plan)
        }
        try link(target, app: app)
    }

    @MainActor
    private static func link(_ draft: ReviewDraft, app: AppModel) throws {
        let folderName = draft.folder?.lastPathComponent
        let match = app.intents.items.first {
            $0.id == draft.intentID || $0.refRun == draft.runID || $0.refRun == folderName
                || (folderName != nil && $0.refRecording == folderName)
        }
        guard var item = match else { return }
        item = draft.intent(existing: item)
        if let steps = try draft.recordedSteps(for: item.id) { item.steps = steps }
        item.until = draft.until
        item.maxLoops = draft.maxLoops
        app.intents.upsert(item)
        draft.intentID = item.id
    }

    private static func sameFolder(_ a: URL?, _ b: URL) -> Bool {
        guard let a else { return false }
        return a.standardizedFileURL.resolvingSymlinksInPath().path
            == b.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
