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
    }
}
