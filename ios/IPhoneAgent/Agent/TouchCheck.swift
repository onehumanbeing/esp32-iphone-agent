import Foundation

/// Gestures that reach the board but not the iPhone: the board acknowledges every move and click, yet iOS takes no
/// pointer from it (AssistiveTouch off, the board plugged into or paired with another device). The screen then never
/// changes and the run would spend its steps on taps that cannot work. Early in a run, a few pointer rounds that
/// changed nothing, with the pointer never seen by a landing check, ask for one probe (the pointer wiggled and looked
/// for); a probe that does not find it either stops the run with what to check.
/// Pure: the loop feeds each round's last step and the probe's answer. Armed only until the first sign that the
/// pointer works (a pointer round that changed the screen, or the pointer seen anywhere), so it costs nothing later.
struct TouchCheck {
    /// Pointer rounds that changed nothing before the probe.
    static let rounds = 3
    /// Actions that move the iOS pointer (keys, typing, Home and open go through the keyboard instead).
    static let pointerActions: Set<String> = ["tap", "swipe", "circle", "path", "back"]

    enum Next: Equatable { case wait, probe }

    private(set) var armed = true
    private(set) var unchanged = 0

    /// After a round: its last step (action, changed, landed).
    mutating func note(_ step: JObject) -> Next {
        guard armed, let action = step["action"]?.str, Self.pointerActions.contains(action),
              case .bool(let changed)? = step["changed"] else { return .wait }
        if changed || step["landed"] != nil { armed = false; return .wait }  // the pointer works
        unchanged += 1
        return unchanged >= Self.rounds ? .probe : .wait
    }

    /// The probe's answer: true = the pointer is not reaching the iPhone (stop and say so); nil = could not tell.
    mutating func probed(_ seen: Bool?) -> Bool {
        armed = false  // one verdict per run (re-armed when the user says to go on)
        return seen == false
    }

    /// Armed again, e.g. after the user fixed the setup and tapped Keep Going.
    mutating func rearm() { self = TouchCheck() }

    /// The step's reason (trace, help panel, free-line run end as `stall`).
    static let reason = "gestures do not reach the iPhone: the pointer was not seen and taps changed nothing"

    /// What to check, for people.
    static var advice: String {
        String(localized: "The board is connected, but the iPhone isn't taking its pointer. Check that AssistiveTouch is on (Settings › Accessibility › Touch › AssistiveTouch), that the board is plugged into this iPhone, then unplug and replug it.")
    }
}
