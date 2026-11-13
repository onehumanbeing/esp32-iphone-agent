import Foundation

/// A saved intent's steps, run one by one before (or instead of) the model:
/// - a move (tap, swipe, type, key, home, back, wait) is done without the model while the screen matches the
///   step's reference screen;
/// - `ai GOAL` hands one sub-goal to the actor until it says done;
/// - `read` / `note` / `progress` / `write` work on the notebook; `manual REASON` waits for the user;
/// - with `until`, the script runs again until the condition holds on screen ("is it over?"), at most maxLoops.
/// A plain recording (moves only, no `until`) keeps the old behaviour: the first miss hands the rest of the task
/// to the model for good. In a script, a missed move is repaired by the model and the script goes on; a missed tap
/// nothing names is skipped.
extension AgentLoop {
    enum ScriptResult { case next, handOver, ended }

    nonisolated static let subGoalSteps = 12

    func scriptStep() async throws -> ScriptResult {
        guard let step = replay.current else { return try await scriptFinished() }
        let n = replay.next + 1
        let name = step.action["action"]?.str ?? ""
        // a plain recording replays moves only (a note in it goes to the model, as before)
        if !replay.isScript && !Replay.replayable.contains(name) { return await handOver(n, "not a move") }
        switch name {
        case "ai":
            guard try await subGoal(step.action["goal"]?.str ?? "", budget: step.action["budget"]?.int ?? Self.subGoalSteps,
                                  endText: step.action["end_text"]?.str, endAfter: step.action["end_after"]?.str) else { return .ended }
        case "manual":
            guard try await handToUser(step.action["reason"]?.str ?? "") else { return .ended }
        case "waittext":  // watch the screen until a line matches, without the model
            guard try await waitText(step.action["pattern"]?.str ?? "", seconds: step.action["seconds"]?.double ?? 60) else {
                guard try await repair(step, n, "not on screen in time") else { return .ended }
                break
            }
        case _ where step.action["blind"] == .bool(true):  // a fixed move: no reference screen to match
            _ = try await move(step)
        case _ where Actions.notebookActions.contains(name):
            var act = step.action
            try await notebookAction(&act)
            act["replay"] = .bool(true)
            record(screen?.frame, act)
        case "tap" where (step.action["label"]?.str?.count ?? 0) >= 2:  // one character names nothing (IntentLearner)
            guard let at = await labelled(step) else {
                let why = "\"\(step.action["label"]?.str ?? "")\" not on screen"
                guard replay.isScript else { return await handOver(n, why) }
                guard try await repair(step, n, why) else { return .ended }
                break
            }
            var found = step
            (found.action["x"], found.action["y"]) = (.int(at.x), .int(at.y))
            if !(try await move(found)) {
                guard replay.isScript else { return await handOver(n, "no change") }
                guard try await repair(step, n, "no change") else { return .ended }
            }
        default:
            if case .handOver(let why) = Replay.decide(step, screen: screen?.frame) {
                guard replay.isScript else { return await handOver(n, why) }
                let seen = await nearText(step)
                if name == "tap", why.hasPrefix("miss"), seen == nil {
                    // 2026-11-13: only its spot is known, and on another screen that spot is something else (the
                    // folder tap at 613, 702 hit the U key, then a group chat): skipped, not repaired by its spot
                    replay.miss(why)
                    record(screen?.frame, ["action": .str("skipped"), "reason": .str("skipped recorded tap: screen differs, nothing names it")])
                } else {
                    guard try await repair(step, n, why, seen: seen) else { return .ended }
                }
            } else if !(try await move(step)) {
                guard replay.isScript else { return await handOver(n, "no change") }
                guard try await repair(step, n, "no change", seen: await nearText(step)) else { return .ended }
            }
        }
        DebugLog.write("script step \(n) (\(name)): done")
        replay.advance()
        return .next
    }

    /// The run's start, for a task that names one app (AppNames.only): `open` it before the first look, done by
    /// the code. Its result is in the history like the model's own open ("auto").
    func autoOpen(_ app: String) async throws {
        let seen = screen?.frame
        var act: JObject = ["action": .str("open"), "app": .str(app), "auto": .bool(true)]
        DebugLog.write("auto open: the task names \(app)")
        onDoing?(.acting(act))
        let started = now()
        if let note = try await perform(act) { act[note.field] = .str(note.value) }
        lastActed = now()
        act["act_s"] = .num(((lastActed - started) * 100).rounded() / 100)
        _ = await settle()
        act["changed"] = .bool(Vision.changed(seen, screen?.frame))
        record(seen, act)
    }

    /// Polls the screen's text (OCR, about twice a second) until a line below the status bar matches `pattern` (a
    /// regex). False = timed out.
    func waitText(_ pattern: String, seconds: Double) async throws -> Bool {
        let until = now() + seconds
        onDoing?(.looking)
        while now() < until {
            try Task.checkCancellation()
            if let frame = screen?.frame,
               let hit = await DemoAnalysis.texts(frame, limit: 80).first(where: {  // below the status bar (its clock reads 2:47)
                   $0.y > 60 && $0.text.range(of: pattern, options: .regularExpression) != nil }) {
                record(frame, ["action": .str("waited"), "reason": .str("\"\(hit.text)\" showed")])
                return true
            }
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        return false
    }

    /// Where a demonstrated tap's label reads on this screen (OCR), nearest to the recorded spot.
    private func labelled(_ step: Replay.Step) async -> (x: Int, y: Int)? {
        guard let label = step.action["label"]?.str else { return nil }
        var at: (x: Int, y: Int)?
        // a sheet or Control Center may still be sliding in after the last move: read again for up to ~2 s
        for attempt in 0..<4 where at == nil {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 600_000_000) }
            guard let frame = screen?.frame else { return nil }
            at = Replay.locate(label, near: step.action["x"]?.int ?? 500, step.action["y"]?.int ?? 500,
                               in: await DemoAnalysis.texts(frame, limit: 80))
        }
        DebugLog.write("script: \"\(label)\" \(at.map { "at \($0.x) \($0.y)" } ?? "not on screen")")
        return at
    }

    /// The model does one sub-goal from the current screen, with no planner call. True = it said done.
    /// `endText`: a regex; once a line on screen matches (a call's "Call Ended"), the part is over without the model.
    /// `endAfter`: an action ("type") that ends the part once it went through, without a round to say done.
    func subGoal(_ goal: String, budget: Int = AgentLoop.subGoalSteps, endText: String? = nil,
                 endAfter: String? = nil) async throws -> Bool {
        let whole = task
        task = goal + "\n(This is one part of: \(whole). Say done as soon as this part is done.)"
        plan = goal
        inPart = true
        defer { task = whole; plan = ""; inPart = false }
        // Watched between the model's looks too: "Call Ended" shows for ~2 s, then Recents; checked only before a step it
        // was missed and the model went on in Control Center and Recents, about to call again (2026-11-13).
        let watch = endText.map { EndWatch(pattern: $0, frame: { [weak self] in self?.screen?.frame }) }
        defer { watch?.stop() }
        for _ in 0..<budget {
            if let watch, let hit = await watch.hit() {
                record(screen?.frame, ["action": .str("ai done"), "answer": .str("ended: \"\(hit)\" showed")])
                return true
            }
            guard try await step() else {
                // the model's action went through without a note on what failed (a `type` typed it all): part done
                if let endAfter, let last = steps.last(where: { $0["thought"] != nil }), last["action"]?.str == endAfter,
                   last["typed"] == nil, last["result"] == nil {
                    record(screen?.frame, ["action": .str("ai done"), "answer": .str("ended after \(endAfter)")])
                    return true
                }
                continue
            }
            guard steps.last?["action"]?.str == "done" else { return false }  // fail ends the run
            steps[steps.count - 1]["action"] = .str("ai done")
            return true
        }
        record(nil, ["action": .str("fail"), "reason": .str("part not done in \(budget) steps: \(goal)")])
        return false
    }

    /// The screen no longer matches a recorded move: the model does that step on the screen it sees, or skips it.
    /// `seen`: the text near an unlabelled tap's spot on its reference screen (`nearText`).
    private func repair(_ step: Replay.Step, _ n: Int, _ why: String, seen: String? = nil) async throws -> Bool {
        replay.miss(why)
        DebugLog.write("script step \(n): \(why) → AI repairs it")
        return try await subGoal(Self.repairGoal(step.action, n, seen: seen))
    }

    /// The step in words, never its x/y (Replay.words); subGoal adds the whole task. The model may skip a step that
    /// this screen or the task doesn't need (2026-11-13: three minutes spent looking for a Send key with nothing typed).
    nonisolated static func repairGoal(_ action: JObject, _ n: Int, seen: String?) -> String {
        "Recorded step \(n) was: \(Replay.words(action, seen: seen)). Do that on this screen if it still applies. "
            + "If it does not apply on this screen, or the task does not need it, say done to skip it."
    }

    /// What names an unlabelled tap: the text near its spot on its reference screen (OCR). nil for other steps.
    private func nearText(_ step: Replay.Step) async -> String? {
        guard (step.action["label"]?.str?.count ?? 0) < 2 else { return nil }
        return await IntentLearner.text(near: step.action, on: step.frame)
    }

    /// A recorded move, done without the model. False = the screen did not change.
    private func move(_ step: Replay.Step) async throws -> Bool {
        let seen = screen?.frame
        if try await pausedBeforeGesture() { return false }  // they paused; don't replay this move on a new screen
        var act = step.action
        onDoing?(.acting(act))
        let started = now()
        try await perform(act)
        lastActed = now()
        act["act_s"] = .num(((lastActed - started) * 100).rounded() / 100)
        let spots = [pointerAt] + pointerPath(act)
        pointerAt = spots.last!
        _ = await settle()
        let changed = act["action"]?.str == "wait" || Vision.changed(seen, screen?.frame, ignore: spots)
        act["replay"] = .bool(true)
        act["changed"] = .bool(changed)
        record(seen, act)
        return changed
    }

    /// A step only the user can do (log in, pick something): wait for them, then go on. False = they stopped.
    private func handToUser(_ reason: String) async throws -> Bool {
        guard let onHelp else {
            record(nil, ["action": .str("skipped"), "reason": .str("nobody to hand this to: \(reason)")])
            return true
        }
        record(nil, ["action": .str("help"), "reason": .str(reason)])
        let choice = await onHelp(reason)
        try Task.checkCancellation()
        switch choice {
        case .stop:
            record(nil, ["action": .str("stopped")])
            return false
        case .resume: record(nil, ["action": .str("takeover"), "reason": .str("the user did this part by hand: \(reason)")])
        case .skip: record(nil, ["action": .str("skipped"), "reason": .str("the user skipped: \(reason)")])
        }
        await screen?.settled()
        return true
    }

    /// The last step is done: check `until` and go round again, or let the model check the goal and finish.
    private func scriptFinished() async throws -> ScriptResult {
        guard replay.isScript, !replay.over, let until = replay.until else { return .handOver }
        if try await holds(until) {
            var done: JObject = ["action": .str("done"), "answer": .str(notebook.items.isEmpty ? until
                                    : "\(notebook.items.count) items collected")]
            attachNotebook(&done)
            record(nil, done)
            return .ended
        }
        guard replay.loops + 1 < replay.maxLoops else {
            record(nil, ["action": .str("fail"), "reason": .str("still not true after \(replay.maxLoops) rounds: \(until)")])
            return .ended
        }
        replay.nextLoop()
        notebook.setProgress("round \(replay.loops + 1) of at most \(replay.maxLoops)")
        return .next
    }

    /// "Is it over?": one yes/no look at the screen.
    func holds(_ condition: String) async throws -> Bool {
        guard let model = planner ?? actor else { throw LLMError(message: "no model") }
        let prompt = "Is this true on the current screen: \(condition)?" + (notebook.isEmpty ? "" : "\n\n" + notebook.summary())
            + "\nReply YES or NO, then one short reason."
        let (reply, seconds, frame) = try await ask("judge", model, "You check an iPhone screenshot against a condition.", prompt)
        let yes = reply.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("YES")
        record(frame, ["action": .str("check"), "reason": .str("\(condition) → \(yes ? "yes" : "no")"), "think_s": .num(seconds)])
        return yes
    }

    /// A plain recording's miss: the model does the rest, with the steps as hints. The taps still to come that no
    /// label names are named by the text near their spots first, so the hints say what they tapped (Replay.words).
    private func handOver(_ n: Int, _ why: String) async -> ScriptResult {
        DebugLog.write("replay step \(n): \(why) → AI")
        replay.miss(why)
        for i in replay.next..<replay.steps.count {
            if let seen = await nearText(replay.steps[i]) { replay.name(i, seen: seen) }
        }
        replay.stop()
        return .handOver
    }
}

/// Reads the live screen every 0.7 s for a line matching `pattern` (OCR) and keeps the first one seen.
@MainActor final class EndWatch {
    private var seen: String?
    private var task: Task<Void, Never>?
    private let pattern: String
    private let frame: () -> Data?

    init(pattern: String, frame: @escaping () -> Data?) {
        self.pattern = pattern
        self.frame = frame
        task = Task { [weak self] in
            while !Task.isCancelled, let self, self.seen == nil {
                await self.look()
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
    }

    /// The matching line seen so far, or on the screen now.
    func hit() async -> String? {
        if seen == nil { await look() }
        return seen
    }

    func stop() { task?.cancel() }

    private func look() async {
        guard seen == nil, let f = frame() else { return }
        seen = await DemoAnalysis.texts(f, limit: 80)
            .first { $0.text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }?.text
    }
}
