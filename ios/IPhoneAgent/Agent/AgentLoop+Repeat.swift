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

    /// The answer to that hold was the same gesture again (issue #166: runs went around this small loop). Asked
    /// once more, plainly; a third same answer is sent as before. Starts like `reason`, so StuckGuard leaves it out.
    static func insist(_ action: String) -> String {
        "Not done: the same \(action) a second time, and it already changed nothing. Do not repeat it: use a "
            + "different kind of action (another element, a scroll, back, a key, or ask for help)."
    }

    /// The first gesture of `acts`.
    static func first(_ acts: [JObject]) -> JObject? { acts.first { Actions.gestures.contains($0["action"]?.str ?? "") } }
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

    /// Only right after the commit: once another gesture came between (a bulk delete swipes the next row, taps its
    /// checkbox or a dialog's button), the same spot is a new item's button and is not held.
    static func repeated(_ acts: [JObject], after steps: [JObject]) -> JObject? {
        guard let tap = acts.first(where: { Actions.gestures.contains($0["action"]?.str ?? "") }),
              tap["action"]?.str == "tap", let x = tap["x"]?.double, let y = tap["y"]?.double,
              let at = steps.lastIndex(where: { $0["action"]?.str == "confirmed" }),
              let done = commit(in: steps), let dx = done["x"]?.double, let dy = done["y"]?.double,
              abs(x - dx) <= near, abs(y - dy) <= near,
              steps.last?["action"]?.str != RepeatGuard.action else { return nil }  // asked once already
        let since = steps[(at + 1)...].filter { $0["plan"] == nil && Actions.gestures.contains($0["action"]?.str ?? "") }
        let onlyThere = since.allSatisfy {
            $0["action"]?.str == "tap" && abs(($0["x"]?.double ?? -1e3) - dx) <= near && abs(($0["y"]?.double ?? -1e3) - dy) <= near
        }
        return onlyThere ? tap : nil
    }

    static let reason = "Not done: this taps where the confirmed step was already done, and would do it again "
        + "(add, send or buy twice). Look for proof it took effect (a success message, the cart's count, the sent "
        + "message) and finish with done; tap it again only if the screen shows it did not happen."
}

/// Back and forth: the new gesture would make A, B, A, B (two moves undoing each other, e.g. a tab and back, or a
/// sheet opened and closed). Held back once like a repeat. Only when the screen came back as it was: a bulk delete
/// (swipe the row, tap 删除, swipe the next row, tap 删除) repeats the same two moves on new content each time, and
/// `sameScreen` (the screens before the two A's) tells it apart.
enum LoopGuard {
    static func repeated(_ acts: [JObject], after steps: [JObject], sameScreen: (Int, Int) -> Bool = { _, _ in true }) -> JObject? {
        guard let new = acts.first(where: { Actions.gestures.contains($0["action"]?.str ?? "") }),
              RepeatGuard.held.contains(new["action"]?.str ?? "") else { return nil }
        let sent = steps.indices.filter { steps[$0]["plan"] == nil && Actions.gestures.contains(steps[$0]["action"]?.str ?? "") }.suffix(3)
        guard sent.count == 3 else { return nil }
        let (ia, ib, ic) = (sent[sent.startIndex], sent[sent.startIndex + 1], sent[sent.startIndex + 2])
        let (a, b, c) = (steps[ia], steps[ib], steps[ic])
        func same(_ p: JObject, _ q: JObject) -> Bool { NoProgress.same([p], [q]) }
        guard same(a, c), same(b, new), !same(a, b), sameScreen(ia, ic) else { return nil }
        return new
    }

    static let reason = "Not done: this would go back and forth between the same two moves (A, B, A, B) without "
        + "getting closer to the goal. Choose a different way, or ask for help."
}

/// Back and forth on a screen that changes each time: LoopGuard needs the screen to come back as it was, so two
/// taps that each reload a list (a sort and a search tab, 2026-11-17: about 150 taps in one run) were never held.
/// Here the screen is not looked at: the same two taps in turn for `cycles` rounds (the new one included) are held
/// once, and when the model goes on and the pair is held again, the run asks the user. A bulk delete that taps
/// the same two spots on each row is held once too; its second answer stands until the next `cycles` rounds.
enum PingPongGuard {
    static let cycles = 4  // A, B four times each: 8 taps

    /// The new tap when it would make the `cycles`-th round of the same two taps (or a tap and back) since the
    /// last hold of this guard.
    static func repeated(_ acts: [JObject], after steps: [JObject]) -> JObject? {
        guard let new = acts.first(where: { Actions.gestures.contains($0["action"]?.str ?? "") }) else { return nil }
        let since = steps.lastIndex(where: held).map { $0 + 1 } ?? 0
        return alternating(sent(steps[since...]).suffix(2 * cycles - 1) + [new]) ? new : nil
    }

    /// The pair was held before and the taps went on in turn ever since: asking the model again won't help.
    static func again(_ steps: [JObject], _ acts: [JObject]) -> Bool {
        guard let at = steps.lastIndex(where: held), let new = acts.first(where: { Actions.gestures.contains($0["action"]?.str ?? "") })
        else { return false }
        return alternating(sent(steps[..<at]).suffix(2 * cycles - 1) + sent(steps[(at + 1)...]) + [new])
    }

    private static func held(_ step: JObject) -> Bool { step["action"]?.str == RepeatGuard.action && step["reason"]?.str == reason }
    private static func sent(_ steps: ArraySlice<JObject>) -> [JObject] {
        steps.filter { $0["plan"] == nil && Actions.gestures.contains($0["action"]?.str ?? "") }
    }

    /// At least `cycles` rounds of two different taps in turn.
    private static func alternating(_ run: [JObject]) -> Bool {
        func same(_ p: JObject, _ q: JObject) -> Bool { NoProgress.same([p], [q]) }
        guard run.count >= 2 * cycles, run.allSatisfy(pair), !same(run[0], run[1]) else { return false }
        return run.indices.allSatisfy { same(run[$0], run[$0 % 2]) }
    }

    private static func pair(_ act: JObject) -> Bool { ["tap", "back"].contains(act["action"]?.str ?? "") }

    static let reason = "Not done: you have tapped the same two places in turn \(cycles) times. The screen changes, "
        + "but you are not getting closer to the goal. Choose a different way (another element, scroll, back), or ask for help."
    static let stuck = "stuck: tapped the same two places back and forth again after being told"
}

/// A swipe on the Home Screen pages through apps or pulls down Search: `open` starts any app from there. Held
/// back once; a swipe from a screen edge (Control Center, Notification Center) is not.
/// Swipe after swipe with nothing read, noted or tapped in between: what is looked for may be above, or the page
/// scrolled past the item into other content (recommendations under an order). Henry 2026-11-18: a detail page
/// scrolled into the feed below it and the model kept scrolling down. Held back once per run of swipes.
enum ScrollGuard {
    static let after = 3

    static func repeated(_ acts: [JObject], after steps: [JObject]) -> JObject? {
        guard let new = RepeatGuard.first(acts), new["action"]?.str == "swipe" else { return nil }
        var swipes = 0
        for step in steps.reversed() {
            let name = step["action"]?.str ?? ""
            if name == RepeatGuard.action, (step["reason"]?.str ?? "") == reason { return nil }  // asked once already
            if name == "swipe" { swipes += 1; continue }
            if Actions.gestures.contains(name) || ["read", "note", "collect", "find", "each"].contains(name) { break }
        }
        return swipes >= after ? new : nil
    }

    static let reason = "Not done: this is another scroll after \(after) in a row with nothing read or tapped. "
        + "Check the screen: if it shows content that is not what you are looking for (recommendations, another "
        + "list, the end of the item), you scrolled past it: scroll back up. If what you want is not on this page, "
        + "go back or use find \"WORDS\"."
}

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
        + "this screen itself answers it. When the goal is a question this screen or your answer already settles, "
        + "give the same done again: a second done is taken."
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
            + SendGuard.listedHint + "Else check the field; if it is wrong, \(SendGuard.clearHint) and type again, before sending."
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
    /// The screens the model saw before steps `i` and `j` look the same (pointer aside); unknown counts as the same.
    func sameShots(_ i: Int, _ j: Int) -> Bool {
        guard let a = shots[i], let b = shots[j] else { return true }
        return !Vision.changed(a, b, ignore: [pointerAt])
    }

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
        } else if LoopGuard.repeated(acts.map(\.act), after: steps, sameScreen: sameShots) != nil {
            DebugLog.write("loop guard: back and forth between two moves; asking once more")
            reason = LoopGuard.reason
        } else if PingPongGuard.repeated(acts.map(\.act), after: steps) != nil {
            if PingPongGuard.again(steps, acts.map(\.act)) {
                DebugLog.write("ping-pong guard: the same two taps again after a hold; asking for help")
                return [Planned(act: ["action": .str("fail"), "reason": .str(PingPongGuard.stuck)], shot: acts[0].shot)]
            }
            DebugLog.write("ping-pong guard: the same two taps in turn \(PingPongGuard.cycles) times; asking once more")
            reason = PingPongGuard.reason
        } else if ScrollGuard.repeated(acts.map(\.act), after: steps) != nil {
            DebugLog.write("scroll guard: \(ScrollGuard.after) scrolls in a row with nothing read or tapped; asking once more")
            reason = ScrollGuard.reason
        } else if HomeSwipeGuard.repeated(acts.map(\.act), after: steps, startsOnHome: homeAtStart) != nil {
            DebugLog.write("home swipe guard: a swipe on the Home Screen; asking once more")
            reason = HomeSwipeGuard.reason
        } else if TypedGuard.repeated(acts.map(\.act), after: steps) != nil {
            DebugLog.write("typed guard: a send right after a type that stopped part way; asking once more")
            reason = TypedGuard.reason(steps.last { $0["action"]?.str == "type" }?["typed"]?.str ?? "")
        } else if DoneGuard.premature(acts.map(\.act), after: steps, earlierRuns: !chatContext.isEmpty) {
            DebugLog.write("done guard: done before any move changed the screen; asking once more")
            reason = DoneGuard.reason
        } else if let audit = await recordAudit(acts.map(\.act)) {
            reason = audit
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
        var thought = (acts[0].act["think_s"]?.double ?? 0) + (again[0].act["think_s"]?.double ?? 0)
        if StuckGuard.repeatHold(reason), let held = RepeatGuard.first(acts.map(\.act)),
           let next = RepeatGuard.first(again.map(\.act)), NoProgress.same([next], [held]) {
            let name = next["action"]?.str ?? ""
            DebugLog.write("repeat guard: the same \(name) again after the hold; asking for another kind of action")
            var insist: JObject = ["action": .str(RepeatGuard.action), "reason": .str(RepeatGuard.insist(name))]
            if again[0].act["jev"] != nil { insist["jev"] = .bool(true) }
            record(again[0].shot, insist)
            checkpoints.asked = "repeat"
            again = try await nextActions()
            thought += again[0].act["think_s"]?.double ?? 0
        }
        again[0].act["think_s"] = .num((thought * 100).rounded() / 100)  // the round's thinking: every call
        return again
    }
}
