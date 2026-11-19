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
        // The Home Screen's Search pill: Spotlight over a plain wallpaper (no on-screen keyboard with the board's) can
        // look like no change, and the second press then landed on Spotlight's suggestions under the pointer and
        // opened another app (a game, this agent).
        if await SearchPill.tapped(seen, at: CGPoint(x: x / 1000, y: y / 1000)) {
            DebugLog.write("step: the Search pill tap read as no change; not pressed again (Spotlight may be opening)")
            return false
        }
        if try await pausedBeforeGesture() { return false }  // they paused; the screen may not be the one tapped
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
        let started = now()
        let (frame, mask) = (screen?.frame, spots)
        if await Vision.off({ Vision.bigChange(seen, frame, ignore: mask) }) {
            verdictSpent += (now() - started) * 1000
            return true
        }
        let small = await Vision.off { Vision.changed(seen, frame, ignore: mask, quiet: quiet) }
        if small, let target = tapTarget() {
            let near = await Vision.off { Vision.changed(seen, frame, at: target, ignore: mask) }
            if Self.changedNearTarget(near) {
                DebugLog.write("step: the tap changed the screen at the target; skipping the pointer check")
                verdictSpent += (now() - started) * 1000
                return true
            }
        }
        // Not on a screen that keeps moving (a map, a video: StepWaits.moving): there the wiggle's diff is mostly the
        // screen's own motion, and each look took 1.8-2.4 s, often "not found" (2026-11-11, a Maps run).
        let landStarted = now()
        guard !StepWaits.moving, let landed = await noteLanding() else {
            verdictSpent += (now() - started) * 1000
            return small
        }
        let landMs = (now() - landStarted) * 1000
        landingSpent += landMs
        spots.append(landed)
        pointerAt = landed  // the next tap's mask starts where the pointer really is
        let (later, all) = (screen?.frame, spots)
        let hit = small ? await Vision.off { Vision.changed(seen, later, ignore: all, quiet: quiet) } : false
        verdictSpent += max(0, (now() - started) * 1000 - landMs)
        return hit
    }

    /// The last tap, near an edge, opened the AssistiveTouch menu: close it (esc), remember the spot for this run and
    /// tell the model. True = it was the menu (the screen is back as it was).
    func closedAssistiveMenu() async throws -> Bool {
        guard let phone, steps.last?["action"]?.str == "tap", let x = steps.last?["x"]?.double, let y = steps.last?["y"]?.double,
              AssistiveTouchGuard.nearEdge(x, y), let jpeg = screen?.frame, let image = Vision.image(jpeg) else { return false }
        let lines = await UITreeOCR.lines(image)
        guard AssistiveTouchGuard.menuShown(lines, size: CGSize(width: image.width, height: image.height)) else { return false }
        DebugLog.write("step: tap \(Int(x)), \(Int(y)) opened the AssistiveTouch menu; closing it")
        try await phone.key("esc")
        _ = await settle(ignoring: [])
        assistiveHits.append(CGPoint(x: x, y: y))
        AssistiveTouchSpots.remember(x: x / 1000, y: y / 1000)
        steps[steps.count - 1]["result"] = .str(AssistiveTouchGuard.opened)
        return true
    }

    /// The last tap's target in screen fractions, when the step has one.
    func tapTarget() -> CGPoint? {
        guard steps.last?["action"]?.str == "tap", let x = steps.last?["x"]?.double, let y = steps.last?["y"]?.double else { return nil }
        return CGPoint(x: x / 1000, y: y / 1000)
    }

    /// TouchCheck after a round: true = the board's pointer is not reaching the iPhone (a fail step is recorded, the
    /// check armed again for after the user's fix). One probe, only early in a run (TouchCheck.note).
    /// `big`: the round changed the screen a lot.
    func touchless(big: Bool) async throws -> Bool {
        guard let last = steps.last, touchCheck.note(last, big: big) == .probe else { return false }
        try await gate?()
        let seen = await phone?.pointerSeen(near: pointerAt)
        DebugLog.write("touch check: \(TouchCheck.rounds) pointer rounds changed nothing; the probe "
                       + (seen.map { $0 ? "found the pointer" : "did not find the pointer" } ?? "could not tell"))
        guard touchCheck.probed(seen) else { return false }
        record(nil, ["action": .str("fail"), "reason": .str(TouchCheck.reason)])
        touchCheck.rearm()
        return true
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
        guard last >= 0, steps[last]["action"]?.str == "tap", let x = steps[last]["x"]?.double, let y = steps[last]["y"]?.double
        else { return nil }
        // the step is in frame fractions, the pointer in screen fractions (they differ only on a letterboxed iPad)
        let geometry = screen?.geometry, target = CGPoint(x: x / 1000, y: y / 1000)
        let aim = geometry?.screenPoint(fromFrame: target) ?? target
        guard let found = await phone?.landing(aim.x, aim.y) else { return nil }
        let p = geometry?.framePoint(fromScreen: found) ?? found
        steps[last]["landed"] = .arr([.int(Int((p.x * 1000).rounded())), .int(Int((p.y * 1000).rounded()))])
        return p
    }
}


/// A number that changed on a screen that otherwise stayed put, for the actor: "11 items" -> "12 items" after a tap
/// on +. The coarse `changed` verdict cannot tell such a step from one that did nothing, so the model taps + again.
/// Read from the OCR lines of the trees the actor was sent (no extra model call). Only numbers: OCR misreads words
/// from frame to frame ("Eventbrite" / "Eventorite"), which would read as changes.
enum ScreenDiff {
    static let maxChanges = 3  // more than this on either side: a new screen, not a small change
    static let minShared = 3  // fewer lines in common: not the same screen
    static let statusBar = 0.06  // the top of the frame: clock, signal, battery

    static func texts(_ tree: UITree) -> [String] {
        tree.lines.compactMap { line in
            guard line.box.count == 4, Double(line.box[1] + line.box[3]) / 2 > statusBar * Double(tree.h) else { return nil }
            let t = String(line.text.trimmingCharacters(in: .whitespaces).prefix(40))
            return t.isEmpty ? nil : t
        }
    }

    /// The words of a line without its digits, case or punctuation: "11 items" and "12 Items" share it.
    static func words(_ s: String) -> String { String(s.lowercased().filter { $0.isLetter }) }
    static func digits(_ s: String) -> String { String(s.filter { ("0"..."9").contains($0) }) }

    /// The line appended to the actor's text, or nil when no number changed on the same screen.
    static func line(from old: [String], to new: [String]) -> String? {
        var gone = old, added: [String] = []
        for t in new {
            if let i = gone.firstIndex(of: t) { gone.remove(at: i) } else { added.append(t) }
        }
        guard gone.count <= maxChanges, added.count <= maxChanges, new.count - added.count >= minShared else { return nil }
        var pairs: [String] = []
        for a in added where !digits(a).isEmpty {
            guard let i = gone.firstIndex(where: { words($0) == words(a) && !digits($0).isEmpty && digits($0) != digits(a) })
            else { continue }
            pairs.append("\"\(gone[i])\" -> \"\(a)\"")
            gone.remove(at: i)
        }
        guard !pairs.isEmpty else { return nil }
        return "\n\nNumbers changed since the last screen: " + pairs.joined(separator: ", ")
    }
}
