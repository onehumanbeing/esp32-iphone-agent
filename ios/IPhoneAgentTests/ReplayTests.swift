import XCTest
import UIKit
@testable import IPhoneAgent

/// Tap first, ask later: replaying a saved intent's recorded steps.
@MainActor final class ReplayTests: XCTestCase {
    /// A white screen with a black block at `block` (fractions), `size` points.
    static func screen(_ block: CGRect, size: CGSize = CGSize(width: 180, height: 390), badge: Bool = false) -> Data {
        UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            UIColor.black.setFill()
            ctx.fill(CGRect(x: block.minX * size.width, y: block.minY * size.height,
                            width: block.width * size.width, height: block.height * size.height))
            if badge { UIColor.red.setFill(); ctx.fill(CGRect(x: size.width * 0.8, y: size.height * 0.5, width: 4, height: 4)) }
        }.jpegData(compressionQuality: 0.9)!
    }

    let a = screen(CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.2))
    let b = screen(CGRect(x: 0.1, y: 0.6, width: 0.8, height: 0.3))
    let c = screen(CGRect(x: 0.3, y: 0.3, width: 0.5, height: 0.5))

    func testSimilarIgnoresSizeAndSmallThings() {
        XCTAssertTrue(Vision.similar(a, Self.screen(CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.2), size: CGSize(width: 360, height: 780))))
        XCTAssertTrue(Vision.similar(a, Self.screen(CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.2), badge: true)))
        XCTAssertFalse(Vision.similar(a, b))
        XCTAssertFalse(Vision.similar(a, nil))
    }

    func testDecide() {
        let tap: JObject = ["action": .str("tap"), "x": .int(300), "y": .int(300)]
        XCTAssertEqual(Replay.decide(.init(action: tap, sure: true, frame: a), screen: a), .perform)
        XCTAssertEqual(Replay.decide(.init(action: tap, sure: true, frame: a), screen: b), .handOver("miss (screen differs)"))
        XCTAssertEqual(Replay.decide(.init(action: tap, sure: false, frame: a), screen: a), .handOver("unsure"))
        XCTAssertEqual(Replay.decide(.init(action: tap, sure: true, frame: nil), screen: a), .handOver("no reference screen"))
        let blank: JObject = ["action": .str("type"), "text": .str("")]
        XCTAssertEqual(Replay.decide(.init(action: blank, sure: true, frame: a), screen: a), .handOver("unknown text"))
        let note: JObject = ["action": .str("note"), "text": .str("tap Save")]
        XCTAssertEqual(Replay.decide(.init(action: note, sure: true, frame: a), screen: a), .handOver("not a move"))
    }

    /// Henry 2026-11-12: a demonstrated tap is replayed by what it tapped, wherever that is on the screen now.
    func testALabelledTapFindsItsRowWherever() {
        let lines = [DemoAnalysis.Line(text: "微信", x: 500, y: 30), DemoAnalysis.Line(text: "my family", x: 400, y: 340),
                     DemoAnalysis.Line(text: "文件传输助手", x: 380, y: 700), DemoAnalysis.Line(text: "微信", x: 80, y: 960)]
        XCTAssertEqual(Replay.locate("文件传输助手", near: 287, 345, in: lines)?.y, 700, "the row moved down: tapped where it is")
        XCTAssertEqual(Replay.locate("微信", near: 90, 940, in: lines)?.x, 80, "two of them: the one nearest the recorded spot")
        XCTAssertEqual(Replay.locate("My Family", near: 0, 0, in: lines)?.y, 340, "case and spaces don't matter")
        XCTAssertNil(Replay.locate("Taobao", near: 500, 500, in: lines))
    }

    func testIntentColourIsSavedAndExported() {
        let draft = ReviewDraft(source: .run, folder: nil, runID: "r", outcome: .done, steps: [], name: "n", prompt: "p")
        draft.color = "teal"
        let item = draft.intent(existing: nil)
        XCTAssertEqual(item.color, "teal")
        XCTAssertEqual(IntentArchive.item(item, screenshots: false).color, "teal")
        draft.color = "accent"
        XCTAssertNil(draft.intent(existing: item).color)
    }

    /// Henry 2026-11-12: a run that worked after the replay missed becomes the intent's steps.
    func testAnIntentLearnsFromARunThatWorked() async throws {
        let replayed: JObject = ["action": .str("tap"), "x": .int(1), "y": .int(2), "replay": .bool(true)]
        let model: JObject = ["action": .str("tap"), "x": .int(437), "y": .int(696)]
        XCTAssertTrue(IntentLearner.shouldLearn([replayed, model, ["action": .str("done")]], done: true))
        XCTAssertFalse(IntentLearner.shouldLearn([replayed, model], done: false), "only a run that worked")
        XCTAssertFalse(IntentLearner.shouldLearn([replayed, ["action": .str("done")]], done: true), "the replay did it all")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let frame = dir.appendingPathComponent("1.jpg"); try a.write(to: frame)
        let run = Run(id: "r1", folder: dir, task: "t", date: Date(), steps: [
            .init(id: 1, action: ["action": .str("plan"), "plan": .str("1. x")], frame: nil, t: nil),
            .init(id: 2, action: ["action": .str("open"), "app": .str("WeChat")], frame: frame, t: nil),
            .init(id: 3, action: ["action": .str("tap"), "x": .int(10), "y": .int(10), "changed": .bool(false)], frame: frame, t: nil),
            .init(id: 4, action: model.merging(["think_s": .num(1)]), frame: frame, t: nil),
            .init(id: 5, action: ["action": .str("done"), "answer": .str("ok")], frame: frame, t: nil),
        ])
        let id = UUID()
        defer { IntentFrames.delete(id) }
        let learned = try await IntentLearner.steps(from: run, for: id)
        XCTAssertEqual(learned?.map { $0.object?["action"]?.str }, ["open", "tap"], "moves that changed the screen")
        XCTAssertNil(learned?[1].object?["think_s"])
        XCTAssertNotNil(IntentFrames.data(id, learned?[1].frame))
        XCTAssertEqual(IntentLearner.label(at: 287, 345, in: [DemoAnalysis.Line(text: "文件传输助手", x: 300, y: 350)]), "文件传输助手")
        XCTAssertNil(IntentLearner.label(at: 287, 345, in: [DemoAnalysis.Line(text: "far", x: 800, y: 900)]))
        XCTAssertNil(IntentLearner.label(at: 287, 345, in: [DemoAnalysis.Line(text: "x", x: 290, y: 350)]), "one character names nothing")
        XCTAssertEqual(Replay.decide(.init(action: ["action": .str("open"), "app": .str("WeChat")], sure: true, frame: nil), screen: b), .perform)
    }

    func testAnIntentWithoutStepsCanUndoWhatItLearned() {
        let store = IntentStore(defaults: UserDefaults(suiteName: "learn-" + UUID().uuidString)!)
        var item = SavedTask(name: "typed", prompt: "p")
        item.steps = [RecordedStep(action: ["action": .str("tap"), "x": .int(1), "y": .int(1)], sure: true, frame: nil)]
        item.learnedFrom = "r1"
        item.refRun = "r1"
        store.upsert(item)
        store.undoLearned(item.id)
        store.clearReference(item.id)
        XCTAssertNil(store.item(item.id)?.steps, "back to no steps")
        XCTAssertNil(store.item(item.id)?.refRun)
    }

    func testLearnedStepsCanBeUndone() {
        let store = IntentStore(defaults: UserDefaults(suiteName: "learn-" + UUID().uuidString)!)
        var item = SavedTask(name: "n", prompt: "p")
        item.steps = [RecordedStep(action: ["action": .str("tap"), "x": .int(1), "y": .int(1)], sure: true, frame: nil)]
        item.previousSteps = [RecordedStep(action: ["action": .str("home")], sure: true, frame: nil)]
        item.learnedFrom = "r1"
        store.upsert(item)
        store.record(item.id, RunStat(run: "r1", ok: true, seconds: 3))
        store.markLastRun(item.id, ok: false)
        XCTAssertEqual(store.item(item.id)?.runs.last?.ok, false, "✗ on the island: the run counts as failed")
        store.undoLearned(item.id)
        XCTAssertEqual(store.item(item.id)?.steps?.first?.object?["action"]?.str, "home")
        XCTAssertNil(store.item(item.id)?.learnedFrom)
    }

    private func steps(_ frames: [Data?]) -> Replay {
        Replay(steps: frames.enumerated().map { i, f in
            .init(action: ["action": .str("tap"), "x": .int(100 * (i + 1)), "y": .int(500)], sure: true, frame: f)
        })
    }

    /// Two matching steps run without the model; then it plans once and says done.
    func testMatchingStepsSkipTheModel() async {
        let screen = FakeScreen(); screen.frame = a
        let phone = ScriptedPhone { n in screen.frame = n == 1 ? self.b : self.c }
        let model = FakeModel { call in call == 1 ? "1. Check it is done" : "THINK: done\nDO: done ok" }
        let agent = AgentLoop(phone: phone, screen: screen, actor: model, planner: model, trace: nil)
        agent.replay = steps([a, b])
        await agent.run()
        XCTAssertEqual(phone.taps, 2)
        XCTAssertEqual(model.prompts.count, 2, "planner and one actor call, none for the replayed steps")
        XCTAssertEqual(agent.steps.filter { $0["replay"] == .bool(true) }.count, 2)
        XCTAssertTrue(agent.actorPrompt.contains("Recorded step 2 (done)"))
    }

    /// The screen doesn't match the first step: the model does everything.
    func testMismatchHandsOverAtOnce() async {
        let screen = FakeScreen(); screen.frame = c
        let phone = ScriptedPhone { _ in }
        let model = FakeModel { call in call == 1 ? "1. Do it" : "THINK: done\nDO: done ok" }
        let agent = AgentLoop(phone: phone, screen: screen, actor: model, planner: model, trace: nil)
        agent.replay = steps([a, b])
        await agent.run()
        XCTAssertEqual(phone.taps, 0)
        XCTAssertEqual(model.prompts.count, 2)
    }

    /// A replayed tap that changes nothing stops the replay; the second step is never tried.
    func testNoChangeHandsOver() async {
        let screen = FakeScreen(); screen.frame = a
        let phone = ScriptedPhone { _ in }
        let model = FakeModel { call in call == 1 ? "1. Do it" : "THINK: done\nDO: done ok" }
        let agent = AgentLoop(phone: phone, screen: screen, actor: model, planner: model, trace: nil)
        agent.replay = steps([a, a])
        await agent.run()
        XCTAssertEqual(phone.taps, 1)
        XCTAssertEqual(agent.steps.first { $0["replay"] == .bool(true) }?["changed"], .bool(false))
        XCTAssertEqual(model.prompts.count, 2)
    }

    /// Saving a demonstration: unsure and wrong steps, a fixed position, screens copied next to the intent.
    func testRecordedStepsFromADemonstration() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f1 = dir.appendingPathComponent("k001.jpg"); try a.write(to: f1)
        let f2 = dir.appendingPathComponent("k002.jpg"); try b.write(to: f2)
        var fixed = DraftStep(action: ["action": .str("tap"), "x": .int(10), "y": .int(10)], frame: f2, uncertain: true)
        fixed.fix = CGPoint(x: 900, y: 80)
        var wrong = DraftStep(action: ["action": .str("swipe"), "x1": .int(1), "y1": .int(1), "x2": .int(2), "y2": .int(2)], frame: f2)
        wrong.verdict = false
        let draft = ReviewDraft(source: .recording, folder: nil, runID: nil, outcome: nil, steps: [
            DraftStep(action: ["action": .str("tap"), "x": .int(500), "y": .int(814)], frame: f1),
            DraftStep(action: ["action": .str("type"), "text": .str("Clock")], frame: nil, uncertain: true),
            fixed, wrong,
            DraftStep(action: ["action": .str("note"), "text": .str("then save")], frame: f2),
        ], name: "Alarm", prompt: "Set an alarm")
        let id = UUID()
        defer { IntentFrames.delete(id) }
        let saved = try XCTUnwrap(draft.recordedSteps(for: id))
        // the unsure type and the note become AI steps: the intent is a script now
        XCTAssertEqual(saved.map { $0.object?["action"]?.str }, ["tap", "ai", "tap", "ai"])
        XCTAssertEqual(saved[1].object?["goal"], .str("Do this step: Type “Clock”"))
        XCTAssertEqual(saved[3].object?["goal"], .str("then save"))
        XCTAssertEqual(saved.map(\.sure), [true, true, true, true])
        XCTAssertEqual(saved[2].object?["x"], .int(900))
        XCTAssertEqual(saved.map(\.frame), ["s01.jpg", nil, "s03.jpg", "s04.jpg"])
        XCTAssertEqual(IntentFrames.data(id, "s01.jpg"), a)
        var item = SavedTask(name: "Alarm", prompt: "Set an alarm"); item.id = id; item.steps = saved
        XCTAssertEqual(Replay(intent: item).steps.first?.frame, a)
    }
}

/// Taps that change the screen, like the real phone.
@MainActor final class ScriptedPhone: Gestures {
    let device: HIDDevice = FakeDevice()
    private(set) var taps = 0
    let onTap: (Int) -> Void
    init(_ onTap: @escaping (Int) -> Void) { self.onTap = onTap }
    func tap(_ x: Double, _ y: Double, aim: Bool) async throws { taps += 1; onTap(taps) }
    func swipe(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, hold: Bool) async throws {}
    func drag(_ points: [CGPoint], hold: Bool) async throws {}
    func type(_ text: String) async throws -> String? { nil }
    func key(_ combo: String) async throws {}
    func goHome(again: Bool) async throws {}
    func openApp(_ name: String) async throws -> OpenResult { .opened }
    func goBack() async throws {}
    func reset() async throws {}
}
