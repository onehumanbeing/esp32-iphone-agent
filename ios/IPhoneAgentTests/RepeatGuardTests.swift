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
        XCTAssertEqual(phone.calls, ["back", "tap"],  // back on a screen that stays put also taps the top-left arrow
                       "the repeat was never sent")
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
        XCTAssertEqual(model.prompts.count, 3, "asked again, then once more plainly (#166), never more")
        XCTAssertEqual(blocked(agent).count, 2)
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
        XCTAssertEqual(blocked(agent).count, 2 * NoProgress.limit, "twice in each round after the first (#166)")
        XCTAssertEqual(model.prompts.count, 1 + 3 * NoProgress.limit)
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
        let nextRow = steps + [["action": .str("swipe"), "x1": .num(800), "y1": .num(400), "x2": .num(200), "y2": .num(400)]]
        XCTAssertNil(CommitGuard.repeated([tap(500, 938)], after: nextRow), "a bulk delete: another gesture came between")
    }

    func testAConfirmationStaysInThePromptAfterItScrollsOut() {
        let agent = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: nil, planner: nil, trace: nil)
        agent.steps = [["action": .str("confirmed"), "reason": .str("the user said yes, do it now: delete 20 orders")]]
            + (0..<9).map { tap(500, Double(100 + $0 * 50), changed: true) }
        XCTAssertTrue(agent.actorUserPrompt().contains("The user confirmed earlier (still holds):\n- the user said yes, do it now: delete 20 orders"))
        agent.steps = Array(agent.steps.prefix(3))
        XCTAssertFalse(agent.actorUserPrompt().contains("confirmed earlier"), "still in the recent actions")
    }

    func testTheSameAnswerAfterTheHoldIsAskedOnceMoreThenSent() async throws {
        let (agent, phone, model, _, _) = try await round(after: [tap(500, 500, changed: false)],
            ["THINK: a\nDO: tap 500 500", "THINK: b\nDO: tap 505 500", "THINK: c\nDO: back"])
        XCTAssertEqual(model.prompts.count, 3)
        XCTAssertEqual(blocked(agent).map { $0["reason"]?.str }, [RepeatGuard.reason("tap"), RepeatGuard.insist("tap")])
        XCTAssertEqual(phone.calls, ["back", "tap"],  // back on a screen that stays put also taps the top-left arrow
                       "neither repeat was sent")
    }

    func testScrollGuardHoldsTheFourthScrollInARowOnce() {
        let swipe: JObject = ["action": .str("swipe"), "x1": .int(500), "y1": .int(700), "x2": .int(500), "y2": .int(400)]
        let tap: JObject = ["action": .str("tap"), "x": .int(1), "y": .int(1)]
        XCTAssertNil(ScrollGuard.repeated([swipe], after: [tap, swipe, swipe]), "two in a row")
        XCTAssertNotNil(ScrollGuard.repeated([swipe], after: [tap, swipe, swipe, swipe]))
        let held: JObject = ["action": .str(RepeatGuard.action), "reason": .str(ScrollGuard.reason)]
        XCTAssertNil(ScrollGuard.repeated([swipe], after: [swipe, swipe, swipe, held]), "asked once already")
        let read: JObject = ["action": .str("read"), "what": .str("x")]
        XCTAssertNil(ScrollGuard.repeated([swipe], after: [swipe, swipe, read, swipe]), "a read in between")
        XCTAssertNil(ScrollGuard.repeated([tap], after: [swipe, swipe, swipe]), "not a scroll")
    }

    func testFeedHeaderOnlyWhenTheSwipeBroughtItUp() {
        XCTAssertEqual(Feed.reached(["订单信息", "猜你喜欢"], before: ["配送地址"]), "猜你喜欢")
        XCTAssertNil(Feed.reached(["猜你喜欢"], before: ["猜你喜欢"]), "already on screen before")
        XCTAssertNil(Feed.header(["我们为你推荐了几家附近评分很高的店铺，欢迎下单"]), "a sentence, not a header")
        XCTAssertEqual(Feed.header(["You may also like"]), "You may also like")
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
        XCTAssertNil(LoopGuard.repeated([g("tap", 900, 900)], after: [a, b, a], sameScreen: { _, _ in false }),
                     "the same two moves on new content (a bulk delete)")
    }

    func testTwoTapsInTurnOnAChangingScreenAreHeldThenHandedToTheUser() {
        let a = g("tap", 300, 120, changed: true), b = g("tap", 700, 120, changed: true)
        let seven = [a, b, a, b, a, b, a]
        XCTAssertNotNil(PingPongGuard.repeated([b], after: seven), "the fourth round of the same two taps")
        XCTAssertNil(PingPongGuard.repeated([b], after: Array(seven.dropFirst())), "three rounds are not enough")
        XCTAssertNil(PingPongGuard.repeated([g("tap", 500, 800)], after: seven), "a different tap breaks it")
        XCTAssertNil(PingPongGuard.repeated([g("swipe", 500, 500)], after: [a, b, a, b, a, b, a]))
        XCTAssertNil(PingPongGuard.repeated([a], after: [a, a, a, a, a, a, a]), "one tap repeated is another guard's")
        let hold: JObject = ["action": .str(RepeatGuard.action), "reason": .str(PingPongGuard.reason)]
        XCTAssertFalse(PingPongGuard.again(seven, [b]), "first time: asked once, not stuck")
        XCTAssertNil(PingPongGuard.repeated([a], after: seven + [hold, b]), "the model went on: its answer stands")
        XCTAssertFalse(PingPongGuard.again(seven + [hold, b], [g("tap", 500, 800)]), "it changed course")
        let more = seven + [hold, b, a, b, a, b, a, b]
        XCTAssertNotNil(PingPongGuard.repeated([a], after: more), "four more rounds after the hold")
        XCTAssertTrue(PingPongGuard.again(more, [a]), "still the same pair: the user is asked")
        let later = seven + [hold, b, g("swipe", 500, 500), a, b, a, b, a, b, a]
        XCTAssertNotNil(PingPongGuard.repeated([b], after: later))
        XCTAssertFalse(PingPongGuard.again(later, [b]), "a new stretch of the pair after other moves is held once again")
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
        let autoOpen: JObject = ["action": .str("open"), "app": .str("微信"), "auto": .bool(true), "changed": .bool(true)]
        XCTAssertTrue(DoneGuard.premature(done, after: [autoOpen], earlierRuns: true), "the app's own open is not the run's doing")
        let asked: JObject = ["action": .str(RepeatGuard.action), "reason": .str(DoneGuard.reason)]
        XCTAssertFalse(DoneGuard.premature(done, after: [asked], earlierRuns: true), "the second done stands")
    }

    func testASendAfterAChineseTypeThatStoppedIsHeld() {
        var typed: JObject = ["action": .str("type"), "text": .str("你好"), "typed": .str("left: hao")]
        let enter: JObject = ["action": .str("key"), "combo": .str("enter")]
        XCTAssertNotNil(TypedGuard.repeated([enter], after: [typed]))
        typed["text"] = .str("hello")
        XCTAssertNil(TypedGuard.repeated([enter], after: [typed]), "English stops are not pinyin")
        XCTAssertNil(TypedGuard.repeated([enter], after: [["action": .str("type"), "text": .str("你好")]]))
    }

    /// Amap 2026-11-20: pinyin typed 上海 and stopped, the suggestion list already showed the place; the tap on that
    /// row (what listedHint asks for) goes through, it is not a send.
    func testATapOnASuggestionAfterAPartWayTypeIsNotHeld() {
        let typed: JObject = ["action": .str("type"), "text": .str("上海西岸艺术中心"),
                              "typed": .str("\"西\" is not among the candidates for xi; typed \"上海\", not typed: \"西岸艺术中心\"")]
        XCTAssertNil(TypedGuard.repeated([g("tap", 500, 260)], after: [g("tap", 500, 90), typed]))
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

    func testEnterIsHeldOnceAfterTypingThatStoppedPartWay() {
        var g = SendGuard()
        g.typed("我们晚上七点见", missing: SendGuard.missing("\"七点\" is not among the candidates for qidian (cleared); typed \"我们晚上\", not typed: \"七点见\""))
        XCTAssertEqual(g.missing, "七点见")
        XCTAssertNotNil(g.enter(step: 3))
        XCTAssertNil(g.enter(step: 4), "enter again: sent as it is")
        g.typed("好的", missing: SendGuard.missing("\"好的\" did not show up in the field after committing it (cleared); typed \"好的\""))
        XCTAssertNotNil(g.enter(step: 5), "a note without the rest: unsure, held once")
        g.cleared()
        XCTAssertNil(g.enter(step: 6), "cleared: nothing held")
    }

    /// 2026-11-22: a DM went out garbled through the Send button; a send button is held like Enter.
    func testASendButtonAfterAPartWayTypeIsHeldOnce() {
        XCTAssertTrue(SendGuard.isSend("发送"))
        XCTAssertTrue(SendGuard.isSend(" Send "))
        XCTAssertFalse(SendGuard.isSend("发送位置"), "a longer label is not the send button")
        XCTAssertFalse(SendGuard.isSend(nil))
        var g = SendGuard()
        g.typed("我们晚上七点见", missing: "七点见")
        let held = g.enter(step: 3, again: "tap it again") ?? ""
        XCTAssertTrue(held.contains("tap it again to send it as it is"), held)
        XCTAssertNil(g.enter(step: 4, again: "tap it again"), "the same tap again: sent as it is")
        g.typed("好的", missing: nil)
        XCTAssertNil(g.enter(step: 5, again: "tap it again"), "typed in full: sent at once")
    }

    func testTheSameTextEnteredAgainIsHeldOnce() {
        var g = SendGuard()
        g.typed("hello", missing: nil)
        XCTAssertNil(g.enter(step: 2))
        XCTAssertNil(g.enter(step: 3), "enter with nothing typed since: not a repeat")
        g.typed("hello", missing: nil)
        XCTAssertEqual(g.enter(step: 6)?.contains("step 2"), true)
        XCTAssertNil(g.enter(step: 7), "enter again: entered a second time")
        g.typed("hello", missing: nil)
        XCTAssertNotNil(g.enter(step: 9), "a third time is held again")
        g.typed("bye", missing: nil)
        XCTAssertNil(g.enter(step: 10))
        XCTAssertTrue(Actions.isEnter(["action": .str("key"), "combo": .str("Return")]))
        XCTAssertFalse(Actions.isEnter(["action": .str("key"), "combo": .str("cmd+enter")]))
    }

    private func screen(_ texts: String...) -> [DemoAnalysis.Line] { texts.map { .init(text: $0, x: 400, y: 600) } }

    /// 2026-11-23 (Wiki #1007): a real send with part of the text missing is held once, then asked, never sent.
    func testARealSendWithPartOfTheTextIsAskedNeverSent() {
        var g = SendGuard()
        g.typed("我们晚上七点见", missing: "七点见", at: 2)
        guard case .hold(let why) = g.send(step: 3, lines: nil, again: "tap it again") else { return XCTFail() }
        XCTAssertTrue(why.contains("七点见"), why)
        guard case .ask(let reason) = g.send(step: 4, lines: screen("我们晚上"), again: "tap it again") else { return XCTFail("sent half") }
        XCTAssertTrue(reason.hasPrefix("send:"), reason)
        g.went(step: 5)  // the user said yes
        g.typed("好的", missing: nil, at: 6)
        XCTAssertEqual(g.send(step: 7, lines: screen("好的"), again: "tap it again"), .go, "typed in full: sent at once")
    }

    /// The guard must not stop a normal run: each of these goes out at once or after the old single hold.
    func testANormalSendIsNeverAsked() {
        var g = SendGuard()
        g.typed("我们晚上七点见", missing: "", at: 2)  // the typer was unsure, the field shows it all
        XCTAssertEqual(g.send(step: 3, lines: screen("我们晚上七点见"), again: "tap it again"), .go, "the screen overrules the typer")
        g.typed("好的👍，明天见!", missing: nil, at: 4)  // OCR drops emoji and punctuation, misreads 见 as 贝
        XCTAssertEqual(g.send(step: 5, lines: screen("好的 明天贝"), again: "tap it again"), .go)
        g.typed("hello there", missing: nil, at: 6)  // Latin text is not read back
        XCTAssertEqual(g.send(step: 7, lines: screen("helo"), again: "key enter again"), .go)
        g.typed("西岸", missing: "岸", at: 8)  // a search typed part way, a result tapped, never entered
        XCTAssertEqual(g.send(step: 20, lines: screen("回复"), again: "tap it again").isHold, true, "old: the soft hold only")
        XCTAssertEqual(g.send(step: 21, lines: screen("回复"), again: "tap it again"), .go)
        for (i, step) in [30, 34, 38].enumerated() {  // one reply to three chats
            g.typed("收到", missing: nil, at: step)
            let first = g.send(step: step + 1, lines: screen("收到"), again: "tap it again")
            if i == 0 { XCTAssertEqual(first, .go) } else {
                XCTAssertTrue(first.isHold, "the same text: held once")
                XCTAssertEqual(g.send(step: step + 2, lines: screen("收到"), again: "tap it again"), .go, "then sent, never asked")
            }
        }
    }

    func testChineseNotOnScreenIsHeldThenAsked() {
        var g = SendGuard()
        g.typed("明天见", missing: nil, at: 2)
        XCTAssertTrue(g.send(step: 3, lines: screen("mingtianjian"), again: "key enter again").isHold)
        guard case .ask = g.send(step: 4, lines: screen("mingtianjian"), again: "key enter again") else { return XCTFail() }
        g.cleared()
        g.typed("明天见", missing: nil, at: 5)
        XCTAssertEqual(g.send(step: 6, lines: nil, again: "key enter again"), .go, "typed in this round: not known, not held")
    }

    func testEnterSendsOnlyWithASendKeyLowOnTheScreen() {
        XCTAssertTrue(SendGuard.sendShown([.init(text: "发送", x: 900, y: 960)]))
        XCTAssertFalse(SendGuard.sendShown([.init(text: "搜索", x: 900, y: 960)]), "a search field: Enter is not a send")
        XCTAssertFalse(SendGuard.sendShown([.init(text: "回复", x: 900, y: 700)]), "a comment list's reply links")
        XCTAssertFalse(SendGuard.sendShown([.init(text: "Send", x: 500, y: 120)]), "a title up top is not the key")
        XCTAssertEqual(SendGuard.seen("今天我们晚上七点", in: [.init(text: "我们晚上七点", x: 400, y: 600)]), 0.75)
    }

    func testPersonalHotspotIsTheBridgeOnItsSubnet() {
        XCTAssertTrue(Hotspot.sharing([("en0", "192.168.4.2"), ("bridge100", "172.20.10.1")]))
        XCTAssertFalse(Hotspot.sharing([("en0", "172.20.10.3")]), "joined to another iPhone's hotspot: not sharing")
        XCTAssertFalse(Hotspot.sharing([("bridge0", "192.168.2.1"), ("pdp_ip0", "10.1.2.3")]))
    }

    func testSchemesByAnyName() {
        XCTAssertEqual(AppNames.schemeURLs("微信").map(\.absoluteString), ["weixin://", "wechat://"], "hand list first")
        XCTAssertEqual(AppNames.schemeURLs("Weixin").map(\.absoluteString), ["weixin://", "wechat://"])
        XCTAssertEqual(AppNames.schemeURLs("RED").map(\.absoluteString), ["xhsdiscover://"])
        XCTAssertTrue(AppNames.schemeURLs("设置").isEmpty, "no public scheme: the old way")
        XCTAssertTrue(AppNames.schemeURLs("SkyTrip").isEmpty, "unknown app: the old way")
        XCTAssertTrue(AppNames.schemes.keys.allSatisfy { en in AppNames.table.contains { $0[1] == en } }, "every scheme has a table row")
    }

    func testTheOneAppATaskNames() {
        XCTAssertEqual(AppNames.only(in: "给妈妈发短信说晚点回家"), "短信")
        XCTAssertEqual(AppNames.only(in: "Open WeChat and send hi to File Transfer"), "WeChat")
        XCTAssertNil(AppNames.only(in: "Turn on dark mode on my iPhone"), "iPhone is not Phone")
        XCTAssertNil(AppNames.only(in: "把淘宝的链接发到微信"), "two apps")
        XCTAssertEqual(AppNames.only(in: "打开美团外卖，收集订单"), "美团外卖", "not 美团")
        XCTAssertEqual(AppNames.only(in: "打开美团外卖，收集 2026年11月9日到今天的所有外卖订单，按收货地区归类，整理成带截图的结果文件。"),
                       "美团外卖", "文件 later in the task is not the Files app")
        XCTAssertEqual(AppNames.schemeURLs("美团外卖").map(\.absoluteString), ["meituanwaimai://"], "its own, never 美团's")
        XCTAssertEqual(AppNames.only(in: "在美团上找一家火锅"), "美团")
        XCTAssertEqual(AppNames.only(in: "打开携程看订单"), "携程")
        XCTAssertNil(AppNames.only(in: "设置一个明天早上的提醒"), "loose words only")
        XCTAssertNil(AppNames.only(in: "Check SkyTrip for my next departure. Set an alarm in Clock 30 minutes before"),
                     "the app the table knows is a later step's")
        XCTAssertEqual(AppNames.only(in: "先在美团看下订单，然后在微信告诉妈妈"), "美团", "the first step's app")
        XCTAssertEqual(AppNames.only(in: "查一下 Uber 的行程，然后打开时钟设个闹钟"), "Uber", "Clock comes after then")
        XCTAssertEqual(AppNames.only(in: "In Clock, add an alarm for 7:00"), "Clock")
    }

    /// The collected scheme list (AppSchemes.swift): apps the hand table did not know, and its extra schemes.
    func testCollectedSchemes() {
        XCTAssertEqual(AppNames.schemeURLs("抖音").map(\.absoluteString), ["snssdk1128://"])
        XCTAssertEqual(AppNames.schemeURLs("Douyin").map(\.absoluteString), ["snssdk1128://"])
        XCTAssertEqual(AppNames.schemeURLs("QQ").map(\.absoluteString), ["mqq://"], "mqqapi left out: other apps answer it")
        XCTAssertEqual(AppNames.schemeURLs("飞书").map(\.absoluteString), ["feishu://"], "lark left out")
        XCTAssertFalse(AppNames.schemeURLs("Messages").map(\.absoluteString).contains("sms://"))
        XCTAssertEqual(AppNames.only(in: "打开抖音刷十分钟视频"), "抖音")
        XCTAssertEqual(AppNames.only(in: "用滴滴打车去机场"), "滴滴")
        XCTAssertNil(AppNames.only(in: "Zoom in on the map and find a cafe"), "a plain word, not the Zoom app")
        XCTAssertNil(AppNames.only(in: "帮我点个外卖"), "外卖 alone names no app")
        let names = AppNames.table.flatMap { $0 }.map(AppNames.norm)
        XCTAssertEqual(AppNames.table.count, Set(AppNames.table.map { AppNames.norm($0[1]) }).count, "one row per app")
        XCTAssertGreaterThan(names.count, 300)
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

/// Fallbacks of 2026-11-17: paste with read-back, pixel coordinates, the Home Screen icon, the second repeat.
@MainActor final class FallbackTests: XCTestCase {

    func testOffScreenNoteGivesThePointAPixelYWouldBe() {
        let a: JObject = ["action": .str("tap"), "x": .int(270), "y": .int(1100)]
        let note = OffScreen.reason(a, image: CGSize(width: 540, height: 1170)) ?? ""
        XCTAssertTrue(note.hasPrefix("not tapped:"), note)
        XCTAssertTrue(note.contains("x 500, y 940"), note)
        // past the image too: only the plain note
        let far: JObject = ["action": .str("tap"), "x": .int(270), "y": .int(1300)]
        XCTAssertFalse(OffScreen.reason(far, image: CGSize(width: 540, height: 1170))!.contains("pixel"))
        XCTAssertNil(OffScreen.reason(["action": .str("tap"), "x": .int(270), "y": .int(900)], image: CGSize(width: 540, height: 1170)))
    }

    func testPastedTextIsSeenByItsStartAndEnd() {
        XCTAssertTrue(AgentLoop.shows("こんにちは", ["メッセージ", "こんにちは"]))
        XCTAssertTrue(AgentLoop.shows("안녕하세요", ["안녕하세요 |"]))
        XCTAssertFalse(AgentLoop.shows("안녕하세요", ["메시지"]))
        let long = "東京駅の近くでおすすめのラーメン屋さんを教えてください"
        XCTAssertTrue(AgentLoop.shows(long, ["東京駅の近くでおすすめの", "ラーメン屋さんを教えてください"]))
        XCTAssertFalse(AgentLoop.shows("", ["anything"]))
    }

    func testCurrentAppIsTheLastOpenedUntilHome() {
        let agent = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: nil, planner: nil, trace: nil)
        XCTAssertNil(agent.currentApp)
        agent.openedAtStart = "LINE"
        XCTAssertEqual(agent.currentApp, "LINE")
        agent.record(nil, ["action": .str("open"), "app": .str("Notes"), "opened": .str("not_found")])
        XCTAssertEqual(agent.currentApp, "LINE")
        agent.record(nil, ["action": .str("open"), "app": .str("KakaoTalk"), "opened": .str(OpenResult.opened.rawValue)])
        agent.record(nil, ["action": .str("tap"), "x": .int(500), "y": .int(500)])
        XCTAssertEqual(agent.currentApp, "KakaoTalk")
        agent.record(nil, ["action": .str("home")])
        XCTAssertNil(agent.currentApp)
    }

    func testHomeScreenOnlyWhenNoSchemeOpenedTheApp() {
        let agent = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: nil, planner: nil, trace: nil)
        agent.startsOnHome = true
        XCTAssertTrue(agent.homeAtStart)
        agent.openedAtStart = "WeChat"
        XCTAssertFalse(agent.homeAtStart)
    }

    func testHomeIconSpotIsAboveTheOnlyLabel() {
        let size = CGSize(width: 1000, height: 2000)
        let lines: [(text: String, box: [Int])] = [("微信", [400, 800, 600, 840]), ("备忘录", [100, 800, 300, 840])]
        let p = AgentLoop.homeIconSpot(lines, labels: ["微信", "WeChat"], size: size)
        XCTAssertEqual(p?.x ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(p?.y ?? 0, (800 - 1.5 * 40) / 2000, accuracy: 0.001)
        // the name twice (a widget, a folder): Spotlight decides
        let twice = lines + [("微信", [400, 1200, 600, 1240])]
        XCTAssertNil(AgentLoop.homeIconSpot(twice, labels: ["微信"], size: size))
        XCTAssertNil(AgentLoop.homeIconSpot(lines, labels: ["淘宝"], size: size))
    }

    func testTheSecondAskIsLeftOutOfTheStuckCount() {
        XCTAssertTrue(StuckGuard.repeatHold(RepeatGuard.insist("tap")))
        XCTAssertNil(RepeatGuard.first([["action": .str("done")]]))
        XCTAssertEqual(RepeatGuard.first([["action": .str("plan")], ["action": .str("tap")]])?["action"]?.str, "tap")
    }
}

final class AlreadyOpenTests: XCTestCase {
    private func opened(_ app: String, _ result: OpenResult = .opened) -> JObject {
        ["action": .str("open"), "app": .str(app), "opened": .str(result.rawValue)]
    }

    func testInsideTheAppItOpenedNothingIsSent() {
        let steps = [opened("美团外卖"), ["action": .str("tap"), "x": .int(1), "y": .int(2)], ["action": .str("back")]]
        XCTAssertTrue(AlreadyOpen.holds("美团外卖", steps))
        XCTAssertTrue(AlreadyOpen.holds("Meituan Waimai", steps), "another name of the same app")
    }

    func testAfterHomeOrAnotherAppItOpens() {
        XCTAssertFalse(AlreadyOpen.holds("美团外卖", [opened("美团外卖"), ["action": .str("home")]]))
        XCTAssertFalse(AlreadyOpen.holds("美团外卖", [opened("美团外卖"), opened("微信")]))
        XCTAssertFalse(AlreadyOpen.holds("美团外卖", [opened("美团外卖", .notOpened)]))
        XCTAssertFalse(AlreadyOpen.holds("美团外卖", []))
    }

    func testAskedTwiceInARowItReallyOpens() {
        XCTAssertFalse(AlreadyOpen.holds("美团外卖", [opened("美团外卖"), opened("美团外卖", .already)]))
    }
}
