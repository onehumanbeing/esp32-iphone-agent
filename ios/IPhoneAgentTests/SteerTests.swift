import XCTest
@testable import IPhoneAgent

/// Henry 2026-11-13: words added while a run goes join its next round (AgentLoop+Steer).
@MainActor final class SteerTests: XCTestCase {
    private func agent(_ actor: FakeModel) -> AgentLoop {
        let agent = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: actor, planner: nil, trace: nil)
        agent.showMock(task: "Delete the old notes", plan: "", steps: [], running: true)
        return agent
    }

    func testAddedWordsJoinTheNextRoundAndTheTrace() async throws {
        let actor = FakeModel { _ in "THINK: look\nDO: wait" }
        let agent = agent(actor)
        XCTAssertTrue(agent.steer("  only the ones from March  "))
        _ = try await agent.step()
        XCTAssertTrue(actor.prompts[0].contains("The user added while you worked"))
        XCTAssertTrue(actor.prompts[0].contains("- only the ones from March"))
        XCTAssertEqual(agent.steps.filter { $0["action"]?.str == "steer" }.count, 1)
        XCTAssertTrue(agent.steering.isEmpty)
        _ = try await agent.step()
        XCTAssertTrue(actor.prompts[1].contains("only the ones from March"), "kept for the rest of the run")
        XCTAssertEqual(agent.steps.filter { $0["action"]?.str == "steer" }.count, 1, "written once")
        XCTAssertFalse(actor.prompts[1].contains("\"steer\""), "not repeated in the recent actions")
    }

    func testNothingIsQueuedWithoutARunOrWords() {
        let agent = agent(FakeModel { _ in "DO: wait" })
        XCTAssertFalse(agent.steer("   "))
        agent.showMock(task: "x", plan: "", steps: [], running: false)
        XCTAssertFalse(agent.steer("later"))
        XCTAssertTrue(agent.steering.isEmpty)
    }

    func testASteerIsNotAMove() {
        XCTAssertTrue(StepText.notMoves.contains("steer"))
        XCTAssertEqual(StepText.title(["action": .str("steer"), "text": .str("skip pinned")]), "You added: skip pinned")
    }
}
