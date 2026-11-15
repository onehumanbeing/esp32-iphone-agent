import UIKit
import XCTest
@testable import IPhoneAgent

/// Local files stay inside one directory, and a plan edit may only write text or a real image there.
@MainActor final class PlanEditTests: XCTestCase {
    func testPlanRoundTripsAndBecomesALoopBeforeAStep() throws {
        let plan = """
        NAME: Orders
        PROMPT: View orders in Meituan
        1. open "Meituan" | k001.jpg
        2. tap 10 20 "Orders" | k002.jpg
        3. tap 10 40 "Back"
        """
        let doc = try XCTUnwrap(PlanText.parse(plan))
        XCTAssertEqual(doc.steps.count, 3)
        XCTAssertEqual(doc.steps[0].frame, "k001.jpg")
        XCTAssertNil(doc.until)
        let rendered = PlanText.render(doc)
        XCTAssertEqual(PlanText.render(try XCTUnwrap(PlanText.parse(rendered))), rendered)
        let looped = PlanEditMock.looped(plan, user: "turn this into a loop, repeat until before step 3")
        let again = try XCTUnwrap(PlanText.parse(looped))
        XCTAssertEqual(again.steps.map(\.command), ["open \"Meituan\"", "tap 10 20 \"Orders\""])
        XCTAssertEqual(again.until, "the screen is ready for what used to come next")
        XCTAssertEqual(again.maxLoops, 8)
        XCTAssertEqual(PlanText.action("open \"Meituan\"")["app"]?.str, "Meituan")
        XCTAssertEqual(PlanText.action("tap 10 20 \"Orders\"")["label"]?.str, "Orders")
    }

    func testPromptsUseThePlannerRoleAndNameNoModel() {
        XCTAssertEqual(PlanModels.role, "planner")
        let blob = (PlanEditSession.editorPrompt + PlanEditSession.reviewPrompt).lowercased()
        for word in ["qwen", "sonnet", "claude", "gpt-", "handsy-"] {
            XCTAssertFalse(blob.contains(word), word)
        }
        for tool in FileTool.edit {
            XCTAssertTrue(PlanEditSession.editorPrompt.contains(tool), tool)
        }
        XCTAssertEqual(FileTool.review, Set(["list", "read"]))
        XCTAssertTrue(PlanEditSession.reviewPrompt.contains("No write"))
    }

    func testToolsStayInsideTheFolderAndOnlyWriteTextOrImages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let boxDir = root.appendingPathComponent("plan")
        try FileManager.default.createDirectory(at: boxDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let box = FileSandbox(root: boxDir)
        let jpeg = try tinyJPEG()
        try jpeg.write(to: boxDir.appendingPathComponent("k001.jpg"))
        try "NAME: A\nPROMPT: A\n1. open \"Meituan\"\n".write(to: boxDir.appendingPathComponent("plan.txt"), atomically: true, encoding: .utf8)

        XCTAssertTrue(box.perform(FileCall(name: "list", args: ["."]), allow: FileTool.edit).contains("plan.txt"))
        XCTAssertTrue(box.perform(FileCall(name: "read", args: ["plan.txt"]), allow: FileTool.edit).contains("Meituan"))

        let escape = box.perform(FileCall(name: "write", args: ["../secret.txt"], body: "nope"), allow: FileTool.edit)
        XCTAssertTrue(escape.hasPrefix("refused"), escape)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("secret.txt").path))

        let secret = root.appendingPathComponent("hidden.txt")
        try "hidden".write(to: secret, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: boxDir.appendingPathComponent("link.txt"), withDestinationURL: secret)
        let linked = box.perform(FileCall(name: "read", args: ["link.txt"]), allow: FileTool.edit)
        XCTAssertTrue(linked.hasPrefix("refused"), linked)
        XCTAssertFalse(linked.contains("hidden"))

        XCTAssertTrue(box.perform(FileCall(name: "write", args: ["shot.jpg"], body: "not-text"), allow: FileTool.edit).hasPrefix("refused"))
        XCTAssertTrue(box.perform(FileCall(name: "write", args: ["review.json"], body: "{}"), allow: FileTool.edit).hasPrefix("refused"))
        XCTAssertTrue(box.perform(FileCall(name: "write", args: ["k001.jpg"], body: "x"), allow: FileTool.edit).hasPrefix("refused"))
        XCTAssertTrue(box.perform(FileCall(name: "tap", args: ["1", "2"]), allow: FileTool.edit).hasPrefix("refused"))
        XCTAssertTrue(box.perform(FileCall(name: "write", args: ["note.txt"], body: "hello"), allow: FileTool.review).hasPrefix("refused"))

        let shot = box.perform(FileCall(name: "screenshot", args: ["1", "orders.jpg"]), allow: FileTool.edit)
        XCTAssertTrue(shot.hasPrefix("ok:"), shot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: boxDir.appendingPathComponent("orders.jpg").path))
        XCTAssertEqual(try Data(contentsOf: boxDir.appendingPathComponent("k001.jpg")), jpeg)

        let crop = box.perform(FileCall(name: "crop", args: ["orders.jpg", "0", "0", "500", "1000", "crop.jpg"]), allow: FileTool.edit)
        XCTAssertTrue(crop.hasPrefix("ok:"), crop)
        let cropped = try Data(contentsOf: boxDir.appendingPathComponent("crop.jpg"))
        let full = try XCTUnwrap(UIImage(data: jpeg)?.cgImage)
        let half = try XCTUnwrap(UIImage(data: cropped)?.cgImage)
        XCTAssertLessThan(half.width, full.width)

        let saved = box.perform(FileCall(name: "save_image", args: ["saved.jpg"], body: jpeg.base64EncodedString()), allow: FileTool.edit)
        XCTAssertTrue(saved.hasPrefix("ok:"), saved)
        XCTAssertNotNil(UIImage(data: try Data(contentsOf: boxDir.appendingPathComponent("saved.jpg"))))
        XCTAssertTrue(box.perform(FileCall(name: "save_image", args: ["bad.jpg"], body: "hello"), allow: FileTool.edit).hasPrefix("refused"))
        XCTAssertTrue(box.perform(FileCall(name: "screenshot", args: ["1", "k002.jpg"]), allow: FileTool.edit).hasPrefix("refused"))
        XCTAssertNil(FileSandbox.insideAgentData(root))
        XCTAssertTrue(AgentFiles.contains(AgentFiles.root.appendingPathComponent("memory/MEMORY.md")))
    }

    func testEditRewritesThePlanAndTheReviewCannotWrite() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try tinyJPEG().write(to: folder.appendingPathComponent("k001.jpg"))
        let before = """
        NAME: Orders
        PROMPT: View orders in Meituan
        1. open "Meituan" | k001.jpg
        2. tap 12 20 "Orders"
        3. tap 12 80 "Back"
        """
        try before.write(to: folder.appendingPathComponent("plan.txt"), atomically: true, encoding: .utf8)
        let box = FileSandbox(root: folder)
        let session = PlanEditSession(sandbox: box, editor: { _, transcript in
            if transcript.contains("Tool result:") { return "MESSAGE: Done." }
            return """
            MESSAGE: The first step repeats until the list ends.
            TOOL write plan.txt
            NAME: Orders
            PROMPT: View orders in Meituan
            UNTIL: the list has ended
            MAX_LOOPS: 6
            1. open "Meituan" | k001.jpg
            END
            """
        }, reviewer: { _, transcript in
            if !transcript.contains("Tool result:") {
                return "TOOL write plan.txt\nhacked\nEND"
            }
            return "VERDICT: ok\nNOTES:\n- still the recorded orders"
        })
        await session.send("turn this into a loop, repeat until before step 2")
        let proposal = try XCTUnwrap(session.proposal)
        XCTAssertTrue(proposal.after.contains("UNTIL: the list has ended"), proposal.after)
        XCTAssertFalse(proposal.after.contains("hacked"))
        XCTAssertTrue(proposal.verdictOK)
        XCTAssertFalse(proposal.blocking)
        XCTAssertTrue(proposal.diff.contains { $0.kind == .added && $0.text.contains("UNTIL:") })
        let onDisk = try String(contentsOf: folder.appendingPathComponent("plan.txt"), encoding: .utf8)
        XCTAssertFalse(onDisk.contains("hacked"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("evil.txt").path))

        let draft = ReviewDraft(source: .recording, folder: folder, runID: nil, outcome: nil, steps: [],
                                name: "Orders", prompt: "View orders in Meituan")
        draft.applyPlan(try XCTUnwrap(PlanText.parse(onDisk)))
        XCTAssertEqual(draft.until, "the list has ended")
        XCTAssertEqual(draft.maxLoops, 6)
        XCTAssertEqual(draft.steps.map(\.name), ["open"])
        XCTAssertEqual(draft.steps[0].frame?.lastPathComponent, "k001.jpg")
        let item = draft.intent(existing: nil)
        XCTAssertEqual(item.until, "the list has ended")
        XCTAssertEqual(item.maxLoops, 6)
    }

    func testOldReviewFileKeepsAnIntentLoopItDoesNotMention() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let action = #"{"action": "tap", "x": 1, "y": 2}"#
        let step: [String: Any] = ["action": action, "note": "", "uncertain": false, "inserted": false]
        let file: [String: Any] = ["steps": [step], "name": "N", "prompt": "P", "hints": [], "icon": "bolt.fill"]
        let data = try JSONSerialization.data(withJSONObject: file)
        try data.write(to: folder.appendingPathComponent("review.json"))
        let draft = ReviewDraft(source: .recording, folder: folder, runID: nil, outcome: nil, steps: [],
                                name: "", prompt: "", until: "keep me", maxLoops: 4)
        XCTAssertEqual(draft.steps.map(\.name), ["tap"])
        XCTAssertEqual(draft.until, "keep me")
        XCTAssertEqual(draft.maxLoops, 4)
    }

    func testToolReplyParsesAMultilineWrite() {
        let reply = """
        MESSAGE: Updating the plan.
        TOOL write plan.txt
        NAME: Orders
        1. open "Meituan"
        END
        TOOL list .
        """
        let parsed = FileTool.parse(reply)
        XCTAssertEqual(parsed.message, "Updating the plan.")
        XCTAssertEqual(parsed.calls.map(\.name), ["write", "list"])
        XCTAssertEqual(parsed.calls[0].args, ["plan.txt"])
        XCTAssertTrue(parsed.calls[0].body.contains("open \"Meituan\""))
        XCTAssertFalse(parsed.calls[0].body.contains("END"))
    }

    private func tinyJPEG() throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
    }

}
