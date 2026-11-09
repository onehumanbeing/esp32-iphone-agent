import CoreGraphics
import Foundation

/// After a round: did the last action change the screen, and one aimed re-press for a tap that changed nothing.
extension AgentLoop {
    /// The last action's result, for the next round and the trace (written after the step row, which is out by then).
    func verdict(_ changed: Bool) {
        steps[steps.count - 1]["changed"] = .bool(changed)
        trace?.write(kind: "verdict", ["changed": .bool(changed), "pointer": .str("\(Int(pointerAt.x * 1000)) \(Int(pointerAt.y * 1000))")])
    }

    /// A tap that changed nothing is pressed once more, the pointer found and set on the target first (`aim`),
    /// unless the landing check already saw it there. Otherwise the model asks for the same tap again, a whole
    /// model call later; with the pointer seen on the target, pressing again rarely helps. Never pressed again: a
    /// round the user confirmed (or that followed a `confirm`: send, pay, post, delete), where a second press could
    /// repeat what can't be undone, and a target that was moving by itself, where "no change" proves nothing.
    func tapChanged(_ seen: Data?, _ spots: inout [CGPoint], quiet: [CGRect], confirmed: Bool) async throws -> Bool {
        if await tapResult(seen, &spots, quiet) { return true }
        let last = steps.count - 1
        guard let phone, !confirmed, let x = steps[last]["x"]?.double, let y = steps[last]["y"]?.double,
              !Self.onTarget(steps[last]), !quiet.contains(where: { $0.contains(CGPoint(x: x / 1000, y: y / 1000)) })
        else { return false }
        try await gate?()
        guard !connectionChanged(since: acceptedLookLinks) else { return false }
        DebugLog.write("step: the tap changed nothing; pressing once more with the pointer checked")
        try await phone.tap(x / 1000, y / 1000, aim: true)
        lastActed = now()
        steps[last]["again"] = .bool(true)
        _ = await settle(ignoring: spots)
        return await tapResult(seen, &spots, quiet)
    }

    /// Did the last tap change the screen? Only the pointer may have changed, landed off target: then find
    /// where it really is (which also teaches the pointer's correction) and look again without it. 2026-11-06:
    /// the pointer 3% above the Search pill read as "changed", so the miss went unseen and nothing was learned.
    func tapResult(_ seen: Data?, _ spots: inout [CGPoint], _ quiet: [CGRect]) async -> Bool {
        let (frame, mask) = (screen?.frame, spots)
        if await Vision.off({ Vision.bigChange(seen, frame, ignore: mask) }) { return true }
        let small = await Vision.off { Vision.changed(seen, frame, ignore: mask, quiet: quiet) }
        guard let landed = await noteLanding() else { return small }
        spots.append(landed)
        pointerAt = landed  // the next tap's mask starts where the pointer really is
        let (later, all) = (screen?.frame, spots)
        return small ? await Vision.off { Vision.changed(seen, later, ignore: all, quiet: quiet) } : false
    }

    /// The landing check saw the pointer on the tap's target (within 1.5% of the screen).
    static func onTarget(_ s: JObject) -> Bool {
        guard case .arr(let p)? = s["landed"], p.count == 2, let lx = p[0].double, let ly = p[1].double,
              let x = s["x"]?.double, let y = s["y"]?.double else { return false }
        return abs(lx - x) <= 15 && abs(ly - y) <= 15
    }

    /// A tap that changed little or nothing: find where the pointer really is, for the model (and the pointer's own
    /// correction, which learns from it), e.g. 37 units under a narrow button.
    @discardableResult
    func noteLanding() async -> CGPoint? {
        let last = steps.count - 1
        guard last >= 0, steps[last]["action"]?.str == "tap", let x = steps[last]["x"]?.double, let y = steps[last]["y"]?.double,
              let p = await phone?.landing(x / 1000, y / 1000) else { return nil }
        steps[last]["landed"] = .arr([.int(Int((p.x * 1000).rounded())), .int(Int((p.y * 1000).rounded()))])
        return p
    }
}
