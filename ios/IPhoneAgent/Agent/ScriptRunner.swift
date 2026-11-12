import Foundation

/// A saved intent's steps, run one by one before (or instead of) the model:
/// - a move (tap, swipe, type, key, home, back, wait) is done without the model while the screen matches the
///   step's reference screen;
/// - `ai GOAL` hands one sub-goal to the actor until it says done;
/// - `read` / `note` / `progress` / `write` work on the notebook; `manual REASON` waits for the user;
/// - with `until`, the script runs again until the condition holds on screen ("is it over?"), at most maxLoops.
/// A plain recording (moves only, no `until`) keeps the old behaviour: the first miss hands the rest of the task
/// to the model for good. In a script, a missed move is repaired by the model and the script goes on.
extension AgentLoop {
    enum ScriptResult { case next, handOver, ended }

    nonisolated static let subGoalSteps = 12

    func scriptStep() async throws -> ScriptResult {
        guard let step = replay.current else { return try await scriptFinished() }
        let n = replay.next + 1
        let name = step.action["action"]?.str ?? ""
        // a plain recording replays moves only (a note in it goes to the model, as before)
        if !replay.isScript && !Replay.replayable.contains(name) { return handOver(n, "not a move") }
        switch name {
        case "ai":
            guard try await subGoal(step.action["goal"]?.str ?? "", budget: step.action["budget"]?.int ?? Self.subGoalSteps,
                                  endText: step.action["end_text"]?.str) else { return .ended }
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
                guard replay.isScript else { return handOver(n, why) }
                guard try await repair(step, n, why) else { return .ended }
                break
            }
            var found = step
            (found.action["x"], found.action["y"]) = (.int(at.x), .int(at.y))
            if !(try await move(found)) {
                guard replay.isScript else { return handOver(n, "no change") }
                guard try await repair(step, n, "no change") else { return .ended }
            }
        default:
            if case .handOver(let why) = Replay.decide(step, screen: screen?.frame) {
                guard replay.isScript else { return handOver(n, why) }
                guard try await repair(step, n, why) else { return .ended }
            } else if !(try await move(step)) {
                guard replay.isScript else { return handOver(n, "no change") }
                guard try await repair(step, n, "no change") else { return .ended }
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
    func subGoal(_ goal: String, budget: Int = AgentLoop.subGoalSteps, endText: String? = nil) async throws -> Bool {
        let whole = task
        task = goal + "\n(This is one part of: \(whole). Say done as soon as this part is done.)"
        plan = goal
        defer { task = whole; plan = "" }
        for _ in 0..<budget {
            if let endText, let frame = screen?.frame,
               let hit = await DemoAnalysis.texts(frame, limit: 80).first(where: { $0.text.range(of: endText, options: [.regularExpression, .caseInsensitive]) != nil }) {
                record(frame, ["action": .str("ai done"), "answer": .str("ended: \"\(hit.text)\" showed")])
                return true
            }
            guard try await step() else { continue }
            guard steps.last?["action"]?.str == "done" else { return false }  // fail ends the run
            steps[steps.count - 1]["action"] = .str("ai done")
            return true
        }
        record(nil, ["action": .str("fail"), "reason": .str("part not done in \(budget) steps: \(goal)")])
        return false
    }

    /// The screen no longer matches a recorded move: the model does that step on the screen it sees.
    private func repair(_ step: Replay.Step, _ n: Int, _ why: String) async throws -> Bool {
        DebugLog.write("script step \(n): \(why) → AI repairs it")
        return try await subGoal("Do the equivalent of recorded step \(n) on this screen: "
                                 + PyJSON.dumps(Actions.key(step.action), ascii: false))
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

    private func handOver(_ n: Int, _ why: String) -> ScriptResult {
        DebugLog.write("replay step \(n): \(why) → AI")
        replay.stop()
        return .handOver
    }
}
