import XCTest
@testable import IPhoneAgent

final class LiveNotesTests: XCTestCase {
    private var root: URL!
    private var files: MemoryFiles { MemoryFiles(box: FileSandbox(root: root), since: Date(timeIntervalSince1970: 0)) }
    private let since = Date(timeIntervalSince1970: 1_794_915_063)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("livenotes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func read(_ path: String) -> String { (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? "" }

    func testEachNoteIsOnDiskAtOnceAndAStopSaysSo() {
        var notes = LiveNotes()
        notes.add("Order 1: ¥12.50", task: "打开美团外卖，收集订单", name: "美团外卖订单 · 按地区", since: since, files: files)
        let folder = notes.folder!
        XCTAssertTrue(folder.hasPrefix("美团外卖订单-按地区-"), folder)
        XCTAssertTrue(read(folder + "/notes.md").contains("- Order 1: ¥12.50\n"))
        notes.add("Order 2: ¥30.00", task: "x", name: nil, since: since, files: files)
        notes.finish(done: false, task: "打开美团外卖，收集订单", files: files)
        let text = read(folder + "/notes.md")
        XCTAssertTrue(text.contains("- Order 2: ¥30.00\n"))
        XCTAssertTrue(text.contains("停止，上面的记录可能不完整"))
        XCTAssertFalse(text.contains("step"), "for the user: no step numbers")
    }

    func testAResumedRunGoesOnWithTheNotesAlreadyThere() {
        var first = LiveNotes()
        first.add("Order 1: ¥12.50", task: "收集订单", name: "订单", since: since, files: files, shot: Data([1]))
        first.add("Order 2: ¥30.00", task: "收集订单", name: nil, since: since, files: files)
        first.finish(done: false, task: "收集订单", files: files)
        let folder = first.folder!
        var resumed = LiveNotes()  // a new app: nothing in memory
        resumed.use(folder, files: files)
        resumed.add("Order 3: ¥8.00", task: "收集订单", name: nil, since: since.addingTimeInterval(3600), files: files, shot: Data([2]))
        let text = read(folder + "/notes.md")
        for order in ["- Order 1: ¥12.50\n  ![](note-01.jpg)\n", "- Order 2: ¥30.00\n", "- Order 3: ¥8.00\n  ![](note-02.jpg)\n"] {
            XCTAssertTrue(text.contains(order), order)
        }
        XCTAssertEqual(text.components(separatedBy: "开始记录").count, 2, "one top")
        XCTAssertFalse(text.contains("停止"), "the old closing line goes")
    }

    @MainActor func testAResumedNotebookHasTheNotesMadeAfterTheLastCheckpoint() throws {
        var book = Notebook()
        book.note("Order 1: ¥12.50")
        let saved = String(decoding: try JSONEncoder().encode(book), as: UTF8.self)
        let steps: [JObject] = [["action": .str("note"), "text": .str("Order 1: ¥12.50")],
                                ["action": .str(AgentLoop.checkpointAction), "notebook": .str(saved)],
                                ["action": .str("note"), "text": .str("Order 2: ¥30.00")],
                                ["action": .str("note"), "text": .str("Order 2: ¥30.00")]]
        XCTAssertEqual(AgentLoop.savedNotebook(steps).notes, ["Order 1: ¥12.50", "Order 2: ¥30.00"])
    }

    func testANoteKeepsTheScreenItWasReadOff() {
        var notes = LiveNotes()
        let shot = Data([0xFF, 0xD8, 0x01]), other = Data([0xFF, 0xD8, 0x02])
        notes.add("Order 1 ¥12", task: "orders", name: nil, since: since, files: files, shot: shot)
        notes.add("Order 1 address Road 5", task: "orders", name: nil, since: since, files: files, shot: shot)
        notes.add("Order 2", task: "orders", name: nil, since: since, files: files, shot: other)
        let folder = notes.folder!
        let text = read(folder + "/notes.md")
        XCTAssertEqual(text.components(separatedBy: "![](note-01.jpg)").count - 1, 2, "one image for two notes off one screen")
        XCTAssertTrue(text.contains("![](note-03.jpg)"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(folder + "/note-03.jpg").path))
    }

    func testANoteThatCompletesAnEarlierOneTakesItsPlace() {
        var notes = LiveNotes()
        notes.add("Shop A · ¥20.8 · Road 12 · date: to find", task: "orders", name: nil, since: since, files: files)
        notes.add("Shop A · ¥20.8 · 2026-11-17 20:14 · Road 12", task: "orders", name: nil, since: since, files: files)
        notes.add("Shop A · ¥20.8 · 2026-11-10 12:00 · Road 12", task: "orders", name: nil, since: since, files: files)
        let text = read(notes.folder! + "/notes.md")
        XCTAssertFalse(text.contains("to find"))
        XCTAssertEqual(text.components(separatedBy: "\n- ").count - 1, 2, "the completed note in place; another day stays its own")
        XCTAssertTrue(Notebook.completes("Shop A · ¥20.8 · 20:14", "Shop A · ¥20.8"))
        XCTAssertFalse(Notebook.completes("Shop A · ¥30 · 20:14", "Shop A · ¥20.8"), "another amount")
        XCTAssertFalse(Notebook.completes("Shop A", "Shop A · ¥20.8"), "shorter")
        var book = Notebook()
        book.note("Shop A · ¥20.8")
        book.note("Shop A · ¥20.8 · 20:14")
        XCTAssertEqual(book.notes, ["Shop A · ¥20.8 · 20:14"])
    }

    func testAtTheEndANoteShotTheRunAlsoSnappedIsSharedNotKeptTwice() throws {
        var notes = LiveNotes()
        let shot = Data([0xFF, 0xD8, 0x07])
        notes.add("Shop A · ¥20.8", task: "orders", name: nil, since: since, files: files, shot: shot)
        let dir = root.appendingPathComponent(notes.folder!)
        try shot.write(to: dir.appendingPathComponent("order1.jpg"))
        notes.finish(done: true, task: "orders", files: files)
        let text = read(notes.folder! + "/notes.md")
        XCTAssertTrue(text.contains("![](order1.jpg)"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("note-01.jpg").path))
    }

    func testADoneRunWithItsOwnResultDropsTheNotesAndAStoppedOneKeepsThem() throws {
        var notes = LiveNotes()
        notes.add("Shop A · ¥20.8", task: "orders", name: nil, since: since, files: files, shot: Data([0xFF, 0xD8, 0x01]))
        notes.add("Shop B · ¥9", task: "orders", name: nil, since: since, files: files, shot: Data([0xFF, 0xD8, 0x02]))
        let dir = root.appendingPathComponent(notes.folder!)
        try "# Orders\n![](note-02.jpg)\n".write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        notes.finish(done: false, task: "orders", files: files)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("notes.md").path), "stopped: kept")
        notes.finish(done: true, task: "orders", files: files)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("notes.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("note-01.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("note-02.jpg").path), "the README shows it")
    }

    func testWithoutAnIntentTheTaskFirstPartNamesTheFolder() {
        var notes = LiveNotes()
        notes.add("a", task: "打开美团外卖，收集订单", name: nil, since: since, files: files)
        XCTAssertTrue(notes.folder!.hasPrefix("打开美团外卖-"), notes.folder!)
    }

    func testAnEarlierFolderOfTheSameNameIsNotReused() throws {
        let first = LiveNotes.newFolder("orders", since: since, files: files)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(first), withIntermediateDirectories: true)
        XCTAssertEqual(LiveNotes.newFolder("orders", since: since, files: files), first + "-2")
    }

    func testNotesMoveToTheFolderTheResultIsWrittenIn() throws {
        var notes = LiveNotes()
        notes.add("Order 1", task: "orders", name: nil, since: since, files: files)
        let draft = notes.folder!
        try FileManager.default.createDirectory(at: root.appendingPathComponent("orders-final"), withIntermediateDirectories: true)
        notes.wrote("orders-final/README.md", files: files)
        XCTAssertEqual(notes.folder, "orders-final")
        XCTAssertTrue(read("orders-final/notes.md").contains("- Order 1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(draft).path))
        notes.add("Order 2", task: "orders", name: nil, since: since, files: files)
        XCTAssertTrue(read("orders-final/notes.md").contains("- Order 2"))
    }

    func testAfterAFileTheFirstNoteGoesInThatFolder() {
        var notes = LiveNotes()
        notes.wrote("trip/page-01.jpg", files: files)
        notes.add("a", task: "x", name: nil, since: since, files: files)
        XCTAssertEqual(notes.folder, "trip")
    }

    func testNoteAmountsMustBeOnTheScreen() {
        XCTAssertEqual(NoteCheck.amounts("Shop A · ¥30 · 19.50 · 11-17"), ["19.50", "30"])
        let screen = ["Shop A", "实付 ¥ 40.50", "2026-11-17 13:51"]
        XCTAssertEqual(NoteCheck.missing("Shop A · ¥40.50 · 11-17", screen: screen), [])
        XCTAssertEqual(NoteCheck.missing("Shop B · ¥19.5 · 11-17", screen: screen), ["19.5"])
        XCTAssertEqual(NoteCheck.missing("Shop A · 1,040.50", screen: ["合计 1,040.50"]), [])
        XCTAssertEqual(NoteCheck.missing("three orders checked", screen: []), [])
        XCTAssertTrue(NoteCheck.warning(["19.5"]).contains("19.5"))
    }

    func testANoteDayMustBeOnThePageAndInsideTheGoalDates() {
        let days = NoteCheck.days("机票 · 2026年11月15日 · ¥798 · 10-15 至 10-16 · 20:14 · 订单 1000000000000001")
        XCTAssertEqual(days.map { "\($0.month)-\($0.day)" }, ["11-15", "10-15", "10-16"], "no times, amounts or order numbers")
        XCTAssertEqual(NoteCheck.days("2026-11-17 20:14:46").map(\.day), [17])
        XCTAssertEqual(NoteCheck.unseenDays(NoteCheck.days("接送机 · 11月09日 · ¥67"), screen: ["在线付 ¥67", "已完成"]).map(\.text),
                       ["11月09日"], "a day the page does not show")
        XCTAssertTrue(NoteCheck.unseenDays(NoteCheck.days("11月15日 上海→北京"), screen: ["11-15 08:00 至 10:15"]).isEmpty,
                      "the same day written another way")
        let goal = "打开携程，收集 2026年11月9日到今天的所有订单"
        let today = DateComponents(calendar: .current, year: 2026, month: 11, day: 18).date!
        XCTAssertNotNil(NoteCheck.outside("维也纳酒店 · 10-15 至 10-16 · ¥305", goal: goal, today: today))
        XCTAssertNil(NoteCheck.outside("机票 · 11-15 · ¥798", goal: goal, today: today))
        XCTAssertNil(NoteCheck.outside("酒店 · 11-08 至 11-10", goal: goal, today: today), "one day inside is enough")
        XCTAssertNil(NoteCheck.outside("酒店 · 10-15", goal: "收集最近3单", today: today), "no range in the goal")
        XCTAssertNotNil(NoteCheck.outside("11月20日", goal: "11月9日到11月15日的订单", today: today))
    }

    func testANoteNameMustBeOnTheScreenToo() {
        let note = "Rice House (North St) · ¥19.5 · 2026-11-17 00:18 · Block 12"
        XCTAssertEqual(NoteCheck.names(note), ["Rice House (North St)"], "parts with digits are amounts, times, addresses")
        let page = ["Lamb Grill (North St)", "实付 ¥19.5", "2026-11-17 00:18"]
        XCTAssertEqual(NoteCheck.unseenNames(NoteCheck.names(note), screen: page), ["Rice House (North St)"], "another shop's name")
        XCTAssertEqual(NoteCheck.unseenNames(["示例菜馆(北店)"], screen: ["示例菜馆（北店）", "¥20.8"]), [])
        XCTAssertEqual(NoteCheck.unseenNames(["Rice House"], screen: ["Rlce House"]), [], "one OCR slip still counts as seen")
        XCTAssertEqual(NoteCheck.names("Order1 · 已送达"), [], "short words and labels are not names")
    }

    func testRunFolderTakesEveryWriteOfTheRun() {
        let run = "orders-20261118-2", goal = "list my last 3 orders"
        XCTAssertEqual(RunFolder.place("orders/order1.jpg", in: run, goal: goal), "orders-20261118-2/order1.jpg")
        XCTAssertEqual(RunFolder.place("results/orders-20261118/a.jpg", in: run, goal: goal), "orders-20261118-2/a.jpg")
        XCTAssertEqual(RunFolder.place("page-01.jpg", in: run, goal: goal), "orders-20261118-2/page-01.jpg")
        XCTAssertEqual(RunFolder.place("orders-20261118-2/README.md", in: run, goal: goal), "orders-20261118-2/README.md")
        XCTAssertEqual(RunFolder.place("trip/README.md", in: run, goal: "add to the folder trip", earlier: ["trip"]), "trip/README.md")
        XCTAssertEqual(RunFolder.place("trip/README.md", in: run, goal: "add to the folder trip"), "orders-20261118-2/README.md")
        XCTAssertEqual(RunFolder.snap("orders/a.jpg 0 0 500 500", in: run, goal: goal), "orders-20261118-2/a.jpg 0 0 500 500")
        let line = RunFolder.file("{\"command\":\"create\",\"path\":\"orders/README.md\",\"file_text\":\"A\"}", in: run, goal: goal)
        XCTAssertTrue(line.contains("\"path\":\"orders-20261118-2/README.md\""), line)
        let view = #"{"command":"view","path":""}"#
        XCTAssertEqual(RunFolder.file(view, in: run, goal: goal), view)
    }

    func testScrollMeterTellsHowFarThePageWent() {
        func line(_ t: String, _ y: Int) -> (text: String, box: [Int]) { (t, [0, y - 10, 100, y + 10]) }
        let bar = line("Orders", 100), tab = line("Home", 1900)
        let before = [bar, line("Card A", 800), line("Card B", 1200), line("Card C", 1600), tab]
        let after = [bar, line("Card B", 400), line("Card C", 800), line("Card D", 1200), tab]
        XCTAssertEqual(ScrollMeter.moved(before, after, height: 2000) ?? 0, 400, accuracy: 0.1)  // 800 px of 2000
        XCTAssertNil(ScrollMeter.moved(before, [bar, line("Card X", 900), tab], height: 2000))
        let swipe: JObject = ["x1": .int(500), "y1": .int(700), "x2": .int(500), "y2": .int(400)]
        XCTAssertEqual(ScrollMeter.swiped(swipe), 300)
        XCTAssertNil(ScrollMeter.result(swiped: 300, moved: 350))
        XCTAssertNotNil(ScrollMeter.result(swiped: 300, moved: 480))
        XCTAssertNotNil(ScrollMeter.result(swiped: 300, moved: nil))
        XCTAssertEqual(ScrollMeter.gain(1, swiped: 300, moved: 300), 1, accuracy: 0.01)
        XCTAssertGreaterThan(ScrollMeter.gain(1, swiped: 300, moved: 600), 1.3)
    }

    func testAViewRepeatedWithoutAWriteIsKnownAndDoneSkipsTheCheckWhenTheCountIsReached() {
        XCTAssertEqual(FileViews.viewed(#"{"command":"view","path":"Orders/README.md"}"#), "Orders/README.md")
        XCTAssertEqual(FileViews.viewed(#"{"command":"view","path":"Orders/"}"#), "Orders")
        XCTAssertNil(FileViews.viewed(#"{"command":"create","path":"Orders/README.md","file_text":"x"}"#))
        XCTAssertTrue(AgentLoop.doneIsShown((3, 3), wrote: true))
        XCTAssertFalse(AgentLoop.doneIsShown((3, 3), wrote: false), "no result file yet")
        XCTAssertFalse(AgentLoop.doneIsShown((2, 3), wrote: true))
        XCTAssertFalse(AgentLoop.doneIsShown((3, nil), wrote: true), "total unknown")
        XCTAssertFalse(AgentLoop.doneIsShown(nil, wrote: true))
    }
}
