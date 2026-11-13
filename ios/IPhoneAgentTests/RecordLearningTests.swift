import XCTest
@testable import IPhoneAgent

/// Henry 2026-11-13: a recording saved as what was meant (DemoSteps), steps checked after the instruction changed
/// (Replan), typed words tied to the instruction (Replay.retyped), a lesson from a failed run (IntentLearner).
@MainActor final class RecordLearningTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    /// A screen file whose bytes name it; the reader's OCR and "same screen" go by that name.
    private func screen(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name + ".jpg")
        try Data(name.utf8).write(to: url)
        return url
    }

    private func reader(_ ocr: [String: [DemoAnalysis.Line]], same: Set<Set<String>> = []) -> DemoSteps.Reader {
        DemoSteps.Reader(lines: { ocr[String(decoding: $0, as: UTF8.self)] ?? [] },
                         same: { a, b in
                             let (x, y) = (String(decoding: a, as: UTF8.self), String(decoding: b, as: UTF8.self))
                             return x == y || same.contains([x, y])
                         })
    }

    private func step(_ action: JObject, _ frame: URL?, unsure: Bool = false) -> DraftStep {
        DraftStep(action: action, frame: frame, uncertain: unsure)
    }

    private func tap(_ x: Int, _ y: Int, _ label: String? = nil) -> JObject {
        var a: JObject = ["action": .str("tap"), "x": .int(x), "y": .int(y)]
        if let label { a["label"] = .str(label) }
        return a
    }

    private func line(_ text: String, _ x: Int, _ y: Int) -> DemoAnalysis.Line { .init(text: text, x: x, y: y) }

    private let keyboard: [DemoAnalysis.Line] = "qwertyuiop".enumerated().map { .init(text: String($1), x: 50 + $0 * 100, y: 700) }
        + "asdfghjkl".enumerated().map { .init(text: String($1), x: 100 + $0 * 100, y: 780) }

    // MARK: - DemoSteps

    func testHomeFolderAndAppTapBecomeOpen() async throws {
        let (a, b, c, d) = (try screen("a"), try screen("b"), try screen("c"), try screen("d"))
        let steps = [step(["action": .str("home")], a), step(tap(613, 702, "Photo & Video"), b),
                     step(tap(497, 493, "WeChat"), c), step(tap(300, 260, "文件传输助手"), d)]
        let ocr = ["b": [line("Photo & Video", 613, 730)], "c": [line("WeChat", 497, 520)], "d": [line("文件传输助手", 320, 260)]]
        let out = await DemoSteps.refine(steps, prompt: "Open WeChat and send ok to 文件传输助手", after: nil, reader: reader(ocr))
        XCTAssertEqual(out.map(\.name), ["open", "tap"])
        XCTAssertEqual(out[0].action["app"]?.str, "WeChat")
        XCTAssertFalse(out[0].uncertain)
        XCTAssertEqual(out[1].action["label"]?.str, "文件传输助手")
    }

    func testSpotlightTypedNameBecomesOpen() async throws {
        let s = try (0..<4).map { try screen("s\($0)") }
        let steps = [step(["action": .str("swipe"), "x1": .int(500), "y1": .int(400), "x2": .int(500), "y2": .int(600)], s[0]),
                     step(["action": .str("type"), "text": .str("时钟")], s[1]),
                     step(tap(200, 300, "时钟"), s[2]),
                     step(tap(800, 120, "+"), s[3])]
        let out = await DemoSteps.refine(steps, prompt: "设一个 7 点的闹钟", after: nil, reader: reader([:]))
        XCTAssertEqual(out.map(\.name), ["open", "tap"])
        XCTAssertEqual(out[0].action["app"]?.str, "时钟")
    }

    func testTheLabelIsWhatReadsAtTheSpot() async throws {
        let a = try screen("a"), b = try screen("b")
        let ocr = ["a": [line("文件传输助手", 300, 262), line("群聊", 300, 700)], "b": [line("Save", 880, 90)]]
        let out = await DemoSteps.refine([step(tap(300, 260), a), step(tap(880, 90, "Cancel"), b)], prompt: "x",
                                         after: nil, reader: reader(ocr))
        XCTAssertEqual(out[0].action["label"]?.str, "文件传输助手", "no label from the model: OCR names it")
        XCTAssertFalse(out[0].uncertain)
        XCTAssertEqual(out[1].action["label"]?.str, "Save", "the screen does not show the model's name")
        XCTAssertTrue(out[1].uncertain)
    }

    func testTheModelsNameReadingElsewhereMovesTheSpot() async throws {
        let a = try screen("a")
        let out = await DemoSteps.refine([step(tap(450, 608, "文件传输助手"), a)], prompt: "x", after: nil,
                                         reader: reader(["a": [line("文件传输助手", 300, 260)]]))
        XCTAssertEqual(out[0].action["x"]?.int, 300)
        XCTAssertEqual(out[0].action["y"]?.int, 260)
        XCTAssertFalse(out[0].uncertain)
    }

    func testKeyboardTapsAreTypingAndTheReturnKeySends() async throws {
        let k1 = try screen("k1"), k2 = try screen("k2"), k3 = try screen("k3")
        let ocr = ["k1": keyboard, "k2": keyboard, "k3": keyboard + [line("发送", 873, 894)]]
        let steps = [step(["action": .str("type"), "text": .str("ok")], k1), step(tap(613, 702), k2), step(tap(873, 894), k3)]
        let out = await DemoSteps.refine(steps, prompt: "x", after: nil, reader: reader(ocr))
        XCTAssertEqual(out.map(\.name), ["type", "key"])
        XCTAssertEqual(out[1].action["combo"]?.str, "enter")
    }

    func testABackToTheSameScreenIsADetour() async throws {
        let list = try screen("list"), chat = try screen("chat"), list2 = try screen("list2"), chat2 = try screen("chat2")
        let steps = [step(tap(300, 260, "文件传输助手"), list), step(tap(49, 80), chat),
                     step(tap(300, 260, "文件传输助手"), list2), step(["action": .str("type"), "text": .str("ok")], chat2)]
        let ocr = ["list": [line("文件传输助手", 300, 260)], "list2": [line("文件传输助手", 300, 260)]]
        let out = await DemoSteps.refine(steps, prompt: "x", after: nil, reader: reader(ocr, same: [["list", "list2"]]))
        XCTAssertEqual(out.map { $0.action["detour"] == .bool(true) }, [true, true, false, false])
        XCTAssertEqual(out[0].verdict, false, "left out unless marked correct")
    }

    func testOpenIsParsedFromTheModel() {
        XCTAssertEqual(DemoRecorder.parseDemonstratedAction("open \"微信\""), ["action": .str("open"), "app": .str("微信")])
        XCTAssertNil(DemoRecorder.parseDemonstratedAction("open"))
    }

    // MARK: - typed words and the instruction

    func testTypedWordsFromAnInstructionThatChangedGoToTheAI() {
        let typed: JObject = ["action": .str("type"), "text": .str("张三"), "slot": .str("张三")]
        XCTAssertEqual(Replay.retyped(typed, prompt: "发消息给张三"), typed)
        XCTAssertEqual(Replay.retyped(typed, prompt: "发消息给李四")["action"]?.str, "ai")
        let plain: JObject = ["action": .str("type"), "text": .str("ok")]
        XCTAssertEqual(Replay.retyped(plain, prompt: "anything"), plain)
    }

    // MARK: - Replan

    func testReplanParsesEachKindAndKeepsWhatItLeavesOut() throws {
        let reply = """
        NAME: Comment on the photos in File Transfer
        STEP 1: keep
        STEP 2: ai "Write a short comment on the photos"
        STEP 3: drop
        HINTS:
        - Open the 文件传输助手 chat from the chat list
        """
        let p = try XCTUnwrap(Replan.parse(reply, count: 5))
        XCTAssertEqual(p.edits, [.keep, .ai("Write a short comment on the photos"), .drop, .keep, .keep])
        XCTAssertEqual(p.name, "Comment on the photos in File Transfer")
        XCTAssertEqual(p.hints, ["Open the 文件传输助手 chat from the chat list"])
        XCTAssertEqual(Replan.parse("STEP 2: type \"李四\"", count: 2)?.edits, [.keep, .type("李四")])
        XCTAssertNil(Replan.parse("I cannot tell", count: 2))
    }

    func testReplanApplyKeepsScreensAndDropsSteps() {
        let steps = [RecordedStep(action: ["action": .str("open"), "app": .str("微信")], sure: true, frame: "s01.jpg"),
                     RecordedStep(action: ["action": .str("type"), "text": .str("ok")], sure: true, frame: "s02.jpg"),
                     RecordedStep(action: tap(873, 894), sure: true, frame: "s03.jpg")]
        let out = Replan.apply([.keep, .ai("Write a comment"), .drop], to: steps)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[1].object?["action"]?.str, "ai")
        XCTAssertEqual(out[1].frame, "s02.jpg")
        XCTAssertTrue(Replan.input(old: "a", new: "b", steps: steps, checklist: []).contains("Type \"ok\""))
        XCTAssertFalse(Replan.input(old: "a", new: "b", steps: steps, checklist: []).contains("873"), "no spots")
    }

    // MARK: - failed runs

    func testAFailedRunGivesOneMaskedHint() throws {
        let steps: [JObject] = [["action": .str("tap"), "thought": .str("This is the home screen; no Photo & Video folder here")],
                                ["action": .str("fail"), "reason": .str("Could not reach 13812345678")]]
        let notes = try XCTUnwrap(IntentLearner.failureNotes(task: "Text 13812345678", steps: steps,
                                                             missed: ["Tap \"Photo & Video\""], checklist: []))
        XCTAssertFalse(notes.contains("13812345678"))
        XCTAssertTrue(notes.contains("Photo & Video"))
        XCTAssertEqual(IntentLearner.failureLesson("- Open WeChat with open, not from the folder\nmore"),
                       "Open WeChat with open, not from the folder")
        XCTAssertNil(IntentLearner.failureLesson("NONE"))
        XCTAssertNil(IntentLearner.failureLesson(""))
    }
}
