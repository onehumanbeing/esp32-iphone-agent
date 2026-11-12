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
        traces.write(kind: "llm", ["role": .str("actor"), "usage": .obj(["prompt_tokens": .int(1200), "completion_tokens": .int(300)])])
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
        XCTAssertEqual(run.modelCalls, 2)
        XCTAssertEqual(run.tokens, 1500)
        XCTAssertTrue(run.stats.hasSuffix("2 AI calls · 2k tokens"))
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
        XCTAssertEqual(IntentStore(defaults: defaults).items.first?.name, IntentStore.text.name)  // the templates lead
    }

    /// Text and call come first, as templates that do not run until their blanks are filled in; an install that
    /// already has intents gets them once at the top, and deleting them sticks.
    func testTextAndCallTemplatesLeadAndNeedEditing() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let fresh = IntentStore(defaults: defaults)
        XCTAssertEqual(fresh.items.prefix(2).map(\.name), [IntentStore.text.name, IntentStore.call.name])
        XCTAssertTrue(fresh.items[0].unfilled && fresh.items[1].unfilled)
        XCTAssertFalse(IntentStore.note.unfilled)
        XCTAssertFalse(IntentStore.unfilled("Call Mom and talk about dinner"))

        let old = UserDefaults(suiteName: UUID().uuidString)!
        old.set(try? JSONEncoder().encode([IntentStore.note]), forKey: "savedTasks")
        old.set(true, forKey: "seededDiagnosticsIntent")
        let store = IntentStore(defaults: old)
        XCTAssertEqual(store.items.map(\.name), [IntentStore.text.name, IntentStore.call.name, IntentStore.note.name])
        store.delete(at: IndexSet(integer: 0))
        XCTAssertEqual(IntentStore(defaults: old).items.count, 2)
    }

    func testCallGuideOnlyForCallTasks() {
        XCTAssertTrue(Calls.isCall("Call Mom and talk about dinner"))
        XCTAssertTrue(Calls.isCall("打电话给妈妈，聊晚饭"))
        XCTAssertFalse(Calls.isCall("在淘宝把耳机加到购物车"))
        XCTAssertFalse(Calls.isCall("Open Settings on this iPhone and recall the last note"))
        XCTAssertEqual(Calls.prompt("Open Notes"), "")
        XCTAssertEqual(try Actions.parseCommand("say \"你好，我是助手\""), ["action": .str("say"), "text": .str("你好，我是助手")])
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

    func testToolsReadSearchAnswersAndRefuseBadFiles() throws {
        let exa = #"{"results":[{"title":"清闲智能","url":"https://qingxian.com/","text":"动态人机工学椅 OC1"}]}"#
        XCTAssertEqual(ToolRunner.text(Data(exa.utf8)), "- 清闲智能: 动态人机工学椅 OC1 (https://qingxian.com/)")
        XCTAssertEqual(ToolRunner.text(Data(#"{"result":"42"}"#.utf8)), "42")
        XCTAssertEqual(ToolRunner.text(Data("plain".utf8)), "plain")

        let store = ToolStore(defaults: UserDefaults(suiteName: "tools-" + UUID().uuidString)!)
        XCTAssertNotNil(store.add(json: Data("nope".utf8)))
        XCTAssertNotNil(store.add(json: Data(#"{"id":"web","title":"t","about":"a","url":"https://x.y"}"#.utf8)), "a built-in's id")
        XCTAssertNotNil(store.add(json: Data(#"{"id":"docs","title":"t","about":"a","url":"http://x.y"}"#.utf8)), "https only")
        XCTAssertNil(store.add(json: Data(#"{"id":"docs","title":"Docs","about":"Search our docs.","url":"https://x.y/s"}"#.utf8)))
        XCTAssertEqual(store.imported.map(\.id), ["docs"])
        XCTAssertTrue(ToolStore.prompt([]).isEmpty, "no tool on: the prompt says nothing")

        let tool = try XCTUnwrap(store.imported.first)
        let request = try XCTUnwrap(ToolRunner.request(tool, query: "q", key: "k", run: "r1"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Run-ID"), "r1")
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(sent["query"] as? String, "q")
        // export → import on another iPhone: the same tools, a keyless one stays keyless
        XCTAssertNil(store.add(json: Data(#"{"id":"wiki","title":"Wiki","about":"a","url":"https://w.k/s","key_header":null}"#.utf8)))
        let other = ToolStore(defaults: UserDefaults(suiteName: "tools-" + UUID().uuidString)!)
        XCTAssertNil(other.add(json: store.export()))
        XCTAssertEqual(other.imported, store.imported)
        XCTAssertNil(other.imported.last?.key_header)
        XCTAssertNotNil(other.add(json: Data(#"[{"id":"ok_one","title":"t","about":"a","url":"https://x.y"},{"id":"bad","title":"t","about":"a","url":"http://x.y"}]"#.utf8)))
        XCTAssertFalse(other.imported.contains { $0.id == "ok_one" }, "a list is added whole or not at all")
        store.remove("docs")
        store.remove("wiki")
        XCTAssertTrue(store.imported.isEmpty)
    }
}

