import XCTest
@testable import IPhoneAgent

final class TapTextTests: XCTestCase {
    private let size = CGSize(width: 1000, height: 2000)

    func testParsesQuotedWords() throws {
        let a = try Actions.parseCommand("tap \"删除\"")
        XCTAssertEqual(a["text"], .str("删除"))
        XCTAssertNil(a["x"])
        XCTAssertEqual(try Actions.parseCommand("tap “下一步” precise")["precise"], .bool(true))
        XCTAssertEqual(try Actions.parseCommand("tap 10 20")["x"], .int(10))
    }

    func testOneExactLineWinsOverLongerOnes() {
        let lines: [(text: String, box: [Int])] = [("删除订单记录说明", [0, 100, 800, 140]), ("删除", [800, 400, 900, 440])]
        XCTAssertEqual(TapText.find("删除", in: lines, size: size), .at(x: 850, y: 210))
    }

    func testWordsInsideALineAreTappedWhereTheyStand() {
        let lines: [(text: String, box: [Int])] = [("全部订单 删除", [0, 100, 600, 140])]
        guard case .at(let x, _) = TapText.find("删除", in: lines, size: size) else { return XCTFail() }
        XCTAssertGreaterThan(x, 400)
    }

    func testAStoreNameIsFoundWhateverItsBrackets() {
        let card: [(text: String, box: [Int])] = [("示例餐厅（中心店）", [100, 500, 700, 540])]
        guard case .at = TapText.find("示例餐厅(中心店)", in: card, size: size) else { return XCTFail("full-width brackets") }
        let cut: [(text: String, box: [Int])] = [("示例餐厅", [100, 500, 500, 540])]
        guard case .at = TapText.find("示例餐厅(中心店)", in: cut, size: size) else { return XCTFail("the name alone") }
    }

    func testTheLogSaysWhatAStepDid() {
        let line = AgentLoop.logLine(["action": .str("tap"), "text": .str("删除"), "x": .int(850), "y": .int(210),
                                      "thought": .str("long"), "result": .str("not sent: x")])
        XCTAssertEqual(line, "tap text=\"删除\" x=850 y=210 -> not sent: x")
    }

    func testSeveralOrNoneAreNotTapped() {
        let lines: [(text: String, box: [Int])] = [("删除", [800, 400, 900, 440]), ("删除", [800, 800, 900, 840])]
        XCTAssertEqual(TapText.find("删除", in: lines, size: size), .several(["850 210", "850 410"]))
        XCTAssertEqual(TapText.find("确认", in: lines, size: size), .none)
        XCTAssertNotNil(TapText.result("确认", .none))
    }

    func testTabLabelAimsAtItsIcon() {
        let size = CGSize(width: 1000, height: 2000)
        let found = TapText.find("订单", in: [("订单", [580, 1915, 660, 1945])], size: size)
        guard case .at(_, let y) = found else { return XCTFail("\(found)") }
        XCTAssertLessThan(y, 950, "above the label, on the icon")
        XCTAssertGreaterThanOrEqual(y, 880)
        let mid = TapText.find("订单", in: [("订单", [580, 1000, 660, 1030])], size: size)
        XCTAssertEqual(mid, .at(x: 620, y: 507), "mid screen: on the words")
    }
}

final class ProgressCountTests: XCTestCase {
    func testCountsAreReadFromTheProgressLine() {
        XCTAssertEqual(Notebook.count("3/12 orders checked")?.done, 3)
        XCTAssertEqual(Notebook.count("3/12 orders checked")?.total, 12)
        XCTAssertEqual(Notebook.count("folder 2 of 5")?.total, 5)
        XCTAssertNil(Notebook.count("3/? orders")?.total)
        XCTAssertNil(Notebook.count("end of list reached"))
    }

    func testAReachedCountTellsTheModelToFinish() {
        var book = Notebook()
        book.setProgress("11/12 orders")
        XCTAssertFalse(book.summary().contains("count is reached"))
        book.setProgress("12/12 orders")
        XCTAssertTrue(book.reached)
        XCTAssertTrue(book.summary().contains("The progress count is reached"))
    }

    func testTheIslandRingNeedsATotal() {
        var s = AgentActivityAttributes.ContentState(mood: .thinking, step: 4, limit: 50, line: "")
        XCTAssertNil(s.countShare)
        (s.done, s.total) = (3, 12)
        XCTAssertEqual(s.countShare, 0.25)
    }
}
