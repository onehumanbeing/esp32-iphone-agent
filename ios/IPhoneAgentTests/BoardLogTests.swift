import XCTest
@testable import IPhoneAgent

/// Board AirPlay log lines ("blog ...") land in debug.log and are relayed like any other line.
@MainActor final class BoardLogTests: XCTestCase {
    func testBoardLogLineIsLoggedAndRelayed() {
        let board = FakeBoard()
        let channel = CommandChannel(transport: board)
        board.channel = channel
        var relayed: [String] = []
        let saved = DebugLog.relay
        DebugLog.relay = { line in MainActor.assumeIsolated { relayed.append(line); _ = channel.relayLog(line) } }
        defer { DebugLog.relay = saved }
        channel.handleReply("blog 1234 mirror: data connection accepted")
        channel.handleReply("blog 99")
        XCTAssertEqual(relayed, ["board: mirror: data connection accepted", "board: "])
    }

    func testStatusWithVideoAgeDecodes() {
        let json = #"{"fw":"0.2.1","up":12421,"rst":"usb","heap":49784,"psram":1931804,"usb":"ok","net":"ap","ip":"192.168.4.1","sta":0,"ap":"idle","w":480,"h":1040,"kbps":0,"fps":0.0,"idr":0,"gop":0,"vage":0,"ble":{"mtu":23,"phy":1,"kbps":0,"drop":0,"rdrop":0,"n":0},"udp":{"n":0,"kbps":0,"nack":0,"drop":0}}"#
        let s = BoardStatus.decode(Data(json.utf8))
        XCTAssertEqual(s?.vage, 0)
        XCTAssertEqual(s?.fw, FirmwareVersion("0.2.1"))
        XCTAssertNil(s?.fz)  // older firmware: never frozen
    }

    func testFrozenGopStatusDecodesAndTheShortNotifyClearsIt() throws {
        let full = try XCTUnwrap(BoardStatus.decode(Data(#"{"fw":"0.2.2","ap":"streaming","gop":4194000,"vage":40,"ovf":1,"fz":1}"#.utf8)))
        XCTAssertEqual(full.fz, 1)
        XCTAssertEqual(full.ovf, 1)
        let short = try XCTUnwrap(BoardStatus.decode(Data(#"{"fw":"0.2.2","ap":"streaming","fz":0,"ble":{"mtu":23}}"#.utf8)))
        let m = full.merged(with: short)
        XCTAssertEqual(m.fz, 0)
        XCTAssertEqual(m.ovf, 1)
    }

    @MainActor func testAFrozenFeedIsNotLive() {
        let feed = VideoFeed(), device = FakeDevice()
        feed.device = device
        feed.mirroring = true
        feed.show(Data([1]), width: 10, height: 20)
        XCTAssertTrue(feed.live)
        feed.frozen = true
        XCTAssertFalse(feed.live)
    }
}

/// M5Stack StopWatch: `ui` lines for its screen, `btn` lines from its buttons; nothing for any other board.
@MainActor final class StopWatchUITests: XCTestCase {
    typealias State = AgentActivityAttributes.ContentState
    let stopwatch = BoardStatus(board: "stopwatch", ui: 1)

    private func make(_ status: BoardStatus?) -> (CommandChannel, FakeBoard) {
        let board = FakeBoard()
        let channel = CommandChannel(transport: board)
        board.channel = channel
        channel.boardStatus = { status }
        return (channel, board)
    }

    private func json(_ line: String) throws -> [String: Any] {
        let body = try XCTUnwrap(line.split(separator: " ", maxSplits: 1).last)
        XCTAssertTrue(line.hasPrefix("ui {"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
    }

    func testTheLineCarriesTheStateWithinItsLimits() throws {
        var state = State(mood: .acting, step: 4, limit: 300, line: String(repeating: "点开设置", count: 30), phase: .running)
        (state.done, state.total) = (3, 12)
        let (line, picks) = try XCTUnwrap(StopWatchUI.command(.show(state)))
        XCTAssertNil(picks)
        XCTAssertLessThanOrEqual(line.utf8.count, StopWatchUI.maxLine)
        let o = try json(line)
        XCTAssertEqual(o["m"] as? String, "acting")
        XCTAssertEqual(o["p"] as? String, "running")
        XCTAssertEqual(o["s"] as? Int, 4)
        XCTAssertEqual(o["l"] as? Int, 300)
        XCTAssertEqual(o["d"] as? Int, 3)
        XCTAssertEqual(o["n"] as? Int, 12)
        XCTAssertEqual(o["f"] as? Bool, false)
        XCTAssertNil(o["k"])
        let t = try XCTUnwrap(o["t"] as? String)
        XCTAssertEqual(t.utf8.count, 78)  // 26 whole 3-byte characters, never half of one
        XCTAssertTrue(state.line.hasPrefix(t))
    }

    func testStandbyPicksAreCappedAndATightLineDropsTheTextFirst() throws {
        let names = ["Morning alarm and weather report", "B", "C", "D"]
        let picks = names.map { StandbyPick(id: UUID(), name: $0, symbol: "alarm") }
        let state = LiveActivityController.standbyState(picks)
        let (line, sent) = try XCTUnwrap(StopWatchUI.command(.show(state)))
        XCTAssertEqual(sent, picks.prefix(3).map(\.id))
        let k = try XCTUnwrap(json(line)["k"] as? [String])
        XCTAssertEqual(k, ["Morning alarm and weathe", "B", "C"])
        XCTAssertTrue(k.allSatisfy { $0.utf8.count <= StopWatchUI.maxPick })
        let (tight, kept) = try XCTUnwrap(StopWatchUI.command(.show(state), max: 100))
        XCTAssertLessThanOrEqual(tight.utf8.count, 100)
        XCTAssertNil(try json(tight)["t"])
        XCTAssertNotNil(kept)
        let (tiny, none) = try XCTUnwrap(StopWatchUI.command(.show(state), max: 60))
        XCTAssertNil(try json(tiny)["k"])
        XCTAssertNil(none)
        XCTAssertEqual(StopWatchUI.command(.off)?.0, "ui off")
    }

    func testOnlyAStopWatchWithAScreenGetsUILines() {
        let state = State(mood: .thinking, step: 1, limit: 300, line: "Reading the screen…")
        for status in [nil, BoardStatus(board: "xiao"), BoardStatus(board: "stopwatch"), BoardStatus(usb: "ok")] as [BoardStatus?] {
            let (channel, board) = make(status)
            channel.showUI(state)
            channel.showUI(nil)
            channel.flushUI()
            XCTAssertEqual(board.lines, [], "\(String(describing: status))")
        }
    }

    func testAStopWatchGetsChangesOnlyAtMostTwiceASecond() {
        let (channel, board) = make(stopwatch)
        var state = State(mood: .thinking, step: 1, limit: 300, line: "a")
        channel.showUI(state)
        channel.showUI(state)
        XCTAssertEqual(board.lines.count, 1)
        XCTAssertTrue(board.lines[0].split(separator: " ")[1] == "ui")
        state.step = 2
        channel.showUI(state)
        state.step = 3
        channel.showUI(state)  // third in a second: kept for later
        XCTAssertEqual(board.lines.count, 2)
        channel.linkUp()  // a reconnect: the newest state goes again
        channel.flushUI()
        XCTAssertEqual(board.lines.count, 2)  // still rate-limited
    }

    func testButtonsMapToCommands() {
        let picks = [UUID(), UUID()]
        XCTAssertEqual(StopWatchUI.action("stop", picks: []), .command(.stop))
        XCTAssertEqual(StopWatchUI.action("pause", picks: []), .command(.pause))
        XCTAssertEqual(StopWatchUI.action("unpause", picks: []), .command(.unpause))
        XCTAssertEqual(StopWatchUI.action("continue", picks: []), .command(.resume))
        XCTAssertEqual(StopWatchUI.action("takeover", picks: []), .command(.takeOver))
        XCTAssertEqual(StopWatchUI.action("home", picks: []), .home)
        XCTAssertEqual(StopWatchUI.action("run 1", picks: picks), .run(picks[1]))
        XCTAssertNil(StopWatchUI.action("run 2", picks: picks))
        XCTAssertNil(StopWatchUI.action("run -1", picks: picks))
        XCTAssertNil(StopWatchUI.action("run", picks: picks))
        XCTAssertNil(StopWatchUI.action("reboot", picks: picks))
    }

    func testRunPicksTheIntentOnTheBoardsScreenAndOtherBoardsAreNotHeard() {
        let picks = ["A", "B"].map { StandbyPick(id: UUID(), name: $0, symbol: "star") }
        let (channel, board) = make(stopwatch)
        var heard: [StopWatchUI.Action] = []
        channel.onButton = { heard.append($0) }
        channel.showUI(LiveActivityController.standbyState(picks))
        XCTAssertEqual(board.lines.count, 1, board.lines.joined(separator: "|"))
        XCTAssertEqual(channel.uiPicks, picks.map(\.id))
        channel.handleReply("btn run 1")
        channel.handleReply("btn stop\n")
        channel.handleReply("btn run 5")
        XCTAssertEqual(heard, [.run(picks[1].id), .command(.stop)])

        let (other, _) = make(BoardStatus(board: "xiao"))
        other.onButton = { heard.append($0) }
        other.handleReply("btn stop")
        XCTAssertEqual(heard.count, 2)
    }

    func testStatusWithAScreenDecodesAndSurvivesAShortNotify() throws {
        let full = try XCTUnwrap(BoardStatus.decode(Data(#"{"board":"stopwatch","ui":1,"hid":"ok"}"#.utf8)))
        XCTAssertTrue(StopWatchUI.enabled(full))
        let short = try XCTUnwrap(BoardStatus.decode(Data(#"{"up":5,"ble":{"mtu":23}}"#.utf8)))
        XCTAssertTrue(StopWatchUI.enabled(full.merged(with: short)))
        XCTAssertFalse(StopWatchUI.enabled(BoardStatus.decode(Data(#"{"board":"xiao","hid":"ok"}"#.utf8))))
    }
}
