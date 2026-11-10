import XCTest
@testable import IPhoneAgent

/// The same gesture right after it left the screen unchanged: held back once, the model asked again in the round.
@MainActor final class RepeatGuardTests: XCTestCase {
    private func tap(_ x: Double, _ y: Double, changed: Bool? = nil) -> JObject {
        var s: JObject = ["action": .str("tap"), "x": .num(x), "y": .num(y)]
        if let changed { s["changed"] = .bool(changed) }
        return s
    }

    /// One round after `before`, the model answering `replies` in turn.
    private func round(after before: [JObject], _ replies: [String], afterPause: Bool = false)
        async throws -> (AgentLoop, FakeGestures, FakeModel, [ModelCall], [Bool]) {
        let screen = FakeScreen(), phone = FakeGestures()
        screen.frame = AgentTests.jpeg()  // never changes
        var held: [Bool] = []
        JevGate.hold = false
        let model = FakeModel { held.append(JevGate.hold); return replies[min($0, replies.count) - 1] }
        let agent = AgentLoop(phone: phone, screen: screen, actor: model, planner: nil, trace: nil)
        var calls: [ModelCall] = []
        agent.onModelCall = { calls.append($0) }
        agent.steps = before
        agent.roundDroppedByPause = afterPause
        _ = try await agent.step()
        return (agent, phone, model, calls, held)
    }

    private func blocked(_ agent: AgentLoop) -> [JObject] {
        agent.steps.filter { $0["action"]?.str == RepeatGuard.action }
    }

    func testTheSameTapAfterAnUnchangedScreenIsNotSentAndTheModelIsAskedAgain() async throws {
        let (agent, phone, model, calls, held) = try await round(
            after: [tap(500, 500, changed: false)], ["THINK: again\nDO: tap 510 490", "THINK: other\nDO: back"])
        XCTAssertEqual(phone.calls, ["back"], "the repeat was never sent")
        XCTAssertEqual(blocked(agent).count, 1)
        XCTAssertEqual(blocked(agent).first?["reason"]?.str, RepeatGuard.reason("tap"))
        XCTAssertEqual(model.prompts.count, 2)
        XCTAssertTrue(model.prompts[1].contains("Not done: the same tap just left the screen unchanged"))
        XCTAssertEqual(calls.count, 2, "the second look is a model call like any other")
        XCTAssertTrue(calls.allSatisfy { $0.reply != nil })
        XCTAssertEqual(held, [false, true], "the second look goes to the user's model, not Jev")
    }

    func testNotHeldBackAfterAChangedScreenOrForAnotherTarget() async throws {
        for (before, reply) in [(tap(500, 500, changed: true), "DO: tap 500 500"),
                                (tap(500, 500, changed: false), "DO: tap 560 500")] {
            let (agent, phone, model, _, _) = try await round(after: [before], ["THINK: t\n" + reply])
            XCTAssertEqual(phone.calls.first, "tap")
            XCTAssertEqual(model.prompts.count, 1)
            XCTAssertTrue(blocked(agent).isEmpty)
        }
    }

    func testTheSameAnswerAgainIsSent() async throws {
        let (agent, phone, model, _, _) = try await round(
            after: [tap(500, 500, changed: false)], ["THINK: a\nDO: tap 500 500", "THINK: b\nDO: tap 500 500"])
        XCTAssertEqual(model.prompts.count, 2, "asked again once per round only")
        XCTAssertEqual(blocked(agent).count, 1)
        XCTAssertEqual(phone.calls.first, "tap")
        XCTAssertEqual(agent.steps.last?["action"]?.str, "tap")
        XCTAssertEqual(agent.steps.last?["changed"], .bool(false), "the stall count sees it as before")
    }

    func testNotHeldBackRightAfterAPausedRound() async throws {
        let (agent, phone, model, _, _) = try await round(
            after: [tap(500, 500, changed: false)], ["DO: tap 500 500"], afterPause: true)
        XCTAssertEqual(model.prompts.count, 1, "the person may have changed the screen while paused")
        XCTAssertEqual(phone.calls.first, "tap")
        XCTAssertTrue(blocked(agent).isEmpty)
        XCTAssertFalse(agent.roundDroppedByPause)
    }

    func testOnlyGesturesAreHeldBack() {
        let still: (String) -> JObject = { ["action": .str($0), "changed": .bool(false)] }
        for name in ["wait", "done", "fail", "note", "home"] {
            XCTAssertNil(RepeatGuard.repeated([["action": .str(name)]], after: [still(name)]), name)
        }
        XCTAssertNotNil(RepeatGuard.repeated([["action": .str("back")]], after: [still("back")]))
        let type: (String) -> JObject = { ["action": .str("type"), "text": .str($0)] }
        XCTAssertNil(RepeatGuard.repeated([type("b")], after: [type("a").merging(["changed": .bool(false)])]))
        // several actions: the new round's first gesture against the previous round's last step
        let note: JObject = ["action": .str("note"), "text": .str("x")]
        XCTAssertNotNil(RepeatGuard.repeated([note, tap(500, 500), tap(100, 100)],
                                             after: [tap(100, 100), tap(500, 500, changed: false)]))
        XCTAssertNil(RepeatGuard.repeated([tap(100, 100)], after: [tap(100, 100), tap(500, 500, changed: false)]))
        // something in between (help, a takeover, a reconnect): the screen may be new
        XCTAssertNil(RepeatGuard.repeated([tap(500, 500)], after: [tap(500, 500, changed: false), ["action": .str("takeover")]]))
        XCTAssertNotNil(RepeatGuard.repeated([tap(500, 500)], after: [tap(500, 500, changed: false), ["action": .str("plan"), "plan": .str("1. x")]]))
    }

    func testAHeldBackActionIsNoMoveForNoProgress() async {
        let screen = FakeScreen(), phone = FakeGestures()
        screen.frame = AgentTests.jpeg()
        phone.pointerVisible = true
        let model = FakeModel { _ in "THINK: try\nDO: tap 500 500" }
        let agent = AgentLoop(phone: phone, screen: screen, actor: model, planner: nil, trace: nil)
        var asked: [String] = []
        agent.onHelp = { asked.append($0); return .stop }
        await agent.run()
        XCTAssertEqual(asked, [NoProgress.reason], "NoProgress still asks after the same repeats")
        XCTAssertEqual(agent.steps.filter { $0["action"]?.str == "tap" }.count, NoProgress.limit + 1)
        XCTAssertEqual(blocked(agent).count, NoProgress.limit, "once in each round after the first")
        XCTAssertEqual(model.prompts.count, 1 + 2 * NoProgress.limit)
        XCTAssertTrue(StepText.notMoves.contains(RepeatGuard.action))
    }
}
