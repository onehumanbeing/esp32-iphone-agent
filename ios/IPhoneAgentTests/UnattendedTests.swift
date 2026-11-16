import XCTest
@testable import IPhoneAgent

@MainActor final class UnattendedTests: XCTestCase {
    func testAttendedPolicyChangesNothingByDefault() {
        let policy = RunPolicy.attended
        XCTAssertFalse(policy.unattended)
        XCTAssertNil(policy.helpTimeout)
        XCTAssertEqual(policy.recoveryLimit, Recovery.limit)
        XCTAssertEqual(policy.maxRestarts, 0)
        XCTAssertFalse(policy.keepAwake)
        XCTAssertFalse(policy.selfHealMirroring)
        XCTAssertNotEqual(policy.confirmDefault, .resume)
    }

    func testAConfirmTimeoutNeverApproves() {
        let policy = RunPolicy.unattended(repairMirroring: false)
        XCTAssertEqual(policy.fallback(reason: "pay", confirm: true, restarts: 0), .skip)
        XCTAssertNotEqual(policy.fallback(reason: "pay", confirm: true, restarts: 0), .resume)
        XCTAssertEqual(policy.fallback(reason: AgentLoop.stallReason, confirm: false, restarts: 0), .restart)
        XCTAssertEqual(policy.fallback(reason: AgentLoop.stallReason, confirm: false, restarts: policy.maxRestarts), .stop)
        XCTAssertEqual(policy.fallback(reason: "login", confirm: false, restarts: 0), .stop)
        XCTAssertFalse(RunPolicy.backsOff(LLMError(message: "day", status: 429, kind: "rate_limit_day")))
        XCTAssertTrue(RunPolicy.backsOff(LLMError(message: "busy", status: 503)))
        XCTAssertTrue(RunPolicy.backsOff(LLMError(message: "minute", status: 429, kind: "rate_limit_minute")))
        XCTAssertEqual(policy.backoff(attempt: 0), 30)
        XCTAssertEqual(policy.backoff(attempt: 1), 60)
        XCTAssertEqual(policy.backoff(attempt: 20), 600)
    }

    func testHelpTimeoutRestartsThenStops() async {
        let screen = FakeScreen()
        screen.frame = AgentTests.jpeg()
        let model = FakeModel { _ in "THINK: again\nDO: tap 100 200" }
        let phone = FakeGestures()
        let agent = AgentLoop(phone: phone, screen: screen, actor: model, planner: model, trace: nil, maxStalls: 1)
        var policy = RunPolicy.unattended(repairMirroring: false)
        policy.helpTimeout = 0.05
        policy.maxRestarts = 1
        agent.policy = policy
        agent.onHelp = { _ in
            try? await Task.sleep(nanoseconds: 400_000_000)
            return .resume
        }
        await agent.run()
        XCTAssertEqual(agent.restarts, 1)
        XCTAssertEqual(agent.steps.last?["action"]?.str, "stopped")
        XCTAssertTrue(phone.calls.contains("home"))
        XCTAssertFalse(agent.steps.contains { $0["action"]?.str == "takeover" }, "the sleeping answer must not win")
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    func testARiskyStepIsSkippedWhenNobodyAnswers() async {
        let screen = FakeScreen()
        screen.frame = AgentTests.jpeg()
        var round = 0
        let model = FakeModel { _ in
            round += 1
            return round == 1 ? "THINK: pay\nDO: confirm send the payment" : "THINK: there\nDO: done ok"
        }
        let agent = AgentLoop(phone: FakeGestures(), screen: screen, actor: model, planner: model, trace: nil)
        var policy = RunPolicy.unattended(repairMirroring: false)
        policy.helpTimeout = 0.05
        agent.policy = policy
        agent.onConfirm = { _ in
            try? await Task.sleep(nanoseconds: 400_000_000)
            return .resume
        }
        await agent.run()
        let skipped = agent.steps.first { $0["action"]?.str == "skipped" }
        XCTAssertEqual(skipped?["confirmed_by"]?.str, "policy")
        XCTAssertEqual(agent.steps.last?["action"]?.str, "done")
        XCTAssertFalse(agent.steps.contains { $0["action"]?.str == "confirmed" })
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    func testUnattendedDoesNotApproveWhenAskingIsOff() async {
        let screen = FakeScreen()
        screen.frame = AgentTests.jpeg()
        var round = 0
        let model = FakeModel { _ in
            round += 1
            return round == 1 ? "THINK: pay\nDO: confirm send the payment" : "THINK: there\nDO: done ok"
        }
        let agent = AgentLoop(phone: FakeGestures(), screen: screen, actor: model, planner: model, trace: nil)
        agent.policy = .unattended(repairMirroring: false)
        agent.askMode = .never
        await agent.run()
        XCTAssertEqual(agent.steps.first { $0["action"]?.str == "skipped" }?["confirmed_by"]?.str, "policy")
        XCTAssertFalse(agent.steps.contains { $0["action"]?.str == "confirmed" })
    }

    func testABusyModelBacksOffWithoutCountingAFailure() async {
        let screen = FakeScreen()
        screen.frame = AgentTests.jpeg()
        let model = OneFailureModel()
        let agent = AgentLoop(phone: FakeGestures(), screen: screen, actor: model, planner: model, trace: nil, maxFailures: 1)
        var policy = RunPolicy.unattended(repairMirroring: false)
        policy.backoffBase = 0.01
        policy.backoffCap = 0.02
        agent.policy = policy
        await agent.run()
        XCTAssertEqual(model.calls, 2)
        XCTAssertTrue(agent.steps.contains { $0["action"]?.str == "hiccup" && ($0["reason"]?.str ?? "").contains("waiting") })
        XCTAssertEqual(agent.steps.last?["action"]?.str, "done")
        XCTAssertFalse(agent.steps.contains { $0["reason"]?.str?.contains("errors in a row") == true })
    }

    func testADailyLimitStillEndsTheRun() async {
        let screen = FakeScreen()
        screen.frame = AgentTests.jpeg()
        let model = FakeModel { _ in "THINK: there\nDO: done ok" }
        model.error = LLMError(message: "used up", status: 429, kind: "rate_limit_day")
        let agent = AgentLoop(phone: FakeGestures(), screen: screen, actor: model, planner: model, trace: nil)
        agent.policy = .unattended(repairMirroring: false)
        await agent.run()
        XCTAssertEqual(agent.steps.last?["action"]?.str, "error")
        XCTAssertFalse(agent.steps.contains { ($0["reason"]?.str ?? "").contains("waiting") })
    }

    func testAFailedLinkCheckRecoversInsteadOfEnding() async {
        let screen = StillLinkScreen()
        screen.fresh = false
        var restores = 0
        let model = FakeModel { _ in
            restores > 0 ? "THINK: there\nDO: done ok" : "THINK: try\nDO: tap 200 400"
        }
        let agent = AgentLoop(phone: FakeGestures(), screen: screen, actor: model, planner: model, trace: nil, maxStalls: 12)
        agent.policy = .unattended(repairMirroring: false)
        agent.restore = {
            restores += 1
            screen.fresh = true
        }
        agent.link = { Recovery.Link(connected: true, sta: 1, ap: "streaming", frameAt: now()) }
        agent.onHelp = { _ in .stop }
        await agent.run()
        XCTAssertGreaterThanOrEqual(restores, 1)
        XCTAssertNotEqual(agent.steps.last?["reason"]?.str, LinkCheck.reason)
    }

    func testLockedWaitsAndNeverLooksLikeAMissingHotspot() {
        var link = Recovery.Link(connected: true, sta: 0, ap: "idle", frameAt: 0, usb: "asleep")
        var recovery = Recovery(at: 0)
        guard case .wait(let stage) = recovery.next(link, at: 0) else { return XCTFail() }
        XCTAssertEqual(stage.part, .locked)
        XCTAssertFalse(stage.ask)
        guard case .wait(let asked) = recovery.next(link, at: 5) else { return XCTFail() }
        XCTAssertTrue(asked.ask)
        XCTAssertLessThanOrEqual(asked.status.short.count, IslandStatus.compactLimit)
        XCTAssertTrue(asked.line.contains("passcode is never typed"))
        link.usb = "ok"
        link.locked = true
        link.sta = 1
        link.ap = "streaming"
        link.frameAt = 10
        guard case .wait(let still) = recovery.next(link, at: 6) else { return XCTFail() }
        XCTAssertEqual(still.part, .locked)
    }

    func testALongerRecoveryLimitDoesNotGiveUpAtFiveMinutes() {
        var recovery = Recovery(at: 0, limit: RunPolicy.unattendedRecovery)
        let link = Recovery.Link(connected: true, sta: 1, ap: "idle", frameAt: 0)
        guard case .wait = recovery.next(link, at: Recovery.limit) else { return XCTFail("5 minutes is not the unattended limit") }
        guard case .giveUp(let reason) = recovery.next(link, at: RunPolicy.unattendedRecovery) else { return XCTFail() }
        XCTAssertTrue(reason.contains("Screen Mirroring"))
        XCTAssertTrue(reason.contains("120"))
    }

    func testMirrorHealWaitsThenBacksOffAndStopsWhenSpotsAreWrong() {
        var clock = MirrorHeal.Clock(part: .mirroring, inPart: 19, connected: true, sta: 1, usb: "ok", spotsValid: true)
        XCTAssertEqual(MirrorHeal.decide(clock), .idle)
        clock.inPart = 20
        XCTAssertEqual(MirrorHeal.decide(clock), .attempt(1))
        clock.usb = "asleep"
        XCTAssertEqual(MirrorHeal.decide(clock), .idle)
        clock.usb = "ok"
        clock.userInFront = true
        XCTAssertEqual(MirrorHeal.decide(clock), .idle)
        clock.userInFront = false
        clock.attempts = 8
        XCTAssertEqual(MirrorHeal.decide(clock), .idle)
        clock.attempts = 1
        clock.now = 10
        clock.backoffUntil = 40
        XCTAssertEqual(MirrorHeal.decide(clock), .idle)
        clock.now = 40
        XCTAssertEqual(MirrorHeal.decide(clock), .attempt(2))
        clock.suspicious = true
        XCTAssertEqual(MirrorHeal.decide(clock), .idle)
        XCTAssertEqual(MirrorHeal.backoff(after: 1), 30)
        XCTAssertEqual(MirrorHeal.backoff(after: 5), 600)
        XCTAssertEqual(MirrorHeal.decide(MirrorHeal.Clock(part: .frames, inPart: 100, connected: true, sta: 1, usb: "ok", spotsValid: true)), .idle)
    }

    func testLearningIgnoresStopMirroringAndFindsTheBoardRow() {
        let size = CGSize(width: 200, height: 400)
        let lines: [(text: String, box: [Int])] = [
            ("Screen Mirroring", [10, 40, 90, 70]),
            ("Stop Mirroring", [10, 200, 90, 230]),
            ("ESP32 Agent", [20, 120, 160, 150]),
        ]
        let tile = MirrorSpots.find(lines, words: MirrorSpots.tileWords, size: size)
        XCTAssertEqual(tile, MirrorSpots.Point(x: 250, y: 138))
        let row = MirrorSpots.find(lines, words: ["esp32 agent"], size: size)
        XCTAssertEqual(row?.y, 338)
        XCTAssertNil(MirrorSpots.find([("Stop Mirroring", [0, 0, 10, 10])], words: ["stop mirroring"], size: size))
        var spots = MirrorSpots(tile: tile!, row: row!, width: 100, height: 200, ios: "18.0", learnedAt: 0)
        XCTAssertTrue(spots.valid(width: 100, height: 200, ios: "18.0"))
        XCTAssertFalse(spots.valid(width: 100, height: 200, ios: "18.1"))
    }

    func testADoLineCountsOnlyOnceItIsComplete() {
        var text = "THINK: look\nDO: ta"
        XCTAssertFalse(StreamMarks.completeDoLine(text))
        text += "p 10 20\n"
        XCTAssertTrue(StreamMarks.completeDoLine(text))
        XCTAssertTrue(StreamMarks.completeDoLine("  DO：wait\n"))
        XCTAssertFalse(StreamMarks.completeDoLine("DO: wait"))
    }

    func testAStepTimingRowFeedsTheBar() {
        let action: JObject = ["action": .str("tap"), "timing": .obj([
            "frame_ms": .num(100), "verdict_ms": .num(20), "landing_ms": .num(5),
            "llm_ms": .num(800), "first_token_ms": .num(300), "hid_ms": .num(40),
            "other_ms": .num(10), "lead_ms": .num(5), "housekeeping_ms": .num(15),
        ])]
        let row = StepTiming.read(action)
        XCTAssertEqual(row?.frame, 100)
        XCTAssertEqual(row?.verdict, 25)
        XCTAssertEqual(row?.modelBefore, 300)
        XCTAssertEqual(row?.modelAfter, 500)
        XCTAssertEqual(row?.hid, 40)
        XCTAssertEqual(row?.other, 30)
        XCTAssertNil(StepTiming.read(["action": .str("tap")]))
        XCTAssertEqual(Metrics.median([1, 4, 2]), 2)
        XCTAssertEqual(Metrics.median([1, 2, 3, 4]), 2.5)
        XCTAssertTrue(AgentLoop.changedNearTarget(true))
        XCTAssertFalse(AgentLoop.changedNearTarget(false))
    }

    func testLowBatteryPausesOnlyWhenUnplugged() {
        XCTAssertFalse(DeviceHealth.shouldPause(.ok))
        XCTAssertFalse(DeviceHealth.shouldPause(DeviceHealth.Snapshot(battery: 0.05, plugged: true)))
        XCTAssertTrue(DeviceHealth.shouldPause(DeviceHealth.Snapshot(battery: 0.05, plugged: false)))
        XCTAssertTrue(DeviceHealth.shouldWarn(DeviceHealth.Snapshot(battery: 0.2, plugged: false)))
        XCTAssertFalse(DeviceHealth.shouldPause(DeviceHealth.Snapshot(battery: 0.2, plugged: false)))
        XCTAssertFalse(DeviceHealth.shouldPause(DeviceHealth.Snapshot(battery: -1, plugged: false)))
        XCTAssertTrue(DeviceHealth.isHot(DeviceHealth.Snapshot(thermal: ProcessInfo.ThermalState.serious.rawValue)))
        XCTAssertFalse(DeviceHealth.isHot(DeviceHealth.Snapshot(thermal: ProcessInfo.ThermalState.nominal.rawValue)))
    }
}

@MainActor private final class OneFailureModel: ChatModel {
    let model = "once-busy"
    var calls = 0
    func chat(system: String, text: String, image: Data?, maxTokens: Int, temperature: Double) async throws -> ChatResult {
        calls += 1
        if calls == 1 { throw LLMError(message: "busy", status: 503) }
        return ChatResult(text: "THINK: there\nDO: done ok", firstToken: nil, total: 0)
    }
}

/// A screen that is still "live" but can refuse a fresh frame, the LinkCheck case.
@MainActor private final class StillLinkScreen: ScreenSource {
    var live = true
    var frame: Data? = AgentTests.jpeg()
    var updated = 0.0
    var capturedAt = 0.0
    var aspect = 0.46
    var fresh: Bool?
    func freshFrame() async -> Bool? { fresh }
}
