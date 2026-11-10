import XCTest
@testable import IPhoneAgent

/// The board acknowledges gestures but the iPhone takes no pointer from it: found early, the run asks with what to check.
@MainActor final class TouchCheckTests: XCTestCase {
    private func step(_ action: String, changed: Bool, landed: Int? = nil) -> JObject {
        var s: JObject = ["action": .str(action), "changed": .bool(changed), "x": .num(500), "y": .num(500)]
        if let landed { s["landed"] = .arr([.int(landed), .int(500)]) }
        return s
    }

    func testPointerRoundsThatChangeNothingAskForOneProbe() {
        var check = TouchCheck()
        XCTAssertEqual(check.note(step("tap", changed: false), big: false), .wait)
        XCTAssertEqual(check.note(step("key", changed: false), big: false), .wait, "keys go through the keyboard, not the pointer")
        XCTAssertEqual(check.note(step("swipe", changed: false), big: false), .wait)
        XCTAssertEqual(check.note(step("type", changed: true), big: true), .wait, "a keyboard change says nothing about the pointer")
        XCTAssertEqual(check.note(step("back", changed: false), big: false), .probe)
        XCTAssertTrue(check.probed(false))
        XCTAssertFalse(check.armed)
        XCTAssertEqual(check.note(step("tap", changed: false), big: false), .wait, "one verdict per run")
    }

    func testAnySignThePointerWorksDisarmsIt() {
        var changed = TouchCheck()
        _ = changed.note(step("tap", changed: false), big: false)
        _ = changed.note(step("tap", changed: true), big: true)
        XCTAssertFalse(changed.armed)
        var landed = TouchCheck()
        _ = landed.note(step("tap", changed: false, landed: 530), big: false)
        XCTAssertFalse(landed.armed, "the landing check saw the pointer on the target")
        var unsure = TouchCheck()
        XCTAssertFalse(unsure.probed(nil), "a probe that could not tell never stops the run")
        XCTAssertFalse(unsure.probed(true))
    }

    func testASmallChangeOrAFarReadingIsNoSignThePointerWorks() {
        var check = TouchCheck()
        XCTAssertEqual(check.note(step("tap", changed: true), big: false), .wait, "e.g. a clock ticking")
        XCTAssertEqual(check.note(step("tap", changed: false, landed: 900), big: false), .wait,
                       "a reading far off the target may be something else on screen")
        XCTAssertTrue(check.armed)
        XCTAssertEqual(check.note(step("tap", changed: true), big: false), .probe)
    }

    private func run(visible: Bool?, maxStalls: Int = 12, answers: [AgentLoop.HelpChoice] = [.stop])
        async -> (agent: AgentLoop, phone: FakeGestures, asked: [String]) {
        // the fake screen never changes; taps move around, so NoProgress (one spot again and again) stays out of it
        let model = SystemRecorder { n in "THINK: try\nDO: tap \(100 + 50 * (n % 16)) 500" }
        let screen = FakeScreen(), phone = FakeGestures()
        screen.frame = AgentTests.jpeg()
        phone.pointerVisible = visible
        let agent = AgentLoop(phone: phone, screen: screen, actor: model, planner: model, trace: nil, maxStalls: maxStalls)
        var asked: [String] = [], answers = answers
        agent.onHelp = { reason in asked.append(reason); return answers.isEmpty ? .stop : answers.removeFirst() }
        await agent.run()
        return (agent, phone, asked)
    }

    func testTapsThatNeverReachTheIPhoneStopEarlyWithWhatToCheck() async {
        let (agent, phone, asked) = await run(visible: false)
        XCTAssertEqual(asked, [TouchCheck.reason])
        XCTAssertEqual(agent.steps.filter { $0["action"]?.str == "tap" }.count, TouchCheck.rounds)
        XCTAssertEqual(phone.probes, 1)
    }

    func testAVisiblePointerLeavesTheRunToTheStallLimit() async {
        let (agent, phone, asked) = await run(visible: true, maxStalls: 5)
        XCTAssertEqual(asked, ["\(AgentLoop.stallReason) in 5 steps"])
        XCTAssertEqual(agent.steps.filter { $0["action"]?.str == "tap" }.count, 5)
        XCTAssertEqual(phone.probes, 1, "probed once, then disarmed")
    }

    func testAPhoneThatCannotSeeThePointerIsNeverStoppedForIt() async {
        let (_, phone, asked) = await run(visible: nil, maxStalls: 4)
        XCTAssertEqual(asked, ["\(AgentLoop.stallReason) in 4 steps"])
        XCTAssertEqual(phone.probes, 1)
    }

    func testAfterKeepGoingTheCheckIsArmedAgain() async {
        let (agent, phone, asked) = await run(visible: false, answers: [.resume, .stop])
        XCTAssertEqual(asked, [TouchCheck.reason, TouchCheck.reason])
        XCTAssertEqual(agent.steps.filter { $0["action"]?.str == "tap" }.count, 2 * TouchCheck.rounds)
        XCTAssertEqual(phone.probes, 2)
    }

    func testTheFreeLineReportsItAsAStall() {
        let end = RunEnd(steps: [["action": .str("fail"), "reason": .str(TouchCheck.reason)]], moves: 3, calls: 3, firmware: nil)
        XCTAssertEqual(end.reason, .stall, "the gateway only takes its own list of reasons")
    }
}
