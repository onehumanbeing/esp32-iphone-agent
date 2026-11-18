import Foundation

/// The same gesture right after it left the screen unchanged is not sent at once: the model is asked once more in
/// the same round, with a line in its history saying so. Told "screen did NOT change", a model still often picks the
/// very same action; another target, a scroll, Back or asking for help is what moves a run on.
/// At most once per round: the same answer again is sent, so NoProgress, TouchCheck and the stall count still see
/// the repeats. Pure: the loop feeds the new reply's actions and the steps so far.
enum RepeatGuard {
    /// The step's action name (not a move: nothing was sent).
    static let action = "blocked"
    /// Gestures held back: all but Home, whose second press is not the same (Pointer.goHome flicks up then).
    static let held = Actions.gestures.subtracting(["home"])

    /// The new round's first gesture, when it is the same as the previous round's last one (NoProgress.same) and
    /// that left the screen unchanged (the verdict the stall count uses). Anything recorded in between (reconnected,
    /// help, a user's takeover) means the screen may be new: nil.
    static func repeated(_ acts: [JObject], after steps: [JObject]) -> JObject? {
        guard let first = acts.first(where: { Actions.gestures.contains($0["action"]?.str ?? "") }),
              held.contains(first["action"]?.str ?? ""),
              let last = steps.last(where: { $0["plan"] == nil }),
              Actions.gestures.contains(last["action"]?.str ?? ""), last["changed"] == .bool(false),
              NoProgress.same([first], [last]) else { return nil }
        return first
    }

    /// The line the model reads in its history: what was not done and what else there is.
    static func reason(_ action: String) -> String {
        "Not done: the same \(action) just left the screen unchanged. "
            + "Choose a different way (another target, scroll, back, open the app, or ask for help)."
    }
}

/// The tap right after a "confirmed" row did the risky thing (add to cart, send, buy, post). Another tap there
/// would do it again: iddzz 2026-11-12, the add-to-cart button sat where the options sheet's button was, every tap
/// "changed the screen", and four chairs went into the cart. Such a tap is not sent at once: the model is told why
/// and asked once more (the planner answers); its second answer stands.
/// A third tap on the same spot while the screen stays much the same, even when each one read as "changed": the
/// pointer, an animation or the Live Activity count as change, so the guard above lets such a repeat through. The rounds before must each have been that one tap with no big change
/// (NoProgress); a tap that moves the screen a lot each time (Next, Continue) is never held.
enum ThirdTapGuard {
    static func repeated(_ acts: [JObject], progress: NoProgress) -> JObject? {
        guard let first = acts.first(where: { Actions.gestures.contains($0["action"]?.str ?? "") }),
              first["action"]?.str == "tap", progress.repeats >= 1, !progress.moved, progress.last.count == 1,
              NoProgress.same([first], progress.last) else { return nil }
        return first
    }

    static let reason = "Not done: the same tap a third time, and the screen has stayed much the same. The target is "
        + "likely not what you think; choose another element, scroll, go back, or ask for help."
}

enum CommitGuard {
    static let near = 40.0  // the 0–1000 grid: the same button

    static func commit(in steps: [JObject]) -> JObject? {
        guard let at = steps.lastIndex(where: { $0["action"]?.str == "confirmed" }) else { return nil }
        return steps[(at + 1)...].first { $0["action"]?.str == "tap" }
    }

    static func repeated(_ acts: [JObject], after steps: [JObject]) -> JObject? {
        guard let tap = acts.first(where: { Actions.gestures.contains($0["action"]?.str ?? "") }),
              tap["action"]?.str == "tap", let x = tap["x"]?.double, let y = tap["y"]?.double,
              let done = commit(in: steps), let dx = done["x"]?.double, let dy = done["y"]?.double,
              abs(x - dx) <= near, abs(y - dy) <= near,
              steps.last?["action"]?.str != RepeatGuard.action else { return nil }  // asked once already
        return tap
    }

    static let reason = "Not done: this taps where the confirmed step was already done, and would do it again "
        + "(add, send or buy twice). Look for proof it took effect (a success message, the cart's count, the sent "
        + "message) and finish with done; tap it again only if the screen shows it did not happen."
}

/// Back and forth: the new gesture would make A, B, A, B (two moves undoing each other, e.g. a tab and back, or a
/// sheet opened and closed). Held back once like a repeat.
enum LoopGuard {
    static func repeated(_ acts: [JObject], after steps: [JObject]) -> JObject? {
        guard let new = acts.first(where: { Actions.gestures.contains($0["action"]?.str ?? "") }),
              RepeatGuard.held.contains(new["action"]?.str ?? "") else { return nil }
        let sent = steps.filter { $0["plan"] == nil && Actions.gestures.contains($0["action"]?.str ?? "") }.suffix(3)
        guard sent.count == 3 else { return nil }
        let (a, b, c) = (sent[sent.startIndex], sent[sent.startIndex + 1], sent[sent.startIndex + 2])
        func same(_ p: JObject, _ q: JObject) -> Bool { NoProgress.same([p], [q]) }
        guard same(a, c), same(b, new), !same(a, b) else { return nil }
        return new
    }

    static let reason = "Not done: this would go back and forth between the same two moves (A, B, A, B) without "
        + "getting closer to the goal. Choose a different way, or ask for help."
}

/// A swipe on the Home Screen pages through apps or pulls down Search: `open` starts any app from there. Held
/// back once; a swipe from a screen edge (Control Center, Notification Center) is not.
enum HomeSwipeGuard {
    static let edge = 80.0

    /// The screen is the Home Screen: the run's start, or a `home` since, with only swipes after it.
    static func onHome(_ steps: [JObject], startsOnHome: Bool) -> Bool {
        for s in steps.reversed() {
            let name = s["action"]?.str ?? ""
            if ["resumed", "takeover", "reconnected", "help", "skipped"].contains(name) { return false }
            guard s["plan"] == nil, Actions.gestures.contains(name) else { continue }
            if name == "swipe" { continue }
            return name == "home"
        }
        return startsOnHome
    }

    static func repeated(_ acts: [JObject], after steps: [JObject], startsOnHome: Bool = false) -> JObject? {
        guard let swipe = acts.first(where: { Actions.gestures.contains($0["action"]?.str ?? "") }),
              swipe["action"]?.str == "swipe", let x = swipe["x1"]?.double, let y = swipe["y1"]?.double,
              x > edge, x < 1000 - edge, y > edge, y < 1000 - edge, onHome(steps, startsOnHome: startsOnHome) else { return nil }
        return swipe
    }

    static let reason = "Not done: this is the Home Screen. Use open APP to start an app (it works from here); "
        + "swipe here only when the goal is about the Home Screen itself."
}

/// `done` from a run whose moves have changed nothing yet, in a chat with earlier runs: what the screen shows was
/// there when it started (an earlier run's result). Held back once; the second done stands.
enum DoneGuard {
    static func premature(_ acts: [JObject], after steps: [JObject], earlierRuns: Bool) -> Bool {
        guard earlierRuns, acts.contains(where: { $0["action"]?.str == "done" }),
              !steps.contains(where: { $0["action"]?.str == "resumed" }) else { return false }
        let changed = steps.contains { Actions.gestures.contains($0["action"]?.str ?? "") && $0["changed"] == .bool(true) }
        let asked = steps.contains { $0["action"]?.str == RepeatGuard.action && $0["reason"]?.str == reason }
        return !changed && !asked
    }

    static let reason = "Not done yet: nothing this run did has changed the screen, so what it shows was already "
        + "there when the run started (an earlier run counts for nothing here). Do the goal now; give done only if "
        + "this screen itself answers it."
}

/// A send right after a Chinese `type` that stopped part way: what is in the field may be pinyin letters, not the
/// words (a nine-key or another keyboard, a word left uncommitted). Held back once with what was left.
enum TypedGuard {
    static func repeated(_ acts: [JObject], after steps: [JObject]) -> JObject? {
        guard let new = acts.first(where: { Actions.gestures.contains($0["action"]?.str ?? "") }),
              let last = steps.last(where: { $0["plan"] == nil && Actions.gestures.contains($0["action"]?.str ?? "") }),
              last["action"]?.str == "type", last["typed"]?.str?.isEmpty == false,
              (last["text"]?.str ?? "").unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) else { return nil }
        let name = new["action"]?.str
        guard name == "tap" || (name == "key" && new["combo"]?.str?.lowercased() == "enter") else { return nil }
        return new
    }

    static func reason(_ left: String) -> String {
        "Not done: the last type stopped part way (\(left)), so the field may hold letters instead of the words. "
            + "Check the field; clear it and type again if it is wrong, before sending."
    }
}

/// Held back this often in a short while: the run is stuck, ask the person rather than try again.
enum StuckGuard {
    static let limit = 3, window = 12

    /// The hold about to happen would be the limit'th.
    static func stuck(_ steps: [JObject]) -> Bool {
        steps.suffix(window).filter { $0["action"]?.str == RepeatGuard.action && !repeatHold($0["reason"]?.str ?? "") }.count >= limit - 1
    }

    /// The repeat guard's own holds: NoProgress and the stall count handle those, as before.
    static func repeatHold(_ reason: String) -> Bool { reason.hasPrefix("Not done: the same ") }

    static let reason = "stuck: the same moves kept being held back (repeated, undone or with no effect)"
}

extension AgentLoop {
    /// The round's actions (nextActions), asked for once more when they start with a repeat of a gesture that just
    /// changed nothing. Not after a round a pause dropped (the flag is taken here): the person may have changed the
    /// screen meanwhile.
    func decide() async throws -> [Planned] {
        let afterPause = roundDroppedByPause
        roundDroppedByPause = false
        let acts = try await nextActions()
        guard !afterPause else { return acts }
        let reason: String
        if let held = RepeatGuard.repeated(acts.map(\.act), after: steps) {
            let name = held["action"]?.str ?? ""
            DebugLog.write("repeat guard: the same \(name) again right after it changed nothing; asking once more")
            reason = RepeatGuard.reason(name)
        } else if ThirdTapGuard.repeated(acts.map(\.act), progress: progress) != nil {
            DebugLog.write("third tap guard: the same tap a third time on a much unchanged screen; asking once more")
            reason = ThirdTapGuard.reason
        } else if CommitGuard.repeated(acts.map(\.act), after: steps) != nil {
            DebugLog.write("commit guard: a tap on the confirmed step's spot again; asking once more")
            reason = CommitGuard.reason
        } else if LoopGuard.repeated(acts.map(\.act), after: steps) != nil {
            DebugLog.write("loop guard: back and forth between two moves; asking once more")
            reason = LoopGuard.reason
        } else if HomeSwipeGuard.repeated(acts.map(\.act), after: steps, startsOnHome: startsOnHome) != nil {
            DebugLog.write("home swipe guard: a swipe on the Home Screen; asking once more")
            reason = HomeSwipeGuard.reason
        } else if TypedGuard.repeated(acts.map(\.act), after: steps) != nil {
            DebugLog.write("typed guard: a send right after a type that stopped part way; asking once more")
            reason = TypedGuard.reason(steps.last { $0["action"]?.str == "type" }?["typed"]?.str ?? "")
        } else if DoneGuard.premature(acts.map(\.act), after: steps, earlierRuns: !chatContext.isEmpty) {
            DebugLog.write("done guard: done before any move changed the screen; asking once more")
            reason = DoneGuard.reason
        } else {
            return acts
        }
        if !StuckGuard.repeatHold(reason), StuckGuard.stuck(steps) {  // the third hold in a short while: another ask won't help
            DebugLog.write("stuck guard: \(StuckGuard.limit) holds in \(StuckGuard.window) steps; asking for help")
            return [Planned(act: ["action": .str("fail"), "reason": .str(StuckGuard.reason)], shot: acts[0].shot)]
        }
        var row: JObject = ["action": .str(RepeatGuard.action), "reason": .str(reason)]
        if acts[0].act["jev"] != nil { row["jev"] = .bool(true) }
        record(acts[0].shot, row)
        // the user's model answers this one (on both lines): Jev reads the same plan and would offer the same step
        checkpoints.asked = "repeat"  // the planner answers the second ask (free line)
        let hold = JevGate.hold
        JevGate.hold = true
        defer { JevGate.hold = hold }
        var again = try await nextActions()
        let both = (acts[0].act["think_s"]?.double ?? 0) + (again[0].act["think_s"]?.double ?? 0)
        again[0].act["think_s"] = .num((both * 100).rounded() / 100)  // the round's thinking: both calls
        return again
    }
}
