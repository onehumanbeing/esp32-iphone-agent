import XCTest
@testable import IPhoneAgent

@MainActor final class RecoveryTests: XCTestCase {
    private func link(_ connected: Bool = true, sta: Int? = 1, ap: String? = "streaming", frameAt: Double = 0) -> Recovery.Link {
        Recovery.Link(connected: connected, sta: sta, ap: ap, frameAt: frameAt)
    }

    func testStagesAfterABoardReboot() {
        var r = Recovery(at: 100)
        XCTAssertEqual(r.next(link(false), at: 100), .wait(.init(part: .board, ask: false)))
        XCTAssertEqual(r.next(link(sta: 0, ap: "idle"), at: 107), .wait(.init(part: .hotspot, ask: false)))
        XCTAssertEqual(r.next(link(sta: 1, ap: "idle"), at: 133), .wait(.init(part: .mirroring, ask: false)))
        XCTAssertEqual(r.next(link(frameAt: 99), at: 140), .wait(.init(part: .frames, ask: false)),
                       "streaming, but no frame newer than the loss yet")
        XCTAssertEqual(r.next(link(frameAt: 141), at: 141), .live)
    }

    func testAsksOnlyAfterEachPartsQuietTime() {
        var r = Recovery(at: 0)
        XCTAssertEqual(r.next(link(sta: 0), at: 0), .wait(.init(part: .hotspot, ask: false)))
        XCTAssertEqual(r.next(link(sta: 0), at: 29), .wait(.init(part: .hotspot, ask: false)))
        XCTAssertEqual(r.next(link(sta: 0), at: 30), .wait(.init(part: .hotspot, ask: true)))
        XCTAssertEqual(r.next(link(ap: "idle"), at: 31), .wait(.init(part: .mirroring, ask: false)), "a new part starts quiet")
        XCTAssertEqual(r.next(link(ap: "idle"), at: 50), .wait(.init(part: .mirroring, ask: false)))
        XCTAssertEqual(r.next(link(ap: "idle"), at: 51), .wait(.init(part: .mirroring, ask: true)))
    }

    func testAsksAtOnceWhenTheBoardGetsNoAirPlayFrames() {
        var r = Recovery(at: 0)
        XCTAssertEqual(r.next(link(), at: 5), .wait(.init(part: .frames, ask: false)))
        var stalled = link()
        stalled.stalled = true
        XCTAssertEqual(r.next(stalled, at: 6), .wait(.init(part: .frames, ask: true)), "restarting mirroring is the only fix")
    }

    func testGivesUpAfterFiveMinutesNamingWhatIsMissing() {
        var r = Recovery(at: 0)
        XCTAssertEqual(r.next(link(ap: "idle"), at: 0), .wait(.init(part: .mirroring, ask: false)))
        XCTAssertEqual(r.next(link(ap: "idle"), at: 299), .wait(.init(part: .mirroring, ask: true)))
        guard case .giveUp(let reason) = r.next(link(ap: "idle"), at: 300) else { return XCTFail() }
        XCTAssertTrue(reason.contains("Screen Mirroring"))
    }

    func testConnectedMirroringWaitsForFreshImageWithoutAskingToStartMirroring() {
        var r = Recovery(at: 100)
        XCTAssertEqual(r.next(link(frameAt: 100), at: 100), .wait(.init(part: .frames, ask: false)))
        XCTAssertEqual(r.next(link(frameAt: 99), at: 119), .wait(.init(part: .frames, ask: false)))
        XCTAssertEqual(r.next(link(frameAt: 99), at: 120), .wait(.init(part: .frames, ask: true)))
        XCTAssertEqual(r.next(link(frameAt: 121), at: 121), .live)
        let pending = Recovery.Stage(part: .frames, ask: false)
        XCTAssertEqual(pending.status.minimal, "Frame")
        XCTAssertTrue(pending.status.full.contains("Mirroring is connected"))
        XCTAssertFalse(pending.line.contains("Start Screen Mirroring"))
        XCTAssertTrue(Recovery.Stage(part: .frames, ask: true).line.contains("restart Screen Mirroring"))
    }

    func testFrameWaitingHasItsOwnQuietWindowAfterMirroringConnects() {
        var r = Recovery(at: 0)
        XCTAssertEqual(r.next(link(ap: "idle"), at: 0), .wait(.init(part: .mirroring, ask: false)))
        XCTAssertEqual(r.next(link(ap: "idle"), at: 20), .wait(.init(part: .mirroring, ask: true)))
        XCTAssertEqual(r.next(link(frameAt: 0), at: 21), .wait(.init(part: .frames, ask: false)))
        XCTAssertEqual(r.next(link(frameAt: 0), at: 40), .wait(.init(part: .frames, ask: false)))
        XCTAssertEqual(r.next(link(frameAt: 0), at: 41), .wait(.init(part: .frames, ask: true)))
    }

    func testTheStatusLabelsSayWhatIsMissing() {
        XCTAssertEqual(Recovery.Stage(part: .board, ask: false).status, .waitingForBoard)
        XCTAssertEqual(Recovery.Stage(part: .board, ask: true).line, IslandStatus.waitingForBoard.full)
        XCTAssertEqual(Recovery.Stage(part: .board, ask: false).status.minimal, "Board")
        XCTAssertEqual(Recovery.Stage(part: .hotspot, ask: false).status.minimal, "Wi-Fi")
        XCTAssertEqual(Recovery.Stage(part: .mirroring, ask: false).status.minimal, "Mirror")
        XCTAssertEqual(Recovery.Stage(part: .mirroring, ask: false).status.full, "Waiting for mirroring…")
        XCTAssertEqual(Recovery.Stage(part: .mirroring, ask: true).status.full, "Tap Screen Mirroring → ESP32 Agent to continue")
        for part in [Recovery.Part.board, .hotspot, .mirroring, .frames] {
            for ask in [false, true] {
                XCTAssertLessThanOrEqual(Recovery.Stage(part: part, ask: ask).status.short.count, IslandStatus.compactLimit)
            }
        }
    }

    func testRunPausesForALostScreenAndGoesOnFromTheSameStep() async {
        let screen = FakeScreen()
        let model = FakeModel { n in n == 1 ? "1. go home" : n == 2 ? "THINK: home\nDO: home" : "THINK: there\nDO: done ok" }
        let phone = FakeGestures()
        let agent = AgentLoop(phone: phone, screen: screen, actor: model, planner: model, trace: nil)
        var stages: [Recovery.Stage?] = []
        var restored = 0
        var state = Recovery.Link(connected: true, sta: 1, ap: "idle", frameAt: 0)
        agent.link = { state }
        agent.onRecover = { stages.append($0) }
        agent.restore = { restored += 1 }
        agent.onStep = {  // the link drops right after the first move
            guard agent.steps.last?["action"] == .str("home") else { return }
            screen.live = false
            Task {
                try? await Task.sleep(nanoseconds: 800_000_000)  // longer than settling after the move
                state = Recovery.Link(connected: true, sta: 1, ap: "streaming", frameAt: now())
                screen.live = true
            }
        }
        await agent.run()
        XCTAssertEqual(agent.steps.map { $0["action"]?.str }, ["home", "reconnected", "done"])
        XCTAssertEqual(stages, [Recovery.Stage(part: .mirroring, ask: false), nil])
        XCTAssertEqual(restored, 1)
        XCTAssertTrue(model.prompts[2].contains("the connection was lost and restored; re-check the screen"))
        XCTAssertFalse(model.prompts[1].contains("connection was lost"))
    }

    func testAStaleFrameIsFetchedAgainBeforeTheModelSeesIt() async {
        let screen = FakeScreen()
        screen.stale = true  // the stream broke after the last action; the shown frame is minutes old
        let model = FakeModel { _ in "THINK: there\nDO: done ok" }
        let agent = AgentLoop(phone: FakeGestures(), screen: screen, actor: model, planner: model, trace: nil)
        var restoredBeforeAsking: Bool?
        agent.link = { Recovery.Link(connected: true, sta: 1, ap: "streaming", frameAt: now()) }
        agent.restore = { restoredBeforeAsking = model.prompts.isEmpty; screen.stale = false }
        await agent.run()
        XCTAssertEqual(restoredBeforeAsking, true)
        XCTAssertEqual(agent.steps.map { $0["action"]?.str }, ["reconnected", "done"])
    }

    func testTapsAfterTheFirstInARoundFindThePointerBeforePressing() async {
        let screen = FakeScreen()
        screen.frame = AgentTests.jpeg()
        var round = 0
        let model = FakeModel { _ in
            round += 1
            return round == 1 ? "THINK: pairs\nDO: tap 189 705\nDO: tap 484 705\nDO: tap 499 921" : "THINK: there\nDO: done ok"
        }
        let phone = FakeGestures()
        let agent = AgentLoop(phone: phone, screen: screen, actor: model, planner: model, trace: nil)
        agent.link = { Recovery.Link(connected: true, sta: 1, ap: "streaming", frameAt: now()) }
        await agent.run()
        XCTAssertEqual(phone.aims, [false, true, true])  // the Duolingo round of 2026-11-06 drifted 13% unseen
    }

    func testARoundOfSeveralTapsLeavesTheNextStepToTheModel() async {
        let screen = FakeScreen()
        screen.frame = AgentTests.jpeg()
        var round = 0, held: [Bool] = []
        let model = FakeModel { _ in
            round += 1
            held.append(JevGate.hold)
            switch round {
            case 1: return "THINK: words\nPLAN:\n1. Tap Rice\n2. Tap and\nDO: tap 821 655\nDO: tap 175 655"
            case 2: return "THINK: check\nDO: tap 500 915"
            default: return "THINK: there\nDO: done ok"
            }
        }
        let agent = AgentLoop(phone: FakeGestures(), screen: screen, actor: model, planner: model, trace: nil)
        agent.link = { Recovery.Link(connected: true, sta: 1, ap: "streaming", frameAt: now()) }
        await agent.run()
        XCTAssertEqual(held, [false, true, false])  // after the two-tap round only (Duolingo, 2026-11-07)
    }

    func testATapWhereTheLastOneWentFindsThePointerFirst() {
        let agent = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: FakeModel { _ in "" }, planner: nil, trace: nil)
        agent.steps = [["action": .str("tap"), "x": .int(789), "y": .int(705), "changed": .bool(true)], ["action": .str("plan")]]
        XCTAssertTrue(agent.retaps(["action": .str("tap"), "x": .int(790), "y": .int(704)]))  // a miss the mascot hid
        XCTAssertFalse(agent.retaps(["action": .str("tap"), "x": .int(499), "y": .int(921)]))
        agent.steps.append(["action": .str("type"), "text": .str("water")])
        XCTAssertFalse(agent.retaps(["action": .str("tap"), "x": .int(789), "y": .int(705)]))
    }

    func testARunFromRunsIsRestoredWithItsLastPlan() {
        let agent = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: FakeModel { _ in "" }, planner: nil, trace: nil)
        agent.restore(task: "Duolingo lesson", steps: [["action": .str("plan"), "plan": .str("1. Open it")],
                                                       ["action": .str("tap"), "x": .int(500), "y": .int(255)],
                                                       ["action": .str("plan"), "plan": .str("1. Tap START")]])
        XCTAssertEqual(agent.task, "Duolingo lesson")
        XCTAssertEqual(agent.steps.count, 3)
        XCTAssertEqual(agent.plan, "1. Tap START")
    }

    func testAResumedRunKeepsItsPlanAndStepsAndSaysItGoesOn() async throws {
        let screen = FakeScreen()
        screen.frame = AgentTests.jpeg()
        let model = FakeModel { _ in "THINK: lesson\nPLAN:\n1. Answer each exercise\nDO: fail stopped here" }
        let agent = AgentLoop(phone: FakeGestures(), screen: screen, actor: model, planner: model, trace: nil)
        agent.link = { Recovery.Link(connected: true, sta: 1, ap: "streaming", frameAt: now()) }
        try agent.start("Duolingo lesson")
        while agent.running { try await Task.sleep(nanoseconds: 20_000_000) }
        let before = agent.steps.count
        XCTAssertEqual(agent.plan, "1. Answer each exercise")
        try agent.start("Duolingo lesson", resume: true)
        agent.stop()
        XCTAssertEqual(agent.plan, "1. Answer each exercise")
        XCTAssertEqual(agent.steps.count, before + 1)
        XCTAssertEqual(agent.steps.last?["action"], .str("resumed"))
        while agent.running { try await Task.sleep(nanoseconds: 20_000_000) }
        try agent.start("Another task", resume: true)  // not this run's task: a fresh start
        agent.stop()
        XCTAssertFalse(agent.steps.contains { $0["action"] == .str("resumed") })
    }

    func testStoppedRunKeepsItsPlanStepsAndNotebookThroughCleanupAndContinue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let trace = TraceStore(root: root), screen = FakeScreen()
        screen.frame = AgentTests.jpeg()
        let model = FakeModel { call in
            switch call {
            case 1: return "PLAN: 1. Collect titles\nDO: read titles\nDO: note checked first page\nDO: progress page 1 of 2"
            case 2: return "Alpha\nBeta"
            default: return "DO: done collected titles"
            }
        }
        let agent = AgentLoop(phone: FakeGestures(), screen: screen, actor: model, planner: nil, trace: trace)
        agent.onStep = { [weak agent] in
            if agent?.steps.last?["action"] == .str("progress") { agent?.stop() }
        }
        let entered = expectation(description: "已停止操作，正在收尾")
        var unblock: CheckedContinuation<Void, Never>?
        var cleanups = 0
        agent.beforeFinish = {
            cleanups += 1
            XCTAssertFalse(Task.isCancelled)
            if cleanups == 1 {
                await withCheckedContinuation { unblock = $0; entered.fulfill() }
                XCTAssertFalse(Task.isCancelled, "重复停止不能取消正在执行的收尾")
            }
        }

        try agent.start("Collect titles")
        await fulfillment(of: [entered], timeout: 5)
        guard let unblock else { agent.stop(); return }
        XCTAssertTrue(agent.running)
        XCTAssertThrowsError(try agent.start("Another task"))
        agent.stop()
        unblock.resume()
        await agent.waitUntilStopped()

        XCTAssertEqual(cleanups, 1)
        let stopped = agent.steps
        XCTAssertEqual(stopped.compactMap { $0["action"]?.str }, ["plan", "read", "note", "progress", "stopped"])
        let stored = try XCTUnwrap(RunStore.load(try XCTUnwrap(trace.dir)))
        XCTAssertEqual(stored.outcome, .stopped)
        XCTAssertEqual(stored.steps.map(\.name), stopped.compactMap { $0["action"]?.str })
        XCTAssertEqual(agent.task, "Collect titles")
        XCTAssertEqual(agent.plan, "1. Collect titles")
        XCTAssertEqual(agent.notebook.items, ["Alpha", "Beta"])
        XCTAssertEqual(agent.notebook.notes, ["checked first page"])
        XCTAssertEqual(agent.notebook.progress, "page 1 of 2")

        try agent.start("Collect titles", resume: true)
        await agent.waitUntilStopped()
        XCTAssertEqual(cleanups, 2)
        XCTAssertEqual(Array(agent.steps.prefix(stopped.count)), stopped)
        XCTAssertEqual(agent.steps.suffix(2).compactMap { $0["action"]?.str }, ["resumed", "done"])
        XCTAssertEqual(agent.steps.last?["notebook"], .arr([.str("Alpha"), .str("Beta")]))
        let prompt = try XCTUnwrap(model.prompts.last)
        for text in ["1. Collect titles", "Alpha", "Beta", "checked first page", "page 1 of 2"] {
            XCTAssertTrue(prompt.contains(text), "恢复时模型应取得保存的进度：\(text)")
        }
    }

    func testFailedRunInvokesCleanupAndKeepsItsRecordedReason() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let trace = TraceStore(root: root)
        let model = FakeModel { _ in "DO: fail button is missing" }
        let agent = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: model, planner: nil, trace: trace)
        var cleanups = 0
        agent.beforeFinish = { cleanups += 1 }
        try agent.start("Find button")
        await agent.waitUntilStopped()
        XCTAssertEqual(cleanups, 1)
        let run = try XCTUnwrap(RunStore.load(try XCTUnwrap(trace.dir)))
        XCTAssertEqual(run.outcome, .failed)
        XCTAssertEqual(run.steps.last?.action["reason"], .str("button is missing"))
        XCTAssertEqual(agent.steps.last?["action"], .str("fail"))
    }

    func testRunEndsWithAClearReasonWhenTheScreenNeverComesBack() async {
        let screen = FakeScreen()
        screen.live = false
        let model = FakeModel { _ in "1. go home" }
        let agent = AgentLoop(phone: FakeGestures(), screen: screen, actor: model, planner: model, trace: nil)
        agent.link = { Recovery.Link(connected: true, sta: 1, ap: "idle", frameAt: 0) }
        agent.recoveryLimit = 0.3
        await agent.run()
        XCTAssertEqual(agent.steps.last?["action"], .str("fail"))
        XCTAssertEqual(agent.steps.last?["reason"], .str(Recovery.reason(.mirroring)))
        XCTAssertTrue(model.prompts.isEmpty, "the model never saw a stale screen")
    }

    func testConnectedMirroringWithoutFramesNeverQueriesTheModel() async {
        let screen = FakeScreen()
        screen.live = false
        let model = FakeModel { _ in "1. go home" }
        let agent = AgentLoop(phone: FakeGestures(), screen: screen, actor: model, planner: model, trace: nil)
        agent.link = { Recovery.Link(connected: true, sta: 1, ap: "streaming", frameAt: 0) }
        agent.recoveryLimit = 0.3
        await agent.run()
        XCTAssertEqual(agent.steps.last?["action"], .str("fail"))
        XCTAssertEqual(agent.steps.last?["reason"], .str(Recovery.reason(.frames)))
        XCTAssertTrue(model.prompts.isEmpty)
    }
}
