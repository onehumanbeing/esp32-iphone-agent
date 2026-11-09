import UIKit
import XCTest
@testable import IPhoneAgent

@MainActor final class KeyboardHandoffTests: XCTestCase {
    func testVisibleOrUnfocusedScreensNeedNoInput() async throws {
        for answer in ["VISIBLE", "NO_INPUT"] {
            let device = FakeDevice(), screen = HandoffScreen()
            try await KeyboardHandoff.restore(device: device, screen: screen, model: FakeModel { _ in answer }, refresh: screen.refresh)
            XCTAssertTrue(device.sent.isEmpty)
        }
    }

    func testFocusedFieldTogglesOnceAndVerifiesTheNewImage() async throws {
        let device = FakeDevice(), screen = HandoffScreen()
        let hidden = screen.frame, visible = HandoffScreen.picture(.white)
        device.onSend = { _ in screen.frame = visible }
        let model = FakeModel { $0 == 1 ? "HIDDEN_FOCUSED" : "VISIBLE" }
        try await KeyboardHandoff.restore(device: device, screen: screen, model: model, refresh: screen.refresh)
        XCTAssertEqual(model.images, [hidden, visible])
        XCTAssertEqual(device.sent, ["key eject"])
    }

    func testUnknownStateAndFailedVerificationNeverRepeatEject() async {
        for answers in [["UNKNOWN"], ["VISIBLE\nDO: key eject"], ["HIDDEN_FOCUSED", "HIDDEN_FOCUSED"]] {
            let device = FakeDevice(), screen = HandoffScreen()
            let model = FakeModel { answers[min($0 - 1, answers.count - 1)] }
            do {
                try await KeyboardHandoff.restore(device: device, screen: screen, model: model, refresh: screen.refresh)
                XCTFail("不能报告未确认的键盘状态")
            } catch {}
            XCTAssertEqual(device.sent, answers.count == 2 ? ["key eject"] : [])
        }
    }

    func testScreenOrLinkChangeDuringClassificationCancelsTheToggle() async {
        for lostLink in [false, true] {
            let device = FakeDevice(), screen = HandoffScreen()
            let model = FakeModel { _ in
                if lostLink { device.links += 1 } else { screen.frame = HandoffScreen.picture(.white) }
                return "HIDDEN_FOCUSED"
            }
            do {
                try await KeyboardHandoff.restore(device: device, screen: screen, model: model, refresh: screen.refresh)
                XCTFail("不能依据过期画面切换")
            } catch {}
            XCTAssertTrue(device.sent.isEmpty)
        }
    }

    func testOldImageCannotConfirmThePostToggleState() async {
        let device = FakeDevice(), screen = HandoffScreen()
        device.onSend = { _ in screen.freeze = true }
        let model = FakeModel { $0 == 1 ? "HIDDEN_FOCUSED" : "VISIBLE" }
        do {
            try await KeyboardHandoff.restore(device: device, screen: screen, model: model, refresh: screen.refresh)
            XCTFail("必须取得晚于动作的画面")
        } catch {}
        XCTAssertEqual(device.sent, ["key eject"])
        XCTAssertEqual(model.images.count, 1)
    }

    func testQueuedEjectIsAbandonedWhenTheUserReopensTheControlApp() async throws {
        let board = FakeBoard(), channel = CommandChannel(transport: board), screen = HandoffScreen()
        board.channel = channel
        board.dropReplyOnceOn = "ping"
        let occupied = expectation(description: "命令锁已被心跳占用")
        board.onCommand = { if $0 == "ping" { occupied.fulfill() } }
        let ping = Task { try await channel.send("ping") }
        await fulfillment(of: [occupied], timeout: 2)

        let verified = expectation(description: "两次截图一致，切换正在等待命令锁")
        var targetApp = true, refreshes = 0
        let handoff = Task {
            try await KeyboardHandoff.restore(device: channel, screen: screen,
                                               model: FakeModel { _ in "HIDDEN_FOCUSED" },
                                               stillInTargetApp: { targetApp }) {
                screen.refresh()
                refreshes += 1
                if refreshes == 2 { verified.fulfill() }
            }
        }
        await fulfillment(of: [verified], timeout: 2)
        targetApp = false  // The user returned to the control app while the mirrored frame still looked the same.
        let id = try XCTUnwrap(board.lines.first?.split(separator: " ").first)
        channel.handleReply("\(id) ok")
        _ = try await ping.value
        do { try await handoff.value; XCTFail("回到控制 App 后不能发送切换") } catch {}
        XCTAssertEqual(board.lines.count, 1)
    }

    func testLateModelReplyCannotToggleAfterCancellation() async {
        let device = FakeDevice(), screen = HandoffScreen()
        let task = Task {
            let model = FakeModel { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return "HIDDEN_FOCUSED"
            }
            try await KeyboardHandoff.restore(device: device, screen: screen, model: model, refresh: screen.refresh)
        }
        do { try await task.value; XCTFail("已取消的判断不能继续执行") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(device.sent.isEmpty)
    }

    func testOnlyAnExplicitlyUnsupportedResetFallsBackToMouseRelease() async throws {
        for failure in [nil, "err unknown command", "err phone usb asleep (unlock the phone)"] {
            let board = ResetBoard(failure), channel = CommandChannel(transport: board)
            board.channel = channel
            do {
                try await channel.releaseForHandoff()
                XCTAssertNil(failure, "旧固件不能确认键盘及消费控制键已释放")
            } catch { XCTAssertNotNil(failure) }
            XCTAssertEqual(board.commands, failure == "err unknown command" ? ["reset", "release"] : ["reset"])
        }
    }

    func testLostAcknowledgementRetriesResetButNeverEject() async throws {
        for command in ["reset", "key eject"] {
            let board = FakeBoard(), channel = CommandChannel(transport: board)
            board.channel = channel
            board.timeoutOnceOn = command
            channel.onTimeout = { _ in }
            do { try await channel.send(command); XCTAssertEqual(command, "reset") }
            catch { XCTAssertEqual(command, "key eject"); XCTAssertTrue(error is BoardTimeout) }
            XCTAssertEqual(board.lines.count, command == "reset" ? 2 : 1)
        }
    }
}

@MainActor private final class HandoffScreen: ScreenSource {
    var live = true, freeze = false
    var frame: Data? = picture(.black)
    var capturedAt = now()
    var updated: Double { capturedAt }
    let aspect = 0.5

    func refresh() { if !freeze { capturedAt = now() } }
    func afterAction(since: Double, ignoring: [CGPoint]) async { refresh() }

    static func picture(_ color: UIColor) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 32, height: 64)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 64))
        }.jpegData(compressionQuality: 1)!
    }
}

@MainActor private final class ResetBoard: BoardTransport {
    let isConnected = true
    let failure: String?
    var commands: [String] = []
    weak var channel: CommandChannel?

    init(_ failure: String?) { self.failure = failure }
    func write(_ line: String) throws {
        let parts = line.split(separator: " ", maxSplits: 1)
        let command = String(parts[1])
        commands.append(command)
        channel?.handleReply("\(parts[0]) \(command == "reset" ? failure ?? "ok" : "ok")")
    }
    func dropLink() {}
}
