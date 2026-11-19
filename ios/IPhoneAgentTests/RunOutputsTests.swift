import XCTest
@testable import IPhoneAgent

/// What a run saved (from its file / snap steps) and which intent started it.
@MainActor final class RunOutputsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("outputs-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func touch(_ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    private func run(_ results: [(String, String)], id: String = "20261116-101010") -> Run {
        let steps = results.enumerated().map { i, r in
            Run.Step(id: i, action: ["action": .str(r.0), "reason": .str(r.1)], frame: nil, t: nil)
        }
        return Run(id: id, folder: root, task: "Save my orders", date: Date(), steps: steps)
    }

    func testFilesComeFromOkFileAndSnapSteps() throws {
        try touch("orders/README.md")  // written as results/orders/… before 2026-11-17, moved to the top since
        try touch("orders/page-01.jpg")
        try touch("notes.md")
        try touch("old/a.md")
        let r = run([
            ("file", "ok: created results/orders/README.md (812 bytes)"),
            ("snap", "ok: saved results/orders/page-01.jpg (40213 bytes)"),
            ("file", "ok: edited results/orders/README.md (900 bytes)"),
            ("file", "ok: created ./notes.md (3 bytes)"),
            ("file", "refused: MEMORY.md is the user's"),
            ("file", "ok: results/old/a.md\n1\tx"),  // a view, not a write
            ("tap", "ok: created results/fake.md (1 bytes)"),  // not a file step
            ("file", "ok: created results/gone/x.md (1 bytes)"),  // deleted since: not on disk
        ])
        XCTAssertEqual(RunOutputs.files(r, root: root), ["orders/README.md", "orders/page-01.jpg", "notes.md"])
        XCTAssertEqual(RunOutputs.items(r, root: root), ["orders", "notes.md"])
        XCTAssertEqual(RunOutputs.source(of: "orders", in: [r], root: root)?.id, r.id)
        XCTAssertNil(RunOutputs.source(of: "old", in: [r], root: root))
    }

    func testRenameAndDeleteFollowTheFiles() throws {
        try touch("trip/plan.md")
        let r = run([
            ("file", "ok: created results/draft/plan.md (10 bytes)"),
            ("file", "ok: renamed results/draft to results/trip"),
            ("file", "ok: created results/trip/tmp.md (1 bytes)"),
            ("file", "ok: deleted results/trip/tmp.md"),
        ])
        XCTAssertEqual(RunOutputs.files(r, root: root), ["trip/plan.md"])
        XCTAssertEqual(RunOutputs.folder(of: "trip/plan.md"), "trip")
        XCTAssertNil(RunOutputs.folder(of: "top.md"))
        XCTAssertEqual(RunOutputs.folder(of: "美团外卖订单/page-01.jpg"), "美团外卖订单")
    }

    func testTraceRemembersTheIntentThatStartedIt() throws {
        let traces = TraceStore(root: root)
        let intent = SavedTask(name: "Duolingo streak", prompt: "Keep my streak")
        traces.start(task: intent.prompt, intent: intent)
        traces.write(kind: "step", ["action": .str("done")])
        let store = RunStore(traces: traces)
        store.reload()
        let saved = try XCTUnwrap(store.runs.first)
        XCTAssertEqual(saved.intentID, intent.id)

        let intents = IntentStore(defaults: UserDefaults(suiteName: "outputs-" + UUID().uuidString)!)
        intents.upsert(intent)
        XCTAssertEqual(intents.intent(of: saved)?.name, "Duolingo streak")
    }

    func testOldTraceWithoutIntentStillLoads() throws {
        let folder = root.appendingPathComponent("20261101-090000")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{\"kind\":\"task\",\"task\":\"Open Notes\",\"n\":0}\n{\"kind\":\"step\",\"action\":\"done\",\"n\":1}\n".utf8)
            .write(to: folder.appendingPathComponent("steps.jsonl"))
        let loaded = try XCTUnwrap(RunStore.load(folder))
        XCTAssertEqual(loaded.task, "Open Notes")
        XCTAssertNil(loaded.intentID)
        XCTAssertEqual(loaded.outcome, .done)
    }
}
