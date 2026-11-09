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

    static func url(_ id: UUID, _ name: String?) -> URL? {
        guard let name, !name.isEmpty, !name.contains("/"), !name.contains("..") else { return nil }
        return folder(id).appendingPathComponent(name)
    }

    static func data(_ id: UUID, _ name: String?) -> Data? { url(id, name).flatMap { try? Data(contentsOf: $0) } }

    static func delete(_ id: UUID) { try? FileManager.default.removeItem(at: folder(id)) }
}

/// Tap first, ask later: a saved intent's recorded steps are done without the model while the screen matches
/// each step's reference screen. The first mismatch, or a step that changes nothing, hands the rest to the
/// model for good; the steps stay in its prompt as hints.
struct Replay {
    struct Step: Equatable {
        var action: JObject
        var sure: Bool
        var frame: Data?
    }

    enum Decision: Equatable { case perform, handOver(String) }

    private(set) var steps: [Step]
    private(set) var next = 0
    private(set) var over = false
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
            s.object.map { Step(action: $0, sure: s.sure, frame: IntentFrames.data(intent.id, s.frame)) }
        }, until: intent.until, maxLoops: intent.maxLoops ?? 5)
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
    mutating func restart() { next = 0; over = false; loops = 0 }

    /// Moves that can be repeated blindly; anything else (notes, done, unknown words) goes to the model.
    static let replayable: Set<String> = ["tap", "swipe", "type", "clear", "home", "back", "key", "wait"]

    static func decide(_ step: Step, screen: Data?) -> Decision {
        let name = step.action["action"]?.str ?? ""
        guard replayable.contains(name) else { return .handOver("not a move") }
        guard step.sure else { return .handOver("unsure") }
        if name == "type", (step.action["text"]?.str ?? "").isEmpty { return .handOver("unknown text") }
        guard let frame = step.frame else { return .handOver("no reference screen") }
        guard Vision.similar(frame, screen) else { return .handOver("miss (screen differs)") }
        return .perform
    }

    /// The steps for the model's prompt, the ones already done marked.
    var hints: [String] {
        steps.enumerated().compactMap { i, s in
            let name = s.action["action"]?.str ?? ""
            let text = name == "note" ? (s.action["text"]?.str ?? "")
                : name == "ai" ? "(AI) " + (s.action["goal"]?.str ?? "") : PyJSON.dumps(s.action, ascii: false)
            guard !text.isEmpty else { return nil }
            return "Recorded step \(i + 1)\(i < next ? " (done)" : ""): \(text)"
        }
    }
}
