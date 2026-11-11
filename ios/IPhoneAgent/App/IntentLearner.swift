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
        return text.isEmpty ? nil : text
    }
}

extension IntentStore {
    /// Back to the steps before the last learned ones (their screens too).
    func undoLearned(_ id: UUID) {
        guard var item = item(id), let old = item.previousSteps else { return }
        let folder = IntentFrames.folder(id), previous = IntentFrames.previous(id)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.moveItem(at: previous, to: folder)
        item.steps = old
        item.previousSteps = nil
        item.learnedFrom = nil
        upsert(item)
    }
}

extension AppModel {
    /// After a run of an intent (RunSession.ended): learn its steps when the replay missed and the run worked.
    func learnIntent(_ intent: SavedTask, run runID: String, steps: [JObject], done: Bool) {
        guard IntentLearner.shouldLearn(steps, done: done) else { return }
        Task {
            guard let run = runs.run(runID), var item = intents.item(intent.id) else { return }
            do {
                guard let learned = try await IntentLearner.steps(from: run, for: item.id) else { return }
                item.previousSteps = item.steps
                item.steps = learned
                item.learnedFrom = runID
                intents.upsert(item)
                let labels = learned.compactMap { $0.object?["label"]?.str }
                DebugLog.write("intent \"\(item.name)\": \(learned.count) steps learned from run \(runID) (labels: \(labels.joined(separator: ", ")))")
            } catch {
                DebugLog.write("intent \"\(item.name)\": learning from \(runID) failed: \(error.localizedDescription)")
            }
        }
    }
}
