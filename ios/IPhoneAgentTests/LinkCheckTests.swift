import XCTest
@testable import IPhoneAgent

/// Rounds that change nothing check the link before the model acts again; a pointer far off target calibrates again.
@MainActor final class LinkCheckTests: XCTestCase {
    /// A screen that still counts as live but whose fresh frame never comes (nil: can't tell).
    private final class StillScreen: ScreenSource {
        var live = true
        var frame: Data? = AgentTests.jpeg()
        var updated = 0.0, capturedAt = 0.0, aspect = 0.46
        var fresh: Bool?
        var checks = 0
        func freshFrame() async -> Bool? { checks += 1; return fresh }
    }

    private final class SilentBoard: HIDDevice {
        var links = 1, connected = true
        func send(_ command: String) async throws -> String { throw BoardTimeout(command: command, seconds: 8) }
        func waitConnected(_ timeout: TimeInterval) async -> Bool { true }
    }

    func testDueEveryFewUnchangedRounds() {
        XCTAssertEqual((0...7).filter(LinkCheck.due), [LinkCheck.rounds, 2 * LinkCheck.rounds])
    }

    func testABoardThatDoesNotAnswerOrNoFreshFrameFailsTheCheck() async {
        let screen = StillScreen()
        let ok = await LinkCheck.check(FakeDevice(), screen)
        XCTAssertNil(ok, "a screen that can't tell passes")
        let silent = await LinkCheck.check(SilentBoard(), screen)
        XCTAssertEqual(silent, .board)
        screen.fresh = false
        let frozen = await LinkCheck.check(FakeDevice(), screen)
        XCTAssertEqual(frozen, .frames)
        screen.live = false
        let lost = await LinkCheck.check(FakeDevice(), screen)
        XCTAssertNil(lost, "a known loss is the recovery's")
    }

    private func run(fresh: Bool?, maxStalls: Int = 12) async -> (AgentLoop, StillScreen, FakeGestures) {
        let model = SystemRecorder { n in "THINK: try\nDO: tap \(100 + 50 * (n % 16)) 500" }  // the screen never changes
        let screen = StillScreen(), phone = FakeGestures()
        screen.fresh = fresh
        let agent = AgentLoop(phone: phone, screen: screen, actor: model, planner: model, trace: nil, maxStalls: maxStalls)
        agent.onHelp = { _ in .stop }
        await agent.run()
        return (agent, screen, phone)
    }

    func testAFrozenLinkEndsTheRunWithAConnectionMessage() async {
        let (agent, screen, phone) = await run(fresh: false)
        XCTAssertEqual(agent.steps.last?["reason"]?.str, LinkCheck.reason)
        XCTAssertEqual(agent.steps.filter { $0["action"]?.str == "tap" }.count, LinkCheck.rounds)
        XCTAssertEqual(screen.checks, 1)
        XCTAssertEqual(phone.probes, 0, "the link first")
        let end = RunEnd(steps: agent.steps, moves: 3, calls: 3, firmware: nil)
        XCTAssertEqual(end.reason, .blindMirroring)
    }

    func testAWorkingLinkLeavesTheRunAsBefore() async {
        let (agent, screen, _) = await run(fresh: true, maxStalls: 7)
        XCTAssertEqual(agent.steps.last?["action"]?.str, "stopped")
        XCTAssertEqual(agent.steps.filter { $0["action"]?.str == "tap" }.count, 7)
        XCTAssertEqual(screen.checks, 2, "after 3 and 6 unchanged rounds")
    }

    // MARK: recalibration

    func testAFarMissRecalibratesBeforeTheNextTapAtMostOnceInAWhile() {
        let pixels = CGSize(width: 1170, height: 2532), target = CGPoint(x: 0.5, y: 0.5)
        var r = Recalibration()
        r.measured(target, CGPoint(x: 0.55, y: 0.52), pixels: pixels)  // ~81 px: the usual correction
        XCTAssertFalse(r.tap())
        r.measured(target, CGPoint(x: 0.5, y: 0.545), pixels: pixels)  // ~114 px
        XCTAssertTrue(r.tap())
        XCTAssertFalse(r.tap(), "once per miss")
        while r.taps - (r.last ?? 0) < Recalibration.every {
            r.measured(target, CGPoint(x: 0.9, y: 0.9), pixels: pixels)
            XCTAssertFalse(r.tap(), "not again within \(Recalibration.every) taps")
        }
        r.measured(target, CGPoint(x: 0.9, y: 0.9), pixels: pixels)
        XCTAssertTrue(r.tap())
    }

    func testAFailedRecalibrationKeepsThePreviousOneAndRehomes() async throws {
        let device = FakeDevice(), screen = FakeScreen()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let pointer = Pointer(device: device, calibrationFile: file, screen: screen)
        pointer.finishCalibration(x: 0.5, y: 0.25)
        let span = pointer.span
        pointer.recalibration.measured(CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.9, y: 0.9), pixels: CGSize(width: 1170, height: 2532))
        try await pointer.tap(0.5, 0.5)
        XCTAssertEqual(device.sent.first, "home", "calibration starts from the corner")
        XCTAssertEqual(pointer.span, span, "the pointer is never seen on this screen: the old calibration stays")
        XCTAssertEqual(device.sent.last, "click")
    }
}
