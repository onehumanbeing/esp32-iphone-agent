import Foundation

/// The rounds that need judgement go to a stronger model with the same prompt, screen and tree as the actor's;
/// the actor answers every other round. Free line: the gateway's planner ("handsy-planner"). Own endpoint: the
/// Planner model in Settings › Model › Advanced, when it is set and differs from the actor's.
/// Checkpoints: the run's first round (the plan), a run circling (only swipes and scrolls, the plan unchanged),
/// the repeat guard's second ask, and a `done` from the actor (confirmed or overruled). A planner call that fails
/// falls back to the actor (the gateway also serves it with the actor's model when its planner is unavailable).
struct Checkpoints {
    /// Sent actions since the last checkpoint that were all swipes or scrolls: the run is circling.
    static let circleRounds = 4
    static let scrolls: Set<String> = ["swipe", "scroll"]
    /// Sent actions since the last checkpoint after which the planner reviews the run anyway (Henry 2026-11-17: the
    /// stronger model should look over a long run as it goes; a run opened the same order twice and waited three
    /// times for words that were below the fold, with no checkpoint after the first round).
    static let reviewEvery = 10
    static let reviewNote = "Review (the stronger model looks over the run every few steps): compare the notebook and "
        + "recent actions with the goal. Say in THINK what is done, what was repeated or did not work, and the "
        + "shortest way to finish; fix the PLAN if needed, then give the next action. When the same open-item, read, "
        + "go-back round was done twice on a list, give each \"ANCHOR\" read \"WHAT\" for the rest instead.\n\n"

    static let revisitNote = "Going round (the stronger model looks because this screen came back a third time with "
        + "nothing new in the notebook): say in THINK which screens the run went between and why it did not get "
        + "closer to the goal, then choose a different way to reach it, or ask for help.\n\n"
    /// Screens with progress between them are not going round: the notebook grew.
    static let progressActions: Set<String> = ["read", "collect", "note", "progress", "remember", "write"]

    /// The screen the last gesture was decided on came back for the third time since `from` (the last checkpoint)
    /// with no notebook row in between (2026-11-21: 10 of 58 user runs went page, home, page until the step or
    /// time limit; every screen changed, so the circling check, which counts swipes only, never fired).
    /// `same(i, j)`: the screenshots of steps i and j show the same screen.
    static func revisited(_ steps: [JObject], from: Int, same: (Int, Int) -> Bool) -> Bool {
        let shown = steps.indices.filter { $0 >= from && steps[$0]["shot"] == .bool(true)
            && Actions.gestures.contains(steps[$0]["action"]?.str ?? "") }
        guard let last = shown.last else { return false }
        var seen = 1
        for i in shown.dropLast().reversed() {
            if steps[i..<last].contains(where: { progressActions.contains($0["action"]?.str ?? "") }) { break }
            if same(i, last) { seen += 1 }
            if seen >= 3 { return true }
        }
        return false
    }

    /// steps.count at the last checkpoint; nil = none yet this run (the first round is one).
    var lastAt: Int?
    /// Asked for by code outside the round (the repeat guard).
    var asked: String?
    var calls = 0
    /// The planner answered the current round (the trace's "planner" flag).
    var answered = false

    /// Why this round goes to the planner, or nil for the actor. `planChanged`: a plan row since the last checkpoint.
    func reason(_ steps: [JObject]) -> String? {
        guard let lastAt else { return "first round" }
        if let asked { return asked }
        let since = steps.dropFirst(min(lastAt, steps.count))
        let sent = since.filter { Actions.gestures.contains($0["action"]?.str ?? "") }
        if sent.count >= Self.reviewEvery { return "review" }  // a new plan does not hold the review off
        if since.contains(where: { $0["action"]?.str == "plan" }) { return nil }
        guard sent.count >= Self.circleRounds else { return nil }
        return sent.suffix(Self.circleRounds).allSatisfy({ Self.scrolls.contains($0["action"]?.str ?? "") }) ? "circling" : nil
    }

    mutating func used(at count: Int) {
        (lastAt, asked) = (count, nil)
        calls += 1
    }
}

extension AgentLoop {
    /// Why this round goes to the planner: the checkpoints' own reasons, or the run going round between screens.
    var checkpointReason: String? {
        guard checkpointModel != nil else { return nil }
        if let reason = checkpoints.reason(steps) { return reason }
        guard let from = checkpoints.lastAt else { return nil }
        // only screenshots both there count (a run resumed from disk has the steps but not their screens)
        let same = { (i: Int, j: Int) in self.shots[i] != nil && self.shots[j] != nil && self.sameShots(i, j) }
        return Checkpoints.revisited(steps, from: from, same: same) ? "revisit" : nil
    }

    /// One round's reply: from the planner at a checkpoint, else the actor. A planner error (an old gateway that
    /// doesn't know the model, a dropped call) falls back to the actor for this round.
    func askRound(_ reason: String?, _ actor: ChatModel, _ prompt: String, temperature: Double) async throws -> (String, Double, Data?) {
        checkpoints.answered = false
        if let reason, let planner = checkpointModel {
            checkpoints.used(at: steps.count)
            DebugLog.write("checkpoint (\(reason)): asking \(planner.model)")
            do {
                let asked = reason == "review" ? Checkpoints.reviewNote + prompt
                    : reason == "revisit" ? Checkpoints.revisitNote + prompt : prompt
                let reply = try await ask("actor", planner, actorPrompt, asked, temperature: temperature)
                checkpoints.answered = true
                return reply
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
        if Self.doneIsShown(notebook.count, wrote: resultWritten) {
            // 2026-11-18: progress 3/3, README written, and the check still took 19 s to say done
            DebugLog.write("checkpoint (done check): skipped, progress \(notebook.progress) reached and the result written")
            return nil
        }
        checkpoints.used(at: steps.count)
        DebugLog.write("checkpoint (done check): asking \(planner.model)")
        do {
            let reply = try await ask("actor", planner, actorPrompt, prompt)
            checkpoints.answered = true
            return reply
        } catch let e where !(e is CancellationError) && !Task.isCancelled {
            DebugLog.write("checkpoint: \(planner.model) failed (\(e.localizedDescription)); the actor's done stands")
            return nil
        }
    }

    /// Done needs no second look when the progress count is reached and the run wrote its result file.
    nonisolated static func doneIsShown(_ count: (done: Int, total: Int?)?, wrote: Bool) -> Bool {
        guard wrote, let count, let total = count.total, total > 0 else { return false }
        return count.done >= total
    }
}
