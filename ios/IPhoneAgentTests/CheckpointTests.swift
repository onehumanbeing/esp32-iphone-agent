import XCTest
@testable import IPhoneAgent

/// Checkpoints: the rounds the planner model answers instead of the actor (free line or the own Planner model).
@MainActor final class CheckpointTests: XCTestCase {
    private func swipe() -> JObject { ["action": .str("swipe"), "x1": .int(500), "y1": .int(700), "x2": .int(500), "y2": .int(300)] }

    func testReasons() {
        var c = Checkpoints()
        XCTAssertEqual(c.reason([]), "first round")
        c.used(at: 0)
        XCTAssertNil(c.reason([["action": .str("tap")]]))
        let circling = [swipe(), swipe(), swipe(), swipe()]
        XCTAssertEqual(c.reason(circling), "circling", "four swipes in a row, the plan unchanged")
        XCTAssertNil(c.reason([swipe(), ["action": .str("plan"), "plan": .str("2. x")], swipe(), swipe(), swipe()]),
                     "a new plan is progress")
        XCTAssertNil(c.reason([swipe(), swipe(), ["action": .str("tap")], swipe()]))
        c.used(at: 4)
        XCTAssertNil(c.reason(circling + [swipe()]), "counted again from the last checkpoint")
        let taps: [JObject] = Array(repeating: ["action": .str("tap")], count: Checkpoints.reviewEvery)
        XCTAssertNil(c.reason(Array(circling.prefix(4)) + taps.prefix(0)), "counted from 4")
        let plan: JObject = ["action": .str("plan"), "plan": .str("x")]
        let long: [JObject] = Array(taps.prefix(4)) + taps + [plan]
        XCTAssertEqual(c.reason(long), "review", "the planner looks over a long stretch, a new plan or not")
        c.asked = "repeat"
        XCTAssertEqual(c.reason([]), "repeat")
        c.used(at: 5)
        XCTAssertNil(c.asked)
    }

    func testRevisitedScreenGoesToThePlannerOnTheThirdTime() {
        func tap(_ x: Int) -> JObject { ["action": .str("tap"), "x": .int(x), "y": .int(500), "shot": .bool(true)] }
        let note: JObject = ["action": .str("note"), "text": .str("x")]
        // screens by step index: 0 A, 1 B, 2 A, 3 B, 4 A
        let screens = ["A", "B", "A", "B", "A"]
        let same = { (i: Int, j: Int) in screens[i] == screens[j] }
        let steps = [tap(1), tap(2), tap(3), tap(4), tap(5)]
        XCTAssertTrue(Checkpoints.revisited(steps, from: 0, same: same), "A for the third time")
        XCTAssertFalse(Checkpoints.revisited(Array(steps.prefix(3)), from: 0, same: same), "only twice")
        XCTAssertFalse(Checkpoints.revisited(steps, from: 1, same: same), "counted from the last checkpoint")
        var noted = steps
        noted.insert(note, at: 3)  // a notebook row between the second and third A: the run got somewhere
        let notedSame = { (i: Int, j: Int) in (i == 3 || j == 3) ? false : screens[i < 3 ? i : i - 1] == screens[j < 3 ? j : j - 1] }
        XCTAssertFalse(Checkpoints.revisited(noted, from: 0, same: notedSame))
        let all = Array(repeating: tap(1), count: 5)
        XCTAssertFalse(Checkpoints.revisited(all, from: 0, same: { _, _ in false }), "new screens each time")
    }

    private func agent(actor: FakeModel, planner: FakeModel?) -> AgentLoop {
        let screen = FakeScreen()
        let a = AgentLoop(phone: FakeGestures(), screen: screen, actor: actor, planner: nil, trace: nil)
        a.checkpointModel = planner
        return a
    }

    func testFirstRoundGoesToThePlanner() async throws {
        let actor = FakeModel { _ in "THINK: a\nDO: tap 100 200" }, planner = FakeModel { _ in "THINK: p\nPLAN:\n1. x\nDO: tap 300 400" }
        let a = agent(actor: actor, planner: planner)
        let first = try await a.nextActions()
        XCTAssertEqual(first.first?.act["x"], .int(300))
        XCTAssertEqual(planner.prompts.count, 1)
        XCTAssertEqual(actor.prompts.count, 0)
        a.steps.append(first[0].act)
        _ = try await a.nextActions()
        XCTAssertEqual(actor.prompts.count, 1, "later rounds: the actor")
        XCTAssertEqual(planner.prompts.count, 1)
    }

    func testTheActorsDoneIsCheckedByThePlanner() async throws {
        let actor = FakeModel { _ in "THINK: found\nDO: done the address" }
        let planner = FakeModel { _ in "THINK: rating missing but not shown\nDO: done address 29 Essex St; no rating shown" }
        let a = agent(actor: actor, planner: planner)
        a.checkpoints.used(at: 0)  // past the first round
        let acts = try await a.nextActions()
        XCTAssertEqual(actor.prompts.count, 1)
        XCTAssertEqual(planner.prompts.count, 1)
        XCTAssertEqual(acts.first?.act["action"], .str("done"))
        XCTAssertEqual(acts.first?.act["answer"]?.str, "address 29 Essex St; no rating shown")
    }

    func testThePlannerCanOverruleADone() async throws {
        let actor = FakeModel { _ in "THINK: done\nDO: done ok" }, planner = FakeModel { _ in "THINK: not yet\nDO: tap 10 20" }
        let a = agent(actor: actor, planner: planner)
        a.checkpoints.used(at: 0)
        let acts = try await a.nextActions()
        XCTAssertEqual(acts.first?.act["action"], .str("tap"))
    }

    func testAFailingPlannerFallsBackToTheActor() async throws {
        let actor = FakeModel { _ in "THINK: a\nDO: tap 100 200" }, planner = FakeModel { _ in "" }
        planner.error = LLMError(message: "unknown model")
        let a = agent(actor: actor, planner: planner)
        let acts = try await a.nextActions()
        XCTAssertEqual(acts.first?.act["x"], .int(100))
        XCTAssertEqual(actor.prompts.count, 1)
    }

    func testWithoutAPlannerNothingChanges() async throws {
        let actor = FakeModel { _ in "THINK: done\nDO: done ok" }
        let a = agent(actor: actor, planner: nil)
        let acts = try await a.nextActions()
        XCTAssertEqual(acts.first?.act["action"], .str("done"))
        XCTAssertEqual(actor.prompts.count, 1)
    }

    /// Own endpoint: a Planner model set and different from the actor's answers the checkpoints; else none.
    func testOwnPlannerModelBecomesTheCheckpointModel() async throws {
        let name = "checkpoint-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = Settings(defaults: defaults, info: [:])
        settings.selectProvider(.others)
        settings.baseURL = "http://192.168.1.4:8080/v1"
        settings.model = "fast-vision"
        let none = try await settings.checkpointClient()
        XCTAssertNil(none, "no Planner model: every round goes to the actor")
        settings.plannerModel = "fast-vision"
        let same = try await settings.checkpointClient()
        XCTAssertNil(same, "the same model as the actor")
        settings.plannerModel = "strong-vision"
        let planner = try await settings.checkpointClient()
        XCTAssertEqual(planner?.model, "strong-vision")
        settings.actorModel = "strong-vision"
        let both = try await settings.checkpointClient()
        XCTAssertNil(both, "the actor is already that model")
    }

    /// Recordings are read by one's own Planner model (else the shared one); the free line only where the server allows.
    func testRecordingReader() async throws {
        let name = "recording-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = Settings(defaults: defaults, info: [:])
        settings.selectProvider(.others)
        settings.baseURL = "http://192.168.1.4:8080/v1"
        settings.model = "fast-vision"
        let shared = try await settings.recordingClient()
        XCTAssertEqual(shared?.model, "fast-vision")
        settings.plannerModel = "strong-vision"
        let planner = try await settings.recordingClient()
        XCTAssertEqual(planner?.model, "strong-vision")
        settings.selectedProvider = .handsyTrial
        let free = try await settings.recordingClient()
        XCTAssertNil(free, "Manina AI Free: not this install (the server never said recording)")
        guard settings.provider == .handsyTrial else { return }  // a build without the free line
        Trial.shared.setKey("hsk_test_" + String(repeating: "k", count: 43))
        defer { Trial.shared.setKey("") }
        let paid = try await settings.recordingClient()
        XCTAssertEqual(paid?.model, Trial.recordingModel, "a Manina AI key pays for recordings")
        XCTAssertEqual(try Trial.shared.recordingHeaders()["Authorization"], "Bearer hsk_test_" + String(repeating: "k", count: 43))
    }

    func testThePlannerFlagMarksItsRounds() async throws {
        let actor = FakeModel { _ in "THINK: a\nDO: tap 100 200" }, planner = FakeModel { _ in "THINK: p\nDO: tap 300 400" }
        let a = agent(actor: actor, planner: planner)
        let first = try await a.nextActions()
        XCTAssertEqual(first.first?.act["planner"], .bool(true))
        a.steps.append(first[0].act)
        let second = try await a.nextActions()
        XCTAssertNil(second.first?.act["planner"])
    }
}
