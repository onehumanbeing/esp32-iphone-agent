import Foundation

/// A task saved for reuse ("intent"): a short name and the prompt the agent gets.
struct SavedTask: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var prompt: String
    var icon: String?
    var hints: [String]?     // checklist, appended to the actor prompt as hints when it runs
    var refRecording: String? // folder name of the original demonstration
    var refRun: String?      // the run it was made from
    var steps: [RecordedStep]? // replayed before asking the model (Replay)
    var history: [RunStat]?  // its runs, newest last
    var builtin: String?     // "diagnostics": runs in the app (sends the report), no board or model
    var until: String?      // a script repeats its steps until this is true on screen (ScriptRunner)
    var maxLoops: Int?       // at most this many rounds of an `until` script (default 5)

    var symbol: String { icon ?? "bolt.fill" }
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let saved = try? JSONDecoder().decode([SavedTask].self, from: data) {
            items = saved
            if !defaults.bool(forKey: Self.diagnosticsKey) {  // existing installs get it once; deleting it sticks
                defaults.set(true, forKey: Self.diagnosticsKey)
                if !items.contains(where: { $0.builtin == Self.diagnostics.builtin }) { items.append(Self.diagnostics); save() }
            }
        } else {
            defaults.set(true, forKey: Self.diagnosticsKey)
            items = Self.examples
            save()
        }
    }

    /// First launch: one intent for Notes and one for Clock (the demo run is the alarm).
    static var examples: [SavedTask] { [note, alarm, diagnostics] }
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

    /// The low-fps recording of the mirror stream (video/<ms>.jpg), if it was on.
    var video: [(url: URL, t: Double)] {
        let dir = folder.appendingPathComponent("video")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { u in Double(u.deletingPathExtension().lastPathComponent).map { (u, $0 / 1000) } }
            .sorted { $0.t < $1.t }
    }

    var moves: [Step] { steps.filter(\.isMove) }
    /// From someone else's shared archive: replay only.
    var imported: Bool { RunShare.isImported(folder) }
    var outcome: Outcome { Outcome(last: steps.last?.name, running: false) }
    func outcome(isActive: Bool) -> Outcome {
        Outcome(last: steps.last?.name, running: isActive)
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

    func reload(limit: Int = 30) {
        runs = traces.runs().prefix(limit).compactMap(Self.load)
    }

    static func load(_ folder: URL) -> Run? {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("steps.jsonl"), encoding: .utf8) else { return nil }
        var task = "", frame: URL?, steps: [Run.Step] = []
        for line in text.split(separator: "\n") {
            guard let any = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                  case .obj(let rec) = PyJSON.from(any) else { continue }
            if let f = rec["frame"]?.str { frame = folder.appendingPathComponent(f) }
            switch rec["kind"]?.str {
            case "task": task = rec["task"]?.str ?? ""
            case "step": steps.append(Run.Step(id: steps.count, action: rec.without(["n", "t", "kind", "frame"]), frame: frame,
                                               t: rec["t"]?.double))
            default: break
            }
        }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return Run(id: folder.lastPathComponent, folder: folder, task: task,
                   date: f.date(from: folder.lastPathComponent.replacingOccurrences(of: "imported-", with: "")) ?? Date(),
                   steps: steps)
    }

    func run(_ id: String) -> Run? {
        runs.first { $0.id == id } ?? Self.load(traces.root.appendingPathComponent(id))
    }

    func delete(_ run: Run) throws {
        try FileManager.default.removeItem(at: run.folder)
        runs.removeAll { $0.id == run.id }
    }
}
