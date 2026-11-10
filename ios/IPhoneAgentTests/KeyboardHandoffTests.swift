import UIKit
import XCTest
@testable import IPhoneAgent

@MainActor final class KeyboardHandoffTests: XCTestCase {
    func testDisablingKeyboardRestorePersistsAndSkipsScreenshotsAndModelCalls() async throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = Settings(defaults: defaults, info: [:])
        XCTAssertTrue(settings.restoreKeyboardAfterRun)
        settings.restoreKeyboardAfterRun = false

        let reopened = Settings(defaults: defaults, info: [:])
        let device = FakeDevice(), screen = HandoffScreen(), model = FakeModel { _ in "HIDDEN_FOCUSED" }
        try await KeyboardHandoff.restore(device: device, screen: screen, model: model,
                                          enabled: { reopened.restoreKeyboardAfterRun }) {
            XCTFail("A disabled keyboard check must not request a screenshot")
        }
        XCTAssertTrue(model.images.isEmpty)
        XCTAssertTrue(device.sent.isEmpty)
    }

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
        let stop = AsyncStream<Void>.makeStream()
        stop.continuation.finish()
        try await KeyboardHandoff.finish(by: .now + .seconds(30), stop: stop.stream) {
            try await KeyboardHandoff.restore(device: device, screen: screen, model: model, refresh: screen.refresh)
        }
        XCTAssertEqual(model.images, [hidden, visible])
        XCTAssertEqual(device.sent, ["key eject"])
    }

    func testStopBeforeOrDuringKeyboardCheckShortensTheWait() async {
        for stoppedBeforeRelease in [true, false] {
            let stop = AsyncStream<Void>.makeStream()
            if stoppedBeforeRelease { stop.continuation.finish() }
            let checking = expectation(description: "Asked for the current keyboard state")
            let ended = expectation(description: "Stopped before the normal deadline")
            let device = FakeDevice(), screen = HandoffScreen(), model = SlowModel()
            model.delay = 10_000_000_000
            let result = Task {
                defer { ended.fulfill() }
                try await KeyboardHandoff.finish(by: .now + .seconds(4), stop: stop.stream, stopGrace: .milliseconds(20)) {
                    try await KeyboardHandoff.restore(device: device, screen: screen, model: model) {
                        screen.refresh()
                        checking.fulfill()
                    }
                }
            }
            await fulfillment(of: [checking], timeout: 2)
            stop.continuation.finish()
            await fulfillment(of: [ended], timeout: 2)
            do { try await result.value; XCTFail("Expected the slow keyboard check to be cancelled") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertTrue(model.cancelled)
            XCTAssertTrue(device.sent.isEmpty)
        }
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
        let unknown = "err unknown command", asleep = "err phone usb asleep (unlock the phone)"
        let cases: [(String?, String?, HandoffRelease?)] = [
            (nil, nil, .allInputs), (unknown, nil, .leftMouseButtonOnly),
            (asleep, nil, nil), (unknown, asleep, nil)
        ]
        for (resetFailure, releaseFailure, expected) in cases {
            let board = ResetBoard(resetFailure, releaseFailure), channel = CommandChannel(transport: board)
            board.channel = channel
            do {
                let release = try await channel.releaseForHandoff()
                XCTAssertEqual(release, expected)
            } catch {
                XCTAssertNil(expected)
                XCTAssertEqual((error as? DeviceError)?.message, asleep)
            }
            XCTAssertEqual(board.commands, resetFailure == unknown ? ["reset", "release"] : ["reset"])
        }
    }

    func testLegacyBoardReleasesEveryTimeButShowsOneNoticePerConnection() async throws {
        let board = ResetBoard("err unknown command"), channel = CommandChannel(transport: board)
        board.channel = channel
        var lastNoticeLink: Int?
        for reconnect in [true, false, true] {
            if reconnect { channel.linkUp() }
            let release = try await channel.releaseForHandoff()
            XCTAssertEqual(release, .leftMouseButtonOnly)
            XCTAssertEqual(release.notice(on: channel.links, lastShown: &lastNoticeLink) != nil, reconnect)
        }
        XCTAssertEqual(board.commands, ["reset", "release", "reset", "release", "reset", "release"])
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
    let resetFailure: String?, releaseFailure: String?
    var commands: [String] = []
    weak var channel: CommandChannel?

    init(_ resetFailure: String?, _ releaseFailure: String? = nil) {
        self.resetFailure = resetFailure
        self.releaseFailure = releaseFailure
    }
    func write(_ line: String) throws {
        let parts = line.split(separator: " ", maxSplits: 1)
        let command = String(parts[1])
        commands.append(command)
        let failure = command == "reset" ? resetFailure : releaseFailure
        channel?.handleReply("\(parts[0]) \(failure ?? "ok")")
    }
    func dropLink() {}
}
