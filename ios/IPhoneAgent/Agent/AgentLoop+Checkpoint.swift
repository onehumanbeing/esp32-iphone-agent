import Foundation

/// Free line: the rounds that need judgement go to a stronger model ("handsy-planner": Opus 5.5 on the gateway)
/// with the same prompt, screen and tree as the actor's; Qwen answers every other round. Henry 2026-11-11: on the
/// Maps case Qwen swiped five times with the answer on screen; Opus answered the right `done` 3/3, 4-6 s a call.
/// Checkpoints: the run's first round (the plan), a run circling (only swipes and scrolls, the plan unchanged),
/// the repeat guard's second ask, and a `done` from the actor (confirmed or overruled). A planner call that fails
/// falls back to the actor: the gateway serves it as a Qwen call itself when the planner is off or over its caps.
struct Checkpoints {
    /// Sent actions since the last checkpoint that were all swipes or scrolls: the run is circling.
    static let circleRounds = 4
    static let scrolls: Set<String> = ["swipe", "scroll"]

    /// steps.count at the last checkpoint; nil = none yet this run (the first round is one).
    var lastAt: Int?
    /// Asked for by code outside the round (the repeat guard).
    var asked: String?
    var calls = 0

    /// Why this round goes to the planner, or nil for the actor. `planChanged`: a plan row since the last checkpoint.
    func reason(_ steps: [JObject]) -> String? {
        guard let lastAt else { return "first round" }
        if let asked { return asked }
        let since = steps.dropFirst(min(lastAt, steps.count))
        if since.contains(where: { $0["action"]?.str == "plan" }) { return nil }
        let sent = since.filter { Actions.gestures.contains($0["action"]?.str ?? "") }
        guard sent.count >= Self.circleRounds else { return nil }
        return sent.suffix(Self.circleRounds).allSatisfy({ Self.scrolls.contains($0["action"]?.str ?? "") }) ? "circling" : nil
    }

    mutating func used(at count: Int) {
        (lastAt, asked) = (count, nil)
        calls += 1
    }
}

extension AgentLoop {
    /// One round's reply: from the planner at a checkpoint, else the actor. A planner error (an old gateway that
    /// doesn't know the model, a dropped call) falls back to the actor for this round.
    func askRound(_ reason: String?, _ actor: ChatModel, _ prompt: String, temperature: Double) async throws -> (String, Double, Data?) {
        if let reason, let planner = checkpointModel {
            checkpoints.used(at: steps.count)
            DebugLog.write("checkpoint (\(reason)): asking \(planner.model)")
            do {
                return try await ask("actor", planner, actorPrompt, prompt, temperature: temperature)
            } catch let e where !(e is CancellationError) && !Task.isCancelled {
                DebugLog.write("checkpoint: \(planner.model) failed (\(e.localizedDescription)); the actor answers")
            }
        }
        return try await ask("actor", actor, actorPrompt, prompt, temperature: temperature)
    }

    /// The actor said done (and the planner hasn't answered this round): the planner looks at the same screen.
    /// Its reply stands, whether it confirms done (often with a fuller answer) or goes on. nil = keep the actor's.
    func confirmDone(_ acts: [JObject], _ prompt: String) async throws -> (String, Double, Data?)? {
        guard let planner = checkpointModel, acts.contains(where: { $0["action"]?.str == "done" }) else { return nil }
        checkpoints.used(at: steps.count)
        DebugLog.write("checkpoint (done check): asking \(planner.model)")
        do {
            return try await ask("actor", planner, actorPrompt, prompt)
        } catch let e where !(e is CancellationError) && !Task.isCancelled {
            DebugLog.write("checkpoint: \(planner.model) failed (\(e.localizedDescription)); the actor's done stands")
            return nil
        }
    }
}
