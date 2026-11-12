import UIKit
import XCTest
@testable import IPhoneAgent

/// The same action again and again while the screen stays much the same: the run asks instead of going on.
/// Also the robustness around it: a far reading that stays put, and a Home key that may not take effect.
@MainActor final class NoProgressTests: XCTestCase {
    private func tap(_ x: Double, _ y: Double) -> JObject { ["action": .str("tap"), "x": .num(x), "y": .num(y)] }

    func testTheSameGesturesWithinAFewUnitsAreTheSame() {
        XCTAssertTrue(NoProgress.same([tap(500, 500)], [tap(520, 480)]))
        XCTAssertFalse(NoProgress.same([tap(500, 500)], [tap(540, 500)]))
        XCTAssertFalse(NoProgress.same([tap(500, 500)], [tap(500, 500), tap(500, 500)]))
        let type: (String) -> JObject = { ["action": .str("type"), "text": .str($0)] }
        XCTAssertFalse(NoProgress.same([type("a")], [type("b")]))
        XCTAssertTrue(NoProgress.same([["action": .str("home")]], [["action": .str("home")]]))
    }

    func testOnlyRepeatsWithoutABigChangeCount() {
        var p = NoProgress()
        XCTAssertFalse(p.note([tap(500, 500)], big: true))
        for _ in 1..<NoProgress.limit { XCTAssertFalse(p.note([tap(505, 500)], big: false)) }
        XCTAssertFalse(p.note([tap(500, 500)], big: true), "a big change is progress")
        for _ in 1..<NoProgress.limit { XCTAssertFalse(p.note([tap(500, 500)], big: false)) }
        XCTAssertTrue(p.note([tap(500, 500)], big: false))
        XCTAssertEqual(p.repeats, 0, "counted again from zero")
    }

    private func run(_ reply: @escaping (Int) -> String) async -> (AgentLoop, FakeGestures, [String]) {
        let model = SystemRecorder(reply)
        let screen = FakeScreen(), phone = FakeGestures()
        screen.frame = AgentTests.jpeg()  // never changes
        phone.pointerVisible = true  // the touch probe finds the pointer
        let agent = AgentLoop(phone: phone, screen: screen, actor: model, planner: model, trace: nil)
        var asked: [String] = []
        agent.onHelp = { reason in asked.append(reason); return .stop }
        await agent.run()
        return (agent, phone, asked)
    }

    func testTheSameTapOnAStillScreenAsksLongBeforeTheStallLimit() async {
        let (agent, _, asked) = await run { _ in "THINK: try\nDO: tap 500 500" }
        XCTAssertEqual(asked, [NoProgress.reason])
        XCTAssertEqual(agent.steps.filter { $0["action"]?.str == "tap" }.count, NoProgress.limit + 1)
        XCTAssertTrue(NoProgress.reason.hasPrefix(AgentLoop.stallReason), "the same help buttons, a stall for the free line")
        let end = RunEnd(steps: [["action": .str("fail"), "reason": .str(NoProgress.reason)]], moves: 5, calls: 5, firmware: nil)
        XCTAssertEqual(end.reason, .stall)
    }

    func testHomeAgainAfterAHomeThatChangedLittleFlicks() async {
        let (_, phone, asked) = await run { _ in "THINK: leave\nDO: home" }
        XCTAssertEqual(phone.homeAgain, [false] + Array(repeating: true, count: NoProgress.limit),
                       "the first Home may be on the Home Screen already")
        XCTAssertEqual(asked, [NoProgress.reason])
    }

    // MARK: Pointer

    func testAFarReadingThatStaysPutWhileTargetsMoveIsNotThePointer() {
        let last = (target: CGPoint(x: 0.2, y: 0.3), found: CGPoint(x: 0.7, y: 0.5))
        XCTAssertTrue(Pointer.stuckReading(CGPoint(x: 0.71, y: 0.5), target: CGPoint(x: 0.5, y: 0.8), last: last))
        XCTAssertFalse(Pointer.stuckReading(CGPoint(x: 0.71, y: 0.5), target: CGPoint(x: 0.25, y: 0.3), last: last),
                       "the same target again: the pointer may really be stuck there")
        XCTAssertFalse(Pointer.stuckReading(CGPoint(x: 0.4, y: 0.5), target: CGPoint(x: 0.5, y: 0.8), last: last))
    }

    private func frame(_ mark: CGRect?, block: CGRect = CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3)) -> Data {
        let size = CGSize(width: 180, height: 390)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            UIColor.black.setFill()
            ctx.fill(CGRect(x: block.minX * size.width, y: block.minY * size.height,
                            width: block.width * size.width, height: block.height * size.height))
            if let mark { UIColor.red.setFill(); ctx.fill(mark) }
        }.jpegData(compressionQuality: 0.9)!
    }

    /// Home pressed with the screen turning into `after`; true = the flick up from the home bar followed.
    private func home(to after: Data, again: Bool) async throws -> Bool {
        let device = FakeDevice(), screen = FakeScreen()
        screen.frame = frame(nil)
        device.onSend = { if $0 == "homescreen" { screen.frame = after } }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let pointer = Pointer(device: device, calibrationFile: file, screen: screen)
        pointer.finishCalibration(x: 0.5, y: 0.25)
        try await pointer.goHome(again: again)
        XCTAssertEqual(device.sent.first, "homescreen")
        return device.sent.contains { $0.hasPrefix("flick ") }
    }

    func testTheHomeFlickFollowsUnlessTheAppWasLeft() async throws {
        let small = frame(CGRect(x: 120, y: 300, width: 30, height: 6))  // a clock ticking, a caret
        XCTAssertTrue(Vision.changed(frame(nil), small))
        XCTAssertFalse(Vision.bigChange(frame(nil), small))
        let flickedOnce = try await home(to: small, again: false)
        XCTAssertFalse(flickedOnce, "maybe on the Home Screen already: no App Switcher")
        let flickedAgain = try await home(to: small, again: true)
        XCTAssertTrue(flickedAgain, "Home twice, changing little: the key did not take effect")
        let left = try await home(to: frame(nil, block: CGRect(x: 0.1, y: 0.6, width: 0.8, height: 0.3)), again: true)
        XCTAssertFalse(left, "the app was left")
    }
}
