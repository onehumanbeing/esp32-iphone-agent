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

    static let subGoalSteps = 12

    func scriptStep() async throws -> ScriptResult {
        guard let step = replay.current else { return try await scriptFinished() }
        let n = replay.next + 1
        let name = step.action["action"]?.str ?? ""
        // a plain recording replays moves only (a note in it goes to the model, as before)
        if !replay.isScript && !Replay.replayable.contains(name) { return handOver(n, "not a move") }
        switch name {
        case "ai":
            guard try await subGoal(step.action["goal"]?.str ?? "") else { return .ended }
        case "manual":
            guard try await handToUser(step.action["reason"]?.str ?? "") else { return .ended }
        case _ where Actions.notebookActions.contains(name):
            var act = step.action
            try await notebookAction(&act)
            act["replay"] = .bool(true)
            record(screen?.frame, act)
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

    /// The model does one sub-goal from the current screen, with no planner call. True = it said done.
    func subGoal(_ goal: String, budget: Int = AgentLoop.subGoalSteps) async throws -> Bool {
        let whole = task
        task = goal + "\n(This is one part of: \(whole). Say done as soon as this part is done.)"
        plan = goal
        defer { task = whole; plan = "" }
        for _ in 0..<budget {
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
        try await gate?()
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
