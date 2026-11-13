import CoreGraphics
import Foundation

/// Rounds that repeat the last one and leave the screen much as it was: no progress, whatever the verdict said.
/// A small change, such as a clock ticking or a caret blinking, reads as "changed" and resets the stall count, so
/// the same tap could go on until the step limit. After `limit` repeats in a row the run asks for help, as a stall
/// does. Pure: the loop feeds each round's gestures and whether the screen changed a lot since the round before.
struct NoProgress {
    /// Repeats in a row (after the first round) that ask for help.
    static let limit = 4
    /// Coordinates this close (0-1000 units) are the same spot.
    static let near = 30.0

    private(set) var repeats = 0
    /// The previous round's gestures, and whether it changed the screen a lot (true before the first round).
    private(set) var last: [JObject] = []
    private(set) var moved = true
    /// Where the previous round left off: steps seen, the screen, the pointer.
    var seen = 0, frame: Data?, pointer = CGPoint.zero

    /// After a round: true = no progress (counted again from zero).
    mutating func note(_ acts: [JObject], big: Bool) -> Bool {
        repeats = !acts.isEmpty && !big && Self.same(acts, last) ? repeats + 1 : 0
        (last, moved) = (acts, big)
        guard repeats >= Self.limit else { return false }
        repeats = 0
        return true
    }

    /// The same gestures: same actions, coordinates within `near`, same text, keys and app.
    static func same(_ a: [JObject], _ b: [JObject]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { p, q in
            p["action"] == q["action"] && ["text", "combo", "app"].allSatisfy { p[$0] == q[$0] }
                && ["x", "y", "x1", "y1", "x2", "y2", "r"].allSatisfy { k in
                    switch (p[k]?.double, q[k]?.double) {
                    case let (u?, v?): abs(u - v) <= near
                    case (nil, nil): true
                    default: false
                    }
                }
        }
    }

    /// The step's reason (trace, help panel; a stall for the free line, by its prefix).
    static let reason = "the screen did not change after the same action repeated"

    /// What to check, for people.
    static var advice: String {
        String(localized: "The same action keeps leaving the screen as it was. Check that the pointer shows on the iPhone (AssistiveTouch on, the board connected).")
    }
}

extension AgentLoop {
    /// After a round: TouchCheck and NoProgress, both on whether the screen changed a lot since the round before
    /// (NoProgress starts over after the user's help, so it does not fire again at once). True = a fail step is
    /// recorded: ask for help.
    func stuck() async throws -> Bool {
        let round = steps[min(progress.seen, steps.count)...]
        let acts = round.filter { Actions.gestures.contains($0["action"]?.str ?? "") }
        let before = progress.frame ?? round.indices.lazy.compactMap { self.shots[$0] }.first  // first: what the model saw
        let (frame, spots) = (screen?.frame, [progress.pointer, pointerAt])
        (progress.seen, progress.frame, progress.pointer) = (steps.count, frame, pointerAt)
        let helped = round.contains { $0["action"]?.str == "help" }
        let big = await Vision.off { Vision.bigChange(before, frame, ignore: spots) }
        if try await touchless(big: big) { return true }
        guard progress.note(Array(acts), big: big || helped) else { return false }
        DebugLog.write("no progress: the same action \(NoProgress.limit + 1) rounds in a row, the screen much the same")
        record(nil, ["action": .str("fail"), "reason": .str(NoProgress.reason)])
        return true
    }

    /// Home again after a Home round that changed little: the key may not have taken effect (Pointer.goHome).
    var homeAgain: Bool { !progress.moved && progress.last.last?["action"]?.str == "home" }
}
