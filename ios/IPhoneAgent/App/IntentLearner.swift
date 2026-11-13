import Foundation

/// Henry 2026-11-12: an intent fixes itself from a run that worked. When its recorded steps missed (the AI took
/// over and finished the task), the moves of that run become the intent's steps: each tap named by the text at
/// its spot (OCR on the screen it was done on), so the next run replays it by name (Replay.locate); its screens
/// become the reference screens. The intent's words and checklist are not touched; the old steps are kept in
/// `previousSteps` and their screens in IntentFrames.previous (one level of Undo).
enum IntentLearner {
    /// Moves kept from a run: what the agent did that changed the screen.
    static let kept: Set<String> = ["tap", "swipe", "type", "clear", "key", "home", "back", "open"]
    /// A tap's label: the OCR line nearest its spot, within this distance (0-1000 units).
    static let reach = 90.0

    /// Runs the user called wrong from the island (✗): never learned from.
    @MainActor static var rejected: Set<String> = []

    /// A checklist never grows past this by itself (what the user wrote is never dropped).
    static let checklistLimit = 8

    /// The lessons the actor offered on a run (`learn`, "App: point"), kept on the intent's checklist when the run
    /// ends done, so its next run starts with them (Henry 2026-11-12: an intent gets smarter by itself).
    static func lessons(_ steps: [JObject]) -> [String] {
        steps.filter { $0["action"]?.str == "learn" }
            .compactMap { $0["text"]?.str?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// True when the run is worth learning from: it ended done and the model, not the replay, did a move.
    static func shouldLearn(_ steps: [JObject], done: Bool) -> Bool {
        done && steps.contains { kept.contains($0["action"]?.str ?? "") && $0["replay"] != .bool(true) }
    }

    /// The run's moves as an intent's steps (frames copied to the intent's folder). nil = nothing usable.
    static func steps(from run: Run, for id: UUID) async throws -> [RecordedStep]? {
        let moves = run.steps.filter { kept.contains($0.name) && $0.action["changed"] != .bool(false) }
        guard !moves.isEmpty else { return nil }
        let folder = IntentFrames.folder(id)
        let staging = folder.deletingLastPathComponent().appendingPathComponent(id.uuidString + ".new")
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var result: [RecordedStep] = []
        for (i, step) in moves.enumerated() {
            var action = Actions.key(step.action)
            let data = step.frame.flatMap { try? Data(contentsOf: $0) }
            if step.name == "tap", let data, let x = action["x"]?.int, let y = action["y"]?.int,
               let label = label(at: x, y, in: await DemoAnalysis.texts(data, limit: 80)) {
                action["label"] = .str(label)
            }
            var name: String?
            if let data {
                name = String(format: "s%02d.jpg", i + 1)
                try data.write(to: staging.appendingPathComponent(name!), options: .atomic)
            }
            result.append(RecordedStep(action: action, sure: true, frame: name))
        }
        let previous = IntentFrames.previous(id)  // the old screens, for Undo
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: folder, to: previous)
        try FileManager.default.moveItem(at: staging, to: folder)
        return result
    }

    /// The text at a tap's spot: the nearest OCR line within `reach`.
    static func label(at x: Int, _ y: Int, in lines: [DemoAnalysis.Line]) -> String? {
        func distance(_ l: DemoAnalysis.Line) -> Double { hypot(Double(l.x - x), Double(l.y - y)) }
        guard let near = lines.min(by: { distance($0) < distance($1) }), distance(near) <= reach else { return nil }
        let text = near.text.trimmingCharacters(in: .whitespaces)
        // One character ("x", an icon's glyph read as text) names nothing: the replay would find it anywhere
        // (iddzz 2026-11-12: the Photo & Video folder learned as "x"). Unlabelled, the tap replays by its spot.
        return text.count < 2 ? nil : text
    }
}

extension AppModel {
    /// ✓ / ✗ from a done run's Live Activity. Wrong: the run counts as failed for its intent, and steps learned
    /// from it are undone (or never learned, when the answer comes first).
    func runVerdict(_ run: String, correct: Bool) {
        live.verdictGiven()
        DebugLog.write("run \(run): the user says \(correct ? "correct" : "wrong")")
        guard !correct else { return }
        IntentLearner.rejected.insert(run)
        for item in intents.items where item.runs.last?.run == run {
            intents.markLastRun(item.id, ok: false)
            if let steps = runs.run(run)?.steps.map(\.action) {
                intents.removeLessons(item.id, IntentLearner.lessons(steps))
            }
            if item.learnedFrom == run {
                intents.undoLearned(item.id)
                if intents.item(item.id)?.refRun == run { intents.clearReference(item.id) }
            }
        }
    }
}

extension IntentStore {
    /// New lessons onto the checklist, up to IntentLearner.checklistLimit, none twice.
    func addLessons(_ id: UUID, _ lessons: [String]) {
        guard var item = item(id), !lessons.isEmpty else { return }
        var list = item.hints ?? []
        for lesson in lessons where !list.contains(lesson) && list.count < IntentLearner.checklistLimit {
            list.append(lesson)
        }
        guard list != (item.hints ?? []) else { return }
        item.hints = list
        upsert(item)
    }

    /// A run called wrong: the lessons it brought go again.
    func removeLessons(_ id: UUID, _ lessons: [String]) {
        guard var item = item(id), !lessons.isEmpty, let list = item.hints else { return }
        item.hints = list.filter { !lessons.contains($0) }
        if item.hints != list { upsert(item) }
    }

    /// A run called wrong is no intent's reference.
    func clearReference(_ id: UUID) {
        guard var item = item(id) else { return }
        item.refRun = nil
        upsert(item)
    }

    /// The intent's last run counts as `ok` after all.
    func markLastRun(_ id: UUID, ok: Bool) {
        guard var item = item(id), var runs = item.history, !runs.isEmpty else { return }
        runs[runs.count - 1].ok = ok
        item.history = runs
        upsert(item)
    }

    /// Learning finished after a ✗: put the previous screens back (the steps were never saved).
    func undoLearnedFrames(_ id: UUID) {
        let folder = IntentFrames.folder(id), previous = IntentFrames.previous(id)
        guard FileManager.default.fileExists(atPath: previous.path) else { return }
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.moveItem(at: previous, to: folder)
    }

    /// Back to the steps before the last learned ones (their screens too).
    func undoLearned(_ id: UUID) {
        guard var item = item(id), item.learnedFrom != nil else { return }
        let old = item.previousSteps  // nil: it had none (an intent typed in)
        let folder = IntentFrames.folder(id), previous = IntentFrames.previous(id)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.moveItem(at: previous, to: folder)  // none: it had no screens either
        item.steps = old
        item.previousSteps = nil
        item.learnedFrom = nil
        upsert(item)
    }
}

extension AppModel {
    /// After a run of an intent (RunSession.ended): learn its steps when the replay missed and the run worked.
    /// Henry 2026-11-12: any intent, when Settings › Intents learn from runs is on. An intent typed in (no reference
    /// run yet) gets its first run that worked as its reference run, and its steps.
    func learnIntent(_ intent: SavedTask, run runID: String, steps: [JObject], done: Bool) {
        guard settings.learnFromRuns else { return }
        if done, !IntentLearner.rejected.contains(runID) {
            let lessons = IntentLearner.lessons(steps)
            intents.addLessons(intent.id, lessons)
            if !lessons.isEmpty { DebugLog.write("intent \"\(intent.name)\": checklist +\(lessons.count) lesson(s) from run \(runID)") }
        }
        guard IntentLearner.shouldLearn(steps, done: done) else { return }
        Task {
            guard !IntentLearner.rejected.contains(runID),  // ✗ came first
                  let run = runs.run(runID), var item = intents.item(intent.id) else { return }
            do {
                guard let learned = try await IntentLearner.steps(from: run, for: item.id) else { return }
                if IntentLearner.rejected.contains(runID) { return intents.undoLearnedFrames(item.id) }
                item.previousSteps = item.steps
                item.steps = learned
                item.learnedFrom = runID
                if item.refRun == nil { item.refRun = runID }
                intents.upsert(item)
                let labels = learned.compactMap { $0.object?["label"]?.str }
                DebugLog.write("intent \"\(item.name)\": \(learned.count) steps learned from run \(runID) (labels: \(labels.joined(separator: ", ")))")
            } catch {
                DebugLog.write("intent \"\(item.name)\": learning from \(runID) failed: \(error.localizedDescription)")
            }
        }
    }
}
