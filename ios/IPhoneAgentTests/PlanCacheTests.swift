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
}
