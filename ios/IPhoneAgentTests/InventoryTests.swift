import XCTest
@testable import IPhoneAgent

/// Henry 2026-11-13: a task over many items is listed and confirmed before anything is deleted.
@MainActor final class InventoryTests: XCTestCase {
    func testBatchTasksAreRecognised() {
        XCTAssertTrue(Inventory(task: "删除 3 月以前的所有读研文章").needed)
        XCTAssertTrue(Inventory(task: "Unfollow every account I don't know").needed)
        XCTAssertTrue(Inventory(task: "Open WeChat", until: true).needed, "a repeat-until intent")
        XCTAssertFalse(Inventory(task: "Open WeChat and send ok to 文件传输助手").needed)
    }

    func testTheFirstDestructiveTapIsHeldOnceAndNeverAfterAConfirm() {
        var inventory = Inventory(task: "delete all old notes")
        XCTAssertFalse(inventory.holds(label: "Notes", steps: []))
        XCTAssertTrue(inventory.holds(label: "Delete", steps: []))
        XCTAssertFalse(inventory.holds(label: "Delete", steps: []), "only once")
        var fresh = Inventory(task: "删除所有草稿")
        XCTAssertFalse(fresh.holds(label: "删除", steps: [["action": .str("confirmed")]]))
        XCTAssertTrue(Inventory.isDestructive("确定删除"))
        XCTAssertFalse(Inventory.isDestructive("删除线格式与其他文字说明"), "a long line that only mentions it")
    }

    func testABatchConfirmWaitsForTheUserEvenOnPaymentsOnly() async throws {
        let actor = FakeModel { _ in "THINK: list done\nDO: confirm Delete 2 notes: A, B" }
        let agent = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: actor, planner: nil, trace: nil)
        agent.showMock(task: "delete all my test notes", plan: "", steps: [], running: true)
        agent.inventory = Inventory(task: agent.task)
        agent.askMode = .payments
        var asked: String?
        agent.onConfirm = { reason in asked = reason; return .stop }
        let over = try await agent.step()
        XCTAssertTrue(over)
        XCTAssertEqual(asked, "Delete 2 notes: A, B")
    }
}
