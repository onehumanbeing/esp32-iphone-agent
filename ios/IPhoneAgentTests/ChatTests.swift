import XCTest
@testable import IPhoneAgent

/// Chats: earlier turns as prompt text, "continue", and the summary a stopped run leaves.
@MainActor final class ChatTests: XCTestCase {
    func testEarlierTurnsBecomePromptText() {
        let turns = [ChatTurn(ask: "Read my Bilibili favorites", run: "r1", outcome: "done", answer: "3 titles",
                              items: ["A", "B", "C"])]
        XCTAssertEqual(ChatContext.render(turns), "User: Read my Bilibili favorites\nResult (done): 3 titles\nCollected 3 items: A; B; C")
    }

    func testRenderKeepsTheNewestTurnsWithinTheLimit() {
        let turns = (1...10).map { ChatTurn(ask: "task \($0) " + String(repeating: "x", count: 900), run: "", outcome: "done", answer: "ok") }
        let text = ChatContext.render(turns)
        XCTAssertLessThanOrEqual(text.count, ChatContext.maxChars + 1)
        XCTAssertTrue(text.contains("task 10"))
        XCTAssertFalse(text.contains("task 6 "))
    }

    func testContinueWords() {
        XCTAssertTrue(ChatContext.isContinue("继续"))
        XCTAssertTrue(ChatContext.isContinue(" Continue. "))
        XCTAssertFalse(ChatContext.isContinue("continue reading the second folder"))
    }

    func testStopSummarySaysWhatWasDoneAndWhatIsLeft() {
        var book = Notebook()
        book.add(["A", "B"])
        book.setProgress("folder 1 of 3")
        let steps: [JObject] = [["action": .str("plan"), "plan": .str("1. x")],
                                ["action": .str("swipe"), "x1": .int(1), "y1": .int(2), "x2": .int(3), "y2": .int(4)],
                                ["action": .str("stopped")]]
        let s = ChatContext.stopSummary(steps: steps, plan: "1. x", notebook: book)
        XCTAssertTrue(s.hasPrefix("Stopped after 1 step (stopped). Last action: {\"action\": \"swipe\""))
        XCTAssertTrue(s.contains("Progress: folder 1 of 3. 2 items collected."))
    }

    func testThreadsAreSavedAndTheLatestReopens() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ThreadStore(folder: folder)
        store.append(ChatTurn(ask: "a", run: "r", outcome: "done", answer: "ok"))
        XCTAssertEqual(ThreadStore(folder: folder).current.turns.map(\.ask), ["a"])
        store.newChat()
        XCTAssertTrue(store.current.turns.isEmpty)
    }

    func testTheChatGoesIntoBothPrompts() async {
        let model = FakeModel { n in n == 1 ? "1. go" : "THINK: ok\nDO: done ok" }
        let agent = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: model, planner: model, trace: nil)
        agent.chatContext = "User: earlier\nResult (done): fine"
        XCTAssertTrue(agent.actorPrompt.hasSuffix("progress of this run):\nUser: earlier\nResult (done): fine"))
    }
}
