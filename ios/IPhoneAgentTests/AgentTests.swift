import ImageIO
import XCTest
@testable import IPhoneAgent

/// Port of server/tests/test_agent.py.
@MainActor final class AgentTests: XCTestCase {
    func testReconnectDuringHTTPDiscardsOldCoordinatesAndRestoresBeforeLookingAgain() async throws {
        let phone = FakeGestures(), screen = FakeScreen()
        let device = try XCTUnwrap(phone.device as? FakeDevice)
        let oldFrame = screen.frame, freshFrame = Data([2])
        let model = FakeModel { call in
            if call == 1 {
                device.links += 1  // reconnect while the actor's HTTP request is outstanding
                return "THINK: old screen\nDO: tap 900 900"
            }
            return "THINK: fresh screen\nDO: tap 100 200"
        }
        let agent = AgentLoop(phone: phone, screen: screen, actor: model, planner: nil, trace: nil)
        var restored = 0, calls: [ModelCall] = []
        agent.restore = {
            restored += 1
            screen.frame = freshFrame
            screen.updated = now()
        }
        agent.onModelCall = { calls.append($0) }
        _ = try await agent.step()
        XCTAssertEqual(restored, 1)
        XCTAssertEqual(model.images, [oldFrame, freshFrame])
        XCTAssertEqual(phone.taps, [CGPoint(x: 0.1, y: 0.2)])
        XCTAssertEqual(calls.count, 2, "The discarded completed request still contributes usage")
        XCTAssertTrue(calls.allSatisfy { $0.reply != nil })
    }

    func testNetworkFailureAfterReconnectRestoresAndRetries() async throws {
        let phone = FakeGestures(), screen = FakeScreen()
        let device = try XCTUnwrap(phone.device as? FakeDevice)
        let model = ConnectionFailureModel { device.links += 1 }
        let agent = AgentLoop(phone: phone, screen: screen, actor: model, planner: nil, trace: nil)
        var restored = 0, calls: [ModelCall] = []
        agent.restore = { restored += 1; screen.frame = Data([3]); screen.updated = now() }
        agent.onModelCall = { calls.append($0) }
        let acts = try await agent.nextActions()
        XCTAssertEqual(model.calls, 2)
        XCTAssertEqual(restored, 1)
        XCTAssertEqual(acts.first?.act["action"], .str("wait"))
        XCTAssertEqual(calls.count, 2)
        XCTAssertNotNil(calls.first?.error)
        XCTAssertNotNil(calls.last?.reply)
    }

    func testLinkChangesAtActionGateCannotExecuteAcceptedOldReply() async throws {
        let phone = FakeGestures(), screen = FakeScreen()
        let device = try XCTUnwrap(phone.device as? FakeDevice)
        let actor = FakeModel { call in
            call == 1 ? "THINK: old screen\nDO: tap 900 900"
                : call == 2 ? "THINK: fresh screen\nDO: tap 100 200" : "THINK: done\nDO: done ok"
        }
        let agent = AgentLoop(phone: phone, screen: screen, actor: actor, planner: nil, trace: nil)
        var gates = 0, restored = 0
        agent.gate = {
            gates += 1
            if gates == 2 { device.links += 1 }  // the look, then its first action gate
        }
        agent.restore = { restored += 1; screen.frame = Data([4]); screen.updated = now() }
        await agent.run()
        XCTAssertEqual(restored, 1)
        XCTAssertEqual(phone.taps, [CGPoint(x: 0.1, y: 0.2)])
        XCTAssertEqual(agent.steps.last?["action"], .str("done"))
    }

    func testCancelledRequestRecoveryDoesNotWaitForTheBoard() async throws {
        let phone = FakeGestures(), screen = FakeScreen()
        let device = try XCTUnwrap(phone.device as? FakeDevice)
        let replied = expectation(description: "Old response returned after the board disconnected")
        let actor = FakeModel { _ in
            device.connected = false
            replied.fulfill()
            return "THINK: stale\nDO: tap 900 900"
        }
        let agent = AgentLoop(phone: phone, screen: screen, actor: actor, planner: actor, trace: nil)
        let query = Task { try await agent.nextActions() }
        await fulfillment(of: [replied], timeout: 1)
        query.cancel()
        do { _ = try await query.value; XCTFail("Recovery must observe cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(phone.calls.isEmpty)
    }

    func testRepeatedReconnectsShareOneRecoveryDeadline() async throws {
        let phone = FakeGestures(), screen = FakeScreen()
        let device = try XCTUnwrap(phone.device as? FakeDevice)
        let actor = FakeModel { _ in
            device.links += 1
            return "THINK: stale\nDO: tap 900 900"
        }
        let agent = AgentLoop(phone: phone, screen: screen, actor: actor, planner: actor, trace: nil)
        agent.recoveryLimit = 0.02
        agent.restore = { screen.frame = Data([5]); screen.updated = now() }
        do { _ = try await agent.nextActions(); XCTFail("Flapping must not retry forever") }
        catch { XCTAssertTrue(error is BlindError) }
        XCTAssertLessThanOrEqual(actor.prompts.count, 2)
        XCTAssertTrue(phone.calls.isEmpty)
    }

    func testTimeoutRetriesOnceAndChecksGateAgain() async throws {
        let model = TimeoutModel(failures: 1)
        let agent = AgentLoop(phone: nil, screen: FakeScreen(), actor: model, planner: nil, trace: nil)
        var gates = 0
        var retryShown = false
        agent.gate = { gates += 1 }
        agent.onDoing = { if case .retrying = $0 { retryShown = true } }
        let acts = try await agent.nextActions()
        XCTAssertEqual(model.calls, 2)
        XCTAssertEqual(gates, 2)
        XCTAssertTrue(retryShown)
        XCTAssertEqual(acts.first?.act["action"], .str("wait"))
    }

    func testTimeoutStopsAfterOneRetry() async {
        let model = TimeoutModel(failures: 10)
        let agent = AgentLoop(phone: nil, screen: FakeScreen(), actor: model, planner: nil, trace: nil)
        do { _ = try await agent.nextActions(); XCTFail("Expected timeout") }
        catch { XCTAssertTrue(ModelRequestFailure.isTimeout(error)) }
        XCTAssertEqual(model.calls, 2)
        XCTAssertTrue(agent.steps.isEmpty)
    }

    func testActorShowsPendingThenReceiving() async throws {
        let model = ProgressModel()
        let agent = AgentLoop(phone: nil, screen: FakeScreen(), actor: model, planner: nil, trace: nil)
        var states: [String] = []
        agent.onDoing = {
            switch $0 {
            case .waiting: states.append("waiting")
            case .planning: states.append("planning")
            case .thinking: states.append("thinking")
            default: break
            }
        }
        _ = try await agent.nextActions()
        XCTAssertEqual(states.first, "waiting")
        XCTAssertEqual(states.last, "thinking")
        XCTAssertFalse(states.contains("planning"))
        XCTAssertNil(model.onProgress)
    }

    func testParseSingleAction() throws {
        let acts = try Actions.parseActions("THINK: The Search pill is visible, so I tap it.\nDO: tap 500 814")
        XCTAssertEqual(acts, [["thought": .str("The Search pill is visible, so I tap it."), "thought_zh": .str(""),
                               "action": .str("tap"), "x": .int(500), "y": .int(814)]])
        XCTAssertEqual(acts[0].keys, ["thought", "thought_zh", "action", "x", "y"])
    }

    func testParseSeveralActionsKeepsThoughtOnFirst() throws {
        let acts = try Actions.parseActions("THINK: Type and search.\nDO: type Whiteboard\nDO: key enter")
        XCTAssertEqual(acts.map { $0["action"]?.str }, ["type", "key"])
        XCTAssertEqual(acts[0]["text"], .str("Whiteboard"))
        XCTAssertEqual(acts[1]["combo"], .str("enter"))
        XCTAssertNil(acts[1]["thought"])
    }

    func testParseStopsWhereTheModelIsBlind() throws {
        let send = try Actions.parseActions("THINK: Focus, type, send.\nDO: tap 420 908\nDO: type 你好\nDO: tap 917 908")
        XCTAssertEqual(send.map { $0["action"]?.str }, ["tap", "type"])
        let search = try Actions.parseActions("THINK: Search.\nDO: tap 500 815\nDO: type Notes\nDO: key enter\nDO: tap 1 1")
        XCTAssertEqual(search.map { $0["action"]?.str }, ["tap", "type", "key"])
        let early = try Actions.parseActions("THINK: Check it.\nDO: wait\nTHINK: Sent.\nDO: done")
        XCTAssertEqual(early.map { $0["action"]?.str }, ["wait"])
        XCTAssertEqual(try Actions.parseActions("THINK: Sent.\nDO: done").map { $0["action"]?.str }, ["done"])
        let open = try Actions.parseActions("THINK: Bilibili.\nDO: open Bilibili\nDO: tap 1 1")
        XCTAssertEqual(open.map { $0["app"]?.str ?? $0["action"]?.str }, ["Bilibili"])
        let ime = try Actions.parseActions("THINK: English.\nDO: key cmd+a\nDO: key ctrl+space\nDO: type Hello")
        XCTAssertEqual(ime.map { $0["combo"]?.str ?? $0["action"]?.str }, ["cmd+a", "ctrl+space"])
    }

    func testParseCapsAtSixActions() throws {
        let reply = "THINK: draw\n" + (0..<10).map { "DO: tap \($0) \($0)" }.joined(separator: "\n")
        XCTAssertEqual(try Actions.parseActions(reply).count, 6)
    }

    func testParsePathAndCircle() throws {
        XCTAssertEqual(try Actions.parseCommand("path 100 200 300 400 500 600")["points"],
                       .arr([.arr([.int(100), .int(200)]), .arr([.int(300), .int(400)]), .arr([.int(500), .int(600)])]))
        XCTAssertEqual(try Actions.parseCommand("circle 500 450 200"),
                       ["action": .str("circle"), "x": .int(500), "y": .int(450), "r": .int(200)])
    }

    func testParseRejectsBadCommands() {
        for line in ["fly 1 2", "tap 500", "path 1 2 3"] {
            XCTAssertThrowsError(try Actions.parseCommand(line), line)
        }
    }

    func testParseRequiresADoLine() {
        XCTAssertThrowsError(try Actions.parseActions("THINK: I am not sure what to do."))
    }

    func testParsePlanWithAndWithoutLanguages() {
        XCTAssertTrue(Actions.parsePlan("EN:\n1. Tap Search\nZH:\n1. 点搜索") == ("1. Tap Search", "1. 点搜索"))
        XCTAssertTrue(Actions.parsePlan("1. Tap Search") == ("1. Tap Search", "1. Tap Search"))
    }

    func testCircleIsClosedAndRoundOnATallScreen() {
        let aspect = 0.46  // width / height of a portrait iPhone frame
        let pts = circle(0.5, 0.5, 0.2, aspect: aspect)
        XCTAssertEqual(pts[0].x, pts.last!.x, accuracy: 1e-9)
        XCTAssertEqual(pts[0].y, pts.last!.y, accuracy: 1e-9)
        for p in pts {  // equal radius in pixels: y offsets shrink by the aspect ratio
            XCTAssertEqual(hypot(p.x - 0.5, (p.y - 0.5) / aspect), 0.2, accuracy: 1e-9)
        }
    }

    func testPreciseTapFlag() throws {
        XCTAssertEqual(try Actions.parseCommand("tap 120 640 precise"),
                       ["action": .str("tap"), "x": .int(120), "y": .int(640), "precise": .bool(true)])
        XCTAssertNil(try Actions.parseCommand("tap 120 640")["precise"])
    }

    // MARK: - beyond the Python tests

    func testHistoryIsFormattedLikePythonJSONDumps() async throws {
        let actor = FakeModel { _ in "THINK: ok\nDO: wait" }
        let agent = AgentLoop(phone: nil, screen: FakeScreen(), actor: actor, planner: actor, trace: nil)
        agent.steps = [
            ["t": .num(1), "shot": .bool(true), "action": .str("plan"), "plan": .str("1. x")],
            ["t": .num(2), "shot": .bool(true), "thought": .str("hi"), "action": .str("tap"), "x": .int(1), "y": .int(2),
             "think_s": .num(1.5), "changed": .bool(true)],
            ["t": .num(3), "shot": .bool(false), "action": .str("type"), "text": .str("café")],
        ]
        _ = try await agent.nextActions()
        XCTAssertTrue(actor.prompts[0].hasSuffix(
            "Recent actions:\n{\"action\": \"tap\", \"x\": 1, \"y\": 2} -> screen changed\n"
            + "{\"action\": \"type\", \"text\": \"caf\\u00e9\"}\n\nNext action?"))
    }

    func testRunStopsAfterThreeErrorsInARow() async {
        let model = FakeModel { _ in "no action here" }
        let agent = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: model, planner: model, trace: nil)
        await agent.run()
        XCTAssertEqual(agent.steps.last?["action"], .str("fail"))
        XCTAssertEqual(agent.steps.last?["reason"], .str("3 errors in a row"))
    }

    func testRunStopsAtOnceWhenTheFreeLineEndsIt() async {
        let model = FakeModel { _ in "THINK: x\nDO: wait" }
        model.error = LLMError.trialRunEnded
        let agent = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: model, planner: model, trace: nil)
        await agent.run()
        XCTAssertEqual(model.prompts.count, 1)  // no retries: every further call would be refused too
        XCTAssertEqual(agent.steps.last?["action"], .str("error"))
    }

    func testStepTimingIsKeptForTheNextRequest() async {
        let model = FakeModel { n in n == 1 ? "THINK: home\nDO: home" : "THINK: there\nDO: done ok" }
        let agent = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: model, planner: nil, trace: nil)
        await agent.run()
        let header = StepReport.shared.take()[StepReport.header] ?? ""
        XCTAssertTrue(header.hasPrefix("llm="), header)
        XCTAssertTrue(header.contains(",settle=") && header.contains(",mode=stream,gap="), header)
        XCTAssertFalse(StepWaits.moving)
    }

    func testRunFinishesOnDone() async {
        let model = FakeModel { n in n == 1 ? "THINK: home\nPLAN:\n1. Go home\nDO: home" : "THINK: there\nDO: done ok" }
        let phone = FakeGestures()
        let agent = AgentLoop(phone: phone, screen: FakeScreen(), actor: model, planner: nil, trace: nil)
        await agent.run()
        XCTAssertEqual(phone.calls, ["home"])
        XCTAssertEqual(agent.steps.map { $0["action"]?.str }, ["plan", "home", "done"])
        XCTAssertEqual(agent.plan, "1. Go home")
        XCTAssertEqual(agent.steps.last?["answer"], .str("ok"))
        XCTAssertTrue(model.prompts[0].contains("Plan:\n(none yet: write one)"))  // one call plans and acts
        XCTAssertTrue(model.prompts[1].contains("Plan:\n1. Go home\n\nRecent actions:"))  // the layout Jev reads
    }

    // MARK: - the model keeps its own plan

    /// A plain grey JPEG (Vision.changed needs a decodable frame).
    static func jpeg() -> Data {
        let ctx = CGContext(data: nil, width: 60, height: 130, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 60, height: 130))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    func testPlanBlockParsing() {
        XCTAssertEqual(Actions.planBlock("THINK: a\nPLAN:\n1. Open Duolingo\n2. Answer until the results\nDO: open Duolingo"),
                       "1. Open Duolingo\n2. Answer until the results")
        XCTAssertEqual(Actions.planBlock("THINK: a\nPLAN: 1. One line\nDO: wait"), "1. One line")
        XCTAssertNil(Actions.planBlock("THINK: a\nDO: wait"))
        XCTAssertNil(Actions.planBlock("THINK: a\nPLAN:\nDO: wait"))
    }

    func testAPlanUpdateReplacesThePlanOnlyWhenItChanges() async throws {
        let model = FakeModel { n in
            n == 1 ? "THINK: lesson\nPLAN:\n1. Answer until the results screen\nDO: tap 1 2"
                : n == 2 ? "THINK: same\nPLAN:\n1. Answer until the results screen\nDO: tap 3 4" : "THINK: ok\nDO: wait"
        }
        let agent = AgentLoop(phone: nil, screen: FakeScreen(), actor: model, planner: nil, trace: nil)
        agent.plan = "1. Open Duolingo\n2. Do one exercise"
        for _ in 0..<3 { _ = try await agent.nextActions() }
        XCTAssertEqual(agent.plan, "1. Answer until the results screen")
        XCTAssertEqual(agent.steps.filter { $0["action"]?.str == "plan" }.count, 1)
    }

    func testNoHarnessRuleOverridesTheModel() async throws {
        // the same move again after it changed nothing goes through: the model sees the result and decides
        let model = FakeModel { _ in "THINK: again, precisely\nDO: tap 500 921 precise" }
        let agent = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: model, planner: nil, trace: nil)
        agent.steps = [["action": .str("tap"), "x": .int(500), "y": .int(921), "changed": .bool(false)],
                       ["action": .str("tap"), "x": .int(500), "y": .int(921), "changed": .bool(false)]]
        let acts = try await agent.nextActions()
        XCTAssertEqual(acts[0].act["action"], .str("tap"))
        XCTAssertEqual(model.prompts.count, 1)
    }

    /// 2026-11-06: the pointer landed 3% above the Search pill, outside the target's mask; the pointer alone
    /// read as "changed". Found where it really is, the tap reads as a miss.
    func testAPointerLandedOffTargetIsNotAScreenChange() async throws {
        let v = VisionTests(), phone = FakeGestures(), screen = FakeScreen()
        screen.frame = v.screen(pointer: (249, 518))
        phone.onTap = { screen.frame = v.screen(pointer: (232, 852)) }
        phone.landed = v.p(232, 852)
        let model = FakeModel { _ in "THINK: Search\nDO: tap 500 814" }
        let agent = AgentLoop(phone: phone, screen: screen, actor: model, planner: nil, trace: nil)
        agent.pointerAt = v.p(249, 518)
        _ = try await agent.step()
        XCTAssertEqual(agent.steps.last?["changed"], .bool(false))
        XCTAssertNotNil(agent.steps.last?["landed"])
        XCTAssertEqual(agent.pointerAt, v.p(232, 852))
        // new content still counts, with the pointer found
        let other = FakeGestures(), shown = FakeScreen()
        shown.frame = v.screen(pointer: (249, 518))
        other.onTap = { shown.frame = v.screen(pointer: (232, 852), checked: true) }
        other.landed = v.p(232, 852)
        let again = AgentLoop(phone: other, screen: shown, actor: FakeModel { _ in "THINK: x\nDO: tap 500 814" },
                              planner: nil, trace: nil)
        again.pointerAt = v.p(249, 518)
        _ = try await again.step()
        XCTAssertEqual(again.steps.last?["changed"], .bool(true))
    }

    func testATapThatChangedNothingIsPressedOnceMoreWithThePointerChecked() async throws {
        let phone = FakeGestures(), screen = FakeScreen()
        screen.frame = Self.jpeg()  // the same before and after
        let agent = AgentLoop(phone: phone, screen: screen, actor: FakeModel { _ in "THINK: Send\nDO: tap 500 500" },
                              planner: nil, trace: nil)
        _ = try await agent.step()
        XCTAssertEqual(phone.aims, [false, true])
        XCTAssertEqual(phone.taps, [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.5, y: 0.5)])
        XCTAssertEqual(agent.steps.last?["again"], .bool(true))
        XCTAssertEqual(agent.steps.last?["changed"], .bool(false))
        XCTAssertNil(Actions.key(agent.steps.last!)["again"])
    }

    func testASecondPressThatWorksReadsAsChanged() async throws {
        let v = VisionTests(), phone = FakeGestures(), screen = FakeScreen()
        screen.frame = v.screen()
        var presses = 0
        phone.onTap = { presses += 1; if presses == 2 { screen.frame = v.screen(button: true) } }
        let agent = AgentLoop(phone: phone, screen: screen, actor: FakeModel { _ in "THINK: Open\nDO: tap 500 500" },
                              planner: nil, trace: nil)
        _ = try await agent.step()
        XCTAssertEqual(presses, 2)
        XCTAssertEqual(agent.steps.last?["changed"], .bool(true))
    }

    func testAMissWithThePointerOnTheTargetIsNotPressedAgain() async throws {
        let phone = FakeGestures(), screen = FakeScreen()
        phone.landed = CGPoint(x: 0.505, y: 0.495)
        screen.frame = Self.jpeg()
        let agent = AgentLoop(phone: phone, screen: screen, actor: FakeModel { _ in "THINK: label\nDO: tap 500 500" },
                              planner: nil, trace: nil)
        _ = try await agent.step()
        XCTAssertEqual(phone.aims, [false])  // the target itself does nothing: the model decides what next
        XCTAssertEqual(agent.steps.last?["changed"], .bool(false))
    }

    func testAConfirmedTapIsNeverPressedTwice() async throws {
        let phone = FakeGestures(), screen = FakeScreen()
        screen.frame = Self.jpeg()  // the same before and after
        let agent = AgentLoop(phone: phone, screen: screen, actor: FakeModel { _ in "THINK: Send\nDO: tap 500 500" },
                              planner: nil, trace: nil)
        agent.steps = [["action": .str("confirm"), "reason": .str("send the message")],
                       ["action": .str("confirmed"), "reason": .str("the user said yes, do it now: send the message")]]
        _ = try await agent.step()
        XCTAssertEqual(phone.aims, [false])
        XCTAssertEqual(agent.steps.last?["changed"], .bool(false))
        XCTAssertNil(agent.steps.last?["again"])
    }

    func testATargetThatMovedByItselfIsNotPressedAgain() async throws {
        let v = VisionTests(), phone = FakeGestures(), screen = FakeScreen()
        let seen = v.screen(spinner: 230)
        screen.frame = seen
        var looked = false
        let model = FakeModel { _ in
            looked = true
            return "THINK: bar\nDO: tap 720 289"  // on the bar (x 300-420, y 300-324 of 498 x 1080)
        }
        let agent = AgentLoop(phone: phone, screen: screen, actor: model, planner: nil, trace: nil)
        agent.onDoing = { if case .acting = $0, looked { screen.frame = v.screen(spinner: 90) } }  // moved while the model looked
        phone.onTap = { screen.frame = v.screen(spinner: 160) }
        _ = try await agent.step()
        XCTAssertEqual(phone.aims, [false])
        XCTAssertEqual(agent.steps.last?["changed"], .bool(false))
    }

    func testAMissedTapSaysWhereThePointerIs() async throws {
        let phone = FakeGestures()
        phone.landed = CGPoint(x: 0.5, y: 0.958)
        let screen = FakeScreen()
        screen.frame = Self.jpeg()  // a real picture, the same before and after the tap
        let model = FakeModel { _ in "THINK: Check\nDO: tap 500 921" }
        let agent = AgentLoop(phone: phone, screen: screen, actor: model, planner: nil, trace: nil)
        _ = try await agent.step()  // the fake screen never changes
        XCTAssertEqual(agent.steps.last?["landed"], .arr([.int(500), .int(958)]))
        XCTAssertEqual(AgentLoop.effect(agent.steps.last!),
                       " -> screen did NOT change; the pointer is at 500 958 (37 below the target)")
        XCTAssertNil(Actions.key(agent.steps.last!)["landed"])
    }

    /// Pause holds at the gesture gate. Continue must not send a tap chosen for the screen from before the pause.
    func testPauseBeforeAChosenGestureDropsItAndLooksAgain() async throws {
        let phone = FakeGestures()
        let model = FakeModel { n in n == 1 ? "THINK: tap\nDO: tap 10 20\nDO: type hi" : "THINK: now\nDO: wait" }
        let agent = AgentLoop(phone: phone, screen: FakeScreen(), actor: model, planner: nil, trace: nil)
        var gestureGates = 0
        agent.gate = {
            guard agent.droppingChosenGesture else { return }  // a pause during the look does not drop the decision
            gestureGates += 1
            if gestureGates == 1 { agent.notePauseInterrupted() }
        }
        let dropped = try await agent.step()
        XCTAssertFalse(dropped)
        XCTAssertEqual(phone.calls, [])
        XCTAssertTrue(agent.steps.isEmpty)
        let looked = try await agent.step()
        XCTAssertFalse(looked)
        XCTAssertEqual(phone.calls, [])
        XCTAssertEqual(agent.steps.last?["action"]?.str, "wait")
    }

    /// The first gesture of a batch ran; a pause before the next one sends nothing further.
    func testPauseBetweenGesturesDropsTheRest() async throws {
        let phone = FakeGestures()
        let model = FakeModel { _ in "THINK: tap then type\nDO: tap 10 20\nDO: type hi" }
        let agent = AgentLoop(phone: phone, screen: FakeScreen(), actor: model, planner: nil, trace: nil)
        var gestureGates = 0
        agent.gate = {
            guard agent.droppingChosenGesture else { return }
            gestureGates += 1
            if gestureGates == 2 { agent.notePauseInterrupted() }
        }
        let dropped = try await agent.step()
        XCTAssertFalse(dropped)
        XCTAssertEqual(phone.calls, ["tap"])
        XCTAssertEqual(agent.steps.map { $0["action"]?.str }, ["tap"])
    }
}

// MARK: - fakes

@MainActor final class FakeModel: ChatModel {
    let model = "fake"
    private(set) var prompts: [String] = []
    private(set) var images: [Data?] = []
    private let reply: (Int) -> String
    var tree: Data?  // the free line's handsy.tree on every reply
    var error: Error?  // thrown instead of a reply

    init(_ reply: @escaping (Int) -> String) { self.reply = reply }

    func chat(system: String, text: String, image: Data?, maxTokens: Int, temperature: Double) async throws -> ChatResult {
        prompts.append(text)
        images.append(image)
        if let error { throw error }
        var result = ChatResult(text: reply(prompts.count), firstToken: nil, total: 0)
        result.tree = tree
        return result
    }
}

@MainActor final class FakeScreen: ScreenSource {
    var live = true
    var frame: Data? = Data([0xff, 0xd8])
    var updated = 0.0
    var capturedAt = 0.0
    var aspect = 0.46
    var stale = false
}

@MainActor final class FakeDevice: HIDDevice {
    var links = 1
    var connected = true
    var sent: [String] = []
    var onSend: ((String) -> Void)?
    func send(_ command: String) async throws -> String {
        sent.append(command)
        onSend?(command)
        return ""
    }
    func waitConnected(_ timeout: TimeInterval) async -> Bool { connected }
}

@MainActor final class FakeGestures: Gestures {
    let device: HIDDevice = FakeDevice()
    var calls: [String] = []
    var taps: [CGPoint] = []
    var aims: [Bool] = []
    var onTap: (() -> Void)?  // e.g. the screen shows the pointer where it landed
    func tap(_ x: Double, _ y: Double, aim: Bool) async throws {
        calls.append("tap")
        aims.append(aim)
        taps.append(CGPoint(x: x, y: y))
        onTap?()
    }
    func swipe(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, hold: Bool) async throws { calls.append("swipe") }
    func drag(_ points: [CGPoint], hold: Bool) async throws { calls.append("drag") }
    var typeNote: String?
    func type(_ text: String) async throws -> String? { calls.append("type"); return typeNote }
    func key(_ combo: String) async throws { calls.append("key") }
    func goHome() async throws { calls.append("home") }
    var openResult = OpenResult.opened
    func openApp(_ name: String) async throws -> OpenResult { calls.append("open \(name)"); return openResult }
    func goBack() async throws { calls.append("back") }
    func reset() async throws { calls.append("reset") }
    var landed: CGPoint?
    func landing(_ x: Double, _ y: Double) async -> CGPoint? { landed }
    var pointerVisible: Bool?  // what a TouchCheck probe sees (nil = can't tell)
    var probes = 0
    func pointerSeen(near p: CGPoint) async -> Bool? { probes += 1; return pointerVisible }
}

@MainActor private final class ConnectionFailureModel: ChatModel {
    let model = "connection-failure-test"
    private(set) var calls = 0
    let onFirst: () -> Void
    init(_ onFirst: @escaping () -> Void) { self.onFirst = onFirst }
    func chat(system: String, text: String, image: Data?, maxTokens: Int, temperature: Double) async throws -> ChatResult {
        calls += 1
        if calls == 1 {
            onFirst()
            throw URLError(.networkConnectionLost)
        }
        return ChatResult(text: "THINK: new screen\nDO: wait", total: 0)
    }
}

@MainActor private final class TimeoutModel: ChatModel {
    let model = "timeout-test"
    let failures: Int
    var calls = 0
    init(failures: Int) { self.failures = failures }
    func chat(system: String, text: String, image: Data?, maxTokens: Int, temperature: Double) async throws -> ChatResult {
        calls += 1
        if calls <= failures { throw URLError(.timedOut) }
        return ChatResult(text: "THINK: look\nDO: wait", total: 0)
    }
}

@MainActor private final class ProgressModel: ChatModel, ModelProgressReporting {
    let model = "progress-test"
    var onProgress: ((ModelResponseProgress) -> Void)?
    func chat(system: String, text: String, image: Data?, maxTokens: Int, temperature: Double) async throws -> ChatResult {
        onProgress?(.waiting)
        onProgress?(.receiving)
        return ChatResult(text: "THINK: Wait for the screen\nDO: wait", total: 0)
    }
}
