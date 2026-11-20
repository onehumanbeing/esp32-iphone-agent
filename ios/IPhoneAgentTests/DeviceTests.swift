import UIKit
import XCTest
@testable import IPhoneAgent

/// A board that answers every command like the firmware does.
@MainActor final class FakeBoard: BoardTransport {
    var isConnected = true
    var lines: [String] = []
    var drops = 0
    var silent = false
    var timeoutOnceOn: String?
    var dropReplyOnceOn: String?
    var onCommand: ((String) -> Void)?
    weak var channel: CommandChannel?

    func write(_ line: String) throws {
        lines.append(line)
        guard !silent else { return }
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        onCommand?(parts[1])
        if parts[1] == dropReplyOnceOn {
            dropReplyOnceOn = nil
            return
        }
        if parts[1] == timeoutOnceOn {
            timeoutOnceOn = nil
            throw DeviceError(message: "timeout")
        }
        let reply = parts[1] == "bad" ? "\(parts[0]) err unknown command" : "\(parts[0]) ok"
        Task { @MainActor in self.channel?.handleReply(reply) }
    }

    func dropLink() { drops += 1 }
}

/// Port of server/tests/test_device.py, with a fake BLE transport instead of a TCP socket.
@MainActor final class DeviceTests: XCTestCase {
    /// These tests check the iPhone's moves; the iPad's own tests set DeviceKind.isPad themselves (CI runs both).
    private static var wasPad = false
    override func setUp() {
        super.setUp()
        Self.wasPad = DeviceKind.isPad
        DeviceKind.isPad = false
    }
    override func tearDown() {
        DeviceKind.isPad = Self.wasPad
        super.tearDown()
    }

    func testTimeoutGrowsWithMoveDistanceAndTextLength() {
        XCTAssertEqual(CommandChannel.timeout("click"), 5)
        XCTAssertGreaterThan(CommandChannel.timeout("move 1000 -20"), CommandChannel.timeout("move 10 10"))
        XCTAssertGreaterThanOrEqual(CommandChannel.timeout("move 10 10"), 5)
        XCTAssertGreaterThan(CommandChannel.timeout("type " + String(repeating: "x", count: 40)),
                             CommandChannel.timeout("type hi"))
    }

    func testSendWithoutBoardFailsFast() async {
        do {
            try await CommandChannel().send("ping")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not connected"))
        }
    }

    func testRoundTripWithAFakeBoard() async throws {
        let board = FakeBoard()
        let channel = CommandChannel(transport: board)
        board.channel = channel
        channel.linkUp()
        let ok = await channel.waitConnected(2)
        XCTAssertTrue(ok)
        try await channel.send("ping")
        do {
            try await channel.send("bad")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("unknown command"))
        }
        XCTAssertEqual(channel.links, 1)
        let ids = board.lines.compactMap { Int($0.split(separator: " ")[0]) }  // request ids: random start, then +1
        XCTAssertEqual(board.lines.map { $0.split(separator: " ")[1] }, ["ping", "bad"])
        XCTAssertEqual(ids.count == 2 ? ids[1] - ids[0] : 0, 1)
    }

    func testCommandsGoOneAtATime() async throws {
        let board = FakeBoard()
        let channel = CommandChannel(transport: board)
        board.channel = channel
        async let a: String = channel.send("move 1 0")
        async let b: String = channel.send("move -1 0")
        _ = try await (a, b)
        XCTAssertEqual(board.lines.count, 2)
    }

    func testCancellingQueuedInputDoesNotWriteItBeforeReset() async throws {
        let board = FakeBoard(), channel = CommandChannel(transport: board)
        board.channel = channel
        let firstWritten = expectation(description: "首条命令已发出，保留回执以占住发送锁")
        board.dropReplyOnceOn = "ping"
        board.onCommand = { if $0 == "ping" { firstWritten.fulfill() } }
        let first = Task { try await channel.send("ping") }
        await fulfillment(of: [firstWritten], timeout: 2)

        let queued = expectation(description: "旧任务已请求发送输入")
        let input = Task {
            queued.fulfill()
            return try await channel.send("key enter")
        }
        await fulfillment(of: [queued], timeout: 2)
        XCTAssertEqual(board.lines.count, 1)
        input.cancel()
        let id = try XCTUnwrap(board.lines.first?.split(separator: " ").first)
        channel.handleReply("\(id) ok")
        _ = try await first.value
        do {
            _ = try await input.value
            XCTFail("已取消的输入必须退出发送队列")
        } catch { XCTAssertTrue(error is CancellationError) }

        try await channel.send("reset")
        XCTAssertEqual(board.lines.map { $0.split(separator: " ", maxSplits: 1)[1] }, ["ping", "reset"])
    }

    func testLostReplyDoesNotRepeatInputButRetriesSafeCommands() async throws {
        let board = FakeBoard(), channel = CommandChannel(transport: board)
        board.channel = channel
        var recovered: [String] = []
        channel.onTimeout = { recovered.append($0) }
        for command in ["click", "type abc", "move 9 0", "scroll 1 0", "press", "key enter", "homescreen"] {
            board.timeoutOnceOn = command
            board.lines = []
            do {
                try await channel.send(command)
                XCTFail("回执丢失后应将输入结果报告为未知")
            } catch { XCTAssertTrue(error is BoardTimeout) }
            XCTAssertEqual(board.lines.count, 1, command)
            XCTAssertEqual(recovered.last, command)
        }
        for command in ["home", "release", "snap", "logs 0 5"] {
            board.timeoutOnceOn = command
            board.lines = []
            try await channel.send(command)
            XCTAssertEqual(board.lines.count, 2, command)
        }
    }

    func testActualReplyDeadlineDoesNotRepeatClickAndStillRetriesRelease() async throws {
        // Drop the reply after a successful write so the channel timer fires.
        for command in ["click", "release"] {
            let board = FakeBoard(), channel = CommandChannel(transport: board)
            board.channel = channel
            board.dropReplyOnceOn = command
            var recoveries = 0
            channel.onTimeout = { _ in
                recoveries += 1
                let id = board.lines[0].split(separator: " ")[0]
                channel.handleReply("\(id) ok")  // A late reply must not complete a later request.
            }
            do {
                try await channel.send(command)
                XCTAssertEqual(command, "release")
            } catch {
                XCTAssertEqual(command, "click")
                XCTAssertTrue(error is BoardTimeout)
            }
            XCTAssertEqual(recoveries, 1)
            XCTAssertEqual(board.lines.count, command == "click" ? 1 : 2)
            XCTAssertEqual(Set(board.lines.map { $0.split(separator: " ")[0] }).count, board.lines.count)
        }
    }

    func testLostPressReplyReleasesButtonBeforeEndingGesture() async throws {
        let board = FakeBoard(), channel = CommandChannel(transport: board)
        board.channel = channel
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let pointer = Pointer(device: channel, calibrationFile: file)
        pointer.finishCalibration(x: 0.5, y: 0.25)
        pointer.flickInOne = false  // firmware before 0.2.5: press, move, release
        for homeSwipe in [false, true] {
            board.lines = []
            board.timeoutOnceOn = "press"
            do {
                if homeSwipe { try await pointer.homeSwipe() }
                else { try await pointer.swipe(0.2, 0.2, 0.5, 0.5) }
                XCTFail("丢失按下回执后应终止手势")
            } catch { XCTAssertTrue(error is BoardTimeout) }
            XCTAssertEqual(board.lines.suffix(2).map { $0.split(separator: " ")[1] }, ["press", "release"])
        }
    }

    func testCancellingADragDuringPressStillAcknowledgesReleaseAndReset() async throws {
        let board = FakeBoard(), channel = CommandChannel(transport: board)
        board.channel = channel
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let pointer = Pointer(device: channel, calibrationFile: file)
        pointer.finishCalibration(x: 0.5, y: 0.25)
        let pressed = expectation(description: "The board received the press")
        board.dropReplyOnceOn = "press"
        board.onCommand = { if $0 == "press" { pressed.fulfill() } }
        var acknowledged: [String] = []
        channel.onTiming = { name, _ in acknowledged.append(name) }

        let drag = Task {
            do {
                try await pointer.swipe(0.2, 0.2, 0.5, 0.5)
                XCTFail("The drag should have been cancelled")
            } catch is CancellationError {}
            try await channel.send("reset")
        }
        await fulfillment(of: [pressed], timeout: 2)
        drag.cancel()
        try await drag.value

        XCTAssertEqual(board.lines.suffix(3).map { $0.split(separator: " ")[1] }, ["press", "release", "reset"])
        XCTAssertEqual(Array(acknowledged.suffix(2)), ["release", "reset"])
    }

    func testUnacknowledgedAimMovesForceRehomingButSuccessfulAimKeepsPosition() async throws {
        let images = VisionTests()
        let before = images.screen(pointer: (274, 540)), after = images.screen(pointer: (289, 540))
        for failure in ["move 12 0", "move -12 0", "correction", "none"] {
            let board = FakeBoard(), channel = CommandChannel(transport: board), screen = FakeScreen()
            board.channel = channel
            board.timeoutOnceOn = failure
            screen.frame = before
            var correction: [Int]?
            // Trigger aim correction through a pixel change, then drop the reply after the move appears on screen.
            board.onCommand = { [weak board] command in
                if command == "move 12 0" { screen.frame = after; screen.updated = now() }
                if command == "move -12 0" { screen.frame = before; screen.updated = now() }
                if command.hasPrefix("move "),
                   !["move 200 400", "move 12 0", "move -12 0"].contains(command) {
                    correction = command.split(separator: " ").dropFirst().compactMap { Int($0) }
                    if failure == "correction" { board?.timeoutOnceOn = command }
                }
            }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
            defer { try? FileManager.default.removeItem(at: file) }
            let pointer = Pointer(device: channel, calibrationFile: file, screen: screen)
            pointer.finishCalibration(x: 0.5, y: 0.25)
            do {
                try await pointer.point(0.5, 0.5, aim: true)
                XCTAssertEqual(failure, "none")
            } catch {
                XCTAssertNotEqual(failure, "none")
                XCTAssertTrue(error is BoardTimeout)
            }
            if failure == "correction" || failure == "none" { XCTAssertNotNil(correction) }
            let previousCorrection = correction
            let count = board.lines.count
            board.onCommand = nil
            try await pointer.point(0.5, 0.5)
            let subsequent = board.lines.dropFirst(count).map { String($0.split(separator: " ", maxSplits: 1)[1]) }
            if failure == "none" {
                let delta = try XCTUnwrap(previousCorrection)
                XCTAssertEqual(subsequent, ["move \(-delta[0]) \(-delta[1])"])
            } else {
                XCTAssertEqual(subsequent, ["home", "move 200 400"], failure)
            }
        }
    }

    func testLostHomeKeyReplyDoesNotTriggerAnotherHomeGesture() async {
        let board = FakeBoard(), channel = CommandChannel(transport: board)
        board.channel = channel
        board.timeoutOnceOn = "homescreen"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let pointer = Pointer(device: channel, calibrationFile: file)
        do {
            try await pointer.goHome()
            XCTFail("丢失主屏键回执后应报告超时")
        } catch { XCTAssertTrue(error is BoardTimeout) }
        XCTAssertEqual(board.lines.map { $0.split(separator: " ")[1] }, ["homescreen"])
    }

    func testDepartureChecksForBackgroundAfterLostSwipeReply() async throws {
        var attempts: [AppDeparture.Method] = []
        let departure = AppDeparture(isBackground: { false }, isConnected: { true }, attempt: { method in
            attempts.append(method)
            throw BoardTimeout(command: "move", seconds: 5)
        }, waitForBackground: { _ in true })
        let left = try await departure.leave()
        XCTAssertTrue(left)
        XCTAssertEqual(attempts, [.swipe])
    }

    func testLinkDownFailsCommandsInFlight() async {
        let board = FakeBoard()
        board.silent = true
        let channel = CommandChannel(transport: board)
        board.channel = channel
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            channel.linkDown()
        }
        do {
            try await channel.send("click")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("disconnected"))
        }
    }

    func testReplyParsing() {
        XCTAssertEqual(BoardReply.parse("12 ok"), BoardReply(id: 12, ok: true, text: ""))
        XCTAssertEqual(BoardReply.parse("3 ok 812\n"), BoardReply(id: 3, ok: true, text: "812"))
        XCTAssertEqual(BoardReply.parse("4 err unknown command"), BoardReply(id: 4, ok: false, text: "unknown command"))
        XCTAssertNil(BoardReply.parse("ok"))
    }

    /// A --dual-hid board reports its input (hidm); a compact status without it keeps the last one.
    func testDualHIDBoardReportsItsInputMode() throws {
        let ble = try XCTUnwrap(BoardStatus.decode(Data(#"{"hidm":"ble","hid":"ok","usb":"ok"}"#.utf8)))
        XCTAssertEqual(ble.hidm, "ble")
        XCTAssertTrue(ble.isWirelessHID)
        XCTAssertEqual(ble.merged(with: BoardStatus(up: 5)).hidm, "ble")
        let usb = try XCTUnwrap(BoardStatus.decode(Data(#"{"hidm":"usb","usb":"ok"}"#.utf8)))
        XCTAssertFalse(usb.isWirelessHID, "USB mode sends no hid field")
        XCTAssertEqual(usb.inputState, "ok")
        XCTAssertNil(try XCTUnwrap(BoardStatus.decode(Data(#"{"usb":"ok"}"#.utf8))).hidm, "single-mode firmware")
    }

    func testAnotherDevicesMirroringIsNotThisDevicesScreen() throws {
        let iPhone = try XCTUnwrap(BoardStatus.decode(Data(#"{"ap":"streaming","src":"iPhone15,4","usb":"ok"}"#.utf8)))
        XCTAssertEqual(iPhone.seen(by: "iPad15,3").ap, "other", "the iPad must not take the iPhone's screen")
        XCTAssertEqual(iPhone.seen(by: "iPhone15,4").ap, "streaming")
        var connecting = iPhone
        connecting.ap = "connected"
        XCTAssertEqual(connecting.seen(by: "iPad15,3").ap, "other")
        var none = iPhone
        none.ap = "idle"; none.src = ""
        XCTAssertEqual(none.seen(by: "iPad15,3").ap, "idle")
        var unknown = iPhone
        unknown.src = ""  // before SETUP names the sender
        XCTAssertEqual(unknown.seen(by: "iPad15,3").ap, "streaming")
        unknown.src = nil  // older firmware
        XCTAssertEqual(unknown.seen(by: "iPad15,3").ap, "streaming")
        // the iPhone stops, the iPad starts: the next status names the iPad
        let merged = iPhone.merged(with: try XCTUnwrap(BoardStatus.decode(Data(#"{"ap":"streaming","src":"iPad15,3"}"#.utf8))))
        XCTAssertEqual(merged.seen(by: "iPad15,3").ap, "streaming")
    }

    func testAUSBBoardLeavingThisIPhoneInvalidatesThePointerAndAsksToPlugIn() {
        let board = BoardLink(mock: true)
        board.updateStatus(BoardStatus(usb: "ok", ap: "streaming"))
        let plugged = board.commands.links
        board.updateStatus(BoardStatus(usb: "off"))
        XCTAssertNotEqual(board.commands.links, plugged, "the pointer the app tracked is gone with the USB link")
        XCTAssertEqual(board.status?.needsUSBHost, true)
        XCTAssertEqual(board.status?.needsWirelessPointer, false)
        let off = board.commands.links
        board.updateStatus(BoardStatus(usb: "ok"))
        XCTAssertEqual(board.commands.links, off, "coming back does not invalidate again")
        XCTAssertEqual(board.status?.inputReady, true)
    }

    func testWirelessPairingIsSeparateFromTheControlConnection() throws {
        let board = BoardLink(mock: true)
        let full = try XCTUnwrap(BoardStatus.decode(Data(#"{"board":"esp32s3","usb":"ok","hid":"off","ap":"streaming"}"#.utf8)))
        board.updateStatus(full)
        XCTAssertTrue(full.needsWirelessPointer)
        XCTAssertFalse(full.inputReady)
        board.updateStatus(BoardStatus(hid: "ok"))
        XCTAssertEqual(board.status?.inputReady, true)
        XCTAssertEqual(board.status?.ap, "streaming")
        let paired = board.commands.links
        board.updateStatus(BoardStatus(up: 200))
        XCTAssertEqual(board.status?.hid, "ok")
        board.updateStatus(BoardStatus(hid: "off"))
        XCTAssertNotEqual(board.commands.links, paired, "Losing the pointer while GATT stays connected must invalidate earlier actions")
        XCTAssertEqual(board.status?.needsWirelessPointer, true)
        XCTAssertEqual(board.status?.usb, "ok")
        board.updateStatus(BoardStatus(hid: "ok"))
        XCTAssertEqual(board.status?.needsWirelessPointer, false)
    }

    func testReconnectingFromAbsoluteUSBToBLEClearsUSBStatusAndPointerMode() {
        let board = BoardLink(mock: true)
        let net = NetConfig(mode: "ap")
        board.mockConnect(name: "board", net: net)
        let usb = BoardStatus(fw: .init([0, 2, 4]), heap: 81234, abs: 1, usb: "asleep")
        board.updateStatus(usb)
        XCTAssertEqual(board.status?.acceptsUSBRelease, true)

        board.setDisconnected()
        XCTAssertEqual(board.status, usb)
        board.mockConnect(name: "board", net: net)
        XCTAssertNil(board.status)
        board.updateStatus(BoardStatus(usb: "ok", hid: "off"))
        XCTAssertEqual(board.status?.acceptsUSBRelease, false)
        XCTAssertNil(board.status?.heap)
        XCTAssertNil(board.status?.abs)
        board.updateStatus(BoardStatus(hid: "ok"))
        XCTAssertEqual(board.status?.inputReady, true)
        XCTAssertNil(board.status?.abs)
    }

    func testCalibratedSetupCanContinueWithSleepingUSBButWaitsForWirelessInput() {
        let app = AppModel.shared, board = BoardLink(mock: true)
        let net = NetConfig(mode: "ap")
        // The page reads the calibration through AutoCalibrator.hasValidCalibration, which is the app's pointer.
        let pointer = app.pointer
        pointer.mockCalibrated(quality: 0.005)
        let view = OnboardingView(app: app, board: board, feed: app.feed, settings: app.settings,
                                  calibrator: AutoCalibrator(app: app), pointer: pointer, start: .act)
        func check(_ ready: Bool, line: UInt = #line) {
            XCTAssertEqual(view.pageDone, ready, line: line)
            XCTAssertEqual(view.primaryEnabled, ready, line: line)
        }

        board.mockConnect(name: "board", net: net)
        board.updateStatus(BoardStatus(usb: "asleep"))
        check(true)
        board.setDisconnected()
        check(true)
        board.mockConnect(name: "board", net: net)
        board.updateStatus(BoardStatus(usb: "ok", hid: "off"))
        check(false)
        board.updateStatus(BoardStatus(hid: "ok"))
        check(true)
        board.setDisconnected()
        XCTAssertNil(board.status)
        check(false)
        board.mockConnect(name: "board", net: net)
        check(false)
        board.updateStatus(BoardStatus(hid: "ok"))
        check(true)

        board.setDisconnected()
        board.updateStatus(BoardStatus(hid: "ok"))
        check(false)
        board.mockConnect(name: "board", net: net)
        check(true)
    }

    func testHIDCapabilityDoesNotDependOnBoardName() throws {
        for model in ["note4", "esp32s3"] {
            let status = try XCTUnwrap(BoardStatus.decode(Data("{\"board\":\"\(model)\",\"usb\":\"ok\"}".utf8)))
            XCTAssertFalse(status.isWirelessHID, "The board model alone must not imply wireless HID support")
            XCTAssertNil(status.inputState, "A named board without an input capability must not fall back to USB status")
            XCTAssertFalse(status.inputReady)
            XCTAssertFalse(status.acceptsUSBRelease)
            let paired = status.merged(with: BoardStatus(hid: "ok"))
            XCTAssertTrue(paired.isWirelessHID)
            XCTAssertTrue(paired.inputReady)
            XCTAssertFalse(paired.acceptsUSBRelease)
            XCTAssertEqual(paired.board, model)
        }
        let unnamedHID = BoardStatus(usb: "ok", hid: "off")
        XCTAssertTrue(unnamedHID.isWirelessHID)
        XCTAssertTrue(unnamedHID.needsWirelessPointer)
        XCTAssertFalse(unnamedHID.inputReady)
    }

    func testUSBStartupRetryKeepsWiredTimingAndSkipsWirelessInput() {
        XCTAssertEqual(AutoCalibrator.usbStartupRetry(BoardStatus(up: 15_000, usb: "ok"))?.delay, 45)
        XCTAssertEqual(AutoCalibrator.usbStartupRetry(BoardStatus(up: 75_000, usb: "ok"))?.delay, 10)
        XCTAssertNil(AutoCalibrator.usbStartupRetry(BoardStatus(up: 90_000, usb: "ok")))
        XCTAssertNil(AutoCalibrator.usbStartupRetry(BoardStatus(up: 15_000, usb: "off", hid: "ok")))
        XCTAssertNil(AutoCalibrator.usbStartupRetry(BoardStatus(up: 15_000, usb: "off", board: "unknown")))
    }

    func testMissingUSBHostOnlyBlocksUSBInput() {
        XCTAssertTrue(BoardStatus(usb: "off").needsUSBHost)
        XCTAssertFalse(BoardStatus(usb: "asleep").needsUSBHost)
        XCTAssertFalse(BoardStatus(usb: "off", hid: "ok").needsUSBHost)
        XCTAssertFalse(BoardStatus(usb: "off", hid: "off").needsUSBHost)
        XCTAssertFalse(BoardStatus(usb: "off", board: "unknown").needsUSBHost)
    }

    func testUSBUpdateRequiresAnIdentifiedUSBBoard() {
        XCTAssertFalse(BoardStatus().acceptsUSBRelease)
        XCTAssertFalse(BoardStatus(fw: .init([0, 2, 2]), usb: "off", board: "note4").acceptsUSBRelease)
        XCTAssertFalse(BoardStatus(usb: "ok", hid: "off").acceptsUSBRelease)
        XCTAssertFalse(BoardStatus(usb: "ok", board: "another-board").acceptsUSBRelease)
        let usb = BoardStatus(usb: "ok")
        XCTAssertTrue(usb.acceptsUSBRelease)
        XCTAssertTrue(usb.inputReady)
        XCTAssertFalse(usb.needsWirelessPointer)
        XCTAssertFalse(BoardStatus(usb: "asleep").inputReady)
        XCTAssertTrue(BoardStatus(usb: "asleep").acceptsUSBRelease)
    }

    func testStatusDecoding() throws {
        let json = #"{"up":123456,"rst":"power-on","heap":81234,"psram":6200000,"usb":"ok","net":"ap","ip":"192.168.4.1","sta":1,"ap":"streaming","w":480,"h":1040,"kbps":180,"fps":4.8,"idr":2000,"gop":42000,"ble":{"mtu":247,"phy":2,"kbps":350,"drop":0}}"#
        let s = try XCTUnwrap(BoardStatus.decode(Data(json.utf8)))
        XCTAssertEqual(s.ap, "streaming")
        XCTAssertEqual(s.ble?.mtu, 247)
        XCTAssertEqual(s.fps, 4.8)
    }

    func testLandingsSavedBeforeEveryGestureRehomedAreDropped() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let old = #"{"w":400,"h":800,"seen":{"x":[[0.5,0.52],[0.3,0.33]],"y":[]}}"#
        try Data(old.utf8).write(to: file)
        XCTAssertEqual(Pointer(device: FakeDevice(), calibrationFile: file).seen["x"]?.count, 0)
        XCTAssertTrue(Pointer(device: FakeDevice(), calibrationFile: file).calibrated)  // the calibration stays
        try Data(old.replacingOccurrences(of: "}}", with: "},\"v\":3}").utf8).write(to: file)
        XCTAssertEqual(Pointer(device: FakeDevice(), calibrationFile: file).seen["x"]?.count, 0, "v3 video samples left out the origin")
        try Data(old.replacingOccurrences(of: "}}", with: "},\"v\":4}").utf8).write(to: file)
        XCTAssertEqual(Pointer(device: FakeDevice(), calibrationFile: file).seen["x"]?.count, 2)
    }

    func testHomesOffsetFromTheCornerIsPartOfTheCalibration() async throws {
        // the probe fit of 2026-11-06: home left the pointer at x 0.142 (the rounded corner); the check missed by 14%
        let device = FakeDevice()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let pointer = Pointer(device: device, calibrationFile: file)
        let x = ProbeFit.Line(a: 0.00148, b: 0.142, rms: 0.0057), y = ProbeFit.Line(a: 0.00071, b: -0.009, rms: 0.0087)
        let samples = [150.0, 350, 77, 418, 248].map { u in (ux: u, uy: u, fx: 0.00148 * u + 0.142, fy: 0.00071 * u - 0.009) }
        pointer.applyProbe(x: x, y: y, samples: samples)
        try await pointer.point(0.5, 0.62)
        let move = try XCTUnwrap(device.sent.last).split(separator: " ").compactMap { Double($0) }
        XCTAssertEqual(0.00148 * move[0] + 0.142, 0.5, accuracy: 0.005)
        XCTAssertEqual(0.00071 * move[1] - 0.009, 0.62, accuracy: 0.005)
        XCTAssertEqual(Pointer(device: FakeDevice(), calibrationFile: file).origin.x, 0.142, accuracy: 1e-9)  // kept
    }

    /// Issue #96: a check that missed by ±49.8% (a span ~2x off, the pointer pinned at an edge) was kept and used.
    func testRejectedCalibrationIsNotSavedAndThePreviousOneStays() throws {
        XCTAssertGreaterThan(0.498, AutoCalibrator.rejectAbove)
        XCTAssertLessThanOrEqual(0.012, AutoCalibrator.rejectAbove)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let pointer = Pointer(device: FakeDevice(), calibrationFile: file)
        let good = ProbeFit.Line(a: 0.00148, b: 0.142, rms: 0.0057), goodY = ProbeFit.Line(a: 0.00071, b: -0.009, rms: 0.0087)
        pointer.applyProbe(x: good, y: goodY, samples: [])
        pointer.setQuality(0.011)
        let previous = pointer.snapshot(), span = pointer.span
        XCTAssertNotNil(previous)

        let bad = ProbeFit.Line(a: 0.003, b: 0, rms: 0.01)
        pointer.applyProbe(x: bad, y: bad, samples: [])
        pointer.setQuality(0.498)
        XCTAssertNotEqual(pointer.span, span)
        pointer.restore(previous)
        XCTAssertEqual(pointer.span, span)
        XCTAssertEqual(pointer.quality, 0.011)
        XCTAssertEqual(pointer.origin.x, 0.142, accuracy: 1e-9)
        let reloaded = Pointer(device: FakeDevice(), calibrationFile: file)  // what the next launch uses
        XCTAssertEqual(reloaded.span, span)
        XCTAssertEqual(reloaded.quality, 0.011)
    }

    func testRejectedFirstCalibrationLeavesNone() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let pointer = Pointer(device: FakeDevice(), calibrationFile: file)
        let previous = pointer.snapshot()
        XCTAssertNil(previous)
        pointer.applyProbe(x: ProbeFit.Line(a: 0.003, b: 0, rms: 0.01), y: ProbeFit.Line(a: 0.003, b: 0, rms: 0.01),
                           samples: [])
        pointer.setQuality(0.498)
        XCTAssertTrue(pointer.calibrated)
        pointer.restore(previous)
        XCTAssertFalse(pointer.calibrated)
        XCTAssertNil(pointer.quality)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(Pointer(device: FakeDevice(), calibrationFile: file).calibrated)
    }

    func testShortMovesAreScaledUpByTheSpeedCalibration() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let pointer = Pointer(device: FakeDevice(), calibrationFile: file)
        pointer.finishCalibration(x: 0.5, y: 0.25)
        XCTAssertTrue(pointer.paced(5, 0) == (5, 0))  // no speed calibration: as asked
        pointer.applySpeeds([(2, 0.5), (6, 0.8), (10, 1.3)])  // full speed is the reference, never stored
        XCTAssertEqual(pointer.ratio(atSpeed: 4), 0.65, accuracy: 1e-9)
        XCTAssertEqual(pointer.ratio(atSpeed: 1), 0.5)
        XCTAssertEqual(pointer.ratio(atSpeed: 10), 1)
        let (x, _) = pointer.paced(4, 0)  // one slow report: sent longer so it goes 4 at full speed's scale
        XCTAssertEqual(Double(x) * pointer.ratio(atSpeed: Double(x)), 4, accuracy: 0.6)
        XCTAssertTrue(pointer.paced(300, 0) == (300, 0))  // a long move runs at full speed
        XCTAssertEqual(Pointer(device: FakeDevice(), calibrationFile: file).gain.count, 2)  // saved
    }

    func testACalibrationUnderAnotherBoardPaceIsDoneAgain() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"w":400,"h":800,"v":3}"#.utf8).write(to: file)  // saved before the firmware answered "pace"
        let pointer = Pointer(device: FakeDevice(), calibrationFile: file)
        XCTAssertTrue(pointer.calibrated)  // no board yet
        pointer.boardPace = 1
        XCTAssertTrue(pointer.calibrated)  // old firmware: same moves
        pointer.boardPace = 2
        XCTAssertFalse(pointer.calibrated)  // one-speed moves go other distances
        pointer.finishCalibration(x: 0.5, y: 0.25)
        XCTAssertTrue(pointer.calibrated)
        let again = Pointer(device: FakeDevice(), calibrationFile: file)
        again.boardPace = 2
        XCTAssertTrue(again.calibrated)
    }

    func testScreenGeometryRoundTripsALandscapeLetterbox() {
        let geometry = ScreenGeometry(screenAspect: 1180.0 / 820, frameAspect: 480.0 / 1040, orientation: 3)
        let rect = geometry.contentRect
        XCTAssertEqual(rect.minX, 0, accuracy: 1e-9)  // a tall frame on a wide screen: the screen is a band across it
        XCTAssertGreaterThan(rect.minY, 0)
        for point in [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 1, y: 1)] {
            let back = geometry.screenPoint(fromFrame: geometry.framePoint(fromScreen: point))
            XCTAssertEqual(back.x, point.x, accuracy: 1e-9)
            XCTAssertEqual(back.y, point.y, accuracy: 1e-9)
        }
        XCTAssertFalse(geometry.contains(framePoint: CGPoint(x: 0.5, y: 0.01)))
        XCTAssertTrue(geometry.contains(framePoint: CGPoint(x: 0.5, y: 0.5)))
    }

    func testScreenGeometryRoundTripsAPillarbox() {
        let geometry = ScreenGeometry(screenAspect: 0.5, frameAspect: 2, orientation: 1)
        XCTAssertEqual(geometry.contentRect.minX, 0.375, accuracy: 1e-9)
        XCTAssertEqual(geometry.contentRect.width, 0.25, accuracy: 1e-9)
        let point = geometry.screenPoint(fromFrame: CGPoint(x: 0.45, y: 0.25))
        XCTAssertEqual(point.x, 0.3, accuracy: 1e-9)
        XCTAssertEqual(point.y, 0.25, accuracy: 1e-9)
        XCTAssertFalse(geometry.contains(framePoint: CGPoint(x: 0.1, y: 0.5)))
    }

    func testIPadCalibrationKeepsItsOrientationAndRefusesAnother() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let portrait = ScreenGeometry(screenAspect: 0.7, frameAspect: 0.7, orientation: 1)
        let landscape = ScreenGeometry(screenAspect: 1 / 0.7, frameAspect: 1 / 0.7, orientation: 3)
        let pointer = Pointer(device: FakeDevice(), calibrationFile: file)
        pointer.currentGeometry = { portrait }
        pointer.finishCalibration(x: 0.5, y: 0.25)
        let restored = Pointer(device: FakeDevice(), calibrationFile: file)
        XCTAssertTrue(restored.matches(geometry: portrait))
        XCTAssertFalse(restored.matches(geometry: landscape))
        restored.currentGeometry = { landscape }
        do {
            try await restored.point(0.5, 0.5)
            XCTFail("a rotated iPad must not move with the old calibration")
        } catch {}
        XCTAssertTrue((restored.device as? FakeDevice)?.sent.isEmpty ?? false)
    }

    /// iPad: each orientation keeps its own calibration; turning back loads it instead of asking again.
    func testIPadKeepsOneCalibrationPerOrientation() throws {
        let wasPad = DeviceKind.isPad
        DeviceKind.isPad = true
        defer { DeviceKind.isPad = wasPad }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("calibration.json")
        let portrait = ScreenGeometry(screenAspect: 0.695, frameAspect: 580.0 / 834, orientation: 1)
        let landscape = ScreenGeometry(screenAspect: 1 / 0.695, frameAspect: 1200.0 / 834, orientation: 3)
        let flipped = ScreenGeometry(screenAspect: 1 / 0.695, frameAspect: 1200.0 / 834, orientation: 4)
        var current = portrait
        let pointer = Pointer(device: FakeDevice(), calibrationFile: file)
        pointer.currentGeometry = { current }
        pointer.finishCalibration(x: 0.5, y: 0.25)  // portrait: 400 x 800
        current = landscape
        pointer.adopt(current)
        XCTAssertFalse(pointer.calibrated, "landscape has no calibration yet")
        pointer.finishCalibration(x: 0.25, y: 0.5)  // landscape: 800 x 400
        current = portrait
        pointer.adopt(current)
        XCTAssertEqual(pointer.span, Pointer.Span(w: 400, h: 800))
        XCTAssertTrue(pointer.matches(geometry: portrait))
        let later = Pointer(device: FakeDevice(), calibrationFile: file)  // after a relaunch
        later.currentGeometry = { flipped }
        later.adopt(flipped)  // landscape the other way round: the same calibration
        XCTAssertEqual(later.span, Pointer.Span(w: 800, h: 400))
        XCTAssertTrue(later.matches(geometry: flipped))
    }

    /// iPhone: the pointer sends exactly what it always sent (no geometry, no iPad homing, diagonal moves).
    func testIPhonePointerCommandsAreUnchanged() async throws {
        let wasPad = DeviceKind.isPad
        DeviceKind.isPad = false
        defer { DeviceKind.isPad = wasPad }
        let device = FakeDevice()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let pointer = Pointer(device: device, calibrationFile: file)
        pointer.finishCalibration(x: 0.5, y: 0.25)  // span 400 x 800
        try await pointer.point(0.75, 0.5)
        try await pointer.reset()
        XCTAssertEqual(device.sent, ["release", "home", "move 300 400", "release", "home"])
        device.sent = []
        try await pointer.probe(150, 150)
        try await pointer.probe(150, 150, then: (80, 80, 4))
        try await pointer.parkForManualCalibration()
        XCTAssertEqual(device.sent, ["home", "move 150 150", "home", "move 150 150", "move 80 80 4",
                                     "release", "home", "move 200 200"])
    }

    func testIPadPointerStepsOffTheTopEdgeBeforeHoming() async throws {
        let wasPad = DeviceKind.isPad
        DeviceKind.isPad = true
        defer { DeviceKind.isPad = wasPad }
        let device = FakeDevice()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let pointer = Pointer(device: device, calibrationFile: file)
        pointer.finishCalibration(x: 0.5, y: 0.25)  // span 400 x 800
        try await pointer.reset()  // position unknown: it may rest at the top edge
        try await pointer.reset()  // at home, on the top edge
        XCTAssertEqual(device.sent, ["release", "move 0 150", "home", "release", "move 0 150", "home"])
        device.sent = []
        try await pointer.point(0.75, 0.5)  // a new link: released and homed first; then one axis at a time
        XCTAssertEqual(device.sent, ["release", "move 0 150", "home", "move 0 400", "move 300 0"])
        device.sent = []
        try await pointer.reset()  // well below the edge: the flick into the corner arrives from below
        XCTAssertEqual(device.sent, ["release", "home"])
    }

    /// iPad over Bluetooth (HomeTuning): blind homes push up the tuned count; with a known position the pointer goes
    /// to the left edge only and up the measured way, so it pushes at the top edge only briefly. Probes stay blind.
    func testBluetoothIPadHomesWithTheTunedCountOrTheMeasuredWay() async throws {
        let wasPad = DeviceKind.isPad
        DeviceKind.isPad = true
        defer { DeviceKind.isPad = wasPad }
        let device = FakeDevice()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let pointer = Pointer(device: device, calibrationFile: file)
        pointer.homeUp = { 7 }
        pointer.finishCalibration(x: 0.5, y: 0.25)  // span 400 x 800
        try await pointer.reset()  // position unknown: blind, stepping off the top edge first
        XCTAssertEqual(device.sent, ["release", "move 0 150", "home 4 7"])
        try await pointer.point(0.75, 0.5)
        device.sent = []
        try await pointer.reset()  // known (300, 400): left edge, then up 400 + a 4% margin of 800
        XCTAssertEqual(Array(device.sent.prefix(2)), ["release", "home 4 0"])
        XCTAssertEqual(device.sent.count, 3)
        XCTAssertTrue(device.sent[2].hasPrefix("move 0 -432"), device.sent[2])
        device.sent = []
        try await pointer.probe(150, 350)  // calibration needs the real corner, known position or not
        XCTAssertEqual(device.sent, ["move 0 150", "home 4 7", "move 0 350", "move 150 0"])
        pointer.homeUp = { nil }  // a USB board on the iPad: as before
        device.sent = []
        try await pointer.reset()
        XCTAssertEqual(device.sent, ["release", "move 0 150", "home"])
    }

    func testHomeTuningGoesDownAfterAPanelAndUpWhenShortWithinBounds() {
        let defaults = UserDefaults(suiteName: "HomeTuningTests-\(UUID().uuidString)")!
        XCTAssertEqual(HomeTuning.value(landscape: true, defaults: defaults), HomeTuning.start)
        XCTAssertEqual(HomeTuning.next(after: .panel, from: 25), 17)
        XCTAssertEqual(HomeTuning.next(after: .panel, from: 10), 7)
        XCTAssertEqual(HomeTuning.next(after: .panel, from: 5), HomeTuning.least)
        XCTAssertNil(HomeTuning.next(after: .panel, from: HomeTuning.least))
        XCTAssertEqual(HomeTuning.next(after: .short(0.03), from: 10), 13)
        XCTAssertNil(HomeTuning.next(after: .short(0.03), from: HomeTuning.most))
        HomeTuning.store(13, landscape: true, defaults: defaults)
        XCTAssertEqual(HomeTuning.value(landscape: true, defaults: defaults), 13)
        XCTAssertEqual(HomeTuning.value(landscape: false, defaults: defaults), HomeTuning.start, "each orientation its own")
        XCTAssertNotEqual(HomeTuning.key(landscape: true, model: "iPad15,3"), HomeTuning.key(landscape: true, model: "iPad16,1"))
    }

    func testIPadPointerMovesOneAxisAtATimeExceptMidDrag() async throws {
        let wasPad = DeviceKind.isPad
        DeviceKind.isPad = true
        defer { DeviceKind.isPad = wasPad }
        let device = FakeDevice()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let pointer = Pointer(device: device, calibrationFile: file)
        pointer.finishCalibration(x: 0.5, y: 0.25)
        try await pointer.point(0.75, 0.75)
        device.sent = []
        try await pointer.swipe(0.5, 0.5, 0.25, 0.25)
        let still = Array(repeating: ["move 0 1", "move 0 -1"], count: Pointer.stillReports).flatMap { $0 }
        XCTAssertEqual(device.sent, ["move 0 -200", "move -100 0", "press", "move -70 -140", "move -20 -40", "move -10 -20"]
                       + still + ["release"], "slows down in steps, then rests still before the lift")
        try await pointer.reset()  // at home, on the top edge: the probe steps off it first
        device.sent = []
        try await pointer.probe(150, 350, then: (80, 0, 4))  // calibration probes go the agent's own way
        XCTAssertEqual(device.sent, ["move 0 150", "home", "move 0 350", "move 150 0", "move 80 0 4"])
    }

    func testNetConfigEncodingForTheModeSwitch() throws {
        let sta = try JSONEncoder().encode(NetConfig(mode: "sta", ssid: "Home", pass: "secret"))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: sta) as? [String: String])
        XCTAssertEqual(obj, ["mode": "sta", "ssid": "Home", "pass": "secret"])  // nil ip/vtok are omitted
        let open = try JSONEncoder().encode(NetConfig(mode: "sta", ssid: "Cafe"))
        let openObj = try XCTUnwrap(JSONSerialization.jsonObject(with: open) as? [String: String])
        XCTAssertEqual(openObj, ["mode": "sta", "ssid": "Cafe"])  // no pass: an open network
        let back = try JSONEncoder().encode(NetConfig(mode: "ap"))
        XCTAssertEqual(String(data: back, encoding: .utf8), #"{"mode":"ap"}"#)
    }

    func testPointerRehomesEveryTenGestures() async throws {
        let device = FakeDevice()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let pointer = Pointer(device: device, calibrationFile: file)
        pointer.finishCalibration(x: 0.5, y: 0.25)  // span 400 x 800
        for _ in 0..<11 { try await pointer.point(0.5, 0.5) }
        XCTAssertEqual(device.sent.filter { $0 == "home" }.count, 2)
        XCTAssertEqual(device.sent[0], "release")  // a new link: let go first
        XCTAssertEqual(device.sent[2], "move 200 400")
    }

    private func pointer(_ device: HIDDevice) -> Pointer {
        Pointer(device: device, calibrationFile: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
    }

    func testAbsolutePointerSendsCoordinatesWithoutHomingOrCalibration() async throws {
        let device = FakeDevice()
        let pointer = pointer(device)
        XCTAssertFalse(pointer.calibrated)
        pointer.absolute = true
        XCTAssertTrue(pointer.calibrated)
        for _ in 0..<11 { try await pointer.tap(0.5, 0.25) }
        try await pointer.swipe(0.5, 0.75, 0.5, 0.25, hold: false)
        XCTAssertFalse(device.sent.contains("home"))
        XCTAssertEqual(Array(device.sent.prefix(3)), ["release", "abs 16384 8192", "click"])  // 16383.5 rounds to even
        XCTAssertEqual(Array(device.sent.suffix(4)), ["abs 16384 24575", "press", "abs 16384 8192 2000", "release"])  // hold: false
    }

    func testAListDragEasesInGlidesEasesOutAndRests() async throws {
        let device = FakeDevice()
        let pointer = pointer(device)
        pointer.absolute = true
        try await pointer.swipe(0.5, 0.7, 0.5, 0.4, hold: true)
        // slow first fifth, faster middle, slow last fifth: the list stops where the finger stops
        XCTAssertEqual(Array(device.sent.suffix(5)),
                       ["press", "abs 16384 20971 90", "abs 16384 15073 160", "abs 16384 13107 90", "release"])
    }

    func testAbsolutePointerGoesHomeWithAFlickNotTheHomeKey() async throws {
        let device = FakeDevice()
        let pointer = pointer(device)
        pointer.absolute = true
        try await pointer.goHome()
        XCTAssertFalse(device.sent.contains("homescreen"))
        XCTAssertEqual(Array(device.sent.suffix(3)), ["press", "abs 16384 4915 2000", "release"])  // a flick, not a glide
    }

    /// iOS ignores a Home key over Bluetooth HID (2026-11-19): a wireless board goes Home with the flick only.
    func testWirelessPointerGoesHomeWithAFlickNotTheHomeKey() async throws {
        let device = FakeDevice()
        let pointer = pointer(device)
        pointer.mockCalibrated(quality: 0.005)  // a relative pointer flicks only once calibrated
        pointer.swipeHome = true
        try await pointer.goHome()
        try await pointer.homeKey()
        XCTAssertFalse(device.sent.contains("homescreen"))
        XCTAssertFalse(device.sent.contains("key cmd+h"))
        XCTAssertEqual(device.sent.filter { $0.hasPrefix("flick 0 -") }.count, 2, "each goes Home with the flick up from the home bar")
    }

    /// A board flashed back to the relative mouse answers `abs` with an error: the pointer stops sending it.
    @MainActor private final class RelativeBoard: HIDDevice {
        var links = 1
        var connected = true
        var sent: [String] = []
        func send(_ command: String) async throws -> String {
            sent.append(command)
            if command.hasPrefix("abs ") { throw DeviceError(message: "err unknown command") }
            return ""
        }
        func waitConnected(_ timeout: TimeInterval) async -> Bool { true }
    }

    /// 2026-11-14: closing a call's Control Center with goHome flicked twice (the Live Captions panel's words stay
    /// on screen in every app) and the flicks collapsed the panel. The call script's home steps are the key alone.
    func testACallsHomeStepIsTheHomeKeyAlone() async throws {
        let device = FakeDevice()
        try await pointer(device).homeKey()
        XCTAssertEqual(device.sent, ["homescreen"])
        let homes = Calls.script("Call 10086 and ask the balance").compactMap(\.object).filter { $0["action"]?.str == "home" }
        XCTAssertFalse(homes.isEmpty)
        XCTAssertTrue(homes.allSatisfy { $0["keyOnly"]?.bool == true })
    }

    func testAbsolutePointerSwitchesBackWithAFlickAlongTheHomeBar() async throws {
        let device = FakeDevice()
        let pointer = pointer(device)
        pointer.absolute = true
        try await pointer.switchToPreviousApp()
        XCTAssertFalse(device.sent.contains { $0.hasPrefix("flick") || $0.hasPrefix("move") })
        XCTAssertEqual(Array(device.sent.suffix(3)), ["press", "abs 26214 32734 2000", "release"])
    }

    func testAPointerFlashedBackToRelativeStopsSendingAbs() async throws {
        let device = RelativeBoard()
        let pointer = pointer(device)
        pointer.absolute = true
        do {
            try await pointer.tap(0.5, 0.5)
            XCTFail("expected the board's error")
        } catch {}
        XCTAssertFalse(pointer.absolute)
        XCTAssertEqual(device.sent.filter { $0.hasPrefix("abs ") }.count, 1)
    }

    func testAbsIsNotCarriedOverFromAnOlderStatus() throws {
        let abs = try XCTUnwrap(BoardStatus.decode(Data(#"{"fw":"0.2.4","abs":1,"usb":"ok"}"#.utf8)))
        let relative = try XCTUnwrap(BoardStatus.decode(Data(#"{"fw":"0.2.4","usb":"ok"}"#.utf8)))
        XCTAssertEqual(abs.merged(with: relative).abs, nil)
        XCTAssertEqual(relative.merged(with: abs).abs, 1)
    }

    /// No screen to read the candidates from: each word's pinyin is committed with space (HanTyper); accents go
    /// through Option keys (Accents).
    func testChineseIsTypedAsPinyinWordByWordNeverPasted() async throws {
        let device = FakeDevice()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let pointer = Pointer(device: device, calibrationFile: file)
        try await pointer.type("hello world")
        try await pointer.type("卫生纸 3卷")
        try await pointer.type("café 👋")
        XCTAssertEqual(device.sent, ["type hello world", "type weishengzhi", "key space", "type  3", "type juan", "key space",
                                     "type caf", "key alt+e", "type e "])  // é through Option+e, the emoji dropped
    }

    func testShortStatusNotifyIsMergedWithTheFullRead() throws {
        let full = try XCTUnwrap(BoardStatus.decode(Data(#"{"up":1,"heap":81234,"usb":"ok","net":"ap","sta":2,"ap":"idle","kbps":180,"ble":{"mtu":247,"phy":2}}"#.utf8)))
        let short = try XCTUnwrap(BoardStatus.decode(Data(#"{"up":2,"usb":"asleep","net":"ap","ap":"streaming","ble":{"mtu":23}}"#.utf8)))
        let m = full.merged(with: short)
        XCTAssertEqual(m.up, 2)
        XCTAssertEqual(m.usb, "asleep")
        XCTAssertEqual(m.ap, "streaming")
        XCTAssertEqual(m.heap, 81234)  // kept from the full read
        XCTAssertEqual(m.sta, 2)
        XCTAssertEqual(m.ble?.mtu, 23)
        XCTAssertEqual(m.ble?.phy, 2)
    }

    func testFreshCalibrationHasNoDriftAndSurvivesARestart() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let pointer = Pointer(device: FakeDevice(), calibrationFile: file)
        XCTAssertFalse(pointer.calibrated)
        pointer.finishCalibration(x: 0.5, y: 0.25)
        XCTAssertEqual(pointer.drift, 0)
        let again = Pointer(device: FakeDevice(), calibrationFile: file)
        XCTAssertEqual(again.span, Pointer.Span(w: 400, h: 800))
    }

    func testUnusableSpanLeavesThePointerUncalibrated() {  // TestFlight 1.0.1 (9) crashed converting inf to Int
        XCTAssertNil(Pointer.Span(w: 200 / 0.0, h: 400))
        XCTAssertNil(Pointer.Span(w: .nan, h: 400))
        XCTAssertNil(Pointer.Span(w: -300.0, h: 400))
        XCTAssertEqual(Pointer.Span(w: 399.6, h: 800.2), Pointer.Span(w: 400, h: 800))
        let pointer = Pointer(device: FakeDevice(), calibrationFile: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json"))
        pointer.finishCalibration(x: 0, y: 0.25)
        XCTAssertFalse(pointer.calibrated)
    }

    func testModelSettingsNeedOnlyAnEndpoint() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let settings = Settings(defaults: defaults, info: nil)  // no build-time preset
        XCTAssertFalse(settings.isConfigured)  // nothing is built in
        settings.baseURL = "https://example.com/v1"
        XCTAssertTrue(settings.isConfigured)  // the model is picked from GET /models
        XCTAssertNil(settings.currentModel)
        settings.model = "some-model"
        XCTAssertEqual(settings.currentModel, "some-model")
    }

    /// One probe far off (a report dropped right after power-up) no longer drags the whole fit.
    func testRobustProbeFitDropsOneFarSample() throws {
        let good: [(Double, Double)] = [(150, 0.20), (350, 0.40), (250, 0.30), (550, 0.60), (750, 0.80)]
        let bad = good + [(450, 0.38)]  // should be 0.50
        let plain = try XCTUnwrap(ProbeFit.line(bad)), robust = try XCTUnwrap(ProbeFit.robustLine(bad))
        XCTAssertGreaterThan(plain.rms, 0.03)
        XCTAssertEqual(robust.a, 0.001, accuracy: 1e-6)
        XCTAssertEqual(robust.b, 0.05, accuracy: 1e-6)
        let noisy: [(Double, Double)] = [(150, 0.205), (350, 0.395), (250, 0.30), (550, 0.605), (750, 0.795)]
        XCTAssertEqual(ProbeFit.robustLine(noisy), ProbeFit.line(noisy), "small scatter is kept")
        XCTAssertEqual(ProbeFit.robustLine(Array(bad.suffix(4))), ProbeFit.line(Array(bad.suffix(4))), "too few to judge")
    }

    func testProbeFitRecoversScaleAndOffset() {
        let samples: [(Double, Double)] = [150.0, 350, 60].map { u in (u, 0.02 + u / 400) }
        let line = ProbeFit.line(samples)
        XCTAssertEqual(line?.a ?? 0, 1 / 400, accuracy: 1e-9)
        XCTAssertEqual(line?.b ?? 0, 0.02, accuracy: 1e-9)
        XCTAssertEqual(line?.rms ?? 1, 0, accuracy: 1e-9)
        XCTAssertEqual(line?.units(for: 0.52), 200)
        XCTAssertNil(ProbeFit.line([(100, 0.3)]))
        XCTAssertFalse(ProbeFit.usable(0.995))  // stuck at the edge
    }

    func testAppDepartureDoesNotMistakeHomeAcknowledgementForBackground() async throws {
        var background = false
        var attempts: [AppDeparture.Method] = []
        let departure = AppDeparture(isBackground: { background }, isConnected: { true }, attempt: { method in
            attempts.append(method)
            if method == .shortcut { background = true }
        }, waitForBackground: { _ in background })
        let left = try await departure.leave()
        XCTAssertTrue(left)
        XCTAssertEqual(attempts, [.swipe, .homeKey, .shortcut])
    }

    func testAppDepartureUnsupportedHomeKeyStillTriesShortcut() async throws {
        var background = false
        var attempts: [AppDeparture.Method] = []
        var failures = 0
        let departure = AppDeparture(isBackground: { background }, isConnected: { true }, attempt: { method in
            attempts.append(method)
            if method == .homeKey { throw DeviceError(message: "unsupported") }
            if method == .shortcut { background = true }
        }, waitForBackground: { _ in background }, failed: { _, _ in failures += 1 })
        let left = try await departure.leave()
        XCTAssertTrue(left)
        XCTAssertEqual(attempts, [.swipe, .homeKey, .shortcut])
        XCTAssertEqual(failures, 1)
    }

    func testAppDepartureReconnectsAndRetriesTheSameMethod() async throws {
        var connected = true
        var background = false
        var attempts: [AppDeparture.Method] = []
        var reconnects = 0
        let departure = AppDeparture(isBackground: { background }, isConnected: { connected }, attempt: { method in
            attempts.append(method)
            if attempts.count == 1 { connected = false; throw DeviceError(message: "link lost") }
            background = true
        }, waitForBackground: { _ in background }, waitForConnection: {
            reconnects += 1
            connected = true
        })
        let left = try await departure.leave()
        XCTAssertTrue(left)
        XCTAssertEqual(attempts, [.swipe, .swipe])
        XCTAssertEqual(reconnects, 1)
    }

    func testAppDepartureCancellationDoesNotSendAnotherGesture() async {
        var attempts: [AppDeparture.Method] = []
        var waits = 0
        let departure = AppDeparture(isBackground: { false }, isConnected: { true }, attempt: { method in
            attempts.append(method)
            throw CancellationError()
        }, waitForBackground: { _ in waits += 1; return false })
        do {
            _ = try await departure.leave()
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error") }
        XCTAssertEqual(attempts, [.swipe])
        XCTAssertEqual(waits, 0)
    }

    func testAppDepartureCancellationInterruptsBackgroundWait() async {
        let waiting = expectation(description: "Waiting for iOS background state")
        var attempts: [AppDeparture.Method] = []
        let departure = AppDeparture(isBackground: { false }, isConnected: { true }, attempt: { attempts.append($0) },
                                     waitForBackground: { _ in
            waiting.fulfill()
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return false
        })
        let job = Task { try await departure.leave() }
        await fulfillment(of: [waiting], timeout: 1)
        job.cancel()
        do {
            _ = try await job.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error") }
        XCTAssertEqual(attempts, [.swipe])
    }

    func testAppDepartureFailsBeforeGestureWhenBoardDisconnects() async {
        var attempts = 0
        let departure = AppDeparture(isBackground: { false }, isConnected: { false }, attempt: { _ in attempts += 1 },
                                     waitForBackground: { _ in false })
        do {
            _ = try await departure.leave()
            XCTFail("Expected board failure")
        } catch { XCTAssertTrue(error.localizedDescription.contains("board disconnected")) }
        XCTAssertEqual(attempts, 0)
    }

    func testCalibrationModelMeasuresTheRestingPointerDuringSetupAndVerification() async throws {
        let device = FakeDevice(), screen = FakeScreen()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let pointer = Pointer(device: device, calibrationFile: file, screen: screen)
        var x = 0, y = 0
        var positions: [Data: CGPoint] = [:]
        device.onSend = { command in
            let parts = command.split(separator: " ")
            if command == "home" { x = 0; y = 0 }
            guard parts.first == "move" else { return }
            let dx = Int(parts[1])!, dy = Int(parts[2])!
            x += dx
            y += dy
            let position = CGPoint(x: Double(x) / 400, y: Double(y) / 800)
            // Change the background during the nudge to simulate animation that hides the pointer in the pixel diff.
            let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 200)).image { context in
                (dx == Pointer.nudge ? UIColor.black : .white).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 100, height: 200))
                UIColor.red.setFill()
                context.fill(CGRect(x: position.x * 100, y: position.y * 200, width: 3, height: 3))
            }.jpegData(compressionQuality: 0.9)!
            positions[image] = position
            screen.frame = image
            screen.updated = now()
        }
        var readings: [CGPoint] = []
        pointer.locate = { image in
            guard let position = positions[image] else { return nil }
            readings.append(position)
            return position
        }

        let calibrated = try await pointer.startCalibration()
        XCTAssertTrue(calibrated)
        XCTAssertEqual(readings, [CGPoint(x: 0.375, y: 0.1875), CGPoint(x: 0.875, y: 0.4375)])
        // Load a known calibration so errors in calibration and verification cannot cancel each other out.
        pointer.finishCalibration(x: 0.5, y: 0.25)
        let error = try await pointer.verify()
        XCTAssertEqual(error, 0)
        XCTAssertEqual(readings.last, CGPoint(x: 0.5, y: 0.62))
    }

    func testDeleteKeyIsSentAsBackspace() async throws {
        let device = FakeDevice()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        try await Pointer(device: device, calibrationFile: file).key("cmd+delete")
        XCTAssertEqual(device.sent.last, "key cmd+backspace")
    }

    func testHomeKeyThatLeavesTheScreenUnchangedIsFollowedByTheFlick() async throws {
        let device = FakeDevice(), screen = FakeScreen()
        screen.frame = ReplayTests.screen(CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let pointer = Pointer(device: device, calibrationFile: file, screen: screen)
        pointer.finishCalibration(x: 0.5, y: 0.25)
        try await pointer.goHome()
        XCTAssertEqual(device.sent.first, "homescreen")
        XCTAssertEqual(device.sent.last?.hasPrefix("flick "), true)  // the sheet stayed: flicked up from the home bar
    }

    func testPhysicalHomeSwipeDoesNotUseAcknowledgedHomeKey() async throws {
        let device = FakeDevice()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let pointer = Pointer(device: device, calibrationFile: file)
        pointer.finishCalibration(x: 0.5, y: 0.25)
        try await pointer.homeSwipe()
        XCTAssertFalse(device.sent.contains("homescreen"))
        XCTAssertFalse(device.sent.contains("key cmd+h"))
        XCTAssertEqual(device.sent.suffix(2), ["move 0 80", "flick 0 -680"])  // past the bottom edge, then up 85% in one
        XCTAssertEqual(pointer.flickInOne, true)
    }

    /// Firmware before 0.2.5 answers `flick` with "unknown command": press, move, release, and no flick again.
    func testOldFirmwareGetsTheThreeCommandFlick() async throws {
        let device = FakeDevice()
        device.reject = ["flick"]
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let pointer = Pointer(device: device, calibrationFile: file)
        pointer.finishCalibration(x: 0.5, y: 0.25)
        try await pointer.homeSwipe()
        XCTAssertEqual(device.sent.suffix(3), ["press", "move 0 -680", "release"])
        XCTAssertEqual(pointer.flickInOne, false)
        device.sent = []
        try await pointer.homeSwipe()
        XCTAssertFalse(device.sent.contains { $0.hasPrefix("flick") })
    }


    func testStartupFrameCapturedAfterBackgroundBeforePollingIsAccepted() {
        let boundary = StartupFrameBoundary(requestedAt: 10)
        // Background notification at 11; Home image at 11.05; polling observes it at 11.1.
        XCTAssertTrue(boundary.accepts(capturedAt: 11.05, backgroundEnteredAt: 11))
        XCTAssertEqual(boundary.threshold(backgroundEnteredAt: 11), 11)
    }

    func testStartupFrameRejectsOwnAppCaptureFromBeforeActualBackground() {
        let boundary = StartupFrameBoundary(requestedAt: 10)
        XCTAssertFalse(boundary.accepts(capturedAt: 10.99, backgroundEnteredAt: 11))
        XCTAssertFalse(boundary.accepts(capturedAt: 11, backgroundEnteredAt: 11))
        XCTAssertFalse(boundary.accepts(capturedAt: 0, backgroundEnteredAt: 11))
    }

    func testStartupFrameFallsBackToDepartureRequestWhenTransitionIsUnknown() {
        let boundary = StartupFrameBoundary(requestedAt: 10)
        XCTAssertEqual(boundary.threshold(backgroundEnteredAt: 0), 10)
        XCTAssertEqual(boundary.threshold(backgroundEnteredAt: 8), 10)  // an earlier app session
        XCTAssertFalse(boundary.accepts(capturedAt: 9.99, backgroundEnteredAt: 0))
        XCTAssertTrue(boundary.accepts(capturedAt: 10.01, backgroundEnteredAt: 0))
    }

    func testStartupAlreadyInBackgroundCanUseItsExistingHomeFrame() {
        let boundary = StartupFrameBoundary(requestedAt: 8)  // already-backgrounded caller's recorded transition
        XCTAssertTrue(boundary.accepts(capturedAt: 9, backgroundEnteredAt: 8))
        XCTAssertFalse(boundary.accepts(capturedAt: 9, backgroundEnteredAt: 11))  // a new app visit supersedes it
    }

}
