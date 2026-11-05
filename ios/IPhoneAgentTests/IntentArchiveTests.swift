import XCTest
import UIKit
@testable import IPhoneAgent

/// .esp32intent export and import.
@MainActor final class IntentArchiveTests: XCTestCase {
    private var created: [UUID] = []
    override func tearDown() { created.forEach(IntentFrames.delete) }

    /// An intent with two steps; the first has a reference screen.
    private func intent() throws -> SavedTask {
        var item = SavedTask(name: "Notes hello", prompt: "Open Notes and write hello", icon: "note.text", hints: ["Use the + button"])
        created.append(item.id)
        try FileManager.default.createDirectory(at: IntentFrames.folder(item.id), withIntermediateDirectories: true)
        try ReplayTests.screen(CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.2)).write(to: IntentFrames.folder(item.id).appendingPathComponent("s01.jpg"))
        item.steps = [RecordedStep(action: ["action": .str("tap"), "x": .int(500), "y": .int(800)], sure: true, frame: "s01.jpg"),
                      RecordedStep(action: ["action": .str("type"), "text": .str("hello")], sure: true, frame: nil)]
        item.history = [RunStat(run: "secret-run", ok: true, seconds: 12)]
        item.refRun = "secret-run"
        return item
    }

    private func importAll(_ data: Data, existing: [SavedTask] = []) throws -> (added: [SavedTask], skipped: Int) {
        let r = try IntentArchive.newIntents(try IntentArchive.decode(data), existing: existing)
        created += r.added.map(\.id)
        return r
    }

    func testRoundTripWithoutScreenshots() throws {
        let original = try intent()
        let data = try IntentArchive.encode([IntentArchive.item(original, screenshots: false)])
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("secret-run"), "no history or run ids")
        let back = try XCTUnwrap(importAll(data).added.first)
        XCTAssertNotEqual(back.id, original.id)
        XCTAssertEqual(back.name, original.name)
        XCTAssertEqual(back.prompt, original.prompt)
        XCTAssertEqual(back.icon, "note.text")
        XCTAssertEqual(back.hints, ["Use the + button"])
        XCTAssertEqual(back.steps?.map(\.frame), [nil, nil])
        XCTAssertEqual(back.steps?.first?.object, original.steps?.first?.object)
        XCTAssertNil(back.history)
    }

    func testRoundTripWithScreenshotsReplays() throws {
        let original = try intent()
        let data = try IntentArchive.encode([IntentArchive.item(original, screenshots: true)])
        let back = try XCTUnwrap(importAll(data).added.first)
        XCTAssertEqual(back.steps?.map(\.frame), ["s01.jpg", nil])
        XCTAssertEqual(IntentFrames.data(back.id, "s01.jpg"), IntentFrames.data(original.id, "s01.jpg"))
        XCTAssertEqual(Replay(intent: back).steps.first?.sure, true)
    }

    func testDuplicatesAreSkipped() throws {
        let original = try intent()
        var other = original; other.name = "Other"
        let data = try IntentArchive.encode([original, other, original].map { IntentArchive.item($0, screenshots: false) })
        let r = try importAll(data, existing: [original])
        XCTAssertEqual(r.added.map(\.name), ["Other"])
        XCTAssertEqual(r.skipped, 2)
    }

    func testBadFilesAreRefused() {
        XCTAssertThrowsError(try IntentArchive.decode(Data("{\"hello\":1}".utf8)))
        XCTAssertThrowsError(try IntentArchive.decode(Data("{\"format\":2,\"intents\":[]}".utf8)))
        let junk = #"{"format":1,"intents":[{"name":"x","prompt":"do it","steps":[{"action":"not json","sure":true},{"action":"{\"action\": \"home\"}","sure":true,"frame":"bm90IGFuIGltYWdl"}]}]}"#
        let items = try? IntentArchive.decode(Data(junk.utf8))
        XCTAssertEqual(items?.first?.steps?.count, 1, "the step that isn't JSON is dropped")
        XCTAssertNil(items?.first?.steps?.first?.frame, "a frame that isn't an image is dropped")
    }
}

/// What Send to Developer attaches.
@MainActor final class IntentShareTests: XCTestCase {
    func testSharedIntentIsAnonymous() async throws {
        var item = SavedTask(name: "Notes hello", prompt: "Open Notes with hello-key")
        defer { IntentFrames.delete(item.id) }
        try FileManager.default.createDirectory(at: IntentFrames.folder(item.id), withIntermediateDirectories: true)
        try ReplayTests.screen(CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.2), size: CGSize(width: 718, height: 1560))
            .write(to: IntentFrames.folder(item.id).appendingPathComponent("s01.jpg"))
        item.steps = [RecordedStep(action: ["action": .str("tap"), "x": .int(500), "y": .int(800)], sure: true, frame: "s01.jpg"),
                      RecordedStep(action: ["action": .str("type"), "text": .str("hello")], sure: true, frame: nil)]
        item.refRun = "secret-run"
        let redactor = Redactor(secrets: ["hello-key"])
        let shared = await IntentShare.prepare(item, screenshots: true, redactor: redactor)
        XCTAssertEqual(shared.prompt, "Open Notes with [redacted]")
        XCTAssertEqual(shared.steps?[1].action.contains("•••"), true)
        XCTAssertEqual(shared.steps?[1].action.contains("hello"), false)
        let frame = try XCTUnwrap(IntentShare.frames(shared).first.flatMap { UIImage(data: $0)?.cgImage })
        XCTAssertLessThanOrEqual(frame.width, Int(IntentShare.width))
        XCTAssertFalse(String(decoding: try IntentArchive.encode([shared]), as: UTF8.self).contains("secret-run"))
        let none = await IntentShare.prepare(item, screenshots: false, redactor: redactor)
        XCTAssertTrue(IntentShare.frames(none).isEmpty)
    }

    func testReviewNoteOnlyWithScreenshots() throws {
        XCTAssertTrue(IntentShare.mailBody(screenshots: true).contains(IntentShare.reviewNote))
        XCTAssertFalse(IntentShare.mailBody(screenshots: false).contains(IntentShare.reviewNote))
        let item = IntentArchive.Item(name: "x", prompt: "do it")
        let data = try IntentArchive.encode([item], note: IntentShare.reviewNote)
        let file = try JSONDecoder().decode(IntentArchive.File.self, from: data)
        XCTAssertEqual(file.note, IntentShare.reviewNote)
        XCTAssertEqual(try IntentArchive.decode(data), [item], "the note doesn't change what is imported")
    }
}
