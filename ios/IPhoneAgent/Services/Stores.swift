import Foundation

/// A task saved for reuse ("intent"): a short name and the prompt the agent gets.
struct SavedTask: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var prompt: String
    var icon: String?
    var color: String?       // IntentTint name; nil = the app's accent
    var hints: [String]?     // checklist, appended to the actor prompt as hints when it runs
    var refRecording: String? // folder name of the original demonstration
    var refRun: String?      // the run it was made from
    var steps: [RecordedStep]? // replayed before asking the model (Replay)
    var previousSteps: [RecordedStep]? // before IntentLearner replaced them (Undo)
    var learnedFrom: String? // the run the steps were learned from (IntentLearner)
    var history: [RunStat]?  // its runs, newest last
    var builtin: String?     // "diagnostics": runs in the app (sends the report), no board or model
    var until: String?      // a script repeats its steps until this is true on screen (ScriptRunner)
    var maxLoops: Int?       // at most this many rounds of an `until` script (default 5)
    var kind: String?        // "call": always a phone call; "task": never; nil: by its words (Calls.dials)

    var symbol: String { icon ?? (isCall ? "phone.fill" : "bolt.fill") }  // a call shows as one
    /// Runs as a phone call (Calls.script): the Phone call switch, or else the words ("Call …", "打电话给…").
    var isCall: Bool { Calls.isCall(prompt, kind: kind) }
    /// A template's blanks ("[who]") are still in it: edit them before it can run.
    var unfilled: Bool { IntentStore.unfilled(prompt) }
    var checklist: [String] { hints ?? [] }
    var runs: [RunStat] { history ?? [] }
    var successRate: Double? { runs.isEmpty ? nil : Double(runs.filter(\.ok).count) / Double(runs.count) }
    var averageSeconds: Double? { runs.isEmpty ? nil : runs.map(\.seconds).reduce(0, +) / Double(runs.count) }
}

struct RunStat: Codable, Equatable, Hashable {
    var run: String
    var ok: Bool
    var seconds: Double
    var date = Date()
}

/// Saved tasks, kept in UserDefaults. Seeded once with the examples (the alarm demo first).
@MainActor final class IntentStore: ObservableObject {
    @Published private(set) var items: [SavedTask] = []
    private let defaults: UserDefaults
    private static let key = "savedTasks"
    private static let diagnosticsKey = "seededDiagnosticsIntent"
    private static let callsKey = "seededTextAndCallIntents"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let saved = try? JSONDecoder().decode([SavedTask].self, from: data) {
            items = saved
            if !defaults.bool(forKey: Self.diagnosticsKey) {  // existing installs get it once; deleting it sticks
                defaults.set(true, forKey: Self.diagnosticsKey)
                if !items.contains(where: { $0.builtin == Self.diagnostics.builtin }) { items.append(Self.diagnostics); save() }
            }
            if !defaults.bool(forKey: Self.callsKey) {  // Henry 2026-11-12: text and call at the top, once
                defaults.set(true, forKey: Self.callsKey)
                items.insert(contentsOf: [Self.text, Self.call], at: 0)
                save()
            }
        } else {
            defaults.set(true, forKey: Self.diagnosticsKey)
            defaults.set(true, forKey: Self.callsKey)
            items = [Self.text, Self.call] + Self.examples
            save()
        }
    }

    /// First launch: one intent for Notes and one for Clock (the demo run is the alarm).
    static var examples: [SavedTask] { [note, alarm, diagnostics] }
    /// Templates (Henry 2026-11-12): who, and what to say or talk about, are the user's to fill in; until the
    /// "[…]" blanks are edited the intent does not run.
    static var text: SavedTask {
        SavedTask(name: String(localized: "Text someone"),
                  prompt: String(localized: "Send a text message to [who]: [message]"), icon: "message.fill", color: "green")
    }
    static var call: SavedTask {
        SavedTask(name: String(localized: "Call someone"),
                  prompt: String(localized: "Call [who] and talk about [topic]"), icon: "phone.fill", color: "blue",
                  kind: "call")
    }
    nonisolated static let blanks = ["[who]", "[message]", "[topic]", "[联系人]", "[内容]", "[话题]"]
    nonisolated static func unfilled(_ prompt: String) -> Bool { blanks.contains { prompt.contains($0) } }

    /// For list subtitles: phone-number-like runs (7+ digits, spaces, dashes, a leading +) keep their first 3 and last 2
    /// digits (2026-11-13: Home's intent list showed whole numbers in every screen recording). The intent and its runs
    /// keep the real text.
    nonisolated static func maskingNumbers(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\+?\d[\d \-]{5,}\d"#) else { return text }
        var out = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: out) else { continue }
            let run = String(out[range]), digits = run.filter(\.isNumber)
            guard digits.count >= 7 else { continue }
            out.replaceSubrange(range, with: (run.hasPrefix("+") ? "+" : "") + digits.prefix(3)
                                + String(repeating: "•", count: digits.count - 5) + digits.suffix(2))
        }
        return out
    }

    static var note: SavedTask {
        SavedTask(name: String(localized: "Note: hello"), prompt: String(localized: "Open Notes and write \"hello\""))
    }
    static var alarm: SavedTask {
        SavedTask(name: String(localized: "7 AM daily alarm"),
                  prompt: String(localized: "Set an alarm for 7:00 AM that repeats every day, then save it"))
    }

    /// Sends the debug log, board state and crash reports to the developer (DiagnosticReport).
    static var diagnostics: SavedTask {
        SavedTask(name: String(localized: "Send diagnostics"),
                  prompt: String(localized: "Send the debug log, board state and crash reports to the developer"),
                  icon: "paperplane", builtin: "diagnostics")
    }

    func add(name: String, prompt: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        items.insert(SavedTask(name: trimmed.isEmpty ? String(prompt.prefix(30)) : trimmed, prompt: prompt), at: 0)
        save()
    }

    func delete(at offsets: IndexSet) {
        offsets.forEach { IntentFrames.delete(items[$0].id) }
        items.remove(atOffsets: offsets)
        save()
    }

    func delete(_ id: UUID) {
        IntentFrames.delete(id)
        items.removeAll { $0.id == id }
        save()
    }

    /// Adds a new intent or replaces the one with the same id.
    func upsert(_ item: SavedTask) {
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item } else { items.insert(item, at: 0) }
        save()
    }

    func item(_ id: UUID?) -> SavedTask? { items.first { $0.id == id } }

    func record(_ id: UUID, _ stat: RunStat) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].history = Array((items[i].runs + [stat]).suffix(50))
        save()
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(items), forKey: Self.key)
    }
}

/// One past or current agent run, read back from its trace folder.
struct Run: Identifiable, Equatable {
    struct Step: Identifiable, Equatable {
        let id: Int
        let action: JObject
        let frame: URL?  // the screenshot the model decided on
        let t: Double?

        var name: String { action["action"]?.str ?? "" }
        var isMove: Bool { !StepText.notMoves.contains(name) }
    }

    let id: String  // folder name, yyyyMMdd-HHmmss
    let folder: URL
    let task: String
    let date: Date
    let steps: [Step]
    var modelCalls = 0  // from the llm records of the trace
    var tokens = 0

    /// One line for a list row or a chat reply: "12 steps · 1m 3s · 14 AI calls · 52k tokens".
    static func statsText(steps: Int, seconds: Double?, calls: Int, tokens: Int) -> String {
        var parts = [String(localized: "\(steps) steps")]
        if let seconds { parts.append(seconds.durationText) }
        if calls > 0 { parts.append(String(localized: "\(calls) AI calls")) }
        if tokens > 0 {
            let t = tokens >= 1000 ? "\(Int((Double(tokens) / 1000).rounded()))k" : "\(tokens)"
            parts.append(String(localized: "\(t) tokens"))
        }
        return parts.joined(separator: " · ")
    }

    var stats: String { Self.statsText(steps: moves.count, seconds: duration, calls: modelCalls, tokens: tokens) }

    /// The low-fps recording of the mirror stream (video/<ms>.jpg), if it was on.
    var video: [(url: URL, t: Double)] {
        let dir = folder.appendingPathComponent("video")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { u in Double(u.deletingPathExtension().lastPathComponent).map { (u, $0 / 1000) } }
            .sorted { $0.t < $1.t }
    }

    var moves: [Step] { steps.filter(\.isMove) }
    /// Recorded from the person's own taps (DemoRecorder), not run by the agent.
    var isDemo: Bool { steps.contains { $0.action["demo"] == .bool(true) } }
    /// From someone else's shared archive: replay only.
    var imported: Bool { RunShare.isImported(folder) }
    var outcome: Outcome { Outcome(last: steps.last?.name, running: false) }
    func outcome(isActive: Bool) -> Outcome {
        Outcome(last: steps.last?.name, running: isActive)
    }
    /// What the run found for the user (the done step's answer); nil when it gave none. Text only for now.
    var result: String? {
        guard steps.last?.name == "done", let text = steps.last?.action["answer"]?.str, !text.isEmpty else { return nil }
        return text
    }
    var cover: URL? { steps.last(where: { $0.frame != nil })?.frame }
    var firstFrame: URL? { steps.first(where: { $0.frame != nil })?.frame }
    var duration: Double? {
        guard let a = steps.first?.t, let b = steps.last?.t else { return nil }
        return max(0, b - a)
    }
}

/// Runs on disk (Documents/traces), newest first.
@MainActor final class RunStore: ObservableObject {
    @Published private(set) var runs: [Run] = []
    let traces: TraceStore

    init(traces: TraceStore) { self.traces = traces }

    /// Runs read before, by folder, with their steps.jsonl's size and date then: a reload reads only what changed.
    /// 2026-11-11: every recorded step (several a round, during a run) parsed all 30 runs' steps again on the main
    /// thread, between the model's reply and the first gesture.
    private var cache: [URL: (stamp: Stamp, run: Run?)] = [:]
    struct Stamp: Equatable { let size: Int, date: Date }

    func reload(limit: Int = 30) {
        var kept: [URL: (stamp: Stamp, run: Run?)] = [:]
        runs = traces.runs().prefix(limit).compactMap { folder in
            let stamp = Self.stamp(folder)
            let run: Run?
            if let stamp, let old = cache[folder], old.stamp == stamp { run = old.run } else { run = Self.load(folder) }
            if let stamp { kept[folder] = (stamp, run) }
            return run
        }
        cache = kept
    }

    static func stamp(_ folder: URL) -> Stamp? {
        let path = folder.appendingPathComponent("steps.jsonl").path
        guard let a = try? FileManager.default.attributesOfItem(atPath: path), let size = a[.size] as? NSNumber,
              let date = a[.modificationDate] as? Date else { return nil }
        return Stamp(size: size.intValue, date: date)
    }

    static func load(_ folder: URL) -> Run? {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("steps.jsonl"), encoding: .utf8) else { return nil }
        var task = "", frame: URL?, steps: [Run.Step] = [], calls = 0, tokens = 0
        for line in text.split(separator: "\n") {
            guard let any = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                  case .obj(let rec) = PyJSON.from(any) else { continue }
            if let f = rec["frame"]?.str { frame = folder.appendingPathComponent(f) }
            switch rec["kind"]?.str {
            case "task": task = rec["task"]?.str ?? ""
            case "step": steps.append(Run.Step(id: steps.count, action: rec.without(["n", "t", "kind", "frame"]), frame: frame,
                                               t: rec["t"]?.double))
            case "verdict":  // the step's result, so a run continued from disk still says "-> screen changed"
                if let last = steps.popLast(), let changed = rec["changed"] {
                    var action = last.action
                    action["changed"] = changed
                    steps.append(Run.Step(id: last.id, action: action, frame: last.frame, t: last.t))
                }
            case "llm":
                calls += 1
                if case .obj(let u) = rec["usage"] {
                    tokens += u["total_tokens"]?.int ?? ((u["prompt_tokens"]?.int ?? 0) + (u["completion_tokens"]?.int ?? 0))
                }
            default: break
            }
        }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return Run(id: folder.lastPathComponent, folder: folder, task: task,
                   date: f.date(from: folder.lastPathComponent.replacingOccurrences(of: "imported-", with: "")) ?? Date(),
                   steps: steps, modelCalls: calls, tokens: tokens)
    }

    func run(_ id: String) -> Run? {
        runs.first { $0.id == id } ?? Self.load(traces.root.appendingPathComponent(id))
    }

    func delete(_ run: Run) throws {
        try FileManager.default.removeItem(at: run.folder)
        runs.removeAll { $0.id == run.id }
    }
}
