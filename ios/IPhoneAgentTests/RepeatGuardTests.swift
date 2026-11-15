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

    func testATapOnTheConfirmedStepsSpotIsHeldBackOnce() {
        let confirmed: JObject = ["action": .str("confirmed"), "reason": .str("add to cart")]
        let steps = [tap(500, 900, changed: true), confirmed, tap(500, 938, changed: true)]
        XCTAssertNotNil(CommitGuard.repeated([tap(505, 930)], after: steps), "the same button again")
        XCTAssertNil(CommitGuard.repeated([tap(500, 600)], after: steps), "another target")
        XCTAssertNil(CommitGuard.repeated([tap(500, 938)], after: [tap(500, 938, changed: true)]), "nothing confirmed")
        XCTAssertNil(CommitGuard.repeated([tap(500, 938)], after: [confirmed]), "the commit itself")
        let asked = steps + [["action": .str(RepeatGuard.action), "reason": .str(CommitGuard.reason)]]
        XCTAssertNil(CommitGuard.repeated([tap(500, 938)], after: asked), "its second answer stands")
    }
}

/// The run guards: back and forth, swipes on the Home Screen, an early done, a send after a typing
/// stop, too many holds, long swipes, and the one app a task names.
final class DefectGuardTests: XCTestCase {
    private func g(_ name: String, _ x: Double = 0, _ y: Double = 0, changed: Bool? = nil) -> JObject {
        var s: JObject = ["action": .str(name), "x": .num(x), "y": .num(y)]
        if let changed { s["changed"] = .bool(changed) }
        return s
    }
    private func swipe(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> JObject {
        ["action": .str("swipe"), "x1": .num(x1), "y1": .num(y1), "x2": .num(x2), "y2": .num(y2)]
    }

    func testBackAndForthIsHeldButNotThreeDifferentMoves() {
        let a = g("tap", 100, 900, changed: true), b = g("tap", 900, 900, changed: true)
        XCTAssertNotNil(LoopGuard.repeated([g("tap", 900, 900)], after: [a, b, a]))
        XCTAssertNil(LoopGuard.repeated([g("tap", 500, 500)], after: [a, b, a]))
        XCTAssertNil(LoopGuard.repeated([g("tap", 900, 900)], after: [b, a]), "needs three before it")
    }

    func testASwipeOnTheHomeScreenIsHeldButNotFromAnEdgeOrInAnApp() {
        XCTAssertNotNil(HomeSwipeGuard.repeated([swipe(800, 500, 200, 500)], after: [], startsOnHome: true))
        XCTAssertNil(HomeSwipeGuard.repeated([swipe(800, 500, 200, 500)], after: []), "a run not started from Home")
        XCTAssertNotNil(HomeSwipeGuard.repeated([swipe(800, 500, 200, 500)], after: [g("tap", 1, 1), g("home"), swipe(800, 500, 200, 500)]))
        XCTAssertNil(HomeSwipeGuard.repeated([swipe(950, 10, 950, 300)], after: [], startsOnHome: true), "Control Center")
        XCTAssertNil(HomeSwipeGuard.repeated([swipe(500, 700, 500, 400)], after: [g("open")]))
        XCTAssertNil(HomeSwipeGuard.repeated([swipe(500, 700, 500, 400)], after: [["action": .str("resumed")]]))
    }

    func testDoneBeforeAnyChangeIsHeldOnce() {
        let done: [JObject] = [["action": .str("done"), "answer": .str("ok")]]
        XCTAssertTrue(DoneGuard.premature(done, after: [], earlierRuns: true))
        XCTAssertFalse(DoneGuard.premature(done, after: [], earlierRuns: false), "no earlier run to mistake for this one")
        XCTAssertTrue(DoneGuard.premature(done, after: [g("tap", 5, 5, changed: false)], earlierRuns: true))
        XCTAssertFalse(DoneGuard.premature(done, after: [g("tap", 5, 5, changed: true)], earlierRuns: true))
        XCTAssertFalse(DoneGuard.premature(done, after: [["action": .str("resumed")]], earlierRuns: true))
        let asked: JObject = ["action": .str(RepeatGuard.action), "reason": .str(DoneGuard.reason)]
        XCTAssertFalse(DoneGuard.premature(done, after: [asked], earlierRuns: true), "the second done stands")
    }

    func testASendAfterAChineseTypeThatStoppedIsHeld() {
        var typed: JObject = ["action": .str("type"), "text": .str("你好"), "typed": .str("left: hao")]
        XCTAssertNotNil(TypedGuard.repeated([["action": .str("key"), "combo": .str("enter")]], after: [typed]))
        XCTAssertNotNil(TypedGuard.repeated([g("tap", 900, 500)], after: [typed]))
        typed["text"] = .str("hello")
        XCTAssertNil(TypedGuard.repeated([g("tap", 900, 500)], after: [typed]), "English stops are not pinyin")
        XCTAssertNil(TypedGuard.repeated([g("tap", 900, 500)], after: [["action": .str("type"), "text": .str("你好")]]))
    }

    func testTheThirdHoldInAShortWhileIsStuck() {
        let hold: JObject = ["action": .str(RepeatGuard.action)]
        XCTAssertFalse(StuckGuard.stuck([hold]))
        XCTAssertTrue(StuckGuard.stuck([hold, g("tap"), hold]))
        XCTAssertFalse(StuckGuard.stuck([hold, hold] + Array(repeating: g("tap"), count: 12)))
        let repeatHold: JObject = ["action": .str(RepeatGuard.action), "reason": .str(RepeatGuard.reason("tap"))]
        XCTAssertFalse(StuckGuard.stuck([repeatHold, repeatHold, repeatHold]), "the repeat guard's own holds stall as before")
    }

    func testLongSwipesAreCutButEdgeSwipesAreNot() {
        var a = swipe(500, 800, 500, 100)
        SwipeClamp.apply(&a)
        XCTAssertEqual(a["y2"]?.double, 500)
        XCTAssertNotNil(a["result"])
        var edge = swipe(500, 990, 500, 100)
        SwipeClamp.apply(&edge)
        XCTAssertEqual(edge["y2"]?.double, 100)
        var short = swipe(500, 600, 500, 400)
        SwipeClamp.apply(&short)
        XCTAssertNil(short["result"])
    }

    func testTheOneAppATaskNames() {
        XCTAssertEqual(AppNames.only(in: "给妈妈发短信说晚点回家"), "短信")
        XCTAssertEqual(AppNames.only(in: "Open WeChat and send hi to File Transfer"), "WeChat")
        XCTAssertNil(AppNames.only(in: "Turn on dark mode on my iPhone"), "iPhone is not Phone")
        XCTAssertNil(AppNames.only(in: "把淘宝的链接发到微信"), "two apps")
        XCTAssertNil(AppNames.only(in: "设置一个明天早上的提醒"), "loose words only")
    }

    /// A third same tap with the screen much the same each time is held, even when each read as changed; a tap that
    /// moves the screen a lot (Continue) is not.
    func testAThirdTapOnAStillScreenIsHeldButNotOneThatMovesIt() {
        func tap(_ x: Double, _ y: Double, changed: Bool? = nil) -> JObject {
            var s: JObject = ["action": .str("tap"), "x": .num(x), "y": .num(y)]
            if let changed { s["changed"] = .bool(changed) }
            return s
        }
        let t = tap(500, 500, changed: true)
        var still = NoProgress()
        _ = still.note([t], big: false)
        XCTAssertNil(ThirdTapGuard.repeated([tap(505, 495)], progress: still), "the second tap goes")
        _ = still.note([t], big: false)
        XCTAssertNotNil(ThirdTapGuard.repeated([tap(505, 495)], progress: still), "the third is held")
        XCTAssertNil(ThirdTapGuard.repeated([tap(700, 200)], progress: still), "another spot goes")
        XCTAssertTrue(StuckGuard.repeatHold(ThirdTapGuard.reason))
        var moving = NoProgress()
        _ = moving.note([t], big: true)
        _ = moving.note([t], big: true)
        XCTAssertNil(ThirdTapGuard.repeated([tap(500, 500)], progress: moving))
    }
}
