import UIKit
import XCTest
@testable import IPhoneAgent

/// A board that answers every command like the firmware does.
@MainActor final class FakeBoard: BoardTransport {
    var isConnected = true
    var lines: [String] = []
    var drops = 0
    var silent = false
    weak var channel: CommandChannel?

    func write(_ line: String) throws {
        lines.append(line)
        guard !silent else { return }
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let reply = parts[1] == "bad" ? "\(parts[0]) err unknown command" : "\(parts[0]) ok"
        Task { @MainActor in self.channel?.handleReply(reply) }
    }

    func dropLink() { drops += 1 }
}

/// Port of server/tests/test_device.py, with a fake BLE transport instead of a TCP socket.
@MainActor final class DeviceTests: XCTestCase {
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

    func testStatusDecoding() throws {
        let json = #"{"up":123456,"rst":"power-on","heap":81234,"psram":6200000,"usb":"ok","net":"ap","ip":"192.168.4.1","sta":1,"ap":"streaming","w":480,"h":1040,"kbps":180,"fps":4.8,"idr":2000,"gop":42000,"ble":{"mtu":247,"phy":2,"kbps":350,"drop":0}}"#
        let s = try XCTUnwrap(BoardStatus.decode(Data(json.utf8)))
        XCTAssertEqual(s.ap, "streaming")
        XCTAssertEqual(s.ble?.mtu, 247)
        XCTAssertEqual(s.fps, 4.8)
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

    func testChineseIsTypedAsPinyinNeverPasted() async throws {
        let device = FakeDevice()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let pointer = Pointer(device: device, calibrationFile: file)
        try await pointer.type("hello world")
        try await pointer.type("卫生纸 3卷")
        try await pointer.type("café 👋")
        XCTAssertEqual(device.sent, ["type hello world", "type weishengzhi 3juan", "type cafe"])
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
        XCTAssertEqual(device.sent.last, "release")  // the sheet stayed: flicked up from the home bar
    }

    func testPhysicalHomeSwipeDoesNotUseAcknowledgedHomeKey() async throws {
        let device = FakeDevice()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let pointer = Pointer(device: device, calibrationFile: file)
        pointer.finishCalibration(x: 0.5, y: 0.25)
        try await pointer.homeSwipe()
        XCTAssertTrue(device.sent.contains("press"))
        XCTAssertEqual(device.sent.last, "release")
        XCTAssertFalse(device.sent.contains("homescreen"))
        XCTAssertFalse(device.sent.contains("key cmd+h"))
        let press = try XCTUnwrap(device.sent.firstIndex(of: "press"))
        XCTAssertEqual(device.sent[press - 1], "move 0 80")  // pushed past the bottom edge first
        XCTAssertEqual(device.sent[press + 1], "move 0 -680")  // then up 85% of the height, with no end hold
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
