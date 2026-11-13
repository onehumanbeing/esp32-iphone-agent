import XCTest
@testable import IPhoneAgent

/// Saved intents as scripts: moves, AI sub-goals, notebook steps, steps for the user and `until` rounds.
@MainActor final class ScriptTests: XCTestCase {
    private func step(_ action: JObject, frame: Data? = nil) -> Replay.Step { .init(action: action, sure: true, frame: frame) }

    /// "Read every page until the end": an AI step and a read, again until the judge says yes. No planner call.
    func testUntilRepeatsTheScriptAndCollects() async {
        let model = FakeModel { n in
            switch n {
            case 1, 4: return "THINK: on the list\nDO: done list open"
            case 2: return "A\nB"
            case 3: return "NO, more below"
            case 5: return "B\nC"
            default: return "YES, the end of the list"
            }
        }
        let agent = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: model, planner: model, trace: nil)
        agent.replay = Replay(steps: [step(["action": .str("ai"), "goal": .str("Show the next page")]),
                                      step(["action": .str("read"), "what": .str("titles")])],
                              until: "the list shows its end", maxLoops: 3)
        await agent.run()
        XCTAssertEqual(model.prompts.count, 6)
        XCTAssertEqual(agent.notebook.items, ["A", "B", "C"])
        XCTAssertEqual(agent.steps.last?["action"], .str("done"))
        XCTAssertEqual(agent.steps.last?["notebook"], .arr(["A", "B", "C"].map { .str($0) }))
        XCTAssertEqual(agent.steps.filter { $0["action"] == .str("ai done") }.count, 2)
    }

    func testUntilGivesUpAfterMaxLoops() async {
        let model = FakeModel { n in n % 2 == 1 ? "THINK: x\nDO: done ok" : "NO" }
        let agent = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: model, planner: model, trace: nil)
        agent.replay = Replay(steps: [step(["action": .str("ai"), "goal": .str("next page")])], until: "the end", maxLoops: 2)
        await agent.run()
        XCTAssertEqual(agent.steps.last?["action"], .str("fail"))
        XCTAssertEqual(agent.steps.last?["reason"], .str("still not true after 2 rounds: the end"))
    }

    /// In a script a missed move is done by the model, then the script goes on (a plain recording would hand
    /// over the whole task instead).
    func testAMissedMoveIsRepairedAndTheScriptGoesOn() async {
        let screen = FakeScreen(); screen.frame = ReplayTests.screen(CGRect(x: 0.3, y: 0.3, width: 0.5, height: 0.5))
        let phone = ScriptedPhone { _ in }
        let model = FakeModel { n in
            switch n {
            case 1: return "THINK: the button moved\nDO: tap 100 500"
            case 2: return "THINK: did it\nDO: done ok"
            case 3: return "X"
            case 4: return "1. Check"
            default: return "THINK: all good\nDO: done finished"
            }
        }
        let agent = AgentLoop(phone: phone, screen: screen, actor: model, planner: model, trace: nil)
        let reference = ReplayTests.screen(CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.2))
        agent.replay = Replay(steps: [step(["action": .str("tap"), "x": .int(300), "y": .int(300)], frame: reference),
                                      step(["action": .str("read"), "what": .str("the title")])])
        await agent.run()
        XCTAssertEqual(phone.taps, 2)  // the model's tap changed nothing on the still fake screen: pressed once more
        XCTAssertTrue(model.prompts[0].contains("Do the equivalent of recorded step 1 on this screen"))
        XCTAssertEqual(agent.notebook.items, ["X"])
        XCTAssertEqual(agent.steps.last?["answer"], .str("finished"))
    }

    /// A manual step waits for the user; after they hand back, the script goes on.
    func testManualStepWaitsForTheUser() async {
        let model = FakeModel { n in n == 1 ? "1. Check" : "THINK: ok\nDO: done ok" }
        let agent = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: model, planner: model, trace: nil)
        var asked: [String] = []
        agent.onHelp = { reason in asked.append(reason); return .resume }
        agent.replay = Replay(steps: [step(["action": .str("manual"), "reason": .str("Log in")])])
        await agent.run()
        XCTAssertEqual(asked, ["Log in"])
        XCTAssertEqual(agent.steps.map { $0["action"]?.str }, ["help", "takeover", "done"])
    }

    func testOnlyNewStepKindsOrUntilMakeAScript() {
        XCTAssertFalse(Replay(steps: [step(["action": .str("tap"), "x": .int(1), "y": .int(1)]),
                                      step(["action": .str("note"), "text": .str("x")])]).isScript)
        XCTAssertTrue(Replay(steps: [step(["action": .str("ai"), "goal": .str("x")])]).isScript)
        XCTAssertTrue(Replay(steps: [], until: "done").isScript)
        XCTAssertFalse(Replay(steps: [], until: "  ").isScript)
    }
}
