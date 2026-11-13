import Foundation

/// One step of a saved intent, from a demonstration or a run: the action (JSON, 0-1000 screen units like the
/// actor's), whether it is trusted, and the screen it was done on.
struct RecordedStep: Codable, Equatable, Hashable {
    var action: String
    var sure: Bool
    var frame: String?  // a file in the intent's frame folder (IntentFrames)

    init(action: JObject, sure: Bool, frame: String?) {
        self.action = PyJSON.dumps(action, ascii: false)
        self.sure = sure
        self.frame = frame
    }

    var object: JObject? {
        guard let any = try? JSONSerialization.jsonObject(with: Data(action.utf8)),
              case .obj(let o) = PyJSON.from(any) else { return nil }
        return o
    }
}

/// Reference screens of saved intents: Documents/intent-frames/<intent id>/sNN.jpg.
enum IntentFrames {
    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("intent-frames")
    }

    static func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString) }

    /// The screens of the steps before the last learned ones (IntentLearner), for Undo.
    static func previous(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".prev") }

    static func url(_ id: UUID, _ name: String?) -> URL? {
        guard let name, !name.isEmpty, !name.contains("/"), !name.contains("..") else { return nil }
        return folder(id).appendingPathComponent(name)
    }

    static func data(_ id: UUID, _ name: String?) -> Data? { url(id, name).flatMap { try? Data(contentsOf: $0) } }

    static func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: folder(id))
        try? FileManager.default.removeItem(at: previous(id))
    }
}

/// Tap first, ask later: a saved intent's recorded steps are done without the model while the screen matches
/// each step's reference screen. The first mismatch, or a step that changes nothing, hands the rest to the
/// model for good; the steps stay in its prompt as hints.
struct Replay {
    struct Step: Equatable {
        var action: JObject
        var sure: Bool
        var frame: Data?
        /// An unlabelled tap: the text near its spot on `frame` (OCR), once looked up (ScriptRunner).
        var seen: String?
    }

    enum Decision: Equatable { case perform, handOver(String) }

    private(set) var steps: [Step]
    private(set) var next = 0
    private(set) var over = false
    /// Recorded moves (indices into steps) that missed in this run: the screen differed, their label wasn't on it, or
    /// they changed nothing. A run that doesn't finish demotes them in its intent (IntentLearner.demoted).
    private(set) var missed: Set<Int> = []
    /// A script repeats until this holds ("结束了吗"), at most maxLoops rounds; loops counts the rounds done.
    var until: String?
    var maxLoops = 5
    private(set) var loops = 0

    init(steps: [Step] = [], until: String? = nil, maxLoops: Int = 5) {
        self.steps = steps
        self.until = until.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        self.maxLoops = max(1, maxLoops)
    }

    init(intent: SavedTask) {
        self.init(steps: (intent.steps ?? []).compactMap { s in
            s.object.map { Step(action: Self.retyped($0, prompt: intent.prompt), sure: s.sure,
                                frame: IntentFrames.data(intent.id, s.frame)) }
        }, until: intent.until, maxLoops: intent.maxLoops ?? 5)
    }

    /// Henry 2026-11-13: text typed from the instruction's words (`slot`, ReviewDraft.recordedSteps) that the
    /// instruction no longer has ("发给张三" became "发给李四"): the AI types what the instruction says now.
    static func retyped(_ action: JObject, prompt: String) -> JObject {
        guard action["action"]?.str == "type", let slot = action["slot"]?.str, !slot.isEmpty, !prompt.contains(slot)
        else { return action }
        return ["action": .str("ai"), "goal": .str("Type what the task says now in place of \"\(slot)\"")]
    }

    /// Steps the script runs itself besides moves: an AI sub-goal, notebook actions, a step for the user.
    static let scriptKinds: Set<String> = ["ai", "read", "progress", "write", "manual"]

    /// A script (any of those steps, or an `until`) runs to its end and repairs a missed move with the model;
    /// a plain recording hands the rest of the task to the model at the first miss, as before.
    var isScript: Bool {
        until != nil || steps.contains { Self.scriptKinds.contains($0.action["action"]?.str ?? "") }
    }

    mutating func nextLoop() { loops += 1; next = 0 }

    var current: Step? { over || next >= steps.count ? nil : steps[next] }
    mutating func advance() { next += 1 }
    mutating func stop() { over = true }
    mutating func name(_ i: Int, seen: String) { if steps.indices.contains(i) { steps[i].seen = seen } }
    mutating func restart() { next = 0; over = false; loops = 0; missed = [] }
    /// The current step missed (`why` from decide, a label not found, or "no change"); other hand-overs aren't misses.
    mutating func miss(_ why: String) {
        if why.hasPrefix("miss") || why == "no change" || why.hasSuffix("not on screen") { missed.insert(next) }
    }

    /// Moves that can be repeated blindly; anything else (notes, done, unknown words) goes to the model.
    static let replayable: Set<String> = ["tap", "swipe", "type", "clear", "home", "back", "key", "wait", "open"]

    static func decide(_ step: Step, screen: Data?) -> Decision {
        let name = step.action["action"]?.str ?? ""
        guard replayable.contains(name) else { return .handOver("not a move") }
        guard step.sure else { return .handOver("unsure") }
        if name == "open" { return .perform }  // opens the app from any screen
        if name == "type", (step.action["text"]?.str ?? "").isEmpty { return .handOver("unknown text") }
        guard let frame = step.frame else { return .handOver("no reference screen") }
        guard Vision.similar(frame, screen) else { return .handOver("miss (screen differs)") }
        return .perform
    }

    /// Henry 2026-11-12: a demonstrated tap names what was tapped ("label"), so it is replayed by that name, not by
    /// its spot: a chat list in another order still finds the row. The OCR line that reads it, nearest to the
    /// recorded spot; nil when the screen doesn't show it (the model repairs the step).
    static func locate(_ label: String, near x: Int, _ y: Int, in lines: [DemoAnalysis.Line]) -> (x: Int, y: Int)? {
        func plain(_ s: String) -> String { s.lowercased().filter { !$0.isWhitespace } }
        let want = plain(label)
        guard !want.isEmpty else { return nil }
        let hits = lines.filter { plain($0.text) == want }
        let found = hits.isEmpty ? lines.filter { plain($0.text).contains(want) } : hits
        return found.min { hypot(Double($0.x - x), Double($0.y - y)) < hypot(Double($1.x - x), Double($1.y - y)) }
            .map { ($0.x, $0.y) }
    }

    /// The steps for the model's prompt, the ones already done marked. In words, never a spot (see `words`).
    var hints: [String] {
        steps.enumerated().compactMap { i, s in
            let name = s.action["action"]?.str ?? ""
            let text = name == "ai" ? "(AI) " + (s.action["goal"]?.str ?? "") : Self.words(s.action, seen: s.seen)
            guard !text.isEmpty else { return nil }
            return "Recorded step \(i + 1)\(i < next ? " (done)" : ""): \(text)"
        }
    }

    /// A recorded step in words for the model, without its x/y (2026-11-13: "Do the equivalent of recorded step 4 on
    /// this screen: {"action": "tap", "x": 613, …}" made the model tap 613, 702 on other screens: the U key, a group
    /// chat, a photo; and the JSON showed in the status). A tap is named by its label, else by `seen` (the text near
    /// its spot on its reference screen), else as something nothing names.
    static func words(_ action: JObject, seen: String? = nil) -> String {
        let n = { (k: String) in action[k]?.double ?? 0 }
        switch action["action"]?.str ?? "" {
        case "tap":
            if let label = action["label"]?.str, label.count >= 2 { return "Tap \"\(label)\"" }
            if let seen { return "Tap \"\(seen)\"" }
            return "Tap an icon or picture (no text names it)"
        case "swipe":
            let (dx, dy) = (n("x2") - n("x1"), n("y2") - n("y1"))
            return "Swipe " + (abs(dy) >= abs(dx) ? (dy < 0 ? "up" : "down") : (dx < 0 ? "left" : "right"))
        case "path": return "Draw the recorded path"
        case "circle": return "Draw a circle"
        case "type": return "Type \"\(action["text"]?.str ?? "")\""
        case "clear": return "Clear the text field"
        case "key": return "Press \(action["combo"]?.str ?? "a key")"
        case "home": return "Go to the Home Screen"
        case "back": return "Go back"
        case "open": return "Open \(action["app"]?.str ?? "the app")"
        case "wait": return "Wait a moment"
        case "note": return action["text"]?.str ?? ""
        case "ai": return action["goal"]?.str ?? ""
        case "waittext": return "Wait until \"\(action["pattern"]?.str ?? "")\" shows"
        default: return PyJSON.dumps(action, ascii: false)  // a script's other steps (read, manual…): no spot in them
        }
    }
}
