import CoreGraphics
import Foundation

/// The same gesture leaving the screen unchanged time after time. 2026-11-24: 47 of 122 runs (254 steps; 24 / 83 the
/// day before) tapped, opened or went Home again and again while nothing changed, until the user stopped them or the
/// lease ended. The guards before let it through: RepeatGuard looks only at the step right before (a `wait` or a note
/// between two taps hid the repeat), holds no Home and, held twice, sends the same answer anyway; ThirdTapGuard and
/// NoProgress count whole rounds, start over on any other round in between (a wait, a held answer) and NoProgress
/// waits five of them; the stall count needs twelve.
///
/// Only a confirmed "no change" counts here (`still` on the step, AgentLoop.confirmStill): a frame captured after the
/// action arrived, the round's settle was done, the screen was not moving by itself (StepWaits.moving) and a tap's
/// target was not a part that moves by itself. With no frame the result is unknown, never "unchanged" (2026-11-23,
/// iPhone X: a tap had worked but no frame had come, and the press again sent a message's leftover text).
/// Twice: one line in the next actor request (the same call, no extra one). Three times: one more settle and look,
/// since a slow phone or link may be the cause, and only if the screen is still the same the user is asked.
/// Pure: the loop feeds the steps.
enum StillRepeat {
    static let hintAt = 2, askAt = 3
    /// Rows after which the screen may be new or the user stepped in: the count starts over.
    static let breaks: Set<String> = ["resumed", "takeover", "reconnected", "help", "skipped", "restarted", "fail", "stale_look"]

    /// Confirmed no-changes of the same gesture (NoProgress.same: kind, target within a few units, text, key, app) in a
    /// row at the end of `steps`. Rows that sent nothing in between (a hold, a note, a wait that changed nothing) don't
    /// break it; a change, an unknown result or another gesture does. `say` speaks into a call: the screen needn't move.
    static func count(_ steps: [JObject]) -> Int {
        var n = 0
        var first: JObject?
        for s in steps.reversed() {
            let name = s["action"]?.str ?? ""
            if s["changed"] == .bool(true) || breaks.contains(name) { break }
            guard s["plan"] == nil, Actions.gestures.contains(name) else { continue }
            guard name != "say", s["still"] == .bool(true), first.map({ NoProgress.same([s], [$0]) }) ?? true else { break }
            first = first ?? s
            n += 1
        }
        return n
    }

    /// The line for the actor's prompt (empty below `hintAt`): next to the reply, where the model reads it.
    static func hint(_ steps: [JObject]) -> String {
        let n = count(steps)
        guard n >= hintAt, let last = steps.last(where: { Actions.gestures.contains($0["action"]?.str ?? "") }) else { return "" }
        return "\n\nDid nothing \(n) times: \(command(last)) was done \(n) times in a row and the screen stayed the same "
            + "each time (a new screen image came after each). Do not do it again: try a different way (another "
            + "element, a scroll, back, or another route to the goal)."
    }

    /// The gesture as the model writes it, e.g. `tap 500 812`, `open Settings`.
    static func command(_ s: JObject) -> String {
        let name = s["action"]?.str ?? ""
        func n(_ k: String) -> String { s[k]?.double.map { String(Int($0.rounded())) } ?? "?" }
        switch name {
        case "tap", "circle": return "`\(name) \(n("x")) \(n("y"))`"
        case "swipe": return "`swipe \(n("x1")) \(n("y1")) \(n("x2")) \(n("y2"))`"
        case "open": return "`open \(s["app"]?.str ?? "")`"
        case "key": return "`key \(s["combo"]?.str ?? "")`"
        case "type": return "`type \"\((s["text"]?.str ?? "").prefix(40))\"`"
        default: return "`\(name)`"
        }
    }

    /// The fail step's reason: a stall by its prefix (the free line's reason, the help panel's Keep Going).
    static let reason = "the screen did not change after the same action \(askAt) times, nor on a second look"

    /// What the user reads (Live Activity, notification).
    static var message: String {
        String(localized: "The same step changed nothing three times, even after a longer wait.")
    }
}

extension AgentLoop {
    /// A frame captured at or after `t` is shown. Unknown times (0, or no screen: the fakes) count as arrived.
    func frameSince(_ t: Double) -> Bool {
        guard let screen else { return true }
        let shown = screen.capturedAt > 0 ? screen.capturedAt : screen.updated
        return shown == 0 || shown >= t
    }

    /// After the round's settle, for a step that read as "no change": confirmed (`still`), or unknown for want of a
    /// frame after the action (`noframe`; the model reads "effect unknown"). A screen that moves by itself, or a tap on
    /// a part that does (`quiet`), proves nothing either way: neither. `final` false: right after the early settle
    /// (LookAhead), before the rest of the wait, where a frame may still come; set then, a speculative prompt stays
    /// the one the round ends with.
    func confirmStill(quiet: [CGRect], final: Bool = true) {
        let last = steps.count - 1
        guard last >= 0, steps[last]["changed"] == .bool(false) else { return }
        let target = steps[last]["x"]?.double.flatMap { x in steps[last]["y"]?.double.map { CGPoint(x: x / 1000, y: $0 / 1000) } }
        if StepWaits.moving || target.map({ p in quiet.contains { $0.contains(p) } }) == true {
            steps[last]["still"] = nil
            return
        }
        guard steps[last]["still"] == nil, steps[last]["noframe"] == nil else { return }
        if frameSince(lastActed) {
            steps[last]["still"] = .bool(true)
        } else if final {
            steps[last]["noframe"] = .bool(true)
            DebugLog.write("verdict: no frame since the action; its effect is unknown, not \"no change\"")
        }
    }

    /// After a round: the same gesture changed nothing `StillRepeat.askAt` times. One more settle and a look at a
    /// frame from after it; still the same: a fail step is recorded (true: ask the user). Changed meanwhile: the step
    /// reads "changed" and the run goes on. No frame came: unknown, the run goes on.
    func stillAgain() async throws -> Bool {
        let n = StillRepeat.count(steps)
        guard n >= StillRepeat.askAt,
              let at = steps.lastIndex(where: { Actions.gestures.contains($0["action"]?.str ?? "") }) else { return false }
        try await gate?()
        cancelSpeculative("one more look before asking for help")
        let name = steps[at]["action"]?.str ?? ""
        let mask = [pointerAt] + pointerPath(steps[at], geometry: screen?.geometry)
        let looked = now()
        await screen?.settled(ignoring: mask)
        if !frameSince(looked) { _ = await screen?.fresh(since: looked) }
        guard frameSince(looked) else {
            DebugLog.write("still repeat: no frame on the second look; the result stays unknown, the run goes on")
            return false
        }
        let (before, after) = (shots[at], screen?.frame)
        if await Vision.off({ Vision.changed(before, after, ignore: mask) }) {
            DebugLog.write("still repeat: the \(name) changed the screen after a longer wait; the run goes on")
            steps[at]["changed"] = .bool(true)
            steps[at]["still"] = nil
            trace?.write(kind: "verdict", ["changed": .bool(true), "late": .bool(true)])
            prepareFrame(after)
            return false
        }
        DebugLog.write("still repeat: the same \(name) changed nothing \(n) times, nor on a second look; asking for help")
        record(nil, ["action": .str("fail"), "reason": .str(StillRepeat.reason), "message": .str(StillRepeat.message)])
        return true
    }
}
