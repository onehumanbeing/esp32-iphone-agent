import XCTest
@testable import IPhoneAgent

/// The board's RAM log is read page by page (`logs <offset> <max>`) for diagnostics; old firmware has none.
@MainActor final class BoardLogDumpTests: XCTestCase {
    func testPagesJoinAndUnescape() async {
        let board = PagedLogBoard(log: "[1.000] boot fw 0.2.3\n[2.500] wifi: got ip 192.168.4.1\nC:\\path\n")
        let text = await BoardLogDump.read(board, page: 10)
        XCTAssertEqual(text, board.log)
        XCTAssertGreaterThan(board.sent.count, 3)
        XCTAssertTrue(board.sent.allSatisfy { $0.hasPrefix("logs ") && $0.hasSuffix(" 10") })
    }

    func testOldFirmwareHasNoLog() async {
        let board = PagedLogBoard(log: "x\n")
        board.unknown = true
        let text = await BoardLogDump.read(board)
        XCTAssertNil(text)
    }

    func testNoBoardNoLog() async {
        let board = PagedLogBoard(log: "x\n")
        board.connected = false
        let text = await BoardLogDump.read(board)
        XCTAssertNil(text)
        XCTAssertTrue(board.sent.isEmpty)
    }

    func testParse() {
        XCTAssertEqual(BoardLogDump.parse("12 40 a\\nb")?.text, "a\nb")
        XCTAssertEqual(BoardLogDump.parse("40 40 ")?.next, 40)
        XCTAssertNil(BoardLogDump.parse("rst usb, last dump: none"))
    }
}

/// Answers `logs` like firmware 0.2.3: "<next> <end> <escaped text>" (what send returns after "ok").
@MainActor private final class PagedLogBoard: HIDDevice {
    let log: String
    var links = 1
    var connected = true
    var unknown = false
    var sent: [String] = []
    init(log: String) { self.log = log }

    func send(_ command: String) async throws -> String {
        sent.append(command)
        if unknown { throw DeviceError(message: "unknown command") }
        let args = command.split(separator: " ").dropFirst().compactMap { Int($0) }
        let bytes = Array(log.utf8), from = min(args[0], bytes.count), max = args[1]
        var out = "", next = from
        while next < bytes.count {
            let c = bytes[next]
            let piece = c == 10 ? "\\n" : c == 92 ? "\\\\" : String(UnicodeScalar(c))
            if out.count + piece.count > max { break }
            out += piece
            next += 1
        }
        return "\(next) \(bytes.count) \(out)"
    }

    func waitConnected(_ timeout: TimeInterval) async -> Bool { connected }
}
