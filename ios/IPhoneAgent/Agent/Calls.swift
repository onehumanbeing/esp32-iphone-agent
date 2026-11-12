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
            + "only way to hear the other side is Live Captions on screen; they understand English best and may mishear "
            + "other languages, so read them with care. Speak in the goal's language. Both are buttons in Control Center (swipe down "
            + "from the top right corner): while the call still rings, turn Live Captions on there, then tap Live Speech "
            + "and `type` the first sentence into its field without enter (Live Speech is open when its text field and the "
            + "keyboard show at the bottom; its button does not stay lit, never tap it again); the moment they answer (the call timer "
            + "starts), `key enter` says it. Live Captions stay on screen until turned off: after hanging up, turn them "
            + "off in Control Center and check they are gone before `done`. Find each button by its name (Live Captions, "
            + "Live Speech) and tap it once: a lit button is on, never tap it again. If a button is not there by name, "
            + "`fail` and say which one to add or widen (Control Center › + › Add a Control; drag its corner so its name "
            + "shows). To speak again, `say \"TEXT\"`: the "
            + "iPhone says TEXT into the call. One or two short sentences per say, in the other side's language, then wait and read the captions. Keep to the goal, never promise or agree to anything it "
            + "does not ask for, and hang up when it is done or the other side ends; `done` then sums up what was said."
    }
}

/// A task that is a call ("Call Mom and …", "打电话给妈妈…", the Call template) runs as a script: the model dials;
/// code opens Control Center, turns Live Captions on and opens Live Speech while it rings; the model types the first
/// sentence; code says it the moment the call is answered; the model talks and hangs up; code turns captions off.
/// The model-only way took too long: the call was answered before anything was ready.
extension Calls {
    static let dialing = [#"^\s*(please\s+)?(call|dial|phone|ring)\s"#, #"^\s*(请)?(帮我)?(打电话给|拨打|致电)"#, #"给.{1,20}打(个|一个)?电话"#]

    /// The task asks to place a call (not just mentions a phone).
    static func dials(_ task: String) -> Bool {
        dialing.contains { task.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// A saved intent's Phone call switch wins ("call" / "task"); without one, the words decide.
    static func isCall(_ task: String, kind: String?) -> Bool { kind.map { $0 == "call" } ?? dials(task) }

    /// The call screen once either side hung up.
    static let ended = #"^(call ended|通话结束)"#
    /// The call screen right after dialing: the dial part ends here without a model round to say so.
    static let calling = #"^(calling|呼叫中|正在呼叫|正在拨号)"#

    static func ai(_ goal: String, budget: Int? = nil, end: String? = nil) -> RecordedStep {
        var a: JObject = ["action": .str("ai"), "goal": .str(goal)]
        if let budget { a["budget"] = .int(budget) }
        if let end { a["end_text"] = .str(end) }
        return RecordedStep(action: a, sure: true, frame: nil)
    }

    static func move(_ a: JObject) -> RecordedStep {
        var a = a
        a["blind"] = .bool(true)
        return RecordedStep(action: a, sure: true, frame: nil)
    }

    /// A Control Center button: by the person's marked spot, else by its name (large buttons show it; the model
    /// repairs a miss).
    static func button(_ label: String, at spot: (x: Int, y: Int)? = nil) -> RecordedStep {
        guard let spot else {
            return RecordedStep(action: ["action": .str("tap"), "x": .int(500), "y": .int(500), "label": .str(label)], sure: true, frame: nil)
        }
        return RecordedStep(action: ["action": .str("tap"), "x": .int(spot.x), "y": .int(spot.y), "blind": .bool(true),
                                     "note": .str(label)], sure: true, frame: nil)
    }

    static let controlCenter = move(["action": .str("swipe"), "x1": .int(930), "y1": .int(5), "x2": .int(930), "y2": .int(450)])
    /// The call screen's timer (0:05, 00:05) shows once the other side answers; "Calling…" before.
    static let answered = RecordedStep(action: ["action": .str("waittext"), "pattern": .str(#"^\d{1,2}:\d{2}$"#), "seconds": .num(60)],
                                       sure: true, frame: nil)

    /// Where the two large buttons sit when set up as asked (side by side at the bottom of Control Center: Live
    /// Speech left, Live Captions right), 0-1000; Settings › Developer can change them, empty = found by name.
    static var spots: (captions: (x: Int, y: Int)?, speech: (x: Int, y: Int)?) {
        func read(_ key: String, _ fallback: String) -> (x: Int, y: Int)? {
            let n = (UserDefaults.standard.string(forKey: key) ?? fallback).split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Int($0) }
            return n.count == 2 ? (n[0], n[1]) : nil
        }
        return (read("callTestCaptions", "707 820"), read("callTestSpeech", "290 820"))
    }

    /// Nothing opens before dialing (the panels would cover the Keypad); right after, code opens both by their spots
    /// at once, before it is answered.
    static func script(_ task: String) -> [RecordedStep] {
        let (captions, speech) = spots
        return [
         move(["action": .str("open"), "app": .str("Phone")]),  // by code: the model's own open cost a round
         ai("Phone is open. Place the call the goal asks for: find the contact (search or Contacts) or type the number on the Keypad, then tap the call button once; do both in one reply when you can. The call is what the user asked for: no `confirm`.", end: calling),
         controlCenter, button("Live Captions", at: captions), button("Live Speech", at: speech),
         move(["action": .str("home")]),  // Control Center stays over Live Speech until closed (the model took ~25 s to close it)
         ai("Live Speech is open: its text field is focused with the keyboard at the bottom (its button does not stay lit; never tap it again, never tap the field or the call buttons). `type` the first short sentence to say for the goal (a greeting and why you call, in the goal's language), without enter. Done once it is typed."),
         answered,
         move(["action": .str("key"), "combo": .str("enter")]),
         ai("Hold the call for the goal. Your first sentence is already said: never say it, or anything you said before, again. Read what they said since your last line in Live Captions and answer that with `say` (one short sentence); with nothing new from them, `wait`. Hang up when the goal is done or they end it. Done with a summary of what was said.", budget: 30, end: ended),
         controlCenter, button("Live Captions", at: captions), move(["action": .str("home")]),
         ai("If the Live Speech text field still shows, close it; done once it is gone (or was not there).", budget: 4)]

    }
}

#if DEBUG
/// Settings › Developer › Call test (Debug builds only, never TestFlight or the App Store): the call flow as a
/// script, one step at a time, with the person on the other phone in the loop (`manual` waits for them).
extension Calls {
    /// `captions` / `speech`: where those Control Center buttons are (0-1000), when the person marked them; else they
    /// are looked for by name (wide buttons show it) and the model repairs a miss.
    static func test(number: String, line: String, captions: (x: Int, y: Int)? = nil, speech: (x: Int, y: Int)? = nil) -> SavedTask {
        func manual(_ reason: String) -> RecordedStep { RecordedStep(action: ["action": .str("manual"), "reason": .str(reason)], sure: true, frame: nil) }
        return SavedTask(name: "Call test", prompt: "Call test: phone \(number), say one line, listen to the reply, hang up.",
                         steps: [
                            ai("Open Phone's Keypad, type \(number), check the whole number shows, then tap the call button once."),
                            controlCenter, button("Live Captions", at: captions), button("Live Speech", at: speech),
                            move(["action": .str("type"), "text": .str(line)]),
                            answered,
                            move(["action": .str("key"), "combo": .str("enter")]),
                            manual("Did the other phone hear it? Say one short sentence back, then resume."),
                            ai("Read what the other side just said from Live Captions; done with it as the answer."),
                            ai("Hang up the call."),
                            controlCenter, button("Live Captions", at: captions), move(["action": .str("home")]),
                         ])
    }
}
#endif
