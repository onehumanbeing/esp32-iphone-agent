import Foundation

/// One step in the review editor: what was done, on which screenshot, and the user's verdict and fix.
struct DraftStep: Identifiable, Equatable {
    var id = UUID()
    var action: JObject
    var frame: URL?
    var t: Double?
    var verdict: Bool?       // true ✓, false ✗, nil = not judged
    var fix: CGPoint?        // the right spot, 0-1000 screen units
    var note = ""            // "should tap the + at the top right"
    var uncertain = false    // inferred from a demonstration and not sure
    var inserted = false     // added by the user

    var name: String { action["action"]?.str ?? "" }
    var isMove: Bool { !StepText.notMoves.contains(name) }
}

/// The review editor's document: a run, a demonstration or an intent, the steps with the user's
/// corrections, and the intent being made (name, icon, prompt, checklist). Saved next to its trace.
@MainActor final class ReviewDraft: ObservableObject, Identifiable {
    enum Source { case run, recording, intent }

    let id = UUID()
    let source: Source
    let folder: URL?
    let runID: String?
    let outcome: Outcome?
    @Published var steps: [DraftStep]
    @Published var name: String
    @Published var icon: String
    @Published var color: String?
    @Published var prompt: String
    @Published var hints: [String]
    @Published var intentID: UUID?
    /// Open the Save sheet right away (Record › Save last run as intent).
    var showSaveOnOpen = false

    init(source: Source, folder: URL?, runID: String?, outcome: Outcome?, steps: [DraftStep], name: String,
         prompt: String, hints: [String] = [], icon: String = "bolt.fill", color: String? = nil, intentID: UUID? = nil) {
        self.source = source; self.folder = folder; self.runID = runID; self.outcome = outcome
        self.steps = steps; self.name = name; self.prompt = prompt; self.hints = hints; self.icon = icon
        self.color = color
        self.intentID = intentID
        loadEdits()
    }

    /// A finished run; the intent it ran for (if any) fills the name, prompt and checklist.
    /// A demonstration written as a run (DemoRecorder) opens as one: its unsure steps marked.
    convenience init(run: Run, intent: SavedTask? = nil) {
        let steps = run.steps.map {
            DraftStep(action: $0.action, frame: $0.frame, t: $0.t, uncertain: $0.action["sure"] == .bool(false))
        }
        self.init(source: intent == nil ? (run.isDemo ? .recording : .run) : .intent, folder: run.folder, runID: run.id, outcome: run.outcome,
                  steps: steps, name: intent?.name ?? "", prompt: intent?.prompt ?? run.task,
                  hints: intent?.checklist ?? [], icon: intent?.symbol ?? "bolt.fill", color: intent?.color, intentID: intent?.id)
    }

    /// An intent without a reference run: only its words to edit.
    convenience init(intent: SavedTask) {
        let recording = intent.refRecording.flatMap { name -> URL? in
            guard !name.isEmpty, !name.contains("/"), !name.contains("..") else { return nil }
            return DemoRecorder.root.appendingPathComponent(name)
        }
        self.init(source: .intent, folder: recording, runID: nil, outcome: nil, steps: [], name: intent.name,
                  prompt: intent.prompt, hints: intent.checklist, icon: intent.symbol, color: intent.color, intentID: intent.id)
    }

    /// A demonstration: an old recording, or a run DemoRecorder wrote (its steps say `demo`).
    var isDemo: Bool { source == .recording || steps.contains { $0.action["demo"] == .bool(true) } }

    /// An imported run: replay only, no edits or intents.
    var readOnly: Bool { folder.map(RunShare.isImported) ?? false }

    var title: String {
        switch source {
        case .run: return prompt
        case .recording: return name.isEmpty ? String(localized: "Demonstration") : name
        case .intent: return name
        }
    }

    // MARK: - editing

    func index(_ id: UUID) -> Int? { steps.firstIndex { $0.id == id } }

    func mark(_ id: UUID, _ ok: Bool?) {
        guard let i = index(id) else { return }
        steps[i].verdict = steps[i].verdict == ok ? nil : ok
        steps[i].uncertain = false
        saveEdits()
    }

    func setFix(_ id: UUID, point: CGPoint?, note: String) {
        guard let i = index(id) else { return }
        steps[i].fix = point
        steps[i].note = note
        if point != nil || !note.isEmpty { steps[i].verdict = false }
        steps[i].uncertain = false
        saveEdits()
    }

    func delete(_ id: UUID) {
        steps.removeAll { $0.id == id }
        saveEdits()
    }

    /// A step written by the user ("then tap Save"), shown on the previous screenshot.
    func insert(after id: UUID?, text: String) {
        let at = id.flatMap(index).map { $0 + 1 } ?? steps.count
        let frame = at > 0 ? steps[at - 1].frame : nil
        steps.insert(DraftStep(action: ["action": .str("note"), "text": .str(text)], frame: frame, inserted: true), at: at)
        saveEdits()
    }

    var corrections: Int { steps.filter { $0.verdict == false || $0.inserted || !$0.note.isEmpty }.count }

    // MARK: - intent

    func intent(existing: SavedTask?) -> SavedTask {
        var item = existing ?? SavedTask(name: "", prompt: "")
        item.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String(prompt.prefix(30)) : name
        item.prompt = prompt
        item.icon = icon
        item.color = color == "accent" ? nil : color
        item.hints = hints.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        item.refRun = runID ?? item.refRun
        if source == .recording && runID == nil { item.refRecording = folder?.lastPathComponent }  // before recordings were runs
        let corrections = steps.compactMap { step -> String? in
            guard !step.uncertain else { return nil }
            if let point = step.fix { return "For \(StepText.title(step.action)), use screen position \(Int(point.x)), \(Int(point.y)) (0–1000). \(step.note)" }
            if !step.note.isEmpty { return step.note }
            if step.inserted { return step.action["text"]?.str }
            return nil
        }
        for correction in corrections where !(item.hints ?? []).contains(correction) {
            item.hints = (item.hints ?? []) + [correction]
        }
        return item
    }

    /// The moves to replay next time (Replay), their screens copied next to the intent so deleting the run or
    /// recording keeps them. nil = nothing to replay here (an intent opened without its steps): keep the old ones.
    func recordedSteps(for id: UUID) throws -> [RecordedStep]? {
        // A demonstration keeps script steps too; a note or an unsure move there becomes an AI step (ScriptRunner).
        let demo = isDemo
        let kept = Replay.replayable.union(Replay.scriptKinds).union(demo ? ["note"] : [])
        let picked = steps.filter { kept.contains($0.name) && !$0.inserted && ($0.verdict != false || $0.fix != nil) }
        guard !picked.isEmpty else { return source == .intent ? nil : [] }
        let folder = IntentFrames.folder(id)
        let staging = folder.deletingLastPathComponent().appendingPathComponent(id.uuidString + ".new")
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let result = try picked.enumerated().map { i, step -> RecordedStep in
            var action = Actions.key(step.action)
            if step.name == "tap", let label = step.action["label"] { action["label"] = label }  // replayed by name
            var sure = source == .run ? outcome == .done && step.action["changed"] != .bool(false) : !step.uncertain
            if let fix = step.fix, step.name == "tap" {
                action["x"] = .int(Int(fix.x)); action["y"] = .int(Int(fix.y))
                sure = true
            }
            if step.verdict == true { sure = true }
            if demo && (step.name == "note" || (!sure && Replay.replayable.contains(step.name))) {
                let label = action["label"]?.str.map { "Tap \"\($0)\"" }
                let goal = step.name == "note" ? step.action["text"]?.str ?? "" : label ?? "Do this step: " + StepText.title(action)
                action = ["action": .str("ai"), "goal": .str(goal)]
                sure = true
            }
            if Replay.scriptKinds.contains(action["action"]?.str ?? "") { sure = true }
            var name: String?
            if let frame = step.frame, let data = try? Data(contentsOf: frame) {
                name = String(format: "s%02d.jpg", i + 1)
                try data.write(to: staging.appendingPathComponent(name!), options: .atomic)
            }
            return RecordedStep(action: action, sure: sure, frame: name)
        }
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.moveItem(at: staging, to: folder)
        return result
    }

    // MARK: - AI optimization

    static let optimizerPrompt = """
    You improve saved tasks for an AI agent that operates an iPhone with a mouse pointer. You get the task, \
    the steps of one run or of a human demonstration, and the user's corrections. Write a clearer instruction \
    and a short checklist of concrete hints that would make the next run succeed (for example "Type the time \
    instead of scrolling the wheel"). Keep the user's language. Reply in this format only:
    PROMPT: <one clear instruction>
    HINTS:
    - <hint>
    (at most 6 hints)
    """

    /// The trace and the corrections, as text for the model.
    func optimizerInput() -> String {
        var lines = ["Task: \(prompt)"]
        if !hints.isEmpty { lines.append("Current hints:\n" + hints.map { "- " + $0 }.joined(separator: "\n")) }
        if let outcome { lines.append("Run outcome: \(outcome)") }
        lines.append("Steps:")
        for (i, s) in steps.enumerated() {
            var line = "\(i + 1). " + PyJSON.dumps(Actions.key(s.action).without(["plan", "plan_zh"]), ascii: false)
            if let t = s.action["thought"]?.str { line += " (thought: \(t.prefix(200)))" }
            if s.inserted { line += " [ADDED BY USER]" }
            if s.verdict == true { line += " [USER: correct]" }
            if s.verdict == false { line += " [USER: wrong]" }
            if let p = s.fix { line += " [USER: the right spot is \(Int(p.x)) \(Int(p.y))]" }
            if !s.note.isEmpty { line += " [USER NOTE: \(s.note)]" }
            if s.action["changed"]?.bool == false { line += " (screen did not change)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// PROMPT: … / HINTS: - … ; nil if the reply has no prompt.
    static func parseOptimized(_ reply: String) -> (prompt: String, hints: [String])? {
        var prompt = "", hints: [String] = [], inHints = false
        for raw in reply.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.uppercased().hasPrefix("PROMPT:") {
                prompt = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                inHints = false
            } else if line.uppercased().hasPrefix("HINTS:") {
                inHints = true
            } else if inHints, line.hasPrefix("-") || line.hasPrefix("•") {
                hints.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
            }
        }
        return prompt.isEmpty ? nil : (prompt, Array(hints.prefix(6)))
    }

    // MARK: - persistence (review.json next to the trace)

    private struct Edits: Codable {
        struct Step: Codable { var action: String; var frame: String?; var t: Double?; var verdict: Bool?
            var fix: CGPoint?; var note: String; var uncertain: Bool; var inserted: Bool }
        var steps: [Step]
        var name: String, prompt: String, hints: [String], icon: String
    }

    private var editsURL: URL? { folder?.appendingPathComponent("review.json") }

    func saveEdits() {
        do { try persistEdits() } catch { persistenceError = error.localizedDescription }
    }

    @Published var persistenceError: String?

    func persistEdits() throws {
        guard let editsURL else { return }
        let e = Edits(steps: steps.map {
            .init(action: PyJSON.dumps($0.action, ascii: false), frame: $0.frame?.lastPathComponent, t: $0.t,
                  verdict: $0.verdict, fix: $0.fix, note: $0.note, uncertain: $0.uncertain, inserted: $0.inserted)
        }, name: name, prompt: prompt, hints: hints, icon: icon)
        try JSONEncoder().encode(e).write(to: editsURL, options: .atomic)
        persistenceError = nil
    }

    private func loadEdits() {
        guard let editsURL, let folder, let data = try? Data(contentsOf: editsURL),
              let e = try? JSONDecoder().decode(Edits.self, from: data) else { return }
        steps = e.steps.compactMap { s in
            guard let any = try? JSONSerialization.jsonObject(with: Data(s.action.utf8)),
                  case .obj(let action) = PyJSON.from(any) else { return nil }
            return DraftStep(action: action, frame: s.frame.map { folder.appendingPathComponent($0) }, t: s.t,
                             verdict: s.verdict, fix: s.fix, note: s.note, uncertain: s.uncertain, inserted: s.inserted)
        }
        if intentID == nil { name = e.name; prompt = e.prompt; hints = e.hints; icon = e.icon }
    }
}
