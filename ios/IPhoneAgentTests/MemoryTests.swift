import XCTest
@testable import IPhoneAgent

/// The notebook (what one run collects) and long-term memory (MEMORY.md).
@MainActor final class MemoryTests: XCTestCase {
    func testNotebookSkipsTheOverlapBetweenTwoReadsOfAScrolledList() {
        var book = Notebook()
        XCTAssertEqual(book.add(["A", "B", "C"]), 3)
        XCTAssertEqual(book.add(["B", "c ", "D", "E"]), 2)  // scrolled by one row; case and spaces don't matter
        XCTAssertEqual(book.add(["A", "F"]), 1)  // a line seen before is not kept twice
        XCTAssertEqual(book.items, ["A", "B", "C", "D", "E", "F"])
    }

    func testReaderRepliesBecomeItems() {
        XCTAssertEqual(Notebook.lines("- 视频一\n2. 视频二\n\n• Video 3\nNONE"), ["视频一", "视频二", "Video 3"])
        XCTAssertEqual(Notebook.lines("NONE"), [])
    }

    func testSummaryShowsCountsProgressAndTheLastItems() {
        var book = Notebook()
        book.add((1...12).map { "t\($0)" })
        book.setProgress("folder 1 of 3")
        let s = book.summary(lastItems: 2)
        XCTAssertTrue(s.hasPrefix("Notebook (12 items collected; progress: folder 1 of 3):"))
        XCTAssertTrue(s.hasSuffix("  …\n  11. t11\n  12. t12"))
    }

    func testMemoryRoundTripsThePiMemoryFormat() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/MEMORY.md")
        let store = MemoryStore(file: file)
        store.add("Favorites are under Me › Favorites", kind: .app, topic: "Bilibili")
        store.add("I like short answers", kind: .preference)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("#app [[bilibili]] Favorites are under Me › Favorites"))
        XCTAssertTrue(text.contains("#preference I like short answers"))
        let again = MemoryStore(file: file)
        XCTAssertEqual(again.entries.map(\.text), store.entries.map(\.text))
        XCTAssertEqual(again.entries.first?.topic, "bilibili")
        XCTAssertEqual(again.entries.first?.kind, .app)
    }

    func testMemoryKeepsNoSecretsOrDuplicates() {
        let store = MemoryStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/m.md"))
        XCTAssertNil(store.add("my password is hunter2", kind: .fact))
        XCTAssertNil(store.add("验证码 482913", kind: .fact))
        XCTAssertNil(store.add("card 4111 1111 1111 1111", kind: .fact))
        XCTAssertNotNil(store.add("Call me Henry", kind: .preference))
        XCTAssertNil(store.add("call me henry", kind: .preference))
        XCTAssertEqual(store.entries.count, 1)
    }

    func testRecallFindsTheEntriesLikeTheTask() {
        let store = MemoryStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/m.md"))
        store.add("B站收藏夹在 我的 › 收藏", kind: .app, topic: "bilibili")
        store.add("Alarms: type the time instead of scrolling", kind: .app, topic: "clock")
        XCTAssertEqual(store.recall("把B站收藏夹的标题写到备忘录").first?.topic, "bilibili")
        XCTAssertEqual(store.recall("set an alarm at 7").first?.topic, "clock")
    }

    func testRememberOnlyKeepsTheUsersOwnWords() {
        XCTAssertTrue(AgentLoop.saidByUser("I prefer Bilibili favorites in Notes", in: "Remember: I prefer Bilibili favorites in Notes"))
        XCTAssertFalse(AgentLoop.saidByUser("The user's card ends in 1234", in: "Open Settings"))
    }

    /// The favorites task: read a screen, scroll, read the next (overlapping) screen, finish. The notebook keeps
    /// the four titles, the actor sees it, and done carries the full list.
    func testReadingSeveralScreensFillsTheNotebook() async {
        let model = FakeModel { n in
            switch n {
            case 1: return "1. Read every title"
            case 2: return "THINK: first screen\nDO: read video titles\nDO: swipe 500 800 500 400"
            case 3: return "A\nB\nC"
            case 4: return "THINK: next screen\nDO: read video titles"
            case 5: return "C\nD"
            default: return "THINK: end of list\nDO: done 4 titles"
            }
        }
        let phone = FakeGestures()
        let agent = AgentLoop(phone: phone, screen: FakeScreen(), actor: model, planner: model, trace: nil)
        await agent.run()
        XCTAssertEqual(phone.calls, ["swipe"])
        XCTAssertEqual(agent.notebook.items, ["A", "B", "C", "D"])
        XCTAssertTrue(model.prompts[3].contains("Notebook (3 items collected):"))
        XCTAssertEqual(agent.steps.last?["notebook"], .arr(["A", "B", "C", "D"].map { .str($0) }))
    }

    func testReadAfterAGestureWaitsForTheNextLook() throws {
        let acts = try Actions.parseActions("THINK: x\nDO: swipe 1 2 3 4\nDO: read titles")
        XCTAssertEqual(acts.map { $0["action"]?.str }, ["swipe"])
    }

    func testLessonsAreKeptOnlyWhenTheRunEndsWithDone() async {
        let store = MemoryStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/m.md"))
        let model = FakeModel { n in n == 1 ? "1. go" : n == 2 ? "THINK: x\nDO: learn Clock: type the time" : "THINK: y\nDO: done ok" }
        let agent = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: model, planner: model, trace: nil)
        agent.memory = store
        await agent.run()
        XCTAssertEqual(store.entries.map(\.text), ["Clock: type the time"])
        XCTAssertEqual(store.entries.first?.topic, "clock")
    }
}
