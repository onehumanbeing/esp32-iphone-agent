import UIKit
import XCTest
@testable import IPhoneAgent

/// Port of server/tests/test_agent.py.
@MainActor final class AgentTests: XCTestCase {
    func testReconnectDuringHTTPDiscardsOldCoordinatesAndRestoresBeforeLookingAgain() async throws {
        let phone = FakeGestures(), screen = FakeScreen()
        let device = try XCTUnwrap(phone.device as? FakeDevice)
        let oldFrame = screen.frame, freshFrame = Data([2])
        let model = FakeModel { call in
            if call == 1 {
                device.links += 1  // reconnect while the actor's HTTP request is outstanding
                return "THINK: old screen\nDO: tap 900 900"
            }
            return "THINK: fresh screen\nDO: tap 100 200"
        }
        let agent = AgentLoop(phone: phone, screen: screen, actor: model, planner: nil, trace: nil)
        var restored = 0, calls: [ModelCall] = []
        agent.restore = {
            restored += 1
            screen.frame = freshFrame
            screen.updated = now()
        }
        agent.onModelCall = { calls.append($0) }
        _ = try await agent.step()
        XCTAssertEqual(restored, 1)
        XCTAssertEqual(model.images, [oldFrame, freshFrame])
        XCTAssertEqual(phone.taps, [CGPoint(x: 0.1, y: 0.2)])
        XCTAssertEqual(calls.count, 2, "The discarded completed request still contributes usage")
        XCTAssertTrue(calls.allSatisfy { $0.reply != nil })
    }

    func testPlannerNetworkFailureAfterReconnectRestoresAndRetries() async throws {
        let phone = FakeGestures(), screen = FakeScreen()
        let device = try XCTUnwrap(phone.device as? FakeDevice)
        let model = ConnectionFailureModel { device.links += 1 }
        let agent = AgentLoop(phone: phone, screen: screen, actor: model, planner: model, trace: nil)
        var restored = 0, calls: [ModelCall] = []
        agent.restore = { restored += 1; screen.frame = Data([3]); screen.updated = now() }
        agent.onModelCall = { calls.append($0) }
        try await agent.replan()
        XCTAssertEqual(model.calls, 2)
        XCTAssertEqual(restored, 1)
        XCTAssertEqual(agent.plan, "1. Observe the new screen")
        XCTAssertEqual(calls.count, 2)
        XCTAssertNotNil(calls.first?.error)
        XCTAssertNotNil(calls.last?.reply)
    }

    func testLinkChangesAtActionGateCannotExecuteAcceptedOldReply() async throws {
        let phone = FakeGestures(), screen = FakeScreen()
        let device = try XCTUnwrap(phone.device as? FakeDevice)
        let actor = FakeModel { call in
            call == 1 ? "THINK: old screen\nDO: tap 900 900"
                : call == 2 ? "THINK: fresh screen\nDO: tap 100 200" : "THINK: done\nDO: done ok"
        }
        let planner = FakeModel { _ in "1. Tap the visible control" }
        let agent = AgentLoop(phone: phone, screen: screen, actor: actor, planner: planner, trace: nil)
        var gates = 0, restored = 0
        agent.gate = {
            gates += 1
            if gates == 3 { device.links += 1 }  // planner look, actor look, then its first action gate
        }
        agent.restore = { restored += 1; screen.frame = Data([4]); screen.updated = now() }
        await agent.run()
        XCTAssertEqual(restored, 1)
        XCTAssertEqual(phone.taps, [CGPoint(x: 0.1, y: 0.2)])
        XCTAssertEqual(agent.steps.last?["action"], .str("done"))
    }

    func testCancelledRequestRecoveryDoesNotWaitForTheBoard() async throws {
        let phone = FakeGestures(), screen = FakeScreen()
        let device = try XCTUnwrap(phone.device as? FakeDevice)
        let replied = expectation(description: "Old response returned after the board disconnected")
        let actor = FakeModel { _ in
            device.connected = false
            replied.fulfill()
            return "THINK: stale\nDO: tap 900 900"
        }
        let agent = AgentLoop(phone: phone, screen: screen, actor: actor, planner: actor, trace: nil)
        let query = Task { try await agent.nextActions() }
        await fulfillment(of: [replied], timeout: 1)
        query.cancel()
        do { _ = try await query.value; XCTFail("Recovery must observe cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(phone.calls.isEmpty)
    }

    func testRepeatedReconnectsShareOneRecoveryDeadline() async throws {
        let phone = FakeGestures(), screen = FakeScreen()
        let device = try XCTUnwrap(phone.device as? FakeDevice)
        let actor = FakeModel { _ in
            device.links += 1
            return "THINK: stale\nDO: tap 900 900"
        }
        let agent = AgentLoop(phone: phone, screen: screen, actor: actor, planner: actor, trace: nil)
        agent.recoveryLimit = 0.02
        agent.restore = { screen.frame = Data([5]); screen.updated = now() }
        do { _ = try await agent.nextActions(); XCTFail("Flapping must not retry forever") }
        catch { XCTAssertTrue(error is BlindError) }
        XCTAssertLessThanOrEqual(actor.prompts.count, 2)
        XCTAssertTrue(phone.calls.isEmpty)
    }

    func testActorRetryUsesOnlyTheDimensionsOfTheImageSentOnThatAttempt() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: ModelImage.key)
        defaults.set(true, forKey: ModelImage.key)
        defer { defaults.set(previous, forKey: ModelImage.key) }
        let screen = FakeScreen(), block = CGRect(x: 0.25, y: 0.5, width: 0.2, height: 0.1)
        screen.frame = ReplayTests.screen(block, size: CGSize(width: 600, height: 900))
        let actor = FakeModel { attempt in
            if attempt == 1 {
                screen.frame = ReplayTests.screen(block, size: CGSize(width: 900, height: 600))
                throw URLError(.timedOut)
            }
            return "DO: tap 250 500"
        }
        let agent = AgentLoop(phone: nil, screen: screen, actor: actor, planner: nil, trace: nil)
        _ = try await agent.nextActions()
        let sizes = try actor.images.map { try XCTUnwrap($0.flatMap { UIImage(data: $0) }).size }
        XCTAssertEqual(sizes, [CGSize(width: 540, height: 810), CGSize(width: 540, height: 360)])
        XCTAssertEqual(actor.prompts.count, 2)
        for (prompt, size) in zip(actor.prompts, sizes) {
            XCTAssertTrue(prompt.contains("\(Int(size.width))×\(Int(size.height))"))
            XCTAssertTrue(prompt.contains("0-1000"))
        }
        XCTAssertFalse(try XCTUnwrap(actor.prompts.last).contains("540×810"))
    }

    func testActorPromptAndTraceMatchTheUnshrunkImage() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: ModelImage.key)
        defaults.set(false, forKey: ModelImage.key)
        defer { defaults.set(previous, forKey: ModelImage.key) }
        let screen = FakeScreen()
        screen.frame = ReplayTests.screen(CGRect(x: 0.2, y: 0.3, width: 0.1, height: 0.1),
                                          size: CGSize(width: 600, height: 900))
        let frame = try XCTUnwrap(screen.frame)
        let size = try XCTUnwrap(UIImage(data: frame)).size
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let trace = TraceStore(root: root)
        trace.start(task: "坐标回归")
        let actor = FakeModel { _ in "DO: tap 250 500" }
        let agent = AgentLoop(phone: nil, screen: screen, actor: actor, planner: nil, trace: trace)
        let actions = try await agent.nextActions()
        XCTAssertEqual(actor.images, [frame])
        let prompt = try XCTUnwrap(actor.prompts.first)
        XCTAssertTrue(prompt.contains("\(Int(size.width))×\(Int(size.height))"))
        XCTAssertTrue(prompt.contains("pixel_x / \(Int(size.width))"))
        XCTAssertTrue(prompt.contains("pixel_y / \(Int(size.height))"))
        XCTAssertEqual(actions.first?.act["x"], .int(250))
        let traceFile = try XCTUnwrap(trace.dir).appendingPathComponent("steps.jsonl")
        let records = try String(contentsOf: traceFile, encoding: .utf8).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        let lastRecord = try XCTUnwrap(records.last ?? nil)
        XCTAssertEqual(lastRecord["prompt"] as? String, prompt)
    }

    func testPlannerTimeoutRetriesOnceAndChecksGateAgain() async throws {
        let model = TimeoutModel(failures: 1)
        let agent = AgentLoop(phone: nil, screen: FakeScreen(), actor: model, planner: model, trace: nil)
        var gates = 0
        var retryShown = false
        agent.gate = { gates += 1 }
        agent.onDoing = { if case .retrying = $0 { retryShown = true } }
        try await agent.replan()
        XCTAssertEqual(model.calls, 2)
        XCTAssertEqual(gates, 2)
        XCTAssertTrue(retryShown)
        XCTAssertEqual(agent.plan, "1. Observe the screen")
    }

    func testPlannerTimeoutStopsAfterOneRetry() async {
        let model = TimeoutModel(failures: 10)
        let agent = AgentLoop(phone: nil, screen: FakeScreen(), actor: model, planner: model, trace: nil)
        do { try await agent.replan(); XCTFail("Expected timeout") }
        catch { XCTAssertTrue(ModelRequestFailure.isTimeout(error)) }
        XCTAssertEqual(model.calls, 2)
        XCTAssertTrue(agent.steps.isEmpty)
    }

    func testPlannerAndActorHaveDistinctPendingAndReceivingStates() async throws {
        let model = ProgressModel()
        let agent = AgentLoop(phone: nil, screen: FakeScreen(), actor: model, planner: model, trace: nil)
        var states: [String] = []
        agent.onDoing = {
            switch $0 {
            case .waiting: states.append("waiting")
            case .planning: states.append("planning")
            case .thinking: states.append("thinking")
            default: break
            }
        }
        try await agent.replan()
        XCTAssertEqual(states.last, "planning")
        XCTAssertEqual(states.first, "waiting")
        XCTAssertNil(model.onProgress)
        states = []
        _ = try await agent.nextActions()
        XCTAssertEqual(states.first, "waiting")
        XCTAssertEqual(states.last, "thinking")
        XCTAssertFalse(states.contains("planning"))
        XCTAssertNil(model.onProgress)
    }

    func testParseSingleAction() throws {
        let acts = try Actions.parseActions("THINK: The Search pill is visible, so I tap it.\nDO: tap 500 814")
        XCTAssertEqual(acts, [["thought": .str("The Search pill is visible, so I tap it."), "thought_zh": .str(""),
                               "action": .str("tap"), "x": .int(500), "y": .int(814)]])
        XCTAssertEqual(acts[0].keys, ["thought", "thought_zh", "action", "x", "y"])
    }

    func testParseSeveralActionsKeepsThoughtOnFirst() throws {
        let acts = try Actions.parseActions("THINK: Type and search.\nDO: type Whiteboard\nDO: key enter")
        XCTAssertEqual(acts.map { $0["action"]?.str }, ["type", "key"])
        XCTAssertEqual(acts[0]["text"], .str("Whiteboard"))
        XCTAssertEqual(acts[1]["combo"], .str("enter"))
        XCTAssertNil(acts[1]["thought"])
    }

    func testParseStopsWhereTheModelIsBlind() throws {
        let send = try Actions.parseActions("THINK: Focus, type, send.\nDO: tap 420 908\nDO: type 你好\nDO: tap 917 908")
        XCTAssertEqual(send.map { $0["action"]?.str }, ["tap", "type"])
        let search = try Actions.parseActions("THINK: Search.\nDO: tap 500 815\nDO: type Notes\nDO: key enter\nDO: tap 1 1")
        XCTAssertEqual(search.map { $0["action"]?.str }, ["tap", "type", "key"])
        let early = try Actions.parseActions("THINK: Check it.\nDO: wait\nTHINK: Sent.\nDO: done")
        XCTAssertEqual(early.map { $0["action"]?.str }, ["wait"])
        XCTAssertEqual(try Actions.parseActions("THINK: Sent.\nDO: done").map { $0["action"]?.str }, ["done"])
        let open = try Actions.parseActions("THINK: Bilibili.\nDO: open Bilibili\nDO: tap 1 1")
        XCTAssertEqual(open.map { $0["app"]?.str ?? $0["action"]?.str }, ["Bilibili"])
        let ime = try Actions.parseActions("THINK: English.\nDO: key cmd+a\nDO: key ctrl+space\nDO: type Hello")
        XCTAssertEqual(ime.map { $0["combo"]?.str ?? $0["action"]?.str }, ["cmd+a", "ctrl+space"])
    }

    func testParseCapsAtSixActions() throws {
        let reply = "THINK: draw\n" + (0..<10).map { "DO: tap \($0) \($0)" }.joined(separator: "\n")
        XCTAssertEqual(try Actions.parseActions(reply).count, 6)
    }

    func testParsePathAndCircle() throws {
        XCTAssertEqual(try Actions.parseCommand("path 100 200 300 400 500 600")["points"],
                       .arr([.arr([.int(100), .int(200)]), .arr([.int(300), .int(400)]), .arr([.int(500), .int(600)])]))
        XCTAssertEqual(try Actions.parseCommand("circle 500 450 200"),
                       ["action": .str("circle"), "x": .int(500), "y": .int(450), "r": .int(200)])
    }

    func testParseRejectsBadCommands() {
        for line in ["fly 1 2", "tap 500", "path 1 2 3"] {
            XCTAssertThrowsError(try Actions.parseCommand(line), line)
        }
    }

    func testParseRequiresADoLine() {
        XCTAssertThrowsError(try Actions.parseActions("THINK: I am not sure what to do."))
    }

    func testParsePlanWithAndWithoutLanguages() {
        XCTAssertTrue(Actions.parsePlan("EN:\n1. Tap Search\nZH:\n1. 点搜索") == ("1. Tap Search", "1. 点搜索"))
        XCTAssertTrue(Actions.parsePlan("1. Tap Search") == ("1. Tap Search", "1. Tap Search"))
    }

    func testCircleIsClosedAndRoundOnATallScreen() {
        let aspect = 0.46  // width / height of a portrait iPhone frame
        let pts = circle(0.5, 0.5, 0.2, aspect: aspect)
        XCTAssertEqual(pts[0].x, pts.last!.x, accuracy: 1e-9)
        XCTAssertEqual(pts[0].y, pts.last!.y, accuracy: 1e-9)
        for p in pts {  // equal radius in pixels: y offsets shrink by the aspect ratio
            XCTAssertEqual(hypot(p.x - 0.5, (p.y - 0.5) / aspect), 0.2, accuracy: 1e-9)
        }
    }

    func testActorMayNotRepeatAMoveThatChangedNothing() async throws {
        let actor = FakeModel { n in
            n == 1 ? "THINK: again\nDO: swipe 382 253 382 150" : "THINK: other\nDO: tap 1 2"
        }
        let agent = AgentLoop(phone: nil, screen: FakeScreen(), actor: actor, planner: actor, trace: nil)
        agent.steps = [["action": .str("swipe"), "x1": .int(382), "y1": .int(253), "x2": .int(382), "y2": .int(150),
                        "changed": .bool(false)]]
        let acts = try await agent.nextActions()
        XCTAssertEqual(acts[0].act["action"], .str("tap"))
        XCTAssertTrue(actor.prompts[1].contains("changed nothing"))
    }

    func testRepeatingAMoveThatKeepsChangingTheScreenIsNotStuck() {
        let agent = AgentLoop(phone: nil, screen: nil, actor: nil, planner: nil, trace: nil)
        let swipe: JObject = ["action": .str("swipe"), "x1": .int(500), "y1": .int(800), "x2": .int(500), "y2": .int(400)]
        agent.steps = [swipe.merging(["changed": .bool(true)]), swipe.merging(["changed": .bool(true)])]
        XCTAssertFalse(agent.repeating(swipe))
        agent.steps[1]["changed"] = .bool(false)  // reached the end of the list
        XCTAssertTrue(agent.repeating(swipe))
    }

    func testPreciseTapFlag() throws {
        XCTAssertEqual(try Actions.parseCommand("tap 120 640 precise"),
                       ["action": .str("tap"), "x": .int(120), "y": .int(640), "precise": .bool(true)])
        XCTAssertNil(try Actions.parseCommand("tap 120 640")["precise"])
    }

    // MARK: - beyond the Python tests

    func testHistoryIsFormattedLikePythonJSONDumps() async throws {
        let actor = FakeModel { _ in "THINK: ok\nDO: wait" }
        let agent = AgentLoop(phone: nil, screen: FakeScreen(), actor: actor, planner: actor, trace: nil)
        agent.steps = [
            ["t": .num(1), "shot": .bool(true), "action": .str("plan"), "plan": .str("1. x")],
            ["t": .num(2), "shot": .bool(true), "thought": .str("hi"), "action": .str("tap"), "x": .int(1), "y": .int(2),
             "think_s": .num(1.5), "changed": .bool(true)],
            ["t": .num(3), "shot": .bool(false), "action": .str("type"), "text": .str("café")],
        ]
        _ = try await agent.nextActions()
        XCTAssertTrue(actor.prompts[0].hasSuffix(
            "Recent actions:\n{\"action\": \"tap\", \"x\": 1, \"y\": 2} -> screen changed\n"
            + "{\"action\": \"type\", \"text\": \"caf\\u00e9\"}\n\nNext action?"))
    }

    func testPromptsAreVerbatimFromThePythonServer() throws {
        let agentPy = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../server/hidagent/agent.py").standardized
        guard let source = try? String(contentsOf: agentPy, encoding: .utf8) else {
            throw XCTSkip("server source not reachable from the test runner")
        }
        XCTAssertTrue(source.contains("PLANNER_PROMPT = \"\"\"" + Prompts.planner + "\"\"\""))
        XCTAssertTrue(source.contains("ACTOR_PROMPT = \"\"\"" + Prompts.actorServer + "\"\"\""))
    }

    func testRunStopsAfterThreeErrorsInARow() async {
        let model = FakeModel { n in n == 1 ? "1. do it" : "no action here" }
        let agent = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: model, planner: model, trace: nil)
        await agent.run()
        XCTAssertEqual(agent.steps.last?["action"], .str("fail"))
        XCTAssertEqual(agent.steps.last?["reason"], .str("3 errors in a row"))
    }

    func testRunFinishesOnDone() async {
        let model = FakeModel { n in n == 1 ? "1. go home" : n == 2 ? "THINK: home\nDO: home" : "THINK: there\nDO: done ok" }
        let phone = FakeGestures()
        let agent = AgentLoop(phone: phone, screen: FakeScreen(), actor: model, planner: model, trace: nil)
        await agent.run()
        XCTAssertEqual(phone.calls, ["home"])
        XCTAssertEqual(agent.steps.map { $0["action"]?.str }, ["plan", "home", "done"])
        XCTAssertEqual(agent.steps.last?["answer"], .str("ok"))
    }
}

// MARK: - fakes

@MainActor final class FakeModel: ChatModel {
    let model = "fake"
    private(set) var prompts: [String] = []
    private(set) var images: [Data?] = []
    private let reply: (Int) throws -> String

    init(_ reply: @escaping (Int) throws -> String) { self.reply = reply }

    func chat(system: String, text: String, image: Data?, maxTokens: Int, temperature: Double) async throws -> ChatResult {
        prompts.append(text)
        images.append(image)
        return ChatResult(text: try reply(prompts.count), firstToken: nil, total: 0)
    }
}

@MainActor final class FakeScreen: ScreenSource {
    var live = true
    var frame: Data? = Data([0xff, 0xd8])
    var updated = 0.0
    var capturedAt = 0.0
    var aspect = 0.46
}

@MainActor final class FakeDevice: HIDDevice {
    var links = 1
    var connected = true
    var sent: [String] = []
    func send(_ command: String) async throws -> String { sent.append(command); return "" }
    func waitConnected(_ timeout: TimeInterval) async -> Bool { connected }
}

@MainActor final class FakeGestures: Gestures {
    let device: HIDDevice = FakeDevice()
    var calls: [String] = []
    var taps: [CGPoint] = []
    func tap(_ x: Double, _ y: Double, aim: Bool) async throws { calls.append("tap"); taps.append(CGPoint(x: x, y: y)) }
    func swipe(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, hold: Bool) async throws { calls.append("swipe") }
    func drag(_ points: [CGPoint], hold: Bool) async throws { calls.append("drag") }
    func type(_ text: String) async throws { calls.append("type") }
    func key(_ combo: String) async throws { calls.append("key") }
    func goHome() async throws { calls.append("home") }
    func openApp(_ name: String) async throws { calls.append("open \(name)") }
    func goBack() async throws { calls.append("back") }
    func reset() async throws { calls.append("reset") }
}

@MainActor private final class ConnectionFailureModel: ChatModel {
    let model = "connection-failure-test"
    private(set) var calls = 0
    let onFirst: () -> Void
    init(_ onFirst: @escaping () -> Void) { self.onFirst = onFirst }
    func chat(system: String, text: String, image: Data?, maxTokens: Int, temperature: Double) async throws -> ChatResult {
        calls += 1
        if calls == 1 {
            onFirst()
            throw URLError(.networkConnectionLost)
        }
        return ChatResult(text: "1. Observe the new screen", total: 0)
    }
}

@MainActor private final class TimeoutModel: ChatModel {
    let model = "timeout-test"
    let failures: Int
    var calls = 0
    init(failures: Int) { self.failures = failures }
    func chat(system: String, text: String, image: Data?, maxTokens: Int, temperature: Double) async throws -> ChatResult {
        calls += 1
        if calls <= failures { throw URLError(.timedOut) }
        return ChatResult(text: "1. Observe the screen", total: 0)
    }
}

@MainActor private final class ProgressModel: ChatModel, ModelProgressReporting {
    let model = "progress-test"
    var onProgress: ((ModelResponseProgress) -> Void)?
    func chat(system: String, text: String, image: Data?, maxTokens: Int, temperature: Double) async throws -> ChatResult {
        onProgress?(.waiting)
        onProgress?(.receiving)
        return ChatResult(text: "THINK: Wait for the screen\nDO: wait", total: 0)
    }
}
