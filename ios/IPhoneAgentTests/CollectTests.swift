import XCTest
@testable import IPhoneAgent

@MainActor final class CollectTests: XCTestCase {
    func testWhenToStop() {
        XCTAssertNil(Collect.end(page: 1, dryRun: 0, moved: true))
        XCTAssertNil(Collect.end(page: 3, dryRun: 1, moved: true), "one dry screen is not the end")
        XCTAssertEqual(Collect.end(page: 3, dryRun: 2, moved: true), .dry)
        XCTAssertEqual(Collect.end(page: 2, dryRun: 0, moved: false), .still)
        XCTAssertEqual(Collect.end(page: Collect.pages, dryRun: 0, moved: true), .limit)
    }

    func testCollectReadsScrollsAndStopsAtAListThatNoLongerMoves() async throws {
        let screen = FakeScreen(), phone = FakeGestures()
        screen.frame = AgentTests.jpeg()  // never changes: the first scroll finds the end
        let model = FakeModel { $0 == 1 ? "THINK: page through\nDO: collect order rows" : "Order A ¥12\nOrder B ¥30" }
        let agent = AgentLoop(phone: phone, screen: screen, actor: model, planner: nil, trace: nil)
        _ = try await agent.step()
        XCTAssertEqual(agent.notebook.items, ["Order A ¥12", "Order B ¥30"])
        XCTAssertEqual(phone.calls.filter { $0 == "swipe" }.count, 1)
        let row = agent.steps.last { $0["action"]?.str == "collect" }
        XCTAssertTrue(row?["reason"]?.str?.contains("stopped: the list stopped moving") == true)
    }

    func testCollectEndsTheBatch() throws {
        let acts = try Actions.parseActions("THINK: x\nDO: collect titles\nDO: swipe 500 700 500 300")
        XCTAssertEqual(acts.count, 1)
        XCTAssertEqual(acts[0]["what"], .str("titles"))
    }
}

final class WaitForTests: XCTestCase {
    func testWaitAndFindLinesParse() throws {
        let w = try Actions.parseCommand("wait \"支付成功\" 12")
        XCTAssertEqual(w["text"], .str("支付成功"))
        XCTAssertEqual(w["seconds"]?.double, 12)
        XCTAssertNil(w["gone"])
        let g = try Actions.parseCommand("wait gone “加载中”")
        XCTAssertEqual(g["gone"], .bool(true))
        XCTAssertEqual(g["seconds"]?.double, WaitFor.seconds)
        XCTAssertNil(try Actions.parseCommand("wait")["text"], "plain wait settles as before")
        XCTAssertEqual(try Actions.parseCommand("wait \"x\" 99")["seconds"]?.double, WaitFor.most)
        XCTAssertEqual(try Actions.parseCommand("find \"满减\"")["text"], .str("满减"))
    }

    func testWordsShowAnywhereInALine() {
        XCTAssertTrue(WaitFor.shows("支付成功", in: ["订单 支付成功 ✓"]))
        XCTAssertTrue(WaitFor.shows("Paid", in: ["Order PAID"]))
        XCTAssertFalse(WaitFor.shows("支付成功", in: ["待支付"]))
    }

    func testFindEndsTheBatch() throws {
        XCTAssertEqual(try Actions.parseActions("THINK: x\nDO: find \"满减\"\nDO: tap \"满减\"").count, 1)
    }
}

@MainActor final class EachTests: XCTestCase {
    private let size = CGSize(width: 1000, height: 2000)

    private func line(_ text: String, y: Int, x: Int = 100, w: Int = 300) -> (text: String, box: [Int]) {
        (text, [x, y, x + w, y + 40])
    }

    func testParse() {
        XCTAssertEqual(Each.parse(#""已完成" read "店名, 金额" max 3"#), Each.Order(anchor: "已完成", what: "店名, 金额", max: 3))
        XCTAssertEqual(Each.parse(#""已完成" read "店名""#)?.max, Each.defaultItems)
        XCTAssertEqual(Each.parse(#""已完成" read "店名" max 9999"#)?.max, Each.maxItems)
        XCTAssertNil(Each.parse(#""已完成""#), "no WHAT")
        // with RECORD the reader reads its fields: WHAT may be left out
        let rec = Each.parse(#""已完成" open "查看更多" max 20"#, record: ["店铺名称", "实付金额"])
        XCTAssertEqual(rec, Each.Order(anchor: "已完成", what: "店铺名称, 实付金额", max: 20, open: "查看更多"))
        XCTAssertEqual(Each.parse(#""已完成" read "店名""#, record: ["店铺名称", "实付金额"])?.what, "店名", "a WHAT given wins")
    }

    func testParsedAsOneAction() throws {
        let act = try Actions.parseCommand(#"each "已完成" read "店名, 金额" max 3"#)
        XCTAssertEqual(act["action"]?.str, "each")
        XCTAssertEqual(Each.parse(act["text"]?.str ?? "")?.anchor, "已完成")
    }

    func testCardsTopToBottomInsideTheContentBand() {
        let lines = [
            line("示例餐厅A", y: 400), line("已完成", y: 400, x: 700, w: 120), line("11-17 12:30", y: 460),
            line("示例餐厅B", y: 900), line("已完成", y: 900, x: 700, w: 120), line("11-16 18:05", y: 960),
            line("已完成", y: 1950, x: 700, w: 120),  // cut off at the bottom edge
            line("已完成", y: 100, x: 700, w: 120),   // under the top bar
        ]
        let cards = Each.cards("已完成", in: lines, size: size)
        XCTAssertEqual(cards.count, 2)
        XCTAssertLessThan(cards[0].y, cards[1].y)
        XCTAssertTrue(cards[0].key.contains("示例餐厅a"))
        XCTAssertNotEqual(cards[0].key, cards[1].key)
    }

    func testOpenStepAndPriceAnchorParse() {
        let o = Each.parse(#""¥*" open "查看更多" read "店名, 下单时间" max 5"#)
        XCTAssertEqual(o, Each.Order(anchor: "¥*", what: "店名, 下单时间", max: 5, open: "查看更多"))
        XCTAssertNil(Each.parse(#""已完成" read "店名""#)?.open)
    }

    func testPriceAnchorTapsEachCardsOwnPrice() {
        let lines = [
            line("示例餐厅A", y: 400), line("已完成", y: 400, x: 700, w: 120),
            line("¥75.4", y: 520, x: 700, w: 120), line("共1件", y: 560, x: 700, w: 120), line("再来一单", y: 640),
            line("示例餐厅B", y: 900), line("已完成", y: 900, x: 700, w: 120),
            line("¥15.50", y: 1020, x: 700, w: 120), line("共1件", y: 1060, x: 700, w: 120), line("再来一单", y: 1140),
            line("¥", y: 1300, x: 700, w: 40),  // the sign alone is no price
        ]
        let cards = Each.cards("¥*", in: lines, size: size)
        XCTAssertEqual(cards.count, 2)
        XCTAssertEqual(cards.map(\.y), cards.map(\.y).sorted())
        XCTAssertGreaterThan(cards[0].y, 1000 * 400 / Int(size.height), "below the title row, on the price")
        XCTAssertNotEqual(cards[0].key, cards[1].key, "the same buttons below, told apart by the price")
        XCTAssertTrue(Each.matches("¥75.4", "¥*"))
        XCTAssertFalse(Each.matches("已完成", "¥*"))
    }

    func testNextSkipsDoneCards() {
        let a = Each.Card(x: 1, y: 1, key: "a"), b = Each.Card(x: 2, y: 2, key: "b")
        XCTAssertEqual(Each.next([a, b], done: ["a"]), b)
        XCTAssertNil(Each.next([a, b], done: ["a", "b"]))
    }

    func testPayingAnchorIsRefused() {
        XCTAssertNotNil(PayGuard.kind("删除"))
        XCTAssertNil(PayGuard.kind("已完成"))
    }
}

@MainActor final class RecordTests: XCTestCase {
    func testFieldsFromThePlansFirstLine() {
        let plan = "RECORD: 店铺名称, 实付金额，下单时间、收货地址\n1. 打开订单\n2. 逐个打开"
        XCTAssertEqual(Record.fields(plans: [plan]), ["店铺名称", "实付金额", "下单时间", "收货地址"])
        XCTAssertEqual(Record.fields(plans: [plan, "1. 继续"]), ["店铺名称", "实付金额", "下单时间", "收货地址"],
                       "a later plan without the line keeps the fields")
        XCTAssertEqual(Record.fields(plans: ["1. 打开设置"]), [])
    }

    func testReplyBecomesOneLineInTheFieldsOrder() {
        let fields = ["店铺名称", "实付金额", "下单时间", "收货地址"]
        let reply = "下单时间: 2026-11-14 10:15:00\n店铺名称: 示例餐厅(中心店)\n实付金额：¥30.5"
        XCTAssertEqual(Record.line(reply, fields: fields), "示例餐厅(中心店) · ¥30.5 · 2026-11-14 10:15:00")
        XCTAssertNil(Record.line("NONE", fields: fields))
        XCTAssertNil(Record.line("店铺名称: 示例餐厅", fields: fields), "one value is not a record")
    }

    func testALaterScreenCompletesTheSameItem() {
        var book = Notebook()
        book.note("示例餐厅(中心店) · ¥30.5 · 上海 示例区 示例路1号")
        book.note("示例餐厅(中心店) · ¥30.5 · 2026-11-14 10:15:00 · 上海 示例区 示例路1号")
        XCTAssertEqual(book.notes.count, 1)
        XCTAssertTrue(book.notes[0].contains("10:15:00"))
        book.note("示例超市 · ¥22.7 · 2026-11-13 20:55:10 · 上海 示例区 示例路1号")
        XCTAssertEqual(book.notes.count, 2, "another item is its own record")
    }
}


@MainActor final class SpeedFixTests: XCTestCase {
    func testRecordLineNeedsTheFirstField() {
        let fields = ["店铺名称", "实付金额", "下单时间"]
        XCTAssertNil(Record.line("实付金额: ¥31.2\n下单时间: 2026-11-13 20:46:17", fields: fields))
        XCTAssertEqual(Record.line("店铺名称: 示例面馆\n实付金额: ¥28.5", fields: fields), "示例面馆 · ¥28.5")
    }

    func testNotesMatchAcrossFullAndHalfWidth() {
        var book = Notebook()
        book.note("示例超市（东店） · ¥15.50 · 2026-11-12 23:10:00")
        XCTAssertTrue(book.noted("示例超市(东店) · ¥15.50 · 2026-11-12 23:10:00"))
        book.note("示例超市(东店) · ¥15.50 · 2026-11-12 23:10:00")
        XCTAssertEqual(book.notes.count, 1)
    }

    /// RECORD keeps notes, not items: the count is the notes', and earlier notes stay in view by name.
    func testRecordNotebookShowsEveryNotedName() {
        var book = Notebook()
        for i in 1...8 { book.note("示例店\(i) · ¥\(i).5 · 2026-11-1\(i) 12:00") }
        let s = book.summary()
        XCTAssertTrue(s.hasPrefix("Notebook (8 notes"), s)
        XCTAssertTrue(s.contains("earlier notes (names): 示例店1; 示例店2; 示例店3"), s)
        XCTAssertTrue(s.contains("note: 示例店8 · ¥8.5"), s)
        XCTAssertFalse(s.contains("items collected"), s)
    }

    /// 2026-11-19: an order card aimed under the tab bar opened 神券; a tab the THINK names is still tapped.
    func testTabBarGuardHoldsTapsOnUnnamedTabs() {
        let lines: [(text: String, box: [Int])] = [("首页", [90, 1880, 160, 1910]), ("神券", [400, 1880, 470, 1910]),
                                                   ("订单", [620, 1880, 690, 1910]), ("我的", [840, 1880, 910, 1910]),
                                                   ("示例店", [100, 1700, 300, 1740])]
        let card: JObject = ["action": .str("tap"), "x": .int(488), "y": .int(943), "thought": .str("open the next order 示例店")]
        XCTAssertNotNil(TabBarGuard.held(card, lines: lines, w: 1000, h: 2000))
        var tab = card; tab["thought"] = .str("go to the 神券 tab")
        XCTAssertNil(TabBarGuard.held(tab, lines: lines, w: 1000, h: 2000))
        var high = card; high["y"] = .int(860)
        XCTAssertNil(TabBarGuard.held(high, lines: lines, w: 1000, h: 2000), "above the tab bar")
    }

    /// 2026-11-21: a short word low on the screen is not a tab bar. Notes' compose next to its search field, and the
    /// Phone search button beside its pill (three labels close together, under half the width), were held.
    func testTabBarGuardNeedsARowOfTabs() {
        let notes: [(text: String, box: [Int])] = [("搜索", [80, 1880, 150, 1910])]
        let compose: JObject = ["action": .str("tap"), "x": .int(200), "y": .int(945), "thought": .str("new note")]
        XCTAssertNil(TabBarGuard.held(compose, lines: notes, w: 1000, h: 2000), "one word: no tab bar")
        let phone: [(text: String, box: [Int])] = [("通话", [220, 1880, 290, 1910]), ("通讯录", [370, 1880, 470, 1910]),
                                                   ("拨号键盘", [540, 1880, 680, 1910])]
        let search: JObject = ["action": .str("tap"), "x": .int(700), "y": .int(945), "thought": .str("open search")]
        XCTAssertNil(TabBarGuard.held(search, lines: phone, w: 1000, h: 2000), "the pill is under half the width")
        // the search glyph read as one sign at the end of a full-width row: an icon, not a tab
        let wide: [(text: String, box: [Int])] = [("通话", [80, 1880, 150, 1910]), ("通讯录", [330, 1880, 430, 1910]),
                                                  ("拨号键盘", [560, 1880, 700, 1910]), ("Q", [880, 1880, 910, 1910])]
        let glyph: JObject = ["action": .str("tap"), "x": .int(895), "y": .int(945), "thought": .str("open search")]
        XCTAssertNil(TabBarGuard.held(glyph, lines: wide, w: 1000, h: 2000))
        let me: [(text: String, box: [Int])] = [("首页", [80, 1880, 150, 1910]), ("市集", [280, 1880, 350, 1910]),
                                                ("消息", [640, 1880, 710, 1910]), ("我", [870, 1880, 900, 1910])]
        let tab: JObject = ["action": .str("tap"), "x": .int(885), "y": .int(945), "thought": .str("open the profile")]
        XCTAssertNotNil(TabBarGuard.held(tab, lines: me, w: 1000, h: 2000), "a one-character tab is still a tab")
    }

    func testAnItemBeforeTheGoalsDatesEndsTheList() {
        let goal = "收集 2026年11月9日到今天的所有外卖订单"
        let today = DateComponents(calendar: .current, year: 2026, month: 11, day: 19).date!
        XCTAssertTrue(NoteCheck.beforeStart("示例餐厅 · ¥19.5 · 2026-11-07 00:39:13", goal: goal, today: today))
        XCTAssertFalse(NoteCheck.beforeStart("示例餐厅 · ¥19.5 · 2026-11-10 00:39:13", goal: goal, today: today))
        XCTAssertTrue(NoteCheck.outside("示例餐厅 · 2026-11-07", goal: goal, today: today)?.contains("two or three in a row") == true || NoteCheck.outside("示例餐厅 · 2026-11-07", goal: goal, today: today)?.contains("next two or three items are older") == true)
    }

    /// 2026-11-19: one order kept as four lines in notes.md.
    func testLinesAboutOneItemMerge() {
        var book = Notebook()
        book.note("示例超市(东店) · ¥15.50 · 2026-11-12 23:10:00 · 上海 示例酒店(1234)")
        book.note("¥15.50 · 2026-11-12 23:10:00 · 上海示例酒店 (1234 送上来)")   // no shop: says less
        book.note("¥15.50 · 2026-11-12 23:10:00")
        book.note("示例超市（东店） · ¥15.50 · 上海示例酒店 (1234 送上来)")       // no time: same name and amount
        XCTAssertEqual(book.notes, ["示例超市(东店) · ¥15.50 · 2026-11-12 23:10:00 · 上海 示例酒店(1234)"])
        book.note("示例面馆 · ¥28.5 · 上海 示例酒店")
        book.note("示例面馆 · ¥28.5 · 2026-11-11 04:10:00 · 上海 示例酒店")      // the time added: replaces it
        XCTAssertEqual(book.notes.count, 2)
        XCTAssertTrue(book.notes[1].contains("04:10:00"))
        book.note("示例面馆 · ¥31.0 · 2026-11-10 12:00:00 · 上海 示例酒店")      // another order of that shop
        XCTAssertEqual(book.notes.count, 3)
    }

    func testRecordAuditReadsProblemsOrOK() {
        XCTAssertNil(RecordAudit.problems("OK"))
        XCTAssertNil(RecordAudit.problems("Everything matches."))
        let found = RecordAudit.problems("- MISSING: 示例店 ¥25.50\nNAME: record 3 is a product; the shop is 示例超市\nnote")
        XCTAssertEqual(found, "MISSING: 示例店 ¥25.50\nNAME: record 3 is a product; the shop is 示例超市")
        var seen = SeenLines()
        seen.add(["12:30", "示例店", "示例店", "¥25.50", "x"])
        XCTAssertEqual(seen.lines, ["示例店", "¥25.50"])
    }

    func testConnectionDropsAreRetried() {
        XCTAssertTrue(LLMClient.connectionDrop(URLError(.secureConnectionFailed)))
        XCTAssertTrue(LLMClient.connectionDrop(URLError(.networkConnectionLost)))
        XCTAssertFalse(LLMClient.connectionDrop(URLError(.timedOut)), "a slow answer is not retried here")
        XCTAssertFalse(LLMClient.connectionDrop(URLError(.cancelled)))
    }

    func testResumeKeepsRecordedLines() {
        let steps: [JObject] = [["action": .str("tap")],
                                ["action": .str("tap"), "recorded": .arr([.str("示例面馆 · ¥28.5 · 2026-11-11 04:10:00")])]]
        XCTAssertEqual(AgentLoop.savedNotebook(steps).notes, ["示例面馆 · ¥28.5 · 2026-11-11 04:10:00"])
    }

    func testSnapsStayForGoalsThatAskForPictures() {
        XCTAssertTrue(Record.wantsPictures("把每个订单截图保存"))
        XCTAssertTrue(Record.wantsPictures("Save a screenshot of each order"))
        XCTAssertFalse(Record.wantsPictures("把美团外卖订单按地区整理"))
    }

    func testBusyReason() {
        XCTAssertEqual(LLMClient.busyReason(#"{"status":"busy","reason":"call_in_progress"}"#), "call_in_progress")
        XCTAssertNil(LLMClient.busyReason("oops"))
    }

    func testTreeWaitGivesUpWithoutStoppingTheTask() async {
        let slow = Task<Int, Never> { try? await Task.sleep(nanoseconds: 600_000_000); return 7 }
        let started = Date()
        let early = await FramePrep.value(of: slow, within: 0.1)
        XCTAssertNil(early)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.4)
        let later = await FramePrep.value(of: slow, within: 2)
        XCTAssertEqual(later, 7, "the task went on after the first wait gave up")
    }
}

final class MainStallTests: XCTestCase {
    /// The stall sampler reads the main thread's stack while it is stuck (Henry 2026-11-19: "找不到，你就要补 log").
    @MainActor func testMainStallNamesTheBusyFrame() {
        let stall = MainStall()
        let done = expectation(description: "sampled")
        DispatchQueue.global().async {
            Thread.sleep(forTimeInterval: 0.1)
            for _ in 0..<10 { stall.sample(); Thread.sleep(forTimeInterval: 0.02) }
            done.fulfill()
        }
        let until = Date().addingTimeInterval(0.5)
        while Date() < until { _ = (0..<1000).reduce(0, +) }  // busy on main
        wait(for: [done], timeout: 2)
        let line = stall.report(lag: 0.5) ?? ""
        XCTAssertTrue(line.hasPrefix("main stall 500 ms, 10 samples"), line)
        XCTAssertNil(stall.report(lag: 0.5))  // reset after a report
    }
}

final class NotebookBlockTests: XCTestCase {
    /// 2026-11-19 (Gaode): rides read as four lines each were kept line by line; a shared start was dropped.
    func testMultiLineItemsAreOneItemEach() {
        let reply = "起点: 酒店A\n终点: 机场\n下单时间: 2026-11-15 06:10\n¥60.50\n\n起点: 咖啡馆\n终点: 酒店A\n下单时间: 2026-11-14 22:10\n¥20.50"
        XCTAssertEqual(Notebook.lines(reply), ["起点: 酒店A · 终点: 机场 · 下单时间: 2026-11-15 06:10 · ¥60.50",
                                               "起点: 咖啡馆 · 终点: 酒店A · 下单时间: 2026-11-14 22:10 · ¥20.50"])
        let packed = "起点: A\n终点: B\n¥1.5\n起点: C\n终点: D\n¥2.5"
        XCTAssertEqual(Notebook.lines(packed), ["起点: A · 终点: B · ¥1.5", "起点: C · 终点: D · ¥2.5"])
        XCTAssertEqual(Notebook.lines("Song A\nSong B\n\nSong C"), ["Song A", "Song B", "Song C"])
    }

    func testSameTimeReadTwiceIsKeptOnce() {
        var book = Notebook()
        book.add(["起点: A · 下单时间: 2026-11-15 06:10 · ¥59.90"])
        book.add(["起点: X", "起点: A · 终点: B · 下单时间: 2026-11-15 06:10 · ¥60.50"])
        XCTAssertEqual(book.items, ["起点: A · 终点: B · 下单时间: 2026-11-15 06:10 · ¥60.50", "起点: X"])
    }
}

/// After the list is read (2026-11-19, Ctrip): a done after a snap or a file ends the run; one scroll back up is refused.
@MainActor final class ListDoneTests: XCTestCase {
    private func act(_ s: String) -> JObject { try! Actions.parseCommand(s) }

    func testADoneAfterOnlyWritingIsKept() {
        let kept = Actions.blindSafe([act("snap a/p.jpg"), act("done ok")])
        XCTAssertEqual(kept.map { $0["action"]?.str }, ["snap", "done"])
        XCTAssertEqual(Actions.blindSafe([act("tap 1 2"), act("done ok")]).map { $0["action"]?.str }, ["tap"])
    }

    func testTheFirstScrollBackAfterTheListIsReadIsRefused() {
        let agent = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: FakeModel { _ in "" }, planner: nil, trace: nil)
        let back = act("swipe 500 300 500 600"), down = act("swipe 500 700 500 300")
        XCTAssertNil(agent.scrollBackRefusal(back))  // the list is not read yet
        agent.listRead = true
        XCTAssertNil(agent.scrollBackRefusal(down))
        XCTAssertNotNil(agent.scrollBackRefusal(back))
        XCTAssertNil(agent.scrollBackRefusal(back))  // asked again: it goes through
    }

    private func loop(_ model: FakeModel, folder: String) -> AgentLoop {
        let agent = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: model, planner: nil, trace: nil)
        (agent.task, agent.runFolder) = ("collect my rides", folder)
        return agent
    }

    private func folder() -> (String, URL) {
        let name = "listdone-\(UUID().uuidString.prefix(6))"
        return (name, MemoryFiles.root.appendingPathComponent(name))
    }

    /// 2026-11-20: 25 rides collected, then the README in one reply was cut three times. The app writes it now.
    func testAListDoneWritesTheResultFromTheNotebook() throws {
        let (name, dir) = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = loop(FakeModel { _ in "" }, folder: name)
        XCTAssertEqual(agent.listDone(), Collect.listDone, "an empty notebook: nothing to write")
        agent.notebook.add(["Ride A ¥12", "Ride B ¥30"])
        let hint = agent.listDone()
        XCTAssertTrue(hint.contains("\(name)/README.md") && hint.contains("Do not write it again"), hint)
        XCTAssertTrue(agent.resultWritten)
        let readme = dir.appendingPathComponent("README.md")
        XCTAssertEqual(try String(contentsOf: readme, encoding: .utf8), "# collect my rides\n\n- Ride A ¥12\n- Ride B ¥30\n")
        let saved = agent.steps.filter { $0["action"]?.str == "file" }
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(RunOutputs.written(String(saved[0]["reason"]?.str?.dropFirst(4) ?? "")), "\(name)/README.md", "shown with the run")
        XCTAssertTrue(agent.actorUserPrompt().contains("Do not write it again"), "said in full, not only in a cut history line")
        // more read later: the app's file is written again; nothing new: left as it is
        agent.notebook.add(["Ride C ¥8"])
        _ = agent.listDone(); _ = agent.listDone()
        XCTAssertTrue(try String(contentsOf: readme, encoding: .utf8).hasSuffix("- Ride C ¥8\n"))
        XCTAssertEqual(agent.steps.filter { $0["action"]?.str == "file" }.count, 2)
        // a result the actor wrote itself is left alone
        let own = loop(FakeModel { _ in "" }, folder: name + "-own")
        own.notebook.add(["Ride A ¥12"])
        own.resultWritten = true
        XCTAssertEqual(own.listDone(), Collect.listDone)
        XCTAssertFalse(FileManager.default.fileExists(atPath: MemoryFiles.root.appendingPathComponent(name + "-own").path))
    }

    func testErrorsInARowAfterTheWorkIsCompleteEndTheRunAsDone() async throws {
        let (name, dir) = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = loop(FakeModel { _ in "no action here" }, folder: name)
        agent.notebook.add(["Ride A ¥12"])
        agent.listRead = true
        var asked = false
        agent.onHelp = { _ in asked = true; return .stop }
        await agent.run()
        XCTAssertFalse(asked, "the work was done: no help")
        XCTAssertEqual(agent.steps.last?["action"]?.str, "done")
        XCTAssertTrue(agent.steps.last?["reason"]?.str?.contains("after the work was complete") == true)
        XCTAssertEqual(agent.steps.last?["notebook"], .arr([.str("Ride A ¥12")]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("README.md").path))
    }

    func testErrorsInARowBeforeTheWorkIsCompleteAskForHelpInPlainWords() async throws {
        let (name, dir) = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = FakeModel { _ in "" }
        model.error = LLMError(message: "the model's reply stream ended before it finished", reason: "stream_cut")
        let agent = loop(model, folder: name)
        agent.notebook.add(["Ride A ¥12"])  // the list is not read to its end
        var asked: (reason: String, shown: String?)?
        agent.onHelp = { [unowned agent] reason in asked = (reason, agent.helpMessage); return .stop }
        await agent.run()
        XCTAssertEqual(asked?.reason, "3 errors in a row", "the record and its matching stay")
        XCTAssertEqual(asked?.shown, ModelRequestFailure.streakMessage(3, cutOff: true))
        XCTAssertNil(agent.helpMessage)
        XCTAssertEqual(agent.steps.last?["action"]?.str, "stopped")
        XCTAssertEqual(agent.steps.filter { $0["action"]?.str == "hiccup" }.first?["reason"]?.str, ModelRequestFailure.cutOffHiccup)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("README.md").path))
    }

    func testTheErrorHelpSaysWhatHappenedAndWhatToDo() {
        let cut = ModelRequestFailure.streakMessage(3, cutOff: true), other = ModelRequestFailure.streakMessage(3, cutOff: false)
        for text in [cut, other] {
            XCTAssertTrue(text.contains("3 times in a row") && text.contains("saved") && text.contains("Continue"), text)
            XCTAssertFalse(text.contains("errors in a row"))
        }
        XCTAssertTrue(cut.contains("cut off"))
        XCTAssertFalse(other.contains("cut off"))
        XCTAssertTrue(ModelRequestFailure.cutOff(URLError(.timedOut)))
        XCTAssertTrue(ModelRequestFailure.cutOff(LLMError(message: "x", reason: "stream_cut")))
        XCTAssertTrue(ModelRequestFailure.cutOff(LLMError(message: "x", status: 504)))
        XCTAssertFalse(ModelRequestFailure.cutOff(LLMError(message: "x", status: 500)))
        XCTAssertEqual(RunPolicy.unattended(repairMirroring: false).fallback(reason: "3 errors in a row", confirm: false, restarts: 0), .restart)
    }
}
