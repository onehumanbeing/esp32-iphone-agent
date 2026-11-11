import XCTest
@testable import IPhoneAgent

/// Free line checkpoints: the rounds the planner (Opus on the gateway) answers instead of the actor.
@MainActor final class CheckpointTests: XCTestCase {
    private func swipe() -> JObject { ["action": .str("swipe"), "x1": .int(500), "y1": .int(700), "x2": .int(500), "y2": .int(300)] }

    func testReasons() {
        var c = Checkpoints()
        XCTAssertEqual(c.reason([]), "first round")
        c.used(at: 0)
        XCTAssertNil(c.reason([["action": .str("tap")]]))
        let circling = [swipe(), swipe(), swipe(), swipe()]
        XCTAssertEqual(c.reason(circling), "circling", "four swipes in a row, the plan unchanged")
        XCTAssertNil(c.reason([swipe(), ["action": .str("plan"), "plan": .str("2. x")], swipe(), swipe(), swipe()]),
                     "a new plan is progress")
        XCTAssertNil(c.reason([swipe(), swipe(), ["action": .str("tap")], swipe()]))
        c.used(at: 4)
        XCTAssertNil(c.reason(circling + [swipe()]), "counted again from the last checkpoint")
        c.asked = "repeat"
        XCTAssertEqual(c.reason([]), "repeat")
        c.used(at: 5)
        XCTAssertNil(c.asked)
    }

    private func agent(actor: FakeModel, planner: FakeModel?) -> AgentLoop {
        let screen = FakeScreen()
        let a = AgentLoop(phone: FakeGestures(), screen: screen, actor: actor, planner: nil, trace: nil)
        a.checkpointModel = planner
        return a
    }

    func testFirstRoundGoesToThePlanner() async throws {
        let actor = FakeModel { _ in "THINK: a\nDO: tap 100 200" }, planner = FakeModel { _ in "THINK: p\nPLAN:\n1. x\nDO: tap 300 400" }
        let a = agent(actor: actor, planner: planner)
        let first = try await a.nextActions()
        XCTAssertEqual(first.first?.act["x"], .int(300))
        XCTAssertEqual(planner.prompts.count, 1)
        XCTAssertEqual(actor.prompts.count, 0)
        a.steps.append(first[0].act)
        _ = try await a.nextActions()
        XCTAssertEqual(actor.prompts.count, 1, "later rounds: the actor")
        XCTAssertEqual(planner.prompts.count, 1)
    }

    func testTheActorsDoneIsCheckedByThePlanner() async throws {
        let actor = FakeModel { _ in "THINK: found\nDO: done the address" }
        let planner = FakeModel { _ in "THINK: rating missing but not shown\nDO: done address 29 Essex St; no rating shown" }
        let a = agent(actor: actor, planner: planner)
        a.checkpoints.used(at: 0)  // past the first round
        let acts = try await a.nextActions()
        XCTAssertEqual(actor.prompts.count, 1)
        XCTAssertEqual(planner.prompts.count, 1)
        XCTAssertEqual(acts.first?.act["action"], .str("done"))
        XCTAssertEqual(acts.first?.act["answer"]?.str, "address 29 Essex St; no rating shown")
    }

    func testThePlannerCanOverruleADone() async throws {
        let actor = FakeModel { _ in "THINK: done\nDO: done ok" }, planner = FakeModel { _ in "THINK: not yet\nDO: tap 10 20" }
        let a = agent(actor: actor, planner: planner)
        a.checkpoints.used(at: 0)
        let acts = try await a.nextActions()
        XCTAssertEqual(acts.first?.act["action"], .str("tap"))
    }

    func testAFailingPlannerFallsBackToTheActor() async throws {
        let actor = FakeModel { _ in "THINK: a\nDO: tap 100 200" }, planner = FakeModel { _ in "" }
        planner.error = LLMError(message: "unknown model")
        let a = agent(actor: actor, planner: planner)
        let acts = try await a.nextActions()
        XCTAssertEqual(acts.first?.act["x"], .int(100))
        XCTAssertEqual(actor.prompts.count, 1)
    }

    func testWithoutAPlannerNothingChanges() async throws {
        let actor = FakeModel { _ in "THINK: done\nDO: done ok" }
        let a = agent(actor: actor, planner: nil)
        let acts = try await a.nextActions()
        XCTAssertEqual(acts.first?.act["action"], .str("done"))
        XCTAssertEqual(actor.prompts.count, 1)
    }
}
