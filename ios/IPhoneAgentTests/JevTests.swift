import XCTest
@testable import IPhoneAgent

@MainActor final class FakeJev: JevStepping {
    var answers: [Result<JevAnswer, Error>] = []
    var delay: UInt64 = 0
    private(set) var inputs: [JevStepInput] = []

    func step(_ input: JevStepInput) async throws -> JevAnswer {
        inputs.append(input)
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return try (answers.isEmpty ? .success(JevAnswer()) : answers.removeFirst()).get()
    }
}

/// A model that answers after a while, or fails; notes whether its request was cancelled.
@MainActor final class SlowModel: ChatModel {
    let model = "slow"
    var delay: UInt64 = 0
    var error: Error?
    private(set) var calls = 0
    private(set) var cancelled = false

    func chat(system: String, text: String, image: Data?, maxTokens: Int, temperature: Double) async throws -> ChatResult {
        calls += 1
        do { try await Task.sleep(nanoseconds: delay) } catch { cancelled = true; throw error }
        if let error { throw error }
        return ChatResult(text: "THINK: model\nDO: tap 1 1", firstToken: nil, total: 0)
    }
}

@MainActor final class JevTests: XCTestCase {
    let jpeg = Data([0xff, 0xd8, 0x01])
    let prompt = "Goal: open Notes\n\nPlan:\n1. Open Notes\n\nRecent actions:\n(none)\n\nNext action?"
        + "\n\nScreen elements:\n#1 Notes"
    let sure = JevAnswer(accept: true, do: "tap 120 340", step_text: "Tap Notes", prob: 0.97)
    let unsure = JevAnswer(accept: false, reason: "unsure")

    private func decider(_ mode: Deciders.Mode, race: Bool = false, model: ChatModel, jev: FakeJev) -> JevDeciderModel {
        JevDeciderModel(inner: model, jev: jev, mode: mode, race: race)
    }

    private func ask(_ m: JevDeciderModel) async throws -> ChatResult {
        try await m.chat(system: "s", text: prompt, image: jpeg, maxTokens: 100, temperature: 0)
    }

    // MARK: deciders

    func testModesAndFreeLineHeader() {
        var d = Deciders.standard(freeLine: true)
        XCTAssertEqual(d.mode, .jevFirst)
        XCTAssertEqual(d.freeLineHeader(race: true, threshold: 0.6), ["X-Handsy-Jev": "race", "X-Handsy-Jev-Threshold": "0.60"])
        d.move(from: [1], to: 0)
        XCTAssertEqual(d.mode, .modelFirst)
        XCTAssertEqual(d.freeLineHeader(race: false), [:])
        d.set(.model, on: false, freeLine: true)  // the free line keeps the model on
        XCTAssertTrue(d.isOn(.model))
        var own = Deciders.standard(freeLine: false)
        XCTAssertEqual(own.mode, .modelOnly)
        own.set(.jev, on: true, freeLine: false)
        own.set(.model, on: false, freeLine: false)
        XCTAssertEqual(own.mode, .jevOnly)
        own.set(.jev, on: false, freeLine: false)  // never both off
        XCTAssertTrue(own.isOn(.jev))
    }

    func testSavedDecidersAndWithdrawTurnsJevOff() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: JevConsent.key)
        defer {
            defaults.set(saved, forKey: JevConsent.key)
            defaults.removeObject(forKey: Deciders.key(freeLine: false))
        }
        JevConsent.grant()
        Deciders(order: [.model, .jev], off: []).save(freeLine: false)
        XCTAssertEqual(Deciders.load(freeLine: false).mode, .modelFirst)
        JevConsent.revoke()
        XCTAssertEqual(Deciders.load(freeLine: false).mode, .modelOnly)
    }

    func testParsesTheActorPrompt() {
        let input = JevStepInput.parse(prompt, image: jpeg)
        XCTAssertEqual(input, JevStepInput(goal: "open Notes", plan: "1. Open Notes", history: "(none)", image: jpeg))
        XCTAssertNil(JevStepInput.parse("Goal: open Notes", image: jpeg))  // the planner's prompt
        XCTAssertNil(JevStepInput.parse(prompt, image: Data([0x89, 0x50])))  // Jev takes JPEG only
        let unplanned = prompt.replacingOccurrences(of: "1. Open Notes", with: "(none yet: write one)")
        XCTAssertNil(JevStepInput.parse(unplanned, image: jpeg))  // no numbered plan yet: Jev is not asked
    }

    func testThresholdSettingIsClampedAndDefaultsTo60() {
        let defaults = UserDefaults.standard
        defer { defaults.removeObject(forKey: JevConfig.thresholdKey) }
        defaults.removeObject(forKey: JevConfig.thresholdKey)
        XCTAssertEqual(JevConfig.threshold, 0.55)
        defaults.set(0.1, forKey: JevConfig.thresholdKey)
        XCTAssertEqual(JevConfig.threshold, 0.5)
        defaults.set(0.75, forKey: JevConfig.thresholdKey)
        XCTAssertEqual(JevConfig.threshold, 0.75)
        XCTAssertTrue(Deciders.race(UserDefaults(suiteName: "jev-race-\(UUID())")!))  // asks both at once by default
    }

    // MARK: modes

    func testJevFirstTakesTheStepWithoutTheModel() async throws {
        let model = SlowModel(), jev = FakeJev()
        jev.answers = [.success(sure)]
        let reply = try await ask(decider(.jevFirst, model: model, jev: jev))
        XCTAssertEqual(reply.text, "THINK: Jev - Tap Notes\nDO: tap 120 340")
        XCTAssertEqual(reply.servedModel, "handsy-jev")
        XCTAssertEqual(model.calls, 0)
    }

    func testAfterARoundOfSeveralGesturesTheModelTakesTheStep() async throws {
        let model = SlowModel(), jev = FakeJev()
        jev.answers = [.success(sure)]
        JevGate.hold = true
        defer { JevGate.hold = false }
        let reply = try await ask(decider(.jevFirst, model: model, jev: jev))
        XCTAssertEqual(model.calls, 1)
        XCTAssertNil(reply.servedModel)
        XCTAssertEqual(Deciders.standard(freeLine: true).freeLineHeader(race: true), [:])  // the free line too
    }

    func testJevFirstLeavesUnsureStepsToTheModel() async throws {
        let model = SlowModel(), jev = FakeJev()
        jev.answers = [.success(unsure)]
        let reply = try await ask(decider(.jevFirst, model: model, jev: jev))
        XCTAssertEqual(model.calls, 1)
        XCTAssertNil(reply.servedModel)
    }

    func testRaceCancelsTheModelWhenJevIsSure() async throws {
        let model = SlowModel(), jev = FakeJev()
        model.delay = 2_000_000_000
        jev.answers = [.success(sure)]
        let reply = try await ask(decider(.jevFirst, race: true, model: model, jev: jev))
        XCTAssertEqual(reply.servedModel, "handsy-jev")
        XCTAssertEqual(model.calls, 1)
        XCTAssertTrue(model.cancelled)
    }

    func testRaceWaitsForTheModelWhenJevIsUnsure() async throws {
        let model = SlowModel(), jev = FakeJev()
        model.delay = 50_000_000
        jev.answers = [.success(unsure)]
        let reply = try await ask(decider(.jevFirst, race: true, model: model, jev: jev))
        XCTAssertEqual(reply.text, "THINK: model\nDO: tap 1 1")
    }

    func testJevNeverEndsARun() async throws {
        let model = SlowModel(), jev = FakeJev()
        jev.answers = [.success(JevAnswer(accept: true, do: "done Done: Duolingo", step_text: "", prob: 0.95))]
        let reply = try await ask(decider(.jevFirst, model: model, jev: jev))
        XCTAssertEqual(model.calls, 1)  // the model alone decides the goal is reached
        XCTAssertNil(reply.servedModel)
    }

    func testJevOnlyTurnsUnsureIntoFail() async throws {
        let model = SlowModel(), jev = FakeJev()
        jev.answers = [.success(unsure)]
        let reply = try await ask(decider(.jevOnly, model: model, jev: jev))
        XCTAssertEqual(reply.text, JevDeciderModel.unsure)
        XCTAssertEqual(try Actions.parseActions(reply.text).first?["action"]?.str, "fail")
        XCTAssertEqual(model.calls, 0)
    }

    func testModelFirstAsksJevOnlyWhenTheModelFails() async throws {
        let model = SlowModel(), jev = FakeJev()
        let fine = try await ask(decider(.modelFirst, model: model, jev: jev))
        XCTAssertNil(fine.servedModel)
        XCTAssertTrue(jev.inputs.isEmpty)
        model.error = LLMError(message: "down", status: 502)
        jev.answers = [.success(sure)]
        let rescued = try await ask(decider(.modelFirst, model: model, jev: jev))
        XCTAssertEqual(rescued.servedModel, "handsy-jev")
    }

    // MARK: breaker

    func testBreakerOpensProbesAndBacksOff() {
        var t = 0.0
        let b = Breaker("test") { t }
        for _ in 0..<2 { b.record(ok: false) }
        XCTAssertTrue(b.allow())
        b.record(ok: false)  // the 3rd failure within 60 s
        XCTAssertFalse(b.allow())
        t = 121
        XCTAssertTrue(b.allow())   // the one probe
        XCTAssertFalse(b.allow())  // and only one
        b.record(ok: false)        // failed: open twice as long
        t = 121 + 239
        XCTAssertFalse(b.allow())
        t = 121 + 241
        XCTAssertTrue(b.allow())
        b.record(ok: true)
        XCTAssertTrue(b.allow())
        XCTAssertFalse(b.isOpen)
    }

    func testOldFailuresDoNotCount() {
        var t = 0.0
        let b = Breaker("test") { t }
        b.record(ok: false); t = 30
        b.record(ok: false); t = 95  // the first one is older than 60 s
        b.record(ok: false)
        XCTAssertTrue(b.allow())
    }

    func testUnsureIsNotAFailureButDownIs() async throws {
        let model = SlowModel(), jev = FakeJev()
        let m = decider(.jevFirst, model: model, jev: jev)
        jev.answers = Array(repeating: .success(unsure), count: 4)
        for _ in 0..<4 { _ = try await ask(m) }
        XCTAssertFalse(m.jevBreaker.isOpen)
        jev.answers = [.failure(URLError(.timedOut)), .success(JevAnswer(reason: "unavailable")), .failure(URLError(.timedOut))]
        for _ in 0..<3 { _ = try await ask(m) }
        XCTAssertTrue(m.jevBreaker.isOpen)
        jev.answers = [.success(sure)]
        let skipped = try await ask(m)  // straight to the model while open
        XCTAssertNil(skipped.servedModel)
        XCTAssertEqual(jev.inputs.count, 7)
    }

    // MARK: client

    func testStepClientSendsTheStepAndReadsTheAnswer() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        StubProtocol.seen = []
        StubProtocol.respond = { _ in (200, "application/json", #"{"accept":true,"do":"tap 5 6","step_text":"Tap","prob":0.9}"#) }
        let client = JevStepClient(url: URL(string: "https://jev.test/trial/jev/step"), session: URLSession(configuration: config)) { "t1" }
        let answer = try await client.step(JevStepInput.parse(prompt, image: jpeg)!)
        XCTAssertTrue(answer.taken)
        let sent = try XCTUnwrap(StubProtocol.seen.last)
        XCTAssertEqual(sent["ticket"] as? String, "t1")
        XCTAssertEqual(sent["goal"] as? String, "open Notes")
        XCTAssertEqual(sent["history"] as? String, "(none)")
        XCTAssertEqual(sent["image"] as? String, "data:image/jpeg;base64," + jpeg.base64EncodedString())
        StubProtocol.respond = { _ in (503, "application/json", "{}") }
        do { _ = try await client.step(JevStepInput.parse(prompt, image: jpeg)!); XCTFail("503 is a failure") } catch {}
    }

    // MARK: own TypeSafe key

    private func choice(_ c: String, _ ids: [String]) -> [String: Any] {
        ["choice": c, "confidence": 0.9, "probabilities": Dictionary(uniqueKeysWithValues: ids.map { ($0, $0 == c ? 0.9 : 0.1 / Double(ids.count - 1)) })]
    }

    func testTypeSafeRepliesLikeTheServer() {
        let steps = JevRules.planSteps("1. Open Notes\n2. Tap New note")
        XCTAssertEqual(steps.map(\.key), ["1", "2"])
        let ids = ["step 1", "step 2", "done", "other"], ops = Array(JevRules.operations.keys)
        let open = JevRules.reply(steps: steps, response: ["answers": ["step": choice("step 1", ids), "operation": choice("OPEN", ops)]])
        XCTAssertEqual(open?.do, "open Notes")
        XCTAssertEqual(open?.taken, true)
        let box: [String: Any] = ["confidence": 0.95, "box": ["top": 0.1, "bottom": 0.2, "left": 0.4, "right": 0.6]]
        let tap = JevRules.reply(steps: steps, response: ["answers": ["step": choice("step 2", ids), "operation": choice("TAP", ops), "box_2": box]])
        XCTAssertEqual(tap?.do, "tap 500 150")
        let done = JevRules.reply(steps: steps, response: ["answers": ["step": choice("done", ids), "operation": choice("DONE", ops)]])
        XCTAssertEqual(done?.taken, false)  // only the model ends a run
        XCTAssertNil(JevRules.reply(steps: steps, response: ["answers": ["step": ["choice": "step 1"]]]))
        let tapAt = { (p: Double, history: String?, accept: Double) in
            let b: [String: Any] = ["confidence": p, "box": ["top": 0.1, "bottom": 0.2, "left": 0.4, "right": 0.6]]
            return JevRules.reply(steps: steps, response: ["answers": ["step": self.choice("step 2", ids), "operation": self.choice("TAP", ops), "box_2": b]],
                                  history: history, accept: accept)
        }
        XCTAssertEqual(tapAt(0.65, nil, 0.6)?.taken, true)  // the user's own setting
        XCTAssertEqual(tapAt(0.65, nil, 0.7)?.taken, false)
        for result in ["screen changed", "screen did NOT change"] {  // a tap on the last tap's spot goes to the model
            XCTAssertEqual(tapAt(0.95, "{\"action\": \"tap\", \"x\": 505, \"y\": 160} -> \(result)", 0.6)?.reason, "repeat")
        }
        let tapLine = { (x: Int, y: Int) in "{\"action\": \"tap\", \"x\": \(x), \"y\": \(y)} -> screen changed" }
        let aba = [tapLine(505, 160), tapLine(200, 800), "{\"action\": \"wait\"} -> screen changed"].joined(separator: "\n")
        XCTAssertEqual(tapAt(0.95, aba, 0.6)?.reason, "repeat")  // tap A, tap B, tap A: a loop
        let older = ([tapLine(505, 160)] + (0..<4).map { tapLine(100 + $0 * 100, 900) }).joined(separator: "\n")
        XCTAssertEqual(tapAt(0.95, older, 0.6)?.taken, true)  // 5 taps back: not a repeat
        let wait = JevRules.reply(steps: steps, response: ["answers": ["step": choice("step 2", ids), "operation": choice("WAIT", ops)]], accept: 0.5)
        XCTAssertEqual(wait?.taken, false)
    }

    func testTypeSafeFloorsPerOperationAsTheServer() {
        let steps = JevRules.planSteps("1. Open Notes\n2. Tap New note\n3. Type \"milk\"")
        let ids = ["step 1", "step 2", "step 3", "done", "other"], ops = Array(JevRules.operations.keys)
        let op = { (op: String, step: String, p: Double, history: String?) -> JevAnswer? in
            let probs = Dictionary(uniqueKeysWithValues: ops.map { ($0, $0 == op ? p : (1 - p) / Double(ops.count - 1)) })
            let box: [String: Any] = ["confidence": 0.99, "box": ["top": 0.1, "bottom": 0.2, "left": 0.4, "right": 0.6]]
            return JevRules.reply(steps: steps, response: ["answers": [
                "step": self.choice(step, ids), "operation": ["choice": op, "confidence": p, "probabilities": probs], "box_2": box]],
                history: history)
        }
        XCTAssertEqual(op("TAP", "step 2", 0.58, nil)?.taken, true, "TAP: the user's setting, default 0.55")
        XCTAssertEqual(op("OPEN", "step 1", 0.65, nil)?.taken, false, "OPEN, TYPE, HOME, BACK: at least 0.7")
        XCTAssertEqual(op("OPEN", "step 1", 0.72, nil)?.taken, true)
        XCTAssertEqual(op("TYPE", "step 3", 0.65, nil)?.taken, false)
        XCTAssertEqual(op("TYPE", "step 3", 0.72, nil)?.do, "type milk")
        XCTAssertEqual(op("WAIT", "step 2", 0.99, nil)?.taken, false, "WAIT is never Jev's")
        XCTAssertEqual(JevRules.acceptFloor("HOME", threshold: 0.55, history: nil), 0.7)
        XCTAssertEqual(JevRules.acceptFloor("BACK", threshold: 0.8, history: nil), 0.8, "a higher setting raises every floor")
        let unchanged = "{\"action\": \"tap\", \"x\": 100, \"y\": 900} -> screen did NOT change"
        let changed = "{\"action\": \"tap\", \"x\": 100, \"y\": 900} -> screen changed"
        XCTAssertEqual(op("TAP", "step 2", 0.6, unchanged)?.taken, false, "after a round that changed nothing: 0.1 more")
        XCTAssertEqual(op("TAP", "step 2", 0.67, unchanged)?.taken, true)
        XCTAssertEqual(op("TAP", "step 2", 0.6, unchanged + "\n" + changed)?.taken, true, "only the previous round counts")
        XCTAssertEqual(op("TAP", "step 2", 0.6, changed + "\n" + unchanged + "\n{\"action\": \"hiccup\"}")?.taken, false)
    }

    func testShortProviderError() {
        let raw = "GET /models: HTTP 400 {\n  \"error\": {\n    \"message\": \"Please pass a valid API key\"\n  }\n}"
        XCTAssertEqual(ProviderFields.short(raw), "Please pass a valid API key")
        XCTAssertEqual(ProviderFields.short("timed out"), "timed out")
    }
}
