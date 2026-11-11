import XCTest
@testable import IPhoneAgent

/// Needs-your-help pauses, intent hints, the AI optimizer's reply and demonstration drafts.
@MainActor final class ReviewTests: XCTestCase {
    func testGivingUpAsksForHelpAndGoesOnAfterTakeOver() async {
        let model = SystemRecorder { n in
            switch n {
            case 1: return "1. open it"
            case 2: return "THINK: I need a login\nDO: fail login required"
            case 3: return "1. go on"
            default: return "THINK: there\nDO: done ok"
            }
        }
        let agent = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: model, planner: model, trace: nil)
        var asked: [String] = []
        agent.onHelp = { reason in asked.append(reason); return .resume }
        await agent.run()
        XCTAssertEqual(asked, ["login required"])
        XCTAssertEqual(agent.steps.map { $0["action"]?.str },
                       ["fail", "help", "takeover", "done"])
    }

    func testRiskyStepWaitsForTheUsersOK() async {
        let model = SystemRecorder { n in
            switch n {
            case 1: return "1. send it"
            case 2: return "THINK: about to send\nDO: confirm send the message to Anna"
            default: return "THINK: sent\nDO: done sent"
            }
        }
        let agent = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: model, planner: model, trace: nil)
        agent.askMode = .risky
        var asked: [String] = []
        agent.onConfirm = { reason in asked.append(reason); return .resume }
        await agent.run()
        XCTAssertEqual(asked, ["send the message to Anna"])
        XCTAssertEqual(agent.steps.map { $0["action"]?.str }, ["confirm", "confirmed", "done"])
    }

    func testPaymentsOnlyLetsASendGoOnWithoutAsking() async {
        let model = SystemRecorder { n in n == 1 ? "1. send it" : n == 2 ? "THINK: send\nDO: confirm send the message to Anna" : "THINK: sent\nDO: done sent" }
        let agent = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: model, planner: model, trace: nil)
        agent.askMode = .payments
        var asked: [String] = []
        agent.onConfirm = { reason in asked.append(reason); return .resume }
        await agent.run()
        XCTAssertEqual(asked, [])
        XCTAssertEqual(agent.steps.map { $0["action"]?.str }, ["confirm", "confirmed", "done"])
    }

    func testAskModesPickWhichConfirmsWait() {
        XCTAssertTrue(AskMode.payments.asks("pay 9.99 for the order"))
        XCTAssertTrue(AskMode.payments.asks("确认支付 12 元"))
        XCTAssertFalse(AskMode.payments.asks("send the message to Anna"))
        XCTAssertFalse(AskMode.payments.asks("delete the laptop photo"))  // "tip" inside a word does not count
        XCTAssertTrue(AskMode.risky.asks("delete the photo"))
        XCTAssertFalse(AskMode.never.asks("pay 9.99"))
    }

    func testStopFromAConfirmEndsTheRun() async {
        let model = SystemRecorder { n in n == 1 ? "1. pay" : "THINK: pay\nDO: confirm pay 9.99" }
        let agent = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: model, planner: model, trace: nil)
        agent.onConfirm = { _ in .stop }
        await agent.run()
        XCTAssertEqual(agent.steps.last?["action"], .str("stopped"))
    }

    func testStopFromHelpEndsTheRun() async {
        let model = SystemRecorder { n in n == 1 ? "1. open it" : "THINK: stuck\nDO: fail no button" }
        let agent = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: model, planner: model, trace: nil)
        agent.onHelp = { _ in .stop }
        await agent.run()
        XCTAssertEqual(agent.steps.last?["action"], .str("stopped"))
    }

    func testRoundsThatChangeNothingAskTheUserInsteadOfRunningOn() async {
        let model = SystemRecorder { _ in "THINK: try\nDO: tap 500 500" }  // the fake screen never changes
        let screen = FakeScreen()
        screen.frame = AgentTests.jpeg()
        let agent = AgentLoop(phone: FakeGestures(), screen: screen, actor: model, planner: model, trace: nil,
                              maxStalls: 3)
        var asked: [String] = []
        agent.onHelp = { reason in asked.append(reason); return .stop }
        await agent.run()
        XCTAssertEqual(asked, ["the screen did not change in 3 steps"])
        XCTAssertEqual(agent.steps.filter { $0["action"]?.str == "tap" }.count, 3)
    }

    func testTheSafetyCapAsksTheUserAndCanGoOn() async {
        let model = SystemRecorder { _ in "THINK: try\nDO: tap 500 500" }
        let agent = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: model, planner: model, trace: nil,
                              maxSteps: 2, maxStalls: 100)
        var asked: [String] = []
        agent.onHelp = { reason in asked.append(reason); return asked.count == 1 ? .resume : .stop }
        await agent.run()
        XCTAssertEqual(asked, ["step limit reached", "step limit reached"])
        XCTAssertEqual(agent.steps.filter { $0["action"]?.str == "tap" }.count, 4)  // 2, the user said go on, 2 more
    }

    func testIntentHintsAreAppendedToTheActorPromptOnly() async {
        let model = SystemRecorder { _ in "THINK: there\nDO: done ok" }
        let agent = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: model, planner: model, trace: nil)
        agent.hints = ["Type the time instead of scrolling"]
        await agent.run()
        let rule = "\n" + AssistiveTouchSpots.rule
        XCTAssertEqual(model.systems, [Prompts.actor + rule + "\n\nHints for this task:\n- Type the time instead of scrolling"])
        agent.hints = []
        XCTAssertEqual(agent.actorPrompt, Prompts.actor + rule)
    }

    func testOptimizerReplyIsParsed() {
        let r = ReviewDraft.parseOptimized("Sure.\nPROMPT: Set a 7 AM alarm\nHINTS:\n- Type the time\n- Tap Save\n")
        XCTAssertEqual(r?.prompt, "Set a 7 AM alarm")
        XCTAssertEqual(r?.hints, ["Type the time", "Tap Save"])
        XCTAssertNil(ReviewDraft.parseOptimized("no idea"))
    }

    func testDemonstrationReplyBecomesADraftWithUnsureSteps() {
        let frames = (1...3).map { URL(fileURLWithPath: "/tmp/k00\($0).jpg") }
        let draft = DemoRecorder.draft("""
        NAME: Alarm
        PROMPT: Set an alarm
        STEP 1: tap 500 814 | sure
        STEP 3: type "0700" | unsure
        STEP 2: something odd | sure
        """, frames: frames, folder: URL(fileURLWithPath: "/tmp/none"))
        XCTAssertEqual(draft.name, "Alarm")
        XCTAssertEqual(draft.prompt, "Set an alarm")
        XCTAssertEqual(draft.steps.map(\.name), ["tap", "type", "note"])
        XCTAssertEqual(draft.steps.map(\.uncertain), [false, true, true])
        XCTAssertEqual(draft.steps[1].frame, frames[2])
    }

    func testDemonstrationCanProposeAIAndReadSteps() {
        let draft = DemoRecorder.draft("""
        STEP 1: tap 500 814 | sure
        STEP 1: ai "open the newest video" | sure
        STEP 1: read "video titles" | sure
        """, frames: [URL(fileURLWithPath: "/tmp/k001.jpg")], folder: URL(fileURLWithPath: "/tmp/none"))
        XCTAssertEqual(draft.steps.map(\.name), ["tap", "ai", "read"])
        XCTAssertEqual(draft.steps[1].action["goal"], .str("open the newest video"))
        XCTAssertEqual(draft.steps[2].action["what"], .str("video titles"))
    }

    /// Henry 2026-11-12: a tap names what was tapped; an app still opening is not a step.
    func testDemonstrationTapsCarryTheirLabelAndNoneIsDropped() {
        let draft = DemoRecorder.draft("""
        STEP 1: tap 437 696 "WeChat" | sure
        STEP 2: none | sure
        STEP 3: wait | sure
        STEP 4: tap 287 345 "File Transfer" | sure
        """, frames: (1...4).map { URL(fileURLWithPath: "/tmp/k00\($0).jpg") }, folder: URL(fileURLWithPath: "/tmp/none"))
        XCTAssertEqual(draft.steps.map(\.name), ["tap", "tap"])
        XCTAssertEqual(draft.steps.map { $0.action["label"]?.str }, ["WeChat", "File Transfer"])
        XCTAssertEqual(draft.steps[0].action["x"], .int(437))
        XCTAssertEqual(draft.steps[1].frame?.lastPathComponent, "k004.jpg")
        XCTAssertEqual(DemoRecorder.splitLabel("tap 1 2").1, nil)
    }

    func testCorrectionsReachTheOptimizerInput() {
        let draft = ReviewDraft(source: .run, folder: nil, runID: nil, outcome: .failed,
                                steps: [DraftStep(action: ["action": .str("tap"), "x": .int(1), "y": .int(2)])],
                                name: "", prompt: "Set an alarm")
        draft.setFix(draft.steps[0].id, point: CGPoint(x: 905, y: 88), note: "tap the +")
        draft.insert(after: draft.steps[0].id, text: "then tap Save")
        let text = draft.optimizerInput()
        XCTAssertTrue(text.contains("[USER: wrong]"))
        XCTAssertTrue(text.contains("the right spot is 905 88"))
        XCTAssertTrue(text.contains("[USER NOTE: tap the +]"))
        XCTAssertTrue(text.contains("[ADDED BY USER]"))
        XCTAssertEqual(draft.corrections, 2)
    }
    func testDemonstrationInvalidFramesAndConfidenceStayUncertain() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let frame = folder.appendingPathComponent("k001.jpg")
        let draft = DemoRecorder.draft("""
        STEP -9223372036854775808: tap 1 2 | sure
        STEP 2: tap 1 2 | sure
        STEP 1: tap 1 2 | perhaps
        STEP 1: tap 9000 2 | sure
        STEP 1: tap 999999999999999999999999999 2 | sure
        STEP 1: done success | sure
        """, frames: [frame], folder: folder)
        XCTAssertEqual(draft.steps.count, 6)
        XCTAssertTrue(draft.steps.allSatisfy(\.uncertain))
        XCTAssertNil(draft.steps[0].frame)
        XCTAssertEqual(draft.steps.last?.name, "note")
        XCTAssertNil(DemoRecorder.draft("STEP 1: home | sure", frames: [], folder: folder).steps.first?.frame)
    }

    /// A demonstration is written as a run (DemoRecorder.writeRun): Runs lists it as stopped, so it can be
    /// continued; its unsure steps stay unsure, and the intent saved from it points at the run.
    func testDemonstrationRunIsAStoppedRunWithItsUnsureSteps() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("20261112-090000")
        let trace = TraceStore(root: root)
        trace.open(folder)
        trace.write(kind: "task", ["task": .str("Send hi to File Transfer"), "demo": .bool(true)])
        trace.write(kind: "step", ["action": .str("tap"), "x": .int(120), "y": .int(260), "changed": .bool(true),
                                   "demo": .bool(true), "sure": .bool(true), "frame": .str("k001.jpg"), "t": .num(10)])
        trace.write(kind: "step", ["action": .str("tap"), "x": .int(500), "y": .int(900), "changed": .bool(true),
                                   "demo": .bool(true), "sure": .bool(false), "frame": .str("k002.jpg"), "t": .num(12)])
        trace.write(kind: "step", ["action": .str("stopped"), "demo": .bool(true), "t": .num(12)])
        let run = try XCTUnwrap(RunStore.load(folder))
        XCTAssertTrue(run.isDemo)
        XCTAssertEqual(run.outcome, .stopped)
        XCTAssertEqual(run.moves.count, 2)
        XCTAssertEqual(run.steps[0].frame?.lastPathComponent, "k001.jpg")
        XCTAssertEqual(run.duration, 2)
        let draft = ReviewDraft(run: run)
        XCTAssertEqual(draft.source, .recording)
        XCTAssertEqual(draft.steps.map(\.uncertain), [false, true, false])
        let item = draft.intent(existing: nil)
        XCTAssertEqual(item.refRun, run.id)
        XCTAssertNil(item.refRecording)
        let steps = try XCTUnwrap(draft.recordedSteps(for: item.id))
        defer { try? FileManager.default.removeItem(at: IntentFrames.folder(item.id)) }
        XCTAssertEqual(steps.count, 2)
        XCTAssertTrue(steps[0].action.contains("\"tap\"") && !steps[0].action.contains("demo"))
        XCTAssertTrue(steps[1].action.contains("\"ai\""), "the unsure tap is left to the model")
    }

    func testVerdictRowsReachTheirStep() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("20261112-090001")
        let trace = TraceStore(root: root)
        trace.open(folder)
        trace.write(kind: "task", ["task": .str("x")])
        trace.write(kind: "step", ["action": .str("tap"), "x": .int(1), "y": .int(2)])
        trace.write(kind: "verdict", ["changed": .bool(false), "pointer": .str("1 2")])
        let reopened = TraceStore(root: root)
        reopened.open(folder)  // a resumed run goes on in the same folder, numbering on
        reopened.write(kind: "step", ["action": .str("resumed")])
        let run = try XCTUnwrap(RunStore.load(folder))
        XCTAssertEqual(run.steps.first?.action["changed"], .bool(false))
        XCTAssertEqual(run.steps.map(\.name), ["tap", "resumed"])
        let text = try String(contentsOf: folder.appendingPathComponent("steps.jsonl"), encoding: .utf8)
        XCTAssertTrue(text.contains("\"n\": 4"), text)
    }

    func testRecordingIntentReopensScreensCorrectionsAndHints() throws {
        let folder = DemoRecorder.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let frame = folder.appendingPathComponent("k001.jpg")
        let draft = DemoRecorder.draft("NAME: Alarm\nPROMPT: Set an alarm\nSTEP 1: tap 1 2 | unsure", frames: [frame], folder: folder)
        draft.setFix(draft.steps[0].id, point: CGPoint(x: 500, y: 300), note: "Tap Add")
        draft.insert(after: draft.steps[0].id, text: "Save the alarm")
        try draft.persistEdits()
        let item = draft.intent(existing: nil)
        XCTAssertEqual(item.refRecording, folder.lastPathComponent)
        XCTAssertTrue(item.checklist.contains { $0.contains("500, 300") && $0.contains("Tap Add") })
        XCTAssertTrue(item.checklist.contains("Save the alarm"))
        let decoded = try JSONDecoder().decode(SavedTask.self, from: JSONEncoder().encode(item))
        let restored = ReviewDraft(intent: decoded)
        XCTAssertEqual(restored.steps.count, 2)
        XCTAssertEqual(restored.steps[0].frame, frame)
        XCTAssertEqual(restored.steps[0].fix, CGPoint(x: 500, y: 300))
        XCTAssertEqual(restored.prompt, item.prompt)
        XCTAssertEqual(restored.intent(existing: decoded).checklist, item.checklist)
    }

    func testDraftPersistenceFailureIsReported() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let draft = ReviewDraft(source: .recording, folder: folder, runID: nil, outcome: nil,
                                steps: [], name: "Test", prompt: "Test")
        XCTAssertThrowsError(try draft.persistEdits())
        draft.saveEdits()
        XCTAssertNotNil(draft.persistenceError)
    }

    func testOldIntentsDecodeWithoutRecordingReference() throws {
        let data = Data("{\"id\":\"\(UUID().uuidString)\",\"name\":\"Alarm\",\"prompt\":\"Set alarm\"}".utf8)
        XCTAssertNil(try JSONDecoder().decode(SavedTask.self, from: data).refRecording)
    }

}

/// A fake model that also keeps each system prompt.
@MainActor final class SystemRecorder: ChatModel {
    let model = "fake"
    private(set) var systems: [String] = []
    private let reply: (Int) -> String

    init(_ reply: @escaping (Int) -> String) { self.reply = reply }

    func chat(system: String, text: String, image: Data?, maxTokens: Int, temperature: Double) async throws -> ChatResult {
        systems.append(system)
        return ChatResult(text: reply(systems.count), firstToken: nil, total: 0)
    }
}
