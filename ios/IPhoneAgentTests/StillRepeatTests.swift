import UIKit
import XCTest
@testable import IPhoneAgent

/// The same gesture with a confirmed "no change" again and again: a line to the actor at two, one more look and then
/// the user at three. Only a frame from after the action confirms it; a moving screen or target never does.
@MainActor final class StillRepeatTests: XCTestCase {
    override func tearDown() {
        StepWaits.reset()
        StepWaits.lastMoving = -1000
        super.tearDown()
    }

    private func tap(_ x: Double, _ y: Double, still: Bool = true) -> JObject {
        var s: JObject = ["action": .str("tap"), "x": .num(x), "y": .num(y), "changed": .bool(false)]
        if still { s["still"] = .bool(true) }
        return s
    }

    private func gray(_ level: CGFloat) -> Data {
        let ctx = CGContext(data: nil, width: 60, height: 130, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: level, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 60, height: 130))
        return UIImage(cgImage: ctx.makeImage()!).jpegData(compressionQuality: 0.9)!
    }

    // MARK: what counts

    func testNoFrameAfterTheActionIsUnknownAndNotCounted() {
        let screen = FakeScreen()
        let agent = AgentLoop(phone: FakeGestures(), screen: screen, actor: nil, planner: nil, trace: nil)
        agent.lastActed = 100
        screen.updated = 99  // the last frame came before the action
        agent.steps = [tap(500, 500, still: false)]
        agent.confirmStill(quiet: [], final: false)
        XCTAssertNil(agent.steps[0]["still"], "the early look: a frame may still come")
        XCTAssertNil(agent.steps[0]["noframe"])
        agent.confirmStill(quiet: [])
        XCTAssertNil(agent.steps[0]["still"])
        XCTAssertEqual(agent.steps[0]["noframe"], .bool(true))
        XCTAssertEqual(AgentLoop.effect(agent.steps[0]), AgentLoop.staleEffect, "the model reads unknown, not \"did NOT change\"")
        XCTAssertTrue(agent.actorUserPrompt().contains(AgentLoop.staleNote))
        XCTAssertFalse(agent.actorUserPrompt().contains("\"noframe\""), "the flag stays out of the history")
        agent.steps = [tap(500, 500), tap(500, 500), agent.steps[0]]
        XCTAssertEqual(StillRepeat.count(agent.steps), 0, "an unknown result is not a third no-change")

        screen.capturedAt = 101  // a frame captured after the action
        agent.steps = [tap(500, 500, still: false)]
        agent.confirmStill(quiet: [])
        XCTAssertEqual(agent.steps[0]["still"], .bool(true))
        agent.verdict(true)
        XCTAssertNil(agent.steps[0]["still"], "a new verdict clears it")
    }

    func testMovingScreensAndSelfMovingTargetsAreNotCounted() {
        let agent = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: nil, planner: nil, trace: nil)
        StepWaits.moving = true  // a video, a map
        agent.steps = [tap(500, 500, still: false)]
        agent.confirmStill(quiet: [])
        XCTAssertNil(agent.steps[0]["still"])
        XCTAssertNil(agent.steps[0]["noframe"])
        StepWaits.moving = false
        agent.confirmStill(quiet: [CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)])  // the target moved by itself
        XCTAssertNil(agent.steps[0]["still"])
        agent.confirmStill(quiet: [CGRect(x: 0, y: 0, width: 0.2, height: 0.2)])  // something else moved
        XCTAssertEqual(agent.steps[0]["still"], .bool(true))
        StepWaits.moving = true
        agent.confirmStill(quiet: [])
        XCTAssertNil(agent.steps[0]["still"], "the rest of the wait found the screen moving: taken back")
    }

    func testAChangeOrAnUnknownInBetweenResets() {
        XCTAssertEqual(StillRepeat.count([tap(500, 500), tap(500, 500), tap(500, 500)]), 3)
        var changed = tap(500, 500, still: false)
        changed["changed"] = .bool(true)
        XCTAssertEqual(StillRepeat.count([tap(500, 500), changed, tap(500, 500)]), 1)
        XCTAssertEqual(StillRepeat.count([tap(500, 500), tap(500, 500, still: false), tap(500, 500)]), 1)
        let waited: JObject = ["action": .str("wait"), "changed": .bool(true)]
        XCTAssertEqual(StillRepeat.count([tap(500, 500), waited, tap(500, 500)]), 1, "the screen moved while waiting")
        for name in ["help", "takeover", "fail", "reconnected"] {
            XCTAssertEqual(StillRepeat.count([tap(500, 500), ["action": .str(name)], tap(500, 500)]), 1, name)
        }
        // nothing sent in between: a hold, a note, a wait that changed nothing, the plan
        let between: [JObject] = [["action": .str(RepeatGuard.action), "reason": .str("x")], ["action": .str("note"), "text": .str("x")],
                                  ["action": .str("wait"), "changed": .bool(false)], ["action": .str("plan"), "plan": .str("1. x")]]
        XCTAssertEqual(StillRepeat.count([tap(500, 500)] + between + [tap(500, 500)]), 2)
    }

    func testDifferentTargetsDoNotCountTogether() {
        XCTAssertEqual(StillRepeat.count([tap(500, 500), tap(600, 500)]), 1)
        XCTAssertEqual(StillRepeat.count([tap(500, 500), tap(515, 490)]), 2, "a few units off is the same target")
        XCTAssertEqual(StillRepeat.count([tap(500, 500), tap(600, 500), tap(500, 500)]), 1, "not in a row")
        let open: (String) -> JObject = { ["action": .str("open"), "app": .str($0), "changed": .bool(false), "still": .bool(true)] }
        XCTAssertEqual(StillRepeat.count([open("Maps"), open("Notes")]), 1)
        XCTAssertEqual(StillRepeat.count([open("Maps"), open("Maps")]), 2)
        let home: JObject = ["action": .str("home"), "changed": .bool(false), "still": .bool(true)]
        XCTAssertEqual(StillRepeat.count([home, home, home]), 3, "Home counts too")
        let say: JObject = ["action": .str("say"), "text": .str("hi"), "changed": .bool(false), "still": .bool(true)]
        XCTAssertEqual(StillRepeat.count([say, say]), 0, "say speaks into a call: the screen needn't move")
    }

    // MARK: what the run does

    func testTwoConfirmedNoChangesPutOneLineInTheNextRequest() {
        let agent = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: nil, planner: nil, trace: nil)
        agent.steps = [tap(500, 500)]
        XCTAssertEqual(StillRepeat.hint(agent.steps), "")
        XCTAssertFalse(agent.actorUserPrompt().contains("Did nothing"))
        agent.steps = [tap(500, 500), tap(505, 500)]
        let prompt = agent.actorUserPrompt()
        XCTAssertTrue(prompt.contains("Did nothing 2 times: `tap 505 500` was done 2 times in a row"))
        XCTAssertTrue(prompt.hasSuffix(StillRepeat.hint(agent.steps) + "\n\n" + AgentLoop.replyFormat), "next to the reply")
        XCTAssertFalse(prompt.contains("\"still\""), "the flag stays out of the history")
        XCTAssertEqual(StillRepeat.command(["action": .str("open"), "app": .str("Maps")]), "`open Maps`")
        XCTAssertEqual(StillRepeat.command(["action": .str("key"), "combo": .str("cmd+space")]), "`key cmd+space`")
    }

    /// End to end: a still screen with frames coming, the model tapping the same spot. Two: the line (the same calls
    /// as before, no extra one for it). Three: asked, never a fourth tap.
    func testTheThirdIsLookedAtOnceMoreThenTheUserIsAsked() async {
        let screen = FakeScreen(), phone = FakeGestures()
        screen.frame = AgentTests.jpeg()  // never changes
        phone.pointerVisible = true  // the touch probe finds the pointer
        let model = FakeModel { _ in "THINK: try\nDO: tap 500 500" }
        let agent = AgentLoop(phone: phone, screen: screen, actor: model, planner: nil, trace: nil)
        var asked: [String] = []
        agent.onHelp = { asked.append($0); return .stop }
        await agent.run()
        XCTAssertEqual(asked, [StillRepeat.reason])
        XCTAssertEqual(agent.steps.filter { $0["action"]?.str == "tap" }.count, StillRepeat.askAt)
        XCTAssertEqual(agent.steps.last { $0["action"]?.str == "fail" }?["message"]?.str, StillRepeat.message)
        let hinted = model.prompts.filter { $0.contains("Did nothing 2 times") }
        XCTAssertFalse(hinted.isEmpty, "the line went with the requests after the second")
        XCTAssertEqual(model.prompts.count, 1 + 3 * 2, "RepeatGuard's asks as before; the line adds none")
        XCTAssertTrue(StillRepeat.reason.hasPrefix(AgentLoop.stallReason), "a stall: the same help buttons, the free line's reason")
        let end = RunEnd(steps: [["action": .str("fail"), "reason": .str(StillRepeat.reason)]], moves: 3, calls: 7, firmware: nil)
        XCTAssertEqual(end.reason, .stall)
    }

    func testTheSecondLookFindsALateChangeAndTheRunGoesOn() async throws {
        let screen = FakeScreen()
        let before = AgentTests.jpeg()
        screen.frame = before
        let agent = AgentLoop(phone: FakeGestures(), screen: screen, actor: nil, planner: nil, trace: nil)
        for _ in 0..<StillRepeat.askAt { agent.record(before, tap(500, 500)) }
        screen.frame = gray(0.95)  // the slow app opened at last
        let asked = try await agent.stillAgain()
        XCTAssertFalse(asked)
        XCTAssertEqual(agent.steps.last?["changed"], .bool(true))
        XCTAssertEqual(StillRepeat.count(agent.steps), 0)
        XCTAssertFalse(agent.steps.contains { $0["action"]?.str == "fail" })

        screen.frame = before
        agent.record(before, tap(500, 500))
        agent.record(before, tap(500, 500))
        let early = try await agent.stillAgain()
        XCTAssertFalse(early, "two since the change: not yet")
        agent.record(before, tap(500, 500))
        screen.updated = 1  // frames stopped: the second look sees nothing new
        agent.lastActed = 2
        let blind = try await agent.stillAgain()
        XCTAssertFalse(blind, "no frame on the second look: unknown, not asked")
        screen.updated = 0
        let third = try await agent.stillAgain()
        XCTAssertTrue(third)
        XCTAssertEqual(agent.steps.last?["reason"]?.str, StillRepeat.reason)
    }
}

/// A look-ahead from the early frame is skipped only when it would be thrown away: the screen still moving, or no
/// frame from after the action yet (2026-11-27: 16% of the Hy calls were superseded look-aheads).
@MainActor final class LookAheadGateTests: XCTestCase {
    override func tearDown() {
        StepWaits.reset()
        StepWaits.movingSteps = 0
        StepWaits.lastMoving = -1000
        super.tearDown()
    }

    func testSettledSaysWhetherTheScreenStoodStill() async {
        let screen = FakeScreen()
        let still = await screen.settled(quiet: 0.1, least: 0, most: 0.5)
        XCTAssertTrue(still)
        screen.updated = now() + 100  // changes all the time
        let moving = await screen.settled(quiet: 0.1, least: 0, most: 0.3)
        XCTAssertFalse(moving)
    }

    func testStandsOnlyWithAStillScreenAndAFrameFromAfterTheAction() {
        let screen = FakeScreen()
        let agent = AgentLoop(phone: FakeGestures(), screen: screen, actor: nil, planner: nil, trace: nil)
        agent.lastActed = 100
        XCTAssertFalse(agent.lookAheadStands(stood: false))
        screen.capturedAt = 99
        XCTAssertFalse(agent.lookAheadStands(stood: true), "the early frame is from before the action")
        screen.capturedAt = 101
        XCTAssertTrue(agent.lookAheadStands(stood: true))
    }

    func testAStepStartsALookAheadOnlyWhenItWouldStand() async throws {
        for (captured, expected) in [(0.0, true), (1.0, false)] {  // 0: unknown, counts as arrived; 1: long before
            let screen = FakeScreen()
            screen.capturedAt = captured
            let actor = FakeModel { _ in "THINK: home\nDO: home" }
            let agent = AgentLoop(phone: FakeGestures(), screen: screen, actor: actor, planner: nil, trace: nil)
            agent.speculate = true
            _ = try await agent.step()
            XCTAssertEqual(agent.pendingLook != nil, expected, "captured \(captured)")
            agent.cancelSpeculative("test end")
        }
    }
}
