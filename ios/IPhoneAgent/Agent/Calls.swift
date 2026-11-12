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
        return "\n\nPhone calls: `confirm` before dialing. To speak, open Live Speech (Control Center › Live Speech, "
            + "or the AssistiveTouch menu) and give `say \"TEXT\"`: the iPhone says TEXT into the call. One or two short "
            + "sentences per say, in the other side's language, then wait and listen. To hear, read Live Captions on "
            + "screen (turn them on in Control Center if they are not showing) and the \"Phone audio\" line. Keep to the "
            + "goal, never promise or agree to anything it does not ask for, and hang up when it is done or the other "
            + "side ends; `done` then sums up what was said."
    }
}
