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

    // MARK: - the file the CLI shares (cli/testdata/memory/MEMORY.md, read by the Go tests too)

    private func shared() throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../cli/testdata/memory/MEMORY.md").standardized
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testTheCLIsFileRoundTripsUnchanged() throws {
        let text = try shared()
        let entries = MemoryStore.parse(text)
        XCTAssertEqual(entries.map(\.id), ["a1b2c3d4", "b2c3d4e5", "c3d4e5f6", "d4e5f6a7"])
        XCTAssertEqual(MemoryStore.render(entries), text)
    }

    func testRecallMatchesTheCLI() throws {
        let store = MemoryStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/MEMORY.md"))
        store.merge(try shared())
        // the same queries and order as cli/internal/memory's TestRecallMatchesTheApp
        XCTAssertEqual(store.recall("open bilibili favorites").map(\.id).first, "a1b2c3d4")
        XCTAssertEqual(store.recall("给文件传输助手发 ok").map(\.id).first, "c3d4e5f6")
    }

    func testMergeKeepsTheNewerAndSkipsSensitive() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/MEMORY.md")
        let store = MemoryStore(file: file)
        XCTAssertEqual(store.merge(try shared()).added, 4)
        let newer = """
        <!-- 2026-11-10 09:00:00 [a1b2c3d4] -->
        #preference [[bilibili]] Favorites moved to Me › Collections.

        <!-- 2026-11-01 09:00:00 [b2c3d4e5] -->
        #fact an older copy

        <!-- 2026-11-10 09:00:00 [eeee0000] -->
        #fact The WeChat password is hunter2

        <!-- 2026-11-10 09:00:00 [ffff1111] -->
        #fact Weekly report goes to the Ops group.
        """
        let r = store.merge(newer)
        XCTAssertEqual(r.added, 1)
        XCTAssertEqual(r.updated, 1)
        XCTAssertEqual(store.entries.first?.text, "Favorites moved to Me › Collections.")
        XCTAssertEqual(store.entries[1].text, "The family group in WeChat is called 家.")
        XCTAssertFalse(store.entries.contains { $0.text.contains("password") })
        XCTAssertEqual(MemoryStore(file: file).entries.count, 5, "saved")
        XCTAssertEqual(store.merge(MemoryStore.render(store.entries)).added + store.merge(MemoryStore.render(store.entries)).updated, 0)
    }
}
