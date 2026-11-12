import Foundation

/// Phone calls the agent holds itself (Henry 2026-11-12, flow A): it speaks through iOS Live Speech (typed text the
/// iPhone says into the call; the board has no audio) and hears through Live Captions on screen and the phone audio
/// line. `say "TEXT"` types into the open Live Speech field and presses return. The guide goes into the actor's prompt
/// only for a task that sounds like a call, so other tasks pay nothing for it.
enum Calls {
    static let words = ["电话", "致电", "打给", "通话"]
    /// Whole words only: "iPhone" and "recall" are not calls.
    static let english = #"\b(call|calling|phone|ring|dial)\b"#

    static func isCall(_ task: String) -> Bool {
        words.contains { task.contains($0) } || task.range(of: english, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func prompt(_ task: String) -> String {
        guard isCall(task) else { return "" }
        return "\n\nPhone calls: a number goes in with `type` on Phone's Keypad (the board is a keyboard); the number "
            + "above the keys can take a moment to show. The Keypad has no text selection: cmd+a does nothing there, so "
            + "remove a wrong number with `key backspace` once per digit before typing it again. Check the whole number "
            + "shows once, `confirm`, then tap the call button once. Keep the call on the iPhone itself: if the call "
            + "screen shows Speaker on, tap Audio (or Speaker) and pick iPhone. Call sound never goes over AirPlay, so the "
            + "only way to hear the other side is Live Captions on screen. Both are buttons in Control Center (swipe down "
            + "from the top right corner): while the call still rings, turn Live Captions on there, then tap Live Speech "
            + "and `type` the first sentence into its field without enter; the moment they answer (the call timer "
            + "starts), `key enter` says it. Live Captions stay on screen until turned off: after hanging up, turn them "
            + "off in Control Center and check they are gone before `done`. If either button is not in Control Center, "
            + "`fail` and say which one to add (Control Center › + › Add a Control). To speak again, `say \"TEXT\"`: the "
            + "iPhone says TEXT into the call. One or two short sentences per say, in the other side's language, then wait and read the captions. Keep to the goal, never promise or agree to anything it "
            + "does not ask for, and hang up when it is done or the other side ends; `done` then sums up what was said."
    }
}

#if DEBUG
/// Settings › Developer › Call test (Debug builds only, never TestFlight or the App Store): the call flow as a
/// script, one step at a time, with the person on the other phone in the loop (`manual` waits for them).
extension Calls {
    static func test(number: String, line: String) -> SavedTask {
        func ai(_ goal: String) -> RecordedStep { RecordedStep(action: ["action": .str("ai"), "goal": .str(goal)], sure: true, frame: nil) }
        func manual(_ reason: String) -> RecordedStep { RecordedStep(action: ["action": .str("manual"), "reason": .str(reason)], sure: true, frame: nil) }
        return SavedTask(name: "Call test", prompt: "Call test: phone \(number), say one line, listen to the reply, hang up.",
                         steps: [
                            ai("Open Phone's Keypad, type \(number), check the whole number shows, then tap the call button once."),
                            ai("While it rings: in Control Center turn Live Captions on, then tap Live Speech and `type \"\(line)\"` into its field, without enter."),
                            ai("Watch with `wait` until the call timer starts (the other phone answered), then at once `key enter` to say the line."),
                            manual("Did the other phone hear it? Say one short sentence back, then resume."),
                            ai("Read what the other side just said from Live Captions; done with it as the answer."),
                            ai("Hang up the call."),
                            ai("Open Control Center, turn Live Captions off and check the caption panel is gone."),
                         ])
    }
}
#endif
