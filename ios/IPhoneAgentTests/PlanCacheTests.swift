import XCTest
@testable import IPhoneAgent

@MainActor
final class PlanCacheTests: XCTestCase {
    private func tempFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    func testAPlanIsAFileKeptWhileTheWordsAreUnchanged() throws {
        let folder = tempFolder()
        let cache = PlanCache(folder: folder)
        var intent = SavedTask(name: "Orders: last 3", prompt: "Open the shop, list my last 3 orders")
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        cache.save("1. Orders tab\n2. note each", for: intent, run: "r1", now: day)
        XCTAssertEqual(cache.entry(for: intent, now: day)?.plan, "1. Orders tab\n2. note each")
        let file = try XCTUnwrap(cache.entries[intent.id]?.url)
        XCTAssertEqual(file.lastPathComponent, "Orders  last 3.md", "named after the intent, no path characters")
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("\n---\n\n1. Orders tab\n2. note each\n"))
        XCTAssertEqual(PlanCache(folder: folder).entry(for: intent, now: day)?.run, "r1", "read back from the file")
        intent.hints = ["a lesson the app added"]
        XCTAssertNotNil(cache.entry(for: intent, now: day), "checklist lessons don't count")
        XCTAssertNil(cache.entry(for: intent, now: day + PlanCache.maxAge + 1), "too old")
        XCTAssertNotNil(cache.stale(for: intent, now: day + PlanCache.maxAge + 1))
        var edited = intent
        edited.prompt += " and their dates"
        XCTAssertNil(cache.entry(for: edited, now: day), "the words changed")
        cache.forget(run: "r1")
        XCTAssertNil(cache.entry(for: intent, now: day))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        cache.save("1. again", for: intent, run: "r2", now: day)
        cache.forget(intent.id)
        XCTAssertNil(PlanCache(folder: folder).entry(for: intent, now: day), "forgotten by hand, the file too")
    }

    func testAPlanTheUserEditedIsTheirs() throws {
        let folder = tempFolder()
        let cache = PlanCache(folder: folder)
        let intent = SavedTask(name: "Cleaning", prompt: "book a cleaning")
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        cache.save("1. app plan", for: intent, run: "r1", now: day)
        let file = try XCTUnwrap(cache.entries[intent.id]?.url)
        XCTAssertTrue(cache.update(file, plan: "1. my plan\n2. earliest morning slot"))
        XCTAssertEqual(cache.entry(for: intent, now: day)?.edited, true)
        cache.save("1. newer app plan", for: intent, run: "r2", now: day)
        cache.drop(intent.id)
        cache.forget(run: "r1")
        let kept = PlanCache(folder: folder).entry(for: intent, now: day + 30 * 24 * 3600)
        XCTAssertEqual(kept?.plan, "1. my plan\n2. earliest morning slot", "not overwritten, dropped or expired")
        var reworded = intent
        reworded.prompt = "book a deep cleaning"
        XCTAssertNil(cache.entry(for: reworded, now: day), "other words end it")
        cache.save("1. plan for the new words", for: reworded, run: "r3", now: day)
        XCTAssertEqual(cache.entry(for: reworded, now: day)?.plan, "1. plan for the new words")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 1, "same file")
    }

    func testAFileFromANewerAppIsReadButNeverWrittenOver() throws {
        let folder = tempFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let intent = SavedTask(name: "Orders", prompt: "list my orders")
        let text = """
        ---
        format: 2
        intent: \(intent.id.uuidString)
        instruction: \(PlanCache.key(intent))
        saved: 2026-11-18T10:00:00Z
        steps: 4
        ---
        1. go
        """
        let file = folder.appendingPathComponent("Orders.md")
        try Data(text.utf8).write(to: file)
        try Data("# just notes".utf8).write(to: folder.appendingPathComponent("notes.md"))
        let cache = PlanCache(folder: folder)
        let day = ISO8601DateFormatter().date(from: "2026-11-19T10:00:00Z")!
        XCTAssertEqual(cache.entry(for: intent, now: day)?.plan, "1. go", "unknown header lines ignored")
        XCTAssertEqual(cache.entries.count, 1, "a file without the header is not a plan")
        cache.save("1. mine", for: intent, run: "r1")
        cache.drop(intent.id)
        XCTAssertFalse(cache.update(file, plan: "x"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), text, "the newer file stays as it was")
        var parsed = try XCTUnwrap(PlanFile.parse(text))
        parsed.format = 1
        XCTAssertTrue(parsed.text.contains("\nsteps: 4\n"), "unknown lines are written back")
    }

    func testTheAgentCannotWriteThePlansFolder() {
        XCTAssertTrue(MemoryFiles.isReserved("Plans/Orders.md"))
        XCTAssertTrue(PlanCache.holds("Plans/Orders.md"))
        XCTAssertFalse(PlanCache.holds("Orders/Plans.md"))
        XCTAssertFalse(FileSandbox.canChange("Plans"), "the folder stays")
        XCTAssertTrue(FileSandbox.canChange("Plans/Orders.md"), "the user may delete a plan")
    }

    func testARunWithASavedPlanSkipsThePlannersFirstRound() async throws {
        let planned = "1. Orders tab\n2. note each order"
        let planner = FakeModel { _ in "THINK: orders are under the tab\nPLAN:\n\(planned)\nDO: done ok" }
        let actor = FakeModel { _ in "THINK: done\nDO: done ok" }
        let first = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: actor, planner: planner, trace: nil)
        first.checkpointModel = planner
        try first.start("list my orders")
        await first.waitUntilStopped()
        XCTAssertEqual(first.firstPlan, planned, "the planner's first plan is what gets kept")
        XCTAssertFalse(first.usedCachedPlan)

        let planner2 = FakeModel { _ in "THINK: done\nDO: done ok" }
        let actor2 = FakeModel { _ in "THINK: done\nDO: done ok" }
        let second = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: actor2, planner: planner2, trace: nil)
        second.checkpointModel = planner2
        second.cachedPlan = planned
        try second.start("list my orders")
        await second.waitUntilStopped()
        XCTAssertTrue(second.usedCachedPlan)
        XCTAssertTrue(actor2.prompts.first?.contains(planned) == true, "the actor takes the first round with the saved plan")
        XCTAssertTrue(second.steps.contains { $0["cached"] == .bool(true) })
        XCTAssertNil(second.cachedPlan, "used once")
        XCTAssertFalse(planner2.prompts.contains { $0.contains("Plan:\n(none yet") }, "no first-round plan asked for")
    }

    // MARK: PlanJudge: after any run, a fast model says whether the plan is kept

    private let plan = "1. Open the shop app\n2. Orders tab\n3. note each order"
    private func stopped() -> [JObject] {
        [["action": .str("plan"), "plan": .str("1. Open the shop app")],
         ["action": .str("tap"), "x": .int(100), "y": .int(200), "thought": .str("the Orders tab is at the bottom")],
         ["action": .str("stopped"), "reason": .str("stopped by the user")]]
    }

    func testAYesSavesThePlanFromTextOnly() async throws {
        let cache = PlanCache(folder: tempFolder())
        let intent = SavedTask(name: "Orders", prompt: "list my orders")
        let judge = FakeModel { _ in "**YES** — right app, right order" }
        let notes = PlanJudge.notes(task: intent.prompt, plan: plan, steps: stopped(), latestPlan: plan, progress: "")
        let kept = await PlanJudge.keep(plan, for: intent, run: "r1", notes: notes, model: judge, cache: cache) { true }
        XCTAssertEqual(kept, .yes)
        XCTAssertEqual(cache.entry(for: intent)?.plan, plan)
        XCTAssertEqual(cache.entry(for: intent)?.run, "r1")
        XCTAssertEqual(judge.images, [nil], "never a screen")
        let asked = try XCTUnwrap(judge.prompts.first)
        XCTAssertTrue(asked.contains("Task: list my orders") && asked.contains(plan))
        XCTAssertTrue(asked.contains("The user stopped it.") && asked.contains("the Orders tab is at the bottom"))
        XCTAssertTrue(asked.contains("after 1 step(s)"))
    }

    func testANoOrAnErrorSavesNothing() async {
        let intent = SavedTask(name: "Orders", prompt: "list my orders")
        for (reply, expected) in [("NO: it opens the wrong app", PlanJudge.Kept.no), ("I am not sure.", .error)] {
            let cache = PlanCache(folder: tempFolder())
            let kept = await PlanJudge.keep(plan, for: intent, run: "r1", notes: "n", model: FakeModel { _ in reply }, cache: cache) { true }
            XCTAssertEqual(kept, expected, reply)
            XCTAssertNil(cache.entry(for: intent), reply)
        }
        let cache = PlanCache(folder: tempFolder())
        let failing = FakeModel { _ in "YES: fine" }
        failing.error = LLMError(message: "offline")
        let kept = await PlanJudge.keep(plan, for: intent, run: "r1", notes: "n", model: failing, cache: cache) { true }
        XCTAssertEqual(kept, .error)
        XCTAssertNil(cache.entry(for: intent), "an error keeps nothing")
        let none = await PlanJudge.keep(plan, for: intent, run: "r1", notes: "n", model: nil, cache: cache) { true }
        XCTAssertEqual(none, .error, "no model: not kept")
        let unwanted = await PlanJudge.keep(plan, for: intent, run: "r1", notes: "n", model: FakeModel { _ in "YES: ok" },
                                            cache: cache) { false }
        XCTAssertEqual(unwanted, .no, "✗ or Reuse Plan off while it was asked")
        XCTAssertNil(cache.entry(for: intent))
    }

    func testWhichRunsAreJudged() {
        func step(reuse: Bool = true, learn: Bool = true, rejected: Bool = false, plan: String? = "1. go",
                  usedCached: Bool = false, cachedKept: Bool = false, _ outcome: Outcome) -> PlanJudge.Step {
            PlanJudge.step(reuse: reuse, learn: learn, rejected: rejected, plan: plan, usedCached: usedCached,
                           cachedKept: cachedKept, outcome: outcome)
        }
        for outcome in [Outcome.done, .stopped, .failed] {
            XCTAssertEqual(step(outcome), .judge("1. go"), "any end is judged, a stop by the user too: \(outcome)")
            XCTAssertEqual(step(reuse: false, outcome), .skip, "Reuse Plan off: not saved")
            XCTAssertEqual(step(learn: false, outcome), .skip, "Learn from runs off")
            XCTAssertEqual(step(rejected: true, outcome), .skip)
            XCTAssertEqual(step(plan: nil, outcome), .skip, "no first plan")
            XCTAssertEqual(step(plan: " ", outcome), .skip)
        }
        XCTAssertEqual(step(usedCached: true, cachedKept: true, .failed), .drop, "the saved plan failed: dropped")
        XCTAssertEqual(step(usedCached: true, cachedKept: false, .failed), .drop)
        XCTAssertEqual(step(usedCached: true, cachedKept: true, .stopped), .skip, "stopped by the user: kept as it is")
        XCTAssertEqual(step(usedCached: true, cachedKept: true, .done), .skip)
        XCTAssertEqual(step(usedCached: true, cachedKept: false, .stopped), .judge("1. go"), "forgotten meanwhile: asked again")
        XCTAssertEqual(step(reuse: false, usedCached: true, cachedKept: true, .failed), .skip)
    }

    func testTheVerdictLine() {
        XCTAssertEqual(PlanJudge.verdict("YES: right app")?.keep, true)
        XCTAssertEqual(PlanJudge.verdict("YES: right app")?.reason, "right app")
        XCTAssertEqual(PlanJudge.verdict("Thinking first.\nNo — it misses the Orders tab")?.keep, false)
        XCTAssertEqual(PlanJudge.verdict("> \"yes\", it works")?.keep, nil, "a quote mark is not a verdict line")
        XCTAssertNil(PlanJudge.verdict("NOTE: hard to say\nYesterday's plan"), "words that only start like it")
        XCTAssertNil(PlanJudge.verdict(""))
    }

    func testReusePlanSwitchDecodesOldIntentsAsOn() throws {
        let old = #"[{"id":"7C1D4B6A-1F7E-4B9B-9F5A-2E7A0C7B1D11","name":"Orders","prompt":"list my orders"}]"#
        let item = try XCTUnwrap(JSONDecoder().decode([SavedTask].self, from: Data(old.utf8)).first)
        XCTAssertNil(item.planReuse)
        XCTAssertTrue(item.reusesPlan, "saved before the switch: on")
        var off = item
        off.planReuse = false
        let back = try JSONDecoder().decode(SavedTask.self, from: JSONEncoder().encode(off))
        XCTAssertFalse(back.reusesPlan)
    }

    func testTheRunEndSaysWhetherTheRunStartedFromASavedPlan() {
        var end = RunEnd(reason: .userStop, stage: .running)
        XCTAssertNil(end.json["plan_cached"], "a failed start says nothing")
        end.planCached = true
        XCTAssertEqual(end.json["plan_cached"] as? Bool, true)
    }
}
