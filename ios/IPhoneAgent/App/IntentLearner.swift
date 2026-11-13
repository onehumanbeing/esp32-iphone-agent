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

    /// Henry 2026-11-13: a run that failed teaches too. Its notes in words (never a screen): the task, why it
    /// failed, the last thoughts and the recorded steps that missed, phone numbers masked. One call gives at most
    /// one checklist hint, kept as a lesson of that run (removed again when the run is called wrong).
    static let failurePrompt = """
    An AI agent operating an iPhone failed a saved task. From its notes, write ONE hint for the task's checklist \
    that would make the next run succeed: what to do differently, true for this task every time. No names of \
    people, no message text, no numbers read off the screen. At most 120 characters, in the task's language. \
    Reply with the hint only, or NONE when the notes do not show what went wrong.
    """

    static func failureNotes(task: String, steps: [JObject], missed: [String], checklist: [String]) -> String? {
        guard let fail = steps.last(where: { $0["action"]?.str == "fail" }) ?? steps.last else { return nil }
        let why = fail["reason"]?.str ?? fail["thought"]?.str ?? ""
        let thoughts = steps.compactMap { $0["thought"]?.str }.suffix(4).map { "- " + $0.prefix(240) }
        guard !why.isEmpty || !thoughts.isEmpty else { return nil }
        var lines = ["Task: \(task)", "Why it stopped: \(why.prefix(300))"]
        if !thoughts.isEmpty { lines.append("Its last thoughts:\n" + thoughts.joined(separator: "\n")) }
        if !missed.isEmpty { lines.append("Recorded steps that missed: " + missed.joined(separator: "; ")) }
        if !checklist.isEmpty { lines.append("The checklist already says:\n" + checklist.map { "- " + $0 }.joined(separator: "\n")) }
        return IntentStore.maskingNumbers(lines.joined(separator: "\n"))
    }

    /// The model's reply as a hint: one line, NONE or empty = nil, cut at 160 characters.
    static func failureLesson(_ reply: String) -> String? {
        let line = reply.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let hint = line.trimmingCharacters(in: CharacterSet(charactersIn: "-•\" ")).trimmingCharacters(in: .whitespaces)
        guard hint.count >= 6, hint.uppercased() != "NONE", !hint.uppercased().hasPrefix("NONE") else { return nil }
        return String(hint.prefix(160))
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

    /// The text near a recorded tap's spot on the screen it was done on (OCR), nil when none names it.
    static func text(near action: JObject, on frame: Data?) async -> String? {
        guard action["action"]?.str == "tap", let frame, let x = action["x"]?.int, let y = action["y"]?.int else { return nil }
        return label(at: x, y, in: await DemoAnalysis.texts(frame, limit: 80))
    }

    /// Henry 2026-11-13: a run of an intent that did not finish (failed, or stopped by the user) where recorded moves
    /// missed: those moves stop being replayed. A tap nothing names (no label, no text near its spot on its screen) is
    /// dropped, since its spot means nothing on another screen (the folder tap at 613, 702 hit the U key and a group
    /// chat); any other becomes an AI step that says what it did ("Tap \"文件传输助手\""). The other steps stay.
    /// nil = nothing to change.
    static func demoted(_ steps: [RecordedStep], missed: Set<Int>, for id: UUID) async -> [RecordedStep]? {
        guard !missed.isEmpty else { return nil }
        var result: [RecordedStep] = [], i = -1, changed = false
        for step in steps {
            guard let action = step.object else { result.append(step); continue }
            i += 1  // the index Replay(intent:) gave it: steps that don't parse aren't in the replay
            let name = action["action"]?.str ?? ""
            guard missed.contains(i), Replay.replayable.contains(name) else { result.append(step); continue }
            changed = true
            let named = (action["label"]?.str?.count ?? 0) >= 2
            let seen = name == "tap" && !named ? await text(near: action, on: IntentFrames.data(id, step.frame)) : nil
            if name == "tap" && !named && seen == nil { continue }
            result.append(RecordedStep(action: ["action": .str("ai"), "goal": .str(Replay.words(action, seen: seen))],
                                       sure: true, frame: step.frame))
        }
        return changed ? result : nil
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

    /// Steps demoted after a run that did not finish (IntentLearner.demoted): the same Undo as learned steps. The
    /// screens stay; a copy goes to IntentFrames.previous so Undo puts the same ones back.
    func demote(_ id: UUID, to steps: [RecordedStep], from run: String) {
        guard var item = item(id) else { return }
        let folder = IntentFrames.folder(id), previous = IntentFrames.previous(id)
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.copyItem(at: folder, to: previous)  // none: it had no screens
        item.previousSteps = item.steps
        item.steps = steps
        item.learnedFrom = run
        upsert(item)
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
    /// `missed`: the recorded steps that missed in the run (Replay.missed); a run that did not finish demotes them.
    func learnIntent(_ intent: SavedTask, run runID: String, steps: [JObject], done: Bool, failed: Bool = false,
                     missed: Set<Int> = []) {
        guard settings.learnFromRuns else { return }
        if done, !IntentLearner.rejected.contains(runID) {
            let lessons = IntentLearner.lessons(steps)
            intents.addLessons(intent.id, lessons)
            if !lessons.isEmpty { DebugLog.write("intent \"\(intent.name)\": checklist +\(lessons.count) lesson(s) from run \(runID)") }
        }
        if failed { learnFromFailure(intent, run: runID, steps: steps, missed: missed) }
        if !done { return demoteMissed(intent, run: runID, missed: missed) }
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

    /// A run that failed (not one the user stopped): one hint from its notes onto the checklist (IntentLearner.failurePrompt).
    private func learnFromFailure(_ intent: SavedTask, run runID: String, steps: [JObject], missed: Set<Int>) {
        let replay = Replay(intent: intent)
        let words = missed.sorted().compactMap { replay.steps.indices.contains($0) ? Replay.words(replay.steps[$0].action) : nil }
        guard !MockMode.on, let notes = IntentLearner.failureNotes(task: intent.prompt, steps: steps, missed: words,
                                                                   checklist: intent.checklist) else { return }
        Task {
            do {
                let reply = try await settings.client("planner").chat(system: IntentLearner.failurePrompt, text: notes, image: nil,
                                                                      maxTokens: 120, temperature: 0)
                guard !IntentLearner.rejected.contains(runID), let lesson = IntentLearner.failureLesson(reply.text) else { return }
                intents.addLessons(intent.id, [lesson])
                DebugLog.write("intent \"\(intent.name)\": checklist +1 lesson from failed run \(runID)")
            } catch {
                DebugLog.write("intent \"\(intent.name)\": no lesson from failed run \(runID): \(error.localizedDescription)")
            }
        }
    }

    /// A run that did not finish: its missed steps leave the intent's replay (IntentLearner.demoted), with Undo.
    private func demoteMissed(_ intent: SavedTask, run runID: String, missed: Set<Int>) {
        guard !missed.isEmpty, let steps = intent.steps else { return }
        Task {
            guard !IntentLearner.rejected.contains(runID),
                  let demoted = await IntentLearner.demoted(steps, missed: missed, for: intent.id),
                  !IntentLearner.rejected.contains(runID),
                  intents.item(intent.id)?.steps == steps else { return }  // edited meanwhile: those are the user's
            intents.demote(intent.id, to: demoted, from: runID)
            DebugLog.write("intent \"\(intent.name)\": \(missed.count) missed step(s) demoted after run \(runID) "
                           + "(\(steps.count) → \(demoted.count) steps)")
        }
    }
}
