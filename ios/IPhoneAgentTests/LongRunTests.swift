import XCTest
@testable import IPhoneAgent

/// Henry 2026-11-13: a task over many items runs past 300 steps and keeps what it listed across a Continue.
@MainActor final class LongRunTests: XCTestCase {
    private func agent(_ task: String) -> AgentLoop {
        let agent = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: FakeModel { _ in "" }, planner: nil, trace: nil)
        agent.showMock(task: task, plan: "", steps: [], running: true)
        agent.inventory = Inventory(task: task)
        return agent
    }

    func testABatchTaskGetsTheLongLimit() {
        XCTAssertEqual(agent("delete all old notes").stepLimit, AgentLoop.longLimit)
        let plain = agent("Open WeChat")
        XCTAssertEqual(plain.stepLimit, plain.maxSteps)
        XCTAssertEqual(plain.stepLimit(for: "删除所有草稿"), AgentLoop.longLimit)
    }

    func testEveryTenMovesTheNotebookIsSavedAndComesBack() {
        let a = agent("delete all old notes")
        a.notebook.add(["Note A", "Note B"])
        for i in 0..<9 { a.record(nil, ["action": .str("tap"), "x": .int(i), "y": .int(1)]) }
        a.saveCheckpoint()
        XCTAssertFalse(a.steps.contains { $0["action"]?.str == AgentLoop.checkpointAction }, "not at 9 moves")
        a.record(nil, ["action": .str("tap"), "x": .int(9), "y": .int(1)])
        a.saveCheckpoint()
        a.saveCheckpoint()
        XCTAssertEqual(a.steps.filter { $0["action"]?.str == AgentLoop.checkpointAction }.count, 1, "once per ten")
        XCTAssertEqual(AgentLoop.savedNotebook(a.steps).items, ["Note A", "Note B"])
        XCTAssertTrue(AgentLoop.savedNotebook([]).isEmpty)
    }
}
