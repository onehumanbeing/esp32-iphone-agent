import XCTest
@testable import IPhoneAgent

/// Runs read back from trace folders (what the Runs list and the replay player show), and saved intents.
@MainActor final class StoreTests: XCTestCase {
    func testEmptyActiveRunIsNotFailedButAbandonedRunIs() {
        let run = Run(id: "pending", folder: URL(fileURLWithPath: "/tmp/pending"),
                      task: "Open Notes", date: Date(), steps: [])
        XCTAssertEqual(run.outcome(isActive: true), .running)
        XCTAssertEqual(run.outcome(isActive: false), .failed)
    }

    func testRunIsReadBackWithFramesOutcomeAndDuration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let traces = TraceStore(root: root)
        traces.start(task: "Open Settings")
        traces.write(Data([0xFF, 0xD8]), kind: "llm", ["role": .str("actor")])
        traces.write(kind: "step", ["action": .str("tap"), "x": .int(500), "y": .int(300), "changed": .bool(true)])
        traces.write(kind: "step", ["action": .str("done"), "answer": .str("ok")])

        let store = RunStore(traces: traces)
        store.reload()
        let run = try XCTUnwrap(store.runs.first)
        XCTAssertEqual(run.task, "Open Settings")
        XCTAssertEqual(run.steps.count, 2)
        XCTAssertEqual(run.moves.count, 1)
        XCTAssertEqual(run.outcome, .done)
        XCTAssertNotNil(run.steps[0].frame)
        XCTAssertNotNil(run.duration)
        XCTAssertEqual(StepText.title(run.steps[0].action), "Tap at 500, 300")
        try? FileManager.default.removeItem(at: root)
    }

    func testIntentsAreSavedAndDeleted() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = IntentStore(defaults: defaults)
        XCTAssertFalse(store.items.isEmpty)  // seeded with the examples
        store.add(name: "", prompt: "Open Notes and write hello")
        XCTAssertEqual(store.items.first?.name, "Open Notes and write hello")
        XCTAssertEqual(IntentStore(defaults: defaults).items.count, store.items.count)
        store.delete(at: IndexSet(integer: 0))
        XCTAssertEqual(IntentStore(defaults: defaults).items.first?.name, IntentStore.examples[0].name)
    }

    func testDeletingRunRemovesRecordingAndPersistsAfterReload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let traces = TraceStore(root: root)
        traces.start(task: "Open Notes")
        traces.write(Data([0xFF, 0xD8]), kind: "step", ["action": .str("done")])
        let store = RunStore(traces: traces)
        store.reload()
        let run = try XCTUnwrap(store.runs.first)

        try store.delete(run)

        XCTAssertFalse(FileManager.default.fileExists(atPath: run.folder.path))
        XCTAssertTrue(store.runs.isEmpty)
        store.reload()
        XCTAssertTrue(store.runs.isEmpty)
    }

    func testFailedDiskRemovalKeepsRunVisibleAndReportsError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let traces = TraceStore(root: root)
        traces.start(task: "Open Notes")
        let store = RunStore(traces: traces)
        store.reload()
        let run = try XCTUnwrap(store.runs.first)
        try FileManager.default.removeItem(at: run.folder)

        XCTAssertThrowsError(try store.delete(run))
        XCTAssertEqual(store.runs.map(\.id), [run.id])
    }

    func testFailedStartupCardAndDeleteTargetUseStoredRunInsteadOfPreviousAgentCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let traces = TraceStore(root: root)
        traces.start(task: "New task that could not start")
        traces.write(Data([0xFF, 0xD8]), kind: "step", ["action": .str("error"), "reason": .str("Could not leave app")])
        let store = RunStore(traces: traces)
        store.reload()
        let stored = try XCTUnwrap(store.run(try XCTUnwrap(traces.dir).lastPathComponent))
        let oldSteps: [JObject] = [["action": .str("tap")], ["action": .str("done")]]

        let card = try XCTUnwrap(RunCardSnapshot.select(running: false, liveTask: "Previous completed task",
                                                       liveSteps: oldSteps, liveFrame: Data([1]), storedRun: stored))

        XCTAssertEqual(card.task, stored.task)
        XCTAssertEqual(card.lastStep?["action"]?.str, "error")
        XCTAssertEqual(card.moveCount, 0)
        XCTAssertNil(card.frame)
        XCTAssertEqual(card.cover, stored.cover)
        XCTAssertEqual(card.storedRun?.id, stored.id)
        XCTAssertNil(RunCardSnapshot.select(running: false, liveTask: "Deleted task", liveSteps: oldSteps,
                                           liveFrame: Data([1]), storedRun: nil))
    }

    func testActiveRunCardUsesLiveProgressAndOffersNoStoredDeleteTarget() throws {
        let old = Run(id: "old", folder: URL(fileURLWithPath: "/tmp/old"), task: "Old task", date: Date(), steps: [])
        let frame = Data([1, 2, 3])
        let card = try XCTUnwrap(RunCardSnapshot.select(running: true, liveTask: "Current task",
                                                       liveSteps: [["action": .str("tap")]], liveFrame: frame,
                                                       storedRun: old))
        XCTAssertEqual(card.task, "Current task")
        XCTAssertEqual(card.moveCount, 1)
        XCTAssertEqual(card.frame, frame)
        XCTAssertNil(card.cover)
        XCTAssertNil(card.storedRun)
    }
}
